package bench

import (
	"fmt"
	"slices"
	"strings"
)

// MatrixPlanRefusal says whether one planned frozen-matrix cell could EVER be scored, before anything is rented.
//
// It is the frozen matrix's half of what LadderPlanRefusal does for the ladder, and it exists for the same
// reason: every refusal here already existed and every one of them fired ON THE RENTED CARD. `replay`
// validates the arm against its study after the engines are up, and the cell floors are applied by the
// readings after the replay has finished. A mistyped study, an arm the registry does not admit, or a load
// whose premium tail the readings would refuse therefore cost a bring-up each time -- and the frozen matrix
// had no local plan check at all, because PLAN_ONLY was implemented for a ladder and refused anything else.
//
// The floor it applies is MinTailSamples and it is applied PER CELL, because a cell is one repetition and
// RegisteredEstimandFor refuses an arm whose MinRepetitionTail falls below it -- not only one whose pooled
// tail does. A matrix of fifteen cells that each offer 94 premium requests pools 1410 and is still refused.
//
// TWO REFUSALS THE LADDER MAKES ARE DELIBERATELY ABSENT, and saying so is the point of this paragraph.
// LadderPlanRefusal also demands that an isolated baseline carry no contender and that a contended cell
// hold the contender at a fixed count. Neither can be violated by the generator this matrix uses: gen-trace
// filters the contending tenant out of an isolated baseline itself (cmd/benchharness/main.go, the
// IsIsolatedBaseline block), and it refuses a contender weight of zero outright with "tenant
// \"standard-noisy\" weight must be positive". A refusal no fixture can reach is a refusal no mutation can
// test, and this repository has already shipped one of those.
func MatrixPlanRefusal(study, arm string, premiumOffers int) error {
	s, ok := LookupStudy(study)
	if !ok {
		return fmt.Errorf("study %q is not registered; known studies are %s", study, strings.Join(KnownStudyIDs(), ", "))
	}
	if !s.Admits(arm) {
		return fmt.Errorf("arm %q is not one of study %s's arms (%s)", arm, s.ID, strings.Join(s.Arms, ", "))
	}
	if premiumOffers < MinTailSamples {
		return fmt.Errorf("the trace offers %d premium requests and every repetition's tail must reach %d completed, so this cell could not be scored even if every request succeeded",
			premiumOffers, MinTailSamples)
	}
	return nil
}

// MatrixPlanArmSetRefusal says whether the arm LIST a frozen run was given can be scored at all.
//
// EvaluateSharingMatrix already refuses a run with no R1 or no `shared` and names which is missing, because
// every reading divides by R1 or compares against `shared`. That refusal arrives after the whole matrix has
// been bought; asked here it costs nothing. It is a question about the SET rather than about a cell, which
// is why it is a second function: no single cell's trace can answer it.
func MatrixPlanArmSetRefusal(study string, arms []string) error {
	s, ok := LookupStudy(study)
	if !ok {
		return fmt.Errorf("study %q is not registered; known studies are %s", study, strings.Join(KnownStudyIDs(), ", "))
	}
	if len(arms) == 0 {
		return fmt.Errorf("no arms were planned for study %s, so there is nothing to buy and nothing to score", s.ID)
	}
	for _, required := range []struct{ arm, why string }{
		{ArmR1, "the isolated baseline both bars divide by"},
		{ArmShared, "the control every improvement is measured from"},
	} {
		if !slices.Contains(arms, required.arm) {
			return fmt.Errorf("the planned arms (%s) do not include %s, and it is %s; the readings call a run without it INVALID, so this matrix would be bought and then refused",
				strings.Join(arms, " "), required.arm, required.why)
		}
	}
	return nil
}
