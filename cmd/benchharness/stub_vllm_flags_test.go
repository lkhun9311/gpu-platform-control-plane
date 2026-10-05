package main

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
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
		// The lib takes the study first, so neither session's arms can be judged under the other's tables.
		script := `. hack/lib/instrument-validation.sh && iv_process_args_refusal "$IV_STUDY" "$1" "$2"`
		cmd := exec.Command("bash", "-c", script, "_", c.arm, line)
		cmd.Dir = "../.."
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Errorf("%s: the harness refused the stub's line %q: %v\n%s", c.arm, line, err, out)
		}
	}
	// And the refusal still fires: a -log arm handed the -nolog line must be refused.
	cmd := exec.Command("bash", "-c", `. hack/lib/instrument-validation.sh && iv_process_args_refusal "$IV_STUDY" "$1" "$2"`,
		"_", "serial-log", stubNonDefaultArgs(8000, true, false))
	cmd.Dir = "../.."
	if out, err := cmd.CombinedOutput(); err == nil {
		t.Errorf("the harness accepted a -log arm whose engine reported no iteration logging: %s", out)
	}
}

// In vLLM mode the stub ends each stream with a usage chunk, and a prompt of a measured length reports that
// length's token count, so session 2's warm-up check can pass on a stub the way it passes on the engine.
func TestStubReportsPromptTokensForMeasuredLengths(t *testing.T) {
	res, ok := bench.ResolveInputTokens(2048)
	if !ok {
		t.Fatal("2,048 tokens is not in the measured table")
	}
	srv := httptest.NewServer(stubMux(stubProfile{tokens: 2, usage: true}, newStubStats()))
	defer srv.Close()
	for _, c := range []struct {
		chars int
		want  string
	}{{res.Chars, `"prompt_tokens":2048`}, {400, `"prompt_tokens":100`}} {
		body := fmt.Sprintf(`{"messages":[{"role":"user","content":%q}],"stream":true}`, strings.Repeat("a", c.chars))
		resp, err := http.Post(srv.URL+"/v1/chat/completions", "application/json", strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		out, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if !strings.Contains(string(out), c.want) || !strings.HasSuffix(string(out), "data: [DONE]\n\n") {
			t.Errorf("%d characters: the stream does not end with a usage chunk carrying %s: %q", c.chars, c.want, out)
		}
	}
}
