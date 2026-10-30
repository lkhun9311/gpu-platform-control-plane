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

// serialPrefillAdmitter keeps, per backend, whether a standard request is in prefill and who is waiting, in turn.
type serialPrefillAdmitter struct {
	mu      sync.Mutex
	maxHold time.Duration
	busy    map[string]bool
	waiters map[string]*fairLine
}

// waiter is a held request's turn, when it began waiting and how long it may wait, so a turn is never handed to one already past its hold.
// Each waiter keeps the hold it arrived under, so a changed maxHold applies to the next request and not to one already waiting.
type waiter struct {
	turn    chan struct{}
	since   time.Time
	maxHold time.Duration
	tenant  string
}

// NewSerialPrefillAdmitter returns the serial-prefill admitter with its longest hold.
func NewSerialPrefillAdmitter(maxHold time.Duration) Admitter {
	return newSerialPrefillAdmitter(maxHold)
}

func newSerialPrefillAdmitter(maxHold time.Duration) *serialPrefillAdmitter {
	return &serialPrefillAdmitter{maxHold: maxHold, busy: map[string]bool{}, waiters: map[string]*fairLine{}}
}

// Admit refuses, as the prospective admitter's does: the server reaches a reserving admitter only through Reserve,
// and an admission without the hold would be the rule bypassed.
func (s *serialPrefillAdmitter) Admit(context.Context, RequestMeta, *BackendRef, string, string) (bool, string) {
	return false, reasonReservationRequired
}

// Reserve admits a premium request at once, and a standard one when its backend has no standard request in prefill,
// waiting its turn behind those that arrived before it.
func (s *serialPrefillAdmitter) Reserve(ctx context.Context, _ RequestMeta, backend *BackendRef, tenant, tier string) (*reservation, bool, string) {
	return s.reserve(ctx, backend, tenant, tier, s.maxHold)
}

// reserve is Reserve with the hold passed in, so the hold-cap admitter can give each backend the hold from its own spec.
func (s *serialPrefillAdmitter) reserve(ctx context.Context, backend *BackendRef, tenant, tier string, maxHold time.Duration) (*reservation, bool, string) {
	if tier == tierPremium {
		return nil, true, reasonPremiumUnreserved
	}
	key := backend.URL.String()
	s.mu.Lock()
	line := s.waiters[key]
	if line == nil {
		line = newFairLine()
		s.waiters[key] = line
	}
	if !s.busy[key] && line.len() == 0 {
		s.busy[key] = true
		s.mu.Unlock()
		return s.hold(key), true, reasonSerialPrefillFree
	}
	turn := make(chan struct{})
	line.push(waiter{turn: turn, since: time.Now(), maxHold: maxHold, tenant: tenant})
	s.mu.Unlock()

	timer := time.NewTimer(maxHold)
	defer timer.Stop()
	select {
	case <-turn:
		return s.hold(key), true, reasonSerialPrefillWaited
	case <-timer.C:
		s.leave(key, tenant, turn)
		return nil, false, reasonSerialPrefillHoldTimeout
	case <-ctx.Done():
		s.leave(key, tenant, turn)
		return nil, false, reasonSerialPrefillClientGone
	}
}

// hold is the reservation for an admitted standard request: its prefill release hands the backend to the next waiter.
func (s *serialPrefillAdmitter) hold(key string) *reservation {
	return &reservation{releasePrefill: func() { s.next(key) }, onContent: true}
}

// next passes the backend to the waiter whose turn it is, or marks it free; the turn is handed over under the lock, so no
// request can slip in between a release and the waiter it was meant for.
// A waiter already past its hold is skipped, not handed the turn: its own timer refuses it, and a turn and a timer
// ready together would otherwise be decided at random (v26 review, A14).
func (s *serialPrefillAdmitter) next(key string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if line := s.waiters[key]; line != nil {
		if w, ok := line.pop(time.Now()); ok {
			close(w.turn)
			return
		}
	}
	s.busy[key] = false
}

// leave takes a waiter out of line; if its turn had already been handed to it as it gave up, it passes it on, so a
// timed-out or abandoned waiter cannot keep the backend.
// A waiter no longer in line was either handed the turn, whose channel is then closed, or skipped by next for being
// past its hold, whose channel is not; only the first may pass the turn on, or a skipped waiter's timeout admits a
// second request beside the holder (review of 0057699).
func (s *serialPrefillAdmitter) leave(key, tenant string, turn chan struct{}) {
	s.mu.Lock()
	if line := s.waiters[key]; line != nil && line.remove(tenant, turn) {
		s.mu.Unlock()
		return
	}
	s.mu.Unlock()
	select {
	case <-turn:
		s.next(key)
	default:
	}
}

// state reports whether a backend has a standard request in prefill and how many wait, for tests.
func (s *serialPrefillAdmitter) state(backend *BackendRef) (bool, int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := backend.URL.String()
	if line := s.waiters[key]; line != nil {
		return s.busy[key], line.len()
	}
	return s.busy[key], 0
}
