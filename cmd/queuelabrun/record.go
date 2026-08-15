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
	"bytes"
	"encoding/json"
	"fmt"
	"time"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/queuelab"
)

// recordSchemaVersion is refused by any reader that does not know it.
//
// An unknown version must not be read under today's rules: the whole point of the record is that a later
// reader can tell what a run actually established, and silently applying current semantics to a document
// written under different ones is the failure this package exists to prevent.
const recordSchemaVersion = 1

// runRecord is what a non-preview invocation leaves behind.
//
// It makes no experimental claim: it says an invocation happened, what disposition it reached, and carries
// the raw events. Fixtures, environment, restoration audit and validity are later pieces and add their own
// fields when they exist rather than being reserved here.
type runRecord struct {
	SchemaVersion int `json:"schemaVersion"`
	// Preview has no writer on purpose, and is NOT a reserved slot like the Flags field deleted before it: it
	// exists for decodeRunRecord, so that a preview document fed to a run-record reader is rejected by the
	// specific check below rather than by a generic unknown-field error that says nothing about why. Deleting
	// it would silently weaken that message, so it stays despite buildRecord never setting it.
	//
	// It buys only that message: a hand-written {"schemaVersion":1,"preview":true,"runID":"x",
	// "disposition":"y"} with no events still decodes as a valid RUN record, because the check that fires is
	// about carrying events, not about the flag.
	Preview     bool   `json:"preview,omitempty"`
	RunID       string `json:"runID"`
	Arm         string `json:"arm"`
	StartedAt   string `json:"startedAt,omitempty"`
	EndedAt     string `json:"endedAt,omitempty"`
	Disposition string `json:"disposition"`
	Reason      string `json:"reason,omitempty"`
	// Events is the ledger. It is present whenever a collector ran.
	Events []queuelab.LifecycleEvent `json:"events,omitempty"`
}

// previewRecord is a separate type, not runRecord with the events omitted.
//
// A preview runs without the validity gates, so its output must not be convertible into evidence. Because
// queuelab.Reconstruct accepts an event slice, any field decodable into one is reconstructable regardless
// of its name — so the preview branch has no such field at all, and the summary below is deliberately
// lossy.
type previewRecord struct {
	SchemaVersion int    `json:"schemaVersion"`
	Preview       bool   `json:"preview"`
	RunID         string `json:"runID"`
	Arm           string `json:"arm"`
	StartedAt     string `json:"startedAt,omitempty"`
	EndedAt       string `json:"endedAt,omitempty"`
	Disposition   string `json:"disposition"`
	Reason        string `json:"reason,omitempty"`
	// EventCount is a count, not a ledger: it cannot be inverted into events.
	EventCount int    `json:"eventCount"`
	Note       string `json:"note"`
}

// previewNote is a fixed constant, never anything derived from the run.
//
// previewRecord has no field a ledger can be decoded out of, but Note is free text, so a future writer could
// fold run data — a JSON-encoded ledger, most obviously — into it and hand a gateless run exactly the
// reconstructable evidence the type was shaped to deny it. A constant closes that second-order route with
// something a test can check, which a formatted string could not be.
const previewNote = "preview: the validity gates were not enforced, so this is a smoke check and not evidence"

// classified refuses a zero disposition, which is the one thing a record must never carry.
//
// run sets a disposition on every return, but nothing in the language enforces that: deleting a single
// assignment leaves the named return at its zero value, and neither the compiler nor go vet says a word.
// The test that walked the returns could only reach two of seventeen, so the invariant is enforced here,
// where every record is built, rather than audited where only some are reachable.
//
// It substitutes rather than panicking. A panic in the record writer would destroy the record for a run
// that genuinely happened, which is precisely the evidence loss this whole task exists to stop; naming the
// bug in the artifact keeps the record, fails the run (main exits non-zero on anything that is not
// dispChecksPassed), and leaves a string a reader can grep for.
func classified(o outcome) outcome {
	if o.Disposition != "" {
		return o
	}
	reason := "a return path set no disposition; this is a bug in run(), not an outcome of the run"
	if o.Reason != "" {
		reason = reason + " (reason given: " + o.Reason + ")"
	}
	return outcome{Disposition: dispUnclassified, Reason: reason}
}

// buildRecord chooses which record a given invocation may leave behind.
//
// This is the only place the preview and non-preview branches diverge, so the guarantee that a gateless run
// cannot emit reconstructable evidence lives in one readable decision rather than being spread across the
// call sites that write.
func buildRecord(o outcome, events []queuelab.LifecycleEvent, runID, arm string, preview bool,
	started, ended time.Time) any {
	o = classified(o)
	startedAt := started.UTC().Format(time.RFC3339)
	endedAt := ended.UTC().Format(time.RFC3339)
	if preview {
		return previewRecord{
			SchemaVersion: recordSchemaVersion,
			Preview:       true,
			RunID:         runID,
			Arm:           arm,
			StartedAt:     startedAt,
			EndedAt:       endedAt,
			Disposition:   string(o.Disposition),
			Reason:        o.Reason,
			EventCount:    len(events),
			Note:          previewNote,
		}
	}
	return runRecord{
		SchemaVersion: recordSchemaVersion,
		RunID:         runID,
		Arm:           arm,
		StartedAt:     startedAt,
		EndedAt:       endedAt,
		Disposition:   string(o.Disposition),
		Reason:        o.Reason,
		Events:        events,
	}
}

func encodeRecord(v any) ([]byte, error) {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("encode record: %w", err)
	}
	return append(b, '\n'), nil
}

// decodeRunRecord refuses anything it does not fully understand.
//
// A non-empty RunID is required but does not mean a run id somebody chose: an invocation refused before it
// read -runid is recorded under the unidentifiedRunID sentinel, which runIDPattern can never accept, so a
// reader matching records to runs must expect ids that name no run.
func decodeRunRecord(b []byte) (runRecord, error) {
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	var r runRecord
	if err := dec.Decode(&r); err != nil {
		return runRecord{}, fmt.Errorf("decode record: %w", err)
	}
	if r.SchemaVersion != recordSchemaVersion {
		return runRecord{}, fmt.Errorf("decode record: schema %d is not %d", r.SchemaVersion, recordSchemaVersion)
	}
	if r.Preview && len(r.Events) > 0 {
		return runRecord{}, fmt.Errorf("decode record: a preview record carries %d events; preview output is not evidence",
			len(r.Events))
	}
	if r.RunID == "" || r.Disposition == "" {
		return runRecord{}, fmt.Errorf("decode record: runID and disposition are required")
	}
	return r, nil
}
