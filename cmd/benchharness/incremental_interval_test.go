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
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// These exercise the M5-b incremental interval through the REAL report command, which is the gap the
// paired-block work left open.
//
// internal/bench pins the estimator's value; nothing pinned the path from --raw files to the interval the
// gate reads. The consumer takes the blocks from armEvidence, and a mis-wiring there would leave every
// estimator test green: the arrays would still be paired correctly inside the function and the function
// would still compute the right thing on them.

// captureBoth runs fn with BOTH standard streams redirected and returns them concatenated.
//
// The first draft of these tests collected only stdout and the report file, and reported that the censoring
// refusal "is not mentioned anywhere in the output" while the refusal was on stderr the whole time. The
// warning path in incrementalCI uses fmt.Fprintf(os.Stderr, ...), so a test that asserts on a refusal and
// reads only stdout is asserting on a stream the message never travels.
func captureBoth(t *testing.T, fn func() error) (string, error) {
	t.Helper()
	ro, wo, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	re, we, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	done := make(chan string, 2)
	drain := func(r *os.File) {
		var sb strings.Builder
		_, _ = io.Copy(&sb, r)
		done <- sb.String()
	}
	go drain(ro)
	go drain(re)
	origOut, origErr := os.Stdout, os.Stderr
	os.Stdout, os.Stderr = wo, we
	runErr := fn()
	os.Stdout, os.Stderr = origOut, origErr
	_ = wo.Close()
	_ = we.Close()
	a, b := <-done, <-done
	_ = ro.Close()
	_ = re.Close()
	return a + b, runErr
}

// writeM5BRepetition writes one M5-b repetition: premium rows at a given tail, an optional number that
// timed out, and one contender row so the admission-match accounting has a denominator.
//
// timedOut is what makes a repetition censored (`internal/bench/report.go` sets Censored at >= 1% of
// premium requests not completing), and it is a per-file argument because the whole point of the
// 2026-10-01 amendment's refusal is that ONE repetition can be censored while the pool is not.
func writeM5BRepetition(t *testing.T, dir, arm string, rep, completed int, ttftMs float64, timedOut int) string {
	t.Helper()
	path := filepath.Join(dir, fmt.Sprintf("raw-%s-%d.jsonl", arm, rep))
	f, err := os.Create(path)
	if err != nil {
		t.Fatalf("create %s: %v", path, err)
	}
	defer func() { _ = f.Close() }()

	enc := json.NewEncoder(f)
	write := func(r bench.RawRow) {
		if err := enc.Encode(r); err != nil {
			t.Fatalf("encode: %v", err)
		}
	}
	// Each repetition gets its own send epoch so two of them are never read as one replay.
	base := int64(1_000_000_000) + int64(rep)*1_000_000_000_000
	for i := range completed {
		send := base + int64(i)*2_000_000
		first := send + int64(ttftMs*1e6)
		write(bench.RawRow{
			Index: i, Arm: arm, Tenant: "premium", HTTPStatus: 200,
			SendUnixNanos: send, FirstTokenUnixNanos: first, EndUnixNanos: first + 20_000_000,
			EstInputTokens: 10, MatchTolerance: 0.05,
			TraceChecksum: "0000000000000000000000000000000000000000000000000000000000000000",
		})
	}
	for i := range timedOut {
		send := base + int64(completed+i)*2_000_000
		write(bench.RawRow{
			Index: completed + i, Arm: arm, Tenant: "premium", HTTPStatus: 0, ErrorKind: "timeout",
			SendUnixNanos: send, EstInputTokens: 10, MatchTolerance: 0.05,
			TraceChecksum: "0000000000000000000000000000000000000000000000000000000000000000",
		})
	}
	// One contender row above the eligible threshold, identical across arms, so the admission-match check
	// is not what decides these runs.
	write(bench.RawRow{
		Index: completed + timedOut, Arm: arm, Tenant: "contender", IsNoisy: true, HTTPStatus: 200,
		SendUnixNanos: 1, FirstTokenUnixNanos: 2, EndUnixNanos: 3,
		EstInputTokens: 4096 + 250, ExactInputTokens: 4096 + 250, LongThreshold: 4096,
		MatchTolerance: 0.05,
		TraceChecksum:  "0000000000000000000000000000000000000000000000000000000000000000",
	})
	return path
}

