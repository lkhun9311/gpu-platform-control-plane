/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package gateway

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	dto "github.com/prometheus/client_model/go"
	"github.com/prometheus/common/expfmt"
	"github.com/prometheus/common/model"
)

// --- Exposition parser -----------------------------------------------------
//
// Design rationale (design spec v1 Mechanism section, v2 Arm C "Metric aggregation"): vLLM has
// renamed the KV-cache usage series across versions, so both names are read, and a scrape that
// samples multiple engine/model series for one logical backend is aggregated (max usage, sum
// waiting) rather than picked arbitrarily.

const (
	// metricUsageV1 is vLLM's current KV-cache usage series name.
	metricUsageV1 = "vllm:kv_cache_usage_perc"
	// metricUsageV0 is the pre-rename alias, read only when metricUsageV1 is absent.
	metricUsageV0 = "vllm:gpu_cache_usage_perc"
	// metricWaiting is vLLM's waiting-queue depth series name; it has not been renamed.
	metricWaiting = "vllm:num_requests_waiting"
)

// maxMetricsBytes bounds how much of a /metrics response the parser will read.
//
// Mirrors maxBodyBytes in proxy.go: an exposition response is normally tens of KB, so this
// leaves ample room while keeping a misbehaving or malicious scrape target unable to make the
// gateway buffer an unbounded response (design spec Arm C section, "Scraper hardening").
const maxMetricsBytes = 1 << 20 // 1MiB

// kvSample is one backend's parsed pressure signal from a single /metrics scrape.
type kvSample struct {
	// CacheUsage is the aggregated KV-cache usage fraction, in [0,1].
	CacheUsage float64
	// Waiting is the aggregated waiting-queue depth.
	Waiting int
}

// parseKVMetrics parses r as vLLM's Prometheus text exposition format and returns the pinned
// KV-cache usage and waiting-queue series, aggregated for one logical backend.
//
// r is wrapped in a bounded reader regardless of what the caller already bounded, so this
// function is safe to call directly (as the parser specs do) and not only through the scraper.
func parseKVMetrics(r io.Reader) (kvSample, error) {
	// TextParser's zero value carries an unset ValidationScheme, which panics on the first
	// metric name it validates; LegacyValidation is the classic Prometheus exposition scheme
	// (colons included, as vLLM's own metric names use), so it is what NewTextParser needs
	// here rather than leaving the parser's zero value in play.
	parser := expfmt.NewTextParser(model.LegacyValidation)
	mfs, err := parser.TextToMetricFamilies(io.LimitReader(r, maxMetricsBytes))
	if err != nil {
		return kvSample{}, fmt.Errorf("parse vllm metrics: %w", err)
	}

	usage, err := parseUsage(mfs)
	if err != nil {
		return kvSample{}, err
	}
	waiting, err := parseWaiting(mfs)
	if err != nil {
		return kvSample{}, err
	}
	return kvSample{CacheUsage: usage, Waiting: waiting}, nil
}

// parseUsage reads the KV-cache usage series, preferring the V1 name and falling back to the V0
// alias, and aggregates multiple matching series (design spec Arm C section, "Metric
// aggregation") by taking the max.
func parseUsage(mfs map[string]*dto.MetricFamily) (float64, error) {
	mf, name := mfs[metricUsageV1], metricUsageV1
	if mf == nil || len(mf.GetMetric()) == 0 {
		mf, name = mfs[metricUsageV0], metricUsageV0
	}
	if mf == nil || len(mf.GetMetric()) == 0 {
		return 0, fmt.Errorf("vllm metrics: missing %s (and V0 alias %s)", metricUsageV1, metricUsageV0)
	}

	values, err := gaugeValues(mf, name)
	if err != nil {
		return 0, err
	}
	max := values[0]
	for _, v := range values[1:] {
		if v > max {
			max = v
		}
	}
	if max < 0 || max > 1 {
		return 0, fmt.Errorf("vllm metrics: %s value %v out of range [0,1]", name, max)
	}
	return max, nil
}

