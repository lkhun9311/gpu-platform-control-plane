package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// genIVS3 runs gen-trace for one session-3 arm and returns the trace bytes and its path.
func genIVS3(t *testing.T, arm string, extra ...string) ([]byte, string) {
	t.Helper()
	dir := t.TempDir()
	tracePath := filepath.Join(dir, "trace.jsonl")
	args := append([]string{"--study", bench.StudyInstrumentValidationS3, "--arm", arm, "--seed", "11", "--duration-ms", ivS2Duration,
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

// gen-trace writes session 3's warm-up, and its stagger decoders carry the minimum there as in the measured trace.
func TestGenTraceS3WritesTheWarmupWithTheDecoderMinimum(t *testing.T) {
	for _, warm := range [][]string{nil, {"--warmup"}} {
		stagger, _ := genIVS3(t, "stagger-nolog", warm...)
		decoders := bytes.Count(stagger, []byte(`"maxOutputTokens":512,`))
		withMin := bytes.Count(stagger, []byte(`"minOutputTokens":512`))
		if decoders == 0 || withMin != decoders || bytes.Count(stagger, []byte("minOutputTokens")) != decoders {
			t.Errorf("stagger %v: %d decoders, %d rows with minOutputTokens 512, %d with the field at all",
				warm, decoders, withMin, bytes.Count(stagger, []byte("minOutputTokens")))
		}
		burst, _ := genIVS3(t, "burst-log", warm...)
		if bytes.Contains(burst, []byte("minOutputTokens")) {
			t.Errorf("the session-3 burst trace %v carries minOutputTokens", warm)
		}
		s2burst, _, _, err := genIVS2(t, "burst-log", "11", append([]string{"--duration-ms", ivS2Duration}, warm...)...)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(burst, s2burst) {
			t.Errorf("the session-3 burst trace %v differs from session 2's", warm)
		}
	}
}

// matrix-plan-check scores a session-3 trace on session 2's checks plus the decoder minimum.
func TestMatrixPlanCheckS3(t *testing.T) {
	arms := "serial-log serial-nolog burst-log burst-nolog stagger-log stagger-nolog"
	check := func(study, trace, arm string) error {
		return matrixPlanCheck([]string{"--trace", trace, "--study", study, "--arm", arm, "--arms", arms})
	}
	_, stagger := genIVS3(t, "stagger-log")
	_, burst := genIVS3(t, "burst-log")
	_, warm := genIVS3(t, "burst-log", "--warmup")
	_, s2stagger, _, err := genIVS2(t, "stagger-log", "11", "--duration-ms", ivS2Duration)
	if err != nil {
		t.Fatal(err)
	}
	if err := check(bench.StudyInstrumentValidationS3, stagger, "stagger-log"); err != nil {
		t.Errorf("the session-3 stagger trace was refused: %v", err)
	}
	if err := check(bench.StudyInstrumentValidationS3, burst, "burst-nolog"); err != nil {
		t.Errorf("the session-3 burst trace was refused: %v", err)
	}
	// A decoder that lost its minimum in the file is refused, which a count of settings alone would not do.
	raw, err := os.ReadFile(stagger)
	if err != nil {
		t.Fatal(err)
	}
	stripped := filepath.Join(t.TempDir(), "stripped.jsonl")
	if err := os.WriteFile(stripped, bytes.Replace(raw, []byte(`,"minOutputTokens":512`), nil, 1), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		name, study, trace, arm, want string
	}{
		{"a session-2 stagger trace under session 3", bench.StudyInstrumentValidationS3, s2stagger, "stagger-log", "registers 512 for every stagger decoder"},
		{"a session-3 stagger trace under session 2", bench.StudyInstrumentValidationS2, stagger, "stagger-log", "minOutputTokens 512 and study " + bench.StudyInstrumentValidationS2},
		{"a session-3 trace with one decoder stripped", bench.StudyInstrumentValidationS3, stripped, "stagger-log", "minOutputTokens 0"},
		{"a warm-up trace", bench.StudyInstrumentValidationS3, warm, "burst-log", "not a burst setting"},
		{"a stagger trace in a burst cell", bench.StudyInstrumentValidationS3, stagger, "burst-log", "not a burst setting"},
	} {
		if err := check(c.study, c.trace, c.arm); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: want a refusal containing %q, got %v", c.name, c.want, err)
		}
	}
	if err := matrixPlanCheck([]string{"--trace", burst, "--study", bench.StudyInstrumentValidationS3, "--arm", "burst-log", "--arms", "burst-log"}); err == nil || !strings.Contains(err.Error(), "only one of burst-log and burst-nolog") {
		t.Errorf("a session-3 logging arm planned without its pair: %v", err)
	}
}
