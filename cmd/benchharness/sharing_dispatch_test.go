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
	"path/filepath"
	"strings"
	"testing"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// The sharing readings need R1 and `shared`, and a missing one must produce NO readings rather than readings
// computed against a zero ArmSummary.
//
// A zero value has TTFTMsP99 = 0, so every ratio built from it is either 0 or a division this code guards
// into 0 -- and every one of those still PRINTS, as a number a reader would take for a measurement. This is
// the same failure the price-of-protection evaluator was fixed for, arriving one level up in the dispatch.
func TestTheSharingReadingsAreNotEvaluatedWithoutTheirDenominators(t *testing.T) {
	full := map[string]bench.ArmSummary{
		bench.ArmR1:          {Arm: bench.ArmR1, TTFTMsP99: 67.3, TailSampleSize: 200},
		bench.ArmShared:      {Arm: bench.ArmShared, TTFTMsP99: 1400, TailSampleSize: 200},
		bench.ArmTimeSlicing: {Arm: bench.ArmTimeSlicing, TTFTMsP99: 900, TailSampleSize: 200},
	}
	order := []bench.ArmSummary{full[bench.ArmR1], full[bench.ArmShared], full[bench.ArmTimeSlicing]}

	// frozen is nil throughout: this test is about the arms that divide, not about the declared load, and a
	// study that froze no tuple is the case reading 4e reports as uncomputable rather than silently skipping.
	if got := evaluateSharingMatrix(full, order, nil, nil); got == nil {
		t.Fatal("complete evidence produced no readings at all")
	}

	for _, missing := range []string{bench.ArmR1, bench.ArmShared} {
		partial := map[string]bench.ArmSummary{}
		var kept []bench.ArmSummary
		for name, s := range full {
			if name == missing {
				continue
			}
			partial[name] = s
			kept = append(kept, s)
		}
		got := evaluateSharingMatrix(partial, kept, nil, nil)
		// AMENDED 2026-09-12. This used to require nil, and nil was worse than it looked: the caller only
		// runs the verdict when this is non-nil, so `report` printed a stderr warning and exited ZERO --
		// and the paid runner calls it as `... || fail`. The property worth holding is not "no result" but
		// "no ratio computed from a zero ArmSummary", and one uncomputable gate says that out loud.
		if got == nil {
			t.Fatalf("evidence missing %s produced no result at all, so the verdict block never runs and the "+
				"command exits zero on a run with no %s", missing, missing)
		}
		// AMENDED 2026-10-03, from 1 to 2. The declared-load gate is prepended on BOTH of this wrapper's
		// exits, deliberately: a check that vanishes on the path where the evidence is already in doubt is
		// the shape this repository keeps finding in its own gates. Still an exact count rather than a
		// minimum, because the property being held is that nothing is SCORED here -- a third reading would
		// mean a ratio built from a zero ArmSummary had been computed after all.
		if len(got.Readings) != 2 {
			t.Errorf("evidence missing %s produced %d readings, want the declared-load gate plus one refusal; "+
				"every ratio beyond those is built from a zero ArmSummary and would print as a measurement",
				missing, len(got.Readings))
		}
		// Found by ID rather than by index. The refusal used to be Readings[0] and is now behind 4e, and an
		// index would have gone on passing while asserting something about a different reading.
		var refusal bench.PoPReading
		for _, r := range got.Readings {
			if r.ID == "4" {
				refusal = r
			}
		}
		if refusal.ID == "" {
			t.Errorf("evidence missing %s produced no reading 4 at all; the refusal that names the missing "+
				"denominator is the one a reader needs", missing)
		} else {
			if !refusal.NotEvaluable || refusal.Fired {
				t.Errorf("the reading for evidence missing %s is not a refusal (fired=%v, n/e=%v): %s",
					missing, refusal.Fired, refusal.NotEvaluable, refusal.Detail)
			}
			if !strings.Contains(refusal.Detail, missing) {
				t.Errorf("the refusal does not name the missing arm %s: %s", missing, refusal.Detail)
			}
		}
		if got.Answer != "" {
			t.Errorf("evidence missing %s produced the answer %q", missing, got.Answer)
		}
		// And it must reach the process's exit status, which is the thing the paid runner reads.
		if err := sharingRunInvalid(*got); err == nil {
			t.Errorf("a run with no %s arm exits zero; `benchharness report ... || fail` would accept it", missing)
		}
	}
}

