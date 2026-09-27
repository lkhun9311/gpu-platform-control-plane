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
	"database/sql"
	"path/filepath"
	"strings"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// The projector's only interesting property is that running it again changes nothing. Everything here is a
// way of asking that, plus the cases where silence would be a lie: a run that never started, a trail whose
// position is reported twice with different contents, and a ledger holding more than the object claims.

var projectedAt = time.Unix(1_700_000_000, 0)

func openTemp(t *testing.T) *Store {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "ledger.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func obs(elapsed int32, state string, healthy bool) platformv1.WorkloadRunObservation {
	return platformv1.WorkloadRunObservation{ElapsedSeconds: elapsed, State: state, Healthy: healthy}
}

func runWith(uid, name string, phase platformv1.WorkloadRunPhase, start *time.Time,
	trail ...platformv1.WorkloadRunObservation) platformv1.WorkloadRun {
	r := platformv1.WorkloadRun{
		ObjectMeta: metav1.ObjectMeta{UID: types.UID(uid), Name: name, Namespace: "default"},
		Spec: platformv1.WorkloadRunSpec{
			Scenario: platformv1.ScenarioServingPodKilled,
			Target: platformv1.WorkloadRunTarget{
				Kind: "InferenceDeployment", Name: "served", Namespace: "default",
			},
		},
		Status: platformv1.WorkloadRunStatus{
			Phase: phase, Observations: trail, ObservedGeneration: 1,
		},
	}
	if start != nil {
		r.Status.StartedAt = &metav1.Time{Time: *start}
	}
	return r
}

func counts(t *testing.T, s *Store) (runs, events int) {
	t.Helper()
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM workload_runs`).Scan(&runs); err != nil {
		t.Fatalf("count runs: %v", err)
	}
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM operation_events`).Scan(&events); err != nil {
		t.Fatalf("count events: %v", err)
	}
	return runs, events
}

// Three projections of the same objects must leave exactly what one left.
func TestProjectingThriceChangesNothing(t *testing.T) {
	s := openTemp(t)
	start := projectedAt.Add(-time.Minute)
	runs := []platformv1.WorkloadRun{
		runWith("uid-1", "r1", platformv1.WorkloadRunComplete, &start,
			obs(0, "Ready", true), obs(4, "Degraded", false), obs(9, "Ready", true)),
	}

	first, err := s.ProjectWorkloadRuns(runs, projectedAt)
	if err != nil {
		t.Fatalf("first projection: %v", err)
	}
	if first.EventsWritten != 3 || first.EventsAlreadyPresent != 0 {
		t.Fatalf("first projection wrote %d events and matched %d, want 3 and 0",
			first.EventsWritten, first.EventsAlreadyPresent)
	}
	wantRuns, wantEvents := counts(t, s)

	for i := 2; i <= 3; i++ {
		again, err := s.ProjectWorkloadRuns(runs, projectedAt.Add(time.Duration(i)*time.Hour))
		if err != nil {
			t.Fatalf("projection %d: %v", i, err)
		}
		if again.EventsWritten != 0 {
			t.Fatalf("projection %d wrote %d new events; a replay duplicated the trail", i, again.EventsWritten)
		}
		if again.EventsAlreadyPresent != 3 {
			t.Fatalf("projection %d matched %d events, want 3", i, again.EventsAlreadyPresent)
		}
		gotRuns, gotEvents := counts(t, s)
		if gotRuns != wantRuns || gotEvents != wantEvents {
			t.Fatalf("after projection %d the ledger holds %d runs and %d events, want %d and %d",
				i, gotRuns, gotEvents, wantRuns, wantEvents)
		}
	}
}

// The trail that motivated keying on position: a round trip inside one second. All three observations must
// survive, and a replay must still change nothing.
func TestARoundTripInsideOneSecondKeepsEveryObservation(t *testing.T) {
	s := openTemp(t)
	start := projectedAt.Add(-time.Minute)
	runs := []platformv1.WorkloadRun{
		runWith("uid-1", "r1", platformv1.WorkloadRunComplete, &start,
			obs(0, "Ready", true), obs(0, "Degraded", false), obs(0, "Ready", true)),
	}

	p, err := s.ProjectWorkloadRuns(runs, projectedAt)
	if err != nil {
		t.Fatalf("projection: %v", err)
	}
	if p.EventsWritten != 3 {
		t.Fatalf("wrote %d events for a three-observation trail; a transition was lost to a key collision", p.EventsWritten)
	}
	if _, events := counts(t, s); events != 3 {
		t.Fatalf("ledger holds %d events, want 3", events)
	}

	again, err := s.ProjectWorkloadRuns(runs, projectedAt.Add(time.Hour))
	if err != nil {
		t.Fatalf("replay: %v", err)
	}
	if again.EventsWritten != 0 || again.EventsAlreadyPresent != 3 {
		t.Fatalf("replay wrote %d and matched %d, want 0 and 3", again.EventsWritten, again.EventsAlreadyPresent)
	}
}

