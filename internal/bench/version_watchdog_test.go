package bench

import (
	"context"
	"errors"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fakeWatchClock is a clock only the test moves, so the deadline is reached by an Advance and never by waiting.
type fakeWatchClock struct {
	mu     sync.Mutex
	now    time.Time
	timers []fakeWatchTimer
	// armed receives each timer's due time as it is registered, so a test advances only after the watchdog has armed.
	armed chan time.Time
	// step moves the clock on after every reading, as time passes between reading the clock and arming a timer.
	step time.Duration
}

type fakeWatchTimer struct {
	at time.Time
	c  chan time.Time
}

func newFakeWatchClock(now time.Time) *fakeWatchClock {
	return &fakeWatchClock{now: now, armed: make(chan time.Time, 8)}
}

func (c *fakeWatchClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now
	c.now = c.now.Add(c.step)
	return now
}

func (c *fakeWatchClock) At(at time.Time) <-chan time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	t := fakeWatchTimer{at: at, c: make(chan time.Time, 1)}
	if !at.After(c.now) {
		t.c <- c.now
	} else {
		c.timers = append(c.timers, t)
	}
	c.armed <- t.at
	return t.c
}

// Advance moves the clock to at and fires every timer due by then.
func (c *fakeWatchClock) Advance(at time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = at
	kept := c.timers[:0]
	for _, t := range c.timers {
		if t.at.After(at) {
			kept = append(kept, t)
			continue
		}
		t.c <- at
	}
	c.timers = kept
}

// Fire delivers every armed timer without moving the clock, as a timer read a moment before the clock that set it.
func (c *fakeWatchClock) Fire() {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, t := range c.timers {
		t.c <- c.now
	}
	c.timers = nil
}

// hang is a step that ignores every context, as a hung docker command or model download does, until the test releases it.
type hang struct {
	once    sync.Once
	entered chan struct{}
	release chan struct{}
}

func newHang() *hang { return &hang{entered: make(chan struct{}), release: make(chan struct{})} }

func (h *hang) wait() {
	h.once.Do(func() { close(h.entered) })
	<-h.release
}

// hangingStop is an engine whose removal hangs past every bound, the 120 s engineStopTimeout included.
type hangingStop struct {
	*fakePreflight
	h *hang
}

func (e hangingStop) Stop(context.Context, EngineStart) error {
	e.h.wait()
	return nil
}

// interruptedUnseen is a parent that reports itself cancelled once interrupted is set, while its Done never closes.
// It holds open the moment when a cancellation has happened but the watchdog's select has not yet seen it.
type interruptedUnseen struct {
	context.Context
	interrupted atomic.Bool
}

func (c *interruptedUnseen) Err() error {
	if c.interrupted.Load() {
		return context.Canceled
	}
	return nil
}

// within fails the test when ch does not deliver in real time, so a broken watchdog fails instead of hanging the suite.
func within[T any](t *testing.T, ch <-chan T, what string) T {
	t.Helper()
	select {
	case v := <-ch:
		return v
	case <-time.After(5 * time.Second):
		t.Fatalf("%s did not happen", what)
		panic("unreachable")
	}
}

// watched is one watchdog run on a fake clock, with what its teardown and its session saw.
type watched struct {
	clock     *fakeWatchClock
	launched  time.Time
	deadline  time.Time
	teardowns chan error
	// teardownCtx is whether each teardown's context had already ended when it began.
	teardownCtx chan error
	result      chan error
	// sessionCtx is the context the session ran on, and done closes when the session itself returns.
	sessionCtx chan context.Context
	done       chan struct{}
}

