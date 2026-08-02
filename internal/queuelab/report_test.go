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

package queuelab

import (
	"strings"
	"testing"
)

// TestRenderResultAlwaysExposesExecutionStart is the regression guard for the published overclaim: a report
// that shows only admission lets "the owner was admitted in 120 ms" stand for "the owner was running".
func TestRenderResultAlwaysExposesExecutionStart(t *testing.T) {
	res, err := Reconstruct("Any", reclaimAnyTrace(), ineffectivePreemptionEvents(), 200*sec)
	if err != nil {
		t.Fatal(err)
	}
	out := RenderResult(res)
	for _, want := range []string{"admitLatency", "readyLatency", "admitToReady"} {
		if !strings.Contains(out, want) {
			t.Fatalf("rendered report is missing %q:\n%s", want, out)
		}
	}
	assertTimingLinesAdjacent(t, out, len(res.Outcomes))
}

// assertTimingLinesAdjacent checks per-line adjacency rather than aggregate label counts, because two counts
// that match across the whole output can still hide a refactor that moved admissions and execution starts
// into separate sections: the figures must sit on the SAME line to keep the framing this guard exists for.
func assertTimingLinesAdjacent(t *testing.T, out string, wantLines int) {
	t.Helper()
	timingLines := 0
	for _, line := range strings.Split(out, "\n") {
		if !strings.Contains(line, "admitLatency=") {
			continue
		}
		timingLines++
		if !strings.Contains(line, "readyLatency=") || !strings.Contains(line, "admitToReady=") {
			t.Fatalf("line reports admitLatency without readyLatency and admitToReady beside it: %q", line)
		}
	}
	if timingLines != wantLines {
		t.Fatalf("got %d timing lines, want %d (one per outcome, none silently dropped):\n%s", timingLines, wantLines, out)
	}
}

// TestRenderResultExposesExecutionStartForUnexecutedRows guards the row a refactor is most likely to drop
// silently: one that was offered but never admitted and never executed, so it has no execution timing to
// report. Its missing execution is exactly the fact the guard exists to keep visible, not to hide.
func TestRenderResultExposesExecutionStartForUnexecutedRows(t *testing.T) {
	events := ineffectivePreemptionEvents()
	filtered := events[:0]
	for _, e := range events {
		if e.Job == "b1" && (e.Type == EventAdmitted || e.Type == EventPodReady || e.Type == EventCompleted) {
			continue
		}
		filtered = append(filtered, e)
	}
	res, err := Reconstruct("Any", reclaimAnyTrace(), filtered, 200*sec)
	if err != nil {
		t.Fatal(err)
	}
	var b1 WorkloadOutcome
	for _, o := range res.Outcomes {
		if o.Job == "b1" {
			b1 = o
		}
	}
	if b1.Admitted || b1.Executed {
		t.Fatalf("b1 must be offered but never admitted and never executed for this test to be meaningful: %+v", b1)
	}
	out := RenderResult(res)
	assertTimingLinesAdjacent(t, out, len(res.Outcomes))
	// Ensure censoredWait is rendered for the never-admitted row with its caveat text.
	if !strings.Contains(out, "censoredWait=") || !strings.Contains(out, "(never admitted by horizon)") {
		t.Fatalf("censoredWait with caveat must be rendered for never-admitted rows:\n%s", out)
	}
}

func TestRenderResultSurfacesIneffectivePreemption(t *testing.T) {
	res, err := Reconstruct("Any", reclaimAnyTrace(), ineffectivePreemptionEvents(), 200*sec)
	if err != nil {
		t.Fatal(err)
	}
	out := RenderResult(res)
	if !strings.Contains(out, "PREEMPTION INEFFECTIVE") {
		t.Fatalf("an ineffective preemption must be stated loudly:\n%s", out)
	}
	if !strings.Contains(out, "unattributedOccupancy") {
		t.Fatalf("unattributed occupancy must be reported:\n%s", out)
	}
	// The per-row flag must be pinned on the row that carries it. The earlier form searched the timing line
	// for the job name, which that line does not contain, so its failure branch was unreachable and deleting
	// the field from the renderer would not have failed any test.
	foundIneffectiveRow := false
	for _, o := range res.Outcomes {
		if !o.PreemptionIneffective {
			continue
		}
		foundIneffectiveRow = true
		if !hasLineWith(out, o.Job, "preemptionIneffective=true") {
			t.Fatalf("job %s had ineffective preemption but no row line states preemptionIneffective=true:\n%s", o.Job, out)
		}
	}
	if !foundIneffectiveRow {
		t.Fatalf("no row with ineffective preemption found in outcomes, test setup may be broken: %+v", res.Outcomes)
	}
	// A row without the flag must say so on its own line, so the field is pinned as a per-row value rather
	// than as a string that merely appears somewhere in the output.
	for _, o := range res.Outcomes {
		if !o.PreemptionIneffective && !hasLineWith(out, o.Job, "preemptionIneffective=false") {
			t.Fatalf("row %s should render preemptionIneffective=false:\n%s", o.Job, out)
		}
	}
}

