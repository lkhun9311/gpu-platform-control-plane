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
	"errors"
	"os"
	"reflect"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime/schema"

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

// This test verifies success-content-correctness — that a successful write leaves exactly the destination
// file behind, decodable back to the value passed in — and leftover-temp-file cleanliness. It does not
// verify the atomic replace-not-modify mechanism itself; see TestWriteRecordReplacesTheDestinationInode
// for that, because passing here is consistent with a non-atomic in-place write.
//
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

// This test verifies failure-signalling — that a write which cannot proceed returns a non-nil error and
// leaves no stray file behind — not the atomic replace-not-modify mechanism of a successful write; see
// TestWriteRecordReplacesTheDestinationInode for that.
//
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

// TestWriteRecordReplacesTheDestinationInode pins the atomic replace-not-modify mechanism itself, which
// the two tests above do not: they would pass just as well against a naive os.WriteFile(path, b, 0o644)
// that opens the destination with O_TRUNC and writes into it in place.
//
// The distinguishing property is not timing, so it needs no race and cannot be flaky: os.WriteFile reuses
// the destination's inode, while temp-file-plus-rename replaces the directory entry with a new inode. A
// changed inode number between two successive writes is direct, deterministic evidence that a rename
// happened rather than an in-place modification.
func TestWriteRecordReplacesTheDestinationInode(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("inode numbers are not a meaningful concept on this platform")
	}
	dir := t.TempDir()
	path := dir + "/run.json"

	if err := writeRecord(path, runRecord{
		SchemaVersion: recordSchemaVersion, RunID: "r1", Arm: "A-honor", Disposition: string(dispChecksPassed),
	}); err != nil {
		t.Fatalf("write 1: %v", err)
	}
	fi1, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat 1: %v", err)
	}
	st1, ok := fi1.Sys().(*syscall.Stat_t)
	if !ok {
		t.Skip("syscall.Stat_t is not available on this platform")
	}
	ino1 := st1.Ino

	if err := writeRecord(path, runRecord{
		SchemaVersion: recordSchemaVersion, RunID: "r2", Arm: "A-honor", Disposition: string(dispChecksPassed),
	}); err != nil {
		t.Fatalf("write 2: %v", err)
	}
	fi2, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat 2: %v", err)
	}
	st2 := fi2.Sys().(*syscall.Stat_t)
	ino2 := st2.Ino

	if ino1 == ino2 {
		t.Fatalf("destination inode did not change across two writes (both %d): the file was modified in "+
			"place rather than replaced by a rename, so a reader racing a write could observe a partial file",
			ino1)
	}
}

// absenceName's spellings are a wire format: runRecord.Residue and the Node residue record both persist
// them, so a rename here silently relabels every record already written under the old name. The two other
// residue tests in this file each pin one spelling as a side effect of asserting a full record, but neither
// checks it against a literal — they check it against what buildRecord happened to produce, which is not a
// test of absenceName at all. This one is direct and literal, so a rename of any spelling, or of the
// default's "unrecognised" prefix, has nothing else to hide behind.
func TestAbsenceNameSpellings(t *testing.T) {
	cases := []struct {
		a    absence
		want string
	}{
		{absencePresent, "present"},
		{absenceAbsent, "absent"},
		{absenceForeign, "foreign"},
		{absenceUnknown, "unknown"},
		// A constant added to teardown.go without a matching case here must not fall back to "unknown" — the
		// spelling that means "nobody could tell" — because that would hide the missing case inside a value
		// the schema calls legitimate. It must name the integer instead, so the bug is visible in the record.
		{absence(99), "unrecognised(99)"},
	}
	for _, tc := range cases {
		if got := absenceName(tc.a); got != tc.want {
			t.Errorf("absenceName(%d) = %q, want %q", int(tc.a), got, tc.want)
		}
	}
}

