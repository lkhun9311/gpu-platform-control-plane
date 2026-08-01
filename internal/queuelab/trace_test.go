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

package queuelab

import (
	"bytes"
	"fmt"
	"testing"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/exputil"
)

const tenantA = "tenant-a"

// jsonRow renders one trace row as a JSON Lines record, so malformed-input tests can vary a single field
// without repeating the whole object literal.
func jsonRow(index int, name string, offsetMs, gpu, dur int) string {
	return fmt.Sprintf(`{"index":%d,"name":%q,"offsetMs":%d,"tenant":%q,"gpuCount":%d,"durationSec":%d}`+"\n",
		index, name, offsetMs, tenantA, gpu, dur)
}

func TestReclaimScenarioLateVsEarly(t *testing.T) {
	late := ReclaimScenario(true, 600)
	early := ReclaimScenario(false, 600)

	if len(late) != 3 || len(early) != 3 {
		t.Fatalf("reclaim scenario should have 3 rows")
	}
	// The owner (b1) returns near the end of the borrowed job under lateReturn, and early otherwise.
	if late[2].OffsetMs <= early[2].OffsetMs {
		t.Fatalf("late owner offset %d should exceed early %d", late[2].OffsetMs, early[2].OffsetMs)
	}
	if late[2].OffsetMs != 600*1000-10_000 {
		t.Fatalf("late owner offset = %d, want %d", late[2].OffsetMs, 600*1000-10_000)
	}
	if late[1].Name != "a2-borrow" || late[1].Tenant != tenantA {
		t.Fatalf("row 1 should be tenant-a's borrowing job")
	}
	if late[2].Tenant != "tenant-b" {
		t.Fatalf("row 2 should be the tenant-b owner")
	}
}

func TestReclaimScenarioIsDeterministic(t *testing.T) {
	var a, b bytes.Buffer
	if err := WriteTrace(&a, ReclaimScenario(true, 600)); err != nil {
		t.Fatal(err)
	}
	if err := WriteTrace(&b, ReclaimScenario(true, 600)); err != nil {
		t.Fatal(err)
	}
	if exputil.Checksum(a.Bytes()) != exputil.Checksum(b.Bytes()) {
		t.Fatalf("same scenario must produce the same immutable trace checksum")
	}
}

func TestFIFOHeadOfLine(t *testing.T) {
	rows := FIFOHeadOfLineScenario(600, 120)
	if len(rows) != 5 {
		t.Fatalf("FIFO scenario should have 5 rows, got %d", len(rows))
	}
	if rows[1].Name != "head2" || rows[1].GPUCount != 2 {
		t.Fatalf("row 1 should be the 2-GPU head job")
	}
	// The head job must arrive before the small jobs, so it truly sits at the head of the line.
	for i := 2; i < len(rows); i++ {
		if rows[i].GPUCount != 1 {
			t.Fatalf("small job %d should request 1 GPU", i)
		}
		if rows[i].OffsetMs <= rows[1].OffsetMs {
			t.Fatalf("small job %d must arrive after the head job", i)
		}
	}
}

func TestGeneratedScenariosPassValidation(t *testing.T) {
	// The handcrafted generators must satisfy the same rules a hand-edited trace is held to, so the study's
	// own inputs cannot silently drift out of the mechanism they are meant to exercise.
	if err := ValidateTrace(StudyReclaim, ReclaimScenario(true, 600)); err != nil {
		t.Fatalf("reclaim scenario should validate: %v", err)
	}
	if err := ValidateTrace(StudyFIFO, FIFOHeadOfLineScenario(600, 120)); err != nil {
		t.Fatalf("fifo scenario should validate: %v", err)
	}
}

func TestValidateTraceStudyRules(t *testing.T) {
	// A reclaim trace is a two-tenant borrowing story; a FIFO trace is single-tenant. Crossing the studies
	// would exercise a different mechanism than the one under test.
	reclaim := ReclaimScenario(true, 600)
	if err := ValidateTrace(StudyFIFO, reclaim); err == nil {
		t.Fatalf("a two-tenant trace must fail the single-tenant FIFO study")
	}
	// A reclaim row asking for 2 GPUs exceeds the per-tenant nominal quota of 1 and would test capacity, not
	// reclaim.
	twoGPU := ReclaimScenario(true, 600)
	twoGPU[1].GPUCount = 2
	if err := ValidateTrace(StudyReclaim, twoGPU); err == nil {
		t.Fatalf("a 2-GPU reclaim row must be rejected")
	}
}

func TestReadTraceRejectsMalformedRows(t *testing.T) {
	cases := map[string]string{
		"duplicate name":  jsonRow(0, "x", 0, 1, 60) + jsonRow(1, "x", 10, 1, 60),
		"non-contiguous":  jsonRow(0, "x", 0, 1, 60) + jsonRow(2, "y", 10, 1, 60),
		"zero gpu":        jsonRow(0, "x", 0, 0, 60),
		"negative offset": jsonRow(0, "x", -5, 1, 60),
		"zero duration":   jsonRow(0, "x", 0, 1, 0),
		"bad name":        jsonRow(0, "X_bad", 0, 1, 60),
	}
	for name, body := range cases {
		if _, err := ReadTrace(bytes.NewReader([]byte(body))); err == nil {
			t.Fatalf("%s: malformed trace must be rejected", name)
		}
	}
}

func TestReadTraceRejectsReorderedOffsets(t *testing.T) {
	good := ReclaimScenario(false, 600)
	var buf bytes.Buffer
	if err := WriteTrace(&buf, good); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadTrace(bytes.NewReader(buf.Bytes())); err != nil {
		t.Fatalf("valid trace should read: %v", err)
	}

	bad := []byte(jsonRow(0, "x", 100, 1, 60) + jsonRow(1, "y", 50, 1, 60))
	if _, err := ReadTrace(bytes.NewReader(bad)); err == nil {
		t.Fatalf("a trace with decreasing offsets must be rejected")
	}
}