// startWatched runs session under a watchdog armed five minutes after launch, at the registered rate of $1.337/h.
func startWatched(t *testing.T, ctx context.Context, session func(context.Context) error) *watched {
	t.Helper()
	d := versionAsyncDesign()
	rate := 1.337
	launched := time.Date(2026, 11, 20, 0, 0, 0, 0, time.UTC)
	w := &watched{
		clock:    newFakeWatchClock(launched.Add(5 * time.Minute)),
		launched: launched,
		deadline: launched.Add(time.Duration(d.TeardownDeadlineSeconds(rate)) * time.Second),
		// Buffered beyond one, so a second teardown is seen rather than blocked on.
		teardowns:   make(chan error, 4),
		teardownCtx: make(chan error, 4),
		result:      make(chan error, 1),
		sessionCtx:  make(chan context.Context, 1),
		done:        make(chan struct{}),
	}
	wd := SessionWatchdog{
		Design: d, RatePerHour: rate, LaunchedAt: launched, Clock: w.clock,
		Teardown: func(ctx context.Context, cause error) error {
			w.teardownCtx <- ctx.Err()
			w.teardowns <- cause
			return nil
		},
	}
	go func() {
		w.result <- wd.Run(ctx, func(ctx context.Context) error {
			defer close(w.done)
			w.sessionCtx <- ctx
			return session(ctx)
		})
	}()
	return w
}

// TestSessionWatchdogTearsDownAtTheDeadlineWhateverPhaseIsRunning: each phase hangs past the deadline, ignoring its
// context, and teardown still begins at the deadline, while the phase is hung, and once.
func TestSessionWatchdogTearsDownAtTheDeadlineWhateverPhaseIsRunning(t *testing.T) {
	phases := []struct {
		name    string
		session func(t *testing.T, h *hang) func(context.Context) error
	}{
		{"setup", func(_ *testing.T, h *hang) func(context.Context) error {
			return func(context.Context) error { h.wait(); return nil }
		}},
		{"preflight readiness", func(_ *testing.T, h *hang) func(context.Context) error {
			f := newFakePreflight()
			p := f.preflight()
			p.Ready = func(context.Context) error { h.wait(); return nil }
			return func(ctx context.Context) error { _, err := p.Run(ctx); return err }
		}},
		{"calibration ladder", func(_ *testing.T, h *hang) func(context.Context) error {
			f := newFakePreflight()
			c := f.calibrationPhase()
			c.Calibrate = func(context.Context) (CalibrationResult, error) { h.wait(); return CalibrationResult{}, nil }
			return func(ctx context.Context) error { _, err := c.Run(ctx); return err }
		}},
		{"calibration engine stop", func(_ *testing.T, h *hang) func(context.Context) error {
			f := newFakePreflight()
			c := f.calibrationPhase()
			c.Engine = hangingStop{f, h}
			return func(ctx context.Context) error { _, err := c.Run(ctx); return err }
		}},
		{"block replay", func(t *testing.T, h *hang) func(context.Context) error {
			f := &fakeInstance{}
			j, err := OpenAttemptJournal(filepath.Join(t.TempDir(), "attempts.jsonl"), "camp-1")
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = j.Close() })
			return func(ctx context.Context) error {
				v, vctx := f.visits(ctx)
				v.Replay = func(context.Context, int, string, string, []TraceRow) []RawRow { h.wait(); return nil }
				_, err := RunBlocks(vctx, SessionBlocks{
					Design: v.Design, WindowSeconds: 300, RatePerHour: 1.0,
					Spent: func() float64 { return 0 }, Now: time.Now, Ledger: j, Visit: v.Run,
				})
				return err
			}
		}},
		{"bundle and close", func(_ *testing.T, h *hang) func(context.Context) error {
			return func(context.Context) error { h.wait(); return nil }
		}},
	}
	for _, ph := range phases {
		t.Run(ph.name, func(t *testing.T) {
			h := newHang()
			w := startWatched(t, context.Background(), ph.session(t, h))
			released := false
			defer func() {
				if !released {
					close(h.release)
				}
			}()
			armedAt := within(t, w.clock.armed, "arming")
			if !armedAt.Equal(w.deadline) {
				t.Fatalf("armed for %v, want the launch plus TeardownDeadlineSeconds, %v", armedAt, w.deadline)
			}
			within(t, h.entered, "the phase reaching its hang")
			w.clock.Advance(w.deadline.Add(-time.Nanosecond))
			select {
			case cause := <-w.teardowns:
				t.Fatalf("teardown began before the deadline, cause %v", cause)
			default:
			}
			w.clock.Advance(w.deadline)
			if cause := within(t, w.teardowns, "teardown at the deadline"); !errors.Is(cause, ErrTeardownDeadline) {
				t.Fatalf("teardown cause %v, want ErrTeardownDeadline", cause)
			}
			// Run returns with the phase still hung: the watchdog never waits for a phase to honour its cancellation.
			if err := within(t, w.result, "Run's return"); !errors.Is(err, ErrTeardownDeadline) {
				t.Fatalf("Run returned %v, want ErrTeardownDeadline", err)
			}
			select {
			case <-w.done:
				t.Fatal("the session returned although its phase is still hung")
			default:
			}
			sctx := within(t, w.sessionCtx, "the session's context")
			if !errors.Is(context.Cause(sctx), ErrTeardownDeadline) {
				t.Fatalf("the session's context ended with %v, want ErrTeardownDeadline", context.Cause(sctx))
			}
			released = true
			close(h.release)
			within(t, w.done, "the session's return after release")
			select {
			case cause := <-w.teardowns:
				t.Fatalf("a second teardown, cause %v", cause)
			default:
			}
		})
	}
}