// parseWaiting reads the waiting-queue depth series and aggregates multiple matching series
// (design spec Arm C section, "Metric aggregation") by summing.
func parseWaiting(mfs map[string]*dto.MetricFamily) (int, error) {
	mf, ok := mfs[metricWaiting]
	if !ok || len(mf.GetMetric()) == 0 {
		return 0, fmt.Errorf("vllm metrics: missing %s", metricWaiting)
	}

	values, err := gaugeValues(mf, metricWaiting)
	if err != nil {
		return 0, err
	}
	var sum float64
	for _, v := range values {
		if v < 0 {
			return 0, fmt.Errorf("vllm metrics: %s value %v is negative", metricWaiting, v)
		}
		sum += v
	}
	return int(math.Round(sum)), nil
}

// gaugeValues extracts every series' value from mf, validating that mf is shaped the way this
// parser assumes: a gauge family whose every metric actually carries a gauge value.
//
// Anything else is an unexpected shape and is rejected rather than guessed at (design spec Arm
// C section, "... or reject an unexpected shape"), and every returned value is already checked
// finite, so callers never aggregate a NaN or Inf into a max or sum.
func gaugeValues(mf *dto.MetricFamily, name string) ([]float64, error) {
	if mf.GetType() != dto.MetricType_GAUGE {
		return nil, fmt.Errorf("vllm metrics: %s is not a gauge (unexpected shape)", name)
	}
	metrics := mf.GetMetric()
	values := make([]float64, 0, len(metrics))
	for _, m := range metrics {
		g := m.GetGauge()
		if g == nil {
			return nil, fmt.Errorf("vllm metrics: %s series missing a gauge value (unexpected shape)", name)
		}
		v := g.GetValue()
		if math.IsNaN(v) || math.IsInf(v, 0) {
			return nil, fmt.Errorf("vllm metrics: %s value is not finite", name)
		}
		values = append(values, v)
	}
	return values, nil
}

// --- Pressure state machine -------------------------------------------------

// pressureConfig holds the KV-aware pressure state machine's tunable thresholds.
//
// Design rationale (design spec v1 Mechanism section): engage and release are deliberately
// asymmetric so the guard does not flap at the boundary between them.
type pressureConfig struct {
	// engageUsage and waitingThresh are the ENGAGE thresholds: cacheUsage > engageUsage OR
	// waiting > waitingThresh, sustained for 2 consecutive fresh samples.
	engageUsage   float64
	waitingThresh int
	// releaseUsage is the RELEASE cache-usage threshold: cacheUsage < releaseUsage AND
	// waiting < waitingThresh/2, sustained for releaseSustain.
	releaseUsage   float64
	releaseSustain time.Duration
}

// pressureState is the per-backend KV-cache pressure state machine.
//
// It is driven exclusively by observe and resetConsecutive, both called from exactly one
// goroutine at a time (the backend's own scraper loop), so it needs no lock of its own. It
// never touches HTTP or a real clock itself; both come from the caller, which is what makes it
// testable with an injected clock and no goroutines at all.
type pressureState struct {
	cfg pressureConfig

	engaged bool
	// overThresholdCount counts consecutive fresh samples over an engage threshold while not yet
	// engaged; it resets to 0 on any sample that is not over threshold, so a single spike can
	// never engage on its own.
	overThresholdCount int
	// underSince is when the current unbroken under-both-release-thresholds streak began, while
	// engaged; the zero value means "not currently under both thresholds".
	underSince time.Time
}

// newPressureState returns a pressureState in the RELEASED state.
func newPressureState(cfg pressureConfig) *pressureState {
	return &pressureState{cfg: cfg}
}

