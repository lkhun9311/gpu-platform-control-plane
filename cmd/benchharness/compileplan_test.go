/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package main

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// The command's whole job is to turn one file into a block a shell sources, so what is pinned here is the
// block: which values it claims came from the CR, and that the two it cannot get from the CR are refused
// rather than defaulted.
//
// The compiler's own refusals are tested in internal/bench. What is left for this layer is the translation
// into the runner's units, which is where a wrong answer would be a paid run at a load nobody registered.

const executableCR = "../../config/samples/platform_v1_gpusharingbenchmark_executable.yaml"

// captureStdout runs fn with os.Stdout replaced by a pipe and returns what it wrote.
//
// The reader runs in its own goroutine and is started BEFORE fn. A pipe's buffer is finite, so draining it
// after fn returns deadlocks as soon as the block outgrows that buffer -- and the first version of this
// helper read from /dev/stdin instead of the pipe, which is not an error and simply returned the wrong
// bytes: every assertion failed while the command was working correctly.
func captureStdout(t *testing.T, fn func() error) (string, error) {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	done := make(chan string, 1)
	go func() {
		var sb strings.Builder
		_, _ = io.Copy(&sb, r)
		done <- sb.String()
	}()
	orig := os.Stdout
	os.Stdout = w
	runErr := fn()
	os.Stdout = orig
	_ = w.Close()
	out := <-done
	_ = r.Close()
	return out, runErr
}

func TestTheCompiledBlockCarriesTheRegisteredLoad(t *testing.T) {
	out, err := captureStdout(t, func() error {
		return compilePlan([]string{"--cr", executableCR, "--duration-ms", "505000", "--study", "sharing-matrix-2026-09-10"})
	})
	if err != nil {
		t.Fatalf("the executable sample did not compile: %v", err)
	}
	// The registered tuple, as the pre-registration spells it. A load that is right to twelve decimal places
	// and prints as 9.404499999999999 is the same run under a spelling no document records, and the point of
	// this block is that a reader can match it against one.
	for _, want := range []string{
		`export ARMS="R1 shared"`,
		"export REPS=5",
		"export RATE=9.4045",
		"export PREMIUM_WEIGHT=1",
		"export NOISY_WEIGHT=0.026",
		"export PROBE_WEIGHT=0",
		"export PREMIUM_PROMPT_CHARS=1174",
		"export NOISY_PROMPT_CHARS=42579",
		"export DURATION_MS=505000",
	} {
		if !strings.Contains(out, want+"\n") {
			t.Errorf("the compiled block does not carry %q\ngot:\n%s", want, out)
		}
	}
	// The boundary has to be visible in the block itself, or a reader cannot tell which values the CR
	// supplied from the two it could not.
	if !strings.Contains(out, "# CR-DERIVED") || !strings.Contains(out, "# NOT CR-DERIVED") {
		t.Errorf("the block does not mark which values came from the CR:\n%s", out)
	}
	if !strings.Contains(out, "export BENCHMARK_CR_SHA256=") {
		t.Errorf("the block carries no CR digest, so the runner cannot refuse an environment that disagrees with it:\n%s", out)
	}
}

func TestTheTwoValuesTheCRCannotCarryAreRefusedRatherThanDefaulted(t *testing.T) {
	cases := []struct {
		name string
		args []string
	}{
		{"no duration", []string{"--cr", executableCR, "--study", "sharing-matrix-2026-09-10"}},
		{"no study", []string{"--cr", executableCR, "--duration-ms", "505000"}},
		{"no cr", []string{"--duration-ms", "505000", "--study", "sharing-matrix-2026-09-10"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if err := compilePlan(tc.args); err == nil {
				t.Fatalf("%s was accepted; a defaulted value would be printed beside the CR's own and a reader could not tell them apart", tc.name)
			}
		})
	}
}

func TestAStudyWithADifferentArrivalModelIsRefused(t *testing.T) {
	// The translation to a total rate and a weight is only the same load under the weighted model. Under the
	// independent model the same numbers draw a different schedule, so compiling for that study would hand
	// the runner a load nobody registered.
	err := compilePlan([]string{"--cr", executableCR, "--duration-ms", "505000", "--study", "throughput-ladder-independent-2026-09-15"})
	if err == nil {
		t.Fatal("a study whose arrivals are independent was accepted; its trace would not be this load")
	}
	if !strings.Contains(err.Error(), "weighted") {
		t.Errorf("the refusal does not say why: %v", err)
	}
}

// Every study this command exists to compile is ACCEPTED, which the refusal test above cannot establish.
//
// # WHY A POSITIVE CASE WAS NEEDED
//
// TestAStudyWithADifferentArrivalModelIsRefused asserts a non-nil error whose message contains "weighted".
// Both the id comparison the guard actually makes and an arrival-model comparison produce that message, so
// the test passes either way -- and it would still pass if the guard refused the only studies the command is
// for. Measured on 2026-10-04 while registering two new studies: the guard compares against
// StudySharingMatrix alone, so compiling a plan for either new study is refused, and nothing in this file
// went red. A guard is covered when its YES and its NO are both pinned.
func TestEveryStudyThisCommandCompilesIsAccepted(t *testing.T) {
	for _, study := range []string{
		bench.StudySharingMatrix,
		bench.StudyTailCrossingShortLC,
		bench.StudyTailCrossingLongLC,
	} {
		t.Run(study, func(t *testing.T) {
			err := compilePlan([]string{"--cr", executableCR, "--duration-ms", "505000", "--study", study})
			if err != nil {
				t.Errorf("study %s was refused: %v. These three share the weighted arrival model this command translates rates for; refusing one of them makes the command unusable for the run it was written for", study, err)
			}
		})
	}
}

func TestTheCommittedSampleIsStillRefusedThroughTheCommand(t *testing.T) {
	// internal/bench pins the refusal itself. What this pins is that the command does not paper over it --
	// a compile-plan that "fixed" the sample on the way through would make the documented gap invisible.
	err := compilePlan([]string{
		"--cr", filepath.Join("..", "..", "config", "samples", "platform_v1_gpusharingbenchmark.yaml"),
		"--duration-ms", "505000", "--study", "sharing-matrix-2026-09-10",
	})
	if err == nil {
		t.Fatal("the original sample compiled through the command while internal/bench refuses it")
	}
	if !strings.Contains(err.Error(), "cannot be executed") {
		t.Errorf("the refusal is not the compiler's: %v", err)
	}
}

func TestAnUnknownFieldIsRefusedRatherThanDropped(t *testing.T) {
	dir := t.TempDir()
	body, err := os.ReadFile(executableCR)
	if err != nil {
		t.Fatalf("read the sample: %v", err)
	}
	// A key this binary does not know is a key that changed the experiment for whoever wrote it.
	withExtra := strings.Replace(string(body), "  repetitions: 5", "  repetitions: 5\n  coolDownSeconds: 30", 1)
	if withExtra == string(body) {
		t.Fatal("the fixture was not modified, so this case tests nothing")
	}
	path := filepath.Join(dir, "cr.yaml")
	if err := os.WriteFile(path, []byte(withExtra), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := compilePlan([]string{"--cr", path, "--duration-ms", "505000", "--study", "sharing-matrix-2026-09-10"}); err == nil {
		t.Fatal("an unknown field was silently dropped; the plan would describe a different run than the file does")
	}
}
