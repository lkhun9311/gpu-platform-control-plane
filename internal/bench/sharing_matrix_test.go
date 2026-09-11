/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package bench

import (
	"strings"
	"testing"
)

// healthyArm builds an arm that clears every floor, so each test below changes exactly one thing.
//
// Built rather than written out because the readings share a lot of preconditions: an arm has to have a
// hundred premium completions, an uncensored tail, a premium TPOT and a contender disposition before any
// bar can be applied to it, and a test that spelled all of that out per case would hide which field it was
// actually about.
func healthyArm(name string, ttftP99, tpotP99 float64, contenderTokens int64) ArmSummary {
	// OutputTokens is set, and it is not decoration: shareOf divides by it, so a fixture that left it at
	// zero would make every tenant's share zero and every arm unscorable -- the tests would then pass or
	// fail for a reason that has nothing to do with what they are about.
	return ArmSummary{
		Arm:          name,
		Total:        4000,
		Completed:    3900,
		OutputTokens: 50_000 + contenderTokens,
		// ActiveSeconds is set because reading 1's price is the PREMIUM tenant's tokens per second, which is
		// derived from per-tenant tokens and the arm's own sending time rather than read off the arm's
		// aggregate rate. An arm without it has no premium throughput to report.
		ActiveSeconds:         1000,
		TTFTMsP99:             ttftP99,
		TailSampleSize:        3000,
		RepetitionCount:       3,
		RepetitionTTFTMsP99:   []float64{ttftP99 - 1, ttftP99, ttftP99 + 1},
		OutputTokensPerSecond: 40,
		TPOTMsP99ByTenant:     map[string]float64{PremiumTenant: tpotP99},
		OutputTokensByTenant:  map[string]int64{PremiumTenant: 50_000, NoisyTenant: contenderTokens},
		DispositionByTenant: map[string]Disposition{
			NoisyTenant: {Offered: 300, Completed: 250, TimedOut: 50},
		},
	}
}

// healthyMatrix is a run where the load worked and the split arms improved on the control without reaching
// the bar -- the reading-5 shape, chosen as the baseline because it is the one every INVALID reading has to
// stay silent about.
func healthyMatrix() SharingArms {
	r1 := healthyArm(ArmR1, 67.3, 17.8, 0)
	r1.OutputTokensPerSecond = 46
	r1.DispositionByTenant = map[string]Disposition{}
	return SharingArms{
		R1:     r1,
		Shared: healthyArm(ArmShared, 1400, 80, 40_000),
		Sharing: []ArmSummary{
			healthyArm(ArmTimeSlicing, 900, 60, 38_000),
			healthyArm(ArmMPS, 1000, 62, 37_000),
		},
	}
}

func sharingReadingByID(t *testing.T, res SharingResult, id string) PoPReading {
	t.Helper()
	for _, r := range res.Readings {
		if r.ID == id {
			return r
		}
	}
	t.Fatalf("reading %s was not evaluated at all; the readings present were %v", id, idsOf(res))
	return PoPReading{}
}

func idsOf(res SharingResult) []string {
	out := make([]string, 0, len(res.Readings))
	for _, r := range res.Readings {
		out = append(out, r.ID)
	}
	return out
}

// THE ORDERING TRAP, and it is the reason reading 1 has a third clause.
//
// Reading 2's condition -- meets both bars AND starves the contender -- was a strict subset of reading 1's
// two-clause form. With "the first that fires is the answer", an arm that bought its tail by refusing the
// other tenant's work would have been reported as the deliverable and reading 2 would never have been
// reached. The pre-registration was corrected before any card was rented; this is what holds the correction.
func TestAnArmThatBuysItsTailByStarvingTheContenderIsNegativeNotPositive(t *testing.T) {
	m := healthyMatrix()
	// Meets both bars, and takes the contender's work to do it: a fifth of the control's output, and the
	// ledger shows the loss as refusals rather than as delay.
	starving := healthyArm(ArmTimeSlicing, 100, 20, 5_000)
	starving.DispositionByTenant = map[string]Disposition{
		NoisyTenant: {Offered: 300, Completed: 120, Rejected: 170, TimedOut: 10},
	}
	m.Sharing = []ArmSummary{starving}

	res := EvaluateSharingMatrix(m, PremiumTenant, NoisyTenant)

	one := sharingReadingByID(t, res, "1")
	if one.Fired {
		t.Errorf("reading 1 fired POSITIVE for an arm that met the bars by refusing 170 of the contender's "+
			"requests: %s", one.Detail)
	}
	two := sharingReadingByID(t, res, "2")
	if !two.Fired {
		t.Fatalf("reading 2 did not fire for a starving arm, so the outcome has no reading at all: %s", two.Detail)
	}
	if !strings.HasPrefix(res.Answer, "2") {
		t.Errorf("the answer is %q; an arm that starves the contender to meet the bars is reading 2, the NEGATIVE one", res.Answer)
	}
	// The detail has to show the ledger, because the pre-registration forbids calling a smaller share
	// starvation without it.
	if !strings.Contains(two.Detail, "170") {
		t.Errorf("reading 2's detail does not carry the rejection count that makes it starvation rather than delay: %s", two.Detail)
	}
}

