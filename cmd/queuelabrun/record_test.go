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
	"reflect"
	"strings"
	"testing"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/queuelab"
)

// The assertion checks every field, not a sample, so a struct-copy bug or a stray json:"-" on any one
// field cannot slip through a partial check the way an earlier revision of this test allowed.
func TestRunRecordRoundTrips(t *testing.T) {
	in := runRecord{
		SchemaVersion: recordSchemaVersion,
		RunID:         "r7",
		Arm:           "A-honor",
		StartedAt:     "2026-08-08T10:00:00Z",
		EndedAt:       "2026-08-08T10:02:30Z",
		Disposition:   string(dispChecksPassed),
		Reason:        "",
		Events:        []queuelab.LifecycleEvent{{ElapsedNs: 1, Kind: "Pod", Job: "a1"}},
	}
	b, err := encodeRecord(in)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	got, err := decodeRunRecord(b)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !reflect.DeepEqual(got, in) {
		t.Fatalf("round trip lost content: got %+v, want %+v", got, in)
	}
}

// A reader must refuse a schema it does not understand rather than interpreting it under today's rules.
func TestDecodeRunRecordRefusesAnUnknownSchema(t *testing.T) {
	b := []byte(`{"schemaVersion":99,"runID":"r7","arm":"A-honor","disposition":"completed-implemented-checks-passed"}`)
	if _, err := decodeRunRecord(b); err == nil {
		t.Fatal("an unknown schema version must be refused")
	}
}

// A field the schema does not define must be refused, not silently dropped, or a hand-edited or
// future-schema document could carry content decodeRunRecord never validated.
func TestDecodeRunRecordRefusesAnUnknownField(t *testing.T) {
	b := []byte(`{"schemaVersion":1,"runID":"r7","arm":"A-honor",` +
		`"disposition":"completed-implemented-checks-passed","bogusField":"x"}`)
	if _, err := decodeRunRecord(b); err == nil {
		t.Fatal("an unrecognized field must be refused")
	}
}

// A record without a run identity is not a usable record regardless of what else it claims.
func TestDecodeRunRecordRefusesEmptyRunID(t *testing.T) {
	b := []byte(`{"schemaVersion":1,"runID":"","arm":"A-honor","disposition":"completed-implemented-checks-passed"}`)
	if _, err := decodeRunRecord(b); err == nil {
		t.Fatal("an empty runID must be refused")
	}
}

// Preview safety is structural, not conventional: queuelab.Reconstruct takes an event slice, so anything
// decodable back into one is reconstructable no matter what the field is called or what flag sits beside
// it. The preview record therefore has no field that can carry events at all.
func TestPreviewRecordCannotCarryEvents(t *testing.T) {
	p := previewRecord{
		SchemaVersion: recordSchemaVersion,
		Preview:       true,
		RunID:         "r7",
		Arm:           "A-honor",
		Disposition:   string(dispChecksPassed),
		EventCount:    42,
		Note:          "preview: gates were not enforced, this is not evidence",
	}
	b, err := encodeRecord(p)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}

	// Nothing in the encoded form may decode into lifecycle events.
	var probe struct {
		Events []queuelab.LifecycleEvent `json:"events"`
	}
	if err := json.Unmarshal(b, &probe); err != nil {
		t.Fatalf("probe: %v", err)
	}
	if len(probe.Events) != 0 {
		t.Fatal("a preview record must not carry anything decodable into lifecycle events")
	}
	if strings.Contains(string(b), "elapsedNs") {
		t.Fatalf("a preview record must not contain event fields: %s", b)
	}
}

// A record claiming to be a preview while carrying events is malformed and must be refused, so a
// hand-edited or future file cannot smuggle evidence through the preview branch.
func TestDecodeRunRecordRefusesPreviewWithEvents(t *testing.T) {
	b := []byte(`{"schemaVersion":1,"preview":true,"runID":"r7","arm":"A-honor",` +
		`"disposition":"completed-implemented-checks-passed","events":[{"elapsedNs":1,"kind":"Pod"}]}`)
	if _, err := decodeRunRecord(b); err == nil {
		t.Fatal("a preview record carrying events must be refused")
	}
}

// A successful write must leave exactly the destination file behind, with the content actually written
// decodable back to the value passed in — not merely some decodable-but-unrelated bytes, and not a
// leftover temp file beside it.
func TestWriteRecordLeavesNoPartialFile(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/run.json"

	want := runRecord{
		SchemaVersion: recordSchemaVersion,
		RunID:         "r7",
		Arm:           "A-honor",
		Disposition:   string(dispChecksPassed),
	}
	if err := writeRecord(path, want); err != nil {
		t.Fatalf("write: %v", err)
	}

	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read back: %v", err)
	}
	got, err := decodeRunRecord(b)
	if err != nil {
		t.Fatalf("the written record must decode: %v", err)
	}
	// Decoding without error is not enough: a writer that ignored v and emitted some other fixed,
	// decodable record would still pass a bare decode check, so the decoded value must match what was
	// actually asked to be written.
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("written record does not match what was passed in: got %+v, want %+v", got, want)
	}

	// No temporary file may survive a successful write.
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected exactly the record, got %d entries", len(entries))
	}
	// The one surviving entry must be the destination itself, not some other artifact of the rename.
	if entries[0].Name() != "run.json" {
		t.Fatalf("expected the surviving entry to be run.json, got %q", entries[0].Name())
	}
}

// A write into a directory that does not exist must fail loudly rather than leaving the caller believing
// the run was recorded, and it must not scribble a stray file into the parent directory as a side effect
// of the failed attempt.
func TestWriteRecordFailsLoudlyOnAnUnwritablePath(t *testing.T) {
	parent := t.TempDir()
	if err := writeRecord(parent+"/missing/run.json", runRecord{
		SchemaVersion: recordSchemaVersion, RunID: "r7", Arm: "A-honor",
		Disposition: string(dispChecksPassed),
	}); err == nil {
		t.Fatal("writing into a missing directory must fail")
	}

	entries, err := os.ReadDir(parent)
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("a failed write must leave no trace in the parent directory, got %d entries", len(entries))
	}
}
