package gateway

import (
	"compress/gzip"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/prometheus/client_golang/prometheus"
	dto "github.com/prometheus/client_model/go"
)

// histogramAtMost reads how many of one child's observations were at most le seconds; le must be a bucket bound.
func histogramAtMost(h *prometheus.HistogramVec, le float64, labels ...string) uint64 {
	o, err := h.GetMetricWithLabelValues(labels...)
	if err != nil {
		return 0
	}
	m := &dto.Metric{}
	if err := o.(prometheus.Metric).Write(m); err != nil {
		return 0
	}
	for _, b := range m.GetHistogram().GetBucket() {
		if b.GetUpperBound() == le {
			return b.GetCumulativeCount()
		}
	}
	return 0
}

// histogramSum reads one child's sum of observations, in seconds.
func histogramSum(h *prometheus.HistogramVec, labels ...string) float64 {
	o, err := h.GetMetricWithLabelValues(labels...)
	if err != nil {
		return 0
	}
	m := &dto.Metric{}
	if err := o.(prometheus.Metric).Write(m); err != nil {
		return 0
	}
	return m.GetHistogram().GetSampleSum()
}

var _ = Describe("the serial-prefill admitter in the pipeline", func() {
	body := `{"model":"` + testModel + `","messages":[{"role":"user","content":"hello"}],"stream":true}`

	// The second standard request reaches the engine only once the first one's response has sent its first content,
	// the gateway's sign that its prefill is done; a frame without content does not count (v24 review, finding 3).
	// Mutation that turns this red: release on the first body byte, or on the status line.
	It("forwards the next standard request only after the previous one's first content", func() {
		var reached atomic.Int32
		release := make(chan struct{})
		var once sync.Once
		open := func() { once.Do(func() { close(release) }) }
		up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			n := reached.Add(1)
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			w.(http.Flusher).Flush()
			if n == 1 {
				// A frame with no content first, as an engine may send before the prompt is done: it must not release.
				_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"\"}}]}\n\n"))
				w.(http.Flusher).Flush()
				<-release
			}
			_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n"))
			w.(http.Flusher).Flush()
		}))
		defer up.Close()
		defer open()
		s := newSerialPrefillAdmitter(10e9)
		gw := httptest.NewServer(newAdmissionServer(up.URL, tierStandard, AdmissionSerialPrefill, s).Handler())
		defer gw.Close()

		send := func() *http.Response {
			req, _ := http.NewRequest(http.MethodPost, gw.URL+"/v1/chat/completions", strings.NewReader(body))
			req.Header.Set("Authorization", "Bearer "+testKey)
			resp, err := http.DefaultClient.Do(req)
			Expect(err).NotTo(HaveOccurred())
			return resp
		}
		first := send()
		defer func() { _ = first.Body.Close() }()
		Expect(first.StatusCode).To(Equal(http.StatusOK))

		waitBefore := histogramSum(admissionWait, testTenant, "admit")
		fastBefore := histogramAtMost(requestDuration, 0.25, testTenant, testModel)
		done := make(chan *http.Response, 1)
		go func() { done <- send() }()
		Consistently(func() int32 { return reached.Load() }, "200ms").Should(Equal(int32(1)),
			"the second standard request reached the engine while the first had sent only a frame without content")
		time.Sleep(100 * time.Millisecond)

		open()
		_, _ = io.ReadAll(first.Body)
		second := <-done
		defer func() { _ = second.Body.Close() }()
		Expect(second.StatusCode).To(Equal(http.StatusOK))
		Expect(reached.Load()).To(Equal(int32(2)))
		_, _ = io.ReadAll(second.Body)
		// Its hold, about 300 ms, is in the admission-wait metric and in the request's duration (review of 197bd12).
		// Mutation that turns this red: start the duration timer after the admission decision again.
		Eventually(func() float64 { return histogramSum(admissionWait, testTenant, "admit") - waitBefore }).Should(BeNumerically(">=", 0.25))
		// Both requests took at least 300 ms end to end, the first waiting for its body and the second held, so
		// neither may be filed at 0.25 s or less; the first request's own duration cannot stand in for the second's.
		Consistently(func() uint64 { return histogramAtMost(requestDuration, 0.25, testTenant, testModel) - fastBefore }, "100ms").Should(BeZero())
	})

	// A client that asks for gzip itself, to an upstream that compresses when asked: the first content is still seen,
	// so the next contender goes while the first stream is open (review of 64188a2).
	// Mutation that turns this red: stop removing the client's Accept-Encoding before forwarding.
	It("releases on the first content of a compressed response", func() {
		var reached atomic.Int32
		finish := make(chan struct{})
		var once sync.Once
		end := func() { once.Do(func() { close(finish) }) }
		up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			n := reached.Add(1)
			w.Header().Set("Content-Type", "text/event-stream")
			var out io.Writer = w
			var gz *gzip.Writer
			if strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
				w.Header().Set("Content-Encoding", "gzip")
				gz = gzip.NewWriter(w)
				out = gz
			}
			w.WriteHeader(http.StatusOK)
			_, _ = out.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n"))
			if gz != nil {
				_ = gz.Flush()
			}
			w.(http.Flusher).Flush()
			if n == 1 {
				<-finish
			}
			if gz != nil {
				_ = gz.Close()
			}
		}))
		defer up.Close()
		defer end()
		s := newSerialPrefillAdmitter(10e9)
		gw := httptest.NewServer(newAdmissionServer(up.URL, tierStandard, AdmissionSerialPrefill, s).Handler())
		defer gw.Close()
		send := func() *http.Response {
			req, _ := http.NewRequest(http.MethodPost, gw.URL+"/v1/chat/completions", strings.NewReader(body))
			req.Header.Set("Authorization", "Bearer "+testKey)
			req.Header.Set("Accept-Encoding", "gzip")
			resp, err := http.DefaultClient.Do(req)
			Expect(err).NotTo(HaveOccurred())
			return resp
		}
		first := send()
		defer func() { _ = first.Body.Close() }()
		done := make(chan *http.Response, 1)
		go func() { done <- send() }()
		Eventually(func() int32 { return reached.Load() }, "2s").Should(Equal(int32(2)),
			"the second contender waited for the first's whole response: its compressed content was never seen")
		end()
		second := <-done
		_ = second.Body.Close()
	})
})