// The same arm, losing the same share to DELAY rather than refusal, is not this reading.
func TestAContenderThatWasMerelyDelayedIsNotStarvation(t *testing.T) {
	m := healthyMatrix()
	delayed := healthyArm(ArmTimeSlicing, 100, 20, 5_000)
	delayed.DispositionByTenant = map[string]Disposition{
		NoisyTenant: {Offered: 300, Completed: 120, TimedOut: 180},
	}
	m.Sharing = []ArmSummary{delayed}

	res := EvaluateSharingMatrix(m, PremiumTenant, NoisyTenant)

	if two := sharingReadingByID(t, res, "2"); two.Fired {
		t.Errorf("reading 2 fired on a share that fell to timeouts with no rejections; the pre-registration "+
			"says delay and deletion are different findings and only the second is this reading: %s", two.Detail)
	}
	if one := sharingReadingByID(t, res, "1"); !one.Fired {
		t.Errorf("reading 1 did not fire for an arm that met both bars without refusing any of the "+
			"contender's work: %s", one.Detail)
	}
}

// An arm whose premium requests ALL timed out must not clear the bars with a zero tail.
//
// percentile() returns 0 for an empty slice, so 0/67.3 clears a 2x bar and 0 clears a 1.25x one. The
// price-of-protection evaluator records this as the worst wrong number it could print: the arm that starved
// the protected tenant completely reported as the one that protected it.
func TestAnArmWithNoPremiumTailIsNotScoredAgainstTheBars(t *testing.T) {
	m := healthyMatrix()
	collapsed := healthyArm(ArmTimeSlicing, 0, 0, 38_000)
	collapsed.TPOTMsP99ByTenant = map[string]float64{}
	collapsed.TailSampleSize = 0
	m.Sharing = []ArmSummary{collapsed}

	res := EvaluateSharingMatrix(m, PremiumTenant, NoisyTenant)

	// It is caught before the bars are ever applied: an arm with no completions is reading 4b's business.
	fourB := sharingReadingByID(t, res, "4b")
	if !fourB.Fired {
		t.Fatalf("reading 4b did not fire for an arm with zero premium completions: %s", fourB.Detail)
	}
	if res.Answer != "4b" {
		t.Errorf("the answer is %q; an arm that completed nothing makes the run INVALID through reading 4b", res.Answer)
	}
	for _, r := range res.Readings {
		if r.ID == "1" && r.Fired {
			t.Error("reading 1 fired POSITIVE beneath an INVALID reading, which is the wrong number this " +
				"whole file exists to refuse")
		}
	}
}

// R1 has no contender by construction, so reading 4b's contender floor must not be applied to it.
//
// Applying it would fire INVALID on every run that was working perfectly, which is the failure mode of a
// guard that cannot tell "absent by design" from "absent because something broke".
func TestReadingFourBDoesNotDemandAContenderOfTheIsolatedBaseline(t *testing.T) {
	m := healthyMatrix()
	if len(m.R1.DispositionByTenant) != 0 {
		t.Fatal("this test's premise is that R1 carries no contender disposition")
	}

	res := EvaluateSharingMatrix(m, PremiumTenant, NoisyTenant)

	if fourB := sharingReadingByID(t, res, "4b"); fourB.Fired {
		t.Errorf("reading 4b fired because the isolated baseline has no contender, which is what an "+
			"isolated baseline IS: %s", fourB.Detail)
	}
}

