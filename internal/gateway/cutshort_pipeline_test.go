package gateway

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/prometheus/client_golang/prometheus/testutil"
)

// Every spec here runs the handler behind a real httptest.Server, because ReverseProxy suppresses its abort panic when
// there is no server in the request's context, and the earlier tests that drove the handler directly never saw a
// stream cut short at all (issue #571).
var _ = Describe("a response cut short", func() {
	const frame = "data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n"
	body := `{"model":"` + testModel + `","messages":[{"role":"user","content":"hi"}],"stream":true}`

	// serve puts the gateway with a request record in front of upstream and returns its URL and the record's path.
	serve := func(upstream http.HandlerFunc, configure func(*Server)) (string, string) {
		up := httptest.NewServer(upstream)
		DeferCleanup(up.Close)
		path := filepath.Join(GinkgoT().TempDir(), "record.jsonl")
		rec, err := OpenRequestRecorder(path)
		Expect(err).NotTo(HaveOccurred())
		s := newAdmissionServer(up.URL, tierStandard, AdmissionOff, nil)
		s.recorder = rec
		if configure != nil {
			configure(s)
		}
		gw := httptest.NewServer(s.Handler())
		DeferCleanup(func() { gw.Close(); _ = rec.Close() })
		return gw.URL, path
	}
	send := func(ctx context.Context, url string) (*http.Response, error) {
		req, _ := http.NewRequestWithContext(ctx, http.MethodPost, url+"/v1/chat/completions", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+testKey)
		return http.DefaultClient.Do(req)
	}
	// doneLine waits for the request's done line, which is written as the handler unwinds.
	doneLine := func(path string) map[string]any {
		var done map[string]any
		Eventually(func() bool {
			for _, l := range readRecord(path) {
				if l["ev"] == "done" {
					done = l
					return true
				}
			}
			return false
		}).Should(BeTrue(), "no done line was written")
		return done
	}
	cut := func(cause string) float64 {
		return testutil.ToFloat64(responsesCutShort.WithLabelValues(testTenant, testModel, cause))
	}
	ok := func() float64 { return testutil.ToFloat64(requests.WithLabelValues(testTenant, testModel, "200")) }

	// The control: a stream that ends by itself is recorded as before, with no cause and nothing counted as cut.
	It("leaves a complete stream as it was", func() {
		url, path := serve(func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "text/event-stream")
			_, _ = w.Write([]byte(frame + "data: [DONE]\n\n"))
		}, nil)
		before := cut(cutShortUpstream)
		resp, err := send(context.Background(), url)
		Expect(err).NotTo(HaveOccurred())
		_, readErr := io.ReadAll(resp.Body)
		Expect(readErr).NotTo(HaveOccurred(), "a complete stream must read to its end")
		Expect(doneLine(path)).NotTo(HaveKey("cutShort"))
		Expect(cut(cutShortUpstream)).To(Equal(before))
	})

	// Mutations that turn this red: let the abort panic unwind uncaught, or swallow it without raising it again.
	It("records and counts an upstream that dies mid-stream, and still aborts the client", func() {
		url, path := serve(func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "text/event-stream")
			_, _ = w.Write([]byte(frame))
			w.(http.Flusher).Flush()
			panic(http.ErrAbortHandler)
		}, nil)
		cutBefore, okBefore := cut(cutShortUpstream), ok()
		resp, err := send(context.Background(), url)
		Expect(err).NotTo(HaveOccurred())
		_, readErr := io.ReadAll(resp.Body)
		Expect(readErr).To(MatchError(io.ErrUnexpectedEOF), "the client must see the stream break, not a clean end")
		done := doneLine(path)
		Expect(done["cutShort"]).To(Equal(cutShortUpstream))
		Expect(done["status"]).To(BeNumerically("==", 200))
		Expect(cut(cutShortUpstream) - cutBefore).To(BeNumerically("==", 1))
		Expect(ok()-okBefore).To(BeNumerically("==", 1), "the request must be in requests_total under the status it had")
	})

	// Mutation that turns this red: classify every cut as the upstream's.
	It("names a client that leaves mid-stream", func() {
		url, path := serve(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/event-stream")
			_, _ = w.Write([]byte(frame))
			w.(http.Flusher).Flush()
			for r.Context().Err() == nil {
				_, _ = w.Write([]byte(frame))
				w.(http.Flusher).Flush()
				time.Sleep(20 * time.Millisecond)
			}
		}, nil)
		ctx, cancel := context.WithCancel(context.Background())
		resp, err := send(ctx, url)
		Expect(err).NotTo(HaveOccurred())
		buf := make([]byte, len(frame))
		_, err = io.ReadFull(resp.Body, buf)
		Expect(err).NotTo(HaveOccurred())
		cancel()
		_ = resp.Body.Close()
		Expect(doneLine(path)["cutShort"]).To(Equal(cutShortClient))
	})

	// Mutation that turns this red: never set the idle flag when the bound fires.
	// The order of the idle and client checks is not what this pins: the idle bound cancels only the attempt, so here the
	// client's context is still live and either order names the idle bound.
	It("names the gateway's own idle bound when it is what ended the stream", func() {
		url, path := serve(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/event-stream")
			_, _ = w.Write([]byte(frame))
			w.(http.Flusher).Flush()
			<-r.Context().Done()
		}, func(s *Server) { s.bodyIdleTimeout = 200 * time.Millisecond })
		resp, err := send(context.Background(), url)
		Expect(err).NotTo(HaveOccurred())
		_, readErr := io.ReadAll(resp.Body)
		Expect(readErr).To(HaveOccurred(), "an idle cut must not read as a clean end")
		Expect(doneLine(path)["cutShort"]).To(Equal(cutShortIdle))
	})
})
