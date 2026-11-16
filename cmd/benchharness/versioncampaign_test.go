package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// TestVersionBundleThenManifests drives both subcommands as a session would, and every written manifest loads.
func TestVersionBundleThenManifests(t *testing.T) {
	dir := t.TempDir()
	calibrateFake(t, dir)
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
	calibrateFake(t, "campaign")
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
	calibrateFake(t, dir)
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

// TestVersionCampaignSurvivesBeingMoved: an archived campaign is moved or copied whole, and its frozen manifests must still load.
func TestVersionCampaignSurvivesBeingMoved(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "campaign")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	calibrateFake(t, dir)
	var out bytes.Buffer
	if err := versionBundle([]string{"-dir", dir, "-campaign-id", "s1-test", "-price-usd-per-hour", "1.237",
		"-price-source", "aws-pricing-api", "-price-read-at", "2026-11-20T01:00:00Z"}, &out); err != nil {
		t.Fatal(err)
	}
	mdir := filepath.Join(dir, "manifests")
	if err := os.Mkdir(mdir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := versionManifests([]string{"-bundle", filepath.Join(dir, bench.CampaignBundleFile), "-engine-url", "http://127.0.0.1:8000",
		"-blocks", "1", "-out", mdir}, &out); err != nil {
		t.Fatal(err)
	}
	moved := filepath.Join(root, "archived")
	if err := os.Rename(dir, moved); err != nil {
		t.Fatal(err)
	}
	if _, _, err := bench.LoadCampaignBundle(filepath.Join(moved, bench.CampaignBundleFile)); err != nil {
		t.Fatalf("moved bundle: %v", err)
	}
	entries, _ := os.ReadDir(filepath.Join(moved, "manifests"))
	for _, e := range entries {
		if _, err := bench.LoadManifest(filepath.Join(moved, "manifests", e.Name())); err != nil {
			t.Fatalf("moved manifest %s: %v", e.Name(), err)
		}
	}
	if len(entries) != 6 {
		t.Fatalf("%d manifests, want 6", len(entries))
	}
}

// TestVersionManifestsWritesNothingForABadBlockList: a typo in one block must not leave the others frozen, or the corrected retry meets existing files.
func TestVersionManifestsWritesNothingForABadBlockList(t *testing.T) {
	dir := t.TempDir()
	calibrateFake(t, dir)
	var out bytes.Buffer
	if err := versionBundle([]string{"-dir", dir, "-campaign-id", "s1-test", "-price-usd-per-hour", "1.237",
		"-price-source", "aws-pricing-api", "-price-read-at", "2026-11-20T01:00:00Z"}, &out); err != nil {
		t.Fatal(err)
	}
	for _, blocks := range []string{"1,9", "1,1", "1,x"} {
		mdir := t.TempDir()
		err := versionManifests([]string{"-bundle", filepath.Join(dir, bench.CampaignBundleFile), "-engine-url", "http://127.0.0.1:8000",
			"-blocks", blocks, "-out", mdir}, &out)
		if err == nil {
			t.Fatalf("-blocks %s accepted", blocks)
		}
		if entries, _ := os.ReadDir(mdir); len(entries) != 0 {
			t.Fatalf("-blocks %s: refused but left %d files", blocks, len(entries))
		}
	}
}

// calibrateFake runs version-calibrate's ladder against a fake engine stable up to 2 req/s, writing the evidence a real
// run writes: the probe reports each rung to the runner as RungRunner.Probe does.
func calibrateFake(t *testing.T, dir string) {
	t.Helper()
	st, _ := bench.LookupStudy(bench.StudyVersionAsync)
	runner := &bench.RungRunner{}
	probe := func(_ context.Context, rate float64, ordinal int) bench.RungClass {
		rows, o, cls := fakeRung(t, *st.Version, rate, ordinal, 2)
		runner.OnRung(ordinal, rows, o, cls, nil)
		return cls
	}
	if _, err := runVersionCalibration(context.Background(), dir, st.Version.Calibration, runner, probe); err != nil {
		t.Fatal(err)
	}
}

// fakeRung is what RungRunner.Probe records for one rung of an engine stable up to capacity: the rung's own trace,
// replayed with every request conforming, and the observation and class its rows give.
//
// The stable engine ends each request 100 ms after its intended arrival.
// The unstable one ends it at twice its intended arrival, so its backlog grows through the window.
func fakeRung(t *testing.T, d bench.VersionStudyDesign, rate float64, ordinal int, capacity float64) ([]bench.RawRow, bench.RungObservation, bench.RungClass) {
	t.Helper()
	trace, err := d.CalibrationTrace(ordinal, rate)
	if err != nil {
		t.Fatal(err)
	}
	reported := true
	rows := make([]bench.RawRow, 0, len(trace))
	for _, tr := range trace {
		in := tr.OffsetMs * int64(time.Millisecond)
		end := in + 100*int64(time.Millisecond)
		if rate > capacity {
			end = 2*in + 100*int64(time.Millisecond)
		}
		rows = append(rows, bench.RawRow{
			Index: tr.Index, Arm: fmt.Sprintf("calibration-%d", ordinal), Tenant: tr.Tenant, IsNoisy: tr.IsNoisy,
			RequestID: bench.RequestIDFor(fmt.Sprintf("cal%d", ordinal), tr.Index), ScheduledOffsetMs: tr.OffsetMs,
			PromptLenChars: tr.PromptLenChars, ExactInputTokens: tr.ExactInputTokens,
			Disposition: bench.DispositionCompleted, HTTPStatus: 200, StreamTerminated: true,
			EngineUsageReported: &reported, EngineInputTokens: tr.ExactInputTokens, EngineOutputTokens: tr.MaxOutputTokens,
			FinishReason: "length", OutputTokens: 2,
			Clock: &bench.RequestClock{IntendedNanos: &in, SendNanos: &in, TerminalNanos: &end},
		})
	}
	o, err := bench.ObserveRung(rows, rate, d.Calibration, true)
	if err != nil {
		t.Fatal(err)
	}
	cls := d.Calibration.ClassifyRung(o)
	if want := map[bool]bench.RungClass{true: bench.RungStable, false: bench.RungUnstable}[rate <= capacity]; cls != want {
		t.Fatalf("rung %d at %v req/s classifies %s, want %s from an engine stable up to %v", ordinal, rate, cls, want, capacity)
	}
	return rows, o, cls
}
