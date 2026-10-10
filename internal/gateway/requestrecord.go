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
	deciding     time.Time
	handoff      time.Time
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
	RecordedUnixNanos int64 `json:"recordedUnixNanos,omitempty"`
	DecidedUnixNanos  int64 `json:"decidedUnixNanos,omitempty"`
	// DecidingUnixNanos is when the admission decision began, so decided minus deciding is the request's own hold
	// in a holding admitter, refused or admitted; the histogram of holds cannot give one request's (v25 review,
	// finding 5).
	DecidingUnixNanos int64 `json:"decidingUnixNanos,omitempty"`
	// HandoffUnixNanos is when the request was handed to the reverse proxy. Connection acquisition, dialling and
	// sending the request to the backend all come after it, so the segment from here to first content holds
	// gateway transport time as well as the engine's (review of the pilot scope, round 10, finding 4).
	HandoffUnixNanos int64 `json:"handoffUnixNanos,omitempty"`
	// ReleasedUnixNanos is when the admitter's prefill reservation was released. ReleasedAtEnd says the release
	// came from the request's cleanup rather than from the first body byte: a request that never sent a body
	// still gives its reservation back, and the record must not read as if it had kept it.
	ReleasedUnixNanos int64 `json:"releasedUnixNanos,omitempty"`
	ReleasedAtEnd     bool  `json:"releasedAtEnd,omitempty"`
	// Answered says whether anything reached the client from a backend; Status is then the status the gateway
	// counted, which for an unanswered request is the last failure rather than the writer's default 200.
	Answered              bool  `json:"answered"`
	FirstContentUnixNanos int64 `json:"firstContentUnixNanos,omitempty"`
	// FirstContentAtEnd says the first content was never flushed before the handler returned, so its stamp is
	// the handler's end, the latest instant it can have reached the client by.
	FirstContentAtEnd bool  `json:"firstContentAtEnd,omitempty"`
	EndedUnixNanos    int64 `json:"endedUnixNanos"`
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
	// final is the status the proxy stage resolved, or 0 when the request never reached it.
	final    int
	answered bool
	// contentPending is set when the first content has been written but not yet flushed.
	contentPending bool
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

