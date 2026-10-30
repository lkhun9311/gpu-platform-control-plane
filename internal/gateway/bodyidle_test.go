package gateway

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

// ResponseHeaderTimeout stops counting once headers arrive, and a streaming engine sends them before any token.
// An upstream that then goes silent without closing held the request, its goroutine, and on serial prefill or HoldCap
// the backend's one prefill turn, for as long as the client stayed connected (codex review, 2026-10-30, finding 4).
var _ = Describe("an upstream that stalls after its headers", func() {
	// Mutation that turns this red: never arm the idle watch, or arm it without cancelling the attempt.
	It("ends the request after the idle bound and gives the prefill turn back", func() {
		release := make(chan struct{})
		up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			w.(http.Flusher).Flush()
			select {
			case <-release:
			case <-r.Context().Done():
			}
		}))
		DeferCleanup(up.Close)
		DeferCleanup(func() { close(release) })

		admitter := newSerialPrefillAdmitter(5 * time.Second)
		s := newAdmissionServer(up.URL, tierStandard, AdmissionSerialPrefill, admitter)
		s.bodyIdleTimeout = 100 * time.Millisecond
		body := `{"model":"` + testModel + `","messages":[{"role":"user","content":"hi"}],"stream":true}`

		done := make(chan struct{})
		go func() {
			defer GinkgoRecover()
			defer close(done)
			s.Handler().ServeHTTP(httptest.NewRecorder(), authedRequest(body))
		}()
		Eventually(done, 2*time.Second).Should(BeClosed(), "the stalled request was still held")
		u, err := url.Parse(up.URL)
		Expect(err).NotTo(HaveOccurred())
		busy, waiting := admitter.state(&BackendRef{URL: u})
		Expect(busy).To(BeFalse(), "the stalled request kept the backend's prefill turn")
		Expect(waiting).To(BeZero())
	})

	// The bound is on silence, not on length: a stream still sending is never cut.
	// Mutation that turns this red: time the bound from the headers instead of from the last write.
	It("leaves a stream that keeps sending alone however long it runs", func() {
		up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			for range 8 {
				_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n"))
				w.(http.Flusher).Flush()
				time.Sleep(40 * time.Millisecond)
			}
			_, _ = w.Write([]byte("data: [DONE]\n\n"))
		}))
		DeferCleanup(up.Close)
		s := newAdmissionServer(up.URL, tierStandard, AdmissionOff, offAdmitter{})
		s.bodyIdleTimeout = 100 * time.Millisecond
		body := `{"model":"` + testModel + `","messages":[{"role":"user","content":"hi"}],"stream":true}`
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(body))
		Expect(rr.Body.String()).To(HaveSuffix("data: [DONE]\n\n"), "a stream that never paused for the bound was cut")
	})
})
