package bench

import (
	"math"
	"strings"
	"testing"
)

// The five R1 and shared per-repetition p99s the 2026-10-01 ten-cell run actually produced.
//
// They are the fixture rather than round numbers because the amendment's rounding rule only shows itself on
// values whose medians are not already integers, and because a test that reproduces the published figures
// fails if either the convention or the published figures move.
var (
	measuredR1     = []float64{174.078, 173.832, 174.297, 174.387, 174.034}
	measuredShared = []float64{3996.117, 4000.349, 4000.510, 3998.338, 3997.887}
)

// The ratio is computed from the ROUNDED integers, not from the unrounded medians.
//
// The third 2026-09-30 amendment chose this so "a reader dividing the two published integers" reproduces the
// published ratio, and it named the cost: the extra significant figures are discarded. The two answers differ
// in the third significant figure on the measured run, so this is a real choice and not a formatting detail.
//
// Mutation that turns this red: compute Ratio from medianOf(colocated)/medianOf(baseline).
func TestTheRatioComesFromTheRoundedIntegers(t *testing.T) {
	e := ComputeRegisteredEstimand(measuredR1, measuredShared)
	if !e.Valid {
		t.Fatalf("the estimand refused the measured run: %s", e.InvalidReason)
	}
	if e.BaselineP99Ms != 174 || e.ColocatedP99Ms != 3998 {
		t.Fatalf("B, C = %d, %d ms, want the published 174 and 3998", e.BaselineP99Ms, e.ColocatedP99Ms)
	}
	want := 3998.0 / 174.0
	if math.Abs(e.Ratio-want) > 1e-12 {
		t.Errorf("ratio = %.6f, want %.6f -- the quotient of the two published integers", e.Ratio, want)
	}
	// And it must NOT be the unrounded median ratio, which is the value this rule exists to reject.
	unrounded := medianOf(measuredShared) / medianOf(measuredR1)
	if math.Abs(e.Ratio-unrounded) < 1e-6 {
		t.Errorf("ratio = %.6f equals the unrounded median ratio %.6f, so the rounding rule is not applied",
			e.Ratio, unrounded)
	}
}

// The frozen resample count and seed are the ones the amendment borrowed, by value.
//
// Mutation that turns this red: change either constant.
func TestTheBootstrapDepthAndSeedAreTheFrozenOnes(t *testing.T) {
	if RegisteredBootstrapResamples != 10000 {
		t.Errorf("resamples = %d, want the frozen 10000", RegisteredBootstrapResamples)
	}
	if RegisteredBootstrapSeed != 11 {
		t.Errorf("seed = %d, want the frozen 11 -- the seed the traffic is generated with",
			RegisteredBootstrapSeed)
	}
}

// Unequal repetition counts are refused, and the refusal names both counts.
//
// A median over five repetitions divided by a median over four is a ratio of two different repetition sets.
// This package has already watched a truncated run satisfy the strictest gate in the design vacuously, so the
// estimand refuses rather than zipping the shorter length.
//
// Mutation that turns this red: truncate both slices to the shorter length and carry on.
func TestUnequalRepetitionCountsAreRefused(t *testing.T) {
	e := ComputeRegisteredEstimand(measuredR1, measuredShared[:4])
	if e.Valid {
		t.Fatalf("5 baseline and 4 colocated repetitions produced a ratio of %.3f", e.Ratio)
	}
	for _, want := range []string{"5", "4", "pair"} {
		if !strings.Contains(e.InvalidReason, want) {
			t.Errorf("the refusal does not mention %q, so a reader cannot tell which arm was short: %s",
				want, e.InvalidReason)
		}
	}
}

// A baseline median that rounds to zero is refused instead of dividing by it.
//
// Sub-millisecond baselines are not hypothetical for a stubbed or cached path, and the registered ratio
// divides the two ROUNDED integers, so the zero appears only after rounding -- the unrounded medians look
// perfectly usable.
//
// Mutation that turns this red: drop the b <= 0 branch.
func TestAZeroRoundedBaselineIsRefused(t *testing.T) {
	e := ComputeRegisteredEstimand([]float64{0.4, 0.3, 0.2}, []float64{10, 11, 12})
	if e.Valid {
		t.Fatalf("a baseline median of 0.3 ms produced a ratio of %.3f", e.Ratio)
	}
	if math.IsInf(e.Ratio, 0) || math.IsNaN(e.Ratio) {
		t.Errorf("the refused estimand carries a non-finite ratio %v instead of leaving it zero", e.Ratio)
	}
	if !strings.Contains(e.InvalidReason, "divides by zero") {
		t.Errorf("the refusal does not say why: %s", e.InvalidReason)
	}
	// The medians themselves are still reported, because they were measurable.
	if e.ColocatedP99Ms != 11 {
		t.Errorf("C = %d ms, want 11 -- a refused ratio does not make the medians unmeasured", e.ColocatedP99Ms)
	}
}