// A projection that fails partway must leave nothing, or the ledger disagrees with itself about how far it
// got. The second run has no UID, which is refused after the first has already been written in the same
// transaction.
func TestAFailedProjectionWritesNothing(t *testing.T) {
	s := openTemp(t)
	start := projectedAt.Add(-time.Minute)
	good := runWith("uid-1", "r1", platformv1.WorkloadRunComplete, &start, obs(1, "Ready", true))
	bad := runWith("", "r2", platformv1.WorkloadRunComplete, &start)

	if _, err := s.ProjectWorkloadRuns([]platformv1.WorkloadRun{good, bad}, projectedAt); err == nil {
		t.Fatal("a run with no UID was accepted")
	} else if !strings.Contains(err.Error(), "no UID") {
		t.Fatalf("refusal does not name the cause: %v", err)
	}

	runs, events := counts(t, s)
	if runs != 0 || events != 0 {
		t.Fatalf("a refused projection left %d runs and %d events behind", runs, events)
	}
}

// Interrupting after the first batch and re-running everything must produce what one clean run would.
func TestRestartThenFullReplayMatchesACleanRun(t *testing.T) {
	start := projectedAt.Add(-time.Minute)
	all := []platformv1.WorkloadRun{
		runWith("uid-1", "r1", platformv1.WorkloadRunComplete, &start,
			obs(0, "Ready", true), obs(5, "Degraded", false)),
		runWith("uid-2", "r2", platformv1.WorkloadRunRefused, nil),
	}

	clean := openTemp(t)
	if _, err := clean.ProjectWorkloadRuns(all, projectedAt); err != nil {
		t.Fatalf("clean projection: %v", err)
	}
	wantRuns, wantEvents := counts(t, clean)

	interrupted := openTemp(t)
	if _, err := interrupted.ProjectWorkloadRuns(all[:1], projectedAt); err != nil {
		t.Fatalf("partial projection: %v", err)
	}
	if _, err := interrupted.ProjectWorkloadRuns(all, projectedAt); err != nil {
		t.Fatalf("replay after interruption: %v", err)
	}
	gotRuns, gotEvents := counts(t, interrupted)
	if gotRuns != wantRuns || gotEvents != wantEvents {
		t.Fatalf("interrupted-then-replayed ledger holds %d runs and %d events; a clean run holds %d and %d",
			gotRuns, gotEvents, wantRuns, wantEvents)
	}
}

// A run that never entered Observing is recorded as a run with no events and a NULL start, because "never
// observed" and "observed and nothing happened" are different facts.
func TestARunThatNeverStartedIsRecordedWithNoEvents(t *testing.T) {
	s := openTemp(t)
	p, err := s.ProjectWorkloadRuns([]platformv1.WorkloadRun{
		runWith("uid-1", "r1", platformv1.WorkloadRunRefused, nil),
	}, projectedAt)
	if err != nil {
		t.Fatalf("projection: %v", err)
	}
	if p.RunsWithoutStart != 1 {
		t.Fatalf("projection counted %d runs without a start, want 1", p.RunsWithoutStart)
	}
	runs, events := counts(t, s)
	if runs != 1 || events != 0 {
		t.Fatalf("ledger holds %d runs and %d events, want 1 and 0", runs, events)
	}
	var start sql.NullInt64
	if err := s.db.QueryRow(`SELECT started_at_unix_nanos FROM workload_runs WHERE uid='uid-1'`).Scan(&start); err != nil {
		t.Fatalf("read start: %v", err)
	}
	if start.Valid {
		t.Fatalf("a run that never started has start %d; absence was stored as a time", start.Int64)
	}
	// An absent verdict is NULL rather than the empty string: "there is no answer, rather than an answer of no".
	var verdict sql.NullString
	if err := s.db.QueryRow(`SELECT verdict FROM workload_runs WHERE uid='uid-1'`).Scan(&verdict); err != nil {
		t.Fatalf("read verdict: %v", err)
	}
	if verdict.Valid {
		t.Fatalf("an absent verdict was stored as %q", verdict.String)
	}
}

