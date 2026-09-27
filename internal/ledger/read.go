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
	"strings"
	"time"
)

// ErrNoSuchRun is returned when the ledger holds no run with the requested identity.
//
// It is a distinct error rather than a zero-valued RunRecord so a caller cannot print an empty record and
// have it read as a run that happened and recorded nothing.
var ErrNoSuchRun = errors.New("no such run in this ledger")

// RunRecord is one projected run as the ledger holds it.
//
// The optional fields are pointers rather than zero values because the difference is the whole point of the
// schema: a nil StartedAt is a run that never entered Observing, and a nil Verdict beside a Refused phase is
// the absence of an answer rather than an answer of "no".
type RunRecord struct {
	UID             string
	Namespace       string
	Name            string
	Scenario        string
	TargetKind      string
	TargetName      string
	TargetNamespace string
	Phase           string
	Verdict         *string
	Reason          *string
	StartedAt       *time.Time
	LastObservedAt  *time.Time
	ObservedGen     int64
	ProjectedAt     time.Time
}

// Observation is one entry of a run's trail as the ledger holds it.
//
// ElapsedSeconds is the timing authority. WallClock is DERIVED from the run's StartedAt and is nil when the
// run has none, because a trail whose origin is unknown has no wall-clock reading to report.
type Observation struct {
	Ordinal        int
	ElapsedSeconds int32
	State          string
	Healthy        bool
	WallClock      *time.Time
}

