package gateway

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"sync"
	"time"
)

// RequestRecorder writes the gateway's own account of every request it handled, one JSON line per event.
//
// The measurement pilot reads dispatch lag and the gateway's internal delays from these lines, because every
// client-side stamp has a later point at which a delay can hide (docs/superpowers/specs/
// 2026-10-08-measuring-prospective-admission-design.md, "Dispatch fidelity").
// A request that reaches the handler gets a "done" line on every way out, so the join to the client's rows
// can be checked for completeness.
// A request whose body was read also gets an "arrive" line, synced to disk before admission, so a request the
// gateway admitted always has a record even if the process dies before it finishes.
type RequestRecorder struct {
	mu sync.Mutex
	f  *os.File
}

// OpenRequestRecorder opens path for appending, creating it if absent.
func OpenRequestRecorder(path string) (*RequestRecorder, error) {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
	if err != nil {
		return nil, fmt.Errorf("open request record %s: %w", path, err)
	}
	return &RequestRecorder{f: f}, nil
}

// Close flushes and closes the file.
func (r *RequestRecorder) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.f.Sync(); err != nil {
		_ = r.f.Close()
		return err
	}
	return r.f.Close()
}

// arriveLine is written once the body has been read, before admission.
type arriveLine struct {
	Ev        string `json:"ev"`
	RequestID string `json:"requestId"`
	Tenant    string `json:"tenant"`
	// ArrivedUnixNanos is when the gateway finished reading the body: after every client-side delay, header and
	// body alike, which is why dispatch lag is measured from here and not from a client stamp.
	ArrivedUnixNanos int64 `json:"arrivedUnixNanos"`
}

// requestTimes collects one request's stamps as the handler passes them; zero means the stage was not reached.
type requestTimes struct {
	entered      time.Time
	arrived      time.Time
	recorded     time.Time
	decided      time.Time
	forwarded    time.Time
	released     time.Time
	firstContent time.Time
	ended        time.Time
}

// doneLine is written when the handler returns, on every path.
type doneLine struct {
	Ev        string `json:"ev"`
	RequestID string `json:"requestId"`
	Tenant    string `json:"tenant,omitempty"`
	Tier      string `json:"tier,omitempty"`
	// Decision is "admit", "reject", or empty when the request was refused before admission was consulted.
	Decision string `json:"decision,omitempty"`
	Reason   string `json:"reason,omitempty"`
	Status   int    `json:"status"`
	// Priority is the engine priority the gateway wrote, or -1 when it wrote none.
	Priority int `json:"priority"`

	EnteredUnixNanos int64 `json:"enteredUnixNanos"`
	ArrivedUnixNanos int64 `json:"arrivedUnixNanos,omitempty"`
	// RecordedUnixNanos is when the arrive line had been synced, so the cost of the durable write is measured,
	// not assumed: an unbounded delay there would sit after the arrival stamp (review round 21, finding 1).
	RecordedUnixNanos     int64 `json:"recordedUnixNanos,omitempty"`
	DecidedUnixNanos      int64 `json:"decidedUnixNanos,omitempty"`
	ForwardedUnixNanos    int64 `json:"forwardedUnixNanos,omitempty"`
	ReleasedUnixNanos     int64 `json:"releasedUnixNanos,omitempty"`
	FirstContentUnixNanos int64 `json:"firstContentUnixNanos,omitempty"`
	EndedUnixNanos        int64 `json:"endedUnixNanos"`
}

// nanos keeps an unreached stage at zero rather than at the zero Time's large negative Unix value.
func nanos(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.UnixNano()
}

