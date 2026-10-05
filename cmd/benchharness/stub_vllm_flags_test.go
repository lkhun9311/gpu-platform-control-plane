package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The stub's vLLM-style output is held to the real readers, not to a copy of their patterns.
//
// A regular expression restated here would agree with itself; the harness reads the startup line with
// iv_process_args_refusal and the evaluator reads the iteration lines with iterlog.py, so those are what run.

func TestStubIterationLinesParseInTheEvaluator(t *testing.T) {
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("python3 is not on PATH, so the evaluator cannot be asked")
	}
	f, err := os.Create(filepath.Join(t.TempDir(), "engine.log"))
	if err != nil {
		t.Fatal(err)
	}
	l := &stubIterLog{out: f}
	l.request(4096, 3)
	l.request(400, 1)
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
	py := `import sys; sys.path.insert(0, sys.argv[1]); import iterlog
it = iterlog.parse(open(sys.argv[2])); iterlog.check_indices(it)
print(len(it), [s["ctx_tokens"] for s in it], [s["gen_reqs"] for s in it])`
	out, err := exec.Command("python3", "-c", py, "../../hack/tail-crossing-model", f.Name()).CombinedOutput()
	if err != nil {
		t.Fatalf("the evaluator refused the stub's lines: %v\n%s", err, out)
	}
	if got, want := strings.TrimSpace(string(out)), "4 [1024, 0, 0, 100] [0, 1, 1, 0]"; got != want {
		t.Fatalf("the evaluator read %q, want %q", got, want)
	}
}

func TestStubNonDefaultArgsSatisfyTheHarness(t *testing.T) {
	for _, c := range []struct {
		arm            string
		noAsync, iters bool
	}{
		{"serial-log", true, true},
		{"burst-nolog", true, false},
		{"stagger-async", false, false},
	} {
		line := stubNonDefaultArgs(8000, c.noAsync, c.iters)
		script := `. hack/lib/instrument-validation.sh && iv_process_args_refusal "$1" "$2"`
		cmd := exec.Command("bash", "-c", script, "_", c.arm, line)
		cmd.Dir = "../.."
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Errorf("%s: the harness refused the stub's line %q: %v\n%s", c.arm, line, err, out)
		}
	}
	// And the refusal still fires: a -log arm handed the -nolog line must be refused.
	cmd := exec.Command("bash", "-c", `. hack/lib/instrument-validation.sh && iv_process_args_refusal "$1" "$2"`,
		"_", "serial-log", stubNonDefaultArgs(8000, true, false))
	cmd.Dir = "../.."
	if out, err := cmd.CombinedOutput(); err == nil {
		t.Errorf("the harness accepted a -log arm whose engine reported no iteration logging: %s", out)
	}
}
