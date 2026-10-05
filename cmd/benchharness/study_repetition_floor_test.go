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

package main

import (
	"os"
	"strconv"
	"strings"
	"testing"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// The repetition floor is a property of the STUDY, and these pin that the report says so when it is unmet.
//
// WHY A WARNING AND NOT A REFUSAL. By the time a report runs the cells are paid for. Declining to print the
// tables would leave an operator with evidence and no way to read it, so the floor is reported beside the
// measurements rather than instead of them. What must not happen is the opposite: a report that prints a
// median over fewer blocks than the registration fixed and says nothing.
//
// The floors themselves are pinned in internal/bench/study_test.go as literals. What is pinned here is that
// the comparison runs, that it reads the study the evidence carries, and that a study which registered no
// floor is not judged against an invented one.

// floorFixture writes `reps` repetitions of a study's first two arms and returns the loaded evidence.
//
// One file is one repetition: repIDFromPath reads the identity out of the filename, so the repetition count
// comes from how many files are written rather than from how many rows each holds. replayedAgain shifts the
// send timestamps, because two files with identical ones are the same replay counted twice and the loader
// refuses that by design.
//
// THE ARMS COME FROM THE REGISTRY, and the first version of this helper hardcoded R1 and shared. That is
// fine for three of the four studies here and wrong for the fourth: price-of-protection admits R1 and
// default-fcfs, so loadArmEvidence refused the fixture with "study price-of-protection-2026-09-05 does not
// admit shared" and the test failed for a reason that had nothing to do with repetition floors. A fixture
// refused by an earlier guard tests nothing, and it looks exactly like the rule under test firing.
//
// Deriving rather than listing is acceptable BECAUSE this is a fixture and not an assertion: the floors
// themselves are pinned as literals in internal/bench/study_test.go, where building the expectation from
// production values would prove only that the registry agrees with itself.
func floorFixture(t *testing.T, study string, reps int) *armEvidence {
	t.Helper()
	s, ok := bench.LookupStudy(study)
	if !ok {
		t.Fatalf("study %s is not registered, so this fixture cannot name its arms", study)
	}
	if len(s.Arms) < 2 {
		t.Fatalf("study %s declares %d arm(s); this fixture needs two to produce a summary per arm", study, len(s.Arms))
	}
	dir := t.TempDir()
	var paths []string
	for _, arm := range s.Arms[:2] {
		for i := 1; i <= reps; i++ {
			// A study registering a trace per repetition refuses two repetitions of one trace, so its fixture
			// draws one per repetition; the latency-critical schedule rowsFor writes is the same in every
			// repetition and in both arms, which keeps the baseline paired with its contended repetition.
			sum := "T"
			if s.TracesVaryByRepetition {
				sum = "T" + strconv.Itoa(i)
			}
			rows := rowsFor(study, arm, sum)
			for j := 1; j < i; j++ {
				rows = replayedAgain(rows)
			}
			paths = append(paths, writeRaw(t, dir, "raw-"+arm+"-"+strconv.Itoa(i)+".jsonl", rows))
		}
	}
	e, err := loadArmEvidence(paths)
	if err != nil {
		t.Fatalf("fixture for %s at %d repetition(s) did not load: %v", study, reps, err)
	}
	return e
}

func TestAStudysRepetitionFloorIsReportedWhenUnmet(t *testing.T) {
	// The sharing matrix registered five. One repetition per arm is four short of it.
	e := floorFixture(t, bench.StudySharingMatrix, 1)
	summaries, _ := e.summarize()

	why := e.repetitionFloorShortfall(summaries)
	if why == "" {
		t.Fatal("one repetition per arm passed a floor of five with nothing said")
	}
	for _, want := range []string{bench.StudySharingMatrix, "floor of 5", bench.ArmR1, bench.ArmShared} {
		if !strings.Contains(why, want) {
			t.Errorf("the sentence does not name %q: %s", want, why)
		}
	}
	// The prefix is what the caller prepends, so the label has to travel with the sentence: `report` adds no
	// branch of its own, and an unlabelled sentence at the top of a report reads as part of the tables.
	prefix := e.repetitionFloorPrefix(summaries)
	if !strings.Contains(prefix, "REPETITION FLOOR NOT MET") {
		t.Errorf("the prefix carries no label: %q", prefix)
	}
	if !strings.Contains(prefix, why) {
		t.Errorf("the prefix does not carry the sentence: %q", prefix)
	}
}

// And the exploratory levels, whose registration fixed TWO, are not warned at two.
//
// This is the control that makes the whole change worth having: a floor shared by every study would either
// warn on every cell of this experiment or warn on none of the confirmatory one.
func TestTheExploratoryLevelsAreNotWarnedAtTwoRepetitions(t *testing.T) {
	for _, study := range []string{bench.StudyTailCrossingShortLC, bench.StudyTailCrossingMidLC, bench.StudyTailCrossingLongLC} {
		t.Run(study, func(t *testing.T) {
			e := floorFixture(t, study, 2)
			summaries, _ := e.summarize()
			if why := e.repetitionFloorShortfall(summaries); why != "" {
				t.Errorf("%s registered a floor of 2 and two repetitions were reported short: %s", study, why)
			}
			if p := e.repetitionFloorPrefix(summaries); p != "" {
				t.Errorf("%s got a prefix at its own floor: %q", study, p)
			}
		})
	}
	// One repetition IS short of two, so the same study is checked in both directions. A floor that never
	// fires is indistinguishable from one that is not read.
	e := floorFixture(t, bench.StudyTailCrossingShortLC, 1)
	summaries, _ := e.summarize()
	if why := e.repetitionFloorShortfall(summaries); why == "" {
		t.Error("one repetition passed the exploratory floor of two")
	} else if !strings.Contains(why, "floor of 2") {
		t.Errorf("the sentence quotes the wrong floor: %s", why)
	}
}

// A study that registered NO floor is not judged against one.
//
// Zero means "this registration did not say", the way a nil Frozen does. Treating it as a floor of none
// would be an empty expectation that passes every value, which is this package's commonest defect shape;
// treating it as five would make this file assert something the ladder's registration does not.
func TestAStudyThatFixedNoFloorIsNotJudged(t *testing.T) {
	e := floorFixture(t, bench.StudyPriceOfProtection, 1)
	summaries, _ := e.summarize()
	if why := e.repetitionFloorShortfall(summaries); why != "" {
		t.Errorf("a study with no registered floor was judged: %s", why)
	}
}

// The thin-tail refusals must not be what produces the sentence.
//
// rowsFor writes four rows, far below MinTailSamples, so every arm in these fixtures is already disqualified
// by the tail floors. If the shortfall sentence were coming from those instead of from the repetition count,
// every assertion above would pass for the wrong reason -- the shape where an earlier guard shadows the one
// being probed. So the count is asserted directly: four rows, one repetition, and a sentence that quotes the
// REPETITION number rather than the sample size.
func TestTheSentenceComesFromTheRepetitionCountAndNotTheTailFloor(t *testing.T) {
	e := floorFixture(t, bench.StudySharingMatrix, 1)
	summaries, _ := e.summarize()
	for _, s := range summaries {
		if s.RepetitionCount != 1 {
			t.Fatalf("arm %s has RepetitionCount %d; the fixture is meant to carry exactly one", s.Arm, s.RepetitionCount)
		}
		if s.TailSampleSize >= bench.MinTailSamples {
			t.Fatalf("arm %s has a tail of %d, so this fixture no longer tests the case it was written for", s.Arm, s.TailSampleSize)
		}
	}
	why := e.repetitionFloorShortfall(summaries)
	if !strings.Contains(why, "has 1") {
		t.Errorf("the sentence does not quote the repetition count: %s", why)
	}
	if strings.Contains(why, "premium completions") || strings.Contains(why, "nearest-rank") {
		t.Errorf("the sentence is the tail floor's, not the repetition floor's: %s", why)
	}
}

// An id the registry does not know falls back to the gateway study, exactly as its two siblings do.
//
// Nothing reaches the report this way: loadArmEvidence refuses an unregistered study by name, and
// LookupStudy maps the empty id to the gateway study. Measured 2026-10-04 -- replacing the branch with
// `study, _ :=` left the whole package green, so it is unreachable through the command. It is kept because
// contendedArms and summarize fall back at the same point for the same reason, and a function that answered
// differently about the same input would be the odd one of three.
//
// Pinned by calling the method on a hand-built armEvidence, which is the only way to supply a study id the
// loader would have rejected. The fallback has an observable effect -- the gateway study's floor is five --
// so this asserts the floor that was applied rather than merely that nothing crashed.
func TestAnUnregisteredStudyFallsBackToTheGatewayFloor(t *testing.T) {
	e := &armEvidence{study: "not-a-registered-study-2026"}
	summaries := []bench.ArmSummary{
		{Arm: bench.ArmR1, RepetitionCount: 1},
		{Arm: "static-cap", RepetitionCount: 1},
	}
	why := e.repetitionFloorShortfall(summaries)
	if why == "" {
		t.Fatal("an unregistered study waived the floor entirely; the fallback must apply the gateway study's")
	}
	if !strings.Contains(why, "floor of 5") {
		t.Errorf("the fallback did not apply the gateway study's floor of five: %s", why)
	}
	if !strings.Contains(why, bench.StudyM5BGateway) {
		t.Errorf("the sentence does not name the study whose floor was applied: %s", why)
	}
	// And the registered case is unaffected, so the fallback is not swallowing real ids.
	e2 := &armEvidence{study: bench.StudyTailCrossingShortLC}
	if why := e2.repetitionFloorShortfall([]bench.ArmSummary{
		{Arm: bench.ArmR1, RepetitionCount: 2},
		{Arm: bench.ArmShared, RepetitionCount: 2},
	}); why != "" {
		t.Errorf("a registered study at its own floor was reported short: %s", why)
	}
}

// The call site is pinned as TEXT, because deleting it would leave every assertion above green.
//
// Each test here calls the two functions directly. That proves they compute the right answer and says
// nothing about whether the report asks them -- and a function nothing calls is this repository's recorded
// defect shape. So the number of call sites is read off the file.
func TestTheReportActuallyAsksForTheFloor(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatalf("read main.go: %v", err)
	}
	body := string(src)
	if n := strings.Count(body, "e.repetitionFloorPrefix(summaries)"); n != 1 {
		t.Errorf("the prefix is called %d time(s) in report's path; one call is what puts the sentence in the report and in the file it writes", n)
	}
	// And it is prepended to the report text rather than printed to stderr, so the archive keeps it.
	if !strings.Contains(body, "e.repetitionFloorPrefix(summaries) + bench.FormatReport(") {
		t.Error("the prefix is no longer prepended to the report text; a warning only on the terminal is one the archive does not keep")
	}
}
