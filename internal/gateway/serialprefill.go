package gateway

import (
	"context"
	"sync"
	"time"
)

// AdmissionSerialPrefill holds a standard request at the gateway until no other standard request on its backend is
// still in prefill, so at most one contender prefill runs at a time.
//
// It is the gateway half of the design page's v23 candidate (docs/superpowers/specs/
// 2026-10-08-measuring-prospective-admission-design.md, "v23"). The pilot's step logs show a premium request waiting
// through a whole contender prefill because the engine serves running requests first; an engine cap on a prefill's
// tokens per step lets a waiting request in beside one running prefill, but two prefills together take the whole
// budget, which this rule prevents.
//
// It holds rather than refuses, so the contender's work is kept and its cost is time. A request held longer than
// maxHold is refused, so a held request cannot outlive its client's timeout at the gateway.
// "In prefill" ends when the response's first complete content event reaches the gateway, the nearest point it can
// see to the engine finishing the prompt; not its first body byte, which may be a frame without content (v24 review,
// finding 3). On vLLM v0.27.1 the two coincide: the role frame is sent in the same write as the first token.
// Only a content delta releases: a stream that generates only tool calls or reasoning holds its turn to its end. The
// diagnostic enforces the benchmark profile, whose requests produce neither. That holds only while the engine does not preempt: a preempted request recomputes its
// prompt after its first byte, when this rule already counts it as done.
const AdmissionSerialPrefill AdmissionMode = "serial-prefill"

const (
	// reasonSerialPrefillFree admits a standard request that found no other in prefill.
	reasonSerialPrefillFree = "serial_prefill_free"
	// reasonSerialPrefillWaited admits one that was held until the one before it finished its prefill.
	reasonSerialPrefillWaited = "serial_prefill_waited"
	// reasonSerialPrefillHoldTimeout refuses one held for maxHold without its turn coming.
	reasonSerialPrefillHoldTimeout = "serial_prefill_hold_timeout"
	// reasonSerialPrefillClientGone refuses one whose client went away while it was held.
	reasonSerialPrefillClientGone = "serial_prefill_client_gone"
)

// serialPrefillAdmitter keeps, per backend, whether a standard request is in prefill and who is waiting, in order.
type serialPrefillAdmitter struct {
	mu      sync.Mutex
	maxHold time.Duration
	busy    map[string]bool
	waiters map[string][]waiter
}

// waiter is a held request's turn and when it began waiting, so a turn is never handed to one already past its hold.
type waiter struct {
	turn  chan struct{}
	since time.Time
}

// NewSerialPrefillAdmitter returns the serial-prefill admitter with its longest hold.
func NewSerialPrefillAdmitter(maxHold time.Duration) Admitter {
	return newSerialPrefillAdmitter(maxHold)
}

func newSerialPrefillAdmitter(maxHold time.Duration) *serialPrefillAdmitter {
	return &serialPrefillAdmitter{maxHold: maxHold, busy: map[string]bool{}, waiters: map[string][]waiter{}}
}

// Admit refuses, as the prospective admitter's does: the server reaches a reserving admitter only through Reserve,
// and an admission without the hold would be the rule bypassed.
func (s *serialPrefillAdmitter) Admit(context.Context, RequestMeta, *BackendRef, string, string) (bool, string) {
	return false, "reservation_required"
}

// Reserve admits a premium request at once, and a standard one when its backend has no standard request in prefill,
// waiting its turn behind those that arrived before it.
func (s *serialPrefillAdmitter) Reserve(ctx context.Context, _ RequestMeta, backend *BackendRef, _, tier string) (*reservation, bool, string) {
	if tier == tierPremium {
		return nil, true, reasonPremiumUnreserved
	}
	key := backend.URL.String()
	s.mu.Lock()
	if !s.busy[key] && len(s.waiters[key]) == 0 {
		s.busy[key] = true
		s.mu.Unlock()
		return s.hold(key), true, reasonSerialPrefillFree
	}
	turn := make(chan struct{})
	s.waiters[key] = append(s.waiters[key], waiter{turn, time.Now()})
	s.mu.Unlock()

	timer := time.NewTimer(s.maxHold)
	defer timer.Stop()
	select {
	case <-turn:
		return s.hold(key), true, reasonSerialPrefillWaited
	case <-timer.C:
		s.leave(key, turn)
		return nil, false, reasonSerialPrefillHoldTimeout
	case <-ctx.Done():
		s.leave(key, turn)
		return nil, false, reasonSerialPrefillClientGone
	}
}

// hold is the reservation for an admitted standard request: its prefill release hands the backend to the next waiter.
func (s *serialPrefillAdmitter) hold(key string) *reservation {
	return &reservation{releasePrefill: func() { s.next(key) }, onContent: true}
}

// next passes the backend to the longest waiter, or marks it free; the turn is handed over under the lock, so no
// request can slip in between a release and the waiter it was meant for.
// A waiter already past its hold is skipped, not handed the turn: its own timer refuses it, and a turn and a timer
// ready together would otherwise be decided at random (v26 review, A14).
func (s *serialPrefillAdmitter) next(key string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	for w := s.waiters[key]; len(w) > 0; w = s.waiters[key] {
		s.waiters[key] = w[1:]
		if now.Sub(w[0].since) > s.maxHold {
			continue
		}
		close(w[0].turn)
		return
	}
	s.busy[key] = false
}

// leave takes a waiter out of line; if its turn had already been handed to it as it gave up, it passes it on, so a
// timed-out or abandoned waiter cannot keep the backend.
func (s *serialPrefillAdmitter) leave(key string, turn chan struct{}) {
	s.mu.Lock()
	w := s.waiters[key]
	for i, c := range w {
		if c.turn == turn {
			s.waiters[key] = append(w[:i:i], w[i+1:]...)
			s.mu.Unlock()
			return
		}
	}
	s.mu.Unlock()
	s.next(key)
}

// state reports whether a backend has a standard request in prefill and how many wait, for tests.
func (s *serialPrefillAdmitter) state(backend *BackendRef) (bool, int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := backend.URL.String()
	return s.busy[key], len(s.waiters[key])
}
