package bench

import (
	"context"
	"strings"
	"testing"
)

// TestRunContextStopsTheLadderWhenTheSessionEnds: a deadline or a stop ends calibration as unresolved, never as an engine verdict.
func TestRunContextStopsTheLadderWhenTheSessionEnds(t *testing.T) {
	rule := versionAsyncDesign().Calibration
	ctx, cancel := context.WithCancel(context.Background())
	probes := 0
	res := rule.RunContext(ctx, func(_ context.Context, rate float64, ordinal int) RungClass {
		probes++
		if ordinal == 3 {
			cancel()
		}
		return RungStable
	})
	if res.Resolved || !strings.Contains(res.Reason, "session") {
		t.Fatalf("result %+v, want unresolved because the session stopped", res)
	}
	if probes != 3 {
		t.Fatalf("%d rungs ran, want none after the stop (3)", probes)
	}
	// The artifact lists exactly the rungs that have evidence, each with the class its probe recorded.
	// A made-up invalid rung would have no evidence file, and relabelling the cut rung would contradict its record.
	if len(res.Rungs) != 3 {
		t.Fatalf("the result lists %d rungs, want the 3 that ran: %+v", len(res.Rungs), res.Rungs)
	}
	for _, r := range res.Rungs {
		if r.Class != RungStable {
			t.Fatalf("rung %d is listed %s, but its probe returned %s", r.Ordinal, r.Class, RungStable)
		}
	}
}

// TestRunContextListsNoRungWhenTheSessionEndedFirst: a ladder whose context had ended runs and lists nothing.
func TestRunContextListsNoRungWhenTheSessionEndedFirst(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	res := versionAsyncDesign().Calibration.RunContext(ctx, func(context.Context, float64, int) RungClass {
		t.Fatal("a rung ran after the session ended")
		return RungInvalid
	})
	if res.Resolved || len(res.Rungs) != 0 || !strings.Contains(res.Reason, "session") {
		t.Fatalf("result %+v, want unresolved with no rung", res)
	}
}

// TestRunContextKeepsAResolvedLadder: a ladder that resolved before the context ended is not overwritten.
func TestRunContextKeepsAResolvedLadder(t *testing.T) {
	rule := versionAsyncDesign().Calibration
	res := rule.RunContext(context.Background(), func(_ context.Context, rate float64, _ int) RungClass {
		if rate <= 2 {
			return RungStable
		}
		return RungUnstable
	})
	if !res.Resolved {
		t.Fatalf("result %+v, want resolved", res)
	}
}

// TestRunContextDiscardsAProbeTheSessionInterrupted: a rung cut off by the session is no result, even the last one.
func TestRunContextDiscardsAProbeTheSessionInterrupted(t *testing.T) {
	rule := versionAsyncDesign().Calibration
	full := rule.Run(func(rate float64, _ int) RungClass {
		if rate <= 2 {
			return RungStable
		}
		return RungUnstable
	})
	last := len(full.Rungs)
	ctx, cancel := context.WithCancel(context.Background())
	res := rule.RunContext(ctx, func(_ context.Context, rate float64, ordinal int) RungClass {
		if ordinal == last {
			cancel()
		}
		if rate <= 2 {
			return RungStable
		}
		return RungUnstable
	})
	if res.Resolved || !strings.Contains(res.Reason, "session") {
		t.Fatalf("a ladder whose final confirmation the session cut off came out %+v", res)
	}
}
