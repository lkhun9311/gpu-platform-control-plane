package gateway

import (
	"bufio"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("contentWatcher", func() {
	// Mutation that turns this red: drop the closing-quote check, so the role frame's empty content counts.
	It("does not count the role frame's empty content", func() {
		var c contentWatcher
		Expect(c.observe([]byte(`data: {"choices":[{"delta":{"role":"assistant","content":""}}]}` + "\n\n"))).To(BeFalse())
		Expect(c.observe([]byte(`data: {"choices":[{"delta":{"content":"Hi"}}]}` + "\n\n"))).To(BeTrue())
		Expect(c.observe([]byte(`data: {"choices":[{"delta":{"content":"again"}}]}`+"\n\n"))).To(BeFalse(), "only the first one")
	})

	// Mutation that turns this red: stop carrying the tail between calls.
	It("finds a marker split across chunks, at every split point", func() {
		frame := `data: {"choices":[{"delta":{"content":"x"}}]}` + "\n\n"
		for i := 1; i < len(frame); i++ {
			var c contentWatcher
			first := c.observe([]byte(frame[:i]))
			second := c.observe([]byte(frame[i:]))
			Expect(first || second).To(BeTrue(), "split at %d", i)
			Expect(first && second).To(BeFalse(), "split at %d", i)
		}
	})

	// Mutation that turns this red: match the compact form "content":" only (commit review of d463287).
	It("finds content written with JSON whitespace around the colon, across every split", func() {
		frame := `data: {"choices": [{"delta": {"content" :  "x"}}]}` + "\n\n"
		for i := 1; i < len(frame); i++ {
			var c contentWatcher
			first := c.observe([]byte(frame[:i]))
			second := c.observe([]byte(frame[i:]))
			Expect(first || second).To(BeTrue(), "split at %d", i)
		}
		var c contentWatcher
		Expect(c.observe([]byte(`{"delta": {"role": "assistant", "content": ""}}`))).To(BeFalse())
		Expect(c.observe([]byte(`{"delta": {"content": null}}`))).To(BeFalse())
	})

	It("does not count an empty content split exactly after the marker", func() {
		var c contentWatcher
		Expect(c.observe([]byte(`{"delta":{"content":"`))).To(BeFalse())
		Expect(c.observe([]byte(`"}}`))).To(BeFalse())
	})
})

func readRecord(path string) []map[string]any {
	f, err := os.Open(path)
	Expect(err).NotTo(HaveOccurred())
	defer func() { _ = f.Close() }()
	var out []map[string]any
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var m map[string]any
		Expect(json.Unmarshal(sc.Bytes(), &m)).To(Succeed())
		out = append(out, m)
	}
	return out
}

