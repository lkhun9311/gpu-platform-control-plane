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

// Package ledger stores the operations ledger: durable evidence of what the platform did, outliving the
// cluster that produced it.
//
// Design of record: docs/superpowers/specs/2026-09-27-operations-ledger-slice-one-design.md. Slice 1 writes
// two of the six tables docs/07 lists, workload_runs and operation_events, and deliberately leaves the other
// four absent rather than stubbed.
//
// The ledger is a PROJECTION and never a source of truth. Scheduling and quota are decided by the Kubernetes
// resources and the controllers; nothing here may acquire a vote on them, which is why no package under
// internal/controller imports this one.
//
// The driver is modernc.org/sqlite rather than a cgo binding because Dockerfile:22 builds with
// CGO_ENABLED=0. That is a constraint discovered at container-build time rather than by go test, so it is
// written down here: the comparison between drivers was never open.
package ledger

import (
	"database/sql"
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"
	"time"

	// Registers the pure-Go "sqlite" driver for database/sql.
	_ "modernc.org/sqlite"
)

// schemaVersion is the schema this binary understands.
//
// A database at a HIGHER version was written by a newer binary whose columns this one does not know, so
// reading it would answer questions about a shape it cannot see. Both directions are refused by name rather
// than tolerated.
const schemaVersion = 1

// migration is one schema step, applied with its version record in a single transaction.
//
// Recording the version separately from the DDL it describes would leave a database that has the tables and
// denies having them, or claims a version whose tables never arrived. Both read as a working ledger.
//
// tables is what the step promises to have created, so version() can check the claim rather than trust it.
type migration struct {
	version int
	stmts   []string
	tables  []string
}

// migrations are applied in order, and are append-only ONCE SHIPPED.
//
// Editing an applied migration would leave a developer whose database is already at that version keeping the
// old shape while the file says otherwise, with nothing reporting the divergence. Version 1 below was revised
// after a cold review and before it was ever committed, which is the only window in which revising it is
// honest.
var migrations = []migration{
	{
		version: 1,
		tables:  []string{"schema_migrations", "workload_runs", "operation_events"},
		stmts: []string{
			// STRICT constrains storage CLASSES and nothing else: it stops a string landing in an integer
			// column, and it permits healthy=17, a negative offset and an empty required string. Those are
			// semantics, so they are CHECK constraints below. Claiming STRICT covers them was the kind of
			// overstatement this repository exists to catch, and a review caught it here.
			`CREATE TABLE schema_migrations (
				version               INTEGER PRIMARY KEY,
				applied_at_unix_nanos INTEGER NOT NULL,
				CHECK (version > 0),
				CHECK (applied_at_unix_nanos > 0)
			) STRICT`,

			// One row per WorkloadRun, keyed by the Kubernetes object UID so that re-projecting the same run
			// updates it instead of appending a second account of it.
			//
			// target_namespace is NOT NULL because the API represents cluster scope as the EMPTY STRING
			// (api/v1/workloadrun_types.go:80), not as absence. A nullable column here would invent a third
			// state the source of truth does not have.
			//
			// started_at_unix_nanos IS nullable, because a run that never reached Observing has no start.
			// Note what that does NOT mean: a run can acquire a start and later be Refused -- the gap check
			// at internal/controller/workloadrun_controller.go:160 refuses a trail with a hole in it -- so a
			// Refused run may well have one. Storing 0 for the absent case would read as the epoch: a run
			// that began in 1970 rather than one that never began.
			//
			// projected_at_unix_nanos is named for what it is. An observed_at would invite a reader to treat
			// it as the time something happened, and the number would support that reading while being false.
			//
			// The phase and verdict vocabularies are pinned here on purpose. A value the API cannot produce
			// is not evidence, so an unknown one must stop the projection loudly rather than be stored and
			// read back later as though something had reported it.
			`CREATE TABLE workload_runs (
				uid                     TEXT NOT NULL PRIMARY KEY,
				namespace               TEXT NOT NULL,
				name                    TEXT NOT NULL,
				scenario                TEXT NOT NULL,
				target_kind             TEXT NOT NULL,
				target_name             TEXT NOT NULL,
				target_namespace        TEXT NOT NULL,
				phase                   TEXT NOT NULL,
				verdict                 TEXT,
				reason                  TEXT,
				started_at_unix_nanos   INTEGER,
				observed_generation     INTEGER NOT NULL,
				projected_at_unix_nanos INTEGER NOT NULL,
				CHECK (length(uid) > 0),
				CHECK (length(namespace) > 0),
				CHECK (length(name) > 0),
				CHECK (length(scenario) > 0),
				CHECK (length(target_kind) > 0),
				CHECK (length(target_name) > 0),
				CHECK (phase IN ('Pending', 'Observing', 'Complete', 'Refused')),
				CHECK (verdict IS NULL OR verdict IN ('Recovered', 'NotRecovered')),
				CHECK (observed_generation >= 0),
				CHECK (projected_at_unix_nanos > 0)
			) STRICT`,

			// The identity is the observation's POSITION in the trail, not its (second, state) pair.
			//
			// The pair is not unique. The controller truncates elapsed time to whole seconds
			// (internal/controller/workloadrun_controller.go:230) and appends on every state change (:234),
			// so Ready@0 -> Degraded@0 -> Ready@0 is a legal trail whose first and third entries collide. A
			// key on the pair would either abort the projection or drop the later transition, and a projector
			// counting that drop as "already present" would report a LOSS as a successful replay.
			//
			// The ordinal is meaningful rather than incidental: the API defines status.observations as "the
			// trail, in the order they were seen" (api/v1/workloadrun_types.go:189).
			//
			// elapsed_seconds stays the timing authority for reading the trail. It is simply not unique
			// enough to be the identity.
			`CREATE TABLE operation_events (
				object_uid      TEXT NOT NULL,
				ordinal         INTEGER NOT NULL,
				elapsed_seconds INTEGER NOT NULL,
				state           TEXT NOT NULL,
				healthy         INTEGER NOT NULL,
				PRIMARY KEY (object_uid, ordinal),
				CHECK (length(object_uid) > 0),
				CHECK (ordinal >= 0),
				CHECK (elapsed_seconds >= 0),
				CHECK (length(state) > 0),
				CHECK (healthy IN (0, 1))
			) STRICT`,
		},
	},
}