// resetConsecutive clears the engage/release counters without touching engaged.
//
// Design rationale (design spec Arm C section, "Reset the consecutive-sample timers after
// staleness"): a stale gap must never count toward the 2-consecutive engage condition or the
// 30s release-sustain window. The caller invokes this before observe whenever a stale gap
// preceded the fresh sample about to be recorded, so that sample starts counting from zero
// rather than continuing whatever was already in flight before the gap.
//
// engaged is left as-is deliberately: staleness bypasses the guard's decision at the Admit
// layer (kvAwareAdmitter, via the published snapshot's fresh flag), not by mutating this
// internal flag, so a resumed fresh stream of samples still sees the state it actually left off
// in rather than being forced back through two fresh engage samples for no reason.
func (p *pressureState) resetConsecutive() {
	p.overThresholdCount = 0
	p.underSince = time.Time{}
}

// observe feeds one fresh, successful sample at time now into the state machine.
//
// Design rationale (design spec v1 Mechanism / v2 Arm C sections):
//
//   - ENGAGE when cacheUsage > engageUsage OR waiting > waitingThresh, for 2 consecutive fresh
//     samples (checked only while not already engaged).
//   - RELEASE when cacheUsage < releaseUsage AND waiting < waitingThresh/2, sustained for
//     releaseSustain, measured from when the unbroken streak began (checked only while engaged).
func (p *pressureState) observe(sample kvSample, now time.Time) {
	over := sample.CacheUsage > p.cfg.engageUsage || sample.Waiting > p.cfg.waitingThresh
	under := sample.CacheUsage < p.cfg.releaseUsage && sample.Waiting < p.cfg.waitingThresh/2

	if !p.engaged {
		if over {
			p.overThresholdCount++
		} else {
			p.overThresholdCount = 0
		}
		if p.overThresholdCount >= 2 {
			p.engaged = true
			p.overThresholdCount = 0
		}
		return
	}

	// Already engaged: only the release path matters until the sustain window closes.
	if !under {
		p.underSince = time.Time{}
		return
	}
	if p.underSince.IsZero() {
		p.underSince = now
	}
	if now.Sub(p.underSince) >= p.cfg.releaseSustain {
		p.engaged = false
		p.underSince = time.Time{}
	}
}

// Engaged reports the state machine's current engage/release state.
func (p *pressureState) Engaged() bool { return p.engaged }

// --- Snapshot ----------------------------------------------------------------

// clockFunc returns the current time.
//
// Production uses time.Now; tests inject a fake clock so the state machine and scraper are
// deterministic under go test -race, without real sleeps.
type clockFunc func() time.Time

// backendSnapshot is the immutable, atomically published view of one backend's KV-cache
// pressure telemetry.
//
// Design rationale (design spec Arm C section, "Request-path never scrapes and never holds a
// mutex during HTTP"): the request path reads exactly this struct, lock-free via
// atomic.Pointer, and never touches the scraper's HTTP client or pressureState directly. The
// struct is never mutated after being stored; a new one is built and swapped in on every scrape
// attempt instead.
type backendSnapshot struct {
	engaged    bool
	cacheUsage float64
	waiting    int
	// fresh is false whenever now-lastSuccessfulScrape exceeds maxStaleness, or no scrape has
	// ever succeeded yet. kvAwareAdmitter bypasses (admits) whenever this is false, regardless of
	// engaged (design spec Arm C section, "Fail-open is a staleness bypass, not state
	// unchanged"): retaining engaged=true across a stale gap and still rejecting on it would be
	// fail-CLOSED, which is exactly the v1 bug this snapshot exists to avoid.
	fresh bool
}

// --- Scraper -----------------------------------------------------------------

// errRedirectRefused is returned by backendScraper's CheckRedirect hook.
//
// Design rationale (design spec Arm C section, "Scraper hardening"): a scrape target that
// redirects is not the backend it claims to be, and following the redirect could send the
// scrape wherever it points.
var errRedirectRefused = errors.New("vllm metrics scrape: redirects are not followed")

