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
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"sync"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"sigs.k8s.io/controller-runtime/pkg/metrics"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// The headers a routed response carries, so a replay's rows record where each request went and why.
// They are set only when a routing policy is in force, so a gateway with none answers exactly as before.
const (
	HeaderRoutingPolicy  = "X-Routing-Policy"
	HeaderRoutingBackend = "X-Routing-Backend"
	HeaderRoutingReason  = "X-Routing-Reason"
	// HeaderRoutingMatch is "<matched>/<total>" whole chunks under PrefixAffinity, absent otherwise.
	HeaderRoutingMatch = "X-Routing-Match"
	// HeaderRoutingLoad is "<outstanding on the chosen backend>/<outstanding on the least loaded>" as the decision saw
	// them, before this request was counted. The load escape's one-step-per-request assumption is unmeasured, and these
	// two numbers beside each request's matched chunks are what a study needs to test it afterwards.
	HeaderRoutingLoad = "X-Routing-Load"
)

// The reasons a routing decision records, one per way a backend can be chosen.
const (
	routeRoundRobin = "round_robin"
	routeLeastQueue = "least_queue"
	// routePrefixMatch sent the request to the backend holding its longest indexed prefix.
	routePrefixMatch = "prefix_match"
	// routePrefixNone found no backend holding any of its prefix, so least-queue chose.
	routePrefixNone = "prefix_none"
	// routePrefixEscape found a match on a backend busier than the match would save, so least-queue chose.
	routePrefixEscape = "prefix_escape"
)

// RoutingConfig is the prefix index's sizing; the defaults are what the routing study registered.
type RoutingConfig struct {
	// ChunkChars is the length of one hashed chunk: llm-d's 64-token block at the gateway's four characters a token.
	ChunkChars int
	// CapacityChunks is one backend's index size: the engine's measured KV capacity of 393,232 tokens, times 5.198
	// characters a token measured on the benchmark corpus, over ChunkChars (design page "Gateway configuration").
	CapacityChunks int
	// MaxBackends bounds how many backends the index remembers, and with CapacityChunks its memory.
	MaxBackends int
	// MaxChunks bounds the chunks hashed per request: llm-d's maxPrefixBlocksToMatch default of 2,048.
	MaxChunks int
	// StepBudgetTokens is the engine's per-step token budget, --max-num-batched-tokens=512 in the rendered profile,
	// which the load escape divides a match by.
	StepBudgetTokens int
}

// DefaultRoutingConfig is the configuration docs/superpowers/specs/2026-10-27-prefix-aware-routing-design.md
// registers. Changing a value here changes the treatment that study measures.
func DefaultRoutingConfig() RoutingConfig {
	return RoutingConfig{ChunkChars: 256, CapacityChunks: 7985, MaxBackends: 8, MaxChunks: 2048, StepBudgetTokens: 512}
}

// Validate refuses a configuration under which a policy would silently do nothing.
func (c RoutingConfig) Validate() error {
	if c.ChunkChars <= 0 || c.CapacityChunks <= 0 || c.MaxBackends <= 0 || c.MaxChunks <= 0 || c.StepBudgetTokens <= 0 {
		return fmt.Errorf("every routing size must be positive, got %+v", c)
	}
	return nil
}

// router keeps the state every policy needs: the round-robin positions, the requests outstanding per backend, and
// the prefix index. One lock covers all of it, so a decision and the count it is based on cannot interleave with
// another request's; at the rates this gateway serves that lock is not the bottleneck.
//
// It lives in one process. A second gateway replica would keep its own counts and index, which is why the routing
// study runs one, as config/gateway/deployment.yaml does anyway.
type router struct {
	cfg         RoutingConfig
	mu          sync.Mutex
	next        map[string]uint64
	outstanding map[string]int
	index       *prefixIndex
}