// Reading 4 guards the low side: a control that produced no contention is not a study of protection.
func TestReadingFourFiresWhenTheControlBarelyContends(t *testing.T) {
	m := healthyMatrix()
	m.Shared = healthyArm(ArmShared, 200, 20, 40_000) // 3.0x R1, under the 5x threshold

	res := EvaluateSharingMatrix(m, PremiumTenant, NoisyTenant)

	four := sharingReadingByID(t, res, "4")
	if !four.Fired {
		t.Fatalf("reading 4 did not fire at 3x R1 against a 5x threshold: %s", four.Detail)
	}
	if len(res.Readings) != 1 {
		t.Errorf("evaluation continued past an INVALID reading and produced %v; everything below it would be "+
			"scoring comparisons that do not mean anything", idsOf(res))
	}
}

// Reading 4c fires on a RECORDED refusal, and declines on mere absence.
func TestReadingFourCSeparatesARefusalFromAnAbsence(t *testing.T) {
	t.Run("a recorded refusal fires it", func(t *testing.T) {
		m := healthyMatrix()
		m.Sharing = []ArmSummary{healthyArm(ArmTimeSlicing, 900, 60, 38_000)}
		m.Refused = map[string]string{ArmMPS: "the MPS control daemon never became ready"}

		res := EvaluateSharingMatrix(m, PremiumTenant, NoisyTenant)
		fourC := sharingReadingByID(t, res, "4c")
		if !fourC.Fired {
			t.Fatalf("reading 4c did not fire on a recorded refusal: %s", fourC.Detail)
		}
		if fourC.Cell != ArmMPS {
			t.Errorf("reading 4c names %q rather than the arm that was refused", fourC.Cell)
		}
	})

	t.Run("bare absence is not evaluable", func(t *testing.T) {
		m := healthyMatrix()
		m.Sharing = []ArmSummary{healthyArm(ArmTimeSlicing, 900, 60, 38_000)}

		res := EvaluateSharingMatrix(m, PremiumTenant, NoisyTenant)
		fourC := sharingReadingByID(t, res, "4c")
		if fourC.Fired {
			t.Errorf("reading 4c fired on an arm that is merely absent; absence is equally consistent with "+
				"an interruption or an operator running a subset, and calling it a sharing-mode failure "+
				"attributes a result to a cause the evidence does not establish: %s", fourC.Detail)
		}
		if !fourC.NotEvaluable {
			t.Errorf("reading 4c reported a plain negative for an arm it has no evidence about: %s", fourC.Detail)
		}
	})
}

// Reading 5 is the outcome the previous study had no name for, and it must actually fire.
func TestReadingFiveFiresOnARealImprovementThatMissesTheBar(t *testing.T) {
	res := EvaluateSharingMatrix(healthyMatrix(), PremiumTenant, NoisyTenant)

	if one := sharingReadingByID(t, res, "1"); one.Fired {
		t.Fatalf("reading 1 fired at 13x R1 against a 2x bar: %s", one.Detail)
	}
	if three := sharingReadingByID(t, res, "3"); three.Fired {
		t.Fatalf("reading 3 fired despite a 500 ms improvement against a 2 ms spread: %s", three.Detail)
	}
	five := sharingReadingByID(t, res, "5")
	if !five.Fired {
		t.Fatalf("reading 5 did not fire; the evidence would then land in the same gap the previous study's "+
			"readings left, which is exactly what this reading was added to close: %s", five.Detail)
	}
	if !strings.Contains(five.Detail, "against a 2.0x bar") {
		t.Errorf("reading 5 does not report the remaining distance to the bar, which is the half of it that "+
			"makes a partial result useful: %s", five.Detail)
	}
}

