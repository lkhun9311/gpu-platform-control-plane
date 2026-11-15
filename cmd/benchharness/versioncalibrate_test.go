package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// TestRunVersionCalibrationWritesTheArtifactVersionBundleReads: a resolved ladder's artifact is what version-bundle freezes λ0 from.
func TestRunVersionCalibrationWritesTheArtifactVersionBundleReads(t *testing.T) {
	st, _ := bench.LookupStudy(bench.StudyVersionAsync)
	rule := st.Version.Calibration
	dir := t.TempDir()
	// A fake engine whose capacity is 2 req/s: every rung at or below it is stable.
	probe := func(_ context.Context, rate float64, ordinal int) bench.RungClass {
		if rate <= 2 {
			return bench.RungStable
		}
		return bench.RungUnstable
	}
	res, err := runVersionCalibration(context.Background(), dir, rule, &bench.RungRunner{}, probe)
	if err != nil {
		t.Fatal(err)
	}
	if !res.Resolved || res.Rate > 2 || res.Rate < 2/rule.TargetRatio {
		t.Fatalf("result %+v, want λ0 just under 2", res)
	}
	var out bytes.Buffer
	if err := versionBundle([]string{"-dir", dir, "-campaign-id", "s1-test", "-price-usd-per-hour", "1.237",
		"-price-source", "aws-pricing-api", "-price-read-at", "2026-11-20T01:00:00Z"}, &out); err != nil {
		t.Fatalf("version-bundle could not freeze the calibration it was given: %v", err)
	}
	if _, err := runVersionCalibration(context.Background(), dir, rule, &bench.RungRunner{}, probe); err == nil || !strings.Contains(err.Error(), "already holds calibration evidence") {
		t.Fatalf("second calibration: %v, want a refusal because the campaign was calibrated", err)
	}
}

// TestRunVersionCalibrationRecordsAnUnresolvedStop: "calibration unresolved, stop" is a registered outcome, so it is written, and version-bundle refuses it.
func TestRunVersionCalibrationRecordsAnUnresolvedStop(t *testing.T) {
	st, _ := bench.LookupStudy(bench.StudyVersionAsync)
	dir := t.TempDir()
	res, err := runVersionCalibration(context.Background(), dir, st.Version.Calibration, &bench.RungRunner{}, func(context.Context, float64, int) bench.RungClass { return bench.RungInvalid })
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(dir, calibrationArtifactFile))
	if err != nil {
		t.Fatal(err)
	}
	var art bench.CalibrationArtifact
	if err := json.Unmarshal(data, &art); err != nil || art.Resolved || art.Reason == "" || art.Reason != res.Reason {
		t.Fatalf("artifact %+v err %v, want an unresolved record with its reason", art, err)
	}
	var out bytes.Buffer
	if err := versionBundle([]string{"-dir", dir, "-campaign-id", "s1-test", "-price-usd-per-hour", "1.237",
		"-price-source", "aws-pricing-api", "-price-read-at", "2026-11-20T01:00:00Z"}, &out); err == nil || !strings.Contains(err.Error(), "unresolved") {
		t.Fatalf("version-bundle on an unresolved calibration: %v", err)
	}
}

// TestRunVersionCalibrationKeepsEachRungsEvidence runs real rungs against an engine that never drains, so each is invalid and recorded.
func TestRunVersionCalibrationKeepsEachRungsEvidence(t *testing.T) {
	st, _ := bench.LookupStudy(bench.StudyVersionAsync)
	d := *st.Version
	d.Calibration.DrainSeconds = 1
	dir := t.TempDir()
	busy := func(context.Context) (int, int, error) { return 1, 0, nil }
	runner := &bench.RungRunner{Design: d, Queue: busy, PollEvery: 100 * time.Millisecond}
	res, err := runVersionCalibration(context.Background(), dir, d.Calibration, runner, func(ctx context.Context, rate float64, ordinal int) bench.RungClass {
		return runner.Probe(ctx, rate, ordinal)
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Resolved || len(res.Rungs) != d.Calibration.MaxInvalidRetries+1 {
		t.Fatalf("result %+v, want an unresolved stop after %d invalid rungs", res, d.Calibration.MaxInvalidRetries+1)
	}
	for i := 1; i <= len(res.Rungs); i++ {
		data, err := os.ReadFile(filepath.Join(dir, fmt.Sprintf("calibration-rung-%d.json", i)))
		if err != nil {
			t.Fatal(err)
		}
		var rec rungRecord
		if err := json.Unmarshal(data, &rec); err != nil || rec.Class != bench.RungInvalid || !strings.Contains(rec.Error, "drain") {
			t.Fatalf("rung %d record %+v err %v", i, rec, err)
		}
	}
}

// TestRunVersionCalibrationSendsNothingItCannotRecord: on a paid engine a rung whose evidence cannot be kept is money spent for nothing.
func TestRunVersionCalibrationSendsNothingItCannotRecord(t *testing.T) {
	st, _ := bench.LookupStudy(bench.StudyVersionAsync)
	rule := st.Version.Calibration
	probes := 0
	counting := func(_ context.Context, rate float64, ordinal int) bench.RungClass { probes++; return bench.RungStable }
	if _, err := runVersionCalibration(context.Background(), filepath.Join(t.TempDir(), "missing"), rule, &bench.RungRunner{}, counting); err == nil || probes != 0 {
		t.Fatalf("missing directory: err %v after %d probes, want a refusal before any", err, probes)
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "calibration-rung-2.json"), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	probes = 0
	if _, err := runVersionCalibration(context.Background(), dir, rule, &bench.RungRunner{}, counting); err == nil || probes != 0 {
		t.Fatalf("leftover rung file: err %v after %d probes, want a refusal before any", err, probes)
	}
	// A write that fails mid-ladder stops every later probe.
	dir = t.TempDir()
	runner := &bench.RungRunner{}
	probes = 0
	_, err := runVersionCalibration(context.Background(), dir, rule, runner, func(_ context.Context, rate float64, ordinal int) bench.RungClass {
		probes++
		if ordinal == 2 {
			_ = os.WriteFile(filepath.Join(dir, "calibration-rung-2.json"), []byte("{}"), 0o600)
		}
		runner.OnRung(ordinal, nil, bench.RungObservation{OfferedRate: rate}, bench.RungStable, nil)
		return bench.RungStable
	})
	if err == nil || probes != 2 {
		t.Fatalf("write failure at rung 2: err %v after %d probes, want an error and no probe after rung 2", err, probes)
	}
}

// TestCalibrationReservationAdmitsOneOfTwoConcurrentRuns: two calibrations of one campaign would load the engine together and corrupt both.
func TestCalibrationReservationAdmitsOneOfTwoConcurrentRuns(t *testing.T) {
	for range 20 {
		dir := t.TempDir()
		results := make(chan error, 2)
		for range 2 {
			go func() { results <- reserveCalibration(dir) }()
		}
		ok := 0
		for range 2 {
			if <-results == nil {
				ok++
			}
		}
		if ok != 1 {
			t.Fatalf("%d of two concurrent calibrations reserved the campaign, want exactly 1", ok)
		}
	}
}
