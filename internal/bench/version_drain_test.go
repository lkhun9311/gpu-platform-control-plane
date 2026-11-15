package bench

import (
	"context"
	"testing"
	"time"
)

// TestCellDrainDeadlineRunsFromTheLastScheduledArrival: the registered 120 s start at the last arrival, not when the replay returns.
func TestCellDrainDeadlineRunsFromTheLastScheduledArrival(t *testing.T) {
	origin := time.Unix(1000, 0)
	trace := []TraceRow{{Index: 0, OffsetMs: 0}, {Index: 1, OffsetMs: 359_000}, {Index: 2, OffsetMs: 12_000}}
	got, err := CellDrainDeadline(origin, trace, 120*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if want := origin.Add(359*time.Second + 120*time.Second); !got.Equal(want) {
		t.Fatalf("deadline %v, want %v (last arrival 359 s plus 120 s)", got, want)
	}
	if _, err := CellDrainDeadline(origin, nil, 120*time.Second); err == nil {
		t.Fatal("an empty trace gave a drain deadline")
	}
}

// TestWaitDrainedUntilAcceptsOnlyAnIdleAnswerBeforeTheDeadline: a zero read taken after the deadline is not a drain within it.
func TestWaitDrainedUntilAcceptsOnlyAnIdleAnswerBeforeTheDeadline(t *testing.T) {
	idle := func(context.Context) (int, int, error) { return 0, 0, nil }
	reads := 0
	counting := func(ctx context.Context) (int, int, error) { reads++; return idle(ctx) }
	if WaitDrainedUntil(context.Background(), counting, time.Now().Add(-time.Second), time.Millisecond) || reads != 0 {
		t.Fatalf("a passed deadline counted as drained (%d reads)", reads)
	}
	if !WaitDrainedUntil(context.Background(), idle, time.Now().Add(time.Second), time.Millisecond) {
		t.Fatal("an idle engine before the deadline was not drained")
	}
	late := func(ctx context.Context) (int, int, error) {
		select {
		case <-time.After(60 * time.Millisecond):
			return 0, 0, nil
		case <-ctx.Done():
			return 0, 0, ctx.Err()
		}
	}
	if WaitDrainedUntil(context.Background(), late, time.Now().Add(20*time.Millisecond), time.Millisecond) {
		t.Fatal("an idle answer that arrived after the deadline counted")
	}
	// A reader that ignores its context and answers idle only after the deadline must not count either.
	ignoresCtx := func(context.Context) (int, int, error) { time.Sleep(60 * time.Millisecond); return 0, 0, nil }
	if WaitDrainedUntil(context.Background(), ignoresCtx, time.Now().Add(20*time.Millisecond), time.Millisecond) {
		t.Fatal("an idle answer received after the deadline counted")
	}
	busy := func(context.Context) (int, int, error) { return 1, 0, nil }
	if WaitDrainedUntil(context.Background(), busy, time.Now().Add(20*time.Millisecond), time.Millisecond) {
		t.Fatal("a busy engine counted as drained")
	}
}