// TestSessionWatchdogTriggers: teardown also begins when the session ends or the parent is cancelled, and runs once.
func TestSessionWatchdogTriggers(t *testing.T) {
	t.Run("a session that ends before the deadline is torn down at once, with its own result", func(t *testing.T) {
		boom := errors.New("recorder failure")
		w := startWatched(t, context.Background(), func(context.Context) error { return boom })
		within(t, w.clock.armed, "arming")
		if cause := within(t, w.teardowns, "teardown"); !errors.Is(cause, boom) {
			t.Fatalf("teardown cause %v, want the session's error", cause)
		}
		if err := within(t, w.result, "Run's return"); !errors.Is(err, boom) || errors.Is(err, ErrTeardownDeadline) {
			t.Fatalf("Run returned %v, want only the session's error", err)
		}
	})
	t.Run("an operator interrupt tears down without waiting for a hung phase", func(t *testing.T) {
		h := newHang()
		defer close(h.release)
		ctx, cancel := context.WithCancelCause(context.Background())
		interrupt := errors.New("SIGTERM")
		w := startWatched(t, ctx, func(context.Context) error { h.wait(); return nil })
		within(t, w.clock.armed, "arming")
		within(t, h.entered, "the hang")
		cancel(interrupt)
		if cause := within(t, w.teardowns, "teardown"); !errors.Is(cause, interrupt) {
			t.Fatalf("teardown cause %v, want the interrupt", cause)
		}
		// The interrupt that started teardown must not also cut it, or the instance is left running.
		if err := within(t, w.teardownCtx, "teardown's context"); err != nil {
			t.Fatalf("teardown began on an ended context: %v", err)
		}
		if err := within(t, w.result, "Run's return"); !errors.Is(err, interrupt) {
			t.Fatalf("Run returned %v, want the interrupt", err)
		}
	})
	t.Run("a session that returns cleanly after an interrupt still reports the interrupt", func(t *testing.T) {
		// RunBlocks returns nil when its context is cancelled, so the session's result and the interrupt can both be ready when Run selects.
		// select would then pick either at random; a parent whose Done never closes makes the result branch the one taken, every time.
		ctx := &interruptedUnseen{Context: context.Background()}
		w := startWatched(t, ctx, func(context.Context) error { ctx.interrupted.Store(true); return nil })
		within(t, w.clock.armed, "arming")
		if cause := within(t, w.teardowns, "teardown"); !errors.Is(cause, context.Canceled) {
			t.Fatalf("teardown cause %v, want the interrupt", cause)
		}
		if err := within(t, w.result, "Run's return"); !errors.Is(err, context.Canceled) {
			t.Fatalf("Run returned %v, want the interrupt", err)
		}
	})
	t.Run("an interrupt and the deadline together are both reported, whichever select took", func(t *testing.T) {
		h := newHang()
		defer close(h.release)
		ctx := &interruptedUnseen{Context: context.Background()}
		w := startWatched(t, ctx, func(context.Context) error { h.wait(); return nil })
		within(t, w.clock.armed, "arming")
		within(t, h.entered, "the hang")
		// The interrupt happens first, but its Done never closes, so the timer is the case select takes.
		ctx.interrupted.Store(true)
		w.clock.Advance(w.deadline)
		cause := within(t, w.teardowns, "teardown")
		if !errors.Is(cause, ErrTeardownDeadline) || !errors.Is(cause, context.Canceled) {
			t.Fatalf("teardown cause %v, want both the deadline and the interrupt", cause)
		}
		if err := within(t, w.result, "Run's return"); !errors.Is(err, ErrTeardownDeadline) || !errors.Is(err, context.Canceled) {
			t.Fatalf("Run returned %v, want both the deadline and the interrupt", err)
		}
	})
	t.Run("a timer that fires is the deadline even when the clock reads a moment earlier", func(t *testing.T) {
		h := newHang()
		defer close(h.release)
		w := startWatched(t, context.Background(), func(context.Context) error { h.wait(); return nil })
		within(t, w.clock.armed, "arming")
		within(t, h.entered, "the hang")
		w.clock.Fire()
		if cause := within(t, w.teardowns, "teardown"); !errors.Is(cause, ErrTeardownDeadline) {
			t.Fatalf("teardown cause %v, want ErrTeardownDeadline", cause)
		}
		if err := within(t, w.result, "Run's return"); !errors.Is(err, ErrTeardownDeadline) {
			t.Fatalf("Run returned %v, want ErrTeardownDeadline", err)
		}
	})
	t.Run("time that passes while arming does not move the deadline", func(t *testing.T) {
		d := versionAsyncDesign()
		launched := time.Date(2026, 11, 20, 0, 0, 0, 0, time.UTC)
		deadline := launched.Add(time.Duration(d.TeardownDeadlineSeconds(1.337)) * time.Second)
		clock := newFakeWatchClock(launched.Add(5 * time.Minute))
		clock.step = time.Second
		result := make(chan error, 1)
		go func() {
			result <- SessionWatchdog{
				Design: d, RatePerHour: 1.337, LaunchedAt: launched, Clock: clock,
				Teardown: func(context.Context, error) error { return nil },
			}.Run(context.Background(), func(context.Context) error { return nil })
		}()
		if at := within(t, clock.armed, "arming"); !at.Equal(deadline) {
			t.Fatalf("armed for %v, want %v: the time spent arming was added to the deadline", at, deadline)
		}
		// The session ended at once, so the run ends cleanly.
		if err := within(t, result, "Run's return"); err != nil {
			t.Fatalf("Run returned %v, want a clean end", err)
		}
	})
	t.Run("a session that returns once the deadline is reached counts as cut by it", func(t *testing.T) {
		var w *watched
		assigned := make(chan struct{})
		w = startWatched(t, context.Background(), func(context.Context) error {
			<-assigned
			// The clock reaches the deadline without its timer being delivered, as when both are ready at once.
			w.clock.mu.Lock()
			w.clock.now = w.deadline
			w.clock.mu.Unlock()
			return nil
		})
		close(assigned)
		within(t, w.clock.armed, "arming")
		if cause := within(t, w.teardowns, "teardown"); !errors.Is(cause, ErrTeardownDeadline) {
			t.Fatalf("teardown cause %v, want ErrTeardownDeadline", cause)
		}
		if err := within(t, w.result, "Run's return"); !errors.Is(err, ErrTeardownDeadline) {
			t.Fatalf("Run returned %v, want ErrTeardownDeadline", err)
		}
	})
	t.Run("a session that panics is torn down", func(t *testing.T) {
		w := startWatched(t, context.Background(), func(context.Context) error { panic("nil map") })
		within(t, w.clock.armed, "arming")
		if cause := within(t, w.teardowns, "teardown"); cause == nil || !strings.Contains(cause.Error(), "nil map") {
			t.Fatalf("teardown cause %v, want the panic", cause)
		}
		if err := within(t, w.result, "Run's return"); err == nil || !strings.Contains(err.Error(), "nil map") {
			t.Fatalf("Run returned %v, want the panic", err)
		}
	})
}