// Reading 3 fires when no arm beats the control by more than the control's own noise.
func TestReadingThreeFiresWhenNoArmBeatsTheControlsOwnSpread(t *testing.T) {
	m := healthyMatrix()
	m.Shared = healthyArm(ArmShared, 1400, 80, 40_000)
	m.Shared.RepetitionTTFTMsP99 = []float64{1200, 1400, 1600} // spread 400 ms
	m.Sharing = []ArmSummary{healthyArm(ArmTimeSlicing, 1350, 78, 38_000)}

	res := EvaluateSharingMatrix(m, PremiumTenant, NoisyTenant)

	three := sharingReadingByID(t, res, "3")
	if !three.Fired {
		t.Fatalf("reading 3 did not fire on a 50 ms improvement against a 400 ms spread: %s", three.Detail)
	}
	if five := sharingReadingByID(t, res, "5"); five.Fired {
		t.Error("reading 5 also fired; an improvement inside the control's own noise is reading 3, and two " +
			"readings claiming one outcome is the overlap this study was corrected for")
	}
}

// One repetition means there is no spread, and the readings that compare against one must decline.
func TestTheSpreadReadingsDeclineAtOneRepetition(t *testing.T) {
	m := healthyMatrix()
	m.Shared.RepetitionTTFTMsP99 = []float64{1400}
	m.Shared.RepetitionCount = 1

	res := EvaluateSharingMatrix(m, PremiumTenant, NoisyTenant)

	for _, id := range []string{"3", "5"} {
		r := sharingReadingByID(t, res, id)
		if r.Fired {
			t.Errorf("reading %s fired against a spread that does not exist at one repetition: %s", id, r.Detail)
		}
		if !r.NotEvaluable {
			t.Errorf("reading %s reported a plain negative rather than declining; with one repetition it is "+
				"comparing against noise nobody measured: %s", id, r.Detail)
		}
	}
}

// Reading 1's tie-break goes to timeSlicing, because MPS needs a daemon that can be absent.
func TestAnExactTieGoesToTimeSlicing(t *testing.T) {
	m := healthyMatrix()
	ts := healthyArm(ArmTimeSlicing, 100, 20, 38_000)
	mps := healthyArm(ArmMPS, 100, 20, 38_000)
	// MPS listed first, so a naive "last one wins" or "first one wins" would pick it.
	m.Sharing = []ArmSummary{mps, ts}

	res := EvaluateSharingMatrix(m, PremiumTenant, NoisyTenant)

	one := sharingReadingByID(t, res, "1")
	if !one.Fired {
		t.Fatalf("reading 1 did not fire for two arms that both met the bars: %s", one.Detail)
	}
	if one.Cell != ArmTimeSlicing {
		t.Errorf("an exact tie went to %q; the pre-registration breaks ties toward timeSlicing because MPS "+
			"needs a control daemon that can be absent and the simpler mechanism is the smaller claim", one.Cell)
	}
}

// The deliverable has to carry its price, because a pass/fail line reports a tenth and a half identically.
func TestReadingOneReportsWhatTheProtectionCost(t *testing.T) {
	m := healthyMatrix()
	won := healthyArm(ArmTimeSlicing, 100, 20, 38_000)
	// The same premium tokens over twice the time: half R1's premium throughput. The arm's AGGREGATE rate is
	// deliberately left high, because reporting that instead of the premium tenant's is the defect this
	// test pins -- an arm serving premium at half speed while a contender fills the gap reads as 1.00 if the
	// aggregate is used.
	won.ActiveSeconds = 2000
	won.OutputTokensPerSecond = 999
	m.Sharing = []ArmSummary{won}

	res := EvaluateSharingMatrix(m, PremiumTenant, NoisyTenant)

	one := sharingReadingByID(t, res, "1")
	if !one.Fired {
		t.Fatalf("reading 1 did not fire: %s", one.Detail)
	}
	if !strings.Contains(one.Detail, "0.50 of R1's throughput") {
		t.Errorf("reading 1's detail does not carry the premium tenant's throughput as a fraction of R1's, "+
			"which the pre-registration requires in the write-up's first sentence: %s", one.Detail)
	}
}