var _ = Describe("the request record in the pipeline", func() {
	body := `{"model":"` + testModel + `","messages":[{"role":"user","content":"hello"}]}`

	var path string
	BeforeEach(func() {
		path = filepath.Join(GinkgoT().TempDir(), "record.jsonl")
	})

	// Mutation that turns this red: remove tr.arrived(), tr.handedOff() or the onBody hook from the handler.
	It("stamps arrival, decision, forward, release and first content for a served stream, in order", func() {
		up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`data: {"choices":[{"delta":{"role":"assistant","content":""}}]}` + "\n\n"))
			w.(http.Flusher).Flush()
			_, _ = w.Write([]byte(`data: {"choices":[{"delta":{"content":"Hi"}}]}` + "\n\n"))
			w.(http.Flusher).Flush()
		}))
		defer up.Close()
		p := newProspectiveAdmitter(100000, 4)
		s := newAdmissionServer(up.URL, tierStandard, AdmissionProspective, p)
		rec, err := OpenRequestRecorder(path)
		Expect(err).NotTo(HaveOccurred())
		s.RecordRequests(rec)
		s.BindPriority(true)
		gw := httptest.NewServer(s.Handler())
		defer gw.Close()

		req, _ := http.NewRequest(http.MethodPost, gw.URL+"/v1/chat/completions", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+testKey)
		req.Header.Set("X-Request-Id", "pilot-a-1-P-7")
		resp, err := http.DefaultClient.Do(req)
		Expect(err).NotTo(HaveOccurred())
		_, _ = io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		gw.Close()
		Expect(rec.Close()).To(Succeed())

		lines := readRecord(path)
		Expect(lines).To(HaveLen(2))
		Expect(lines[0]["ev"]).To(Equal("arrive"))
		Expect(lines[0]["requestId"]).To(Equal("pilot-a-1-P-7"))
		d := lines[1]
		Expect(d["ev"]).To(Equal("done"))
		Expect(d["requestId"]).To(Equal("pilot-a-1-P-7"))
		Expect(d["decision"]).To(Equal("admit"))
		Expect(d["tier"]).To(Equal(tierStandard))
		Expect(d["priority"]).To(BeEquivalentTo(1))
		Expect(d["status"]).To(BeEquivalentTo(200))
		order := []string{"enteredUnixNanos", "arrivedUnixNanos", "recordedUnixNanos", "decidedUnixNanos",
			"handoffUnixNanos", "releasedUnixNanos", "firstContentUnixNanos", "endedUnixNanos"}
		prev := 0.0
		for _, k := range order {
			v, ok := d[k].(float64)
			Expect(ok).To(BeTrue(), "%s missing", k)
			Expect(v).To(BeNumerically(">=", prev), "%s precedes the stage before it", k)
			prev = v
		}
		Expect(d["arrivedUnixNanos"]).To(Equal(lines[0]["arrivedUnixNanos"]))
		// The release is at the role frame, the first content at the next frame: the two must be distinguishable.
		Expect(d["firstContentUnixNanos"].(float64)).To(BeNumerically(">=", d["releasedUnixNanos"].(float64)))
	})

	record := func(s *Server) func() []map[string]any {
		rec, err := OpenRequestRecorder(path)
		Expect(err).NotTo(HaveOccurred())
		s.RecordRequests(rec)
		return func() []map[string]any {
			Expect(rec.Close()).To(Succeed())
			return readRecord(path)
		}
	}

	// Mutation that turns this red: go back to `defer res.Done()` without the trace's cleanup wrapper.
	It("stamps a release made at cleanup when no body byte released the prefill, and says so", func() {
		up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusNoContent)
		}))
		defer up.Close()
		s := newAdmissionServer(up.URL, tierStandard, AdmissionProspective, newProspectiveAdmitter(100000, 4))
		read := record(s)
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(body))
		d := read()[1]
		Expect(d["releasedUnixNanos"]).NotTo(BeNil())
		Expect(d["releasedAtEnd"]).To(BeTrue())
	})

	// Mutation that turns this red: drop the nil-reservation guard in tr.release or tr.releaseAtEnd.
	It("stamps no release in an arm whose admitter holds no reservation", func() {
		up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "text/event-stream")
			_, _ = w.Write([]byte(`data: {"choices":[{"delta":{"content":"Hi"}}]}` + "\n\n"))
		}))
		defer up.Close()
		s := newAdmissionServer(up.URL, tierStandard, AdmissionOff, offAdmitter{})
		read := record(s)
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(body))
		d := read()[1]
		Expect(d).NotTo(HaveKey("releasedUnixNanos"))
		Expect(d).To(HaveKey("firstContentUnixNanos"))
	})

	// Mutation that turns this red: stamp first content in body() rather than in flushed().
	It("stamps first content when it is flushed, not when it is written to the buffer", func() {
		rec, err := OpenRequestRecorder(path)
		Expect(err).NotTo(HaveOccurred())
		s := &Server{recorder: rec}
		tr, _ := s.startTrace(httptest.NewRecorder())
		tr.identify("delayed-flush-1")
		tr.body([]byte(`data: {"choices":[{"delta":{"content":"Hi"}}]}` + "\n\n"))
		written := time.Now()
		time.Sleep(50 * time.Millisecond)
		tr.flushed()
		tr.finish()
		Expect(rec.Close()).To(Succeed())
		d := readRecord(path)[0]
		Expect(int64(d["firstContentUnixNanos"].(float64))).To(BeNumerically(">=", written.Add(50*time.Millisecond).UnixNano()))
		Expect(d).NotTo(HaveKey("firstContentAtEnd"))
	})

	It("stamps first content at the handler's end, and says so, when it was never flushed", func() {
		rec, err := OpenRequestRecorder(path)
		Expect(err).NotTo(HaveOccurred())
		s := &Server{recorder: rec}
		tr, _ := s.startTrace(httptest.NewRecorder())
		tr.identify("never-flushed-1")
		tr.body([]byte(`{"delta":{"content":"Hi"}}`))
		tr.finish()
		Expect(rec.Close()).To(Succeed())
		d := readRecord(path)[0]
		Expect(d["firstContentAtEnd"]).To(BeTrue())
		Expect(d["firstContentUnixNanos"]).To(Equal(d["endedUnixNanos"]))
	})

	// Mutation that turns this red: drop the tr.final override in finish.
	It("records the status the proxy stage resolved, not the writer's default", func() {
		rec, err := OpenRequestRecorder(path)
		Expect(err).NotTo(HaveOccurred())
		s := &Server{recorder: rec}
		tr, _ := s.startTrace(httptest.NewRecorder())
		tr.identify("unanswered-1")
		tr.outcome(http.StatusBadGateway, false)
		tr.finish()
		Expect(rec.Close()).To(Succeed())
		d := readRecord(path)[0]
		Expect(d["status"]).To(BeEquivalentTo(502))
		Expect(d["answered"]).To(BeFalse())
	})

	// Mutation that turns this red: move startTrace after the authentication step.
	It("records a refusal before the body is read, with no arrival", func() {
		s := newAdmissionServer("http://127.0.0.1:1", tierStandard, AdmissionOff, nil)
		rec, err := OpenRequestRecorder(path)
		Expect(err).NotTo(HaveOccurred())
		s.RecordRequests(rec)
		req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
		req.Header.Set("X-Request-Id", "pilot-unauth-1")
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, req)
		Expect(rr.Code).To(Equal(http.StatusUnauthorized))
		Expect(rec.Close()).To(Succeed())

		lines := readRecord(path)
		Expect(lines).To(HaveLen(1))
		Expect(lines[0]["ev"]).To(Equal("done"))
		Expect(lines[0]["status"]).To(BeEquivalentTo(401))
		Expect(lines[0]).NotTo(HaveKey("arrivedUnixNanos"))
		Expect(lines[0]["priority"]).To(BeEquivalentTo(-1))
	})

	// Mutation that turns this red: ignore the error from tr.arrived().
	It("refuses a request whose arrival cannot be recorded", func() {
		s := newAdmissionServer("http://127.0.0.1:1", tierStandard, AdmissionOff, nil)
		rec, err := OpenRequestRecorder(path)
		Expect(err).NotTo(HaveOccurred())
		Expect(rec.f.Close()).To(Succeed())
		s.RecordRequests(rec)
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(body))
		Expect(rr.Code).To(Equal(http.StatusServiceUnavailable))
	})

	It("records nothing and changes nothing when no recorder is set", func() {
		s := newAdmissionServer("http://127.0.0.1:1", tierStandard, AdmissionOff, nil)
		tr, w := s.startTrace(httptest.NewRecorder())
		Expect(tr).To(BeNil())
		_, isCode := w.(*codeWriter)
		Expect(isCode).To(BeFalse())
	})
})
