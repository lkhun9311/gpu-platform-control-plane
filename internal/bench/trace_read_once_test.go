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

package bench

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// The replayed rows must be parsed from the very bytes whose checksum was verified.
// Audit finding 26: the manifest hashed the trace, closed it, and the replay opened it again, so a trace replaced in between was sent under the old checksum.
// The test replaces the file after the checksum was frozen, which is the interleaving the two-open path could not see.
// Mutation that turns it red: skip the checksum comparison in ReadTraceFileVerified.
func TestReadTraceFileVerifiedParsesOnlyTheHashedBytes(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "trace.jsonl")
	write := func(rows []TraceRow) []byte {
		var buf bytes.Buffer
		if err := WriteTrace(&buf, rows); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, buf.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
		return buf.Bytes()
	}
	frozen := write(evenTrace(3, 10))
	want := Checksum(frozen)

	rows, err := ReadTraceFileVerified(path, want)
	if err != nil || len(rows) != 3 {
		t.Fatalf("the frozen trace did not read: %d rows, %v", len(rows), err)
	}

	write(evenTrace(5, 10))
	if rows, err := ReadTraceFileVerified(path, want); err == nil {
		t.Fatalf("a trace replaced after its checksum was frozen was read as %d rows", len(rows))
	}
}