// m5bArgs builds the four-arm --raw list the M5-b study admits, with per-arm tails and censoring.
//
// Each repetition's tail is the arm's base tail plus a PER-REPETITION offset, so the four blocks of an arm
// are distinguishable. With one tail per arm -- the first draft -- every block of an arm was identical, and
// a mutation that reversed one arm's blocks at the consumption step changed no number: the test could not
// see a mis-pairing it was written to catch. Distinct blocks are what make the pairing observable at all.
func m5bArgs(t *testing.T, dir string, reps int, tails map[string]float64, censorFirst map[string]int) []string {
	t.Helper()
	var paths []string
	for _, arm := range []string{"R1", "off", "static-cap", "kv-aware"} {
		for rep := 1; rep <= reps; rep++ {
			out := 0
			if n, ok := censorFirst[arm]; ok && rep == 1 {
				out = n
			}
			// The two arms rise at DIFFERENT rates, so the per-repetition C/B ratios are four distinct
			// values rather than one repeated.
			//
			// The first draft scaled every arm by the same factor. That made each repetition's ratio exactly
			// 0.550, and a constant ratio collapses BOTH estimators onto [0.550, 0.550] -- so a mutation
			// swapping the paired-block bootstrap for the mean-of-ratios one changed no number and the test
			// stayed green. Distinguishable blocks were not enough; the blocks' RATIOS have to differ, which
			// is the quantity the two estimators disagree about.
			// 0.15 and 0.30 are chosen, not guessed: the four C/B ratios come out 0.550, 0.622, 0.677 and
			// 0.721 -- all distinct, all under the 0.90 threshold, and their coefficient of variation is
			// 0.115, inside MaxRatioScatter (0.15).
			//
			// The previous draft used 0.6 and 0.15, which spread the ratios from 0.550 to 0.285 and tripped
			// the scatter refusal: the control run came back INVALID, and every mutation then "failed" the
			// same test for a reason that had nothing to do with the mutation. Widening the ratios enough to
			// distinguish the two estimators and keeping them inside the scatter bound is one constraint, not
			// two independent ones.
			growth := 0.15
			if arm == "kv-aware" {
				growth = 0.30
			}
			tail := tails[arm] * (1 + growth*float64(rep-1))
			paths = append(paths, writeM5BRepetition(t, dir, arm, rep, 102-out, tail, out))
		}
	}
	args := []string{"-out", filepath.Join(dir, "report.txt")}
	for _, p := range paths {
		args = append(args, "-raw", p)
	}
	return args
}

// TestTheIncrementalIntervalReachesTheGateThroughTheRealCommand is the control for the two below.
//
// Four repetitions per arm, no censoring, kv-aware's tail well under static-cap's: the interval must be
// computed and the incremental check must pass. Without this control a refusal test proves nothing, because
// a report that refuses everything would satisfy it.
func TestTheIncrementalIntervalReachesTheGateThroughTheRealCommand(t *testing.T) {
	dir := t.TempDir()
	args := m5bArgs(t, dir, 4, map[string]float64{
		"R1": 100, "off": 400, "static-cap": 200, "kv-aware": 110,
	}, nil)

	out, err := captureBoth(t, func() error { return report(args) })
	if err != nil {
		t.Fatalf("a healthy four-repetition M5-b run was refused: %v\n%s", err, out)
	}
	body, rerr := os.ReadFile(filepath.Join(dir, "report.txt"))
	if rerr != nil {
		t.Fatalf("read report: %v", rerr)
	}
	text := string(body)
	if !strings.Contains(text, "incremental value") {
		t.Fatalf("the report carries no incremental-value line:\n%s", text)
	}
	// The interval has to be PRESENT and the check has to PASS. "CI[" absent would mean the gate was
	// satisfied by a missing interval, which is the vacuous pass CI.Valid exists to stop.
	if !strings.Contains(text, "CI[") {
		t.Errorf("the incremental line carries no interval, so the gate read an absent one:\n%s", text)
	}
	for _, line := range strings.Split(text, "\n") {
		if strings.Contains(line, "incremental value") {
			if !strings.Contains(line, "PASS") {
				t.Errorf("kv-aware at 110 ms against static-cap at 200 ms did not pass the incremental"+
					" check: %s", line)
			}
		}
	}

	// The interval's VALUE, recomputed here from the same blocks and compared with what the report printed.
	//
	// Asserting only that an interval is present and the check passed cannot tell the amendment's estimator
	// from the one it replaced: a mutation putting BootstrapCI (the mean of per-repetition ratios) back left
	// every test green. The number is what distinguishes them, so the number is what is asserted.
	lo, hi := parseIntervalFromReport(t, text)
	wantLo, wantHi := expectedBlockInterval(t, dir, 4)
	if math.Abs(lo-wantLo) > 1e-6 || math.Abs(hi-wantHi) > 1e-6 {
		t.Errorf("the report's incremental interval is [%.6f, %.6f] but the paired-block estimator on the"+
			" same blocks gives [%.6f, %.6f]; the gate is reading a different statistic",
			lo, hi, wantLo, wantHi)
	}
}

// parseIntervalFromReport pulls the two bounds out of the `CI[lo, hi]` the report prints.
func parseIntervalFromReport(t *testing.T, text string) (lo, hi float64) {
	t.Helper()
	for _, line := range strings.Split(text, "\n") {
		if !strings.Contains(line, "incremental value") {
			continue
		}
		i := strings.Index(line, "CI[")
		if i < 0 {
			t.Fatalf("the incremental line carries no interval: %s", line)
		}
		rest := line[i+3:]
		j := strings.Index(rest, "]")
		if j < 0 {
			t.Fatalf("the interval is unterminated: %s", line)
		}
		parts := strings.Split(rest[:j], ",")
		if len(parts) != 2 {
			t.Fatalf("the interval does not carry two bounds: %s", line)
		}
		var err error
		if lo, err = strconv.ParseFloat(strings.TrimSpace(parts[0]), 64); err != nil {
			t.Fatalf("parse lo from %q: %v", line, err)
		}
		if hi, err = strconv.ParseFloat(strings.TrimSpace(parts[1]), 64); err != nil {
			t.Fatalf("parse hi from %q: %v", line, err)
		}
		return lo, hi
	}
	t.Fatalf("no incremental-value line in:\n%s", text)
	return 0, 0
}

