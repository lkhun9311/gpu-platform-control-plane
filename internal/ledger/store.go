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
type migration struct {
	version int
	stmts   []string
}

// migrations are applied in order, and are append-only.
//
// An applied migration is never edited: a developer whose database is already at version 1 would keep the old
// shape while the file says otherwise, and nothing would report the divergence.
var migrations = []migration{
	{
		version: 1,
		stmts: []string{
			// STRICT so a type mistake is an error instead of a value stored under the wrong type. SQLite's
			// default flexible typing would accept a string in an integer column and return it later without
			// complaint, which in an evidence store is a wrong number that looks like a right one.
			`CREATE TABLE schema_migrations (
				version               INTEGER PRIMARY KEY,
				applied_at_unix_nanos INTEGER NOT NULL
			) STRICT`,

			// One row per WorkloadRun, keyed by the Kubernetes object UID so that re-projecting the same run
			// updates it instead of appending a second account of it.
			//
			// started_at_unix_nanos is NULLABLE on purpose. status.startedAt is set only on entry to
			// Observing (internal/controller/workloadrun_controller.go:147), so a run that ended in Pending
			// or Refused genuinely has no start, and storing 0 there would read as the epoch: a run that
			// began in 1970 rather than one that never began.
			//
			// projected_at_unix_nanos is named for what it is. An observed_at would invite a reader to treat
			// it as the time something happened, and the number would support that reading while being false.
			`CREATE TABLE workload_runs (
				uid                     TEXT PRIMARY KEY,
				namespace               TEXT NOT NULL,
				name                    TEXT NOT NULL,
				scenario                TEXT NOT NULL,
				target_kind             TEXT NOT NULL,
				target_name             TEXT NOT NULL,
				target_namespace        TEXT,
				phase                   TEXT NOT NULL,
				verdict                 TEXT,
				reason                  TEXT,
				started_at_unix_nanos   INTEGER,
				observed_generation     INTEGER NOT NULL,
				projected_at_unix_nanos INTEGER NOT NULL
			) STRICT`,

			// The composite primary key IS the idempotency mechanism, rather than a uniqueness check written
			// beside one: a replay that would duplicate is refused by the storage engine, not by a code path
			// a test has to remember to exercise.
			//
			// elapsed_seconds is the timing authority because that is what the API records --
			// WorkloadRunObservation carries an offset from startedAt and deliberately not a wall clock. A
			// wall-clock time is derived as started_at + elapsed when a reader wants one. Keying on the
			// projector's own clock instead would give every replay a new timestamp, growing the table
			// without bound while every row in it looked legitimate.
			`CREATE TABLE operation_events (
				object_uid      TEXT NOT NULL,
				elapsed_seconds INTEGER NOT NULL,
				state           TEXT NOT NULL,
				healthy         INTEGER NOT NULL,
				PRIMARY KEY (object_uid, elapsed_seconds, state)
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

// OpenForRead opens an existing ledger read-only, and refuses when there is nothing to read.
//
// A missing file is refused rather than reported as an empty ledger. "No runs are recorded" and "the
// recording could not be read" are different facts, and a reader shown the first when the second is true has
// been told something false about their own system.
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

// version reports the highest applied migration, or 0 for a ledger with no schema yet.
func (s *Store) version() (int, error) {
	var name string
	err := s.db.QueryRow(`SELECT name FROM sqlite_master WHERE type='table' AND name='schema_migrations'`).Scan(&name)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("read ledger %s schema: %w", s.path, err)
	}
	var v sql.NullInt64
	if err := s.db.QueryRow(`SELECT MAX(version) FROM schema_migrations`).Scan(&v); err != nil {
		return 0, fmt.Errorf("read ledger %s schema version: %w", s.path, err)
	}
	if !v.Valid {
		// The table exists and records nothing, which is not the same as no schema: some migration created
		// it and then failed to record itself. Saying 0 here would re-run migration 1 against tables that
		// already exist and report the resulting error as a fresh install gone wrong.
		return 0, fmt.Errorf("ledger %s has a schema_migrations table with no rows; it was left half-migrated", s.path)
	}
	return int(v.Int64), nil
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
