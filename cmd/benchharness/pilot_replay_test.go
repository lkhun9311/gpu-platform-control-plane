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

// pilotManifest generates one pilot arm's trace and manifest against target and returns the manifest path.
func pilotManifest(t *testing.T, dir, arm, target string) string {
	t.Helper()
	manifest := filepath.Join(dir, "manifest-"+arm+".yaml")
	if err := genTrace([]string{"--study", bench.StudyProspectivePilot, "--arm", arm, "--seed", "3", "--duration-ms", "2000",
		"--premium-rate", "9.25", "--noisy-rate", "0.5", "--probe-rate", "0",
		"--premium-prompt-chars", "200", "--noisy-prompt-chars", "40000",
		"--premium-output-tokens", "4", "--noisy-output-tokens", "2", "--timeout-ms", "30000",
		"--model", "m", "--gateway-url", target,
		"--trace-out", filepath.Join(dir, "trace-"+arm+".jsonl"), "--manifest-out", manifest}); err != nil {
		t.Fatalf("gen-trace %s: %v", arm, err)
	}
	return manifest
}

// The pilot's replay refuses to run without request IDs, refuses any connection mode but pooled, and writes the
// same pool for every arm, the isolation arm included.
//
// Mutation that turns it red: drop the SenderPoolSize override, or the prefix refusal.
func TestPilotReplayFixesItsSenderAndRecordsIt(t *testing.T) {
	var probes atomic.Int64
	var refuse atomic.Bool
	engine := stubEngine(t, &probes, &refuse)
	defer engine.Close()
	dir := t.TempDir()

	off := pilotManifest(t, dir, "off", engine.URL)
	base := []string{"-manifest", off, "-target", engine.URL, "-api-keys", "premium-1=k,standard-noisy=k"}

	if err := replay(append(base, "-raw-out", filepath.Join(dir, "raw-noid.jsonl"))); err == nil ||
		!strings.Contains(err.Error(), "request-id-prefix") {
		t.Fatalf("a pilot replay without request IDs was not refused: %v", err)
	}
	if err := replay(append(base, "-raw-out", filepath.Join(dir, "raw-legacy.jsonl"), "-request-id-prefix", "x", "-conn-mode", "legacy")); err == nil ||
		!strings.Contains(err.Error(), "pooled") {
		t.Fatalf("a pilot replay with the legacy client was not refused: %v", err)
	}

	pools := map[string]int{}
	for _, arm := range []string{"off", bench.ArmR1} {
		m := pilotManifest(t, dir, arm, engine.URL)
		raw := filepath.Join(dir, "raw-"+arm+".jsonl")
		if err := replay([]string{"-manifest", m, "-target", engine.URL, "-api-keys", "premium-1=k,standard-noisy=k",
			"-raw-out", raw, "-request-id-prefix", "pilot-a-1-" + arm}); err != nil {
			t.Fatalf("replay %s: %v", arm, err)
		}
		b, err := os.ReadFile(raw + ".sender.json")
		if err != nil {
			t.Fatalf("no sender configuration for %s: %v", arm, err)
		}
		var c senderConfig
		if err := json.Unmarshal(b, &c); err != nil {
			t.Fatal(err)
		}
		if c.BinarySHA256 == "" || c.ConnMode != bench.SenderModePooled || !c.DrainForReuse {
			t.Fatalf("%s: incomplete sender configuration %+v", arm, c)
		}
		pools[arm] = c.MaxIdleConnsPerHost
	}
	if pools["off"] != 600 || pools[bench.ArmR1] != 600 {
		t.Fatalf("pools differ from the study's 600: %v", pools)
	}
}

// frozenEngine answers every request with the frozen count for its prompt length, and records the IDs it saw.
func frozenEngine(t *testing.T, counts map[int]int, ids *[]string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Messages []struct {
				Content string `json:"content"`
			} `json:"messages"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		*ids = append(*ids, r.Header.Get("X-Request-Id"))
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\n")                                                           //nolint:errcheck // test stub
		fmt.Fprintf(w, "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":%d}}\n\ndata: [DONE]\n\n", counts[len(body.Messages[0].Content)]) //nolint:errcheck // test stub
	}))
}

// The frozen counts are checked against the engine with calib- IDs, and a disagreement refuses.
//
// Mutation that turns it red: compare against the estimate instead of the frozen count, or drop the calib prefix.
func TestVerifyExactTokensChecksTheFrozenCountsWithCalibrationIDs(t *testing.T) {
	var ids []string
	good := frozenEngine(t, map[int]int{200: 68, 40000: 7695}, &ids)
	defer good.Close()
	if err := verifyExactTokens([]string{"-study", bench.StudyProspectivePilot, "-engine-url", good.URL, "-model", "m"}); err != nil {
		t.Fatalf("an engine that counts the frozen values was refused: %v", err)
	}
	if strings.Join(ids, ",") != "calib-200,calib-40000" {
		t.Fatalf("the probes were not sent as calib-<length>: %v", ids)
	}
	var none []string
	bad := frozenEngine(t, map[int]int{200: 68, 40000: 7700}, &none)
	defer bad.Close()
	err := verifyExactTokens([]string{"-study", bench.StudyProspectivePilot, "-engine-url", bad.URL, "-model", "m"})
	if err == nil || !strings.Contains(err.Error(), "7700") {
		t.Fatalf("an engine counting 7,700 for the contender was not refused: %v", err)
	}
}

// The pilot's traces are stamped from the frozen counts, and the replay refuses a row that disagrees.
func TestPilotTracesCarryTheFrozenCountsAndTheReplayChecksThem(t *testing.T) {
	var probes atomic.Int64
	var refuse atomic.Bool
	engine := stubEngine(t, &probes, &refuse)
	defer engine.Close()
	dir := t.TempDir()
	m := pilotManifest(t, dir, "off", engine.URL)
	rows, err := readTraceFile(filepath.Join(dir, "trace-off.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range rows {
		want := map[int]int{200: 68, 40000: 7695}[r.PromptLenChars]
		if r.ExactInputTokens != want {
			t.Fatalf("row %d of %d chars carries %d exact tokens, want %d", r.Index, r.PromptLenChars, r.ExactInputTokens, want)
		}
	}
	// A build that did not stamp the frozen counts would still have checksummed what it wrote, so the manifest is
	// re-pointed at the edited trace; otherwise the checksum refusal would answer first and this check go untested.
	rows[0].ExactInputTokens++
	trace := filepath.Join(dir, "trace-off.jsonl")
	old, err := bench.ChecksumFile(trace)
	if err != nil {
		t.Fatal(err)
	}
	if err := writeTrace(trace, rows); err != nil {
		t.Fatal(err)
	}
	sum, err := bench.ChecksumFile(trace)
	if err != nil {
		t.Fatal(err)
	}
	mb, err := os.ReadFile(m)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(mb), old) {
		t.Fatal("the manifest does not carry the trace's checksum, so it cannot be re-pointed")
	}
	if err := os.WriteFile(m, []byte(strings.ReplaceAll(string(mb), old, sum)), 0o644); err != nil {
		t.Fatal(err)
	}
	err = replay([]string{"-manifest", m, "-target", engine.URL, "-api-keys", "premium-1=k,standard-noisy=k",
		"-raw-out", filepath.Join(dir, "raw.jsonl"), "-request-id-prefix", "x"})
	if err == nil || !strings.Contains(err.Error(), "froze") {
		t.Fatalf("a row whose count was edited was replayed: %v", err)
	}
}
