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
	"errors"
	"fmt"
	"time"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// Projection reports what one projection did, so a caller can say what it recorded rather than that it ran.
//
// A projector that returned only an error would make "wrote nothing because there was nothing" and "wrote
// nothing because it matched everything already" the same outcome, and those are different facts about the
// cluster.
type Projection struct {
	// RunsSeen is how many objects were handed to the projector.
	RunsSeen int
	// RunsWritten is how many workload_runs rows were inserted or updated.
	RunsWritten int
	// EventsWritten is how many operation_events rows were new.
	EventsWritten int
	// EventsAlreadyPresent is how many observations were already recorded identically, which is what a
	// replay looks like when it is working.
	EventsAlreadyPresent int
	// RunsWithoutStart is how many runs had no status.startedAt, and so have no derivable wall clock.
	//
	// Those are runs that never entered Observing. A Refused run is usually NOT one of them: the gap check
	// refuses a trail with a hole after observation has begun.
	RunsWithoutStart int
	// RunsStale is how many runs were skipped because the ledger already held a fresher snapshot.
	//
	// It is counted rather than silent because "nothing changed, the ledger was already ahead" and "nothing
	// changed, there was nothing to do" are different facts about the run being projected.
	RunsStale int
}

// isAtLeastAsFresh reports whether this snapshot may advance the stored row.
//
// status.lastObservedAt is when the controller last actually looked (api/v1/workloadrun_types.go:180), which
// makes it the only honest basis for deciding which of two readings is later. A snapshot with none cannot
// establish that it is newer, so it may create a row but never replace one.
func isAtLeastAsFresh(tx *sql.Tx, run *platformv1.WorkloadRun) (bool, error) {
	var stored sql.NullInt64
	err := tx.QueryRow(`SELECT last_observed_at_unix_nanos FROM workload_runs WHERE uid = ?`,
		string(run.UID)).Scan(&stored)
	if errors.Is(err, sql.ErrNoRows) {
		return true, nil
	}
	if err != nil {
		return false, fmt.Errorf("read the stored freshness of %s/%s: %w", run.Namespace, run.Name, err)
	}
	if !stored.Valid {
		return true, nil
	}
	if run.Status.LastObservedAt == nil {
		return false, nil
	}
	return run.Status.LastObservedAt.UnixNano() >= stored.Int64, nil
}

