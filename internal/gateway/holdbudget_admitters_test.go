package gateway

import (
	"context"
	"fmt"
	"testing"
	"time"
)

// oneHeld lets a tenant hold one request of up to 1,000 bytes and the gateway two.
var oneHeld = HoldLimits{Requests: 2, Bytes: 2000, TenantRequests: 1, TenantBytes: 1000}

// heldBody is a request whose buffered body is 400 bytes.
var heldBody = RequestMeta{BodyBytes: 400}

// result is what a Reserve running in the background returned.
type heldResult struct {
	res    *reservation
	ok     bool
	reason string
}

// heldAsync runs reserve in the background and hands back its result when it returns.
func heldAsync(reserve func() (*reservation, bool, string)) <-chan heldResult {
	out := make(chan heldResult, 1)
	go func() {
		res, ok, reason := reserve()
		out <- heldResult{res, ok, reason}
	}()
	return out
}

// charged waits until the budget holds want in total.
func charged(t *testing.T, b *holdBudget, want holdUsage) {
	t.Helper()
	waitFor(t, 2*time.Second, fmt.Sprintf("the budget to hold %+v", want), func() bool {
		total, _ := b.usage("")
		return total == want
	})
}

// A request admitted at once holds nothing at the gateway and is not charged; one that waits is charged for its body
// while it waits; a tenant past its share is refused at once rather than queued; and the charge is gone once the
// waiter's turn comes.
// Mutations that turn it red: charge before the free path, skip the budget, or give the charge back on no branch.
func TestSerialPrefillChargesOnlyWhileARequestWaits(t *testing.T) {
	s := newSerialPrefillAdmitter(5 * time.Second)
	b := newHoldBudget(oneHeld)
	s.useHoldBudget(b)
	ctx := context.Background()

	first, ok, _ := s.Reserve(ctx, heldBody, serialBackend(), "a", tierStandard)
	if !ok {
		t.Fatal("the first request was not admitted on a free backend")
	}
	if total, _ := b.usage(""); total != (holdUsage{}) {
		t.Fatalf("a request admitted at once was charged %+v", total)
	}

	second := heldAsync(func() (*reservation, bool, string) {
		return s.Reserve(ctx, heldBody, serialBackend(), "a", tierStandard)
	})
	charged(t, b, holdUsage{requests: 1, bytes: 400})

	if _, ok, reason := s.Reserve(ctx, heldBody, serialBackend(), "a", tierStandard); ok || reason != reasonHoldTenantFull {
		t.Fatalf("a tenant past its share: admitted %v, reason %q; want refused for %q", ok, reason, reasonHoldTenantFull)
	}
	if _, waiting := s.state(serialBackend()); waiting != 1 {
		t.Fatalf("the refused request joined the line: %d waiting", waiting)
	}

	first.Done()
	r := <-second
	if !r.ok || r.reason != reasonSerialPrefillWaited {
		t.Fatalf("the waiter whose turn came: admitted %v, reason %q", r.ok, r.reason)
	}
	defer r.res.Done()
	charged(t, b, holdUsage{})
}

// A waiter that times out or whose client leaves gives its charge back, so a gateway that refused many is not left full.
// Mutation that turns it red: give the charge back only when the turn comes.
func TestSerialPrefillGivesTheChargeBackOnTimeoutAndClientGone(t *testing.T) {
	s := newSerialPrefillAdmitter(5 * time.Second)
	b := newHoldBudget(oneHeld)
	s.useHoldBudget(b)

	first, ok, _ := s.Reserve(context.Background(), heldBody, serialBackend(), "a", tierStandard)
	if !ok {
		t.Fatal("the first request was not admitted on a free backend")
	}
	defer first.Done()

	// The hold is long enough for the charge to be seen while it waits, and short enough to run out in the test.
	timedOut := heldAsync(func() (*reservation, bool, string) {
		return s.reserve(context.Background(), heldBody, serialBackend(), "b", tierStandard, 500*time.Millisecond)
	})
	charged(t, b, holdUsage{requests: 1, bytes: 400})
	if r := <-timedOut; r.ok || r.reason != reasonSerialPrefillHoldTimeout {
		t.Fatalf("a waiter past its hold: admitted %v, reason %q", r.ok, r.reason)
	}
	if total, _ := b.usage(""); total != (holdUsage{}) {
		t.Fatalf("a waiter refused for its hold left %+v charged", total)
	}

	ctx, cancel := context.WithCancel(context.Background())
	gone := heldAsync(func() (*reservation, bool, string) {
		return s.Reserve(ctx, heldBody, serialBackend(), "b", tierStandard)
	})
	charged(t, b, holdUsage{requests: 1, bytes: 400})
	cancel()
	if r := <-gone; r.ok || r.reason != reasonSerialPrefillClientGone {
		t.Fatalf("a waiter whose client left: admitted %v, reason %q", r.ok, r.reason)
	}
	if total, _ := b.usage(""); total != (holdUsage{}) {
		t.Fatalf("a waiter whose client left left %+v charged", total)
	}
}

