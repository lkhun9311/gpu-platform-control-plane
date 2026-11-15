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