// TestSessionWatchdogNeverRunsASessionItCannotBound: a deadline already passed, or one that cannot be computed, tears
// down at once and runs nothing, since the instance is already billing.
func TestSessionWatchdogNeverRunsASessionItCannotBound(t *testing.T) {
	d := versionAsyncDesign()
	launched := time.Date(2026, 11, 20, 0, 0, 0, 0, time.UTC)
	deadline := launched.Add(time.Duration(d.TeardownDeadlineSeconds(1.337)) * time.Second)
	cases := []struct {
		name     string
		now      time.Time
		launched time.Time
		rate     float64
		ctx      func() context.Context
		want     error
	}{
		{name: "armed exactly at the deadline", now: deadline, launched: launched, rate: 1.337, want: ErrTeardownDeadline},
		{name: "armed after the deadline", now: deadline.Add(time.Hour), launched: launched, rate: 1.337, want: ErrTeardownDeadline},
		{name: "no launch time", now: deadline.Add(-time.Hour), rate: 1.337, want: ErrWatchdogUnarmed},
		{name: "no rate", now: deadline.Add(-time.Hour), launched: launched, rate: 0, want: ErrWatchdogUnarmed},
		{name: "a rate with no time left before the reserve", now: launched, launched: launched, rate: 1e9, want: ErrWatchdogUnarmed},
		{name: "a parent already cancelled", now: launched, launched: launched, rate: 1.337, want: context.Canceled,
			ctx: func() context.Context { c, cancel := context.WithCancel(context.Background()); cancel(); return c }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ctx := context.Background()
			if tc.ctx != nil {
				ctx = tc.ctx()
			}
			var causes []error
			var ran atomic.Bool
			clock := newFakeWatchClock(tc.now)
			err := SessionWatchdog{
				Design: d, RatePerHour: tc.rate, LaunchedAt: tc.launched, Clock: clock,
				Teardown: func(_ context.Context, cause error) error { causes = append(causes, cause); return nil },
			}.Run(ctx, func(context.Context) error { ran.Store(true); return nil })
			// The flag catches a session run in Run's own goroutine.
			// Run does not join a session goroutine, so one started there might not have set it yet.
			// Arming comes before any such start, so a clock never armed is a goroutine never started.
			if ran.Load() {
				t.Fatal("the session ran")
			}
			if n := len(clock.armed); n != 0 {
				t.Fatalf("the watchdog armed %d timer(s), so the session was started", n)
			}
			if len(causes) != 1 || !errors.Is(causes[0], tc.want) || !errors.Is(err, tc.want) {
				t.Fatalf("teardowns %v, Run %v, want one teardown and a return matching %v", causes, err, tc.want)
			}
		})
	}
	t.Run("without a teardown there is nothing to run the session under", func(t *testing.T) {
		ran := false
		err := SessionWatchdog{Design: d, RatePerHour: 1.337, LaunchedAt: launched, Clock: newFakeWatchClock(launched)}.
			Run(context.Background(), func(context.Context) error { ran = true; return nil })
		if ran || err == nil {
			t.Fatalf("ran %v err %v", ran, err)
		}
	})
}

// TestSessionWatchdogTeardownErrorIsReported: a teardown that fails is never read as a clean end.
func TestSessionWatchdogTeardownErrorIsReported(t *testing.T) {
	launched := time.Date(2026, 11, 20, 0, 0, 0, 0, time.UTC)
	broken := errors.New("shutdown: permission denied")
	err := SessionWatchdog{
		Design: versionAsyncDesign(), RatePerHour: 1.337, LaunchedAt: launched, Clock: newFakeWatchClock(launched),
		Teardown: func(context.Context, error) error { return broken },
	}.Run(context.Background(), func(context.Context) error { return nil })
	if !errors.Is(err, broken) {
		t.Fatalf("Run returned %v, want the teardown's error", err)
	}
}