// Store is an open ledger.
type Store struct {
	db   *sql.DB
	path string
}

// Open opens the ledger for writing, creating and migrating it if necessary.
//
// This is the projector's entry point. Creating on demand is right for a writer and wrong for a reader, which
// is why OpenForRead exists separately rather than as a flag on this one.
func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite", "file:"+path+"?_pragma=busy_timeout(5000)")
	if err != nil {
		return nil, fmt.Errorf("open ledger %s: %w", path, err)
	}
	s := &Store{db: db, path: path}
	if err := s.migrate(); err != nil {
		_ = db.Close()
		return nil, err
	}
	return s, nil
}

// OpenForRead opens an existing ledger read-only, and refuses when there is nothing trustworthy to read.
//
// A missing file is refused rather than reported as an empty ledger. "No runs are recorded" and "the
// recording could not be read" are different facts, and a reader shown the first when the second is true has
// been told something false about their own system.
//
// A version other than this binary's is refused in BOTH directions. Higher means columns this binary cannot
// see. Lower means a migration is pending, which is an actionable error rather than proof that today's
// queries are valid against yesterday's shape.
func OpenForRead(path string) (*Store, error) {
	if _, err := os.Stat(path); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("no ledger at %s: this is an unread ledger, not an empty one", path)
		}
		return nil, fmt.Errorf("cannot reach ledger %s: %w", path, err)
	}
	db, err := sql.Open("sqlite", "file:"+path+"?mode=ro&_pragma=busy_timeout(5000)")
	if err != nil {
		return nil, fmt.Errorf("open ledger %s read-only: %w", path, err)
	}
	s := &Store{db: db, path: path}
	have, err := s.version()
	if err != nil {
		_ = db.Close()
		return nil, err
	}
	if have != schemaVersion {
		_ = db.Close()
		return nil, fmt.Errorf("ledger %s is at schema version %d and this binary understands %d; refusing to read a shape it cannot see",
			path, have, schemaVersion)
	}
	return s, nil
}

// Close releases the ledger.
func (s *Store) Close() error {
	if err := s.db.Close(); err != nil {
		return fmt.Errorf("close ledger %s: %w", s.path, err)
	}
	return nil
}