// hasLineWith reports whether any single line of out contains all the given substrings, which is how a
// per-row field is pinned to its own row rather than to the output as a whole.
func hasLineWith(out string, substrings ...string) bool {
	for _, line := range strings.Split(out, "\n") {
		all := true
		for _, s := range substrings {
			if !strings.Contains(line, s) {
				all = false
				break
			}
		}
		if all {
			return true
		}
	}
	return false
}

func TestRenderResultSummarizesOccupancyAndReExecution(t *testing.T) {
	// The run-level summary is what a reader takes away, and hiding re-execution there is exactly what the
	// published run did: the header showed admissions and waste with no sign that a completed attempt had
	// been re-run from zero.
	res, err := Reconstruct("Any", reclaimAnyTrace(), reExecutionEvents(), 200*sec)
	if err != nil {
		t.Fatal(err)
	}
	if res.ReExecutedRows != 1 {
		t.Fatalf("ReExecutedRows = %d, want 1", res.ReExecutedRows)
	}
	var want float64
	for _, o := range res.Outcomes {
		want += o.TotalOccupancyGPUSeconds
	}
	if res.TotalOccupancyGPUSeconds != want {
		t.Fatalf("TotalOccupancyGPUSeconds = %.1f, want %.1f (the sum over rows)", res.TotalOccupancyGPUSeconds, want)
	}
	out := RenderResult(res)
	header := strings.Split(out, "  a1")[0]
	for _, s := range []string{"totalOccupancyGPUSeconds=", "reExecutedRows=1"} {
		if !strings.Contains(header, s) {
			t.Fatalf("run-level header is missing %q:\n%s", s, out)
		}
	}
}

func TestRenderResultReportsOccupancyAgainstServiceTime(t *testing.T) {
	// A bare totalOccupancy=81.0 means nothing; "81 s for a 40 s job" is the entire finding, so the row's
	// declared service time has to sit beside its occupancy.
	res, err := Reconstruct("Any", reclaimAnyTrace(), reExecutionEvents(), 200*sec)
	if err != nil {
		t.Fatal(err)
	}
	for _, o := range res.Outcomes {
		if o.ServiceDurationSec == 0 {
			t.Fatalf("row %s carries no service time from its trace row", o.Job)
		}
	}
	out := RenderResult(res)
	if !hasLineWith(out, "totalOccupancy=", "serviceTime=") {
		t.Fatalf("occupancy must be rendered beside the row's service time:\n%s", out)
	}
}

func TestRenderResultStatesUncreditedLossOnReExecutedIneffectiveRow(t *testing.T) {
	// waste=0.0 is true about mechanism and false about loss: the attempt succeeded, was not credited, and
	// re-ran from zero. Replacing an overclaim with an underclaim is not a fix, so the banner must state the
	// loss rather than leave a reader to infer it from a zero.
	res, err := Reconstruct("Any", reclaimAnyTrace(), reExecutionEvents(), 200*sec)
	if err != nil {
		t.Fatal(err)
	}
	var found bool
	for _, o := range res.Outcomes {
		if o.PreemptionIneffective && o.ReExecuted {
			found = true
		}
	}
	if !found {
		t.Fatalf("fixture must contain a row that is both ineffective and re-executed: %+v", res.Outcomes)
	}
	out := RenderResult(res)
	banner := ""
	for _, line := range strings.Split(out, "\n") {
		if strings.Contains(line, "PREEMPTION INEFFECTIVE") {
			banner = line
		}
	}
	if banner == "" {
		t.Fatalf("an ineffective preemption must be stated loudly:\n%s", out)
	}
	for _, s := range []string{"NOT credited", "re-executed"} {
		if !strings.Contains(banner, s) {
			t.Fatalf("banner must state that the completed attempt's work was %q: %q", s, banner)
		}
	}
}
