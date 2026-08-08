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
	"strings"
	"testing"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/queuelab"
)

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
	if got.RunID != in.RunID || got.Disposition != in.Disposition || len(got.Events) != 1 {
		t.Fatalf("round trip lost content: %+v", got)
	}
}

// A reader must refuse a schema it does not understand rather than interpreting it under today's rules.
func TestDecodeRunRecordRefusesAnUnknownSchema(t *testing.T) {
	b := []byte(`{"schemaVersion":99,"runID":"r7","arm":"A-honor","disposition":"completed-implemented-checks-passed"}`)
	if _, err := decodeRunRecord(b); err == nil {
		t.Fatal("an unknown schema version must be refused")
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
