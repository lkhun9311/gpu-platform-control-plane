package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// Long enough for the session-2 stagger trace, the longest, whose span at seed 11 is 2,378,283 ms.
const ivS2Duration = "2400000"

// genIVS2 runs gen-trace for one session-2 arm and returns the trace bytes, its path and the manifest path.
func genIVS2(t *testing.T, arm, seed string, extra ...string) ([]byte, string, string, error) {
	t.Helper()
	dir := t.TempDir()
	tracePath := filepath.Join(dir, "trace.jsonl")
	manifestPath := filepath.Join(dir, "manifest.yaml")
	args := append([]string{"--study", bench.StudyInstrumentValidationS2, "--arm", arm, "--seed", seed,
		"--trace-out", tracePath, "--manifest-out", manifestPath}, extra...)
	if err := genTrace(args); err != nil {
		return nil, "", "", err
	}
	b, err := os.ReadFile(tracePath)
	if err != nil {
		t.Fatal(err)
	}
	return b, tracePath, manifestPath, nil
}

// The three modes of one type are paired on one trace, measured and warm-up alike.
func TestGenTraceS2GivesTheModesOfOneEpisodeTypeIdenticalBytes(t *testing.T) {
	for _, et := range []string{"burst", "stagger"} {
		for _, warm := range [][]string{nil, {"--warmup"}} {
			var first []byte
			for _, mode := range []string{"log", "nolog", "async"} {
				b, _, _, err := genIVS2(t, et+"-"+mode, "11", append([]string{"--duration-ms", ivS2Duration}, warm...)...)
				if err != nil {
					t.Fatalf("%s-%s %v: %v", et, mode, warm, err)
				}
				if first == nil {
					first = b
					continue
				}
				if !bytes.Equal(first, b) {
					t.Errorf("%s-%s %v differs from %s-log under one seed", et, mode, warm, et)
				}
			}
		}
	}
}

// The warm-up is written with the usual manifest, for the same study and arm, and differs from the measured trace.
func TestGenTraceS2WarmupWritesItsOwnTraceAndManifest(t *testing.T) {
	warm, _, manifest, err := genIVS2(t, "burst-nolog", "11", "--duration-ms", ivS2Duration, "--warmup")
	if err != nil {
		t.Fatal(err)
	}
	measured, _, _, err := genIVS2(t, "burst-nolog", "11", "--duration-ms", ivS2Duration)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(warm, measured) {
		t.Fatal("--warmup wrote the measured trace")
	}
	m, err := bench.LoadManifest(manifest)
	if err != nil {
		t.Fatalf("the warm-up manifest does not load: %v", err)
	}
	if m.Study != bench.StudyInstrumentValidationS2 || m.Arm != "burst-nolog" {
		t.Errorf("the warm-up manifest records study %q arm %q", m.Study, m.Arm)
	}
	// One 2,048/16 request, ten bursts, two 2,048/16 requests: 1 + (1+4+16)x3 + 64 + 2 rows.
	if n := bytes.Count(warm, []byte("\n")); n != 1+63+64+2 {
		t.Errorf("the burst warm-up has %d rows, want %d", n, 1+63+64+2)
	}
	if !strings.HasPrefix(string(warm), `{"index":0,"offsetMs":0,"tenant":"premium-1","promptLenChars":10532,"maxOutputTokens":16,`) {
		t.Errorf("the warm-up does not open with the 2048/16 request: %.120s", warm)
	}
}