// A run where nothing fired must say so as a gap rather than printing a verdict.
func TestNoReadingFiringIsReportedAsAGapRatherThanAnAnswer(t *testing.T) {
	m := healthyMatrix()
	// Every arm unscorable for a reason 4b does not catch: a censored tail.
	censored := healthyArm(ArmTimeSlicing, 900, 60, 38_000)
	censored.Censored = true
	m.Sharing = []ArmSummary{censored}

	res := EvaluateSharingMatrix(m, PremiumTenant, NoisyTenant)
	out := FormatSharingMatrix(res)

	if res.Answer != "" && !strings.Contains(res.Answer, "INVALID") {
		t.Logf("answer: %q", res.Answer)
	}
	if strings.Contains(out, "[FIRED] 1 ") {
		t.Error("reading 1 fired on an arm whose tail is a lower bound rather than a p99")
	}
	if !strings.Contains(out, "censored") && !strings.Contains(out, "INVALID") {
		t.Errorf("the report neither names the censored tail nor declares the run invalid, so a reader cannot "+
			"tell whether the readings looked at everything or at nothing:\n%s", out)
	}
}

// An arm with a healthy premium tail but NO premium TPOT must not clear the stream bar with a zero.
//
// This is the same defect as a missing TTFT and it hides better, because reading 4b does not catch it:
// TailSampleSize counts completions and can be well over the floor while every stream broke after its first
// token, leaving TPOTMsP99ByTenant without an entry. The ratio is then 0/17.8, which clears a 1.25x bar the
// way an empty tail clears a 2x one -- so the arm whose streams all died would be scored as the one that
// kept them alive.
//
// It exists because removing the arm's own numerators from the computable check left every other test in
// this file green. A guard nothing exercises is a guard that will be deleted by someone tidying up.
func TestAnArmWithNoPremiumTPOTIsNotScoredAgainstTheStreamBar(t *testing.T) {
	m := healthyMatrix()
	broken := healthyArm(ArmTimeSlicing, 100, 0, 38_000)
	broken.TPOTMsP99ByTenant = map[string]float64{} // first tokens arrived; no stream produced a second
	m.Sharing = []ArmSummary{broken}

	res := EvaluateSharingMatrix(m, PremiumTenant, NoisyTenant)

	if fourB := sharingReadingByID(t, res, "4b"); fourB.Fired {
		t.Fatalf("this test's premise is that 4b does NOT catch this arm, and it did: %s", fourB.Detail)
	}
	one := sharingReadingByID(t, res, "1")
	if one.Fired {
		t.Errorf("reading 1 fired POSITIVE for an arm with no premium TPOT at all; 0/17.8 clears the 1.25x "+
			"stream bar, so the arm whose streams all broke would be reported as the one that protected "+
			"them: %s", one.Detail)
	}
	if !strings.Contains(one.Detail, "no premium TPOT") {
		t.Errorf("reading 1 did not say WHY it could not score the arm, so a reader cannot tell it from a "+
			"reading that looked and found nothing: %s", one.Detail)
	}
}

// Reading 2 asks about the contender's OUTPUT, not its share of an arm's total.
//
// The two come apart exactly when the split costs both tenants alike, and a share ratio then reports that
// nothing was lost. This is the case an independent review raised, with its numbers: a control producing
// 60k premium and 40k contender against an arm producing 30k and 20k has given the contender half as much
// work, while its share is 40 percent in both. Scored as a share the arm reports 1.00, reading 2 never
// fires, and reading 1 calls an arm that discarded half the contender's work the deliverable.
func TestTheContenderIsMeasuredByItsOutputAndNotItsShare(t *testing.T) {
	m := healthyMatrix()
	m.Shared = healthyArm(ArmShared, 1400, 80, 40_000)
	m.Shared.OutputTokensByTenant = map[string]int64{PremiumTenant: 60_000, NoisyTenant: 40_000}
	m.Shared.OutputTokens = 100_000

	halved := healthyArm(ArmTimeSlicing, 100, 20, 20_000)
	halved.OutputTokensByTenant = map[string]int64{PremiumTenant: 30_000, NoisyTenant: 20_000}
	halved.OutputTokens = 50_000
	// The ledger shows the missing work was refused rather than delayed.
	halved.DispositionByTenant = map[string]Disposition{
		NoisyTenant: {Offered: 300, Completed: 150, Rejected: 150},
	}
	m.Sharing = []ArmSummary{halved}

	res := EvaluateSharingMatrix(m, PremiumTenant, NoisyTenant)

	if one := sharingReadingByID(t, res, "1"); one.Fired {
		t.Errorf("reading 1 fired POSITIVE for an arm that produced half the contender's output. Its SHARE "+
			"is unchanged at 40 percent, which is why a share ratio misses this: %s", one.Detail)
	}
	two := sharingReadingByID(t, res, "2")
	if !two.Fired {
		t.Fatalf("reading 2 did not fire for an arm that halved the contender's output with the ledger "+
			"showing refusals: %s", two.Detail)
	}
	if !strings.Contains(two.Detail, "0.50") {
		t.Errorf("reading 2 reports the contender at something other than 0.50 of its output under the "+
			"control, so it is still measuring a share: %s", two.Detail)
	}
}

