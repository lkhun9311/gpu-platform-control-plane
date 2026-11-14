package bench

import (
	"math"
	"strings"
	"testing"
)

// stableRung is an observation that meets every criterion at rate r over a 180 s window.
func stableRung(r float64) RungObservation {
	a := int(r * 180)
	return RungObservation{
		OfferedRate: r, WindowSeconds: 180, StartedDrained: true,
		Arrivals: a, Departures: a, OutstandingStart: 3, OutstandingEnd: 3, OutstandingSlopePerSec: 0,
		Failures: 0, UnresolvedAtDrain: 0,
	}
}

// TestClassifyRung checks each criterion separately, and that reliability is reported apart from throughput.
func TestClassifyRung(t *testing.T) {
	rule := versionAsyncDesign().Calibration
	for _, c := range []struct {
		name   string
		mutate func(o *RungObservation)
		want   RungClass
	}{
		{"stable", func(*RungObservation) {}, RungStable},
		{"not started drained", func(o *RungObservation) { o.StartedDrained = false }, RungInvalid},
		{"no arrivals", func(o *RungObservation) { o.Arrivals, o.Departures = 0, 0 }, RungInvalid},
		{"departures lag arrivals by 3%", func(o *RungObservation) { o.Departures = o.Arrivals * 97 / 100 }, RungUnstable},
		{"departures lag arrivals by 1%", func(o *RungObservation) { o.Departures = o.Arrivals * 99 / 100 }, RungStable},
		// Attack item 2: medians of 20 s and 24 s passed the old rule while the backlog grew.
		{"outstanding work grows", func(o *RungObservation) { o.OutstandingEnd = o.OutstandingStart + 40 }, RungUnstable},
		{"queue trend rises", func(o *RungObservation) { o.OutstandingSlopePerSec = 0.05 * o.OfferedRate }, RungUnstable},
		{"a request never resolves by the drain deadline", func(o *RungObservation) { o.UnresolvedAtDrain = 1 }, RungUnstable},
		// Attack item 2: one rare failure no longer decides capacity; reliability is its own class.
		{"one failure in 720", func(o *RungObservation) { o.Failures = 1 }, RungStable},
		{"failures over the guardrail", func(o *RungObservation) { o.Failures = o.Arrivals / 100 }, RungUnreliable},
	} {
		o := stableRung(4)
		c.mutate(&o)
		if got := rule.ClassifyRung(o); got != c.want {
			t.Errorf("%s: %s, want %s", c.name, got, c.want)
		}
	}
}

// capacityProbe answers stable at or below capacity and unstable above it, recording every rung.
func capacityProbe(capacity float64, log *[]float64) func(rate float64, ordinal int) RungClass {
	return func(rate float64, _ int) RungClass {
		*log = append(*log, rate)
		if rate <= capacity {
			return RungStable
		}
		return RungUnstable
	}
}

// TestCalibrationResolvesWithinTheBracket is attack item 3: at a capacity of 8 and 12 req/s the old ladder ended unrefined.
func TestCalibrationResolvesWithinTheBracket(t *testing.T) {
	rule := versionAsyncDesign().Calibration
	for _, capacity := range []float64{0.3, 1, 8, 12, 19.5, 30} {
		var rungs []float64
		res := rule.Run(capacityProbe(capacity, &rungs))
		if !res.Resolved {
			t.Errorf("capacity %v: unresolved (%s) after %v", capacity, res.Reason, rungs)
			continue
		}
		if res.Rate > capacity || res.Rate < capacity/rule.TargetRatio {
			t.Errorf("capacity %v: selected %v, want within a factor %v below it", capacity, res.Rate, rule.TargetRatio)
		}
		if len(rungs) > rule.MaxRungs() {
			t.Errorf("capacity %v: %d rungs, over the bound %d", capacity, len(rungs), rule.MaxRungs())
		}
		// The selected rate is confirmed on fresh traces, not taken from one lucky rung.
		confirmations := 0
		for _, r := range rungs {
			if r == res.Rate {
				confirmations++
			}
		}
		if confirmations < 1+rule.Confirmations {
			t.Errorf("capacity %v: selected rate run %d times, want at least %d", capacity, confirmations, 1+rule.Confirmations)
		}
	}
}

// TestCalibrationStopsWhenUnresolved checks every way the ladder can fail ends in an explicit stop, never a number.
func TestCalibrationStopsWhenUnresolved(t *testing.T) {
	rule := versionAsyncDesign().Calibration
	for name, c := range map[string]struct {
		probe func(rate float64, ordinal int) RungClass
		want  string
	}{
		"no upper bracket":                          {func(float64, int) RungClass { return RungStable }, "upper"},
		"nothing stable even at the fallback rates": {func(float64, int) RungClass { return RungUnstable }, "lower"},
		"unreliable at every rate":                  {func(float64, int) RungClass { return RungUnreliable }, "reliab"},
		"invalid twice in a row":                    {func(float64, int) RungClass { return RungInvalid }, "invalid"},
		"confirmation keeps failing": {func() func(float64, int) RungClass {
			seen := map[float64]int{}
			return func(rate float64, _ int) RungClass {
				seen[rate]++
				if rate <= 5 && seen[rate] == 1 {
					return RungStable
				}
				return RungUnstable
			}
		}(), "confirm"},
	} {
		res := rule.Run(c.probe)
		if res.Resolved {
			t.Errorf("%s: resolved at %v", name, res.Rate)
			continue
		}
		if !strings.Contains(strings.ToLower(res.Reason), c.want) {
			t.Errorf("%s: reason %q does not mention %q", name, res.Reason, c.want)
		}
		if res.Rate != 0 {
			t.Errorf("%s: an unresolved calibration still reported rate %v", name, res.Rate)
		}
	}
}

// TestCalibrationRungOrdinalsAreFresh checks each rung gets its own ordinal, so confirmations replay new traces.
func TestCalibrationRungOrdinalsAreFresh(t *testing.T) {
	rule := versionAsyncDesign().Calibration
	seen := map[int]bool{}
	rule.Run(func(rate float64, ordinal int) RungClass {
		if seen[ordinal] {
			t.Errorf("ordinal %d reused", ordinal)
		}
		seen[ordinal] = true
		if rate <= 6 {
			return RungStable
		}
		return RungUnstable
	})
	if len(seen) == 0 {
		t.Fatal("no rungs ran")
	}
	if s := CalibrationSeed(3); s != 2026111503 {
		t.Errorf("rung 3 seed = %d, want 2026111503", s)
	}
}

// TestOutstandingSlope checks the least-squares trend the queue criterion reads.
func TestOutstandingSlope(t *testing.T) {
	if got := OutstandingSlope([]int{0, 1, 2, 3, 4}, 1); math.Abs(got-1) > 1e-12 {
		t.Errorf("slope = %v, want 1", got)
	}
	if got := OutstandingSlope([]int{5, 5, 5}, 2); got != 0 {
		t.Errorf("flat slope = %v, want 0", got)
	}
	if got := OutstandingSlope([]int{1}, 1); !math.IsNaN(got) {
		t.Errorf("one sample gave slope %v, want NaN", got)
	}
}