// HoldCap charges the same budget, because it is serial-prefill per backend and shares the gateway's memory.
// Mutation that turns it red: leave useHoldBudget on holdCapAdmitter a no-op.
func TestHoldCapChargesTheSharedBudget(t *testing.T) {
	h := newHoldCapAdmitter()
	b := newHoldBudget(oneHeld)
	h.useHoldBudget(b)
	backend := serialBackend()
	backend.MaxHold = 5 * time.Second
	ctx := context.Background()

	first, ok, _ := h.Reserve(ctx, heldBody, backend, "a", tierStandard)
	if !ok {
		t.Fatal("the first request was not admitted on a free backend")
	}
	second := heldAsync(func() (*reservation, bool, string) { return h.Reserve(ctx, heldBody, backend, "a", tierStandard) })
	charged(t, b, holdUsage{requests: 1, bytes: 400})
	first.Done()
	r := <-second
	defer r.res.Done()
	charged(t, b, holdUsage{})
}

// Fixed-spacing charges a waiter as serial-prefill does, refuses a tenant past its share, and gives the charge back on timeout.
// Mutations that turn it red: skip the budget, or never give the charge back.
func TestFixedSpacingChargesOnlyWhileARequestWaits(t *testing.T) {
	f := newFixedSpacingAdmitter(time.Hour, 500*time.Millisecond)
	b := newHoldBudget(oneHeld)
	f.useHoldBudget(b)
	ctx := context.Background()

	if _, ok, _ := f.Reserve(ctx, heldBody, serialBackend(), "a", tierStandard); !ok {
		t.Fatal("the first request was not admitted with no spacing to wait out")
	}
	if total, _ := b.usage(""); total != (holdUsage{}) {
		t.Fatalf("a request admitted at once was charged %+v", total)
	}
	second := heldAsync(func() (*reservation, bool, string) {
		return f.Reserve(ctx, heldBody, serialBackend(), "a", tierStandard)
	})
	charged(t, b, holdUsage{requests: 1, bytes: 400})
	if _, ok, reason := f.Reserve(ctx, heldBody, serialBackend(), "a", tierStandard); ok || reason != reasonHoldTenantFull {
		t.Fatalf("a tenant past its share: admitted %v, reason %q", ok, reason)
	}
	if r := <-second; r.ok || r.reason != reasonFixedSpacingHoldTimeout {
		t.Fatalf("a waiter an hour's spacing behind: admitted %v, reason %q", r.ok, r.reason)
	}
	charged(t, b, holdUsage{})
}

// The HoldCap admitter a server builds for its first HoldCap backend charges the server's own budget.
// Mutation that turns it red: build the HoldCap admitter without useHoldBudget in admissionFor.
func TestServerGivesItsHoldCapAdmitterTheBudget(t *testing.T) {
	s := &Server{}
	a, mode, holdCap := s.admissionFor([]*BackendRef{{Admission: AdmissionHoldCap}})
	if !holdCap || mode != AdmissionHoldCap {
		t.Fatalf("a HoldCap head selected mode %q", mode)
	}
	if got := a.(holdCapAdmitter).s.budget; got != s.holds() {
		t.Fatalf("the HoldCap admitter charges %p, not the server's budget %p", got, s.holds())
	}
}
