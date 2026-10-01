package bench

import (
	"fmt"
	"math"
	"math/rand/v2"
	"sort"
)

// The design spec's third 2026-09-30 amendment froze the estimand and every convention it needs, and these
// two constants are the half of that freeze which is a number rather than a rule.
//
// They are named rather than inlined because the amendment borrowed each from somewhere else in the
// repository and said where: the resample count from the depth cmd/benchharness/power.go already drives
// BootstrapCI at, and the seed from the one hack/m5c-matrix.sh passes to gen-trace for every cell. A later
// change to either source is supposed to be visible as a change here too, which an inlined literal hides.
const (
	// RegisteredBootstrapResamples is the frozen resample count for the ratio interval.
	RegisteredBootstrapResamples = 10000

	// RegisteredBootstrapSeed is the frozen analysis seed, the same one the traffic is generated with.
	RegisteredBootstrapSeed = 11
)

// RegisteredEstimand is B, C and R as the third amendment defines them, plus the paired interval on R.
//
// Valid and InvalidReason describe the POINT ESTIMATE only, and RatioCI carries its own validity, because
// the two are different facts and the registration separates them: the seventh amendment publishes B, C and
// R for the 2026-10-01 run while deliberately publishing no interval. One flag covering both would make a
// run with a computable ratio and an unusable interval indistinguishable from a run with neither, which is
// the shape of defect this package keeps finding.
type RegisteredEstimand struct {
	// BaselineP99Ms is median(b_i) rounded half-up to integer milliseconds -- status.result.baselineP99Ms.
	BaselineP99Ms int64

	// ColocatedP99Ms is median(c_i) rounded the same way -- status.result.colocatedP99Ms.
	ColocatedP99Ms int64

	// Ratio is ColocatedP99Ms / BaselineP99Ms computed from those ROUNDED integers.
	//
	// The amendment chose the rounded divisor over the extra significant figures so that a reader dividing
	// the two published integers gets the published ratio. On the 2026-10-01 run the difference is visible in
	// the third significant figure: 3998/174 is 22.977 while the unrounded medians give 22.9686.
	Ratio float64

	// RatioCI is the paired repetition bootstrap interval on Ratio.
	//
	// ⚠️ Computed but NOT published. The amendment fixes the resample count, the seed, the median convention
	// and the percentile convention, and it does not say whether each of the 10000 replicates is rounded to
	// integer milliseconds the way the published fields are. At 174 ms a 1 ms quantisation is 0.6 percent, so
	// the choice moves the bounds and can place Ratio outside them. This field is computed from UNROUNDED
	// medians; until a dated amendment settles that, nothing may publish it. The seventh amendment already
	// decided this run publishes no interval, so nothing is blocked by leaving it unsettled.
	RatioCI CI

	// Valid says whether B, C and R could be computed at all.
	Valid bool

	// InvalidReason names why not, because the causes call for different actions.
	InvalidReason string
}