// ListWorkloadRuns returns every projected run, oldest projection first.
//
// An empty slice with a nil error means the ledger is readable and holds no runs. That is a real answer, and
// it is reachable only because OpenForRead refuses a ledger it cannot read at all -- which is what keeps this
// return value from ever standing in for "the recording could not be opened".
func (s *Store) ListWorkloadRuns() ([]RunRecord, error) {
	rows, err := s.db.Query(`SELECT uid, namespace, name, scenario, target_kind, target_name, target_namespace,
		phase, verdict, reason, started_at_unix_nanos, last_observed_at_unix_nanos,
		observed_generation, projected_at_unix_nanos
		FROM workload_runs ORDER BY projected_at_unix_nanos, uid`)
	if err != nil {
		return nil, fmt.Errorf("read runs from ledger %s: %w", s.path, err)
	}
	defer func() { _ = rows.Close() }()

	var out []RunRecord
	for rows.Next() {
		r, err := scanRun(rows)
		if err != nil {
			return nil, fmt.Errorf("read a run from ledger %s: %w", s.path, err)
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read runs from ledger %s: %w", s.path, err)
	}
	return out, nil
}

// ErrAmbiguousRun is returned when a namespace/name names more than one recorded run.
//
// Kubernetes reuses names: delete a WorkloadRun and recreate it and the ledger holds two rows, correctly
// distinguished by UID. Returning either one would be a coin toss presented as a record.
var ErrAmbiguousRun = errors.New("more than one recorded run has this name")

// GetWorkloadRun returns one run by namespace and name, with its trail.
//
// Namespace and name rather than UID because that is what an operator has in their hand. The cost of that
// choice is that the pair is NOT unique -- names are reusable -- and the first version of this function had no
// ordering and no ambiguity check, so a cold review reproduced it returning an older `Recovered` in preference
// to the current `NotRecovered`. An evidence store that answers the wrong run is worse than one that refuses,
// so a duplicate name is refused and the caller is told to pick a UID.
func (s *Store) GetWorkloadRun(namespace, name string) (RunRecord, []Observation, error) {
	rows, err := s.db.Query(`SELECT uid, namespace, name, scenario, target_kind, target_name, target_namespace,
		phase, verdict, reason, started_at_unix_nanos, last_observed_at_unix_nanos,
		observed_generation, projected_at_unix_nanos
		FROM workload_runs WHERE namespace = ? AND name = ? ORDER BY projected_at_unix_nanos DESC, uid`,
		namespace, name)
	if err != nil {
		return RunRecord{}, nil, fmt.Errorf("read run %s/%s from ledger %s: %w", namespace, name, s.path, err)
	}
	var found []RunRecord
	for rows.Next() {
		rec, err := scanRun(rows)
		if err != nil {
			_ = rows.Close()
			return RunRecord{}, nil, fmt.Errorf("read run %s/%s from ledger %s: %w", namespace, name, s.path, err)
		}
		found = append(found, rec)
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return RunRecord{}, nil, fmt.Errorf("read run %s/%s from ledger %s: %w", namespace, name, s.path, err)
	}
	_ = rows.Close()

	if len(found) == 0 {
		return RunRecord{}, nil, fmt.Errorf("%s/%s: %w", namespace, name, ErrNoSuchRun)
	}
	if len(found) > 1 {
		uids := make([]string, 0, len(found))
		for _, f := range found {
			uids = append(uids, f.UID)
		}
		return RunRecord{}, nil, fmt.Errorf("%s/%s names %d recorded runs (%s): %w",
			namespace, name, len(found), strings.Join(uids, ", "), ErrAmbiguousRun)
	}
	r := found[0]
	trail, err := s.trailOf(r)
	if err != nil {
		return RunRecord{}, nil, err
	}
	return r, trail, nil
}

// GetWorkloadRunByUID returns one run by the Kubernetes object UID, with its trail.
//
// This is the unambiguous lookup, and it exists so that the refusal GetWorkloadRun returns for a reused name is
// actionable: the error names the UIDs, and this is what the caller does with one. A UID is not what anybody
// types from memory, which is why it is the second entry point rather than the only one.
func (s *Store) GetWorkloadRunByUID(uid string) (RunRecord, []Observation, error) {
	row := s.db.QueryRow(`SELECT uid, namespace, name, scenario, target_kind, target_name, target_namespace,
		phase, verdict, reason, started_at_unix_nanos, last_observed_at_unix_nanos,
		observed_generation, projected_at_unix_nanos
		FROM workload_runs WHERE uid = ?`, uid)
	r, err := scanRun(row)
	if errors.Is(err, sql.ErrNoRows) {
		return RunRecord{}, nil, fmt.Errorf("uid %s: %w", uid, ErrNoSuchRun)
	}
	if err != nil {
		return RunRecord{}, nil, fmt.Errorf("read run %s from ledger %s: %w", uid, s.path, err)
	}
	trail, err := s.trailOf(r)
	if err != nil {
		return RunRecord{}, nil, err
	}
	return r, trail, nil
}

// trailOf reads one run's observations, deriving each wall clock from the run's own start.
func (s *Store) trailOf(r RunRecord) ([]Observation, error) {
	rows, err := s.db.Query(`SELECT ordinal, elapsed_seconds, state, healthy
		FROM operation_events WHERE object_uid = ? ORDER BY ordinal`, r.UID)
	if err != nil {
		return nil, fmt.Errorf("read the trail of %s/%s: %w", r.Namespace, r.Name, err)
	}
	defer func() { _ = rows.Close() }()

	var trail []Observation
	for rows.Next() {
		var (
			o       Observation
			healthy int
		)
		if err := rows.Scan(&o.Ordinal, &o.ElapsedSeconds, &o.State, &healthy); err != nil {
			return nil, fmt.Errorf("read an observation of %s/%s: %w", r.Namespace, r.Name, err)
		}
		o.Healthy = healthy == 1
		if r.StartedAt != nil {
			w := r.StartedAt.Add(time.Duration(o.ElapsedSeconds) * time.Second)
			o.WallClock = &w
		}
		trail = append(trail, o)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read the trail of %s/%s: %w", r.Namespace, r.Name, err)
	}
	return trail, nil
}

// scanner is what Query's rows and QueryRow's row have in common.
type scanner interface {
	Scan(dest ...any) error
}

func scanRun(sc scanner) (RunRecord, error) {
	var (
		r                     RunRecord
		verdict, reason       sql.NullString
		started, lastObserved sql.NullInt64
		projected             int64
	)
	if err := sc.Scan(&r.UID, &r.Namespace, &r.Name, &r.Scenario, &r.TargetKind, &r.TargetName,
		&r.TargetNamespace, &r.Phase, &verdict, &reason, &started, &lastObserved,
		&r.ObservedGen, &projected); err != nil {
		return RunRecord{}, err
	}
	if verdict.Valid {
		r.Verdict = &verdict.String
	}
	if reason.Valid {
		r.Reason = &reason.String
	}
	if started.Valid {
		t := time.Unix(0, started.Int64)
		r.StartedAt = &t
	}
	if lastObserved.Valid {
		t := time.Unix(0, lastObserved.Int64)
		r.LastObservedAt = &t
	}
	r.ProjectedAt = time.Unix(0, projected)
	return r, nil
}