// scraperConfig bundles the tunables shared by every backend's scraper and pressure state
// machine.
type scraperConfig struct {
	engageUsage    float64
	releaseUsage   float64
	waitingThresh  int
	releaseSustain time.Duration
	scrapeInterval time.Duration
	maxStaleness   time.Duration
	httpTimeout    time.Duration
	clock          clockFunc
}

// pressureConfig extracts the subset scraperConfig shares with pressureState.
func (c scraperConfig) pressureConfig() pressureConfig {
	return pressureConfig{
		engageUsage:    c.engageUsage,
		releaseUsage:   c.releaseUsage,
		waitingThresh:  c.waitingThresh,
		releaseSustain: c.releaseSustain,
	}
}

// backendScraper owns one backend's HTTP scrape loop, pressure state machine, and published
// snapshot.
//
// Every field below except snap is touched only from this scraper's own goroutine (run/tick),
// so none of them need a lock; the request path only ever reads snap, through the atomic
// pointer swapped in by publish.
type backendScraper struct {
	ref BackendRef
	cfg scraperConfig

	client *http.Client
	state  *pressureState

	// lastSuccessAt, everSucceeded, and lastSample are goroutine-confined to run/tick, same as
	// state above.
	lastSuccessAt time.Time
	everSucceeded bool
	lastSample    kvSample

	snap atomic.Pointer[backendSnapshot]

	stop chan struct{}
	done chan struct{}
}

// newBackendScraper returns a backendScraper for ref, not yet started.
func newBackendScraper(ref BackendRef, cfg scraperConfig) *backendScraper {
	b := &backendScraper{
		ref:   ref,
		cfg:   cfg,
		state: newPressureState(cfg.pressureConfig()),
		client: &http.Client{
			Timeout: cfg.httpTimeout,
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return errRedirectRefused
			},
		},
		stop: make(chan struct{}),
		done: make(chan struct{}),
	}
	// Publish a zero-value (not fresh, not engaged) snapshot immediately, so a snapshot always
	// exists from the moment a backend is registered rather than requiring callers to
	// special-case "registered but nothing published yet" separately from "stale".
	b.snap.Store(&backendSnapshot{})
	return b
}

// scrapeURL returns the backend's metrics endpoint: its resolved URL with /metrics appended.
//
// Design rationale (design spec v2 Arm C section, "Cut the metrics-URL annotation override"):
// there is no per-tenant override here, deliberately; the scrape always targets the same host
// the proxy forwards requests to.
func (b *backendScraper) scrapeURL() string {
	return strings.TrimSuffix(b.ref.URL.String(), "/") + "/metrics"
}

// scrape performs one hardened HTTP GET against the backend's metrics endpoint and parses the
// result.
//
// Hardening (design spec Arm C section, "Scraper hardening"): a bounded client timeout (set on
// b.client at construction), no redirects (also set at construction), status-code validation
// (200 only), a bounded response body, and a request built fresh with no headers copied from
// anywhere, so no caller's or the gateway's own credentials are ever forwarded to the scrape
// target.
func (b *backendScraper) scrape(ctx context.Context) (kvSample, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, b.scrapeURL(), nil)
	if err != nil {
		return kvSample{}, fmt.Errorf("build scrape request for %s: %w", b.ref.Name, err)
	}
	resp, err := b.client.Do(req)
	if err != nil {
		return kvSample{}, fmt.Errorf("scrape %s: %w", b.ref.Name, err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		// Drain a bounded amount so a non-200 response still leaves the connection reusable,
		// without letting even an error response buffer unboundedly.
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, maxMetricsBytes))
		return kvSample{}, fmt.Errorf("scrape %s: unexpected status %d", b.ref.Name, resp.StatusCode)
	}
	return parseKVMetrics(io.LimitReader(resp.Body, maxMetricsBytes))
}

