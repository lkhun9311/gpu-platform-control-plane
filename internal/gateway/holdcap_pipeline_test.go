package gateway

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

var _ = Describe("HoldCap backends in the pipeline", func() {
	body := `{"model":"` + testModel + `","messages":[{"role":"user","content":"hello"}],"stream":true}`

	holdCapRef := func(raw string) *BackendRef {
		u, err := url.Parse(raw)
		Expect(err).NotTo(HaveOccurred())
		return &BackendRef{Namespace: testTenantNS, Name: "capped", URL: u, Model: testModel, Admission: AdmissionHoldCap, MaxHold: 10 * time.Second}
	}
	plainRef := func(raw string) *BackendRef {
		u, err := url.Parse(raw)
		Expect(err).NotTo(HaveOccurred())
		return &BackendRef{Namespace: testTenantNS, Name: "plain", URL: u, Model: testModel}
	}
	send := func(gw *httptest.Server) *http.Response {
		req, _ := http.NewRequest(http.MethodPost, gw.URL+"/v1/chat/completions", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+testKey)
		resp, err := http.DefaultClient.Do(req)
		Expect(err).NotTo(HaveOccurred())
		return resp
	}
	// gated serves a stream whose first request sends no content until release is closed.
	gated := func(reached *atomic.Int32, release chan struct{}) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			n := reached.Add(1)
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			w.(http.Flusher).Flush()
			if n == 1 {
				<-release
			}
			_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n"))
			w.(http.Flusher).Flush()
		}))
	}
	// counting answers 200 and counts the requests that reached it.
	counting := func(n *atomic.Int32) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			n.Add(1)
			w.WriteHeader(http.StatusOK)
		}))
	}
	// deadURL is an address that refuses connections, so a request sent there fails and may fall back.
	deadURL := func() string {
		dead := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
		u := dead.URL
		dead.Close()
		return u
	}

	// The process-wide mode is off, and the backend still serializes: the mode belongs to the backend.
	// Mutation that must turn this red: ignore targets[0].Admission when choosing the admitter.
	It("holds the next standard request on a HoldCap backend while the gateway runs no admission", func() {
		var reached atomic.Int32
		release := make(chan struct{})
		var once sync.Once
		open := func() { once.Do(func() { close(release) }) }
		up := gated(&reached, release)
		defer up.Close()
		defer open()
		s := newAdmissionServer("", tierStandard, AdmissionOff, offAdmitter{})
		s.refsOverride = func(string) []*BackendRef { return []*BackendRef{holdCapRef(up.URL)} }
		gw := httptest.NewServer(s.Handler())
		defer gw.Close()

		first := send(gw)
		defer func() { _ = first.Body.Close() }()
		done := make(chan *http.Response, 1)
		go func() { done <- send(gw) }()
		Consistently(func() int32 { return reached.Load() }, "200ms").Should(Equal(int32(1)))
		open()
		_, _ = io.ReadAll(first.Body)
		second := <-done
		_ = second.Body.Close()
		Expect(reached.Load()).To(Equal(int32(2)))
	})

	It("does not hold a backend that asks for nothing", func() {
		var reached atomic.Int32
		release := make(chan struct{})
		var once sync.Once
		open := func() { once.Do(func() { close(release) }) }
		up := gated(&reached, release)
		defer up.Close()
		defer open()
		s := newAdmissionServer("", tierStandard, AdmissionOff, offAdmitter{})
		s.refsOverride = func(string) []*BackendRef { return []*BackendRef{plainRef(up.URL)} }
		gw := httptest.NewServer(s.Handler())
		defer gw.Close()
		first := send(gw)
		defer func() { _ = first.Body.Close() }()
		go func() {
			r := send(gw)
			_ = r.Body.Close()
		}()
		Eventually(func() int32 { return reached.Load() }, "2s").Should(Equal(int32(2)))
	})

	// Replacement, not stacking: a process-wide static cap that refuses this request has no say over a HoldCap backend.
	// Mutation that must turn this red: run the global admitter before the HoldCap one.
	It("admits through HoldCap a request the process-wide mode would refuse", func() {
		up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) }))
		defer up.Close()
		longStream := strings.TrimSuffix(eligibleLongBody, "}") + `,"stream":true}`
		s := newAdmissionServer("", tierStandard, AdmissionStaticCap, newStaticCapAdmitter(0, 1, 4096))
		s.refsOverride = func(string) []*BackendRef { return []*BackendRef{holdCapRef(up.URL)} }
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(longStream))
		Expect(rr.Code).To(Equal(http.StatusOK))
		Expect(rr.Header().Get(HeaderAdmissionReason)).To(Equal(reasonSerialPrefillFree))
	})

	// Mutation that must turn this red: remove the holdCapTargets call.
	It("never falls back from a HoldCap backend, premium included", func() {
		for _, tier := range []string{tierPremium, tierStandard} {
			var spare atomic.Int32
			live := counting(&spare)
			s := newAdmissionServer("", tier, AdmissionOff, offAdmitter{})
			dead := deadURL()
			s.refsOverride = func(string) []*BackendRef { return []*BackendRef{holdCapRef(dead), plainRef(live.URL)} }
			rr := httptest.NewRecorder()
			s.Handler().ServeHTTP(rr, authedRequest(body))
			live.Close()
			Expect(rr.Code).To(BeNumerically(">=", 500), "tier "+tier)
			Expect(spare.Load()).To(BeZero(), "a "+tier+" request on a HoldCap backend was carried to another backend")
		}
	})

	// Review Focus 2, as amended by C3: the HoldCap backend is dropped from the tail, and the plain backend after it still serves.
	// Mutation that must turn this red: cut the list at the HoldCap backend, or remove the holdCapTargets call.
	It("falls back past a HoldCap backend to the plain one after it, and never into it", func() {
		for _, tier := range []string{tierPremium, tierStandard} {
			var capped, after atomic.Int32
			cappedUp, afterUp := counting(&capped), counting(&after)
			s := newAdmissionServer("", tier, AdmissionOff, offAdmitter{})
			dead := deadURL()
			s.refsOverride = func(string) []*BackendRef {
				c := plainRef(afterUp.URL)
				c.Name = "after"
				return []*BackendRef{plainRef(dead), holdCapRef(cappedUp.URL), c}
			}
			rr := httptest.NewRecorder()
			s.Handler().ServeHTTP(rr, authedRequest(body))
			cappedUp.Close()
			afterUp.Close()
			Expect(capped.Load()).To(BeZero(), "a "+tier+" fallback reached a HoldCap backend without its hold")
			Expect(after.Load()).To(Equal(int32(1)), "a "+tier+" request did not reach the plain backend past the HoldCap one")
			Expect(rr.Code).To(Equal(http.StatusOK))
		}
	})

	// Its engine is rendered with priority scheduling, so the tier must reach it whatever -bind-priority says.
	// Mutation that must turn this red: bind only when s.bindPriority.
	It("binds priority by tier on a HoldCap backend with -bind-priority off", func() {
		for tier, want := range map[string]float64{tierPremium: 0, tierStandard: 1} {
			var got atomic.Value
			up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var m map[string]any
				_ = json.NewDecoder(r.Body).Decode(&m)
				got.Store(m["priority"])
				w.WriteHeader(http.StatusOK)
			}))
			s := newAdmissionServer("", tier, AdmissionOff, offAdmitter{})
			s.refsOverride = func(string) []*BackendRef { return []*BackendRef{holdCapRef(up.URL)} }
			rr := httptest.NewRecorder()
			s.Handler().ServeHTTP(rr, authedRequest(body))
			up.Close()
			Expect(rr.Code).To(Equal(http.StatusOK))
			Expect(got.Load()).To(Equal(want), "tier "+tier)
		}
	})

	// The rule releases a prefill on the first content event, so a request that does not stream, or streams several choices, would hold or release the turn at the wrong time.
	// Mutations that must turn this red: remove the stream refusal; remove the n > 1 refusal.
	DescribeTable("refuses a standard request whose shape the hold cannot time",
		func(extra, reason string) {
			var reached atomic.Int32
			up := counting(&reached)
			defer up.Close()
			s := newAdmissionServer("", tierStandard, AdmissionOff, offAdmitter{})
			s.refsOverride = func(string) []*BackendRef { return []*BackendRef{holdCapRef(up.URL)} }
			before := requestsFor(testTenant, testModel, http.StatusBadRequest)
			rr := httptest.NewRecorder()
			s.Handler().ServeHTTP(rr, authedRequest(`{"model":"`+testModel+`","messages":[{"role":"user","content":"hello"}]`+extra+`}`))
			Expect(rr.Code).To(Equal(http.StatusBadRequest))
			Expect(rr.Header().Get(HeaderAdmissionReason)).To(Equal(reason))
			expectJSONError(rr, reason)
			Expect(rr.Header().Get("Retry-After")).To(BeEmpty(), "the same request is refused again, so no retry hint")
			Expect(requestsFor(testTenant, testModel, http.StatusBadRequest)).To(Equal(before + 1))
			Expect(reached.Load()).To(BeZero())
		},
		Entry("no stream field", ``, reasonHoldCapRequiresStream),
		Entry("stream false", `,"stream":false`, reasonHoldCapRequiresStream),
		Entry("two choices", `,"stream":true,"n":2`, reasonHoldCapSingleChoice),
		Entry("an n it cannot read", `,"stream":true,"n":"2"`, reasonHoldCapSingleChoice),
	)

	It("serves those shapes to a premium tenant, which a HoldCap backend does not hold", func() {
		for _, extra := range []string{``, `,"stream":true,"n":2`} {
			var reached atomic.Int32
			up := counting(&reached)
			s := newAdmissionServer("", tierPremium, AdmissionOff, offAdmitter{})
			s.refsOverride = func(string) []*BackendRef { return []*BackendRef{holdCapRef(up.URL)} }
			rr := httptest.NewRecorder()
			s.Handler().ServeHTTP(rr, authedRequest(`{"model":"`+testModel+`","messages":[{"role":"user","content":"hello"}]`+extra+`}`))
			up.Close()
			Expect(rr.Code).To(Equal(http.StatusOK), "body suffix "+extra)
			Expect(reached.Load()).To(Equal(int32(1)))
		}
	})

	It("serves those shapes on a backend that asks for nothing", func() {
		var reached atomic.Int32
		up := counting(&reached)
		defer up.Close()
		s := newAdmissionServer("", tierStandard, AdmissionOff, offAdmitter{})
		s.refsOverride = func(string) []*BackendRef { return []*BackendRef{plainRef(up.URL)} }
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(`{"model":"`+testModel+`","messages":[{"role":"user","content":"hello"}],"n":2}`))
		Expect(rr.Code).To(Equal(http.StatusOK))
		Expect(reached.Load()).To(Equal(int32(1)))
	})

	// No override: the mode comes from the object's status through backendsFor, as it does in production.
	// The refusal is decided before any upstream is dialled, so the unroutable in-cluster address never matters.
	It("reads HoldCap from the InferenceDeployment's status on the production resolution path", func() {
		s := newAdmissionServer("", tierStandard, AdmissionOff, offAdmitter{})
		ctx := context.Background()
		var d platformv1.InferenceDeployment
		Expect(s.Client.Get(ctx, client.ObjectKey{Namespace: testTenantNS, Name: "llama"}, &d)).To(Succeed())
		d.Generation = 2
		d.Spec.Admission = &platformv1.InferenceAdmission{Mode: platformv1.AdmissionModeHoldCap, MaxHold: &metav1.Duration{Duration: 5 * time.Second}}
		d.Status.Admission = &platformv1.InferenceAdmissionStatus{Mode: platformv1.AdmissionModeHoldCap, ObservedGeneration: 2}
		Expect(s.Client.Update(ctx, &d)).To(Succeed())
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(`{"model":"`+testModel+`","messages":[{"role":"user","content":"hello"}]}`))
		Expect(rr.Code).To(Equal(http.StatusBadRequest))
		Expect(rr.Header().Get(HeaderAdmissionReason)).To(Equal(reasonHoldCapRequiresStream))
	})
})
