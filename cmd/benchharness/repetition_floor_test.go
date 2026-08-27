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

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// writeRepetition writes one repetition file: n completed premium rows with increasing TTFT, plus enough
// contender rows to give the arm an admitted-work fraction the match check will accept.
func writeRepetition(t *testing.T, dir, name, arm string, n int, ttftBaseMs int64, admitted int) string {
	t.Helper()
	path := filepath.Join(dir, name)
	f, err := os.Create(path)
	if err != nil {
		t.Fatalf("create %s: %v", path, err)
	}
	defer func() { _ = f.Close() }()

	enc := json.NewEncoder(f)
	for i := range n {
		ttft := (ttftBaseMs + int64(i)) * 1e6
		row := bench.RawRow{
			Index: i, Arm: arm, Tenant: "premium", HTTPStatus: 200,
			SendUnixNanos: 1, FirstTokenUnixNanos: 1 + ttft, EndUnixNanos: 1 + ttft + 1e6,
			EstInputTokens: 10, MatchTolerance: 0.05, TraceChecksum: "0000000000000000000000000000000000000000000000000000000000000000",
		}
		if err := enc.Encode(row); err != nil {
			t.Fatalf("encode: %v", err)
		}
	}
	// One contender row carrying the offered/admitted work, so admittedWorkFraction is well defined and
	// identical across arms — the admission-match check must not be what refuses these runs.
	c := bench.RawRow{
		Index: n, Arm: arm, Tenant: "contender", IsNoisy: true, HTTPStatus: 200,
		SendUnixNanos: 1, FirstTokenUnixNanos: 2, EndUnixNanos: 3,
		EstInputTokens: admitted, MatchTolerance: 0.05, TraceChecksum: "0000000000000000000000000000000000000000000000000000000000000000",
	}
	if err := enc.Encode(c); err != nil {
		t.Fatalf("encode contender: %v", err)
	}
	return path
}

// TestReportRefusesATruncatedRepetitionThroughTheRealCommand covers the wiring, not the rule.
//
// internal/bench has specs for the rule itself, and they pass on a hand-built ArmSummary with the repetition
// fields already set. What they cannot see is whether the command FILLS those fields: Summarize is handed
// pooled rows and cannot know how they were split, so `report` attaches the repetition shape itself. Deleting
// that attachment leaves every unit spec green -- which is the same defect class as a Terraform variable no
// caller ever passed, and it is why this test drives the actual command over actual files.
func TestReportRefusesATruncatedRepetitionThroughTheRealCommand(t *testing.T) {
	dir := t.TempDir()

	// R1 and static-cap are healthy. kv-aware is split into two repetitions, the second cut short at 30
	// premium completions -- the shape a node going away mid-run produces. Pooled, kv-aware still reports
	// 530 completions, comfortably above MinTailSamples, which is exactly how the truncation used to hide.
	// Every arm gets TWO repetitions so the counts match and the incremental CI is computed. Otherwise the
	// unequal-repetition refusal fires first and this test would pass without the floor existing at all.
	raw := []string{
		writeRepetition(t, dir, "r1a.jsonl", "R1", 500, 100, 250),
		writeRepetition(t, dir, "r1b.jsonl", "R1", 500, 100, 250),
		writeRepetition(t, dir, "ba.jsonl", "static-cap", 500, 200, 250),
		writeRepetition(t, dir, "bb.jsonl", "static-cap", 500, 200, 250),
		writeRepetition(t, dir, "c1.jsonl", "kv-aware", 500, 110, 255),
		writeRepetition(t, dir, "c2.jsonl", "kv-aware", 30, 110, 255),
	}

	outPath := filepath.Join(dir, "report.txt")
	args := []string{"-out", outPath}
	for _, p := range raw {
		args = append(args, "-raw", p)
	}
	if err := report(args); err != nil {
		t.Fatalf("report: %v", err)
	}

	b, err := os.ReadFile(outPath)
	if err != nil {
		t.Fatalf("read report: %v", err)
	}
	got := string(b)

	if !strings.Contains(got, "run invalid") {
		t.Errorf("a run with a 30-completion repetition was not refused; report said:\n%s", got)
	}
	if !strings.Contains(got, "30 premium completions") {
		t.Errorf("the refusal did not name the truncated repetition's size; report said:\n%s", got)
	}
	if strings.Contains(got, "all checks passed") {
		t.Errorf("the report certified a truncated run:\n%s", got)
	}
}

// TestReportAcceptsEqualHealthyRepetitions is the control.
//
// Without it the test above proves only that something refuses, not that the FLOOR is what refuses -- a
// report that refused every input would pass it.
func TestReportAcceptsEqualHealthyRepetitions(t *testing.T) {
	dir := t.TempDir()
	raw := []string{
		writeRepetition(t, dir, "r1a.jsonl", "R1", 500, 100, 250),
		writeRepetition(t, dir, "r1b.jsonl", "R1", 500, 100, 250),
		writeRepetition(t, dir, "ba.jsonl", "static-cap", 500, 200, 250),
		writeRepetition(t, dir, "bb.jsonl", "static-cap", 500, 200, 250),
		writeRepetition(t, dir, "c1.jsonl", "kv-aware", 500, 110, 255),
		writeRepetition(t, dir, "c2.jsonl", "kv-aware", 500, 110, 255),
	}
	outPath := filepath.Join(dir, "report.txt")
	args := []string{"-out", outPath}
	for _, p := range raw {
		args = append(args, "-raw", p)
	}
	if err := report(args); err != nil {
		t.Fatalf("report: %v", err)
	}
	b, err := os.ReadFile(outPath)
	if err != nil {
		t.Fatalf("read report: %v", err)
	}
	if strings.Contains(string(b), "premium completions, below") {
		t.Errorf("healthy equal repetitions were refused by the floor:\n%s", string(b))
	}
}
