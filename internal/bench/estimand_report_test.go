package bench

import (
	"strings"
	"testing"
)

// estimandArm is the smallest arm the registered estimand will accept: a clean tail, enough completions and
// five per-repetition p99s. Anything the refusals look at is set explicitly, so a test that wants one of them
// to fire says so in its own body rather than relying on a zero value.
func estimandArm(name string, reps []float64) ArmSummary {
	return ArmSummary{
		Arm:                 name,
		TailSampleSize:      MinTailSamples,
		RepetitionCount:     len(reps),
		RepetitionTTFTMsP99: reps,
	}
}

// The report prints B, C and R, not just the row they can be derived from.
//
// The per-repetition block made the estimand derivable and left the arithmetic to the reader, which is not
// the same as the repository computing what the registration decided. The three field names are asserted
// because the amendment freezes them by name as status.result fields.
//
// Mutation that turns this red: delete the FormatRegisteredEstimand call from FormatReport.
func TestTheReportPrintsTheRegisteredEstimand(t *testing.T) {
	out := FormatReport([]ArmSummary{
		estimandArm(ArmR1, measuredR1),
		estimandArm(ArmShared, measuredShared),
	}, &Checks{}, 0.05)

	for _, want := range []string{"baselineP99Ms  174", "colocatedP99Ms 3998", "interferenceRatio 22.977"} {
		if !strings.Contains(out, want) {
			t.Errorf("the report does not print %q, so the registered estimand is still the reader's arithmetic:\n%s",
				want, out)
		}
	}
	if !strings.Contains(out, "No interval is published") {
		t.Errorf("the report prints a point estimate without saying no interval accompanies it:\n%s", out)
	}
}

// A censored arm is refused, with the reason printed instead of a ratio.
//
// A censored tail is a lower bound the design spec says to report as at-least-the-timeout. The median of a
// set of lower bounds is not the median of the quantity, so B and C would understate and R would be the
// quotient of two understatements. Reading 4 already refuses to divide by a censored R1, and the estimand has
// to refuse the same evidence or the two paths disagree about one run.
//
// Mutation that turns this red: drop the censored() loop from RegisteredEstimandFor.
func TestACensoredArmHasNoRegisteredEstimand(t *testing.T) {
	for _, tc := range []struct {
		name   string
		damage func(*ArmSummary)
	}{
		{"pooled censoring", func(s *ArmSummary) { s.Censored = true }},
		// The pool can read clean while one repetition was censored, and the per-repetition medians are
		// exactly where that repetition's lower bound lands.
		{"one repetition censored", func(s *ArmSummary) { s.AnyRepetitionCensored = true }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			shared := estimandArm(ArmShared, measuredShared)
			tc.damage(&shared)

			e := RegisteredEstimandFor(estimandArm(ArmR1, measuredR1), shared)
			if e.Valid {
				t.Fatalf("a %s arm produced a ratio of %.3f", tc.name, e.Ratio)
			}
			if !strings.Contains(e.InvalidReason, "censored") {
				t.Errorf("the refusal does not say the tail is censored: %s", e.InvalidReason)
			}

			out := FormatReport([]ArmSummary{estimandArm(ArmR1, measuredR1), shared}, &Checks{}, 0.05)
			if strings.Contains(out, "interferenceRatio") {
				t.Errorf("the report printed a ratio for a censored run:\n%s", out)
			}
			if !strings.Contains(out, "NOT COMPUTED") {
				t.Errorf("the report is silent about the missing estimand, which reads as not having looked:\n%s", out)
			}
		})
	}
}

// An arm below the sample floor is refused, because its p99 is the slowest survivor.
//
// MinTailSamples is derived rather than chosen: below it the nearest-rank p99 index points at the maximum.
//
// Mutation that turns this red: drop the TailSampleSize branch from RegisteredEstimandFor.
func TestAnArmBelowTheSampleFloorHasNoRegisteredEstimand(t *testing.T) {
	r1 := estimandArm(ArmR1, measuredR1)
	r1.TailSampleSize = MinTailSamples - 1

	e := RegisteredEstimandFor(r1, estimandArm(ArmShared, measuredShared))
	if e.Valid {
		t.Fatalf("an arm with %d completions produced a ratio of %.3f", r1.TailSampleSize, e.Ratio)
	}
	if !strings.Contains(e.InvalidReason, "below the") {
		t.Errorf("the refusal does not name the floor: %s", e.InvalidReason)
	}
}

// Evidence that is not the sharing matrix prints nothing at all.
//
// The M5-b gateway study has no R1/shared pair, and a refusal about a study this report is not reporting
// would be noise a reader has to learn to ignore -- which is how a real refusal gets ignored too.
//
// Mutation that turns this red: return a refusal instead of "" when either arm is absent.
func TestEvidenceWithoutTheTwoArmsPrintsNoEstimandBlock(t *testing.T) {
	out := FormatReport([]ArmSummary{
		estimandArm("static-cap", measuredR1),
		estimandArm("kv-aware", measuredShared),
	}, &Checks{}, 0.05)

	for _, unwanted := range []string{"Registered estimand", "NOT COMPUTED", "baselineP99Ms"} {
		if strings.Contains(out, unwanted) {
			t.Errorf("the report mentions %q for evidence that has no R1/shared pair:\n%s", unwanted, out)
		}
	}
}