func newRouter(cfg RoutingConfig) *router {
	return &router{cfg: cfg, next: map[string]uint64{}, outstanding: map[string]int{},
		index: newPrefixIndex(cfg.CapacityChunks, cfg.MaxBackends)}
}

// routingDecision is what the router chose, and what the response and the metrics report about it.
type routingDecision struct {
	policy  string
	backend *BackendRef
	reason  string
	// matched and total are whole chunks, reported under PrefixAffinity only.
	matched, total int
	// load and least are the outstanding counts on the chosen and the least loaded backend before this request.
	load, least int
	// done releases the request's place in the outstanding count of the backend serving it.
	done func()
	// move transfers that place to a fallback the request has moved to.
	move func(*BackendRef)
}

// routeKey names a backend in the router's maps: its InferenceDeployment, or its URL when a test gave it none.
// admission.go's backendKey would name every unnamed test backend "/", and two of them would then share one count.
func routeKey(b *BackendRef) string {
	if b.Namespace != "" || b.Name != "" {
		return b.Namespace + "/" + b.Name
	}
	if b.URL != nil {
		return b.URL.String()
	}
	return ""
}

// routingPolicyFor is the policy every candidate agrees on, or "" for the gateway's ordering.
//
// Every candidate, not the head: the policy is a property of the model's set of backends, and a deployment that does
// not ask for it, a rollout half applied for instance, keeps the ordering everyone already relied on. A HoldCap
// candidate keeps it too, because HoldCap's hold is decided per engine and its backend must never be entered by a
// choice other than being the head.
func routingPolicyFor(targets []*BackendRef) string {
	if len(targets) == 0 {
		return ""
	}
	p := targets[0].Routing
	for _, t := range targets {
		if t.Routing == "" || t.Routing != p || t.Admission == AdmissionHoldCap {
			return ""
		}
	}
	switch p {
	case platformv1.RoutingPolicyRoundRobin, platformv1.RoutingPolicyLeastQueue, platformv1.RoutingPolicyPrefixAffinity:
		return p
	}
	// An unknown value is what the CRD's enum refuses; a gateway newer than its CRD keeps the ordering rather than
	// guessing what was meant.
	return ""
}