// The declared-load gate is on the page whatever else happened, and it is FIRST.
//
// sharingRunInvalid walks the readings and returns on the first one it recognises, so a gate that is absent
// from the list is a gate that cannot fail -- "we never checked" and "we checked and it agreed" would share
// an exit status and a printed page. That is the defect class this whole gate exists to close, and it would
// be perfectly possible to reintroduce it here by attaching 4e on only the scored path.
//
// FIRST because it is a premise. Readings 4 and 4b ask whether the load created contention; a reader who
// meets them above the gate is reading answers about a trace nobody has vouched for yet.
func TestTheDeclaredLoadGateIsPresentOnEveryPathAndComesFirst(t *testing.T) {
	complete := map[string]bench.ArmSummary{
		bench.ArmR1:          {Arm: bench.ArmR1, TTFTMsP99: 67.3, TailSampleSize: 200},
		bench.ArmShared:      {Arm: bench.ArmShared, TTFTMsP99: 1400, TailSampleSize: 200},
		bench.ArmTimeSlicing: {Arm: bench.ArmTimeSlicing, TTFTMsP99: 900, TailSampleSize: 200},
	}
	for _, tc := range []struct {
		name string
		summ map[string]bench.ArmSummary
	}{
		{name: "the scored path", summ: complete},
		{
			name: "the missing-baseline refusal path",
			summ: map[string]bench.ArmSummary{bench.ArmShared: complete[bench.ArmShared]},
		},
		{name: "no arms at all", summ: map[string]bench.ArmSummary{}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var order []bench.ArmSummary
			for _, s := range tc.summ {
				order = append(order, s)
			}
			got := evaluateSharingMatrix(tc.summ, order, nil, nil)
			if got == nil {
				t.Fatal("no result at all, so neither the gate nor the verdict block runs")
			}
			if len(got.Readings) == 0 || got.Readings[0].ID != "4e" {
				var ids []string
				for _, r := range got.Readings {
					ids = append(ids, r.ID)
				}
				t.Fatalf("the declared-load gate is not the first reading; the readings were %v", ids)
			}
			// And it must reach the exit status, which is what the paid runner reads.
			if err := sharingRunInvalid(*got); err == nil {
				t.Error("the gate came back uncomputable and the run exited zero; " +
					"`benchharness report ... || fail` would accept a load nobody vouched for")
			}
		})
	}
}

// A gate that speaks takes the ANSWER away, because a verdict printed beside a refusal is read as a verdict.
func TestAnUnvouchedLoadWithholdsTheAnswer(t *testing.T) {
	summ := map[string]bench.ArmSummary{
		bench.ArmR1:          {Arm: bench.ArmR1, TTFTMsP99: 67.3, TailSampleSize: 200},
		bench.ArmShared:      {Arm: bench.ArmShared, TTFTMsP99: 1400, TailSampleSize: 200},
		bench.ArmTimeSlicing: {Arm: bench.ArmTimeSlicing, TTFTMsP99: 900, TailSampleSize: 200},
	}
	order := []bench.ArmSummary{summ[bench.ArmR1], summ[bench.ArmShared], summ[bench.ArmTimeSlicing]}

	got := evaluateSharingMatrix(summ, order, nil, nil)
	if got.Answer != "" {
		t.Errorf("the declared-load gate could not be computed and the page still answered %q", got.Answer)
	}
	page := bench.FormatSharingMatrix(*got)
	if !strings.Contains(page, "ANSWER: withheld") {
		t.Errorf("the page does not say the answer was withheld, so a reader sees a blank where a reason "+
			"belongs:\n%s", page)
	}
	if strings.Contains(page, "gap in the outcome space") {
		t.Errorf("the page calls an unvouched load a gap in the outcome space, which invites another paid "+
			"run to fill a gap that is not there:\n%s", page)
	}
}

