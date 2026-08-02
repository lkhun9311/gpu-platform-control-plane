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
	if strings.Count(out, "admitLatency") != strings.Count(out, "readyLatency") {
		t.Fatalf("every admission must be reported next to an execution start:\n%s", out)
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
}
