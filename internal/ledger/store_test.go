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
	"strconv"
	"strings"
	"testing"
)

// Every test here is a statement about ABSENCE or about a refusal, which is the class this repository keeps
// finding unguarded.
//
// A store that opens, migrates and reports rows is easy to test and proves little. What has to hold is that
// an unread ledger is never reported as an empty one, that a replay cannot duplicate, that a version number
// which does not describe the database is refused, and that the schema rejects values the API cannot produce.

func TestOpenCreatesAndMigrates(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ledger.db")
	s, err := Open(path)
	if err != nil {
		t.Fatalf("Open on a fresh path: %v", err)
	}
	defer func() { _ = s.Close() }()

	got, err := s.version()
	if err != nil {
		t.Fatalf("version after Open: %v", err)
	}
	if got != schemaVersion {
		t.Fatalf("schema version is %d after Open, want %d", got, schemaVersion)
	}
	for _, table := range []string{"schema_migrations", "workload_runs", "operation_events"} {
		present, err := s.tableExists(table)
		if err != nil {
			t.Fatalf("look for %s: %v", table, err)
		}
		if !present {
			t.Fatalf("table %s missing after migration", table)
		}
	}
}

// Opening twice must not re-apply migration 1, which would fail on tables that already exist.
func TestOpenIsIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ledger.db")
	first, err := Open(path)
	if err != nil {
		t.Fatalf("first Open: %v", err)
	}
	if err := first.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	second, err := Open(path)
	if err != nil {
		t.Fatalf("second Open on an already migrated ledger: %v", err)
	}
	defer func() { _ = second.Close() }()

	var n int
	if err := second.db.QueryRow(`SELECT COUNT(*) FROM schema_migrations`).Scan(&n); err != nil {
		t.Fatalf("count migrations: %v", err)
	}
	if n != len(migrations) {
		t.Fatalf("schema_migrations holds %d rows after two Opens, want %d", n, len(migrations))
	}
}

// The whole point of OpenForRead: a ledger nobody wrote is not a ledger with nothing in it.
func TestOpenForReadRefusesAMissingLedger(t *testing.T) {
	path := filepath.Join(t.TempDir(), "absent.db")
	s, err := OpenForRead(path)
	if err == nil {
		_ = s.Close()
		t.Fatal("OpenForRead accepted a path with no ledger; an unread ledger would be reported as an empty one")
	}
	if !strings.Contains(err.Error(), "unread ledger") {
		t.Fatalf("refusal does not distinguish unread from empty: %v", err)
	}
	if !strings.Contains(err.Error(), path) {
		t.Fatalf("refusal does not name the path it looked at: %v", err)
	}
}

// An empty-but-migrated ledger is a different fact, and must be readable.
func TestOpenForReadAcceptsAnEmptyMigratedLedger(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ledger.db")
	w, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if err := w.Close(); err != nil {
		t.Fatalf("close writer: %v", err)
	}
	r, err := OpenForRead(path)
	if err != nil {
		t.Fatalf("OpenForRead on an empty migrated ledger: %v", err)
	}
	defer func() { _ = r.Close() }()

	var n int
	if err := r.db.QueryRow(`SELECT COUNT(*) FROM workload_runs`).Scan(&n); err != nil {
		t.Fatalf("count runs: %v", err)
	}
	if n != 0 {
		t.Fatalf("a fresh ledger holds %d runs, want 0", n)
	}
}

// A ledger written by a newer binary has columns this one cannot see.
func TestOpenForReadRefusesANewerSchema(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ledger.db")
	w, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	// 77 rather than a small offset, and the expected strings are built from the values rather than written
	// as literals. The first version of this test planted version 8 and searched for "7", and passed because
	// the temporary pathname quoted in the refusal happened to contain a 7 -- an assertion that could not
	// discriminate, in a test whose whole subject is discrimination.
	future := schemaVersion + 76
	if _, err := w.db.Exec(`INSERT INTO schema_migrations (version, applied_at_unix_nanos) VALUES (?, 1)`, future); err != nil {
		t.Fatalf("plant a future migration: %v", err)
	}
	if err := w.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	// The planted history is {1, 77}, so the contiguity check speaks first, and that is the honest reading:
	// a database recording a step that never ran is broken before it is merely newer.
	if _, err := OpenForRead(path); err == nil {
		t.Fatal("OpenForRead accepted a ledger whose migration history has a hole")
	} else if !strings.Contains(err.Error(), "contiguous") {
		t.Fatalf("refusal does not name the problem: %v", err)
	}
	if _, err := Open(path); err == nil {
		t.Fatal("Open accepted a ledger whose migration history has a hole")
	}
}

