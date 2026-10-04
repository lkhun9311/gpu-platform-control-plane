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
	"math"
	"strings"
	"testing"
)

// The tail-crossing readings: each BE level's latency-critical tail against the isolated baseline's, POOLED
// over the level's traces, because the 2026-10-04 model-first registration made the repetitions independent
// traces and so made the arrival process the population.

// levelSummary is an arm summary with only what the readings read.
func levelSummary(arm string, p95, p99 float64, perTrace []float64, minRepTail int) ArmSummary {
	return ArmSummary{
		Arm: arm, TTFTMsP95: p95, TTFTMsP99: p99,
		TailSampleSize: minRepTail * len(perTrace), RepetitionCount: len(perTrace),
		MinRepetitionTail: minRepTail, RepetitionTTFTMsP99: perTrace,
	}
}

func TestEachLevelIsReadAgainstTheBaselineOnThePooledTail(t *testing.T) {
	r := EvaluateTailCrossing(StudyTailCrossingShortLC, []ArmSummary{
		levelSummary(ArmR1, 62, 65, []float64{64, 65, 66}, 170),
		levelSummary(TailCrossingArm(1), 63, 398, []float64{495, 80, 73}, 170),
		levelSummary(TailCrossingArm(2), 115, 570, []float64{428, 566, 639}, 170),
	})
	if r.InvalidReason != "" {
		t.Fatalf("a complete sweep was refused: %s", r.InvalidReason)
	}
	if len(r.Levels) != 2 {
		t.Fatalf("got %d levels, want 2", len(r.Levels))
	}
	l1 := r.Levels[0]
	if l1.Arm != TailCrossingArm(1) || l1.InvalidReason != "" {
		t.Fatalf("first level is %+v", l1)
	}
	// The POOLED p99, 398, not the median of the per-trace p99s, 80: that is the estimand this study
	// registered, and the two differ by a factor of five on exactly this shape.
	if math.Abs(l1.Multiple99-398.0/65.0) > 1e-9 || l1.Added99Ms != 333 {
		t.Errorf("level 1: multiple %v added %v; want %v and 333", l1.Multiple99, l1.Added99Ms, 398.0/65.0)
	}
	if math.Abs(l1.Multiple95-63.0/62.0) > 1e-9 || l1.Added95Ms != 1 {
		t.Errorf("level 1 p95: multiple %v added %v", l1.Multiple95, l1.Added95Ms)
	}
}

func TestALevelThatCannotBeReadIsRefusedAloneAndNamed(t *testing.T) {
	censoredLevel := levelSummary(TailCrossingArm(1), 0, 0, []float64{1, 2}, 170)
	censoredLevel.AnyRepetitionCensored = true
	thin := levelSummary(TailCrossingArm(2), 70, 80, []float64{70, 80}, 60)
	short := levelSummary(TailCrossingArm(3), 70, 80, []float64{70}, 170)
	ok := levelSummary(TailCrossingArm(4), 70, 80, []float64{70, 90}, 170)
	r := EvaluateTailCrossing(StudyTailCrossingShortLC, []ArmSummary{
		levelSummary(ArmR1, 62, 65, []float64{64, 66}, 170), censoredLevel, thin, short, ok,
	})
	want := map[string]string{
		TailCrossingArm(1): "censored",
		TailCrossingArm(2): "repetition with 60",
		TailCrossingArm(3): "1 trace(s) against the baseline's 2",
		TailCrossingArm(4): "",
	}
	for _, l := range r.Levels {
		w, known := want[l.Arm]
		if !known {
			t.Errorf("unexpected level %s", l.Arm)
			continue
		}
		if w == "" && l.InvalidReason != "" {
			t.Errorf("%s was refused: %s", l.Arm, l.InvalidReason)
		}
		if w != "" && !strings.Contains(l.InvalidReason, w) {
			t.Errorf("%s: refusal %q does not say %q", l.Arm, l.InvalidReason, w)
		}
		if w != "" && (l.Multiple99 != 0 || l.Added99Ms != 0) {
			t.Errorf("%s was refused and still carries a multiple %v", l.Arm, l.Multiple99)
		}
	}
	if len(r.Levels) != 4 {
		t.Errorf("got %d levels, want 4", len(r.Levels))
	}
}

func TestABaselineThatCannotBeReadRefusesEveryLevel(t *testing.T) {
	base := levelSummary(ArmR1, 62, 65, []float64{64, 66}, 170)
	base.Censored = true
	r := EvaluateTailCrossing(StudyTailCrossingLongLC, []ArmSummary{base, levelSummary(TailCrossingArm(1), 70, 80, []float64{70, 90}, 170)})
	if !strings.Contains(r.InvalidReason, "censored") {
		t.Errorf("a censored baseline did not refuse the study: %q", r.InvalidReason)
	}
	r = EvaluateTailCrossing(StudyTailCrossingLongLC, []ArmSummary{levelSummary(TailCrossingArm(1), 70, 80, []float64{70, 90}, 170)})
	if !strings.Contains(r.InvalidReason, ArmR1) {
		t.Errorf("a sweep with no baseline did not say so: %q", r.InvalidReason)
	}
}

func TestTheReadingsPrintNoVerdictAndNameTheEstimand(t *testing.T) {
	out := FormatTailCrossing(EvaluateTailCrossing(StudyTailCrossingShortLC, []ArmSummary{
		levelSummary(ArmR1, 62, 65, []float64{64, 66}, 170),
		levelSummary(TailCrossingArm(1), 63, 398, []float64{495, 80}, 170),
	}))
	for _, want := range []string{"TAIL-CROSSING", "pooled", "be01-shared", "398.0", "6.12x", "+333.0", "495.0 80.0", "no verdict"} {
		if !strings.Contains(out, want) {
			t.Errorf("the block does not contain %q:\n%s", want, out)
		}
	}
	for _, banned := range []string{"PASS", "FAIL", "protects"} {
		if strings.Contains(out, banned) {
			t.Errorf("the block uses the verdict word %q, which this exploratory study registered none of:\n%s", banned, out)
		}
	}
	if FormatTailCrossing(TailCrossingResult{}) != "" {
		t.Error("an empty result printed a block")
	}
}
