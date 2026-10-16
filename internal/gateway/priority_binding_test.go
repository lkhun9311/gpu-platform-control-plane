package gateway

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync/atomic"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

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

	It("reads a rendered engine from the InferenceDeployment's spec", func() {
		rendered := &platformv1.InferenceDeployment{Spec: platformv1.InferenceDeploymentSpec{
			Engine: &platformv1.InferenceEngine{VLLM: &platformv1.VLLMEngine{Profile: platformv1.VLLMProfileV0271A10G}},
		}}
		Expect(enginePriorityScheduled(rendered)).To(BeTrue())
		Expect(enginePriorityScheduled(&platformv1.InferenceDeployment{})).To(BeFalse())
		Expect(allPriorityScheduled(nil)).To(BeFalse(), "no backend is not every backend scheduling by priority")
	})
})
