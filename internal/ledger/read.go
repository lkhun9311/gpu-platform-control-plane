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

// GetWorkloadRun returns one run by namespace and name, with its trail.
//
// Namespace and name rather than UID because that is what an operator has in their hand. A UID would be the
// stabler key, and it is not what anybody types.
func (s *Store) GetWorkloadRun(namespace, name string) (RunRecord, []Observation, error) {
	row := s.db.QueryRow(`SELECT uid, namespace, name, scenario, target_kind, target_name, target_namespace,
		phase, verdict, reason, started_at_unix_nanos, last_observed_at_unix_nanos,
		observed_generation, projected_at_unix_nanos
		FROM workload_runs WHERE namespace = ? AND name = ?`, namespace, name)
	r, err := scanRun(row)
	if errors.Is(err, sql.ErrNoRows) {
		return RunRecord{}, nil, fmt.Errorf("%s/%s: %w", namespace, name, ErrNoSuchRun)
	}
	if err != nil {
		return RunRecord{}, nil, fmt.Errorf("read run %s/%s from ledger %s: %w", namespace, name, s.path, err)
	}

	rows, err := s.db.Query(`SELECT ordinal, elapsed_seconds, state, healthy
		FROM operation_events WHERE object_uid = ? ORDER BY ordinal`, r.UID)
	if err != nil {
		return RunRecord{}, nil, fmt.Errorf("read the trail of %s/%s: %w", namespace, name, err)
	}
	defer func() { _ = rows.Close() }()

	var trail []Observation
	for rows.Next() {
		var (
			o       Observation
			healthy int
		)
		if err := rows.Scan(&o.Ordinal, &o.ElapsedSeconds, &o.State, &healthy); err != nil {
			return RunRecord{}, nil, fmt.Errorf("read an observation of %s/%s: %w", namespace, name, err)
		}
		o.Healthy = healthy == 1
		if r.StartedAt != nil {
			w := r.StartedAt.Add(time.Duration(o.ElapsedSeconds) * time.Second)
			o.WallClock = &w
		}
		trail = append(trail, o)
	}
	if err := rows.Err(); err != nil {
		return RunRecord{}, nil, fmt.Errorf("read the trail of %s/%s: %w", namespace, name, err)
	}
	return r, trail, nil
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