// The bootstrap resamples BLOCKS, so permuting one arm alone changes the interval.
//
// This is the test that tells a paired bootstrap from two independent ones. An unpaired implementation draws
// its own indices per arm, so it sees only each arm's multiset of values and a permutation of one arm cannot
// change its answer. A paired one breaks the (b_i, c_i) correspondence and must move.
//
// Mutation that turns this red: draw a separate index for rc[j].
func TestThePairingIsOverBlocksNotArms(t *testing.T) {
	b := []float64{100, 110, 120, 130, 140}
	c := []float64{200, 400, 600, 800, 1000}
	straight := PairedRatioCI(b, c, 2000, 5, 0.05)
	reversed := PairedRatioCI(b, []float64{1000, 800, 600, 400, 200}, 2000, 5, 0.05)
	if !straight.Valid || !reversed.Valid {
		t.Fatalf("one of the intervals is invalid: %q / %q", straight.InvalidReason, reversed.InvalidReason)
	}
	if straight.Lo == reversed.Lo && straight.Hi == reversed.Hi {
		t.Errorf("permuting the colocated arm alone left the interval at [%.4f, %.4f], so the resample is not paired",
			straight.Lo, straight.Hi)
	}
}

// The same seed gives the same interval, because the interval is part of a frozen protocol.
//
// Mutation that turns this red: seed the generator from the clock.
func TestThePairedIntervalIsReproducible(t *testing.T) {
	a := PairedRatioCI(measuredR1, measuredShared, 2000, RegisteredBootstrapSeed, 0.05)
	b := PairedRatioCI(measuredR1, measuredShared, 2000, RegisteredBootstrapSeed, 0.05)
	if a != b {
		t.Errorf("two runs at seed %d gave [%.6f, %.6f] and [%.6f, %.6f]",
			RegisteredBootstrapSeed, a.Lo, a.Hi, b.Lo, b.Hi)
	}
}

// One repetition per arm yields the point estimate marked INVALID, never a usable interval.
//
// Mutation that turns this red: return the degenerate interval with Valid true.
func TestASingleRepetitionIsNotAnInterval(t *testing.T) {
	ci := PairedRatioCI([]float64{174}, []float64{3998}, 2000, 11, 0.05)
	if ci.Valid {
		t.Fatalf("one repetition produced a valid interval [%.3f, %.3f]", ci.Lo, ci.Hi)
	}
	if ci.Lo != ci.Hi || math.Abs(ci.Lo-3998.0/174.0) > 1e-9 {
		t.Errorf("the degenerate bounds are [%.6f, %.6f], want both at the point estimate %.6f",
			ci.Lo, ci.Hi, 3998.0/174.0)
	}
	if ci.InvalidReason == "" {
		t.Error("the degenerate interval does not say why it is not an interval")
	}
}

// The interval brackets the ratio it is an interval for, on the measured run.
//
// This is a sanity check on the implementation rather than a registered requirement, and it is written against
// the UNROUNDED ratio on purpose: the interval is computed from unrounded medians, the published point
// estimate is not, and that mismatch is exactly what the unsettled rounding convention in RatioCI's comment is
// about. If this ever fails for the published ratio instead, the amendment is owed a decision, not this test a
// looser bound.
func TestTheIntervalBracketsTheUnroundedRatio(t *testing.T) {
	e := ComputeRegisteredEstimand(measuredR1, measuredShared)
	if !e.RatioCI.Valid {
		t.Fatalf("the interval is invalid: %s", e.RatioCI.InvalidReason)
	}
	unrounded := medianOf(measuredShared) / medianOf(measuredR1)
	if unrounded < e.RatioCI.Lo || unrounded > e.RatioCI.Hi {
		t.Errorf("the unrounded ratio %.6f falls outside [%.6f, %.6f]",
			unrounded, e.RatioCI.Lo, e.RatioCI.Hi)
	}
}