// A version number is a claim about shape, so it is checked against the shape.
func TestAVersionThatDoesNotDescribeTheDatabaseIsRefused(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ledger.db")
	s, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if _, err := s.db.Exec(`DROP TABLE operation_events`); err != nil {
		t.Fatalf("drop a table the version claims: %v", err)
	}
	if _, err := s.version(); err == nil {
		t.Fatal("version() reported a version for a database missing a table that version created")
	} else {
		for _, want := range []string{"operation_events", strconv.Itoa(schemaVersion)} {
			if !strings.Contains(err.Error(), want) {
				t.Fatalf("refusal does not name %q: %v", want, err)
			}
		}
	}
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
}

// Tables present with no migration record is a half-migrated ledger, not a fresh one.
func TestTablesWithoutAMigrationRecordAreNotAFreshLedger(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ledger.db")
	s, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if _, err := s.db.Exec(`DROP TABLE schema_migrations`); err != nil {
		t.Fatalf("drop the migration record: %v", err)
	}
	if _, err := s.version(); err == nil {
		t.Fatal("a ledger with tables and no migration record was read as version 0")
	} else if !strings.Contains(err.Error(), "half-migrated") {
		t.Fatalf("refusal does not say what is wrong: %v", err)
	}
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
}

// An empty migration table is the other half-migrated shape.
func TestAnEmptyMigrationTableIsRefused(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ledger.db")
	s, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer func() { _ = s.Close() }()
	if _, err := s.db.Exec(`DELETE FROM schema_migrations`); err != nil {
		t.Fatalf("empty the migration record: %v", err)
	}
	if _, err := s.version(); err == nil {
		t.Fatal("a schema_migrations table with no rows was read as version 0")
	} else if !strings.Contains(err.Error(), "half-migrated") {
		t.Fatalf("refusal does not say what is wrong: %v", err)
	}
}