// deciding stamps the start of the admission decision, which is where a holding admitter's wait begins.
func (tr *requestTrace) deciding(at time.Time) {
	if tr != nil {
		tr.t.deciding = at
	}
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

func (tr *requestTrace) handedOff() {
	if tr != nil {
		tr.t.handoff = time.Now()
	}
}

// release wraps the admitter's prefill release so the instant it ran is recorded beside it.
func (tr *requestTrace) release(res *reservation) func() {
	// A reservation that releases nothing, the fixed-spacing admitter's, only pins the backend; stamping it would
	// record a release that never happened (review of 918b69e).
	if tr == nil || res == nil || res.releasePrefill == nil {
		// No reservation is held in the arms whose admitter does not reserve, so there is nothing to stamp.
		return res.PrefillDone
	}
	done := res.PrefillDone
	return func() {
		if !tr.released {
			tr.released = true
			tr.t.released = time.Now()
		}
		done()
	}
}

// releaseAtEnd wraps the request's final cleanup: if the prefill was not already released at the first body
// byte, this is where it is released, and the record says so.
func (tr *requestTrace) releaseAtEnd(res *reservation) func() {
	if tr == nil || res == nil || res.releasePrefill == nil && res.releaseStream == nil {
		return res.Done
	}
	done := res.Done
	return func() {
		if !tr.released {
			tr.released = true
			tr.t.released = time.Now()
			tr.line.ReleasedAtEnd = true
		}
		done()
	}
}

// outcome records the status the proxy stage resolved and whether any backend answered.
func (tr *requestTrace) outcome(code int, answered bool) {
	if tr != nil {
		tr.final, tr.answered = code, answered
	}
}

// body watches the bytes written toward the client for the first non-empty content delta.
//
// It does not stamp: a write lands in the server's buffer, and the client receives nothing until the flush.
// The stamp is taken at the next flush (pilot scope review 10, finding 1).
func (tr *requestTrace) body(b []byte) {
	if tr != nil && tr.content.observe(b) {
		tr.contentPending = true
	}
}

// flushed stamps first content when the flush that sends it has returned.
func (tr *requestTrace) flushed() {
	if tr != nil && tr.contentPending && tr.t.firstContent.IsZero() {
		tr.t.firstContent = time.Now()
		tr.contentPending = false
	}
}

// finish writes the done line; it runs on every way out of the handler.
func (tr *requestTrace) finish() {
	if tr == nil {
		return
	}
	tr.t.ended = time.Now()
	if tr.contentPending && tr.t.firstContent.IsZero() {
		// Written and never flushed: it reached the client only when the handler returned and the server flushed.
		tr.t.firstContent = tr.t.ended
		tr.line.FirstContentAtEnd = true
	}
	l := tr.line
	l.Ev = "done"
	l.Status = tr.status.code
	if tr.final != 0 {
		// The proxy stage's resolved status, not the writer's: when no backend answered, nothing was written
		// and the writer still holds its default 200.
		l.Status = tr.final
	}
	l.Answered = tr.answered || tr.status.wrote
	l.EnteredUnixNanos = nanos(tr.t.entered)
	l.ArrivedUnixNanos = nanos(tr.t.arrived)
	l.RecordedUnixNanos = nanos(tr.t.recorded)
	l.DecidedUnixNanos = nanos(tr.t.decided)
	l.DecidingUnixNanos = nanos(tr.t.deciding)
	l.HandoffUnixNanos = nanos(tr.t.handoff)
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
	code  int
	wrote bool
}

func (c *codeWriter) WriteHeader(code int) {
	c.code = code
	c.wrote = true
	c.ResponseWriter.WriteHeader(code)
}

func (c *codeWriter) Write(b []byte) (int, error) {
	c.wrote = true
	return c.ResponseWriter.Write(b)
}

func (c *codeWriter) Flush() {
	if f, ok := c.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (c *codeWriter) Unwrap() http.ResponseWriter { return c.ResponseWriter }

// contentKey is the JSON key of a chat-completion content delta.
//
// The value after it is matched allowing JSON whitespace around the colon, because a serializer that spaces its
// output is still emitting content (commit review of d463287). The role frame's empty content ("") does not
// count: the byte after the opening quote must not be the closing quote.
var contentKey = []byte(`"content"`)

// maxContentTail bounds what is carried between chunks while a key's value is still incomplete, so a stream of
// whitespace cannot grow it without limit.
const maxContentTail = 256

// contentWatcher finds the first COMPLETE server-sent event carrying a non-empty content delta, across chunks.
//
// Recognising the content's first byte is not enough: a frame cut after `"content":"x` and finished a second
// later would be stamped at the cut (pilot scope review 11, finding 1). So once the content is found, the
// watcher waits for the blank line that ends the event before it reports.
type contentWatcher struct {
	tail []byte
	seen bool
	// inFrame is set once non-empty content has been found and its event has not yet ended.
	inFrame bool
	// atLineStart and pendingCR carry the line-ending state across chunks, so an event end split between two
	// chunks is still found: atLineStart is set when a line has just ended, pendingCR when it ended in a CR that
	// a following LF would complete.
	atLineStart, pendingCR bool
}

// valueStarts reports, for the bytes after a content key, whether they begin a non-empty string value.
// complete is false when the bytes run out before that can be decided.
func valueStarts(rest []byte) (nonEmpty, complete bool) {
	i := 0
	skip := func() {
		for i < len(rest) && (rest[i] == ' ' || rest[i] == '\t' || rest[i] == '\n' || rest[i] == '\r') {
			i++
		}
	}
	skip()
	if i >= len(rest) {
		return false, false
	}
	if rest[i] != ':' {
		return false, true
	}
	i++
	skip()
	if i >= len(rest) {
		return false, false
	}
	if rest[i] != '"' {
		// null or another non-string value: no content here.
		return false, true
	}
	i++
	if i >= len(rest) {
		return false, false
	}
	return rest[i] != '"', true
}

// observe reports whether b completes the event carrying the stream's first non-empty content delta.
func (c *contentWatcher) observe(b []byte) bool {
	if c.seen {
		return false
	}
	if c.inFrame {
		return c.endOf(b)
	}
	buf := append(c.tail, b...)
	c.tail = nil
	for i := 0; ; {
		j := bytes.Index(buf[i:], contentKey)
		if j < 0 {
			break
		}
		start := i + j
		nonEmpty, complete := valueStarts(buf[start+len(contentKey):])
		if !complete {
			// The key's value continues in the next chunk; carry the key and what follows it.
			if len(buf)-start <= maxContentTail {
				c.tail = append([]byte(nil), buf[start:]...)
			}
			return false
		}
		if nonEmpty {
			c.inFrame = true
			return c.endOf(buf[start:])
		}
		i = start + len(contentKey)
	}
	// Keep only what could be the start of a key split across chunks.
	keep := len(contentKey) - 1
	if len(buf) < keep {
		keep = len(buf)
	}
	c.tail = append([]byte(nil), buf[len(buf)-keep:]...)
	return false
}

// endOf reports whether b, following the content found, ends its event.
//
// An event ends at a blank line, and a server-sent event's lines may end in CRLF, LF or CR, so the end is any
// two line endings in a row with nothing between them, a CRLF counting as one. Matching only "\n\n" missed
// every CRLF-delimited stream, which the client reads and counts (review of 71086d8).
func (c *contentWatcher) endOf(b []byte) bool {
	for _, ch := range b {
		if c.pendingCR {
			c.pendingCR = false
			if ch == '\n' {
				continue
			}
		}
		switch ch {
		case '\r', '\n':
			if c.atLineStart {
				c.seen, c.inFrame = true, false
				return true
			}
			c.atLineStart, c.pendingCR = true, ch == '\r'
		default:
			c.atLineStart = false
		}
	}
	return false
}
