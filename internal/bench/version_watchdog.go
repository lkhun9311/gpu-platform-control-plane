package bench

import (
	"context"
	"errors"
	"fmt"
	"math"
	"time"
)

// ErrTeardownDeadline is the cause a session is cut with when its absolute teardown deadline arrives (#597).
var ErrTeardownDeadline = errors.New("the absolute teardown deadline passed")

// ErrWatchdogUnarmed means the deadline could not be computed, so no session may run under it.
var ErrWatchdogUnarmed = errors.New("the teardown deadline cannot be computed")

// WatchdogClock is the watchdog's time source; SystemClock is the real one, and a test moves a fake one by hand.
type WatchdogClock interface {
	Now() time.Time
	After(d time.Duration) <-chan time.Time
}

// SystemClock is the process's own clock.
type SystemClock struct{}

func (SystemClock) Now() time.Time { return time.Now() }

func (SystemClock) After(d time.Duration) <-chan time.Time { return time.After(d) }

// SessionWatchdog begins teardown at the version study's absolute deadline, TeardownDeadlineSeconds after launch, whatever phase is running.
//
// It is the in-process layer of the deadline only.
// It cannot act once the process is dead, suspended or not yet started, and it does not end the billing itself.
// The guest shutdown backstop and the AWS-side sweeper (#616) are what hold the deadline in those cases.
type SessionWatchdog struct {
	Design VersionStudyDesign
	// RatePerHour is the session rate the deadline is computed from; it must be known before setup, since setup is under the deadline too.
	RatePerHour float64
	// LaunchedAt is EC2's LaunchTime, because billing starts there and not when this process starts.
	LaunchedAt time.Time
	Clock      WatchdogClock
	// Teardown uploads what evidence is on disk and shuts the instance down; it runs once per Run.
	//
	// At the deadline it runs while the session may still be writing, so it must not touch session-owned state such as the live attempt journal.
	// Its context is detached from the parent, so an interrupt does not cut it, and it has no deadline: Teardown bounds its own steps.
	Teardown func(ctx context.Context, cause error) error
}

// Deadline is when teardown must begin: launch plus TeardownDeadlineSeconds at the session rate.
func (w SessionWatchdog) Deadline() (time.Time, error) {
	if w.LaunchedAt.IsZero() {
		return time.Time{}, fmt.Errorf("%w: no launch time", ErrWatchdogUnarmed)
	}
	secs := w.Design.TeardownDeadlineSeconds(w.RatePerHour)
	// A deadline beyond what a Duration holds would wrap, so it is refused like one that has no time in it.
	if secs <= 0 || int64(secs) > math.MaxInt64/int64(time.Second) {
		return time.Time{}, fmt.Errorf("%w: %d s after launch at $%v/h", ErrWatchdogUnarmed, secs, w.RatePerHour)
	}
	return w.LaunchedAt.Add(time.Duration(secs) * time.Second), nil
}

// Run runs session under the deadline and begins teardown exactly once: when the session returns, when the parent is cancelled, or at the deadline.
//
// At the deadline or on an interrupt it cancels the session and begins teardown at once, without waiting for the session to return.
// A phase may ignore its context for minutes, as an engine removal does with its own 120 s bound after a phase deadline, and the deadline must not wait for it.
// A deadline already passed, one that cannot be computed, or a parent already cancelled tears down without running the session, because the instance is billing either way.
// The returned error carries what triggered teardown and any error of Teardown itself, so a failed shutdown is never read as a clean end.
func (w SessionWatchdog) Run(ctx context.Context, session func(context.Context) error) error {
	// Without these the watchdog can neither time nor end anything, so the caller keeps the cleanup.
	if w.Clock == nil || w.Teardown == nil || session == nil {
		return errors.New("session watchdog: a clock, a teardown and a session are required")
	}
	tctx := context.WithoutCancel(ctx)
	teardown := func(cause error) error { return errors.Join(cause, w.Teardown(tctx, cause)) }
	deadline, err := w.Deadline()
	if err != nil {
		return teardown(err)
	}
	if ctx.Err() != nil {
		return teardown(context.Cause(ctx))
	}
	// The remaining time is read once against LaunchTime's wall clock, and the timer then counts on the monotonic clock, so a later wall-clock step cannot move it.
	remaining := deadline.Sub(w.Clock.Now())
	if remaining <= 0 {
		return teardown(ErrTeardownDeadline)
	}
	// Armed before the session starts, so no session work runs unwatched.
	fired := w.Clock.After(remaining)
	sctx, cancel := context.WithCancelCause(ctx)
	defer cancel(nil)
	// Buffered, so a session that returns after teardown has begun does not block forever on a result nobody reads.
	done := make(chan error, 1)
	go func() {
		// A panic would kill the process before teardown, leaving the instance to the slower backstops.
		defer func() {
			if p := recover(); p != nil {
				done <- fmt.Errorf("session panicked: %v", p)
			}
		}()
		done <- session(sctx)
	}()
	var cause error
	select {
	case err := <-done:
		cause = err
		// select picks among ready cases at random, so the deadline and the parent are checked again here.
		// A session cut by either may still return nil, as RunBlocks does, and its clean result must not hide the cut.
		if ctx.Err() != nil {
			cause = errors.Join(context.Cause(ctx), cause)
		}
		if !w.Clock.Now().Before(deadline) {
			cause = errors.Join(ErrTeardownDeadline, cause)
		}
	case <-fired:
		cause = ErrTeardownDeadline
	case <-ctx.Done():
		cause = context.Cause(ctx)
	}
	if cause != nil {
		cancel(cause)
	}
	return teardown(cause)
}