// The residue is the one thing a teardown that did not finish leaves for anybody to act on, so it has to
// survive the round trip the record's whole contract is built on: written, and then read back by a reader
// that refuses anything it does not fully understand.
//
// The entry here carries a REFUSED DELETE on purpose. That is the case settlePhase holds a delete error
// aside for — "the apiserver said no" is the single most useful thing a residue record can say, and it is
// also the case that breaks if the record persists teardown.go's `residue` verbatim: an `error` field
// encodes as `{}` and decodes not at all, so exactly the runs whose teardown was refused would write a
// record decodeRunRecord rejects. Hence the projection this asserts against, and hence the error text
// assertion rather than a bare "the entry is there".
func TestRunRecordCarriesTheResidueAndStillDecodes(t *testing.T) {
	refused := apierrors.NewForbidden(schema.GroupResource{Resource: "namespaces"}, "queuelab-r7",
		errors.New("teardown may not delete namespaces"))
	left := []residue{{
		Observation: observation{
			Target:  target{Phase: phaseNamespace, Kind: "Namespace", Name: "queuelab-r7"},
			Found:   true,
			UID:     "ns-uid",
			WantUID: "ns-uid",
			Err:     refused,
		},
		Absence: absenceUnknown,
	}}

	rec := buildRecord(outcome{Disposition: dispResidueLeft, Reason: "teardown left 1 object(s)"}, nil, left, nil,
		"r7", "A-honor", false, time.Now(), time.Now())
	b, err := encodeRecord(rec)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	got, err := decodeRunRecord(b)
	if err != nil {
		t.Fatalf("a record carrying residue must decode, or the residue is written and then unreadable "+
			"exactly when it matters most: %v\n%s", err, b)
	}
	if len(got.Residue) != 1 {
		t.Fatalf("the record carries %d residue entries, want 1: residue that only reached stderr is "+
			"printed and lost, which is the failure this field exists to end\n%s", len(got.Residue), b)
	}
	e := got.Residue[0]
	if e.Kind != "Namespace" || e.Name != "queuelab-r7" {
		t.Fatalf("the entry must name the object still there, got %s %q", e.Kind, e.Name)
	}
	if e.Absence != "unknown" {
		t.Fatalf("the verdict must be persisted by name, not as the iota an inserted constant would "+
			"silently relabel, got %q", e.Absence)
	}
	if !strings.Contains(e.Error, "forbidden") {
		t.Fatalf("the refusal must survive into the record, or a residue entry reads as a slow finalizer "+
			"when it was actually a permission the run never had, got %q", e.Error)
	}
	if e.UID != "ns-uid" || !e.Found {
		t.Fatalf("the entry must carry what was observed, got %+v", e)
	}
}

// residueForRecord copies eight fields, and two of them — Terminating and WantUID — had no assertion
// anywhere in this file before this test: dropping either from the projection left the whole package
// green. Terminating is the operator's first question reading a residue entry, because it is what tells a
// finalizer stuck on an object apart from a Delete that never even landed; WantUID is what the next
// operator compares against a fresh read to tell "still ours" from "somebody else's object took the name
// after ours left". UID and WantUID are given different values so a projection that swapped the two, not
// just dropped one, would also be caught.
func TestResidueForRecordProjectsTerminatingAndWantUID(t *testing.T) {
	left := []residue{{
		Observation: observation{
			Target:      target{Kind: "Namespace", Name: "queuelab-r7"},
			Found:       true,
			Terminating: true,
			UID:         "have-uid",
			WantUID:     "want-uid",
		},
		Absence: absencePresent,
	}}
	out := residueForRecord(left)
	if len(out) != 1 {
		t.Fatalf("got %d entries, want 1: %+v", len(out), out)
	}
	e := out[0]
	if !e.Terminating {
		t.Fatal("Terminating dropped by the projection: a namespace stuck on a finalizer now reads " +
			"identically to one whose Delete never landed, which is the distinction this field exists for")
	}
	if e.WantUID != "want-uid" {
		t.Fatalf("WantUID = %q, want %q: dropped, or overwritten by the UID field, in the projection",
			e.WantUID, "want-uid")
	}
	if e.UID != "have-uid" {
		t.Fatalf("UID = %q, want %q: corrupted by whatever is wrong with the WantUID projection above",
			e.UID, "have-uid")
	}
}

// A preview is the mode that generates residue TODAY — it runs the whole of run(), namespace and fixtures
// included — so dropping the residue from its record would lose it for the only mode currently producing
// it. Residue is safe to carry there for the reason previewRecord's own comment gives: the guarantee is
// structural, and recordResidue has no field a lifecycle ledger can be decoded out of.
func TestPreviewRecordCarriesResidueToo(t *testing.T) {
	left := []residue{{
		Observation: observation{
			Target: target{Phase: phaseResourceFlavor, Kind: "ResourceFlavor", Name: "queuelab-gpu-r7"},
			Found:  true, UID: "rf-uid", WantUID: "rf-uid",
		},
		Absence: absencePresent,
	}}
	pr, ok := buildRecord(outcome{Disposition: dispResidueLeft}, nil, left, nil, "r7", "A-honor", true,
		time.Now(), time.Now()).(previewRecord)
	if !ok {
		t.Fatal("a preview invocation must build a previewRecord")
	}
	if len(pr.Residue) != 1 || pr.Residue[0].Name != "queuelab-gpu-r7" {
		t.Fatalf("a preview's record must carry what its own teardown could not remove, got %+v", pr.Residue)
	}
	if pr.Residue[0].Absence != "present" {
		t.Fatalf("verdict = %q, want present", pr.Residue[0].Absence)
	}
}

