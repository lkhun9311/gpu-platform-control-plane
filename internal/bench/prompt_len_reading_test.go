package bench

import (
	"strings"
	"testing"
)

// Reading 4f's five outcomes, driven through EvaluateSharingMatrix.
//
// # WHY HAND-BUILT ARMS ARE RIGHT HERE AND WRONG NEXT DOOR
//
// prompt_len_test.go drives Summarize from RawRow, because the claim there is that the TALLY fills three
// maps correctly and a literal would bypass the tally entirely. The claim here is the other half: that the
// READING reads those maps correctly. The maps are this reading's input, so setting them directly is the
// input, not a bypass -- and duplicating the RawRow fixtures would put the same two claims in both files
// with only one of them guarded.
//
// # WHY THE ARMS ARE TAKEN FROM healthyMatrix AND NOT REBUILT
//
// The first version of this file built each arm with `healthyArm(arm, 1000, 60, 37_000)` and set the maps on
// that. Four tests passed and the fifth came back with the readings `[4]` and nothing else: healthyArm takes
// the arm's TTFT p99 as a parameter, so giving R1 and `shared` the same 1000 ms made the control 1.000x the
// baseline, reading 4's contention floor fired at under 5x, and the evaluation short-circuited before 4f was
// ever appended. The four that passed had only replaced `shared` -- 1000 against R1's 67.3 is 14.8x, over the
// floor -- so the fixture defect was invisible in four of five cases.
//
// So these helpers MUTATE an arm from healthyMatrix rather than constructing one. Every value that another
// reading gates on stays as that fixture set it, and these tests change only the three maps they are about.
func withPromptLens(s ArmSummary, lengths map[string]map[int]int, absent, invalid map[string]int) ArmSummary {
	s.PromptLenCharsByTenant = lengths
	s.PromptLenUnreportedByTenant = absent
	s.PromptLenInvalidByTenant = invalid
	return s
}

func oneLength(tenant string, chars, rows int) map[string]map[int]int {
	return map[string]map[int]int{tenant: {chars: rows}}
}

// A population carrying two lengths is two conditions, and the reading says so.
func TestTwoPromptLengthsInOneArmAreReportedAsAMixture(t *testing.T) {
	m := healthyMatrix()
	m.Shared = withPromptLens(m.Shared,
		map[string]map[int]int{PremiumTenant: {1174: 3000, 200: 1655}}, nil, nil)
	res := EvaluateSharingMatrix(m, PremiumTenant, NoisyTenant)

	r := sharingReadingByID(t, res, "4f")
	if !r.Fired {
		t.Errorf("an arm whose premium rows were generated at 1,174 and 200 characters did not fire 4f: %q", r.Detail)
	}
	if !strings.Contains(r.Detail, "1174 chars on 3000 rows") || !strings.Contains(r.Detail, "200 chars on 1655 rows") {
		t.Errorf("4f fired without naming both lengths and their row counts: %q", r.Detail)
	}
	// It must not become the run's verdict. The ANSWER is chosen from the four scored readings and falls
	// back only to 4c, so an observation cannot take the answer away from a measurement.
	if res.Answer == "4f" {
		t.Errorf("4f became the ANSWER; it is an observation and the verdict belongs to the scored readings")
	}
}

// A negative character count is a recorder defect, and it blocks the uniformity judgement without claiming
// the load was wrong.
func TestANegativePromptLengthMakesUniformityUnevaluable(t *testing.T) {
	m := healthyMatrix()
	m.Shared = withPromptLens(m.Shared,
		oneLength(PremiumTenant, 1174, 4654), nil, map[string]int{PremiumTenant: 1})
	res := EvaluateSharingMatrix(m, PremiumTenant, NoisyTenant)

	r := sharingReadingByID(t, res, "4f")
	if r.Fired {
		t.Errorf("a negative length was reported as a MIXTURE; it is evidence about the recorder, not about the load: %q", r.Detail)
	}
	if !r.NotEvaluable {
		t.Errorf("a negative length left 4f evaluable: %q", r.Detail)
	}
}

// Rows that say nothing, beside rows that do, leave uniformity undecided -- the counter-example an external
// review derived before any of this existed.
func TestSomeRowsWithoutALengthLeaveUniformityUnevaluable(t *testing.T) {
	m := healthyMatrix()
	m.Shared = withPromptLens(m.Shared,
		oneLength(PremiumTenant, 1174, 4000), map[string]int{PremiumTenant: 655}, nil)
	res := EvaluateSharingMatrix(m, PremiumTenant, NoisyTenant)

	r := sharingReadingByID(t, res, "4f")
	if !r.NotEvaluable {
		t.Errorf("4,000 rows at one length beside 655 that reported none was treated as uniform: %q", r.Detail)
	}
	if !strings.Contains(r.Detail, "655") {
		t.Errorf("the reading does not say how many rows reported no length: %q", r.Detail)
	}
}

// EVERY population silent is not agreement. This is the false pass the switch had before its own case
// existed: the per-tenant guard skipped them all, the four slices came back empty, and the default branch
// printed "every population reports one prompt length --" with nothing after the dash.
func TestNoArmReportingAnyLengthIsUnevaluableRatherThanUniform(t *testing.T) {
	// healthyMatrix sets none of the three prompt-length maps, which is exactly the shape of evidence
	// collected before RawRow.PromptLenChars existed -- the three committed archives.
	res := EvaluateSharingMatrix(healthyMatrix(), PremiumTenant, NoisyTenant)

	r := sharingReadingByID(t, res, "4f")
	if r.Fired {
		t.Errorf("evidence carrying no lengths at all fired a mixture: %q", r.Detail)
	}
	if !r.NotEvaluable {
		t.Errorf("evidence carrying no lengths at all was reported as uniform: %q", r.Detail)
	}
	if strings.Contains(r.Detail, "every population reports one prompt length") {
		t.Errorf("the reading claims uniformity over no evidence: %q", r.Detail)
	}
}

// THE DELIBERATE LIMITATION, pinned so a later reader does not mistake it for a defect.
//
// Two arms each uniform at a DIFFERENT length both pass 4f, and so would a matrix where every arm agreed on
// the wrong length. Uniformity within an arm is not agreement between arms, and it is not agreement with the
// registration either. Those are reading 4e's territory and the study registration's. If this test ever
// turns red because 4f grew to cover them, the change is an improvement and this test is what to delete.
func TestUniformityWithinAnArmIsNotAgreementBetweenArms(t *testing.T) {
	m := healthyMatrix()
	// Both arms keep the TTFT values healthyMatrix gave them, so reading 4's contention floor stays clear
	// and the evaluation reaches 4f. Only the lengths differ, which is the whole point of the case.
	m.R1 = withPromptLens(m.R1, oneLength(PremiumTenant, 200, 4655), nil, nil)
	m.Shared = withPromptLens(m.Shared, oneLength(PremiumTenant, 1174, 4655), nil, nil)
	for i := range m.Sharing {
		m.Sharing[i] = withPromptLens(m.Sharing[i], oneLength(PremiumTenant, 1174, 4655), nil, nil)
	}
	res := EvaluateSharingMatrix(m, PremiumTenant, NoisyTenant)

	r := sharingReadingByID(t, res, "4f")
	if r.Fired || r.NotEvaluable {
		t.Errorf("arms uniform at different lengths should PASS 4f as written; the between-arm check is not this reading's: %q", r.Detail)
	}
	if !strings.Contains(r.Detail, "does NOT say the arms agree with each other") {
		t.Errorf("4f passed without stating the limit of what it establishes: %q", r.Detail)
	}
}