// tick performs one scrape attempt and publishes its result.
//
// Design rationale (design spec Arm C section, "Fail-open is a staleness bypass" and "Reset the
// consecutive-sample timers after staleness"): a scrape failure never touches the pressure
// state machine directly (state unchanged toward staleness, not toward ENGAGED or RELEASED);
// only a successful scrape does, and only after first resetting the consecutive counters if the
// gap since the last success already exceeded maxStaleness.
func (b *backendScraper) tick(ctx context.Context) {
	now := b.cfg.clock()
	sample, err := b.scrape(ctx)
	if err != nil {
		backendScrapeErrors.WithLabelValues(b.ref.Namespace, b.ref.Name).Inc()
		b.publish(now)
		return
	}
	if b.everSucceeded && now.Sub(b.lastSuccessAt) > b.cfg.maxStaleness {
		b.state.resetConsecutive()
	}
	b.state.observe(sample, now)
	b.lastSuccessAt = now
	b.everSucceeded = true
	b.lastSample = sample
	b.publish(now)
}

// publish builds an immutable snapshot from the scraper's current state and atomically swaps it
// in, then mirrors it onto the backend-scoped gauges.
//
// now is the same clock reading tick took at the start of this scrape attempt, kept fixed for
// both the staleness check here and any staleness check tick already made, so one tick call
// never straddles two different notions of "now".
func (b *backendScraper) publish(now time.Time) {
	fresh := b.everSucceeded && now.Sub(b.lastSuccessAt) <= b.cfg.maxStaleness
	snap := &backendSnapshot{
		engaged:    b.state.Engaged(),
		cacheUsage: b.lastSample.CacheUsage,
		waiting:    b.lastSample.Waiting,
		fresh:      fresh,
	}
	b.snap.Store(snap)

	admissionGuardEngaged.WithLabelValues(b.ref.Namespace, b.ref.Name, b.ref.Model).Set(boolToFloat(snap.engaged))
	backendKVCacheUsage.WithLabelValues(b.ref.Namespace, b.ref.Name, b.ref.Model).Set(snap.cacheUsage)
	backendWaitingRequests.WithLabelValues(b.ref.Namespace, b.ref.Name, b.ref.Model).Set(float64(snap.waiting))
	backendTelemetryFresh.WithLabelValues(b.ref.Namespace, b.ref.Name).Set(boolToFloat(snap.fresh))
}

// boolToFloat maps a boolean gauge value to Prometheus's 0/1 convention.
func boolToFloat(v bool) float64 {
	if v {
		return 1
	}
	return 0
}

// run scrapes on cfg.scrapeInterval until stop is closed.
//
// Design rationale (design spec Arm C section, "Cold registration / prewarm"): the first scrape
// happens immediately rather than waiting a full interval, so registering a backend doubles as
// the prewarm the design spec asks the benchmark harness to trigger during warmup, rather than
// leaving the first scrapeInterval seconds of real traffic looking at a never-scraped, not-fresh
// snapshot for longer than necessary.
func (b *backendScraper) run() {
	defer close(b.done)
	ctx := context.Background()
	b.tick(ctx)
	ticker := time.NewTicker(b.cfg.scrapeInterval)
	defer ticker.Stop()
	for {
		select {
		case <-b.stop:
			return
		case <-ticker.C:
			b.tick(ctx)
		}
	}
}

// Stop signals run to exit and waits for it to actually do so.
func (b *backendScraper) Stop() {
	close(b.stop)
	<-b.done
}

// --- Scraper manager -----------------------------------------------------------

// scraperManager runs one backendScraper per registered backend and lets kvAwareAdmitter look
// up published snapshots by backend key.
type scraperManager struct {
	cfg scraperConfig

	mu       sync.Mutex
	scrapers map[string]*backendScraper
}

// newScraperManager returns an empty scraperManager, defaulting cfg.clock to time.Now when the
// caller left it nil.
func newScraperManager(cfg scraperConfig) *scraperManager {
	if cfg.clock == nil {
		cfg.clock = time.Now
	}
	return &scraperManager{cfg: cfg, scrapers: make(map[string]*backendScraper)}
}