// The same position reported twice with different contents is a contradiction about the cluster, not a
// duplicate of a fact. Settling it silently would leave a row that reads as evidence.
func TestAContradictedPositionIsRefusedRatherThanResolved(t *testing.T) {
	s := openTemp(t)
	start := projectedAt.Add(-time.Minute)
	if _, err := s.ProjectWorkloadRuns([]platformv1.WorkloadRun{
		runWith("uid-1", "r1", platformv1.WorkloadRunObserving, &start, obs(3, "Ready", true)),
	}, projectedAt); err != nil {
		t.Fatalf("first projection: %v", err)
	}

	flipped := runWith("uid-1", "r1", platformv1.WorkloadRunObserving, &start, obs(3, "Ready", false))
	if _, err := s.ProjectWorkloadRuns([]platformv1.WorkloadRun{flipped}, projectedAt); err == nil {
		t.Fatal("the same position was accepted with a different health reading")
	} else if !strings.Contains(err.Error(), "refusing to overwrite") {
		t.Fatalf("refusal does not say what it declined to do: %v", err)
	}

	var stored int
	if err := s.db.QueryRow(`SELECT healthy FROM operation_events WHERE object_uid='uid-1' AND ordinal=0`).Scan(&stored); err != nil {
		t.Fatalf("read stored health: %v", err)
	}
	if stored != 1 {
		t.Fatalf("stored health is %d after a refused projection, want the original 1", stored)
	}
}

// The ledger must not keep observations the object no longer reports. The controller's trail is append-only,
// so this should be impossible -- which is why it is checked rather than assumed.
func TestALedgerHoldingMoreThanTheObjectClaimsIsRefused(t *testing.T) {
	s := openTemp(t)
	start := projectedAt.Add(-time.Minute)
	if _, err := s.ProjectWorkloadRuns([]platformv1.WorkloadRun{
		runWith("uid-1", "r1", platformv1.WorkloadRunComplete, &start,
			obs(0, "Ready", true), obs(5, "Degraded", false), obs(9, "Ready", true)),
	}, projectedAt); err != nil {
		t.Fatalf("first projection: %v", err)
	}

	shrunk := runWith("uid-1", "r1", platformv1.WorkloadRunComplete, &start, obs(0, "Ready", true))
	if _, err := s.ProjectWorkloadRuns([]platformv1.WorkloadRun{shrunk}, projectedAt); err == nil {
		t.Fatal("a shrinking trail was accepted; the ledger would claim observations nothing reports")
	} else if !strings.Contains(err.Error(), "does not claim") {
		t.Fatalf("refusal does not say what is wrong: %v", err)
	}
	if _, events := counts(t, s); events != 3 {
		t.Fatalf("ledger holds %d events after a refused projection, want the original 3", events)
	}
}

// Phase, verdict and reason are re-read on every projection, so a run that has moved on is updated rather
// than duplicated.
func TestAnAdvancedRunUpdatesItsRow(t *testing.T) {
	s := openTemp(t)
	start := projectedAt.Add(-time.Minute)
	if _, err := s.ProjectWorkloadRuns([]platformv1.WorkloadRun{
		runWith("uid-1", "r1", platformv1.WorkloadRunObserving, &start, obs(0, "Ready", true)),
	}, projectedAt); err != nil {
		t.Fatalf("first projection: %v", err)
	}

	done := runWith("uid-1", "r1", platformv1.WorkloadRunComplete, &start,
		obs(0, "Ready", true), obs(6, "Ready", true))
	done.Status.Verdict = platformv1.VerdictRecovered
	done.Status.Reason = "observed Ready at 6s, within the declared 30s"
	if _, err := s.ProjectWorkloadRuns([]platformv1.WorkloadRun{done}, projectedAt); err != nil {
		t.Fatalf("second projection: %v", err)
	}

	runs, events := counts(t, s)
	if runs != 1 {
		t.Fatalf("an advanced run produced %d rows, want 1", runs)
	}
	if events != 2 {
		t.Fatalf("ledger holds %d events, want 2", events)
	}
	var phase, verdict, reason string
	if err := s.db.QueryRow(`SELECT phase, verdict, reason FROM workload_runs WHERE uid='uid-1'`).
		Scan(&phase, &verdict, &reason); err != nil {
		t.Fatalf("read run: %v", err)
	}
	if phase != string(platformv1.WorkloadRunComplete) || verdict != string(platformv1.VerdictRecovered) {
		t.Fatalf("row still reads phase=%q verdict=%q after the run completed", phase, verdict)
	}
	if !strings.Contains(reason, "within the declared") {
		t.Fatalf("reason was not carried across: %q", reason)
	}
}