// Everything that is not R1 or `shared` is a sharing arm, taken as present rather than looked up by name.
//
// An operator running ARMS="shared timeSlicing" should get a matrix with one sharing arm and a reading that
// says the other is absent -- not a name lookup that misses and reports a mode as having failed to engage.
func TestASubsetRunIsAMatrixWithFewerArmsRatherThanAFailedOne(t *testing.T) {
	summ := map[string]bench.ArmSummary{
		bench.ArmR1:          {Arm: bench.ArmR1, TTFTMsP99: 67.3, TailSampleSize: 200},
		bench.ArmShared:      {Arm: bench.ArmShared, TTFTMsP99: 1400, TailSampleSize: 200},
		bench.ArmTimeSlicing: {Arm: bench.ArmTimeSlicing, TTFTMsP99: 900, TailSampleSize: 200},
	}
	order := []bench.ArmSummary{summ[bench.ArmR1], summ[bench.ArmShared], summ[bench.ArmTimeSlicing]}

	res := evaluateSharingMatrix(summ, order, nil, nil)
	if res == nil {
		t.Fatal("a two-arm matrix produced no readings")
	}
	var fourC bench.PoPReading
	for _, r := range res.Readings {
		if r.ID == "4c" {
			fourC = r
		}
	}
	if fourC.Fired {
		t.Errorf("reading 4c fired for an arm the operator simply did not run: %s", fourC.Detail)
	}
}

// The refusal the runner writes must be the refusal the report finds, from a directory it discovers itself.
//
// Reading 4c can only fire on a recorded refusal, and nothing outside the unit tests populated that map
// until refusalsBeside existed. The firing itself is covered in internal/bench; what is covered here is the
// half that cannot be: that a file written beside the raw evidence is picked up without an operator
// remembering a flag, and that an absent file yields no refusals rather than an empty-string entry.
func TestTheReportFindsTheRefusalTheRunnerWroteBesideTheEvidence(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{"raw-R1-1.jsonl", "raw-shared-1.jsonl"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("{}\n"), 0o600); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}

	if got := refusalsBeside([]string{filepath.Join(dir, "raw-R1-1.jsonl")}); len(got) != 0 {
		t.Errorf("a directory with no refusal file yielded %v; an arm that was never refused must not appear "+
			"as one with an empty reason", got)
	}

	want := "the engines are not MPS clients"
	if err := os.WriteFile(filepath.Join(dir, "refused-mps.txt"), []byte(want+"\n"), 0o600); err != nil {
		t.Fatalf("write the refusal: %v", err)
	}
	got := refusalsBeside([]string{filepath.Join(dir, "raw-R1-1.jsonl"), filepath.Join(dir, "raw-shared-1.jsonl")})
	if got["mps"] != want {
		t.Errorf("the report read %q for the mps arm and the runner wrote %q. The reason lives beside the raw "+
			"files precisely so that `benchharness report` needs no extra argument to see it", got["mps"], want)
	}

	// An empty file is not a refusal. The runner writes a reason or it writes nothing.
	if err := os.WriteFile(filepath.Join(dir, "refused-timeSlicing.txt"), []byte("  \n"), 0o600); err != nil {
		t.Fatalf("write the empty refusal: %v", err)
	}
	if _, ok := refusalsBeside([]string{filepath.Join(dir, "raw-R1-1.jsonl")})["timeSlicing"]; ok {
		t.Error("an empty refusal file was read as a refusal, which would fire reading 4c with no reason to give")
	}
}
