package gateway

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// refuseAll refuses every request, so a spec can check what a refusal leaves behind.
type refuseAll struct{}

func (refuseAll) Admit(context.Context, RequestMeta, *BackendRef, string, string) (bool, string) {
	return false, "test_refusal"
}

var _ = Describe("routing through the whole pipeline", func() {
	type backend struct {
		srv  *httptest.Server
		hits atomic.Int64
	}
	start := func() *backend {
		b := &backend{}
		b.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			b.hits.Add(1)
			w.WriteHeader(http.StatusOK)
		}))
		return b
	}
	ref := func(b *backend, name, policy string) *BackendRef {
		u, err := url.Parse(b.srv.URL)
		Expect(err).NotTo(HaveOccurred())
		return &BackendRef{Namespace: testTenantNS, Name: name, URL: u, Model: testModel, Routing: policy}
	}
	body := func(prompt string) string {
		return `{"model":"` + testModel + `","messages":[{"role":"user","content":"` + prompt + `"}],"stream":true}`
	}
	var a, b *backend
	BeforeEach(func() {
		a, b = start(), start()
		DeferCleanup(a.srv.Close)
		DeferCleanup(b.srv.Close)
	})
	serverWith := func(policy string, admitter Admitter) *Server {
		s := newAdmissionServer("", tierPremium, AdmissionOff, admitter)
		Expect(s.SetRoutingConfig(RoutingConfig{ChunkChars: 8, CapacityChunks: 100, MaxBackends: 4, MaxChunks: 64,
			StepBudgetTokens: 512})).To(Succeed())
		s.refsOverride = func(string) []*BackendRef { return []*BackendRef{ref(a, "a", policy), ref(b, "b", policy)} }
		return s
	}

	// The default is the point of the change being safe: a deployment that names no policy routes as before.
	// Mutation that turns this red: apply a policy when the candidates name none.
	It("sends everything to the head and adds no header when no policy is named", func() {
		s := serverWith("", offAdmitter{})
		for range 4 {
			rr := httptest.NewRecorder()
			s.Handler().ServeHTTP(rr, authedRequest(body(strings.Repeat("x", 64))))
			Expect(rr.Code).To(Equal(http.StatusOK))
			Expect(rr.Header().Get(HeaderRoutingPolicy)).To(BeEmpty())
			Expect(rr.Header().Get(HeaderRoutingBackend)).To(BeEmpty())
		}
		Expect(a.hits.Load()).To(Equal(int64(4)))
		Expect(b.hits.Load()).To(BeZero())
	})

	It("alternates under RoundRobin and says where each request went", func() {
		s := serverWith(platformv1.RoutingPolicyRoundRobin, offAdmitter{})
		var went []string
		for range 4 {
			rr := httptest.NewRecorder()
			s.Handler().ServeHTTP(rr, authedRequest(body("hello")))
			Expect(rr.Code).To(Equal(http.StatusOK))
			Expect(rr.Header().Get(HeaderRoutingPolicy)).To(Equal(platformv1.RoutingPolicyRoundRobin))
			went = append(went, rr.Header().Get(HeaderRoutingBackend))
		}
		Expect(went).To(Equal([]string{testTenantNS + "/a", testTenantNS + "/b", testTenantNS + "/a", testTenantNS + "/b"}))
		Expect(a.hits.Load()).To(Equal(int64(2)))
		Expect(b.hits.Load()).To(Equal(int64(2)))
	})

	// The request's prompt reaches the index through the body the pipeline already buffered, and the backend the header
	// names is the one that served it.
	// Mutation that turns this red: hash something other than the request's messages, so every prompt matches or none does.
	It("sends two prompts sharing a prefix to the same backend under PrefixAffinity and a different prefix elsewhere", func() {
		s := serverWith(platformv1.RoutingPolicyPrefixAffinity, offAdmitter{})
		send := func(prompt string) (string, string) {
			rr := httptest.NewRecorder()
			s.Handler().ServeHTTP(rr, authedRequest(body(prompt)))
			Expect(rr.Code).To(Equal(http.StatusOK))
			return rr.Header().Get(HeaderRoutingBackend), rr.Header().Get(HeaderRoutingReason)
		}
		shared := strings.Repeat("s", 80)
		first, why := send(shared + "one")
		Expect(why).To(Equal(routePrefixNone))
		// The first request finished, so both backends are idle and the second goes where the prefix is.
		second, why := send(shared + "two")
		Expect(why).To(Equal(routePrefixMatch))
		Expect(second).To(Equal(first))
		Expect(a.hits.Load() + b.hits.Load()).To(Equal(int64(2)))
	})

	// A refused request must give its outstanding place back, or later requests would avoid a backend doing nothing.
	// Mutation that turns this red: release the count only after the proxy step.
	It("releases the outstanding count of a refused request", func() {
		s := serverWith(platformv1.RoutingPolicyLeastQueue, refuseAll{})
		for range 3 {
			rr := httptest.NewRecorder()
			s.Handler().ServeHTTP(rr, authedRequest(body("hello")))
			Expect(rr.Code).To(Equal(http.StatusTooManyRequests))
			Expect(rr.Header().Get(HeaderRoutingBackend)).NotTo(BeEmpty())
		}
		r := s.routerFor()
		Expect(r.outstanding[testTenantNS+"/a"]).To(BeZero())
		Expect(r.outstanding[testTenantNS+"/b"]).To(BeZero())
	})

	// A request that falls back is outstanding where it is served, or LeastQueue and the escape would read a dead
	// backend as busy and the live one as idle (codex review of the uncommitted change).
	// Mutation that turns this red: drop the onAttempt callback in chatCompletions.
	It("moves a fallen-back request's outstanding count to the backend serving it", func() {
		release := make(chan struct{})
		held := make(chan struct{})
		live := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			close(held)
			<-release
			w.WriteHeader(http.StatusOK)
		}))
		DeferCleanup(live.Close)
		dead := httptest.NewServer(http.NotFoundHandler())
		deadURL := dead.URL
		dead.Close()
		s := newAdmissionServer("", tierPremium, AdmissionOff, offAdmitter{})
		s.refsOverride = func(string) []*BackendRef {
			d, _ := url.Parse(deadURL)
			l, _ := url.Parse(live.URL)
			return []*BackendRef{
				{Namespace: testTenantNS, Name: "a", URL: d, Model: testModel, Routing: platformv1.RoutingPolicyLeastQueue},
				{Namespace: testTenantNS, Name: "b", URL: l, Model: testModel, Routing: platformv1.RoutingPolicyLeastQueue},
			}
		}
		done := make(chan int)
		go func() {
			rr := httptest.NewRecorder()
			s.Handler().ServeHTTP(rr, authedRequest(body("hello")))
			done <- rr.Code
		}()
		Eventually(held).Should(BeClosed())
		r := s.routerFor()
		r.mu.Lock()
		onA, onB := r.outstanding[testTenantNS+"/a"], r.outstanding[testTenantNS+"/b"]
		r.mu.Unlock()
		close(release)
		Expect(<-done).To(Equal(http.StatusOK))
		Expect([]int{onA, onB}).To(Equal([]int{0, 1}), "while b served the request")
		Expect(r.outstanding[testTenantNS+"/b"]).To(BeZero())
	})

	It("reads the policy from the InferenceDeployment's spec", func() {
		infd := &platformv1.InferenceDeployment{}
		Expect(specRouting(infd)).To(BeEmpty())
		infd.Spec.Routing = &platformv1.InferenceRouting{Policy: platformv1.RoutingPolicyLeastQueue}
		Expect(specRouting(infd)).To(Equal(platformv1.RoutingPolicyLeastQueue))
	})
})
