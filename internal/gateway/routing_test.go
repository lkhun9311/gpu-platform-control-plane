package gateway

import (
	"net/http"
	"net/url"
	"strings"
	"testing"

	"sigs.k8s.io/controller-runtime/pkg/metrics"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

func routeRef(name, policy string) *BackendRef {
	u, _ := url.Parse("http://" + name + ".ns.svc:8000")
	return &BackendRef{Namespace: "ns", Name: name, URL: u, Model: "m", Routing: policy}
}

func twoRefs(policy string) []*BackendRef {
	return []*BackendRef{routeRef("a", policy), routeRef("b", policy)}
}

func testRouter() *router {
	return newRouter(RoutingConfig{ChunkChars: 4, CapacityChunks: 100, MaxBackends: 8, MaxChunks: 64, StepBudgetTokens: 512})
}

// A prompt sharing a prefix shares exactly the chunks of that prefix, and one character changed early changes every
// chunk after it, which is what makes a match at chunk i a match of the whole prefix through i.
func TestPrefixChainIsAChain(t *testing.T) {
	a := prefixChain("t", "m", "aaaabbbbcccc", 4, 64)
	b := prefixChain("t", "m", "aaaabbbbdddd", 4, 64)
	c := prefixChain("t", "m", "xaaabbbbcccc", 4, 64)
	if len(a) != 3 || a[0] != b[0] || a[1] != b[1] || a[2] == b[2] {
		t.Fatalf("shared prefix not shared: %v %v", a, b)
	}
	for i := range a {
		if a[i] == c[i] {
			t.Fatalf("chunk %d survived a change in chunk 0", i)
		}
	}
	// Only whole chunks, and at most maxChunks of them.
	if n := len(prefixChain("t", "m", "aaaabbbbcc", 4, 64)); n != 2 {
		t.Fatalf("a partial tail was hashed: %d chunks", n)
	}
	if n := len(prefixChain("t", "m", strings.Repeat("a", 400), 4, 64)); n != 64 {
		t.Fatalf("maxChunks not applied: %d chunks", n)
	}
}

// The index is tenant-scoped: the same text from another tenant, or for another model, matches nothing.
// Mutation that turns this red: drop the tenant from prefixChain's seed.
func TestPrefixChainIsTenantScoped(t *testing.T) {
	a := prefixChain("tenant-a", "m", "aaaabbbb", 4, 64)
	b := prefixChain("tenant-b", "m", "aaaabbbb", 4, 64)
	m := prefixChain("tenant-a", "m2", "aaaabbbb", 4, 64)
	if a[0] == b[0] || a[0] == m[0] {
		t.Fatal("two tenants or two models share a chunk hash")
	}
	r := testRouter()
	refs := twoRefs(platformv1.RoutingPolicyPrefixAffinity)
	got, dec := r.route(refs, platformv1.RoutingPolicyPrefixAffinity, "tenant-a", "m", func() string { return "aaaabbbbcccc" })
	dec.done()
	_, dec2 := r.route(twoRefs(platformv1.RoutingPolicyPrefixAffinity), platformv1.RoutingPolicyPrefixAffinity, "tenant-b", "m",
		func() string { return "aaaabbbbcccc" })
	dec2.done()
	if dec2.reason != routePrefixNone || dec2.matched != 0 {
		t.Fatalf("tenant-b matched %d chunks of tenant-a's prompt sent to %s", dec2.matched, got[0].Name)
	}
}

// Memory is bounded per backend and by the backend count, and what is evicted is the oldest.
// Mutation that turns this red: remove the eviction in record, or the dropOldestBackend call.
func TestPrefixIndexIsBounded(t *testing.T) {
	x := newPrefixIndex(3, 2)
	x.record("a", []uint64{1, 2, 3})
	x.record("a", []uint64{4})
	if x.entries != 3 || x.matched("a", []uint64{1}) != 0 || x.matched("a", []uint64{2, 3}) != 2 {
		t.Fatalf("per-backend LRU wrong: entries %d", x.entries)
	}
	x.record("b", []uint64{9})
	x.record("a", []uint64{2}) // a is now more recent than b
	x.record("c", []uint64{7})
	if _, ok := x.backends["b"]; ok || len(x.backends) != 2 {
		t.Fatalf("the least recent backend was not dropped: %v", x.backends)
	}
	if x.entries != 4 {
		t.Fatalf("entries %d after dropping b, want 4", x.entries)
	}
}

// Round robin alternates, and the other backend stays behind it as fallback.
func TestRoundRobinAlternates(t *testing.T) {
	r := testRouter()
	var seen []string
	for range 4 {
		got, dec := r.route(twoRefs(platformv1.RoutingPolicyRoundRobin), platformv1.RoutingPolicyRoundRobin, "t", "m", nil)
		dec.done()
		if len(got) != 2 {
			t.Fatalf("the fallback was dropped: %d targets", len(got))
		}
		seen = append(seen, got[0].Name)
	}
	if strings.Join(seen, "") != "abab" {
		t.Fatalf("round robin went %v", seen)
	}
}

// Least queue goes where fewer are outstanding, and a finished request gives its place back.
// Mutation that turns this red: never call done, or count on the wrong backend.
func TestLeastQueueFollowsOutstanding(t *testing.T) {
	r := testRouter()
	_, d1 := r.route(twoRefs(platformv1.RoutingPolicyLeastQueue), platformv1.RoutingPolicyLeastQueue, "t", "m", nil)
	got, d2 := r.route(twoRefs(platformv1.RoutingPolicyLeastQueue), platformv1.RoutingPolicyLeastQueue, "t", "m", nil)
	if d1.backend.Name != "a" || got[0].Name != "b" {
		t.Fatalf("least queue chose %s then %s", d1.backend.Name, got[0].Name)
	}
	d1.done()
	d1.done() // a second call must not release twice
	got, d3 := r.route(twoRefs(platformv1.RoutingPolicyLeastQueue), platformv1.RoutingPolicyLeastQueue, "t", "m", nil)
	if got[0].Name != "a" || r.outstanding["ns/a"] != 1 || r.outstanding["ns/b"] != 1 {
		t.Fatalf("after a finished: chose %s, outstanding %v", got[0].Name, r.outstanding)
	}
	d2.done()
	d3.done()
}

// At low load every backend is usually idle, and ties going to the older one sent 67 to 69% of the rehearsal's requests
// there; they rotate now, under LeastQueue and for PrefixAffinity's unmatched prompts alike.
// Mutation that turns this red: take the earliest tied backend.
func TestTiesRotate(t *testing.T) {
	r := testRouter()
	var lq, pa []string
	for i := range 4 {
		_, d := r.route(twoRefs(platformv1.RoutingPolicyLeastQueue), platformv1.RoutingPolicyLeastQueue, "t", "m", nil)
		d.done()
		lq = append(lq, d.backend.Name)
		prompt := strings.Repeat(string(rune('a'+i)), 64)
		_, d = r.route(twoRefs(platformv1.RoutingPolicyPrefixAffinity), platformv1.RoutingPolicyPrefixAffinity, "t", "m2",
			func() string { return prompt })
		d.done()
		pa = append(pa, d.backend.Name)
	}
	if strings.Join(lq, "") != "abab" || strings.Join(pa, "") != "abab" {
		t.Fatalf("idle ties went %v under LeastQueue and %v for new prompts", lq, pa)
	}
}

// Prefix affinity sends a shared prefix back where it went, and the escape sends it elsewhere once that backend is
// busier than the match would save.
// Mutation that turns this red: drop the escape, or compare the gap with the wrong side.
func TestPrefixAffinityMatchesAndEscapes(t *testing.T) {
	r := testRouter()
	prompt := func() string { return strings.Repeat("s", 400) + "tail" }
	refs := func() []*BackendRef { return twoRefs(platformv1.RoutingPolicyPrefixAffinity) }
	_, first := r.route(refs(), platformv1.RoutingPolicyPrefixAffinity, "t", "m", prompt)
	if first.reason != routePrefixNone || first.backend.Name != "a" {
		t.Fatalf("a cold prompt went %s for %s", first.backend.Name, first.reason)
	}
	// 64 chunks of 4 characters is 256 characters, 64 estimated tokens, so any queue gap at all outweighs it at a
	// 512-token step budget: the first request is still outstanding on a, and b is empty.
	_, second := r.route(refs(), platformv1.RoutingPolicyPrefixAffinity, "t", "m", prompt)
	if second.reason != routePrefixEscape || second.backend.Name != "b" || second.matched != 64 {
		t.Fatalf("a busy match went %s for %s with %d matched", second.backend.Name, second.reason, second.matched)
	}
	first.done()
	second.done()
	// Both idle now, and both hold the prompt; the earlier backend wins the tie.
	_, third := r.route(refs(), platformv1.RoutingPolicyPrefixAffinity, "t", "m", prompt)
	if third.reason != routePrefixMatch || third.matched != 64 {
		t.Fatalf("an idle match went %s for %s with %d matched", third.backend.Name, third.reason, third.matched)
	}
	third.done()
}

// With a generous budget per step a matched backend keeps a request despite a queue, up to the bound.
func TestPrefixAffinityToleratesAGapUpToTheMatch(t *testing.T) {
	r := newRouter(RoutingConfig{ChunkChars: 4, CapacityChunks: 1000, MaxBackends: 8, MaxChunks: 512, StepBudgetTokens: 64})
	// 512 chunks of 4 characters, 512 estimated tokens: a gap of up to 8 requests is worth it at 64 tokens a step.
	prompt := func() string { return strings.Repeat("p", 2048) }
	refs := func() []*BackendRef { return twoRefs(platformv1.RoutingPolicyPrefixAffinity) }
	var held []routingDecision
	for i := range 9 {
		_, d := r.route(refs(), platformv1.RoutingPolicyPrefixAffinity, "t", "m", prompt)
		held = append(held, d)
		if d.backend.Name != "a" {
			t.Fatalf("request %d escaped at a gap of %d", i, i)
		}
	}
	_, d := r.route(refs(), platformv1.RoutingPolicyPrefixAffinity, "t", "m", prompt)
	if d.reason != routePrefixEscape {
		t.Fatalf("a gap of 9 kept the match: %s", d.reason)
	}
	for _, h := range append(held, d) {
		h.done()
	}
}

// A policy applies only when every candidate names it and none is HoldCap.
// Mutation that turns this red: decide on targets[0] alone, or drop the HoldCap check.
func TestRoutingPolicyNeedsEveryCandidate(t *testing.T) {
	pa := platformv1.RoutingPolicyPrefixAffinity
	if p := routingPolicyFor(twoRefs(pa)); p != pa {
		t.Fatalf("agreeing candidates gave %q", p)
	}
	mixed := []*BackendRef{routeRef("a", pa), routeRef("b", "")}
	if p := routingPolicyFor(mixed); p != "" {
		t.Fatalf("a candidate with no policy still gave %q", p)
	}
	other := []*BackendRef{routeRef("a", pa), routeRef("b", platformv1.RoutingPolicyRoundRobin)}
	if p := routingPolicyFor(other); p != "" {
		t.Fatalf("disagreeing candidates gave %q", p)
	}
	hc := twoRefs(pa)
	hc[1].Admission = AdmissionHoldCap
	if p := routingPolicyFor(hc); p != "" {
		t.Fatalf("a HoldCap candidate still gave %q", p)
	}
	if p := routingPolicyFor([]*BackendRef{routeRef("a", "Random")}); p != "" {
		t.Fatalf("an unknown policy gave %q", p)
	}
}

func TestRoutingPromptReadsRolesAndContent(t *testing.T) {
	got := routingPrompt([]byte(`{"messages":[{"role":"system","content":"sys"},{"role":"user","content":[{"type":"text","text":"x"}]}]}`))
	want := "system\x00sys\x00user\x00" + `[{"type":"text","text":"x"}]` + "\x00"
	if got != want {
		t.Fatalf("routingPrompt = %q, want %q", got, want)
	}
	if routingPrompt([]byte("not json")) != "" {
		t.Fatal("an undecodable body produced a prompt")
	}
}

func TestDecisionHeaders(t *testing.T) {
	h := http.Header{}
	routingDecision{policy: platformv1.RoutingPolicyPrefixAffinity, backend: routeRef("a", ""), reason: routePrefixMatch, matched: 3, total: 5}.setHeaders(h)
	if h.Get(HeaderRoutingBackend) != "ns/a" || h.Get(HeaderRoutingMatch) != "3/5" || h.Get(HeaderRoutingReason) != routePrefixMatch {
		t.Fatalf("headers %v", h)
	}
	h = http.Header{}
	routingDecision{policy: platformv1.RoutingPolicyRoundRobin, backend: routeRef("a", ""), reason: routeRoundRobin}.setHeaders(h)
	if h.Get(HeaderRoutingMatch) != "" {
		t.Fatal("a match header outside PrefixAffinity")
	}
}

// The routing study's runner and docs/05 read these series by their full names, so the names are pinned here as written.
// Mutation that turns this red: rename any of the four.
func TestRoutingMetricNames(t *testing.T) {
	r := testRouter()
	_, d := r.route(twoRefs(platformv1.RoutingPolicyPrefixAffinity), platformv1.RoutingPolicyPrefixAffinity, "t", "m",
		func() string { return strings.Repeat("n", 64) })
	d.done()
	families, err := metrics.Registry.Gather()
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for _, f := range families {
		seen[f.GetName()] = true
	}
	for _, name := range []string{"gpuaas_gateway_routing_decisions_total", "gpuaas_gateway_routing_outstanding_requests",
		"gpuaas_gateway_routing_prefix_index_entries", "gpuaas_gateway_routing_prefix_index_evictions_total"} {
		if !seen[name] {
			t.Errorf("%s is not registered", name)
		}
	}
}

func TestRoutingConfigRefusesZero(t *testing.T) {
	if err := DefaultRoutingConfig().Validate(); err != nil {
		t.Fatal(err)
	}
	c := DefaultRoutingConfig()
	c.CapacityChunks = 0
	if c.Validate() == nil {
		t.Fatal("a zero capacity was accepted")
	}
}
