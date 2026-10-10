package gateway

import (
	"context"
	"sync"
	"time"
)

// AdmissionFixedSpacing admits a standard request no sooner than a fixed spacing after the previous standard request
// on its backend was admitted, in arrival order, with nothing from the engine.
//
// It is the static control of the design page's v26 (docs/superpowers/specs/
// 2026-10-08-measuring-prospective-admission-design.md, "v26"): serial-prefill releases the next contender when the
// previous one's first content arrives, and this rule asks whether a fixed clock does as well without that signal.
// It holds as serial-prefill does, with the same longest hold, so the two differ only in what releases a contender.
// Only an admission moves the clock: a request refused for waiting or abandoned by its client takes no slot, as in
// the replay that chose the spacings (hack/prospective-pilot/simulate.py, hold_spacing).
const AdmissionFixedSpacing AdmissionMode = "fixed-spacing"

const (
	// reasonFixedSpacingFree admits a standard request that found the spacing already elapsed and nobody waiting.
	reasonFixedSpacingFree = "fixed_spacing_free"
	// reasonFixedSpacingWaited admits one that was held until its turn's spacing had elapsed.
	reasonFixedSpacingWaited = "fixed_spacing_waited"
	// reasonFixedSpacingHoldTimeout refuses one held for maxHold without its turn coming.
	reasonFixedSpacingHoldTimeout = "fixed_spacing_hold_timeout"
	// reasonFixedSpacingClientGone refuses one whose client went away while it was held.
	reasonFixedSpacingClientGone = "fixed_spacing_client_gone"
)

// fixedSpacingLine is one backend's clock and queue: when it last admitted a standard request, who waits in order,
// and whether a timer is set for the head of the line.
type fixedSpacingLine struct {
	last    time.Time
	waiters []waiter
	armed   bool
}

type fixedSpacingAdmitter struct {
	mu      sync.Mutex
	spacing time.Duration
	maxHold time.Duration
	lines   map[string]*fixedSpacingLine
}

// NewFixedSpacingAdmitter returns the fixed-spacing admitter with its spacing and longest hold.
func NewFixedSpacingAdmitter(spacing, maxHold time.Duration) Admitter {
	return newFixedSpacingAdmitter(spacing, maxHold)
}

func newFixedSpacingAdmitter(spacing, maxHold time.Duration) *fixedSpacingAdmitter {
	return &fixedSpacingAdmitter{spacing: spacing, maxHold: maxHold, lines: map[string]*fixedSpacingLine{}}
}

// Admit refuses, as serial-prefill's does: the server reaches a reserving admitter only through Reserve.
func (f *fixedSpacingAdmitter) Admit(context.Context, RequestMeta, *BackendRef, string, string) (bool, string) {
	return false, "reservation_required"
}

// Reserve admits a premium request at once, and a standard one when nobody waits ahead of it and a spacing has passed
// since the backend's last standard admission; otherwise it waits its turn. It returns no reservation: nothing the
// request does later releases anything.
func (f *fixedSpacingAdmitter) Reserve(ctx context.Context, _ RequestMeta, backend *BackendRef, _, tier string) (*reservation, bool, string) {
	if tier == tierPremium {
		return nil, true, reasonPremiumUnreserved
	}
	key := backend.URL.String()
	f.mu.Lock()
	l := f.lines[key]
	if l == nil {
		l = &fixedSpacingLine{}
		f.lines[key] = l
	}
	now := time.Now()
	if len(l.waiters) == 0 && (l.last.IsZero() || now.Sub(l.last) >= f.spacing) {
		l.last = now
		f.mu.Unlock()
		return nil, true, reasonFixedSpacingFree
	}
	turn := make(chan struct{})
	l.waiters = append(l.waiters, waiter{turn, now})
	f.arm(key, l, now)
	f.mu.Unlock()

	timer := time.NewTimer(f.maxHold)
	defer timer.Stop()
	select {
	case <-turn:
		return nil, true, reasonFixedSpacingWaited
	case <-timer.C:
		f.leave(key, turn)
		return nil, false, reasonFixedSpacingHoldTimeout
	case <-ctx.Done():
		f.leave(key, turn)
		return nil, false, reasonFixedSpacingClientGone
	}
}

// arm sets one timer for the head of the line, at the last admission plus the spacing; the caller holds mu.
func (f *fixedSpacingAdmitter) arm(key string, l *fixedSpacingLine, now time.Time) {
	if l.armed || len(l.waiters) == 0 {
		return
	}
	l.armed = true
	time.AfterFunc(l.last.Add(f.spacing).Sub(now), func() { f.release(key) })
}

// release admits the head of the line if its spacing has passed, and sets the timer for the next one.
// A head already past its hold is dropped, not admitted, and takes no slot: its own timer refuses it (v26 review, A14).
func (f *fixedSpacingAdmitter) release(key string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	l := f.lines[key]
	l.armed = false
	now := time.Now()
	for len(l.waiters) > 0 && now.Sub(l.waiters[0].since) > f.maxHold {
		l.waiters = l.waiters[1:]
	}
	if len(l.waiters) > 0 && now.Sub(l.last) >= f.spacing {
		close(l.waiters[0].turn)
		l.waiters = l.waiters[1:]
		l.last = now
	}
	f.arm(key, l, now)
}

// leave takes a waiter out of line. One whose turn was handed to it as it gave up was counted as admitted, and that
// slot is spent: the race is at the 25 s hold or a client's exit, and spending the slot only ever slows this arm.
func (f *fixedSpacingAdmitter) leave(key string, turn chan struct{}) {
	f.mu.Lock()
	defer f.mu.Unlock()
	l := f.lines[key]
	for i, c := range l.waiters {
		if c.turn == turn {
			l.waiters = append(l.waiters[:i:i], l.waiters[i+1:]...)
			return
		}
	}
}

// waiting reports how many standard requests wait on a backend, for tests.
func (f *fixedSpacingAdmitter) waiting(backend *BackendRef) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	if l := f.lines[backend.URL.String()]; l != nil {
		return len(l.waiters)
	}
	return 0
}
