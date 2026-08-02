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
	// Ensure censoredWait is not rendered for rows that were admitted.
	for _, o := range res.Outcomes {
		if o.Admitted {
			// Admitted rows should have their outcome line with admitLatency but no censoredWait in that section.
			lines := strings.Split(out, "\n")
			for i, line := range lines {
				// Find the line for this admitted job.
				if strings.Contains(line, o.Job) && strings.Contains(line, "admitted=true") {
					// The next line should have the timing info without censoredWait.
					if i+1 < len(lines) && strings.Contains(lines[i+1], "admitLatency=") {
						if strings.Contains(lines[i+1], "censoredWait=") {
							t.Fatalf("censoredWait must not appear for admitted row %s:\n%s", o.Job, lines[i+1])
						}
					}
					break
				}
			}
		}
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
	// Ensure per-row preemptionIneffective field appears for rows that experienced ineffective preemption.
	foundIneffectiveRow := false
	for _, o := range res.Outcomes {
		if o.PreemptionIneffective {
			foundIneffectiveRow = true
			lines := strings.Split(out, "\n")
			for _, line := range lines {
				// Find the line for this preempted job with its preemptionIneffective field.
				if strings.Contains(line, o.Job) && strings.Contains(line, "preemptionIneffective=true") {
					break
				}
				if strings.Contains(line, o.Job) && strings.Contains(line, "admitLatency=") {
					t.Fatalf("job %s had ineffective preemption but preemptionIneffective=true not found in output:\n%s", o.Job, out)
				}
			}
		}
	}
	if !foundIneffectiveRow {
		t.Fatalf("no row with ineffective preemption found in outcomes, test setup may be broken: %+v", res.Outcomes)
	}
}
