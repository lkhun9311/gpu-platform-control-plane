package bench

import (
	"strings"
	"testing"
)

// The floor is asserted by VALUE on both sides of it, not by passing a number that is obviously too small.
//
// MinTailSamples is what RegisteredEstimandFor compares each repetition's tail against, so a plan check that
// used a floor of its own would accept a cell the readings then refuse -- which is the whole failure this
// function exists to move off the rented card.
func TestMatrixPlanRefusalAppliesTheReadingsOwnFloor(t *testing.T) {
	if err := MatrixPlanRefusal(StudySharingMatrix, ArmShared, MinTailSamples); err != nil {
		t.Fatalf("a cell offering exactly the floor of %d was refused: %v", MinTailSamples, err)
	}
	err := MatrixPlanRefusal(StudySharingMatrix, ArmShared, MinTailSamples-1)
	if err == nil {
		t.Fatalf("a cell offering %d premium requests was accepted, one below the %d floor every repetition's tail must reach; the readings would refuse it after the card was rented",
			MinTailSamples-1, MinTailSamples)
	}
	for _, want := range []string{"99", "100", "even if every request succeeded"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the refusal does not say %q, so a reader cannot tell what to change: %v", want, err)
		}
	}
}

// The measured case, so the numbers in the refusal are not only arithmetic.
//
// The load is the one the PRE-REGISTRATION names for the next run -- RATE=9.4045, premium weight 1,
// contender weight 0.0260, DURATION_MS=505000 -- and not the wrapper's defaults, which that page calls "the
// seventh pilot's load, the one reading 4b rejected". Pinning the rejected load's counts here would have
// described the wrong run in a comment a later reader trusts.
//
// Measured with gen-trace at that load: 4655 premium offers over 505000 ms, 109 over 12000 ms, 99 over
// 11000 ms. The last pair sits one on each side of MinTailSamples, which is what shows the floor being
// applied is that one.
func TestMatrixPlanRefusalSeparatesTheMeasuredDurations(t *testing.T) {
	if err := MatrixPlanRefusal(StudySharingMatrix, ArmR1, 4655); err != nil {
		t.Errorf("the registered 505000 ms cell (4655 premium offers) was refused: %v", err)
	}
	if err := MatrixPlanRefusal(StudySharingMatrix, ArmR1, 109); err != nil {
		t.Errorf("a 12000 ms cell (109 premium offers) was refused above the floor of %d: %v", MinTailSamples, err)
	}
	if err := MatrixPlanRefusal(StudySharingMatrix, ArmR1, 99); err == nil {
		t.Error("an 11000 ms cell (99 premium offers) was accepted; that is the run the readings refuse after it has been bought")
	}
}

func TestMatrixPlanRefusalChecksTheStudyAndTheArm(t *testing.T) {
	err := MatrixPlanRefusal("sharing-matrix-2026-09-11", ArmShared, 3882)
	if err == nil || !strings.Contains(err.Error(), "is not registered") {
		t.Errorf("a mistyped study was not refused as unregistered: %v", err)
	}
	err = MatrixPlanRefusal(StudySharingMatrix, "rung01-shared", 3882)
	if err == nil || !strings.Contains(err.Error(), "is not one of study") {
		t.Errorf("a ladder arm name was accepted for the frozen study: %v", err)
	}
	// The arm names the frozen matrix does buy, each accepted at the registered load.
	for _, arm := range []string{ArmR1, ArmShared, ArmTimeSlicing, ArmMPS} {
		if err := MatrixPlanRefusal(StudySharingMatrix, arm, 3882); err != nil {
			t.Errorf("arm %s is registered for this study and was refused: %v", arm, err)
		}
	}
}

// A set-level question no single cell can answer.
//
// ARMS defaults to four arms, so the three-arm run must name them; naming the wrong three is what this
// catches. EvaluateSharingMatrix refuses a run with either arm absent, and it does so after every cell has
// been paid for.
func TestMatrixPlanArmSetRefusalNamesTheMissingDenominator(t *testing.T) {
	if err := MatrixPlanArmSetRefusal(StudySharingMatrix, []string{ArmR1, ArmShared, ArmTimeSlicing}); err != nil {
		t.Fatalf("the three-arm plan was refused: %v", err)
	}
	for _, tc := range []struct {
		name string
		arms []string
		want string
	}{
		{"no isolated baseline", []string{ArmShared, ArmTimeSlicing}, ArmR1},
		{"no control", []string{ArmR1, ArmTimeSlicing}, ArmShared},
		{"nothing at all", nil, "nothing to buy"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := MatrixPlanArmSetRefusal(StudySharingMatrix, tc.arms)
			if err == nil {
				t.Fatalf("the plan %v was accepted, and the readings call it INVALID after it has been bought", tc.arms)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Errorf("the refusal does not name %q: %v", tc.want, err)
			}
		})
	}
}

func TestMatrixPlanArmSetRefusalChecksTheStudy(t *testing.T) {
	err := MatrixPlanArmSetRefusal("sharing-matrix-2026-09-11", []string{ArmR1, ArmShared})
	if err == nil || !strings.Contains(err.Error(), "is not registered") {
		t.Errorf("a mistyped study was accepted by the arm-set check: %v", err)
	}
}

// The admission studies' arm sets: the sharing matrix's defaults are refused, a pilot stage may be a subset with R1
// and off, and the diagnostic and v26 must plan exactly their registered arms (v26 review, C6).
// Mutation that turns it red: require `shared` of these studies, or accept a subset for v26.
func TestMatrixPlanArmSetRefusalForTheAdmissionStudies(t *testing.T) {
	if err := MatrixPlanArmSetRefusal(StudyAdmissionFrontier, []string{"R1", "shared", "timeSlicing", "mps"}); err == nil {
		t.Fatal("v26 accepted the sharing matrix's default arms")
	}
	if err := MatrixPlanArmSetRefusal(StudyAdmissionFrontier, []string{"R1", "off", "hold-cap", "fixed-1.62", "fixed-1.66", "fixed-1.70", "fixed-1.74"}); err != nil {
		t.Fatalf("v26's registered arms were refused: %v", err)
	}
	if err := MatrixPlanArmSetRefusal(StudyAdmissionFrontier, []string{"R1", "off", "hold-cap", "fixed-1.62"}); err == nil {
		t.Fatal("v26 accepted a plan missing three fixed arms")
	}
	if err := MatrixPlanArmSetRefusal(StudyAdmissionDiagnostic, []string{"R1", "off", "hold", "cap", "hold-cap"}); err != nil {
		t.Fatalf("the diagnostic's registered arms were refused: %v", err)
	}
	if err := MatrixPlanArmSetRefusal(StudyProspectivePilot, []string{"R1", "off", "prospective"}); err != nil {
		t.Fatalf("pilot stage A's arms were refused: %v", err)
	}
	if err := MatrixPlanArmSetRefusal(StudyProspectivePilot, []string{"R1", "prospective"}); err == nil {
		t.Fatal("a pilot plan without off was accepted")
	}
}
