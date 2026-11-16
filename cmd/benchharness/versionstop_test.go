package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// TestCancelledLadderLeavesAnUnresolvedArtifactNamingTheStop: a stop mid-ladder must leave a directory version-bundle can read and refuse.
func TestCancelledLadderLeavesAnUnresolvedArtifactNamingTheStop(t *testing.T) {
	st, _ := bench.LookupStudy(bench.StudyVersionAsync)
	rule := st.Version.Calibration
	dir := t.TempDir()
	ctx, cancel := context.WithCancelCause(context.Background())
	defer cancel(nil)
	runner := &bench.RungRunner{}
	probe := func(_ context.Context, rate float64, ordinal int) bench.RungClass {
		runner.OnRung(ordinal, nil, bench.RungObservation{OfferedRate: rate}, bench.RungStable, nil)
		// The stop arrives while rung 2 is running.
		if ordinal == 2 {
			cancel(errors.New("stopped by signal: terminated"))
		}
		return bench.RungStable
	}
	res, err := runVersionCalibration(ctx, dir, rule, runner, probe, testIdentity)
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(dir, calibrationArtifactFile))
	if err != nil {
		t.Fatalf("no artifact after a stop: %v", err)
	}
	var art bench.CalibrationArtifact
	if err := json.Unmarshal(data, &art); err != nil || art.Resolved || !strings.Contains(art.Reason, "stopped by signal: terminated") || art.Reason != res.Reason {
		t.Fatalf("artifact %+v err %v, want unresolved naming the stop", art, err)
	}
	var out bytes.Buffer
	if err := versionBundle([]string{"-dir", dir, "-campaign-id", "s1-test", "-price-usd-per-hour", "1.237",
		"-price-source", "aws-pricing-api", "-price-read-at", "2026-11-20T01:00:00Z"}, &out); err == nil || !strings.Contains(err.Error(), "unresolved") {
		t.Fatalf("version-bundle on a stopped calibration: %v, want an unresolved refusal", err)
	}
}

// TestCancelOnSignalNamesTheSignal: the process-level wiring turns a signal into a context cause the ladder's reason prints.
func TestCancelOnSignalNamesTheSignal(t *testing.T) {
	ctx, stop := cancelOnSignal(context.Background(), syscall.SIGUSR1)
	defer stop()
	if err := syscall.Kill(os.Getpid(), syscall.SIGUSR1); err != nil {
		t.Fatal(err)
	}
	select {
	case <-ctx.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("the signal did not end the context")
	}
	if cause := context.Cause(ctx); cause == nil || !strings.Contains(cause.Error(), "stopped by signal") {
		t.Fatalf("cause %v, want it to name the signal", cause)
	}
}
