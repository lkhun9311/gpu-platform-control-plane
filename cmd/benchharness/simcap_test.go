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

// writeSimTrace writes a trace of eligible standard rows, optionally carrying exact token counts.
//
// Every row is above the 4096-token eligibility threshold, because a row below it is outside the population
// the bucket gates and would make these cases about eligibility rather than about the unit.
func writeSimTrace(t *testing.T, dir string, n int, withExact bool) string {
	t.Helper()
	path := filepath.Join(dir, "trace.jsonl")
	f, err := os.Create(path)
	if err != nil {
		t.Fatalf("create trace: %v", err)
	}
	defer func() { _ = f.Close() }()
	enc := json.NewEncoder(f)
	for i := range n {
		row := bench.TraceRow{
			Index: i, OffsetMs: int64(i) * 1000, Tenant: "standard-noisy",
			PromptLenChars: 40_000, MaxOutputTokens: 8, IsNoisy: true,
		}
		if withExact {
			// The project's own calibration: 40,000 characters estimate at 10,000 and measure at 7,695.
			row.ExactInputTokens = 7695
		}
		if err := enc.Encode(row); err != nil {
			t.Fatalf("encode row: %v", err)
		}
	}
	return path
}

// A -target check is a claim about the REGISTERED criterion, which is defined over exact tokens. A trace that
// carries none cannot answer it, and answering anyway on the estimate is how a bucket gets frozen against a
// number nobody measured.
func TestSimCapRefusesATargetCheckOnATraceWithNoExactTokens(t *testing.T) {
	dir := t.TempDir()
	trace := writeSimTrace(t, dir, 20, false)
	err := simCap([]string{
		"-trace", trace, "-rate", "8000", "-burst", "30000",
		"-target-admitted-fraction", "0.8456", "-tolerance", "0.10",
	})
	if err == nil {
		t.Fatal("a target check was answered on a trace with no measured input-token counts; that is the " +
			"fallback to the estimate the whole exact-token repair exists to end")
	}
	if !strings.Contains(err.Error(), "stamp-exact-tokens") {
		t.Errorf("the refusal does not say how to fix it: %v", err)
	}
	if !strings.Contains(err.Error(), "EXACT") {
		t.Errorf("the refusal does not name the unit it is refusing in: %v", err)
	}
}

// Without -target the command is a diagnostic, and a diagnostic may run on whatever the trace has.
func TestSimCapWithoutATargetIsADiagnosticAndDoesNotRefuse(t *testing.T) {
	dir := t.TempDir()
	trace := writeSimTrace(t, dir, 20, false)
	if err := simCap([]string{"-trace", trace, "-rate", "8000", "-burst", "30000"}); err != nil {
		t.Fatalf("the diagnostic mode refused a trace it was not asked to certify: %v", err)
	}
}

// With complete counts the comparison is answerable, and it is answered in the registered unit.
//
// The rate is deliberately generous so every request is admitted: the point of this case is that a trace
// carrying exact counts reaches the comparison at all, not what the bucket does.
func TestSimCapComparesTheTargetInExactTokensWhenTheTraceCarriesThem(t *testing.T) {
	dir := t.TempDir()
	trace := writeSimTrace(t, dir, 20, true)
	if err := simCap([]string{
		"-trace", trace, "-rate", "1000000", "-burst", "1000000",
		"-target-admitted-fraction", "1.0", "-tolerance", "0.01",
	}); err != nil {
		t.Fatalf("a fully admitted trace with exact counts did not match a target of 1.0: %v", err)
	}
}

// And the comparison must be made on the exact fraction rather than the estimated one.
//
// Mutation that turns this red: score the target against `fraction` instead of `exactFraction`. Both are 1.0
// when everything is admitted, so the case above cannot tell them apart -- this one refuses half the traffic,
// where the two fractions differ because the estimate and the measurement scale differently.
func TestSimCapScoresTheTargetOnTheExactFractionNotTheEstimate(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "mixed.jsonl")
	f, err := os.Create(path)
	if err != nil {
		t.Fatalf("create trace: %v", err)
	}
	enc := json.NewEncoder(f)
	// Two rows arriving together. The first is long, the second short-but-eligible, and their exact counts
	// are deliberately NOT proportional to their estimates: 10,000 est / 7,695 exact against 5,000 / 1,000.
	// A bucket that admits only the first therefore admits 0.667 of the estimated work and 0.885 of the exact.
	rows := []bench.TraceRow{
		{Index: 0, OffsetMs: 0, Tenant: "standard-noisy", PromptLenChars: 40_000, MaxOutputTokens: 8, ExactInputTokens: 7695},
		{Index: 1, OffsetMs: 0, Tenant: "standard-noisy", PromptLenChars: 20_000, MaxOutputTokens: 8, ExactInputTokens: 1000},
	}
	for _, r := range rows {
		if err := enc.Encode(r); err != nil {
			t.Fatalf("encode: %v", err)
		}
	}
	_ = f.Close()

	// A burst that fits the first request and not both, with a refill rate too slow to matter.
	err = simCap([]string{
		"-trace", path, "-rate", "1", "-burst", "10000",
		"-target-admitted-fraction", "0.885", "-tolerance", "0.02",
	})
	if err != nil {
		t.Fatalf("the exact-weighted fraction did not match its target, so the comparison is not being made "+
			"in the registered unit: %v", err)
	}
	// And the estimate-weighted target must now MISS, which is what proves the two are different numbers.
	if err := simCap([]string{
		"-trace", path, "-rate", "1", "-burst", "10000",
		"-target-admitted-fraction", "0.667", "-tolerance", "0.02",
	}); err == nil {
		t.Fatal("a target matching the ESTIMATE-weighted fraction passed; the comparison is still scored on " +
			"the estimate")
	}
}
