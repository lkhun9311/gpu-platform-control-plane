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
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeRecord(t *testing.T, dir, name string, r CellRecord) string {
	t.Helper()
	b, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, b, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// A record round-trips through the file, so every refusal below is about the loader.
func TestARecordRoundTripsThroughItsFile(t *testing.T) {
	p := loadedProtocol(t)
	dir := t.TempDir()
	want := validTreatmentCell(p, 2)
	got, err := LoadCellRecord(writeRecord(t, dir, "a.json", want))
	if err != nil {
		t.Fatalf("a record this build wrote was refused on the way back in: %v", err)
	}
	if got.Arm != want.Arm || got.Repetition != want.Repetition || got.Attempt != want.Attempt {
		t.Errorf("identity did not survive: got %s/%d/%d", got.Arm, got.Repetition, got.Attempt)
	}
	if len(got.Censuses) != len(want.Censuses) {
		t.Errorf("census count did not survive: %d, want %d", len(got.Censuses), len(want.Censuses))
	}
	if got.Treatment == nil || !got.Treatment.Applied {
		t.Error("the treatment verdict did not survive")
	}
	if err := p.CheckCell(got); err != nil {
		t.Errorf("the reloaded record was refused by CheckCell: %v", err)
	}
}

// A key this build does not know must be refused, and the direction is what makes it matter.
//
// The zero value of `invalidated_because` is the empty string, which Valid() reads as "this cell stands". Under
// a lenient decoder a mistyped key is dropped and the field keeps that zero value -- so a single transposed
// letter would promote a discarded attempt into the comparison, silently, in the one direction that adds a
// figure nothing supports.
//
// Mutation that turns this red: drop DisallowUnknownFields.
func TestAKeyThisBuildDoesNotKnowIsRefusedRatherThanDropped(t *testing.T) {
	p := loadedProtocol(t)
	dir := t.TempDir()

	discarded := validReferenceCell(p)
	discarded.InvalidatedBecause = "scheduler_restart_during_the_cell"
	discarded.ArmQualification.Qualified = false
	b, err := json.Marshal(discarded)
	if err != nil {
		t.Fatal(err)
	}
	// The mistyped key is DERIVED rather than written out, by transposing two letters of the correct one.
	//
	// Not fastidiousness: `misspell` fails the build on the wrong spelling as a literal, here and in a comment
	// where this was first written as an example. A spell-checking gate cannot tell a wrong word used as this
	// test's input from a wrong word used by mistake, and deriving it keeps the gate sharp instead of silencing
	// it with a nolint.
	const correct = "invalidated_because"
	i := strings.Index(correct, "bec") + 3
	mistyped := correct[:i] + string(correct[i+1]) + string(correct[i]) + correct[i+2:]
	if mistyped == correct || len(mistyped) != len(correct) {
		t.Fatalf("the key was not mistyped (%q); this case would test nothing", mistyped)
	}
	typo := strings.Replace(string(b), `"`+correct+`"`, `"`+mistyped+`"`, 1)
	if typo == string(b) {
		t.Fatalf("the key %q was not present to mistype; this case is not a verdict about the loader", correct)
	}
	path := filepath.Join(dir, "typo.json")
	if err := os.WriteFile(path, []byte(typo), 0o600); err != nil {
		t.Fatal(err)
	}

	got, err := LoadCellRecord(path)
	if err == nil {
		// This is the failure the check exists for: report what the campaign would have believed.
		t.Fatalf("a record with a mistyped invalidation key was accepted, and it reads as standing=%t; the "+
			"discarded attempt would have entered the comparison", got.Valid())
	}
	if !strings.Contains(err.Error(), "does not parse") {
		t.Errorf("the refusal blames something other than the parse: %v", err)
	}
	if !strings.Contains(err.Error(), "promote a discarded attempt") {
		t.Errorf("the refusal does not say why the direction matters: %v", err)
	}
}

// A file holding a second JSON document is refused rather than half-read.
//
// Mutation that turns this red: drop the dec.More() check.
func TestASecondDocumentInOneFileIsRefused(t *testing.T) {
	p := loadedProtocol(t)
	dir := t.TempDir()
	one, err := json.Marshal(validReferenceCell(p))
	if err != nil {
		t.Fatal(err)
	}
	two := append(append([]byte{}, one...), '\n')
	two = append(two, one...)
	path := filepath.Join(dir, "twice.json")
	if err := os.WriteFile(path, two, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadCellRecord(path); err == nil {
		t.Fatal("a file holding two records was accepted; only the first would have been judged")
	} else if !strings.Contains(err.Error(), "more than one JSON document") {
		t.Errorf("the refusal is not the two-document one: %v", err)
	}
}

// The directory loader reads every attempt, in a stable order, and refuses an empty directory.
//
// Order matters because a verdict that names "attempt 3 of 6" has to mean the same thing on every machine;
// directory order is not specified. Refusing empty matters because reading no attempts as a campaign would
// report a comparison from nothing.
//
// Mutation that turns this red: drop the sort, or the empty-directory refusal.
func TestEveryAttemptIsReadInAStableOrder(t *testing.T) {
	p := loadedProtocol(t)
	dir := t.TempDir()

	if _, _, err := LoadCellRecords(dir); err == nil {
		t.Error("an empty directory was read as a campaign")
	} else if !strings.Contains(err.Error(), "not a campaign") {
		t.Errorf("the refusal is not the empty-directory one: %v", err)
	}

	// Written in an order that is not the sorted order, so a loader that trusted the filesystem would differ.
	writeRecord(t, dir, "c-treatment-3.json", validTreatmentCell(p, 3))
	writeRecord(t, dir, "a-reference-1.json", validReferenceCell(p))
	writeRecord(t, dir, "b-treatment-1.json", validTreatmentCell(p, 1))
	// A file the loader must ignore, and one it must not.
	if err := os.WriteFile(filepath.Join(dir, "run.log"), []byte("not a record"), 0o600); err != nil {
		t.Fatal(err)
	}

	records, paths, err := LoadCellRecords(dir)
	if err != nil {
		t.Fatalf("the directory was refused: %v", err)
	}
	if len(records) != 3 || len(paths) != 3 {
		t.Fatalf("read %d record(s) and %d path(s), want 3 of each; run.log must be skipped and no .json may be",
			len(records), len(paths))
	}
	for i, want := range []string{"a-reference-1.json", "b-treatment-1.json", "c-treatment-3.json"} {
		if filepath.Base(paths[i]) != want {
			t.Errorf("position %d is %s, want %s; the order must not depend on the filesystem",
				i, filepath.Base(paths[i]), want)
		}
	}
	if records[0].Arm != ArmUntouched || records[1].Arm != ArmConfigured {
		t.Errorf("the records do not follow their paths: %s then %s", records[0].Arm, records[1].Arm)
	}

	// One unreadable record fails the whole load rather than being skipped: a loader that ignored it would be
	// deciding which attempts the campaign remembers, and remembering all of them is the defence against
	// retaking on the outcome.
	if err := os.WriteFile(filepath.Join(dir, "d-broken.json"), []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := LoadCellRecords(dir); err == nil {
		t.Error("a directory with one unreadable record was loaded as though that attempt did not exist")
	}
}
