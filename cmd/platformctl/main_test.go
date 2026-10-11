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
	"path/filepath"
	"strings"
	"testing"
)

// These pin the two refusals that make the command safe to run by hand, and the one output that must not be
// silent.
//
// The projection logic itself is tested in internal/ledger, where it can be driven without a cluster. What is
// left here is the part a shell touches: whether a missing -ledger is refused instead of defaulted, and
// whether an empty ledger says so.

func TestListRefusesAMissingLedgerFlag(t *testing.T) {
	// A default path would read a database the operator never named. The refusal is the feature.
	if err := list(nil); err == nil {
		t.Fatal("list ran with no -ledger; it must not pick a path on the operator's behalf")
	} else if !strings.Contains(err.Error(), "-ledger is required") {
		t.Fatalf("the refusal does not say what is missing: %v", err)
	}
}

func TestGetRefusesAMissingLedgerFlagAndAMissingName(t *testing.T) {
	if err := get(nil); err == nil {
		t.Fatal("get ran with no -ledger")
	} else if !strings.Contains(err.Error(), "-ledger is required") {
		t.Fatalf("the refusal does not name the missing flag: %v", err)
	}

	// With a ledger but no name there is nothing to look up, and defaulting the name would print some other
	// run's record under a question nobody asked.
	err := get([]string{"-ledger", filepath.Join(t.TempDir(), "x.db")})
	if err == nil {
		t.Fatal("get ran with no -name")
	}
	if !strings.Contains(err.Error(), "-name is required") {
		t.Fatalf("the refusal does not name the missing flag: %v", err)
	}
}

// A ledger that was never written must refuse, not report an empty one. This is the command-level half of the
// distinction internal/ledger.OpenForRead draws.
func TestListRefusesALedgerThatDoesNotExist(t *testing.T) {
	absent := filepath.Join(t.TempDir(), "never-written.db")
	err := list([]string{"-ledger", absent})
	if err == nil {
		t.Fatal("list accepted a path with no ledger; an unread ledger would print as an empty one")
	}
	if !strings.Contains(err.Error(), "unread ledger") {
		t.Fatalf("the refusal does not distinguish unread from empty: %v", err)
	}
}

func TestProjectRefusesAMissingLedgerFlag(t *testing.T) {
	// Checked before any cluster is contacted, so this test needs no apiserver.
	if err := project(nil); err == nil {
		t.Fatal("project ran with no -ledger; it must not create a database nobody named")
	} else if !strings.Contains(err.Error(), "-ledger is required") {
		t.Fatalf("the refusal does not say what is missing: %v", err)
	}
}