// What the run observed about its worker has to survive into the artifact, through a decoder that rejects
// anything it does not fully understand. A qualification that only reached stderr is the same loss the
// residue field was added to end: the run that refused is exactly the run whose evidence nobody kept.
//
// The refusal shape is asserted rather than the clean one, because the clean one is the case where dropping
// the field costs least — an empty consumer list read back as an empty consumer list looks identical whether
// it was persisted or not.
//
// Mutation that turns this red: delete the Qualification field from runRecord, or stop assigning it in
// buildRecord. Either leaves the whole package green apart from this test and its preview twin below.
func TestRunRecordCarriesTheQualificationAndStillDecodes(t *testing.T) {
	q := &qualification{
		Node:           "platform-worker",
		NodeUID:        "uid-node",
		AllocatableGPU: 2,
		RequiredGPU:    2,
		RequiredFrom:   "nominal nvidia.com/gpu quota summed over 2 ClusterQueue(s) on flavor queuelab-gpu-r7",
		Ready:          true,
		Schedulable:    true,
		PodsOnNode:     4,
		GPUConsumers: []gpuConsumer{
			{Namespace: "tenant-a", Name: "train-7", Phase: "Running", Terminating: true, GPUs: 2},
		},
	}
	rec := buildRecord(outcome{Disposition: dispEnvironmentUnqualified, Reason: "a GPU Pod was already there"},
		nil, nil, q, "r7", "A-honor", false, time.Now(), time.Now())
	b, err := encodeRecord(rec)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	got, err := decodeRunRecord(b)
	if err != nil {
		t.Fatalf("a record carrying a qualification must decode, or the evidence is written and then "+
			"unreadable exactly on the runs that produced it: %v\n%s", err, b)
	}
	if got.Qualification == nil {
		t.Fatalf("the qualification did not survive the round trip:\n%s", b)
	}
	if !reflect.DeepEqual(*got.Qualification, *q) {
		t.Fatalf("the qualification changed on the round trip:\n got %+v\nwant %+v\n%s", *got.Qualification, *q, b)
	}
	// The denominator is the half a projection is most likely to drop, because it is the field that says
	// nothing on its own: "no foreign consumer among four Pods inspected" is a claim, and "no foreign
	// consumer" with no count is indistinguishable from having looked in the wrong place.
	if got.Qualification.PodsOnNode != 4 {
		t.Fatalf("PodsOnNode = %d, want 4", got.Qualification.PodsOnNode)
	}
	t.Logf("persisted record:\n%s", b)
}

// A run refused before it ever reached its worker — a bad flag, a refused acquisition — has observed nothing,
// and a record for it must say nothing rather than write a zero qualification claiming a node named "" was
// inspected and found fine. That is why the field is a pointer.
//
// Mutation that turns this red: make runRecord.Qualification a value rather than a pointer. The key then
// appears on every record ever written, populated with zeros, and every reader has to know that Ready:false
// on a node with no name means "not checked".
func TestARecordWithNoQualificationCarriesNoQualificationKey(t *testing.T) {
	rec := buildRecord(outcome{Disposition: dispAcquisitionRefused, Reason: "held by another run"},
		nil, nil, nil, "r7", "A-honor", false, time.Now(), time.Now())
	b, err := encodeRecord(rec)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	if strings.Contains(string(b), "qualification") {
		t.Fatalf("a run that never qualified its worker wrote a qualification anyway:\n%s", b)
	}
}

// A preview runs the whole of run(), so it qualifies its worker exactly as a real run does. Withholding the
// qualification from its record would lose the observation for the only mode that currently produces one on a
// live cluster, and it is safe here for the same structural reason the residue is: it describes the machine,
// and has no field a lifecycle ledger can be decoded out of.
//
// Mutation that turns this red: drop Qualification from previewRecord or stop assigning it in buildRecord's
// preview branch.
func TestPreviewRecordCarriesTheQualificationToo(t *testing.T) {
	q := &qualification{Node: "platform-worker", NodeUID: "uid-node", AllocatableGPU: 2, RequiredGPU: 2,
		Ready: true, Schedulable: true, PodsOnNode: 3}
	pr, ok := buildRecord(outcome{Disposition: dispChecksPassed}, nil, nil, q, "r7", "A-honor", true,
		time.Now(), time.Now()).(previewRecord)
	if !ok {
		t.Fatal("a preview invocation must build a previewRecord")
	}
	if pr.Qualification == nil || pr.Qualification.Node != "platform-worker" {
		t.Fatalf("a preview's record must say which machine it smoke-tested, got %+v", pr.Qualification)
	}
	if pr.Qualification.PodsOnNode != 3 {
		t.Fatalf("PodsOnNode = %d, want 3", pr.Qualification.PodsOnNode)
	}
}
