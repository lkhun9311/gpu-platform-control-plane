package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// genIVS4 runs gen-trace for one session-4 arm and returns the trace bytes and its path.
func genIVS4(t *testing.T, arm string, extra ...string) ([]byte, string) {
	t.Helper()
	dir := t.TempDir()
	tracePath := filepath.Join(dir, "trace.jsonl")
	args := append([]string{"--study", bench.StudyInstrumentValidationS4, "--arm", arm, "--seed", "11", "--duration-ms", ivS2Duration,
		"--trace-out", tracePath, "--manifest-out", filepath.Join(dir, "manifest.yaml")}, extra...)
	if err := genTrace(args); err != nil {
		t.Fatalf("gen-trace %s %v: %v", arm, extra, err)
	}
	b, err := os.ReadFile(tracePath)
	if err != nil {
		t.Fatal(err)
	}
	return b, tracePath
}

// gen-trace writes session 3's measured bytes under session 4, and a warm-up one line longer.
func TestGenTraceS4MeasuredIsSessionThreesAndWarmupIsOneLonger(t *testing.T) {
	for _, arm := range []string{"serial-log", "burst-nolog", "stagger-async"} {
		s4, _ := genIVS4(t, arm)
		s3, _ := genIVS3(t, arm)
		if !bytes.Equal(s4, s3) {
			t.Errorf("the session-4 %s measured trace differs from session 3's", arm)
		}
		w4, _ := genIVS4(t, arm, "--warmup")
		w3, _ := genIVS3(t, arm, "--warmup")
		if n4, n3 := bytes.Count(w4, []byte("\n")), bytes.Count(w3, []byte("\n")); n4 != n3+1 {
			t.Errorf("the session-4 %s warm-up has %d lines and session 3's %d, want one more", arm, n4, n3)
		}
	}
}

// matrix-plan-check scores a session-4 trace on session 3's checks.
func TestMatrixPlanCheckS4(t *testing.T) {
	arms := "serial-log serial-nolog burst-log burst-nolog stagger-log stagger-nolog"
	check := func(study, trace, arm string) error {
		return matrixPlanCheck([]string{"--trace", trace, "--study", study, "--arm", arm, "--arms", arms})
	}
	_, stagger := genIVS4(t, "stagger-log")
	_, serial := genIVS4(t, "serial-nolog")
	_, warm := genIVS4(t, "serial-log", "--warmup")
	_, s2stagger, _, err := genIVS2(t, "stagger-log", "11", "--duration-ms", ivS2Duration)
	if err != nil {
		t.Fatal(err)
	}
	if err := check(bench.StudyInstrumentValidationS4, stagger, "stagger-log"); err != nil {
		t.Errorf("the session-4 stagger trace was refused: %v", err)
	}
	if err := check(bench.StudyInstrumentValidationS4, serial, "serial-log"); err != nil {
		t.Errorf("the session-4 serial trace was refused: %v", err)
	}
	for _, c := range []struct {
		name, trace, arm, want string
	}{
		{"a session-2 stagger trace under session 4", s2stagger, "stagger-log", "registers 512 for every stagger decoder"},
		{"a warm-up trace", warm, "serial-log", "places it exactly 6 times"},
		{"a stagger trace in a serial cell", stagger, "serial-log", "not a serial setting"},
	} {
		if err := check(bench.StudyInstrumentValidationS4, c.trace, c.arm); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: want a refusal containing %q, got %v", c.name, c.want, err)
		}
	}
	if err := matrixPlanCheck([]string{"--trace", serial, "--study", bench.StudyInstrumentValidationS4, "--arm", "serial-log", "--arms", "serial-log"}); err == nil || !strings.Contains(err.Error(), "only one of serial-log and serial-nolog") {
		t.Errorf("a session-4 logging arm planned without its pair: %v", err)
	}
}