// arrive writes and syncs the arrive line, returning when it is on disk.
func (r *RequestRecorder) arrive(rid, tenant string, at time.Time) error {
	b, err := json.Marshal(arriveLine{Ev: "arrive", RequestID: rid, Tenant: tenant, ArrivedUnixNanos: at.UnixNano()})
	if err != nil {
		return err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, err := r.f.Write(append(b, '\n')); err != nil {
		return err
	}
	return r.f.Sync()
}

// done writes the done line without syncing: the arrive line is what must survive a crash, and the done line's
// stamps are only meaningful for a request that finished anyway.
func (r *RequestRecorder) done(l doneLine) error {
	b, err := json.Marshal(l)
	if err != nil {
		return err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	_, err = r.f.Write(append(b, '\n'))
	return err
}

// requestTrace carries one request's stamps through the handler; a nil trace records nothing, so the handler
// calls it unconditionally and a gateway started without a record path pays only the nil checks.
type requestTrace struct {
	rec      *RequestRecorder
	t        requestTimes
	line     doneLine
	content  contentWatcher
	status   *codeWriter
	released bool
}

// startTrace begins a trace at handler entry and returns the writer the handler must use from then on.
func (s *Server) startTrace(w http.ResponseWriter) (*requestTrace, http.ResponseWriter) {
	if s.recorder == nil {
		return nil, w
	}
	cw := &codeWriter{ResponseWriter: w, code: http.StatusOK}
	return &requestTrace{rec: s.recorder, t: requestTimes{entered: time.Now()}, line: doneLine{Priority: -1}, status: cw}, cw
}

func (tr *requestTrace) identify(rid string) {
	if tr != nil {
		tr.line.RequestID = rid
	}
}

func (tr *requestTrace) tenant(t string) {
	if tr != nil {
		tr.line.Tenant = t
	}
}

// arrived stamps the end of the body read and syncs the arrive line before returning.
func (tr *requestTrace) arrived() error {
	if tr == nil {
		return nil
	}
	tr.t.arrived = time.Now()
	if err := tr.rec.arrive(tr.line.RequestID, tr.line.Tenant, tr.t.arrived); err != nil {
		return err
	}
	tr.t.recorded = time.Now()
	return nil
}

func (tr *requestTrace) decided(tier, decision, reason string) {
	if tr != nil {
		tr.t.decided = time.Now()
		tr.line.Tier, tr.line.Decision, tr.line.Reason = tier, decision, reason
	}
}

func (tr *requestTrace) priority(p int) {
	if tr != nil {
		tr.line.Priority = p
	}
}

func (tr *requestTrace) forwarded() {
	if tr != nil {
		tr.t.forwarded = time.Now()
	}
}

// release wraps the admitter's prefill release so the instant it ran is recorded beside it.
func (tr *requestTrace) release(done func()) func() {
	if tr == nil {
		return done
	}
	return func() {
		if !tr.released {
			tr.released = true
			tr.t.released = time.Now()
		}
		done()
	}
}

// body watches the bytes forwarded to the client for the first non-empty content delta.
func (tr *requestTrace) body(b []byte) {
	if tr != nil && tr.content.observe(b) {
		tr.t.firstContent = time.Now()
	}
}

// finish writes the done line; it runs on every way out of the handler.
func (tr *requestTrace) finish() {
	if tr == nil {
		return
	}
	tr.t.ended = time.Now()
	l := tr.line
	l.Ev = "done"
	l.Status = tr.status.code
	l.EnteredUnixNanos = nanos(tr.t.entered)
	l.ArrivedUnixNanos = nanos(tr.t.arrived)
	l.RecordedUnixNanos = nanos(tr.t.recorded)
	l.DecidedUnixNanos = nanos(tr.t.decided)
	l.ForwardedUnixNanos = nanos(tr.t.forwarded)
	l.ReleasedUnixNanos = nanos(tr.t.released)
	l.FirstContentUnixNanos = nanos(tr.t.firstContent)
	l.EndedUnixNanos = nanos(tr.t.ended)
	// A failed write cannot be answered to a client that has already been served; the analysis finds the
	// missing line by its join and treats the arm as ineligible, which is the outcome a lost line must have.
	_ = tr.rec.done(l)
}

// codeWriter records the status the handler wrote, for the done line.
//
// It forwards Flush and Unwrap, because the proxy stream depends on reaching the underlying Flusher.
type codeWriter struct {
	http.ResponseWriter
	code int
}

func (c *codeWriter) WriteHeader(code int) {
	c.code = code
	c.ResponseWriter.WriteHeader(code)
}

func (c *codeWriter) Flush() {
	if f, ok := c.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (c *codeWriter) Unwrap() http.ResponseWriter { return c.ResponseWriter }

// contentMarker is the start of a non-empty chat-completion content delta; the role frame's empty content
// ("content":"") does not match, because the byte after the marker must not be the closing quote.
var contentMarker = []byte(`"content":"`)

// contentWatcher finds the first non-empty content delta in a streamed response, across chunk boundaries.
type contentWatcher struct {
	tail []byte
	seen bool
}

// observe reports whether b completes the first non-empty content delta of the stream.
func (c *contentWatcher) observe(b []byte) bool {
	if c.seen {
		return false
	}
	buf := append(c.tail, b...)
	for i := 0; ; {
		j := bytes.Index(buf[i:], contentMarker)
		if j < 0 {
			break
		}
		k := i + j + len(contentMarker)
		if k >= len(buf) {
			// The marker ends the chunk, so the next byte decides; keep the marker for the next call.
			c.tail = append([]byte(nil), buf[i+j:]...)
			return false
		}
		if buf[k] != '"' {
			c.seen = true
			c.tail = nil
			return true
		}
		i = k
	}
	// Keep only what could be the start of a marker split across chunks.
	keep := len(contentMarker) - 1
	if len(buf) < keep {
		keep = len(buf)
	}
	c.tail = append([]byte(nil), buf[len(buf)-keep:]...)
	return false
}
