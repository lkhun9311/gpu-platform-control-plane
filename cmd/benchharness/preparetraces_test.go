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
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// stubEngine answers like a streaming engine, reporting a prompt-token count no estimate would produce.
//
// chars/5 rather than chars/4: a fallback to the gateway's estimate is then visible in the numbers instead of
// merely plausible. probes counts how many times it was asked, which is how "measured once per distinct
// length" is checked rather than assumed.
//
// refuseNoisy is a SWITCH rather than a constructor argument, because stamping and replay need opposite
// answers from the same engine. stamp-exact-tokens measures every length as the premium tenant precisely
// because no admission mode refuses it -- an engine that refuses the long prompt during stamping makes the
// measurement fail, which is what the first version of this test did to itself. The refusal is turned on only
// once the traces are prepared, so the replay produces the refused row the fraction's denominator needs.
func stubEngine(t *testing.T, probes *atomic.Int64, refuseNoisy *atomic.Bool) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Messages []struct {
				Content string `json:"content"`
			} `json:"messages"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("decode request: %v", err)
			return
		}
		chars := 0
		if len(body.Messages) > 0 {
			chars = len(body.Messages[0].Content)
		}
		probes.Add(1)
		// The long tenant is the one an engaged guard refuses, and a refused row is the denominator of the
		// admitted-work fraction: its exact count has to survive even though it never reached an engine.
		if refuseNoisy != nil && refuseNoisy.Load() && chars > 1000 {
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		f, ok := w.(http.Flusher)
		if !ok {
			t.Fatal("the test server does not flush; a streaming response cannot be simulated")
		}
		fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\n") //nolint:errcheck // test stub
		f.Flush()
		fmt.Fprintf(w, "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":%d}}\n\n", chars/5) //nolint:errcheck // test stub
		f.Flush()
		fmt.Fprint(w, "data: [DONE]\n\n") //nolint:errcheck // test stub
		f.Flush()
	}))
}

// writeCanonicalTrace writes a two-tenant trace: premium rows and long contender rows, with lengths repeated.
func writeCanonicalTrace(t *testing.T, dir string) string {
	t.Helper()
	path := filepath.Join(dir, "trace.jsonl")
	rows := []bench.TraceRow{
		{Index: 1, OffsetMs: 0, Tenant: "premium-1", PromptLenChars: 200, MaxOutputTokens: 8},
		{Index: 2, OffsetMs: 10, Tenant: "standard-noisy", PromptLenChars: 40_000, MaxOutputTokens: 8, IsNoisy: true},
		{Index: 3, OffsetMs: 20, Tenant: "premium-1", PromptLenChars: 200, MaxOutputTokens: 8},
		{Index: 4, OffsetMs: 30, Tenant: "standard-noisy", PromptLenChars: 40_000, MaxOutputTokens: 8, IsNoisy: true},
	}
	if err := writeTrace(path, rows); err != nil {
		t.Fatalf("write canonical trace: %v", err)
	}
	return path
}

func prepareArgs(trace, dir, gatewayURL string) []string {
	return []string{
		"-trace", trace, "-out-dir", dir, "-arms", "R1,off,static-cap,kv-aware", "-reps", "2",
		"-gateway-url", gatewayURL, "-model", "m", "-timeout-ms", "60000", "-seed", "7",
		"-match-tolerance", "0.05",
	}
}

// The defect this command exists to close: the stamped trace was never the one replayed.
//
// So the assertion is end to end -- stamp, prepare, then replay through the real replay path -- and what it
// checks is that the rows the REPLAY produced carry the counts, including the row the stub refused.
func TestPreparedTracesCarryTheirCountsIntoTheReplayedRows(t *testing.T) {
	var probes atomic.Int64
	var refuse atomic.Bool
	engine := stubEngine(t, &probes, &refuse)
	defer engine.Close()

	dir := t.TempDir()
	trace := writeCanonicalTrace(t, dir)

	if err := stampExactTokens([]string{
		"-trace", trace, "-gateway-url", engine.URL, "-model", "m", "-tenant", "premium-1",
	}); err != nil {
		t.Fatalf("stamp: %v", err)
	}
	// Two distinct lengths, so exactly two probes: a per-row measurement would be eight.
	if got := probes.Load(); got != 2 {
		t.Errorf("the engine was asked %d times for 2 distinct prompt lengths", got)
	}

	if err := prepareTraces(prepareArgs(trace, dir, engine.URL)); err != nil {
		t.Fatalf("prepare: %v", err)
	}

	// From here the engine behaves like one under an engaged guard.
	refuse.Store(true)

	if err := replay([]string{
		"-manifest", filepath.Join(dir, "manifest-off-1.yaml"),
		"-target", engine.URL, "-require-exact-tokens",
		"-api-keys", "premium-1=k,standard-noisy=k",
		"-raw-out", filepath.Join(dir, "raw.jsonl"),
	}); err != nil {
		t.Fatalf("replay: %v", err)
	}

	raw, err := os.ReadFile(filepath.Join(dir, "raw.jsonl"))
	if err != nil {
		t.Fatalf("read raw: %v", err)
	}
	var refused, counted int
	for line := range strings.SplitSeq(strings.TrimSpace(string(raw)), "\n") {
		if line == "" {
			continue
		}
		var r bench.RawRow
		if err := json.Unmarshal([]byte(line), &r); err != nil {
			t.Fatalf("parse raw row: %v", err)
		}
		if r.ExactInputTokens <= 0 {
			t.Errorf("row %d reached the evidence with no exact input-token count", r.Index)
			continue
		}
		counted++
		if r.HTTPStatus == http.StatusTooManyRequests {
			refused++
			if r.ExactInputTokens != 8000 {
				t.Errorf("the refused row carries %d exact tokens, want 8000", r.ExactInputTokens)
			}
		}
	}
	if counted != 4 {
		t.Errorf("%d of 4 replayed rows carried an exact count", counted)
	}
	if refused == 0 {
		t.Error("no row was refused, so this did not test that a refused row keeps its count")
	}
}

// The contended arms must replay byte-identical traffic, and R1 must be the premium subset of it.
func TestPreparedArmsShareOneChecksumAndR1IsThePremiumSubset(t *testing.T) {
	var probes atomic.Int64
	engine := stubEngine(t, &probes, nil)
	defer engine.Close()

	dir := t.TempDir()
	trace := writeCanonicalTrace(t, dir)
	if err := stampExactTokens([]string{
		"-trace", trace, "-gateway-url", engine.URL, "-model", "m", "-tenant", "premium-1",
	}); err != nil {
		t.Fatalf("stamp: %v", err)
	}
	if err := prepareTraces(prepareArgs(trace, dir, engine.URL)); err != nil {
		t.Fatalf("prepare: %v", err)
	}

	sums := map[string]string{}
	for _, arm := range []string{"off", "static-cap", "kv-aware", "R1"} {
		m, err := bench.LoadManifest(filepath.Join(dir, "manifest-"+arm+"-1.yaml"))
		if err != nil {
			t.Fatalf("load manifest for %s: %v", arm, err)
		}
		sums[arm] = m.TraceChecksum
	}
	if sums["off"] != sums["static-cap"] || sums["off"] != sums["kv-aware"] {
		t.Errorf("the contended arms do not share one trace checksum: %v", sums)
	}
	if sums["R1"] == sums["off"] {
		t.Error("R1 shares the contended checksum, so it is not the filtered subset it is supposed to be")
	}

	r1, err := readTrace(filepath.Join(dir, "trace-R1.jsonl"))
	if err != nil {
		t.Fatalf("read R1 trace: %v", err)
	}
	if len(r1) != 2 {
		t.Fatalf("R1 has %d rows, want the 2 premium rows", len(r1))
	}
	for _, r := range r1 {
		if r.IsNoisy {
			t.Error("R1 carries a contender row")
		}
		if r.ExactInputTokens != 40 {
			t.Errorf("the derived R1 row lost its measured count: got %d, want 40", r.ExactInputTokens)
		}
	}
	// Derivation must preserve the schedule, which is why R1 is filtered rather than regenerated.
	if r1[0].OffsetMs != 0 || r1[1].OffsetMs != 20 {
		t.Errorf("R1's arrival offsets changed: %d and %d", r1[0].OffsetMs, r1[1].OffsetMs)
	}
}

// No manifest may be published for a trace that was never stamped.
func TestPrepareTracesRefusesAnUnstampedTrace(t *testing.T) {
	dir := t.TempDir()
	trace := writeCanonicalTrace(t, dir)
	err := prepareTraces(prepareArgs(trace, dir, "http://127.0.0.1:1"))
	if err == nil {
		t.Fatal("manifests were published for a trace with no measured counts; the replay loop would then " +
			"produce evidence the admission-match criterion cannot be scored from")
	}
	if !strings.Contains(err.Error(), "stamp-exact-tokens") {
		t.Errorf("the refusal does not say how to fix it: %v", err)
	}
	if _, statErr := os.Stat(filepath.Join(dir, "manifest-off-1.yaml")); statErr == nil {
		t.Error("a manifest was written despite the refusal")
	}
}

// Editing a finalised trace must be caught before any request is sent.
func TestReplayRefusesATraceEditedAfterFinalisation(t *testing.T) {
	var probes atomic.Int64
	engine := stubEngine(t, &probes, nil)
	defer engine.Close()

	dir := t.TempDir()
	trace := writeCanonicalTrace(t, dir)
	if err := stampExactTokens([]string{
		"-trace", trace, "-gateway-url", engine.URL, "-model", "m", "-tenant", "premium-1",
	}); err != nil {
		t.Fatalf("stamp: %v", err)
	}
	if err := prepareTraces(prepareArgs(trace, dir, engine.URL)); err != nil {
		t.Fatalf("prepare: %v", err)
	}

	// Append a row to the finalised per-arm trace: the checksum in the manifest no longer describes it.
	rows, err := readTrace(filepath.Join(dir, "trace-off.jsonl"))
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	rows = append(rows, bench.TraceRow{Index: 99, Tenant: "premium-1", PromptLenChars: 200, MaxOutputTokens: 8, ExactInputTokens: 40})
	if err := writeTrace(filepath.Join(dir, "trace-off.jsonl"), rows); err != nil {
		t.Fatalf("rewrite: %v", err)
	}

	before := probes.Load()
	err = replay([]string{
		"-manifest", filepath.Join(dir, "manifest-off-1.yaml"),
		"-target", engine.URL, "-api-keys", "premium-1=k,standard-noisy=k",
		"-raw-out", filepath.Join(dir, "raw.jsonl"),
	})
	if err == nil {
		t.Fatal("a trace edited after finalisation was replayed")
	}
	if !strings.Contains(err.Error(), "checksum") {
		t.Errorf("the refusal does not name the checksum: %v", err)
	}
	if probes.Load() != before {
		t.Error("requests were sent before the refusal; the point is that it costs no traffic")
	}
}