// ComputeRegisteredEstimand computes the registered estimand from each arm's per-repetition victim TTFT p99s.
//
// It takes the two slices rather than the two ArmSummary values so that it stays usable by a caller that has
// per-repetition tails and nothing else. The censoring refusal the registration needs therefore lives in
// RegisteredEstimandFor, which has the summaries to read it from -- a caller holding only the numbers cannot
// know whether they are p99s or lower bounds, and this function must not pretend it can.
//
// baseline is b_i (the contender absent) and colocated is c_i (the contender present), indexed so that
// position i is the same repetition in both. The caller owns that alignment: the schedule records the
// repetition identity (hack/m5c-matrix.sh builds cells as arm|arm|rep|rate|weight|0), so the pairing is read
// from the run rather than inferred from two slices happening to have equal length.
//
// Unequal lengths are refused rather than truncated or zipped. A median over five repetitions and a median
// over four is a ratio of two different repetition sets, which is not the registered R, and this package has
// already been bitten once by a truncated run quietly satisfying a gate instead of tripping it.
func ComputeRegisteredEstimand(baseline, colocated []float64) RegisteredEstimand {
	switch {
	case len(baseline) == 0 || len(colocated) == 0:
		return RegisteredEstimand{InvalidReason: fmt.Sprintf(
			"the registered estimand needs both arms' per-repetition p99s and has %d baseline and %d colocated",
			len(baseline), len(colocated))}
	case len(baseline) != len(colocated):
		return RegisteredEstimand{InvalidReason: fmt.Sprintf(
			"the estimand pairs repetitions, so the arms must have the same count, and these have %d baseline and %d colocated",
			len(baseline), len(colocated))}
	}

	b := roundToMs(medianOf(baseline))
	c := roundToMs(medianOf(colocated))
	if b <= 0 {
		return RegisteredEstimand{BaselineP99Ms: b, ColocatedP99Ms: c, InvalidReason: fmt.Sprintf(
			"the baseline median rounds to %d ms, so the registered ratio divides by zero; report the medians and no ratio",
			b)}
	}

	return RegisteredEstimand{
		BaselineP99Ms:  b,
		ColocatedP99Ms: c,
		Ratio:          float64(c) / float64(b),
		RatioCI:        PairedRatioCI(baseline, colocated, RegisteredBootstrapResamples, RegisteredBootstrapSeed, 0.05),
		Valid:          true,
	}
}

// PairedRatioCI is the registered interval: resample complete (b_i, c_i) blocks with replacement, recompute
// both medians and their ratio, and take the alpha/2 and 1-alpha/2 percentiles of the resulting ratios.
//
// The pairing is the whole point. Drawing an index once and reading BOTH arms at it keeps a repetition's two
// tails together, which is what makes the interval bound the ratio rather than the quotient of two
// independently resampled arms -- those are different quantities whenever the repetitions are correlated,
// and in this study they are: one trace replayed five times.
//
// Percentiles use the same nearest-rank helper as the per-repetition p99s inside the interval, so one rule
// decides every quantile in the number.
func PairedRatioCI(baseline, colocated []float64, iterations int, seed int64, alpha float64) CI {
	n := len(baseline)
	if n == 0 || n != len(colocated) {
		return CI{InvalidReason: fmt.Sprintf(
			"a paired bootstrap needs equally many repetitions in both arms and has %d and %d",
			len(baseline), len(colocated))}
	}
	if n == 1 {
		// One repetition cannot bound its own variance, so this degenerates to the point estimate.
		//
		// It is returned for display and marked invalid for the same reason BootstrapCI does: a degenerate
		// pair of identical bounds answers "does the interval clear 1.0" vacuously, and a caller cannot tell
		// it from a real interval unless the value itself says so.
		r := 0.0
		if baseline[0] != 0 {
			r = colocated[0] / baseline[0]
		}
		return CI{Lo: r, Hi: r, InvalidReason: "one repetition per arm cannot bound its own variance, so this is the point estimate and not an interval"}
	}

	src := rand.NewPCG(uint64(seed), uint64(seed)^0x9e3779b97f4a7c15)
	rng := rand.New(src)

	ratios := make([]float64, 0, iterations)
	rb := make([]float64, n)
	rc := make([]float64, n)
	for range iterations {
		for j := range n {
			k := rng.IntN(n)
			rb[j] = baseline[k]
			rc[j] = colocated[k]
		}
		mb := medianOf(rb)
		if mb == 0 {
			// A resample whose baseline median is zero has no ratio. Dropping it rather than substituting a
			// zero keeps the percentiles over ratios that exist; the count of survivors is checked below so
			// that an all-dropped distribution cannot read as an interval.
			continue
		}
		ratios = append(ratios, medianOf(rc)/mb)
	}
	if len(ratios) < 2 {
		return CI{InvalidReason: fmt.Sprintf(
			"only %d of %d resamples had a non-zero baseline median, which is too few to take percentiles over",
			len(ratios), iterations)}
	}

	sort.Float64s(ratios)
	return CI{
		Lo:    percentile(ratios, alpha/2),
		Hi:    percentile(ratios, 1-alpha/2),
		Valid: true,
	}
}

