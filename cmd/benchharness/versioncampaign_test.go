package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// TestVersionBundleThenManifests drives both subcommands as a session would, and every written manifest loads.
func TestVersionBundleThenManifests(t *testing.T) {
	dir := t.TempDir()
	art, _ := json.Marshal(bench.CalibrationArtifact{Resolved: true, StableRateRequestsPerSec: 2.0})
	if err := os.WriteFile(filepath.Join(dir, "calibration.json"), art, 0o600); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	err := versionBundle([]string{"-dir", dir, "-campaign-id", "s1-test", "-price-usd-per-hour", "1.237",
		"-price-source", "aws-pricing-api", "-price-read-at", "2026-11-20T01:00:00Z"}, &out)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "window 300 s, 16 traces") {
		t.Fatalf("bundle output %q", out.String())
	}
	mdir := filepath.Join(dir, "manifests")
	if err := os.Mkdir(mdir, 0o700); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	err = versionManifests([]string{"-bundle", filepath.Join(dir, bench.CampaignBundleFile), "-engine-url", "http://127.0.0.1:8000",
		"-blocks", "1,2", "-out", mdir}, &out)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Count(out.String(), "\n"); got != 12 {
		t.Fatalf("%d manifests written, want 2 blocks x 6 arms = 12", got)
	}
	// A second run never replaces a frozen cell's record.
	if err := versionManifests([]string{"-bundle", filepath.Join(dir, bench.CampaignBundleFile), "-engine-url", "http://127.0.0.1:8000",
		"-blocks", "1", "-out", mdir}, &out); err == nil || !strings.Contains(err.Error(), "exists") {
		t.Fatalf("rewrite: %v, want a refusal", err)
	}
}

// TestVersionManifestsRefusesBadBlocks keeps a typo in the block list from writing anything.
func TestVersionManifestsRefusesBadBlocks(t *testing.T) {
	var out bytes.Buffer
	if err := versionManifests([]string{"-bundle", "x", "-blocks", "", "-out", "y"}, &out); err == nil {
		t.Fatal("missing blocks accepted")
	}
	if err := versionBundle([]string{"-campaign-id", "x"}, &out); err == nil || !strings.Contains(err.Error(), "-dir") {
		t.Fatalf("missing dir: %v", err)
	}
}

// TestVersionManifestsWithARelativeBundlePath: LoadManifest resolves a relative trace path against the manifest's directory, so the writer must not record one relative to the working directory.
func TestVersionManifestsWithARelativeBundlePath(t *testing.T) {
	root := t.TempDir()
	t.Chdir(root)
	if err := os.MkdirAll(filepath.Join("campaign"), 0o700); err != nil {
		t.Fatal(err)
	}
	art, _ := json.Marshal(bench.CalibrationArtifact{Resolved: true, StableRateRequestsPerSec: 2.0})
	if err := os.WriteFile(filepath.Join("campaign", "calibration.json"), art, 0o600); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if err := versionBundle([]string{"-dir", "campaign", "-campaign-id", "s1-test", "-price-usd-per-hour", "1.237",
		"-price-source", "aws-pricing-api", "-price-read-at", "2026-11-20T01:00:00Z"}, &out); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir("manifests", 0o700); err != nil {
		t.Fatal(err)
	}
	if err := versionManifests([]string{"-bundle", filepath.Join("campaign", bench.CampaignBundleFile), "-engine-url", "http://127.0.0.1:8000",
		"-blocks", "1", "-out", "manifests"}, &out); err != nil {
		t.Fatal(err)
	}
}

// TestVersionManifestTracesPassTheReplaysFrozenTokenCheck: the loaders accept a trace with no token counts, and the replay then refuses every cell.
func TestVersionManifestTracesPassTheReplaysFrozenTokenCheck(t *testing.T) {
	dir := t.TempDir()
	art, _ := json.Marshal(bench.CalibrationArtifact{Resolved: true, StableRateRequestsPerSec: 2.0})
	if err := os.WriteFile(filepath.Join(dir, "calibration.json"), art, 0o600); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if err := versionBundle([]string{"-dir", dir, "-campaign-id", "s1-test", "-price-usd-per-hour", "1.237",
		"-price-source", "aws-pricing-api", "-price-read-at", "2026-11-20T01:00:00Z"}, &out); err != nil {
		t.Fatal(err)
	}
	mdir := filepath.Join(dir, "manifests")
	if err := os.Mkdir(mdir, 0o700); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	if err := versionManifests([]string{"-bundle", filepath.Join(dir, bench.CampaignBundleFile), "-engine-url", "http://127.0.0.1:8000",
		"-blocks", "1", "-out", mdir}, &out); err != nil {
		t.Fatal(err)
	}
	st, _ := bench.LookupStudy(bench.StudyVersionAsync)
	for path := range strings.FieldsSeq(out.String()) {
		m, err := bench.LoadManifest(path)
		if err != nil {
			t.Fatal(err)
		}
		rows, err := bench.ReadTraceFileVerified(m.TracePath, m.TraceChecksum)
		if err != nil {
			t.Fatal(err)
		}
		if err := frozenTokenRefusal(rows, st, m.TracePath); err != nil {
			t.Fatalf("%s: %v", path, err)
		}
	}
}
