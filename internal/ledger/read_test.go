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

package ledger

import (
	"errors"
	"strings"
	"testing"
	"time"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// Reading has one job beyond returning rows: it must never let an absence read as a fact. A run nobody
// projected is a distinct error, an empty ledger is a legitimate empty answer, and an offset with no origin
// gets no wall clock rather than a plausible wrong one.

func TestGettingARunNobodyProjectedIsAnError(t *testing.T) {
	s := openTemp(t)
	_, _, err := s.GetWorkloadRun("default", "never-ran")
	if err == nil {
		t.Fatal("GetWorkloadRun returned a record for a run the ledger does not hold")
	}
	if !errors.Is(err, ErrNoSuchRun) {
		t.Fatalf("the error does not identify itself as an absent run, so a caller cannot tell it from a read failure: %v", err)
	}
	if !strings.Contains(err.Error(), "default/never-ran") {
		t.Fatalf("the error does not name what was looked for: %v", err)
	}
}

// An empty ledger is a real answer, reachable only because OpenForRead refuses one it cannot read.
func TestListingAnEmptyLedgerIsAnEmptyAnswerNotAnError(t *testing.T) {
	s := openTemp(t)
	runs, err := s.ListWorkloadRuns()
	if err != nil {
		t.Fatalf("listing an empty ledger failed: %v", err)
	}
	if len(runs) != 0 {
		t.Fatalf("an empty ledger listed %d runs", len(runs))
	}
}

// Kubernetes reuses names. Delete a WorkloadRun and recreate it and the ledger holds two rows, correctly
// distinguished by UID -- and a lookup by namespace/name then has two answers.
//
// A cold review reproduced the original behaviour: no ordering and no ambiguity check, so the query returned
// whichever row came first, which was the older `Recovered` in preference to the current `NotRecovered`. An
// evidence store that answers the wrong run is worse than one that refuses.
func TestARepeatedNameIsRefusedRatherThanGuessed(t *testing.T) {
	s := openTemp(t)
	start := projectedAt.Add(-time.Minute)

	old := runWith("uid-old", "fr002", platformv1.WorkloadRunComplete, &start, projectedAt,
		obs(0, "Ready", true), obs(9, "Ready", true))
	if _, err := s.ProjectWorkloadRuns([]platformv1.WorkloadRun{old}, projectedAt); err != nil {
		t.Fatalf("project the first run: %v", err)
	}

	// Same namespace and name, new object, and this one did not recover.
	recreated := runWith("uid-new", "fr002", platformv1.WorkloadRunComplete, &start,
		projectedAt.Add(time.Hour), obs(0, "Ready", true), obs(5, "Degraded", false))
	recreated.Status.Verdict = platformv1.VerdictNotRecovered
	if _, err := s.ProjectWorkloadRuns([]platformv1.WorkloadRun{recreated}, projectedAt.Add(time.Hour)); err != nil {
		t.Fatalf("project the recreated run: %v", err)
	}
	if runs, _ := counts(t, s); runs != 2 {
		t.Fatalf("the ledger holds %d runs, want 2 distinguished by UID", runs)
	}

	_, _, err := s.GetWorkloadRun("default", "fr002")
	if err == nil {
		t.Fatal("GetWorkloadRun picked one of two runs with the same name; a coin toss was presented as a record")
	}
	if !errors.Is(err, ErrAmbiguousRun) {
		t.Fatalf("the error does not identify itself as ambiguity, so a caller cannot tell it from a read failure: %v", err)
	}
	// Both UIDs, or the operator cannot act on the refusal.
	for _, want := range []string{"uid-old", "uid-new"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("the refusal does not name %q, so there is no way to choose: %v", want, err)
		}
	}
}

func TestReadingBackWhatWasProjected(t *testing.T) {
	s := openTemp(t)
	start := projectedAt.Add(-time.Minute)
	done := runWith("uid-1", "r1", platformv1.WorkloadRunComplete, &start, projectedAt,
		obs(0, "Ready", true), obs(4, "Degraded", false), obs(9, "Ready", true))
	done.Status.Reason = "observed Ready at 9s, within the declared 30s"
	if _, err := s.ProjectWorkloadRuns([]platformv1.WorkloadRun{done}, projectedAt); err != nil {
		t.Fatalf("projection: %v", err)
	}

	runs, err := s.ListWorkloadRuns()
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(runs) != 1 {
		t.Fatalf("listed %d runs, want 1", len(runs))
	}

	r, trail, err := s.GetWorkloadRun("default", "r1")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if r.Phase != string(platformv1.WorkloadRunComplete) {
		t.Fatalf("phase reads %q", r.Phase)
	}
	if r.Verdict == nil || *r.Verdict != string(platformv1.VerdictRecovered) {
		t.Fatalf("verdict reads %v, want Recovered", r.Verdict)
	}
	if r.Reason == nil || !strings.Contains(*r.Reason, "within the declared") {
		t.Fatalf("reason reads %v", r.Reason)
	}
	if r.StartedAt == nil || !r.StartedAt.Equal(start) {
		t.Fatalf("startedAt reads %v, want %v", r.StartedAt, start)
	}
	if len(trail) != 3 {
		t.Fatalf("the trail has %d entries, want 3", len(trail))
	}
	for i, o := range trail {
		if o.Ordinal != i {
			t.Fatalf("entry %d reports ordinal %d; the trail came back out of order", i, o.Ordinal)
		}
	}
	// The wall clock is DERIVED from startedAt plus the offset, never stored.
	want := start.Add(4 * time.Second)
	if trail[1].WallClock == nil || !trail[1].WallClock.Equal(want) {
		t.Fatalf("the second observation's wall clock reads %v, want %v", trail[1].WallClock, want)
	}
	if trail[1].Healthy {
		t.Fatal("a Degraded observation came back healthy")
	}
}

// A run with no startedAt has no origin, so its entries get no wall clock rather than one measured from the
// epoch. It also has no trail at all, which is why the absent verdict and start are what there is to check.
func TestARunWithNoStartHasNoWallClockAndNoAnswer(t *testing.T) {
	s := openTemp(t)
	if _, err := s.ProjectWorkloadRuns([]platformv1.WorkloadRun{
		runWith("uid-1", "r1", platformv1.WorkloadRunRefused, nil, projectedAt),
	}, projectedAt); err != nil {
		t.Fatalf("projection: %v", err)
	}
	r, trail, err := s.GetWorkloadRun("default", "r1")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if r.StartedAt != nil {
		t.Fatalf("a run that never started reports a start of %v", r.StartedAt)
	}
	if r.Verdict != nil {
		t.Fatalf("a refused run reports the verdict %q; the absence of an answer became an answer", *r.Verdict)
	}
	if len(trail) != 0 {
		t.Fatalf("a run that never started has %d observations", len(trail))
	}
}
