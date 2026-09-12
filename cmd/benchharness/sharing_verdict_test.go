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
	"strings"
	"testing"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// The exit status must separate a refused ARM from a refused RUN.
//
// hack/m5c-matrix.sh calls `benchharness report ... || fail`, so this predicate decides whether a paid
// session is reported as having produced nothing. It used to match the substring "INVALID" against the
// reading's NAME, and reading 4c is named "the sharing mode did not engage -- INVALID for that arm" -- so
// a run that measured time-slicing and merely failed to bring MPS up was thrown away whole. MPS has
// already been measured failing to engage on this AMI, which makes that the expected run, not an edge.
func TestOnlyTheWholeRunGatesTheExitStatus(t *testing.T) {
	for _, tc := range []struct {
		name    string
		reading bench.PoPReading
		invalid bool
	}{
		{
			name:    "4 fired: the load made no contention, so nothing under it means anything",
			reading: bench.PoPReading{ID: "4", Name: "the load did not create contention -- INVALID", Fired: true},
			invalid: true,
		},
		{
			name:    "4b fired: the load was too high for any arm to be measured",
			reading: bench.PoPReading{ID: "4b", Name: "the load was too high to measure -- INVALID", Fired: true},
			invalid: true,
		},
		{
			name:    "4c fired: one arm did not engage, and the arm beside it was still measured",
			reading: bench.PoPReading{ID: "4c", Name: "the sharing mode did not engage -- INVALID for that arm", Fired: true, Cell: bench.ArmMPS},
			invalid: false,
		},
		{
			name:    "4 did not fire",
			reading: bench.PoPReading{ID: "4", Name: "the load did not create contention -- INVALID"},
			invalid: false,
		},
		{
			// A gate that could not be computed is not a run that stands: it says the evidence could not be
			// assessed. This exited zero, so the paid runner accepted a censored control as a good session.
			name:    "4 could not be evaluated: the control's tail is censored",
			reading: bench.PoPReading{ID: "4", Name: "the load did not create contention -- INVALID", NotEvaluable: true},
			invalid: true,
		},
		{
			name:    "4b could not be evaluated",
			reading: bench.PoPReading{ID: "4b", Name: "the load was too high to measure -- INVALID", NotEvaluable: true},
			invalid: true,
		},
		{
			// But a reading BELOW the gates coming back NotEvaluable is an ordinary "no finding".
			name:    "1 could not be evaluated",
			reading: bench.PoPReading{ID: "1", Name: "separation protects -- POSITIVE", NotEvaluable: true},
			invalid: false,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := sharingRunInvalid(bench.SharingResult{Readings: []bench.PoPReading{tc.reading}})
			switch {
			case tc.invalid && err == nil:
				t.Errorf("reading %s fired and the run exited zero; the paid runner would accept evidence "+
					"the readings had just disqualified", tc.reading.ID)
			case !tc.invalid && err != nil:
				t.Errorf("reading %s made the whole run invalid: %v", tc.reading.ID, err)
			case tc.invalid && !strings.Contains(err.Error(), "run invalid"):
				t.Errorf("the error does not identify the run as invalid: %v", err)
			}
		})
	}
}
