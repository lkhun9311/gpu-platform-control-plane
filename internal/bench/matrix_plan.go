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

// InstrumentValidationPlanRefusal is MatrixPlanRefusal for the instrument-validation study, which is judged on its own terms.
//
// The tail studies' premium-sample floor does not apply: nothing here is a p99, and a trace is complete when it holds its registered cycles.
// What does apply is that the trace is the one this arm's episode type registers, because a burst trace replayed in a serial cell attributes nothing.
// The study is a parameter because the two sessions share arm names and differ in their episodes, so the arm alone cannot say which trace is right.
func InstrumentValidationPlanRefusal(study, arm string, rows []TraceRow) error {
	if !IsInstrumentValidationStudy(study) {
		return fmt.Errorf("study %q is not an instrument-validation study", study)
	}
	s, _ := LookupStudy(study)
	if !s.Admits(arm) {
		return fmt.Errorf("arm %q is not one of study %s's arms (%s)", arm, s.ID, strings.Join(s.Arms, ", "))
	}
	t, _ := InstrumentValidationEpisode(arm)
	return EpisodeTraceRefusal(study, t, rows)
}

// IsInstrumentValidationStudy says whether a study is scored on episodes by the instrument check rather than on a tail.
func IsInstrumentValidationStudy(study string) bool {
	_, ok := designFor(study)
	return ok
}

// instrumentValidationArmSetRefusal refuses a plan whose arms are not all admitted or whose logging arms lack their pair.
//
// I1 is a paired on/off change per episode type, so an on cell bought without its off cell, or the reverse, is a cell no gate can read.
// The async arms stand alone, since the registration publishes them and compares them with nothing.
func instrumentValidationArmSetRefusal(s Study, arms []string) error {
	for _, a := range arms {
		if !s.Admits(a) {
			return fmt.Errorf("arm %q is not one of study %s's arms (%s)", a, s.ID, strings.Join(s.Arms, ", "))
		}
	}
	// The step-boundary session pairs logged with instrumented cells, and its staggered arm stands alone by
	// registration, so its pairs are checked on its own terms.
	// The confirmation buys instrumented arms only and pairs nothing, so admission is its whole check.
	if s.ID == StudyStepConfirm {
		return nil
	}
	if s.ID == StudyStepBoundary {
		for _, t := range []EpisodeType{EpisodeSerial, EpisodeBurst} {
			logged := slices.Contains(arms, InstrumentValidationArm(t, instrumentModeLog))
			step := slices.Contains(arms, InstrumentValidationArm(t, instrumentModeStep))
			if logged != step {
				return fmt.Errorf("the planned arms (%s) include only one of %s and %s, and the overhead gate compares the two as a pair, so the one bought would be unreadable",
					strings.Join(arms, " "), InstrumentValidationArm(t, instrumentModeLog), InstrumentValidationArm(t, instrumentModeStep))
			}
		}
		return nil
	}
	for _, t := range EpisodeTypes {
		on := slices.Contains(arms, InstrumentValidationArm(t, instrumentModeLog))
		off := slices.Contains(arms, InstrumentValidationArm(t, instrumentModeNoLog))
		if on != off {
			return fmt.Errorf("the planned arms (%s) include only one of %s and %s, and the logging-overhead gate compares the two as a pair, so the one bought would be unreadable",
				strings.Join(arms, " "), InstrumentValidationArm(t, instrumentModeLog), InstrumentValidationArm(t, instrumentModeNoLog))
		}
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
	// The instrument check has no isolated baseline and no shared control; what it divides is a logging-on cell by its logging-off pair.
	if IsInstrumentValidationStudy(s.ID) {
		return instrumentValidationArmSetRefusal(s, arms)
	}
	// The admission pilot's family has no `shared`: its control is off. A pilot stage buys a subset of the pilot's
	// arms with R1 and off in it; the diagnostic and v26 buy exactly their registered arms, which their scorers
	// require cell by cell (v26 review, C6: the matrix had been passing the sharing matrix's default arms here).
	// The length calibration has no bare off: its references are off at each length, and every registered arm is
	// required, as its scorer requires each cell.
	if s.ID == StudyLengthCalibration {
		for _, a := range arms {
			if !slices.Contains(s.Arms, a) {
				return fmt.Errorf("the planned arm %s is not one of study %s's (%s)", a, s.ID, strings.Join(s.Arms, " "))
			}
		}
		for _, a := range s.Arms {
			if !slices.Contains(arms, a) {
				return fmt.Errorf("the planned arms (%s) lack %s, and study %s's scorer requires every registered arm", strings.Join(arms, " "), a, s.ID)
			}
		}
		return nil
	}
	switch s.ID {
	case StudyProspectivePilot, StudyAdmissionDiagnostic, StudyAdmissionFrontier:
		for _, a := range arms {
			if !slices.Contains(s.Arms, a) {
				return fmt.Errorf("the planned arm %s is not one of study %s's (%s)", a, s.ID, strings.Join(s.Arms, " "))
			}
		}
		for _, r := range []string{ArmR1, "off"} {
			if !slices.Contains(arms, r) {
				return fmt.Errorf("the planned arms (%s) do not include %s, which every comparison of study %s needs", strings.Join(arms, " "), r, s.ID)
			}
		}
		if s.ID != StudyProspectivePilot {
			for _, a := range s.Arms {
				if !slices.Contains(arms, a) {
					return fmt.Errorf("the planned arms (%s) lack %s, and study %s's scorer requires every registered arm", strings.Join(arms, " "), a, s.ID)
				}
			}
		}
		return nil
	}
	required := []struct{ arm, why string }{
		{ArmR1, "the isolated baseline both bars divide by"},
	}
	// The sharing matrix's control is the bare `shared`. A study that names its contended arms by BE level
	// admits no bare `shared` at all, so requiring it would refuse every plan that study can make; what that
	// study needs instead is at least one contended arm to divide by the baseline.
	//
	// Only for a study whose contended arms ARE per-level names. Every other study keeps the old pair: the
	// price-of-protection sweep admits no bare `shared` either, and a plan check run against it with the
	// matrix's arms must reach the refusal that names the mismatched study rather than this one.
	perLevel := slices.ContainsFunc(s.Arms, isTailCrossingArm)
	if !perLevel {
		required = append(required, struct{ arm, why string }{ArmShared, "the control every improvement is measured from"})
	} else if !slices.ContainsFunc(arms, func(a string) bool { return isTailCrossingArm(a) && s.Admits(a) }) {
		return fmt.Errorf("the planned arms (%s) include no contended arm of study %s, so the baseline would be bought with nothing to compare it to",
			strings.Join(arms, " "), s.ID)
	}
	for _, r := range required {
		if !slices.Contains(arms, r.arm) {
			return fmt.Errorf("the planned arms (%s) do not include %s, and it is %s; the readings call a run without it INVALID, so this matrix would be bought and then refused",
				strings.Join(arms, " "), r.arm, r.why)
		}
	}
	return nil
}