// The composite key is the observation's POSITION, so the same position twice is a duplicate and the same
// (second, state) at two positions is not. The second half is the defect that changed this schema: the
// controller truncates elapsed time to whole seconds, so Ready@0 -> Degraded@0 -> Ready@0 is a legal trail.
func TestTheKeyIsThePositionNotTheSecondAndState(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ledger.db")
	s, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer func() { _ = s.Close() }()

	const ins = `INSERT INTO operation_events (object_uid, ordinal, elapsed_seconds, state, healthy) VALUES (?, ?, ?, ?, ?)`
	if _, err := s.db.Exec(ins, "uid-1", 0, 0, "Ready", 1); err != nil {
		t.Fatalf("first insert: %v", err)
	}
	if _, err := s.db.Exec(ins, "uid-1", 0, 0, "Ready", 1); err == nil {
		t.Fatal("the same position was stored twice; a replay would duplicate the trail")
	}

	// The round trip inside one second: three observations, two of them identical apart from position.
	if _, err := s.db.Exec(ins, "uid-1", 1, 0, "Degraded", 0); err != nil {
		t.Fatalf("second observation: %v", err)
	}
	if _, err := s.db.Exec(ins, "uid-1", 2, 0, "Ready", 1); err != nil {
		t.Fatalf("a repeat of (0s, Ready) at a later position was rejected; a real transition would be lost: %v", err)
	}
	var n int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM operation_events`).Scan(&n); err != nil {
		t.Fatalf("count events: %v", err)
	}
	if n != 3 {
		t.Fatalf("operation_events holds %d rows, want 3", n)
	}
}

// STRICT constrains storage classes only, which is less than it sounds like. These are the CHECK constraints,
// and each value below is one the API cannot produce.
func TestTheSchemaRefusesValuesTheApiCannotProduce(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ledger.db")
	s, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer func() { _ = s.Close() }()

	const ins = `INSERT INTO operation_events (object_uid, ordinal, elapsed_seconds, state, healthy) VALUES (?, ?, ?, ?, ?)`
	for _, c := range []struct {
		name string
		args []any
	}{
		{"healthy outside 0 and 1", []any{"uid-1", 1, 0, "Ready", 17}},
		{"a negative elapsed offset", []any{"uid-1", 2, -9, "Ready", 1}},
		{"a negative ordinal", []any{"uid-1", -1, 0, "Ready", 1}},
		{"an empty state", []any{"uid-1", 3, 0, "", 1}},
		{"an empty object uid", []any{"", 4, 0, "Ready", 1}},
	} {
		if _, err := s.db.Exec(ins, c.args...); err == nil {
			t.Errorf("the schema accepted %s", c.name)
		}
	}

	const insRun = `INSERT INTO workload_runs
		(uid, namespace, name, scenario, target_kind, target_name, target_namespace, phase,
		 observed_generation, projected_at_unix_nanos)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
	if _, err := s.db.Exec(insRun, "uid-1", "default", "r1", "ServingPodKilled",
		"InferenceDeployment", "served", "", "NotAPhase", 1, 99); err == nil {
		t.Error("the schema accepted a phase the API cannot produce")
	}
	if _, err := s.db.Exec(insRun, "uid-2", "default", "r2", "ServingPodKilled",
		"InferenceDeployment", "served", "", "Complete", 1, 99); err != nil {
		t.Errorf("the schema rejected a legitimate run: %v", err)
	}
	// Cluster scope is the empty string in the API, not absence, so the column is NOT NULL.
	if _, err := s.db.Exec(`INSERT INTO workload_runs
		(uid, namespace, name, scenario, target_kind, target_name, target_namespace, phase,
		 observed_generation, projected_at_unix_nanos)
		VALUES ('uid-3', 'default', 'r3', 'DegradedNode', 'NodeHealth', 'node-a', NULL, 'Complete', 1, 99)`); err == nil {
		t.Error("the schema accepted a NULL target namespace, inventing a state the API does not have")
	}
}

// STRICT and the CHECK constraints are separate mechanisms, so they get separate tests.
//
// They were one test, and that hid a misreading: dropping every CHECK reddened four of its six cases, and I
// read the two that stayed quiet as "not guarded" when they were simply reported in a different order. A
// diagnostic showed all four value cases are rejected by a named CHECK and the type case by STRICT. One test
// per mechanism means the failure list says which mechanism failed.
func TestStrictRefusesAWrongStorageClass(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ledger.db")
	s, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer func() { _ = s.Close() }()

	_, err = s.db.Exec(
		`INSERT INTO operation_events (object_uid, ordinal, elapsed_seconds, state, healthy) VALUES (?, ?, ?, ?, ?)`,
		"uid-1", 0, "not-a-number", "Ready", 1)
	if err == nil {
		t.Fatal("a text value was accepted into an INTEGER column; the table is not STRICT")
	}
	if !strings.Contains(err.Error(), "cannot store TEXT value in INTEGER column") {
		t.Fatalf("the refusal came from something other than STRICT, so this test is not measuring STRICT: %v", err)
	}
}

// started_at_unix_nanos is nullable because a run that never entered Observing has no start, and storing 0
// would read as the epoch rather than as absence.
func TestARunThatNeverStartedKeepsANullStart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ledger.db")
	s, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer func() { _ = s.Close() }()

	if _, err := s.db.Exec(`INSERT INTO workload_runs
		(uid, namespace, name, scenario, target_kind, target_name, target_namespace, phase,
		 observed_generation, projected_at_unix_nanos)
		VALUES ('uid-1', 'default', 'r1', 'ServingPodKilled', 'InferenceDeployment', 'served', 'default', 'Refused', 1, 99)`); err != nil {
		t.Fatalf("insert a refused run: %v", err)
	}
	var started sql.NullInt64
	if err := s.db.QueryRow(`SELECT started_at_unix_nanos FROM workload_runs WHERE uid='uid-1'`).Scan(&started); err != nil {
		t.Fatalf("read start: %v", err)
	}
	if started.Valid {
		t.Fatalf("a run that never started has start %d; absence was stored as a time", started.Int64)
	}
}
