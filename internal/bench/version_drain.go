package bench

import (
	"context"
	"errors"
	"time"
)

// CellDrainDeadline is when a cell's drain must have ended: its replay origin, plus its last scheduled arrival, plus the
// registered drain bound.
//
// Replay returns only once its last request has answered or timed out, which can be a whole request timeout after the
// last arrival; a drain timed from that return would grant the engine that much extra time.
// The origin is the moment the caller started the replay, read just before calling it, so the deadline is never later
// than the registered one.
func CellDrainDeadline(origin time.Time, trace []TraceRow, drain time.Duration) (time.Time, error) {
	if len(trace) == 0 {
		return time.Time{}, errors.New("a cell with no scheduled arrival has no drain")
	}
	last := trace[0].OffsetMs
	for _, r := range trace[1:] {
		last = max(last, r.OffsetMs)
	}
	return origin.Add(time.Duration(last)*time.Millisecond + drain), nil
}

// WaitDrainedUntil polls the engine until it reports nothing running or waiting, before deadline.
//
// Unlike WaitDrained, a deadline already passed is no drain at all, and no read is made: an idle answer after the
// deadline shows the engine drained late, which the registration treats as not drained (the engine is restarted).
// Every read runs under the deadline, and an answer that arrives after it does not count.
func WaitDrainedUntil(ctx context.Context, read EngineQueueReader, deadline time.Time, every time.Duration) bool {
	if !time.Now().Before(deadline) {
		return false
	}
	readCtx, cancel := context.WithDeadline(ctx, deadline)
	defer cancel()
	for {
		running, waiting, err := read(readCtx)
		if err == nil && running == 0 && waiting == 0 && time.Now().Before(deadline) {
			return true
		}
		left := time.Until(deadline)
		if left <= 0 {
			return false
		}
		select {
		case <-ctx.Done():
			return false
		case <-time.After(min(every, left)):
		}
	}
}