// roundToMs rounds a fractional-millisecond latency half-up to an integer, which is what the amendment
// specifies for baselineP99Ms and colocatedP99Ms.
//
// math.Round is half-away-from-zero, and that is the same thing as half-up here because a TTFT p99 cannot be
// negative. The distinction is recorded rather than assumed away: if this ever receives a signed quantity,
// half-away-from-zero is NOT the registered rule and the caller is in the wrong function.
func roundToMs(ms float64) int64 {
	if ms < 0 {
		return 0
	}
	return int64(math.Round(ms))
}

// RegisteredEstimandFor is ComputeRegisteredEstimand with the refusals that need the whole summary.
//
// A censored tail is a LOWER BOUND, not a p99: the design spec says to report it as at-least-the-timeout and
// never to drop it. The median of a set of lower bounds is not the median of the quantity, so B and C would
// be understatements wearing a measurement's name and R would be the ratio of two of them. This package
// already refuses to divide by a censored R1 in reading 4 for the same reason, and the registered estimand
// has to carry the same refusal or the two paths disagree about the same evidence.
//
// censored() is the predicate rather than ArmSummary.Censored alone, because a run can pool clean while one
// repetition was censored -- and the per-repetition medians are exactly where that repetition's lower bound
// would land.
func RegisteredEstimandFor(baseline, colocated ArmSummary) RegisteredEstimand {
	for _, a := range [2]ArmSummary{baseline, colocated} {
		if censored(a) {
			return RegisteredEstimand{InvalidReason: fmt.Sprintf(
				"%s has a censored tail, so its per-repetition p99s are lower bounds and their median is not the registered B or C",
				a.Arm)}
		}
		if a.TailSampleSize < MinTailSamples {
			return RegisteredEstimand{InvalidReason: fmt.Sprintf(
				"%s completed %d premium requests, below the %d a nearest-rank p99 needs, so its tail is the slowest survivor rather than a percentile",
				a.Arm, a.TailSampleSize, MinTailSamples)}
		}
	}
	return ComputeRegisteredEstimand(baseline.RepetitionTTFTMsP99, colocated.RepetitionTTFTMsP99)
}

// FormatRegisteredEstimand renders B, C and R for the report, or the reason there is none.
//
// It picks the two arms by name INSIDE this function rather than in FormatReport, so the report's own
// complexity does not grow for a block that is about one study's two arms. An empty string means this
// evidence is not the sharing matrix at all -- the M5-b gateway arms have no R1/shared pair -- and the report
// prints nothing rather than a refusal about a study it is not reporting.
func FormatRegisteredEstimand(summaries []ArmSummary) string {
	var r1, shared ArmSummary
	var haveR1, haveShared bool
	for _, s := range summaries {
		switch s.Arm {
		case ArmR1:
			r1, haveR1 = s, true
		case ArmShared:
			shared, haveShared = s, true
		}
	}
	if !haveR1 || !haveShared {
		return ""
	}

	e := RegisteredEstimandFor(r1, shared)
	if !e.Valid {
		return fmt.Sprintf("\nRegistered estimand: NOT COMPUTED -- %s\n", e.InvalidReason)
	}
	return fmt.Sprintf(
		"\nRegistered estimand (design spec, third 2026-09-30 amendment)\n"+
			"  baselineP99Ms  %d   colocatedP99Ms %d   interferenceRatio %.3f\n"+
			"  R is the quotient of the two integers above, which is what the amendment froze so that a\n"+
			"  reader dividing them reproduces it. No interval is published; see the seventh amendment.\n",
		e.BaselineP99Ms, e.ColocatedP99Ms, e.Ratio)
}
