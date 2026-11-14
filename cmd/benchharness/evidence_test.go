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
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

func pilotReplayArgs(m, target, raw string) []string {
	return []string{"-manifest", m, "-target", target, "-api-keys", "premium-1=k,standard-noisy=k",
		"-raw-out", raw, "-request-id-prefix", "ev-" + filepath.Base(raw)}
}

// A replay never truncates evidence that already exists, and a run that is refused for it sends nothing.
// Audit finding 18: the raw file was opened with os.Create after the replay, so a rerun to the same path destroyed the paid original.
// Mutation that turns it red: reserve the raw file without O_EXCL, or let finalize replace an existing file.
func TestReplayRefusesToOverwriteEvidence(t *testing.T) {
	var probes atomic.Int64
	engine := stubEngine(t, &probes, nil)
	defer engine.Close()
	dir := t.TempDir()
	m := pilotManifest(t, dir, "off", engine.URL)
	raw := filepath.Join(dir, "raw-off.jsonl")
	if err := replay(pilotReplayArgs(m, engine.URL, raw)); err != nil {
		t.Fatalf("first replay: %v", err)
	}
	before, err := os.ReadFile(raw)
	if err != nil {
		t.Fatal(err)
	}
	sent := probes.Load()
	err = replay(pilotReplayArgs(m, engine.URL, raw))
	if err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("a second replay to the same path was not refused: %v", err)
	}
	if probes.Load() != sent {
		t.Fatalf("the refused replay still sent %d request(s)", probes.Load()-sent)
	}
	after, err := os.ReadFile(raw)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatalf("the original evidence changed (%v)", err)
	}
}

// Storage is verified before the first request, so a bad destination costs nothing.
// Audit finding 18: an unwritable destination was discovered by os.Create after the whole replay had been paid for.
// Mutation that turns it red: move reserveEvidence after bench.Replay.
func TestReplayVerifiesStorageBeforeDispatch(t *testing.T) {
	var probes atomic.Int64
	engine := stubEngine(t, &probes, nil)
	defer engine.Close()
	dir := t.TempDir()
	// The default study records no replay timing, so no sender configuration is written beside the raw file and the raw file is the first thing the destination must hold.
	m := filepath.Join(dir, "manifest.yaml")
	if err := genTrace([]string{"--seed", "11", "--duration-ms", "2000", "--rate", "5",
		"--premium-weight", "1", "--noisy-weight", "0.4", "--probe-weight", "0",
		"--premium-prompt-chars", "200", "--noisy-prompt-chars", "400", "--gateway-url", engine.URL,
		"--trace-out", filepath.Join(dir, "trace.jsonl"), "--manifest-out", m}); err != nil {
		t.Fatalf("gen-trace: %v", err)
	}
	err := replay([]string{"-manifest", m, "-target", engine.URL, "-api-keys", "premium-1=k,standard-noisy=k",
		"-raw-out", filepath.Join(dir, "missing-dir", "raw-off.jsonl")})
	if err == nil {
		t.Fatal("a replay into a directory that does not exist succeeded")
	}
	if probes.Load() != 0 {
		t.Fatalf("%d request(s) were sent before the destination was found unusable", probes.Load())
	}
}