// tableExists reports whether the named table is present.
func (s *Store) tableExists(name string) (bool, error) {
	var got string
	err := s.db.QueryRow(`SELECT name FROM sqlite_master WHERE type='table' AND name=?`, name).Scan(&got)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("read ledger %s schema: %w", s.path, err)
	}
	return true, nil
}

// version reports the highest applied migration, or 0 for a ledger with no schema yet.
//
// It VALIDATES rather than reports. MAX(version) alone accepted a database that claims version 1 while
// operation_events had been dropped, and a history of {1,3} with 2 never applied -- both of which read as a
// healthy ledger and would have been queried as one. A version number is a claim about shape, so it is
// checked against the shape.
func (s *Store) version() (int, error) {
	present, err := s.tableExists("schema_migrations")
	if err != nil {
		return 0, err
	}
	if !present {
		// No migration record at all. That is version 0 only if the schema really is absent; if the tables
		// are there, the ledger has a shape it denies having, which must not be read as a fresh install.
		for _, m := range migrations {
			for _, t := range m.tables {
				if t == "schema_migrations" {
					continue
				}
				got, err := s.tableExists(t)
				if err != nil {
					return 0, err
				}
				if got {
					return 0, fmt.Errorf("ledger %s has table %s but no schema_migrations record; it is half-migrated, not empty", s.path, t)
				}
			}
		}
		return 0, nil
	}

	rows, err := s.db.Query(`SELECT version FROM schema_migrations`)
	if err != nil {
		return 0, fmt.Errorf("read ledger %s schema versions: %w", s.path, err)
	}
	defer func() { _ = rows.Close() }()
	var applied []int
	for rows.Next() {
		var v int
		if err := rows.Scan(&v); err != nil {
			return 0, fmt.Errorf("read ledger %s schema version row: %w", s.path, err)
		}
		applied = append(applied, v)
	}
	if err := rows.Err(); err != nil {
		return 0, fmt.Errorf("read ledger %s schema versions: %w", s.path, err)
	}
	if len(applied) == 0 {
		return 0, fmt.Errorf("ledger %s has a schema_migrations table with no rows; it was left half-migrated", s.path)
	}
	sort.Ints(applied)

	// Contiguous from 1, or some step never ran and the shape is a mixture of two schemas.
	for i, v := range applied {
		if v != i+1 {
			return 0, fmt.Errorf("ledger %s records migrations %s, which is not a contiguous history from 1; some step never ran",
				s.path, joinInts(applied))
		}
	}
	top := applied[len(applied)-1]

	// Every table the applied steps promised must actually be there.
	for _, m := range migrations {
		if m.version > top {
			break
		}
		for _, t := range m.tables {
			got, err := s.tableExists(t)
			if err != nil {
				return 0, err
			}
			if !got {
				return 0, fmt.Errorf("ledger %s claims schema version %d but table %s is missing; the version record is not describing this database",
					s.path, top, t)
			}
		}
	}
	return top, nil
}

func joinInts(xs []int) string {
	parts := make([]string, 0, len(xs))
	for _, x := range xs {
		parts = append(parts, fmt.Sprint(x))
	}
	return "{" + strings.Join(parts, ",") + "}"
}

// migrate brings the ledger up to schemaVersion, applying each step atomically with its version record.
func (s *Store) migrate() error {
	have, err := s.version()
	if err != nil {
		return err
	}
	if have > schemaVersion {
		return fmt.Errorf("ledger %s is at schema version %d and this binary understands %d; refusing to migrate downwards",
			s.path, have, schemaVersion)
	}
	for _, m := range migrations {
		if m.version <= have {
			continue
		}
		tx, err := s.db.Begin()
		if err != nil {
			return fmt.Errorf("begin ledger %s migration %d: %w", s.path, m.version, err)
		}
		for _, stmt := range m.stmts {
			if _, err := tx.Exec(stmt); err != nil {
				_ = tx.Rollback()
				return fmt.Errorf("ledger %s migration %d: %w", s.path, m.version, err)
			}
		}
		if _, err := tx.Exec(`INSERT INTO schema_migrations (version, applied_at_unix_nanos) VALUES (?, ?)`,
			m.version, time.Now().UnixNano()); err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("record ledger %s migration %d: %w", s.path, m.version, err)
		}
		if err := tx.Commit(); err != nil {
			return fmt.Errorf("commit ledger %s migration %d: %w", s.path, m.version, err)
		}
	}
	return nil
}