// A shortfall that is mostly timeouts is delay, and the pre-registration says delay is not this reading.
//
// The check was `Rejected+Failed > 0`, so a single broken stream among thousands of timeouts printed
// "refused work, not merely late work" over a ledger that principally said late -- and Failed counts
// transport breaks, which a flaky tunnel produces on its own.
func TestOneBrokenStreamAmongManyTimeoutsIsNotStarvation(t *testing.T) {
	m := healthyMatrix()
	arm := healthyArm(ArmTimeSlicing, 100, 20, 5_000)
	arm.DispositionByTenant = map[string]Disposition{
		NoisyTenant: {Offered: 3000, Completed: 120, TimedOut: 2879, Failed: 1},
	}
	m.Sharing = []ArmSummary{arm}

	res := EvaluateSharingMatrix(m, PremiumTenant, NoisyTenant)

	if two := sharingReadingByID(t, res, "2"); two.Fired {
		t.Errorf("reading 2 fired on 1 failure against 2879 timeouts. The refused work has to account for "+
			"the deficit, not merely be non-zero: %s", two.Detail)
	}
}

// A censored or thin R1 may not be divided by, because every bar is a ratio against it.
func TestACensoredBaselineIsNotDividedBy(t *testing.T) {
	for _, tc := range []struct {
		name   string
		damage func(*ArmSummary)
	}{
		{"censored", func(s *ArmSummary) { s.Censored = true }},
		{"below the sample floor", func(s *ArmSummary) { s.TailSampleSize = MinTailSamples - 1 }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m := healthyMatrix()
			tc.damage(&m.R1)
			// Make the arms look excellent, so anything that scores them would fire POSITIVE.
			m.Sharing = []ArmSummary{healthyArm(ArmTimeSlicing, 100, 20, 38_000)}

			res := EvaluateSharingMatrix(m, PremiumTenant, NoisyTenant)

			// Reading 1 must not fire POSITIVE. WHICH guard stops it is deliberately not asserted: a thin R1
			// is caught by reading 4b, which declares the whole run invalid and short-circuits, while a
			// censored R1 is caught by the scoring precondition further down. Both are correct and pinning
			// one of them would fail the day the other became responsible.
			for _, r := range res.Readings {
				if r.ID == "1" && r.Fired {
					t.Errorf("reading 1 fired POSITIVE against an R1 that is %s. Every bar is a ratio "+
						"against that baseline, so the result is a lower bound wearing a measurement's "+
						"name: %s", tc.name, r.Detail)
				}
			}
			if res.Answer == "1" || strings.HasPrefix(res.Answer, "1 ") {
				t.Errorf("the answer is %q for a run whose baseline is %s", res.Answer, tc.name)
			}
		})
	}
}

// Reading 4c fires on a refusal the runner recorded, which is how an MPS arm that never engaged is reported.
func TestARecordedRefusalIsWhatMakesFourCReachable(t *testing.T) {
	m := healthyMatrix()
	m.Sharing = []ArmSummary{healthyArm(ArmTimeSlicing, 900, 60, 38_000)}
	m.Refused = map[string]string{ArmMPS: "the engines are not MPS clients"}

	res := EvaluateSharingMatrix(m, PremiumTenant, NoisyTenant)
	fourC := sharingReadingByID(t, res, "4c")
	if !fourC.Fired || fourC.Cell != ArmMPS {
		t.Fatalf("reading 4c did not fire for a recorded refusal of the mps arm: fired=%v cell=%q detail=%s",
			fourC.Fired, fourC.Cell, fourC.Detail)
	}
}
