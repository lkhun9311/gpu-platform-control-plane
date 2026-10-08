package main

import (
	"encoding/json"
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
		"--premium-prompt-chars", "200", "--noisy-prompt-chars", "400",
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