// expectedBlockInterval recomputes the amendment's interval from the files on disk, joining the blocks by
// the repetition identity in their names exactly as the loader does.
func expectedBlockInterval(t *testing.T, dir string, reps int) (lo, hi float64) {
	t.Helper()
	read := func(arm string, rep int) []bench.RawRow {
		f, err := os.Open(filepath.Join(dir, fmt.Sprintf("raw-%s-%d.jsonl", arm, rep)))
		if err != nil {
			t.Fatalf("open block: %v", err)
		}
		defer func() { _ = f.Close() }()
		rows, err := bench.ReadRawRows(f)
		if err != nil {
			t.Fatalf("read block: %v", err)
		}
		return rows
	}
	var base, cont [][]bench.RawRow
	for rep := 1; rep <= reps; rep++ {
		base = append(base, read("static-cap", rep))
		cont = append(cont, read("kv-aware", rep))
	}
	ci := bench.PairedBlockRatioCI("static-cap", base, cont,
		bench.M5BIncrementalResamples, bench.M5BIncrementalSeed, 0.05)
	if !ci.Valid {
		t.Fatalf("the expected interval could not be computed: %s", ci.InvalidReason)
	}
	// The report prints three decimals, so compare at that resolution.
	return math.Round(ci.Lo*1000) / 1000, math.Round(ci.Hi*1000) / 1000
}

// TestOneCensoredRepetitionRefusesTheIntervalThroughTheRealCommand is the amendment's new refusal, driven
// end to end.
//
// This is the counter-example an external review enumerated: four repetitions of 102 premium requests, and
// kv-aware's FIRST repetition completes 100 with 2 timing out. Pooled that is 2 of 408, i.e. 0.49% -- under
// the 1% boundary, so ArmSummary.Censored stays false and the old gate accepted the run. Within the block
// it is 2 of 102, i.e. 1.96%, so a resample drawing that block reports a lower bound as a p99.
//
// The amendment refuses the interval when ANY original B or C repetition is censored, and the gate fails a
// run whose interval is absent rather than passing it.
func TestOneCensoredRepetitionRefusesTheIntervalThroughTheRealCommand(t *testing.T) {
	dir := t.TempDir()
	args := m5bArgs(t, dir, 4, map[string]float64{
		"R1": 100, "off": 400, "static-cap": 200, "kv-aware": 110,
	}, map[string]int{"kv-aware": 2})

	out, err := captureBoth(t, func() error { return report(args) })
	body, _ := os.ReadFile(filepath.Join(dir, "report.txt"))
	text := string(body) + out
	if err == nil && !strings.Contains(text, "censored") {
		t.Fatalf("a run with one censored repetition in kv-aware was accepted with no mention of censoring:\n%s", text)
	}
	if !strings.Contains(text, "repetition 1 is censored") {
		t.Errorf("the refusal does not name the censored repetition by its recorded identity, so an operator"+
			" cannot find the file:\n%s", text)
	}
	// And the pooled rate is genuinely under the boundary, which is what makes this a gap rather than a
	// duplicate of the existing pooled check. 2 of 409 rows is 0.49%.
	if strings.Contains(text, "arm kv-aware tail is censored") {
		t.Errorf("the POOLED censoring check fired, so this input does not exercise the per-repetition gap"+
			" the amendment closes:\n%s", text)
	}
}

// TestAMissingIntervalFailsTheGateRatherThanSatisfyingIt keeps the direction of the refusal correct.
//
// `IncrementalValuePass` reads `CI.Hi < 1.0`, and a zero CI has Hi == 0, which satisfies it. The run above
// must therefore come out INVALID, not "passed". This is the shape that once let a truncated run disarm
// the strictest check in the design.
func TestAMissingIntervalFailsTheGateRatherThanSatisfyingIt(t *testing.T) {
	dir := t.TempDir()
	args := m5bArgs(t, dir, 4, map[string]float64{
		"R1": 100, "off": 400, "static-cap": 200, "kv-aware": 110,
	}, map[string]int{"static-cap": 2})

	out, err := captureBoth(t, func() error { return report(args) })
	body, _ := os.ReadFile(filepath.Join(dir, "report.txt"))
	text := string(body) + out
	if err == nil && strings.Contains(text, "incremental value") && strings.Contains(text, "PASS") {
		for _, line := range strings.Split(text, "\n") {
			if strings.Contains(line, "incremental value") && strings.Contains(line, "PASS") {
				t.Errorf("a run whose interval was refused still passed the incremental check: %s", line)
			}
		}
	}
	if !strings.Contains(text, "censored") {
		t.Errorf("the censored static-cap repetition is not mentioned anywhere in the output:\n%s", text)
	}
}