// Register starts a scraper for backend if one is not already running for its key.
//
// Design rationale (design spec Arm C section, "make Register safe to call before requests"):
// idempotent, so a caller that registers the same backend on every routed request (this
// package's chosen wiring, design spec Config and API section) only actually starts a scraper
// on the first such call.
func (m *scraperManager) Register(backend *BackendRef) {
	key := backendKey(backend)
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.scrapers[key]; ok {
		return
	}
	s := newBackendScraper(*backend, m.cfg)
	m.scrapers[key] = s
	go s.run()
}

// Unregister stops backend's scraper and deletes its stale metric labels.
//
// Design rationale (design spec Arm C section, "Lifecycle"): deleting or replacing a backend
// must not leave its last-published gauge values (e.g. admission_guard_engaged=1) visible
// forever after it stops being scraped.
func (m *scraperManager) Unregister(backend *BackendRef) {
	key := backendKey(backend)
	m.mu.Lock()
	s, ok := m.scrapers[key]
	if ok {
		delete(m.scrapers, key)
	}
	m.mu.Unlock()
	if !ok {
		return
	}
	s.Stop()

	admissionGuardEngaged.DeleteLabelValues(backend.Namespace, backend.Name, backend.Model)
	backendKVCacheUsage.DeleteLabelValues(backend.Namespace, backend.Name, backend.Model)
	backendWaitingRequests.DeleteLabelValues(backend.Namespace, backend.Name, backend.Model)
	backendTelemetryFresh.DeleteLabelValues(backend.Namespace, backend.Name)
	// backend_scrape_errors_total is a counter, deliberately left in place: it is the backend's
	// historical error count, not a live gauge, and dropping it would understate the total
	// number of scrape errors this backend ever produced if the same key is registered again.
}

// Stop stops every running scraper, for graceful shutdown.
func (m *scraperManager) Stop() {
	m.mu.Lock()
	scrapers := make([]*backendScraper, 0, len(m.scrapers))
	for _, s := range m.scrapers {
		scrapers = append(scrapers, s)
	}
	m.scrapers = make(map[string]*backendScraper)
	m.mu.Unlock()
	for _, s := range scrapers {
		s.Stop()
	}
}

// snapshotFor returns the published snapshot for key, or (nil, false) if no scraper is
// registered for it.
func (m *scraperManager) snapshotFor(key string) (*backendSnapshot, bool) {
	m.mu.Lock()
	s, ok := m.scrapers[key]
	m.mu.Unlock()
	if !ok {
		return nil, false
	}
	return s.snap.Load(), true
}

// --- Admitter -----------------------------------------------------------------

// reasonKVCachePressure is the 429 reason kvAwareAdmitter reports when it rejects a
// standard-tier, long-input request while its backend is engaged.
const reasonKVCachePressure = "kv_cache_pressure"

// backendRegistrar is implemented by admitters that need to learn about a backend as soon as it
// is routed.
//
// kv-aware is the only admission mode that scrapes anything, so it is the only implementer;
// off and static-cap don't satisfy this, and chatCompletions treats that as a no-op (design
// spec Config and API section, "the gateway registers backends as they are first routed").
type backendRegistrar interface {
	RegisterBackend(backend *BackendRef)
}

// kvAwareAdmitter is the Admitter behind AdmissionKVAware.
//
// Design rationale (design spec Arm C section): it never scrapes and never blocks on I/O; Admit
// only reads the snapshot the scraper manager's background goroutines already published.
type kvAwareAdmitter struct {
	manager       *scraperManager
	longThreshold int
}

// newKVAwareAdmitter returns a kvAwareAdmitter reading from manager.
func newKVAwareAdmitter(manager *scraperManager, longThreshold int) *kvAwareAdmitter {
	return &kvAwareAdmitter{manager: manager, longThreshold: longThreshold}
}