// A finished replay leaves a completion record that reconciles the recording against the trace and pins the raw bytes.
// Mutation that turns it red: write the status before the raw file is finalized, or record a status other than complete for a clean run.
func TestReplayWritesACompletionRecord(t *testing.T) {
	var probes atomic.Int64
	engine := stubEngine(t, &probes, nil)
	defer engine.Close()
	dir := t.TempDir()
	m := pilotManifest(t, dir, "off", engine.URL)
	raw := filepath.Join(dir, "raw-off.jsonl")
	if err := replay(pilotReplayArgs(m, engine.URL, raw)); err != nil {
		t.Fatal(err)
	}
	st := readStatus(t, raw)
	trace, err := readTraceFile(filepath.Join(dir, "trace-off.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(raw)
	if err != nil {
		t.Fatal(err)
	}
	if st.Status != statusComplete || st.Scheduled != len(trace) || st.Recorded != len(trace) || st.RawSHA256 != bench.Checksum(b) {
		t.Fatalf("completion record %+v does not describe the %d-request trace and its raw file", st, len(trace))
	}
	if _, err := os.Stat(raw + partialSuffix); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the partial file outlived finalization: %v", err)
	}
}

func readStatus(t *testing.T, raw string) completionStatus {
	t.Helper()
	b, err := os.ReadFile(raw + statusSuffix)
	if err != nil {
		t.Fatalf("no completion record: %v", err)
	}
	var st completionStatus
	if err := json.Unmarshal(b, &st); err != nil {
		t.Fatal(err)
	}
	return st
}

// A recording that misses a request, or lost a live row, is recorded incomplete, and the replay reports failure.
// Audit findings 4 and 18: live-file errors were a warning, and nothing compared the rows to the trace.
// Mutation that turns it red: ignore the live failure count or the reconciliation error in completionFor.
func TestCompletionForMarksAnIncompleteRecording(t *testing.T) {
	trace := []bench.TraceRow{{Index: 0}, {Index: 1}}
	rows := []bench.RawRow{{Index: 0, Disposition: bench.DispositionCompleted}, {Index: 1, Disposition: bench.DispositionCompleted}}
	if st := completionFor(trace, rows, 0, nil); st.Status != statusComplete {
		t.Fatalf("a complete recording was marked %q: %v", st.Status, st.Reasons)
	}
	if st := completionFor(trace, rows[:1], 0, nil); st.Status != statusIncomplete || len(st.Reasons) == 0 {
		t.Fatalf("a recording missing a request was marked %+v", st)
	}
	if st := completionFor(trace, rows, 2, errors.New("disk full")); st.Status != statusIncomplete || !strings.Contains(strings.Join(st.Reasons, ";"), "disk full") {
		t.Fatalf("a recording that lost live rows was marked %+v", st)
	}
}

// The report refuses current evidence that has no completion record, an incomplete one, or one whose raw bytes changed.
// Audit finding 4: reporting read raw files alone, so a recording missing half its requests in every arm passed.
// Historical files carry no disposition and are read without a record, so a published study re-scores as it did.
// Mutation that turns it red: skip requireCompletionRecord in loadArmEvidence.
func TestReportRefusesCurrentEvidenceWithoutACompleteRecord(t *testing.T) {
	var probes atomic.Int64
	engine := stubEngine(t, &probes, nil)
	defer engine.Close()
	dir := t.TempDir()
	m := pilotManifest(t, dir, "off", engine.URL)
	// The report pairs repetitions by the number in the file name, so every copy below is its own repetition.
	raw := filepath.Join(dir, "raw-off-1.jsonl")
	if err := replay(pilotReplayArgs(m, engine.URL, raw)); err != nil {
		t.Fatal(err)
	}
	if _, err := loadArmEvidence([]string{raw}); err != nil {
		t.Fatalf("complete evidence was refused: %v", err)
	}

	b, err := os.ReadFile(raw)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.SplitAfter(string(b), "\n")
	truncated := filepath.Join(dir, "raw-off-2.jsonl")
	if err := os.WriteFile(truncated, []byte(strings.Join(lines[:len(lines)/2], "")), 0o644); err != nil {
		t.Fatal(err)
	}
	st, err := os.ReadFile(raw + statusSuffix)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(truncated+statusSuffix, st, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := loadArmEvidence([]string{truncated}); err == nil {
		t.Fatal("a raw file cut in half under its original completion record was read")
	}

	noRecord := filepath.Join(dir, "raw-off-3.jsonl")
	if err := os.WriteFile(noRecord, b, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := loadArmEvidence([]string{noRecord}); err == nil {
		t.Fatal("current evidence with no completion record was read")
	}

	var incomplete completionStatus
	if err := json.Unmarshal(st, &incomplete); err != nil {
		t.Fatal(err)
	}
	incomplete.Status, incomplete.Reasons = statusIncomplete, []string{"lost"}
	ib, _ := json.Marshal(incomplete)
	inc := filepath.Join(dir, "raw-off-4.jsonl")
	if err := os.WriteFile(inc, b, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(inc+statusSuffix, ib, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := loadArmEvidence([]string{inc}); err == nil {
		t.Fatal("evidence recorded as incomplete was read")
	}
}
