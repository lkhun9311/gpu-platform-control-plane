package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// Long enough for three stagger cycles, the longest type.
const ivDuration = "700000"

// genIV runs gen-trace for one instrument-validation arm and returns the trace bytes and path.
func genIV(t *testing.T, arm, seed string, extra ...string) ([]byte, string, error) {
	t.Helper()
	dir := t.TempDir()
	tracePath := filepath.Join(dir, "trace.jsonl")
	args := append([]string{"--study", bench.StudyInstrumentValidation, "--arm", arm, "--seed", seed,
		"--trace-out", tracePath, "--manifest-out", filepath.Join(dir, "manifest.yaml")}, extra...)
	if err := genTrace(args); err != nil {
		return nil, "", err
	}
	b, err := os.ReadFile(tracePath)
	if err != nil {
		t.Fatal(err)
	}
	return b, tracePath, nil
}

// The three modes of one episode type are paired controls, so one seed must give them the same bytes.
func TestGenTraceGivesTheModesOfOneEpisodeTypeIdenticalBytes(t *testing.T) {
	for _, et := range []string{"burst", "stagger"} {
		var first []byte
		for _, mode := range []string{"log", "nolog", "async"} {
			b, _, err := genIV(t, et+"-"+mode, "21", "--duration-ms", ivDuration)
			if err != nil {
				t.Fatalf("%s-%s: %v", et, mode, err)
			}
			if first == nil {
				first = b
				continue
			}
			if !bytes.Equal(first, b) {
				t.Errorf("%s-%s differs from %s-log under one seed", et, mode, et)
			}
		}
		other, _, err := genIV(t, et+"-log", "22", "--duration-ms", ivDuration)
		if err != nil {
			t.Fatal(err)
		}
		if bytes.Equal(first, other) {
			t.Errorf("%s: seeds 21 and 22 gave identical traces, so repetitions would not vary", et)
		}
	}
}

func TestGenTraceRefusesWhatAnEpisodeTraceCannotTake(t *testing.T) {
	for _, c := range []struct {
		name string
		arm  string
		args []string
		want string
	}{
		{"a Poisson rate", "burst-log", []string{"--duration-ms", ivDuration, "--premium-rate", "1"}, "--premium-rate configures a Poisson trace"},
		{"a prompt length", "burst-log", []string{"--duration-ms", ivDuration, "--premium-prompt-chars", "1174"}, "--premium-prompt-chars configures"},
		{"an output cap", "burst-log", []string{"--duration-ms", ivDuration, "--premium-output-tokens", "64"}, "--premium-output-tokens configures"},
		{"no duration", "burst-log", nil, "needs --duration-ms"},
		{"a duration that cannot hold three cycles", "burst-log", []string{"--duration-ms", "300000"}, "complete cycles"},
		{"an arm of another study", "R1", []string{"--duration-ms", ivDuration}, `arm "R1" is not one of`},
	} {
		if _, _, err := genIV(t, c.arm, "1", c.args...); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: want a refusal containing %q, got %v", c.name, c.want, err)
		}
	}
}

// matrix-plan-check accepts the generator's own trace and refuses one built for another episode type.
func TestMatrixPlanCheckJudgesAnEpisodeTraceOnItsOwnTerms(t *testing.T) {
	_, burst, err := genIV(t, "burst-log", "3", "--duration-ms", ivDuration)
	if err != nil {
		t.Fatal(err)
	}
	arms := "serial-log serial-nolog burst-log burst-nolog stagger-log stagger-nolog serial-async burst-async stagger-async"
	check := func(trace, arm, arms string) error {
		return matrixPlanCheck([]string{"--trace", trace, "--study", bench.StudyInstrumentValidation, "--arm", arm, "--arms", arms})
	}
	// Accepted although it offers fewer premium requests than the tail studies' floor would demand.
	if err := check(burst, "burst-nolog", arms); err != nil {
		t.Fatalf("the generator's own burst trace was refused: %v", err)
	}
	if err := check(burst, "stagger-log", arms); err == nil || !strings.Contains(err.Error(), "not a stagger setting") {
		t.Errorf("a burst trace in a stagger cell: %v", err)
	}
	if err := check(burst, "burst-log", "burst-log"); err == nil || !strings.Contains(err.Error(), "only one of burst-log and burst-nolog") {
		t.Errorf("a logging arm planned without its pair: %v", err)
	}
	empty := filepath.Join(t.TempDir(), "empty.jsonl")
	if err := os.WriteFile(empty, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := check(empty, "burst-log", arms); err == nil || !strings.Contains(err.Error(), "no rows") {
		t.Errorf("an empty trace: %v", err)
	}
	if err := matrixPlanCheck([]string{"--trace", burst, "--study", bench.StudyInstrumentValidation, "--arm", "burst-log", "--arms", arms, "--reproduces", "hack/x"}); err == nil || !strings.Contains(err.Error(), "--reproduces is not defined") {
		t.Errorf("a reproduction claim: %v", err)
	}
}
