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
)

// Every test here is a statement about ABSENCE, which is the class this repository keeps finding unguarded.
//
// A store that opens, migrates and reports rows is easy to test and proves little. What has to hold is that
// an unread ledger is never reported as an empty one, that a replay cannot duplicate, and that a
// half-migrated database is refused rather than treated as fresh.

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
		var name string
		err := s.db.QueryRow(`SELECT name FROM sqlite_master WHERE type='table' AND name=?`, table).Scan(&name)
		if err != nil {
			t.Fatalf("table %s missing after migration: %v", table, err)
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

// A ledger written by a newer binary has columns this one cannot see, so reading it would answer questions
// about a shape it does not know.
func TestOpenForReadRefusesANewerSchema(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ledger.db")
	w, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	future := schemaVersion + 7
	if _, err := w.db.Exec(`INSERT INTO schema_migrations (version, applied_at_unix_nanos) VALUES (?, 1)`, future); err != nil {
		t.Fatalf("plant a future migration: %v", err)
	}
	if err := w.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	if _, err := OpenForRead(path); err == nil {
		t.Fatal("OpenForRead accepted a ledger from a newer binary")
	} else {
		// Both numbers, or the operator cannot tell which side is behind.
		for _, want := range []string{"7", "1"} {
			if !strings.Contains(err.Error(), want) {
				t.Fatalf("refusal does not name both versions (missing %q): %v", want, err)
			}
		}
	}
	if _, err := Open(path); err == nil {
		t.Fatal("Open accepted a ledger at a higher version and would have migrated downwards")
	}
}

// A schema_migrations table with no rows is a half-migrated ledger. Calling that version 0 would re-run
// migration 1 against tables that already exist and report the collision as a fresh install gone wrong.
func TestHalfMigratedLedgerIsRefusedRatherThanReRun(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ledger.db")
	s, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if _, err := s.db.Exec(`DELETE FROM schema_migrations`); err != nil {
		t.Fatalf("empty the migration record: %v", err)
	}
	if _, err := s.version(); err == nil {
		t.Fatal("a schema_migrations table with no rows was read as version 0")
	} else if !strings.Contains(err.Error(), "half-migrated") {
		t.Fatalf("refusal does not say what is wrong: %v", err)
	}
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
}

// The composite primary key IS the idempotency mechanism, so a duplicate must be refused by the storage
// engine rather than by a code path a caller has to remember.
func TestOperationEventsRefuseADuplicate(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ledger.db")
	s, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer func() { _ = s.Close() }()

	const ins = `INSERT INTO operation_events (object_uid, elapsed_seconds, state, healthy) VALUES (?, ?, ?, ?)`
	if _, err := s.db.Exec(ins, "uid-1", 3, "Ready", 1); err != nil {
		t.Fatalf("first insert: %v", err)
	}
	if _, err := s.db.Exec(ins, "uid-1", 3, "Ready", 1); err == nil {
		t.Fatal("the same observation was stored twice; a replay would duplicate the trail")
	}

	// Same second, different state is a real second observation and must survive.
	if _, err := s.db.Exec(ins, "uid-1", 3, "Degraded", 0); err != nil {
		t.Fatalf("a different state at the same elapsed second was rejected: %v", err)
	}
	var n int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM operation_events`).Scan(&n); err != nil {
		t.Fatalf("count events: %v", err)
	}
	if n != 2 {
		t.Fatalf("operation_events holds %d rows, want 2", n)
	}
}

// STRICT tables exist so a type mistake is an error instead of a value stored under the wrong type. SQLite's
// default flexible typing would accept this and hand it back later without complaint.
func TestStrictTablesRefuseAWrongType(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ledger.db")
	s, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer func() { _ = s.Close() }()

	_, err = s.db.Exec(
		`INSERT INTO operation_events (object_uid, elapsed_seconds, state, healthy) VALUES (?, ?, ?, ?)`,
		"uid-1", "not-a-number", "Ready", 1)
	if err == nil {
		t.Fatal("a text value was accepted into an INTEGER column; the table is not STRICT")
	}
}

// started_at_unix_nanos is nullable because a run that never reached Observing has no start, and storing 0
// would read as the epoch rather than as absence.
func TestARunThatNeverStartedKeepsANullStart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ledger.db")
	s, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer func() { _ = s.Close() }()

	if _, err := s.db.Exec(`INSERT INTO workload_runs
		(uid, namespace, name, scenario, target_kind, target_name, phase, observed_generation, projected_at_unix_nanos)
		VALUES ('uid-1', 'default', 'r1', 'ServingPodKilled', 'InferenceDeployment', 'served', 'Refused', 1, 99)`); err != nil {
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
