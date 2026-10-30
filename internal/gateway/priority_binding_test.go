package gateway

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync/atomic"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// The controller renders every engine it renders with priority scheduling, so a request that can only reach such
// engines must carry its tier in any mode; without it every request arrives at one priority and the policy does
// nothing. The hold-cap product study measured the cost on EKS: the product's Off, which bound nothing, left the
// premium tail at 6 to 10 s.
var _ = Describe("priority binding on rendered engines", func() {
	body := `{"model":"` + testModel + `","messages":[{"role":"user","content":"hello"}],"stream":true}`

	ref := func(raw, name string, rendered bool) *BackendRef {
		u, err := url.Parse(raw)
		Expect(err).NotTo(HaveOccurred())
		return &BackendRef{Namespace: testTenantNS, Name: name, URL: u, Model: testModel, PriorityScheduled: rendered}
	}
	// recording answers 200 and keeps the priority field of the body it received, or nil when there was none.
	recording := func(got *atomic.Value) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var m map[string]any
			_ = json.NewDecoder(r.Body).Decode(&m)
			got.Store([]any{m["priority"]})
			w.WriteHeader(http.StatusOK)
		}))
	}
	serve := func(tier string, refs func(up string) []*BackendRef) (*httptest.ResponseRecorder, any) {
		var got atomic.Value
		up := recording(&got)
		defer up.Close()
		s := newAdmissionServer("", tier, AdmissionOff, offAdmitter{})
		s.refsOverride = func(string) []*BackendRef { return refs(up.URL) }
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(body))
		Expect(rr.Code).To(Equal(http.StatusOK))
		seen, _ := got.Load().([]any)
		Expect(seen).To(HaveLen(1), "the backend was not reached")
		return rr, seen[0]
	}

	// Mutation that must turn this red: drop allPriorityScheduled from bindsPriority.
	It("binds the tier on an Off backend whose engine the controller renders, with -bind-priority off", func() {
		for tier, want := range map[string]float64{tierPremium: 0, tierStandard: 1} {
			rr, got := serve(tier, func(up string) []*BackendRef { return []*BackendRef{ref(up, "rendered", true)} })
			Expect(got).To(Equal(want), "tier "+tier)
			Expect(rr.Header().Get(HeaderEnginePriority)).NotTo(BeEmpty(), "tier "+tier)
		}
	})

	// The behaviour before this change, kept for engines the controller does not render.
	It("leaves a backend the controller does not render unbound", func() {
		rr, got := serve(tierStandard, func(up string) []*BackendRef { return []*BackendRef{ref(up, "plain", false)} })
		Expect(got).To(BeNil())
		Expect(rr.Header().Get(HeaderEnginePriority)).To(BeEmpty())
	})

	// A request may fall back, so one backend that may not schedule by priority keeps the whole request unbound.
	// Mutation that must turn this red: decide on targets[0] alone.
	It("does not bind when a reachable fallback is not a rendered engine", func() {
		rr, got := serve(tierStandard, func(up string) []*BackendRef {
			return []*BackendRef{ref(up, "rendered", true), ref(up, "plain", false)}
		})
		Expect(got).To(BeNil())
		Expect(rr.Header().Get(HeaderEnginePriority)).To(BeEmpty())
	})

	// Unbound must not mean caller-chosen: the rendered head schedules by whatever priority arrives, so a standard
	// tenant's -100 would run ahead of premium's 0.
	// Mutation that must turn this red: skip the strip when the request is not bound.
	It("removes a caller's priority from a request it does not bind", func() {
		var got atomic.Value
		up := recording(&got)
		defer up.Close()
		s := newAdmissionServer("", tierStandard, AdmissionOff, offAdmitter{})
		s.refsOverride = func(string) []*BackendRef {
			return []*BackendRef{ref(up.URL, "rendered", true), ref(up.URL, "plain", false)}
		}
		hostile := `{"model":"` + testModel + `","messages":[{"role":"user","content":"hello"}],"stream":true,"priority":-100}`
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(hostile))
		Expect(rr.Code).To(Equal(http.StatusOK))
		seen, _ := got.Load().([]any)
		Expect(seen).To(Equal([]any{nil}))
		Expect(rr.Header().Get(HeaderEnginePriority)).To(BeEmpty())
	})

	// A reservation pins a request to the head backend, so a fallback it can no longer reach must not keep it unbound.
	// Mutation that must turn this red: judge bindsPriority on targets rather than forwardTargets(res, targets).
	It("binds when a reservation leaves only the rendered head reachable", func() {
		var got atomic.Value
		up := recording(&got)
		defer up.Close()
		s := newAdmissionServer("", tierStandard, AdmissionSerialPrefill, newSerialPrefillAdmitter(10*time.Second))
		s.refsOverride = func(string) []*BackendRef {
			return []*BackendRef{ref(up.URL, "rendered", true), ref(up.URL, "plain", false)}
		}
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(body))
		Expect(rr.Code).To(Equal(http.StatusOK))
		seen, _ := got.Load().([]any)
		Expect(seen).To(Equal([]any{float64(1)}))
	})

	// The spec says what is wanted; only the controller's condition, for the current generation, says the rendered
	// engine is the one serving. Mutation that must turn this red: return true for any spec.engine.
	It("reads a rendered engine from the controller's condition, not from the spec alone", func() {
		infd := func(cond *metav1.Condition) *platformv1.InferenceDeployment {
			d := &platformv1.InferenceDeployment{Spec: platformv1.InferenceDeploymentSpec{
				Engine: &platformv1.InferenceEngine{VLLM: &platformv1.VLLMEngine{Profile: platformv1.VLLMProfileV0271A10G}},
			}}
			d.Generation = 4
			if cond != nil {
				d.Status.Conditions = []metav1.Condition{*cond}
			}
			return d
		}
		inForce := func(status metav1.ConditionStatus, gen int64) *metav1.Condition {
			return &metav1.Condition{Type: platformv1.ConditionEngineInForce, Status: status, ObservedGeneration: gen}
		}
		Expect(enginePriorityScheduled(infd(inForce(metav1.ConditionTrue, 4)))).To(BeTrue())
		Expect(enginePriorityScheduled(infd(nil))).To(BeFalse(), "spec.engine with no word from the controller")
		Expect(enginePriorityScheduled(infd(inForce(metav1.ConditionFalse, 4)))).To(BeFalse(), "rollout in progress")
		Expect(enginePriorityScheduled(infd(inForce(metav1.ConditionTrue, 3)))).To(BeFalse(), "a condition from an older generation")
		Expect(enginePriorityScheduled(&platformv1.InferenceDeployment{})).To(BeFalse())
		Expect(allPriorityScheduled(nil)).To(BeFalse(), "no backend is not every backend scheduling by priority")
	})
})
