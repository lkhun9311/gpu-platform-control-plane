package gateway

import (
	"sync"
	"time"
)

// defaultBodyIdleTimeout is how long a response may go without a body byte before the gateway ends it.
//
// ResponseHeaderTimeout stops counting at the headers, and a streaming engine sends those before the first token, so
// without this an upstream that stalled after them held the request for as long as its client stayed connected.
// It is a bound on silence, not on length: a stream still producing tokens is never cut.
// Five minutes is far above anything a healthy engine is silent for once it has answered, including a queued prompt's
// wait for prefill, and above the 30 s and 60 s per-request timeouts every registered run's load generator gave up at,
// so no registered request could have reached it.
const defaultBodyIdleTimeout = 5 * time.Minute

// idleWatch calls expire once a response has been silent for its bound, counting from the first touch.
//
// It is armed by the first touch rather than at construction, because the wait before headers is
// ResponseHeaderTimeout's to bound and a request still in admission or dialling is not silent upstream.
type idleWatch struct {
	mu     sync.Mutex
	bound  time.Duration
	expire func()
	timer  *time.Timer
	done   bool
}

func newIdleWatch(bound time.Duration, expire func()) *idleWatch {
	return &idleWatch{bound: bound, expire: expire}
}

// touch records activity: the headers or a body write reached the client.
func (w *idleWatch) touch() {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.done {
		return
	}
	if w.timer == nil {
		w.timer = time.AfterFunc(w.bound, w.expire)
		return
	}
	w.timer.Reset(w.bound)
}

// stop disarms the watch for good, once the response has ended by itself.
func (w *idleWatch) stop() {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.done = true
	if w.timer != nil {
		w.timer.Stop()
	}
}
