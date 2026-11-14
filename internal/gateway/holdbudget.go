package gateway

import (
	"fmt"
	"sync"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"sigs.k8s.io/controller-runtime/pkg/metrics"
)

// A hold budget bounds what the gateway keeps while requests wait for their turn.
//
// serial-prefill, HoldCap and fixed-spacing hold a standard request rather than refuse it, and a held request keeps a goroutine and its buffered body until its hold runs out.
// Nothing bounded how many were held, so a burst could have the gateway OOM-killed under its 256 Mi limit, which drops every request it serves, premium included.
// Design: docs/superpowers/specs/2026-11-14-gateway-hold-capacity-design.md.

const (
	// reasonHoldFull refuses a request that would have waited when the gateway already holds as many requests or bytes as it may.
	reasonHoldFull = "hold_full"
	// reasonHoldTenantFull refuses one whose tenant already holds its share, so one tenant cannot take every slot the gateway has.
	reasonHoldTenantFull = "hold_tenant_full"
)

// HoldLimits bounds the requests the gateway holds at once and the body bytes they keep, in total and per tenant.
type HoldLimits struct {
	Requests       int64
	Bytes          int64
	TenantRequests int64
	TenantBytes    int64
}

// DefaultHoldLimits keeps held bodies to a quarter of the gateway's 256 Mi memory limit.
// The registered HoldCap traces hold at most 232 contender requests of at most 40,000 characters, under every one of these.
var DefaultHoldLimits = HoldLimits{Requests: 1024, Bytes: 64 << 20, TenantRequests: 512, TenantBytes: 32 << 20}

// Validate refuses a zero or negative limit, because it would refuse every request that ever had to wait and look like a rule working.
// A tenant limit above its total is refused too, because the total would then decide alone while the flag claimed otherwise.
func (l HoldLimits) Validate() error {
	if l.Requests <= 0 || l.Bytes <= 0 || l.TenantRequests <= 0 || l.TenantBytes <= 0 {
		return fmt.Errorf("every hold limit must be above zero, got requests=%d bytes=%d tenant-requests=%d tenant-bytes=%d",
			l.Requests, l.Bytes, l.TenantRequests, l.TenantBytes)
	}
	if l.TenantRequests > l.Requests || l.TenantBytes > l.Bytes {
		return fmt.Errorf("a tenant's hold limits cannot exceed the totals, got tenant-requests=%d of %d and tenant-bytes=%d of %d",
			l.TenantRequests, l.Requests, l.TenantBytes, l.Bytes)
	}
	return nil
}

var (
	// heldRequests and heldBytes are what the gateway holds now, so an operator sees a limit coming before it refuses anyone.
	// They carry no tenant label, because a tenant name per series would let callers grow the series without bound.
	heldRequests = promauto.With(metrics.Registry).NewGauge(prometheus.GaugeOpts{
		Name: metricPrefix + "held_requests",
		Help: "Standard requests the gateway is holding for their turn.",
	})
	heldBytes = promauto.With(metrics.Registry).NewGauge(prometheus.GaugeOpts{
		Name: metricPrefix + "held_bytes",
		Help: "Request body bytes kept by the requests the gateway is holding.",
	})
)

type holdUsage struct{ requests, bytes int64 }

// holdBudget is one gateway's charge for held requests, shared by every admitter that holds, because they share its memory.
type holdBudget struct {
	mu      sync.Mutex
	limits  HoldLimits
	total   holdUsage
	tenants map[string]holdUsage
}

func newHoldBudget(l HoldLimits) *holdBudget {
	return &holdBudget{limits: l, tenants: map[string]holdUsage{}}
}

// holdBudgetUser is an admitter that holds requests and so must charge them to the gateway's budget.
type holdBudgetUser interface {
	useHoldBudget(*holdBudget)
}

// configure changes the limits for requests that start waiting after it; those already held keep their charge.
func (b *holdBudget) configure(l HoldLimits) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.limits = l
}

// holds is the gateway's one hold budget, made with the defaults the first time anything asks for it.
// A Server that is never configured still bounds what it holds, because an unbounded default is the failure this exists to stop.
func (s *Server) holds() *holdBudget {
	s.holdBudgetOnce.Do(func() { s.holdBudget = newHoldBudget(DefaultHoldLimits) })
	return s.holdBudget
}

// SetHoldLimits replaces the hold limits, refusing ones that Validate rejects and leaving the previous limits in force.
// It may be called before or after SetAdmitter, because every admitter shares the same budget and only its limits change.
func (s *Server) SetHoldLimits(l HoldLimits) error {
	if err := l.Validate(); err != nil {
		return err
	}
	s.holds().configure(l)
	return nil
}

// refusedForHold reports whether an admission reason is the hold budget's, which the server answers 503 rather than 429.
func refusedForHold(reason string) bool {
	return reason == reasonHoldFull || reason == reasonHoldTenantFull
}

// take charges one held request of n body bytes to tenant, or names the limit it would pass and charges nothing.
// The tenant's share is checked first, because when both are reached the tenant's own excess is the cause it can act on.
// A nil budget charges nothing, so an admitter built without one holds as it always did.
func (b *holdBudget) take(tenant string, n int64) (bool, string) {
	if b == nil {
		return true, ""
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	t := b.tenants[tenant]
	if t.requests+1 > b.limits.TenantRequests || t.bytes+n > b.limits.TenantBytes {
		return false, reasonHoldTenantFull
	}
	if b.total.requests+1 > b.limits.Requests || b.total.bytes+n > b.limits.Bytes {
		return false, reasonHoldFull
	}
	b.tenants[tenant] = holdUsage{requests: t.requests + 1, bytes: t.bytes + n}
	b.total = holdUsage{requests: b.total.requests + 1, bytes: b.total.bytes + n}
	heldRequests.Inc()
	heldBytes.Add(float64(n))
	return true, ""
}

// give returns what take charged; a tenant left holding nothing is forgotten, so the map does not keep every tenant ever seen.
func (b *holdBudget) give(tenant string, n int64) {
	if b == nil {
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	t := b.tenants[tenant]
	t = holdUsage{requests: t.requests - 1, bytes: t.bytes - n}
	if t.requests <= 0 {
		delete(b.tenants, tenant)
	} else {
		b.tenants[tenant] = t
	}
	b.total = holdUsage{requests: b.total.requests - 1, bytes: b.total.bytes - n}
	heldRequests.Dec()
	heldBytes.Sub(float64(n))
}

// usage is what the gateway and one tenant hold now, for tests.
func (b *holdBudget) usage(tenant string) (holdUsage, holdUsage) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.total, b.tenants[tenant]
}
