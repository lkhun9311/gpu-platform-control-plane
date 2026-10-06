package bench

import (
	"reflect"
	"strings"
	"testing"
)

// TestStepBoundaryPairsItsOverheadArms pins the step-boundary registration's arm set: serial and burst are bought
// as logged/instrumented pairs, because the overhead gate compares them, and the staggered arm stands alone.
// Mutation that turns it red: drop the StudyStepBoundary branch, so the instrument-validation pairing applies.
func TestStepBoundaryPairsItsOverheadArms(t *testing.T) {
	for _, tc := range []struct {
		arms  []string
		words string
	}{
		{[]string{"serial-log", "serial-step", "burst-log", "burst-step", "stagger-step"}, ""},
		{[]string{"serial-log", "burst-log", "burst-step", "stagger-step"}, "include only one of serial-log and serial-step"},
		{[]string{"serial-log", "serial-step", "burst-step", "stagger-step"}, "include only one of burst-log and burst-step"},
		{[]string{"serial-log", "serial-step", "burst-log", "burst-step", "stagger-log"}, "not one of study"},
		{[]string{"serial-nolog", "serial-step"}, "not one of study"},
	} {
		err := MatrixPlanArmSetRefusal(StudyStepBoundary, tc.arms)
		if tc.words == "" {
			if err != nil {
				t.Fatalf("arms %v were refused: %v", tc.arms, err)
			}
			continue
		}
		if err == nil || !strings.Contains(err.Error(), tc.words) {
			t.Fatalf("arms %v: got %v, want a refusal containing %q", tc.arms, err, tc.words)
		}
	}
}

// TestStepBoundaryReplaysSessionFourEpisodes pins that the study changes the engine and not the trace: at one seed
// its measured and warm-up traces are session 4's row for row.
func TestStepBoundaryReplaysSessionFourEpisodes(t *testing.T) {
	for _, et := range EpisodeTypes {
		for _, warm := range []bool{false, true} {
			gen := GenerateEpisodeTrace
			if warm {
				gen = GenerateEpisodeWarmupTrace
			}
			dur := int64(3_000_000)
			s4, err := gen(EpisodeTraceParams{Study: StudyInstrumentValidationS4, Seed: 29, DurationMs: dur, Type: et})
			if err != nil {
				t.Fatalf("%s warm=%t session 4: %v", et, warm, err)
			}
			sb, err := gen(EpisodeTraceParams{Study: StudyStepBoundary, Seed: 29, DurationMs: dur, Type: et})
			if err != nil {
				t.Fatalf("%s warm=%t step boundary: %v", et, warm, err)
			}
			if !reflect.DeepEqual(s4, sb) {
				t.Fatalf("%s warm=%t: the step-boundary trace differs from session 4's at the same seed", et, warm)
			}
		}
		if got, ok := InstrumentValidationEpisode(InstrumentValidationArm(et, instrumentModeStep)); !ok || got != et {
			t.Fatalf("arm %s resolves to %q, %t", InstrumentValidationArm(et, instrumentModeStep), got, ok)
		}
	}
}
