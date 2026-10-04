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

// The tail-crossing studies sweep the best-effort rate with the latency-critical rate held, and each rate is
// its own arm, for the reason the ladder gives for its rungs: an arm summary pools every row carrying its
// name, so two BE rates under one name would be a p99 for a load nobody offered.

func TestTheTailCrossingStudiesHaveOneArmPerBELevelAndNoBareShared(t *testing.T) {
	for _, id := range []string{StudyTailCrossingShortLC, StudyTailCrossingLongLC} {
		s, _ := LookupStudy(id)
		if !s.Admits(ArmR1) {
			t.Errorf("%s does not admit the isolated baseline", id)
		}
		if s.Admits(ArmShared) {
			t.Errorf("%s admits a bare %q, which names no BE rate and would pool every level into one arm", id, ArmShared)
		}
		for _, want := range []string{"be01-shared", "be06-shared"} {
			if !s.Admits(want) {
				t.Errorf("%s does not admit %s", id, want)
			}
		}
		if s.Admits("be07-shared") || s.Admits("be00-shared") {
			t.Errorf("%s admits a level outside 1..6", id)
		}
	}
}

func TestTheTailCrossingStudiesRegisterIndependentArrivals(t *testing.T) {
	for _, id := range []string{StudyTailCrossingShortLC, StudyTailCrossingLongLC} {
		if s, _ := LookupStudy(id); s.Arrivals != ArrivalsIndependent {
			t.Errorf("%s registers %q arrivals; a weighted mix would move the latency-critical arrivals whenever the BE rate moved", id, s.Arrivals)
		}
	}
}

// A BE level is a contended arm in the baseline's comparison group: the report pairs R1's repetition r with
// every level's repetition r, which is only right because independent arrivals give them one LC schedule.
func TestABELevelIsContendedAndComparedWithTheBaseline(t *testing.T) {
	arm := TailCrossingArm(2)
	if arm != "be02-shared" {
		t.Fatalf("TailCrossingArm(2) = %q", arm)
	}
	if IsIsolatedBaseline(arm) {
		t.Errorf("%s is treated as an isolated baseline, so gen-trace would strip its contender", arm)
	}
	if ArmComparisonGroup(arm) != ArmComparisonGroup(ArmR1) {
		t.Errorf("%s is in group %q and R1 in %q, so the report would never pair them", arm, ArmComparisonGroup(arm), ArmComparisonGroup(ArmR1))
	}
}

func TestATailCrossingPlanNeedsTheBaselineAndAtLeastOneLevel(t *testing.T) {
	study := StudyTailCrossingShortLC
	if err := MatrixPlanArmSetRefusal(study, []string{ArmR1, TailCrossingArm(1), TailCrossingArm(3)}); err != nil {
		t.Errorf("a baseline and two levels were refused: %v", err)
	}
	err := MatrixPlanArmSetRefusal(study, []string{ArmR1})
	if err == nil || !strings.Contains(err.Error(), "contended") {
		t.Errorf("a plan with no BE level was not refused for it: %v", err)
	}
	err = MatrixPlanArmSetRefusal(study, []string{TailCrossingArm(1)})
	if err == nil || !strings.Contains(err.Error(), ArmR1) {
		t.Errorf("a plan with no baseline was not refused for it: %v", err)
	}
	// And the sharing matrix keeps its own requirement: its control is the bare `shared`.
	err = MatrixPlanArmSetRefusal(StudySharingMatrix, []string{ArmR1, "timeSlicing"})
	if err == nil || !strings.Contains(err.Error(), ArmShared) {
		t.Errorf("the sharing matrix lost its control requirement: %v", err)
	}
}
