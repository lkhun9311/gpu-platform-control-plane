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
	"testing"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/exputil"
)

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
	if late[1].Name != "a2-borrow" || late[1].Tenant != "tenant-a" {
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

func TestReadTraceRejectsReorderedOffsets(t *testing.T) {
	good := ReclaimScenario(false, 600)
	var buf bytes.Buffer
	if err := WriteTrace(&buf, good); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadTrace(bytes.NewReader(buf.Bytes())); err != nil {
		t.Fatalf("valid trace should read: %v", err)
	}

	bad := []byte(`{"index":0,"name":"x","offsetMs":100,"tenant":"tenant-a","gpuCount":1,"durationSec":60}` + "\n" +
		`{"index":1,"name":"y","offsetMs":50,"tenant":"tenant-a","gpuCount":1,"durationSec":60}` + "\n")
	if _, err := ReadTrace(bytes.NewReader(bad)); err == nil {
		t.Fatalf("a trace with decreasing offsets must be rejected")
	}
}
