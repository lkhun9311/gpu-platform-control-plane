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
// At the load the frozen matrix was registered with -- RATE=9.85, premium weight 1, contender weight 0.054 --
// gen-trace offers 3882 premium requests over 420000 ms and 94 over 10000 ms. The second is the deliberate
// failure the open defect asked for: a DURATION_MS below the floor must be refused BEFORE the card is rented.
func TestMatrixPlanRefusalSeparatesTheMeasuredDurations(t *testing.T) {
	if err := MatrixPlanRefusal(StudySharingMatrix, ArmR1, 3882); err != nil {
		t.Errorf("the registered 420000 ms cell (3882 premium offers) was refused: %v", err)
	}
	if err := MatrixPlanRefusal(StudySharingMatrix, ArmR1, 94); err == nil {
		t.Error("a 10000 ms cell (94 premium offers) was accepted; that is the run the readings refuse after it has been bought")
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