// RegisterBackend registers backend with the scraper manager.
//
// chatCompletions calls this on every routed request when the configured Admitter implements
// backendRegistrar (kv-aware only); scraperManager.Register is idempotent, so only the first
// call for a given backend actually starts a scraper.
func (a *kvAwareAdmitter) RegisterBackend(backend *BackendRef) {
	a.manager.Register(backend)
}

// Admit implements the Arm C decision (design spec v1 Mechanism / v2 Arm C sections):
//
//   - backend not registered, or its telemetry is stale or has never succeeded -> admit (a
//     staleness BYPASS of the whole guard, not a fail-closed "keep rejecting" retained from
//     whatever engaged said last).
//   - not engaged -> admit.
//   - engaged, premium tier -> admit (the token bucket still applies upstream).
//   - engaged, standard tier, EstInputTokens >= longThreshold -> reject, reasonKVCachePressure.
//   - engaged, standard tier, short -> admit.
func (a *kvAwareAdmitter) Admit(_ context.Context, meta RequestMeta, backend *BackendRef, _, tier string) (bool, string) {
	snap, ok := a.manager.snapshotFor(backendKey(backend))
	if !ok || !snap.fresh {
		return true, ""
	}
	if !snap.engaged {
		return true, ""
	}
	if tier == tierPremium {
		return true, ""
	}
	if meta.EstInputTokens >= a.longThreshold {
		return false, reasonKVCachePressure
	}
	return true, ""
}

// KVAwareConfig configures the kv-aware admission mode's thresholds and scraper.
//
// Design rationale (design spec Config and API section, "Wire mode + flags"): the real
// threshold/W/rate values are tuned on the paid GPU pilot; the values cmd/gateway/main.go
// defaults these flags to are sensible test/dev starting points only, not tuned numbers.
type KVAwareConfig struct {
	// EngageUsage and WaitingThresh are the ENGAGE thresholds; ReleaseUsage and ReleaseSustain
	// are the RELEASE thresholds. See pressureConfig for the exact condition each one gates.
	EngageUsage    float64
	ReleaseUsage   float64
	WaitingThresh  int
	ReleaseSustain time.Duration
	// ScrapeInterval is how often each registered backend is scraped.
	ScrapeInterval time.Duration
	// MaxStaleness is how long since the last successful scrape before the guard bypasses
	// (admits) rather than acting on possibly-stale telemetry.
	MaxStaleness time.Duration
	// HTTPTimeout bounds a single scrape's HTTP round trip.
	HTTPTimeout time.Duration
	// LongThreshold is the minimum EstInputTokens a standard-tier request needs before an
	// engaged backend rejects it; shared in spirit with static-cap's longThreshold, since both
	// modes meter the same eligible population.
	LongThreshold int
}

// toScraperConfig adapts the exported, flag-friendly KVAwareConfig to the internal
// scraperConfig the scraper machinery actually reads.
func (c KVAwareConfig) toScraperConfig() scraperConfig {
	return scraperConfig{
		engageUsage:    c.EngageUsage,
		releaseUsage:   c.ReleaseUsage,
		waitingThresh:  c.WaitingThresh,
		releaseSustain: c.ReleaseSustain,
		scrapeInterval: c.ScrapeInterval,
		maxStaleness:   c.MaxStaleness,
		httpTimeout:    c.HTTPTimeout,
		clock:          time.Now,
	}
}

// NewKVAwareAdmitter returns the Admitter behind AdmissionKVAware, plus a stop function the
// caller must invoke on shutdown to stop every backend's scrape goroutine.
//
// Why a constructor rather than a struct literal, mirroring NewStaticCapAdmitter in
// admission.go: kvAwareAdmitter and scraperManager are both unexported, so
// cmd/gateway/main.go needs this to assemble one from its own admission-mode flags.
func NewKVAwareAdmitter(cfg KVAwareConfig) (Admitter, func()) {
	manager := newScraperManager(cfg.toScraperConfig())
	a := newKVAwareAdmitter(manager, cfg.LongThreshold)
	return a, manager.Stop
}