// ProjectWorkloadRuns records the given runs, and is safe to call repeatedly with the same input.
//
// It takes objects rather than a client on purpose: replay and restart behaviour is the thing most worth
// testing here, and a function that needs an apiserver to test it would be tested less.
//
// projectedAt is passed in rather than read from the clock so a test can pin it, and it is stored as
// projected_at_unix_nanos -- the time the PROJECTION happened. Nothing here treats it as the time anything
// occurred; the run's own elapsed offsets are the timing authority.
//
// Everything happens in one transaction. A projection that failed halfway and left some runs recorded would
// be a ledger that disagrees with itself about how far it got.
func (s *Store) ProjectWorkloadRuns(runs []platformv1.WorkloadRun, projectedAt time.Time) (Projection, error) {
	var p Projection
	p.RunsSeen = len(runs)

	tx, err := s.db.Begin()
	if err != nil {
		return Projection{}, fmt.Errorf("begin projection into %s: %w", s.path, err)
	}
	defer func() { _ = tx.Rollback() }()

	for i := range runs {
		run := &runs[i]
		if run.UID == "" {
			// The UID is the identity the whole table is keyed by. Without it two different runs would
			// collapse into one row, or one run would append a second account of itself on every projection.
			return Projection{}, fmt.Errorf("run %s/%s has no UID; refusing to key a ledger row on nothing",
				run.Namespace, run.Name)
		}

		var startedAt any
		if run.Status.StartedAt != nil {
			startedAt = run.Status.StartedAt.UnixNano()
		} else {
			p.RunsWithoutStart++
			if len(run.Status.Observations) > 0 {
				// The trail's offsets are measured from startedAt, so observations without one have no
				// meaning at all. Storing them would put a trail in the ledger whose clock does not exist.
				return Projection{}, fmt.Errorf("run %s/%s reports %d observations but no startedAt; the offsets have no origin",
					run.Namespace, run.Name, len(run.Status.Observations))
			}
		}

		var lastObserved any
		if run.Status.LastObservedAt != nil {
			lastObserved = run.Status.LastObservedAt.UnixNano()
		}

		if err := refuseIncompatibleIdentity(tx, run); err != nil {
			return Projection{}, err
		}

		// Freshness is decided BEFORE anything else this snapshot says is believed.
		//
		// This ordering was found by a test rather than reasoned out: the stale check and the shrinking-trail
		// check contradicted each other. A snapshot from a minute ago legitimately has a shorter trail, so the
		// ghost-row check fired and refused a projection that should simply have been a no-op. The resolution
		// is that a stale snapshot has no standing to say anything -- not that the trail shrank, and not that
		// the phase moved -- so it is skipped whole.
		fresher, err := isAtLeastAsFresh(tx, run)
		if err != nil {
			return Projection{}, err
		}
		if !fresher {
			p.RunsStale++
			continue
		}

		// The UPSERT advances the row only when this snapshot is at least as fresh as the stored one.
		//
		// Without the WHERE, a projection holding an older snapshot would overwrite a Complete run with the
		// Observing state it had minutes earlier -- the ledger rewriting its own history backwards, with
		// every column still looking like a legitimate reading. status.lastObservedAt exists precisely to
		// say when the controller last looked (api/v1/workloadrun_types.go:180), so it is what decides.
		//
		// A NULL stored value loses to anything, and a run with no lastObservedAt at all can still be
		// written once and then only replaced by a snapshot that has one.
		if _, err := tx.Exec(`INSERT INTO workload_runs
			(uid, namespace, name, scenario, target_kind, target_name, target_namespace,
			 phase, verdict, reason, started_at_unix_nanos, last_observed_at_unix_nanos,
			 observed_generation, projected_at_unix_nanos)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(uid) DO UPDATE SET
			 phase = excluded.phase,
			 verdict = excluded.verdict,
			 reason = excluded.reason,
			 started_at_unix_nanos = excluded.started_at_unix_nanos,
			 last_observed_at_unix_nanos = excluded.last_observed_at_unix_nanos,
			 observed_generation = excluded.observed_generation,
			 projected_at_unix_nanos = excluded.projected_at_unix_nanos
			WHERE excluded.last_observed_at_unix_nanos IS NOT NULL
			  AND (workload_runs.last_observed_at_unix_nanos IS NULL
			       OR excluded.last_observed_at_unix_nanos >= workload_runs.last_observed_at_unix_nanos)`,
			string(run.UID), run.Namespace, run.Name, string(run.Spec.Scenario),
			run.Spec.Target.Kind, run.Spec.Target.Name, run.Spec.Target.Namespace,
			string(run.Status.Phase), emptyToNil(string(run.Status.Verdict)), emptyToNil(run.Status.Reason),
			startedAt, lastObserved, run.Status.ObservedGeneration, projectedAt.UnixNano(),
		); err != nil {
			return Projection{}, fmt.Errorf("record run %s/%s: %w", run.Namespace, run.Name, err)
		}
		p.RunsWritten++

		for ordinal, obs := range run.Status.Observations {
			written, err := insertObservation(tx, string(run.UID), ordinal, obs)
			if err != nil {
				return Projection{}, fmt.Errorf("record observation %d of %s/%s: %w",
					ordinal, run.Namespace, run.Name, err)
			}
			if written {
				p.EventsWritten++
			} else {
				p.EventsAlreadyPresent++
			}
		}

		// The ledger must not hold observations the object no longer reports.
		//
		// status.observations is append-only in the controller, so a shrinking trail should be impossible --
		// which is exactly why it is checked rather than assumed. If it ever happens, the stored rows beyond
		// the trail's end are a claim that something was observed, standing on nothing, and they would be
		// read as evidence.
		var stored int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM operation_events WHERE object_uid = ?`,
			string(run.UID)).Scan(&stored); err != nil {
			return Projection{}, fmt.Errorf("count stored observations of %s/%s: %w", run.Namespace, run.Name, err)
		}
		if stored > len(run.Status.Observations) {
			return Projection{}, fmt.Errorf("ledger holds %d observations of %s/%s but the object now reports %d; refusing to keep a trail the run does not claim",
				stored, run.Namespace, run.Name, len(run.Status.Observations))
		}
	}

	if err := tx.Commit(); err != nil {
		return Projection{}, fmt.Errorf("commit projection into %s: %w", s.path, err)
	}
	return p, nil
}

// refuseIncompatibleIdentity stops a second run's account being attached to the first one's row.
//
// The UID identifies the object, and everything checked here is immutable for that object's whole life: the
// scenario and target carry `self == oldSelf` CEL rules, the namespace and name cannot change, and startedAt
// is written once on entry to Observing. If a stored row disagrees with the object now being projected, one of
// the two is not what it claims to be, and updating the status columns would graft new readings onto an
// identity that did not produce them.
//
// Kubernetes hands a recreated object a new UID, so delete-and-recreate under the same name is safe and lands
// in its own row. What this catches is the case that should be impossible.
func refuseIncompatibleIdentity(tx *sql.Tx, run *platformv1.WorkloadRun) error {
	var (
		namespace, name, scenario, kind, target, targetNS string
		storedStart                                       sql.NullInt64
	)
	err := tx.QueryRow(`SELECT namespace, name, scenario, target_kind, target_name, target_namespace,
		started_at_unix_nanos FROM workload_runs WHERE uid = ?`, string(run.UID)).
		Scan(&namespace, &name, &scenario, &kind, &target, &targetNS, &storedStart)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("read the stored identity of %s/%s: %w", run.Namespace, run.Name, err)
	}

	for _, f := range []struct {
		what   string
		stored string
		now    string
	}{
		{"namespace", namespace, run.Namespace},
		{"name", name, run.Name},
		{"scenario", scenario, string(run.Spec.Scenario)},
		{"target kind", kind, run.Spec.Target.Kind},
		{"target name", target, run.Spec.Target.Name},
		{"target namespace", targetNS, run.Spec.Target.Namespace},
	} {
		if f.stored != f.now {
			return fmt.Errorf("uid %s is recorded with %s %q and is now reported as %q; refusing to attach one run's status to another's identity",
				run.UID, f.what, f.stored, f.now)
		}
	}
	if run.Status.StartedAt != nil && storedStart.Valid && storedStart.Int64 != run.Status.StartedAt.UnixNano() {
		return fmt.Errorf("uid %s is recorded as started at %d and is now reported as %d; every stored offset is measured from the old origin",
			run.UID, storedStart.Int64, run.Status.StartedAt.UnixNano())
	}
	return nil
}

// insertObservation stores one observation at its position in the trail, reporting whether it was new.
//
// A conflict on (object_uid, ordinal) is the NORMAL outcome of a replay and must not be an error. What must be
// an error is a conflict whose stored row DISAGREES: the same position in the same run's trail reported twice
// with different contents is a contradiction about the cluster rather than a duplicate of a fact. Writing
// either version over the other would settle it silently, and the settled row would read as evidence.
func insertObservation(tx *sql.Tx, uid string, ordinal int, obs platformv1.WorkloadRunObservation) (bool, error) {
	res, err := tx.Exec(`INSERT INTO operation_events (object_uid, ordinal, elapsed_seconds, state, healthy)
		VALUES (?, ?, ?, ?, ?) ON CONFLICT(object_uid, ordinal) DO NOTHING`,
		uid, ordinal, obs.ElapsedSeconds, obs.State, boolToInt(obs.Healthy))
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	if n == 1 {
		return true, nil
	}

	var (
		storedElapsed int32
		storedState   string
		storedHealthy int
	)
	err = tx.QueryRow(`SELECT elapsed_seconds, state, healthy FROM operation_events
		WHERE object_uid = ? AND ordinal = ?`, uid, ordinal).
		Scan(&storedElapsed, &storedState, &storedHealthy)
	if errors.Is(err, sql.ErrNoRows) {
		// Nothing was inserted and nothing is there, which the schema does not allow. Reporting this as a
		// successful replay would claim the observation is recorded when it is not.
		return false, errors.New("observation was neither inserted nor found; the ledger did not store it")
	}
	if err != nil {
		return false, err
	}
	if storedElapsed != obs.ElapsedSeconds || storedState != obs.State || storedHealthy != boolToInt(obs.Healthy) {
		return false, fmt.Errorf("position %d is already recorded as (%ds, %q, healthy=%d) and is now reported as (%ds, %q, healthy=%d); refusing to overwrite one reading with the other",
			ordinal, storedElapsed, storedState, storedHealthy,
			obs.ElapsedSeconds, obs.State, boolToInt(obs.Healthy))
	}
	return false, nil
}

// emptyToNil stores an absent optional field as NULL rather than as the empty string.
//
// status.verdict is empty beside phase Refused on purpose -- "there is no answer, rather than an answer of
// no" is how the API puts it -- and an empty string would be a value where the source of truth has none.
func emptyToNil(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