func TestGenTraceS2Refusals(t *testing.T) {
	if _, _, err := genIV(t, "burst-log", "1", "--duration-ms", ivDuration, "--warmup"); err == nil || !strings.Contains(err.Error(), "registers no warm-up") {
		t.Errorf("session 1 was given a warm-up: %v", err)
	}
	dir := t.TempDir()
	err := genTrace([]string{"--study", bench.StudySharingMatrix, "--arm", "R1", "--warmup",
		"--trace-out", filepath.Join(dir, "t.jsonl"), "--manifest-out", filepath.Join(dir, "m.yaml")})
	if err == nil || !strings.Contains(err.Error(), "--warmup is defined only for an episode study") {
		t.Errorf("a Poisson study was given a warm-up: %v", err)
	}
	if _, _, _, err := genIVS2(t, "stagger-log", "11", "--duration-ms", "2378282"); err == nil || !strings.Contains(err.Error(), "pass at least 2378283") {
		t.Errorf("a duration one ms short of the stagger span: %v", err)
	}
	// The held-out lengths are named until the table carries them, by the measured trace and by the warm-up.
	var missing []int
	for _, l := range []int{768, 3072, 6144} {
		if _, ok := bench.ResolveInputTokens(l); !ok {
			missing = append(missing, l)
		}
	}
	for _, warm := range [][]string{nil, {"--warmup"}} {
		_, _, _, err := genIVS2(t, "serial-log", "11", append([]string{"--duration-ms", ivS2Duration}, warm...)...)
		if len(missing) == 0 {
			if err != nil {
				t.Errorf("serial %v with every length measured: %v", warm, err)
			}
			continue
		}
		if err == nil || !strings.Contains(err.Error(), "no character count for "+fmt.Sprint(missing)) {
			t.Errorf("serial %v does not name the unmeasured lengths %v: %v", warm, missing, err)
		}
	}
}

// matrix-plan-check scores a session-2 trace on session 2's terms, and refuses session 1's trace and the warm-up.
func TestMatrixPlanCheckS2(t *testing.T) {
	arms := "serial-log serial-nolog burst-log burst-nolog stagger-log stagger-nolog serial-async burst-async stagger-async"
	check := func(study, trace, arm string) error {
		return matrixPlanCheck([]string{"--trace", trace, "--study", study, "--arm", arm, "--arms", arms})
	}
	_, stagger, _, err := genIVS2(t, "stagger-log", "11", "--duration-ms", ivS2Duration)
	if err != nil {
		t.Fatal(err)
	}
	_, burst, _, err := genIVS2(t, "burst-log", "11", "--duration-ms", ivS2Duration)
	if err != nil {
		t.Fatal(err)
	}
	_, warm, _, err := genIVS2(t, "burst-log", "11", "--duration-ms", ivS2Duration, "--warmup")
	if err != nil {
		t.Fatal(err)
	}
	_, s1stagger, err := genIV(t, "stagger-log", "11", "--duration-ms", ivDuration)
	if err != nil {
		t.Fatal(err)
	}
	if err := check(bench.StudyInstrumentValidationS2, stagger, "stagger-async"); err != nil {
		t.Errorf("the session-2 stagger trace was refused: %v", err)
	}
	if err := check(bench.StudyInstrumentValidationS2, burst, "burst-nolog"); err != nil {
		t.Errorf("the session-2 burst trace was refused: %v", err)
	}
	for _, c := range []struct {
		name, study, trace, arm, want string
	}{
		{"a session-1 stagger trace under session 2", bench.StudyInstrumentValidationS2, s1stagger, "stagger-log", "output cap 128"},
		{"a session-2 stagger trace under session 1", bench.StudyInstrumentValidation, stagger, "stagger-log", "output cap 512"},
		{"a warm-up trace", bench.StudyInstrumentValidationS2, warm, "burst-log", "not a burst setting"},
		{"a stagger trace in a burst cell", bench.StudyInstrumentValidationS2, stagger, "burst-log", "not a burst setting"},
	} {
		if err := check(c.study, c.trace, c.arm); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: want a refusal containing %q, got %v", c.name, c.want, err)
		}
	}
	if err := matrixPlanCheck([]string{"--trace", burst, "--study", bench.StudyInstrumentValidationS2, "--arm", "burst-log", "--arms", "burst-log"}); err == nil || !strings.Contains(err.Error(), "only one of burst-log and burst-nolog") {
		t.Errorf("a session-2 logging arm planned without its pair: %v", err)
	}
}