// route chooses the backend a request goes to first and reorders targets so it is the head, the others keeping their
// order as fallback. It also counts the request as outstanding on that backend until done is called.
//
// prompt is read only under PrefixAffinity, so the other policies never decode the body a second time.
func (r *router) route(targets []*BackendRef, policy, tenant, model string, prompt func() string) ([]*BackendRef, routingDecision) {
	dec := routingDecision{policy: policy}
	var chain []uint64
	if policy == platformv1.RoutingPolicyPrefixAffinity {
		// Hashed before the lock: it is the only per-request cost that grows with the prompt.
		chain = prefixChain(tenant, model, prompt(), r.cfg.ChunkChars, r.cfg.MaxChunks)
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	pick := 0
	switch policy {
	case platformv1.RoutingPolicyRoundRobin:
		key := targets[0].Namespace + "/" + model
		pick = int(r.next[key] % uint64(len(targets)))
		r.next[key]++
		dec.reason = routeRoundRobin
	case platformv1.RoutingPolicyLeastQueue:
		pick = r.leastLoaded(targets, model)
		dec.reason = routeLeastQueue
	case platformv1.RoutingPolicyPrefixAffinity:
		pick, dec.reason, dec.matched = r.prefixPick(targets, model, chain)
		dec.total = len(chain)
		// Recorded at decision time, as llm-d's producer does: the gateway assumes the chosen engine now holds the
		// prefix, before it has computed anything. A request that then fails leaves a belief the engine does not
		// share, which costs one later miss.
		r.index.record(routeKey(targets[pick]), chain)
		routingIndexEntries.Set(float64(r.index.entries))
		routingIndexEvictions.Add(float64(r.index.evictions))
		r.index.evictions = 0
	}
	chosen := targets[pick]
	key := routeKey(chosen)
	dec.load, dec.least = r.outstanding[key], r.minOutstanding(targets)
	r.addOutstanding(chosen, 1)
	// The request is outstanding on whichever backend is serving it: the chosen one, or a fallback it moved to.
	// Both closures take the lock, and released keeps a move that races the end from counting a finished request.
	serving, released := chosen, false
	var once sync.Once
	dec.done = func() {
		once.Do(func() {
			r.mu.Lock()
			defer r.mu.Unlock()
			released = true
			r.addOutstanding(serving, -1)
		})
	}
	dec.move = func(to *BackendRef) {
		r.mu.Lock()
		defer r.mu.Unlock()
		if released || routeKey(to) == routeKey(serving) {
			return
		}
		r.addOutstanding(serving, -1)
		serving = to
		r.addOutstanding(serving, 1)
	}
	dec.backend = chosen
	routingDecisions.WithLabelValues(policy, chosen.Namespace, chosen.Name, dec.reason).Inc()
	ordered := make([]*BackendRef, 0, len(targets))
	ordered = append(ordered, chosen)
	for i, t := range targets {
		if i != pick {
			ordered = append(ordered, t)
		}
	}
	return ordered, dec
}

// addOutstanding moves backend's outstanding count by n and publishes it; the caller holds the lock.
func (r *router) addOutstanding(b *BackendRef, n int) {
	key := routeKey(b)
	r.outstanding[key] += n
	routingOutstanding.WithLabelValues(b.Namespace, b.Name).Set(float64(r.outstanding[key]))
}

// minOutstanding is the fewest requests outstanding on any of the targets.
func (r *router) minOutstanding(targets []*BackendRef) int {
	least := r.outstanding[routeKey(targets[0])]
	for _, t := range targets[1:] {
		least = min(least, r.outstanding[routeKey(t)])
	}
	return least
}

// leastLoaded is the index of a backend with the fewest outstanding requests, ties taken in turn.
//
// Ties rotate rather than going to the earliest, and the kind rehearsal is why: at 0.8 requests a second most
// decisions see every backend idle, so "the earliest on a tie" sent 67% of LeastQueue's requests and, through every
// unmatched prompt, 69% of PrefixAffinity's to the older engine (design page, "Rehearsal on kind"). Under
// PrefixAffinity that bias also decided where each new prompt lived, so it concentrated the prompts, not only the
// requests. The rotation is kept per model, as round robin's is; the caller holds the lock.
func (r *router) leastLoaded(targets []*BackendRef, model string) int {
	least := r.minOutstanding(targets)
	var tied []int
	for i, t := range targets {
		if r.outstanding[routeKey(t)] == least {
			tied = append(tied, i)
		}
	}
	key := "tie/" + targets[0].Namespace + "/" + model
	pick := tied[r.next[key]%uint64(len(tied))]
	r.next[key]++
	return pick
}

// prefixPick chooses by longest indexed prefix, with the load escape.
//
// The escape: a match on backend A saves the engine the prefill of the matched tokens, about matched/budget steps.
// Each request already outstanding on A costs this one at most about one step, because a hit request's own prefill
// fits in one. So A is worth its queue only while outstanding(A) − outstanding(least loaded) ≤ matched tokens /
// budget, and past that the request goes to the least loaded backend. The tokens are the matched characters over
// four, the gateway's own estimate, which reads prose about 30% high, so the escape engages a little late. That one
// step per queued request is an assumption, and the registered study's queue and hot-backend endpoints are what
// would show it wrong.
func (r *router) prefixPick(targets []*BackendRef, model string, chain []uint64) (int, string, int) {
	best, bestN := 0, -1
	for i, t := range targets {
		n := r.index.matched(routeKey(t), chain)
		switch {
		case n > bestN:
			best, bestN = i, n
		case n == bestN && r.outstanding[routeKey(t)] < r.outstanding[routeKey(targets[best])]:
			best = i
		}
	}
	if bestN <= 0 {
		return r.leastLoaded(targets, model), routePrefixNone, 0
	}
	matchedTokens := bestN * r.cfg.ChunkChars / 4
	gap := r.outstanding[routeKey(targets[best])] - r.minOutstanding(targets)
	if gap*r.cfg.StepBudgetTokens > matchedTokens {
		return r.leastLoaded(targets, model), routePrefixEscape, bestN
	}
	return best, routePrefixMatch, bestN
}

// setHeaders reports the decision on the response.
func (d routingDecision) setHeaders(h interface{ Set(string, string) }) {
	h.Set(HeaderRoutingPolicy, d.policy)
	h.Set(HeaderRoutingBackend, routeKey(d.backend))
	h.Set(HeaderRoutingReason, d.reason)
	h.Set(HeaderRoutingLoad, strconv.Itoa(d.load)+"/"+strconv.Itoa(d.least))
	if d.policy == platformv1.RoutingPolicyPrefixAffinity {
		h.Set(HeaderRoutingMatch, strconv.Itoa(d.matched)+"/"+strconv.Itoa(d.total))
	}
}

// routingPrompt is the text a prompt's prefix is read from: each message's role and content in order, a string
// content as its text and any other content as its raw JSON, so two requests share a prefix exactly when their
// messages agree from the start.
//
// The role is included because the engine's chat template puts it in the prompt, so two messages with one text
// under different roles are different prefixes to the engine as well.
// A body that does not decode yields "", which matches nothing; readRequestMeta has already refused such a body.
//
// Keys are read exactly, as readRequestMeta reads them and the engine does: a struct would also take "Messages",
// "Role" or "Content", so a decoy under a case variant after the real field chose the backend by a prompt the engine
// never saw.
func routingPrompt(body []byte) string {
	var top map[string]json.RawMessage
	if json.Unmarshal(body, &top) != nil {
		return ""
	}
	var messages []chatMessage
	if raw, ok := top["messages"]; ok && json.Unmarshal(raw, &messages) != nil {
		return ""
	}
	var b strings.Builder
	for _, m := range messages {
		var role string
		if raw, ok := m["role"]; ok && json.Unmarshal(raw, &role) != nil {
			return ""
		}
		b.WriteString(role)
		b.WriteByte(0)
		content := m["content"]
		var text string
		if json.Unmarshal(content, &text) == nil {
			b.WriteString(text)
		} else {
			b.Write(content)
		}
		b.WriteByte(0)
	}
	return b.String()
}

var (
	// routingDecisions counts every routed request by the backend chosen and why. The labels are bounded: policy and
	// reason are fixed vocabularies, and namespace and name are configured InferenceDeployments.
	routingDecisions = promauto.With(metrics.Registry).NewCounterVec(prometheus.CounterOpts{
		Name: metricPrefix + "routing_decisions_total",
		Help: "Requests routed under a routing policy, by policy, chosen backend and reason.",
	}, []string{"policy", "namespace", "name", "reason"})
	// routingOutstanding is the count the LeastQueue and PrefixAffinity policies decide on.
	routingOutstanding = promauto.With(metrics.Registry).NewGaugeVec(prometheus.GaugeOpts{
		Name: metricPrefix + "routing_outstanding_requests",
		Help: "Requests this gateway has routed to a backend under a routing policy and not yet finished.",
	}, []string{"namespace", "name"})
	routingIndexEntries = promauto.With(metrics.Registry).NewGauge(prometheus.GaugeOpts{
		Name: metricPrefix + "routing_prefix_index_entries",
		Help: "Chunk hashes the prefix index holds across all backends.",
	})
	routingIndexEvictions = promauto.With(metrics.Registry).NewCounter(prometheus.CounterOpts{
		Name: metricPrefix + "routing_prefix_index_evictions_total",
		Help: "Chunk hashes the prefix index evicted to stay within its bounds.",
	})
)
