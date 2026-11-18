package bench

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/engineargs"
)

// srpfDiagnosticDir holds the committed frozen trace and manifest the sweep replays.
const srpfDiagnosticDir = "../../hack/eks-serve/holdcap-study/diagnostic"

// The sweep's pull, download, capture and stop are the readiness preflight's steps, which apply their own bounds.
// The session's hard stop is summed from the sweep's, so the two must be equal or the stop would not cover the work.
// Mutation that turns this red: drop PullBound from the sweep's ReadinessRun.
func TestSRPFSweepBoundsAreTheBoundsItsStepsApply(t *testing.T) {
	for _, c := range []struct {
		name       string
		got, apply time.Duration
	}{
		{"pull", SRPFSweepPullBound, (&SRPFSweep{}).readiness().PullBound},
		{"model download", SRPFSweepModelBound, ReadinessModelBound},
		{"capture", SRPFSweepCaptureBound, ReadinessCaptureBound},
		{"stop", SRPFSweepStopBound, ReadinessStopBound},
	} {
		if c.got != c.apply {
			t.Errorf("the sweep budgets %s for its %s, and the step it runs applies %s", c.got, c.name, c.apply)
		}
	}
	if srpfSweepArmCount != len(SRPFSweepArms()) {
		t.Errorf("srpfSweepArmCount is %d and there are %d arms", srpfSweepArmCount, len(SRPFSweepArms()))
	}
	if SRPFSweepArmBound != 1060*time.Second || SRPFSweepBound != 11320*time.Second {
		t.Errorf("the arm bound is %s and the sweep bound %s; the session's stop was sized for 1060 s and 11320 s", SRPFSweepArmBound, SRPFSweepBound)
	}
}

// The order is frozen before the run, so a reader can check it was not chosen after the results.
// Mutations that turn this red: drop any one of srpfBalanced's three rules, or widen the correlation band to ±0.3.
func TestSRPFSweepOrderIsCounterbalancedAndFixed(t *testing.T) {
	var names []string
	order := SRPFSweepOrder(SRPFSweepOrderSeed)
	for _, a := range order {
		names = append(names, a.Name)
	}
	want := []string{"priority", "srpf-s10", "srpf-s2", "srpf-s5", "fcfs", "srpf-s3", "srpf-s8"}
	if !slices.Equal(names, want) {
		t.Fatalf("order %v, want %v", names, want)
	}
	if !srpfBalanced(order) {
		t.Errorf("order %v is not balanced", names)
	}
	byName := map[string]SRPFArm{}
	for _, a := range SRPFSweepArms() {
		byName[a.Name] = a
	}
	arms := func(names ...string) []SRPFArm {
		out := make([]SRPFArm, len(names))
		for i, n := range names {
			out[i] = byName[n]
		}
		return out
	}
	for _, c := range []struct {
		why   string
		order []SRPFArm
	}{
		// Each order breaks exactly one rule, so dropping any one rule lets one through.
		// Ladder 2, 5, 10, 3, 8 has rho = 0.5: a drift over the session would read as the threshold's effect.
		{"thresholds rising with position", arms("fcfs", "srpf-s2", "srpf-s5", "srpf-s10", "priority", "srpf-s3", "srpf-s8")},
		{"both baselines in one half", arms("fcfs", "priority", "srpf-s3", "srpf-s10", "srpf-s5", "srpf-s2", "srpf-s8")},
		{"a baseline in the middle", arms("priority", "srpf-s3", "srpf-s8", "fcfs", "srpf-s5", "srpf-s10", "srpf-s2")},
		{"ladder neighbours back to back", arms("fcfs", "srpf-s2", "srpf-s8", "srpf-s10", "priority", "srpf-s3", "srpf-s5")},
		// Ladder 2, 5, 10, 8, 3 has rho = 0.3 exactly, inside a ±0.3 band and outside this one.
		{"a correlation of 0.3", arms("fcfs", "srpf-s2", "srpf-s5", "srpf-s10", "priority", "srpf-s8", "srpf-s3")},
	} {
		if srpfBalanced(c.order) {
			t.Errorf("%s was accepted as balanced", c.why)
		}
	}
	sorted := slices.Clone(names)
	slices.Sort(sorted)
	all := SRPFSweepArmNames()
	slices.Sort(all)
	if !slices.Equal(sorted, all) {
		t.Errorf("order %v is not a permutation of the arms %v", names, all)
	}
}

// Each arm's engine differs from the earlier runs' only by its policy and the two SRPF variables.
// Mutations that turn this red: add the SRPF variables whenever Policy is fcfs, or set the starvation one from a constant.
func TestSRPFSweepRunArgsDifferOnlyByTheArm(t *testing.T) {
	s := &SRPFSweep{HFCache: "/hf", CompileRoot: "/compile", Overlay: "/opt/srpf/scheduler.py", Out: "/out", Port: 8000}
	const path = "/usr/local/lib/python3.12/dist-packages/vllm/v1/core/sched/scheduler.py"
	args, err := s.RunArgs(SRPFArm{Name: "srpf-s2", Policy: "fcfs", SRPF: true, Starvation: 2}, path)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"run", "--detach", "--name=srpf-srpf-s2", "--gpus=all", "--shm-size=1g", "--workdir=/",
		"--env=VLLM_SERVER_DEV_MODE=1", "--env=PYTHONPYCACHEPREFIX=/tmp/srpf-pycache", "--env=VLLM_ENABLE_SRPF=1",
		"--env=VLLM_SRPF_STARVATION_THRESHOLD=2",
		"--publish=127.0.0.1:8000:8000", "--volume=/hf:/root/.cache/huggingface", "--volume=/compile/srpf-s2:/root/.cache/vllm",
		"--volume=/opt/srpf/scheduler.py:" + path + ":ro",
		"--volume=/out/observe/srpf_observe.py:/usr/local/lib/python3.12/dist-packages/srpf_observe.py:ro",
		"--volume=/out/observe/zz_srpf_observe.pth:/usr/local/lib/python3.12/dist-packages/zz_srpf_observe.pth:ro",
		"--label=study=srpf-sweep", "--entrypoint=env", SRPFSweepImage, "-u", "VLLM_GPU_SYNC_CHECK", "vllm", "serve",
		"Qwen/Qwen2.5-3B-Instruct", "--dtype=half", "--max-model-len=16384", "--max-num-seqs=64", "--gpu-memory-utilization=0.90",
		"--no-enable-prefix-caching", "--max-num-batched-tokens=512", "--scheduling-policy=fcfs", "--no-async-scheduling",
		"--port=8000", "--served-model-name=Qwen/Qwen2.5-3B-Instruct", "--revision=" + SRPFSweepRevision,
		"--tokenizer-revision=" + SRPFSweepRevision,
	}
	if !slices.Equal(args, want) {
		t.Errorf("srpf-s2 runs\n%q\nwant\n%q", args, want)
	}
	for _, bad := range []SRPFArm{
		{Name: "srpf-default", Policy: "fcfs", SRPF: true},
		{Name: "fcfs-s5", Policy: "fcfs", Starvation: 5},
	} {
		if _, err := s.RunArgs(bad, path); err == nil {
			t.Errorf("arm %+v was given run args", bad)
		}
	}
	// The ladder the author asked for, with the default between, and every baseline unset.
	starvation := map[string]string{}
	rel := engineargs.Releases()[platformv1.VLLMReleaseV0271]
	for _, a := range SRPFSweepArms() {
		args, err := s.RunArgs(a, path)
		if err != nil {
			t.Fatal(err)
		}
		if got := slices.Contains(args, "--env=VLLM_ENABLE_SRPF=1"); got != a.SRPF {
			t.Errorf("%s sets the SRPF variable: %t", a.Name, got)
		}
		for _, arg := range args {
			if v, ok := strings.CutPrefix(arg, "--env=VLLM_SRPF_STARVATION_THRESHOLD="); ok {
				if _, dup := starvation[a.Name]; dup {
					t.Errorf("%s sets the starvation threshold twice", a.Name)
				}
				starvation[a.Name] = v
			}
		}
		if got := slices.Contains(args, "--long-prefill-token-threshold=384"); got != (a.Threshold == 384) {
			t.Errorf("%s passes the threshold: %t", a.Name, got)
		}
		if !slices.Contains(args, "--scheduling-policy="+a.Policy) {
			t.Errorf("%s does not pass its policy %s", a.Name, a.Policy)
		}
		for _, flag := range rel.Args {
			if !strings.HasPrefix(flag, "--scheduling-policy=") && !slices.Contains(args, flag) {
				t.Errorf("%s drops the earlier runs' %s", a.Name, flag)
			}
		}
	}
	wantStarvation := map[string]string{"srpf-s2": "2", "srpf-s3": "3", "srpf-s5": "5", "srpf-s8": "8", "srpf-s10": "10"}
	if !maps.Equal(starvation, wantStarvation) {
		t.Errorf("the arms set the starvation threshold %v, want %v and nothing for fcfs and priority", starvation, wantStarvation)
	}
}

// The engine's own record of its arguments is the check that the arm launched is the arm named.
// Mutation that turns this red: skip the threshold case in srpfNonDefaultArgsRefusal.
func TestSRPFNonDefaultArgsRefusal(t *testing.T) {
	// The run-3 engine's line, with the policy and threshold varied per case.
	line := func(policy string, threshold int) string {
		l := "non-default args: {'model_tag': 'Qwen/Qwen2.5-3B-Instruct', 'dtype': 'half', 'max_num_batched_tokens': 512, 'max_num_seqs': 64"
		if policy != "" {
			l += ", 'scheduling_policy': '" + policy + "'"
		}
		if threshold != 0 {
			l += fmt.Sprintf(", 'long_prefill_token_threshold': %d", threshold)
		}
		return l + ", 'async_scheduling': False}"
	}
	fcfs, prio := SRPFArm{Name: "fcfs", Policy: "fcfs"}, SRPFArm{Name: "priority-t384", Policy: "priority", Threshold: 384}
	for _, c := range []struct {
		name string
		arm  SRPFArm
		line string
		ok   bool
	}{
		{"fcfs, which is the default and so unnamed", fcfs, line("", 0), true},
		{"fcfs named", fcfs, line("fcfs", 0), true},
		{"fcfs arm on a priority engine", fcfs, line("priority", 0), false},
		{"fcfs arm with a threshold", fcfs, line("", 384), false},
		{"priority with its threshold", prio, line("priority", 384), true},
		{"priority arm on fcfs", prio, line("", 384), false},
		{"priority arm without its threshold", prio, line("priority", 0), false},
		{"priority arm with another threshold", prio, line("priority", 3840), false},
		{"no line", fcfs, "", false},
	} {
		err := srpfNonDefaultArgsRefusal(c.arm, c.line)
		if (err == nil) != c.ok {
			t.Errorf("%s: refusal %v, want ok=%t", c.name, err, c.ok)
		}
	}
}

// srpfProbeJSON is a serving probe's answer for the PR's scheduler, with env and starvation for every readable process.
// Its engine core is retitled under the server, with /proc showing 30 variables and none of the server's, as on 2026-11-17.
func srpfProbeJSON(env, starvation *string, pycSize int64) string {
	// The engine core's scheduler holds what it read, and the PR's default 5 when the variable is unset.
	// It reads the variable with int(), as the PR does, so "02" is held as 2.
	threshold := json.RawMessage("5")
	if starvation != nil {
		if v, err := strconv.Atoi(*starvation); err == nil {
			threshold = json.RawMessage(strconv.Itoa(v))
		}
	}
	p := srpfProbe{
		File: srpfFakePath, SHA256: SRPFSweepPRSchedulerSHA256, Size: 170000, SRPFKey: true, Observed: true,
		Schedulers: []srpfSchedulerRecord{{PID: 97, File: srpfFakePath, Threshold: threshold, Env: env, Starvation: starvation}},
		Env:        env, Starvation: starvation, PycachePrefix: new(srpfSweepPycachePrefix), PycFlags: new(int64(0)), PycSourceSize: new(pycSize),
		Procs: []srpfProbeProc{
			{PID: 1, EnvCount: 12, Cmd: "vllm serve", Env: env, Starvation: starvation, PycachePrefix: new(srpfSweepPycachePrefix)},
			{PID: 97, PPID: 1, EnvCount: 30, Cmd: "VLLM::EngineCore"},
		},
	}
	b, _ := json.Marshal(p)
	return "WARNING noise\n" + string(b) + "\n"
}

// The probe is what stops a wrong build, a wrong SRPF setting or a wrong aging threshold from being measured under an arm's name.
// Mutation that turns this red: drop the pyc size comparison in srpfProbeRefusal.
func TestSRPFProbeRefusal(t *testing.T) {
	const path = srpfFakePath
	srpf, fcfs := SRPFArm{Name: "srpf-s2", Policy: "fcfs", SRPF: true, Starvation: 2}, SRPFArm{Name: "fcfs", Policy: "fcfs"}
	one, two := new("1"), new("2")
	proof, err := srpfProbeCheck(srpf, path, true, []byte(srpfProbeJSON(one, two, 170000)))
	if err != nil {
		t.Errorf("a conforming srpf probe was refused: %v", err)
	}
	// Mutation that turns this red: build the proof from the engine core's ancestor instead of its scheduler's record.
	if want := `VLLM::EngineCore 97 initialised srpf_starvation_threshold=2 with VLLM_ENABLE_SRPF="1" VLLM_SRPF_STARVATION_THRESHOLD="2"`; proof != want {
		t.Errorf("the engine core's proof is %q, want %q", proof, want)
	}
	if err := srpfProbeRefusal(fcfs, path, true, []byte(srpfProbeJSON(nil, nil, 170000))); err != nil {
		t.Errorf("a conforming fcfs probe was refused: %v", err)
	}
	mutate := func(f func(p *srpfProbe)) []byte {
		var p srpfProbe
		_ = json.Unmarshal(lastLine([]byte(srpfProbeJSON(one, two, 170000))), &p)
		f(&p)
		b, _ := json.Marshal(p)
		return b
	}
	for _, c := range []struct {
		name    string
		arm     SRPFArm
		out     []byte
		serving bool
		want    string
	}{
		{"srpf arm without the variable", srpf, []byte(srpfProbeJSON(nil, two, 170000)), true, "needs VLLM_ENABLE_SRPF=1"},
		{"fcfs arm with the variable", fcfs, []byte(srpfProbeJSON(one, nil, 170000)), true, "must not set VLLM_ENABLE_SRPF"},
		// The PR's default is 5, so an arm whose variable was dropped would run 5 and look like a measured threshold.
		{"srpf arm without its threshold", srpf, []byte(srpfProbeJSON(one, nil, 170000)), true, "needs VLLM_SRPF_STARVATION_THRESHOLD=2"},
		{"srpf arm with another arm's threshold", srpf, []byte(srpfProbeJSON(one, new("5"), 170000)), true, "needs VLLM_SRPF_STARVATION_THRESHOLD=2"},
		{"srpf arm with a threshold int() reads the same", srpf, []byte(srpfProbeJSON(one, new("02"), 170000)), true, "needs VLLM_SRPF_STARVATION_THRESHOLD=2"},
		{"fcfs arm with a threshold", fcfs, []byte(srpfProbeJSON(nil, two, 170000)), true, "must not set VLLM_SRPF_STARVATION_THRESHOLD"},
		{"the merge base's scheduler", srpf, mutate(func(p *srpfProbe) { p.SHA256 = SRPFSweepBaseSchedulerSHA256 }), true, "not the PR head's"},
		{"run 8's scheduler", srpf, mutate(func(p *srpfProbe) {
			p.SHA256 = "19502766a57a37432cda1ac0a581979d22845cc0fe2d5f08be8647ca113d2fa9"
		}), true, "not the PR head's"},
		{"another file", srpf, mutate(func(p *srpfProbe) { p.File = "/vllm-workspace/vllm/v1/core/sched/scheduler.py" }), true, "not the overlaid"},
		{"the server compiled another source", srpf, mutate(func(p *srpfProbe) { p.PycSourceSize = new(int64(160000)) }), true, "compiled a scheduler of 160000 bytes"},
		{"no server bytecode", srpf, mutate(func(p *srpfProbe) { p.PycSourceSize, p.PycFlags = nil, nil }), true, "no server process wrote bytecode"},
		{"a process without the variable", srpf, mutate(func(p *srpfProbe) {
			p.Procs = append(p.Procs, srpfProbeProc{PID: 7, PPID: 1, EnvCount: 12, Cmd: "EngineCore", Starvation: two, PycachePrefix: new(srpfSweepPycachePrefix)})
		}), true, "process 7"},
		{"a process with another threshold", srpf, mutate(func(p *srpfProbe) {
			p.Procs = append(p.Procs, srpfProbeProc{PID: 7, PPID: 1, EnvCount: 12, Cmd: "python3", Env: one, Starvation: new("10"), PycachePrefix: new(srpfSweepPycachePrefix)})
		}), true, "process 7"},
		// An unreadable environment is excused only through a readable, checked ancestor.
		{"an unreadable process with no readable ancestor", srpf, mutate(func(p *srpfProbe) {
			p.Procs = append(p.Procs, srpfProbeProc{PID: 8, PPID: 99, Cmd: "VLLM::EngineCore"})
		}), true, "no ancestor"},
		// The variables reach the scheduler only in the engine core, so a container without one shows nothing.
		// Mutation that turns this red: drop the engine-core requirement from srpfProbeCheck.
		{"no engine core", srpf, mutate(func(p *srpfProbe) { p.Procs = p.Procs[:1] }), true, "no VLLM::EngineCore process"},
		// The parent carried the arm's variables and the scheduler still runs the default: only the engine core's own record shows it.
		// Mutation that turns this red: drop the threshold comparison on the observer's records.
		{"an engine core whose scheduler holds the default", srpf, mutate(func(p *srpfProbe) { p.Schedulers[0].Threshold = json.RawMessage("5") }), true,
			"needs srpf_starvation_threshold 2 and the scheduler constructed in process 97 holds 5"},
		{"a threshold that is not an int", srpf, mutate(func(p *srpfProbe) { p.Schedulers[0].Threshold = json.RawMessage(`"'2'"`) }), true, "needs srpf_starvation_threshold 2"},
		{"an engine core whose scheduler lost the variable", srpf, mutate(func(p *srpfProbe) { p.Schedulers[0].Starvation = nil }), true,
			"needs VLLM_SRPF_STARVATION_THRESHOLD=2 and the scheduler constructed in process 97 has unset"},
		// Mutation that turns this red: drop the check that every engine core wrote a record.
		{"an engine core with no record", srpf, mutate(func(p *srpfProbe) { p.Schedulers = nil }), true, "engine core 97 wrote no observer record"},
		{"a record from another process", srpf, mutate(func(p *srpfProbe) {
			p.Schedulers = append(p.Schedulers, srpfSchedulerRecord{PID: 1, File: srpfFakePath, Threshold: json.RawMessage("2"), Env: one, Starvation: two})
		}), true, "process 1, which is not a running VLLM::EngineCore"},
		{"a record of another scheduler file", srpf, mutate(func(p *srpfProbe) { p.Schedulers[0].File = "/x/scheduler.py" }), true, "not the overlaid"},
		{"an unreadable record", srpf, mutate(func(p *srpfProbe) { p.Schedulers[0].Error = "97-1.json: ValueError" }), true, "could not be read"},
		{"an image without the observer", srpf, mutate(func(p *srpfProbe) { p.Observed = false }), false, "not wrapped by the observer"},
		{"a baseline whose scheduler does not hold the default", fcfs, mutate(func(p *srpfProbe) {
			p.Env, p.Starvation, p.Procs[0].Env, p.Procs[0].Starvation = nil, nil, nil, nil
			p.Schedulers[0] = srpfSchedulerRecord{PID: 97, File: srpfFakePath, Threshold: json.RawMessage("3")}
		}), true, "needs srpf_starvation_threshold 5"},
		{"no prefix", srpf, mutate(func(p *srpfProbe) { p.PycachePrefix = nil }), true, "PYTHONPYCACHEPREFIX"},
		{"a server with the CI image's sync check", srpf, mutate(func(p *srpfProbe) { p.Procs[0].SyncCheck = new("error") }), true, "VLLM_GPU_SYNC_CHECK=error"},
		{"no server process", srpf, mutate(func(p *srpfProbe) { p.Procs = nil }), true, "no server process"},
		{"not JSON", srpf, []byte("Traceback"), false, "not JSON"},
	} {
		err := srpfProbeRefusal(c.arm, path, c.serving, c.out)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: refusal %v, want one naming %q", c.name, err, c.want)
		}
	}
	// vLLM's engine core renames itself with setproctitle, which can leave /proc showing no environment, as on 2026-11-16.
	renamed := mutate(func(p *srpfProbe) { p.Procs[1].EnvCount = 0 })
	if err := srpfProbeRefusal(srpf, path, true, renamed); err != nil {
		t.Errorf("an engine core renamed under a checked server was refused: %v", err)
	}
	// Run 8's engine core, whose partly overwritten /proc showed other values, is still judged by its parent.
	// Mutation that turns this red: go back to excusing only a process that shows no environment.
	partial := mutate(func(p *srpfProbe) { p.Procs[1].Env, p.Procs[1].Starvation = new("0"), new("99") })
	if err := srpfProbeRefusal(srpf, path, true, partial); err != nil {
		t.Errorf("an engine core whose renamed environment is partly overwritten was refused: %v", err)
	}
	// A retitled parent's /proc may be the title's overwrite, so it cannot vouch for its child, and the server above it does.
	// Mutation that turns this red: let readableAncestor return a retitled process that showed variables.
	nested := mutate(func(p *srpfProbe) {
		p.Procs[1].PPID = 50
		p.Procs = append(p.Procs, srpfProbeProc{PID: 50, PPID: 1, EnvCount: 30, Cmd: "VLLM::APIServer"})
	})
	if proof, err := srpfProbeCheck(srpf, path, true, nested); err != nil || !strings.Contains(proof, "VLLM::EngineCore 97 initialised srpf_starvation_threshold=2 ") {
		t.Errorf("an engine core under a retitled parent was judged by %q (%v), not by the server above it", proof, err)
	}
	// Before any server ran, the image check has no bytecode or process to read.
	if err := srpfProbeRefusal(SRPFArm{Name: "image"}, path, false, mutate(func(p *srpfProbe) {
		p.Env, p.Starvation, p.PycSourceSize, p.PycFlags, p.Procs, p.Schedulers = nil, nil, nil, nil, nil, nil
	})); err != nil {
		t.Errorf("the image probe was refused: %v", err)
	}
}

// The probes are Python run in the container, so they are run here against a fake vllm package to show they parse and
// report what a server process left behind.
// Mutation that turns this red: read the pyc after the probe's own import, which writes it.
func TestSRPFProbesRunUnderPython(t *testing.T) {
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 is not installed")
	}
	root := t.TempDir()
	sched := filepath.Join(root, "site", "vllm", "v1", "core", "sched")
	if err := os.MkdirAll(sched, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, d := range []string{"vllm", "vllm/v1", "vllm/v1/core", "vllm/v1/core/sched"} {
		if err := os.WriteFile(filepath.Join(root, "site", d, "__init__.py"), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	src := "class Scheduler:\n    def _get_srpf_key_for_req(self, req):\n        return ()\n"
	if err := os.WriteFile(filepath.Join(sched, "scheduler.py"), []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
	prefix := filepath.Join(root, "pycache")
	env := append(os.Environ(), "PYTHONPATH="+filepath.Join(root, "site"), "PYTHONPYCACHEPREFIX="+prefix, "VLLM_ENABLE_SRPF=1",
		"VLLM_SRPF_STARVATION_THRESHOLD=3")

	// The locate probe must find the file without importing the package's modules.
	out, err := runPython(t, py, env, srpfLocateProbe)
	if err != nil {
		t.Fatalf("locate probe: %v: %s", err, out)
	}
	var loc srpfProbe
	if err := json.Unmarshal(lastLine(out), &loc); err != nil || loc.File != filepath.Join(sched, "scheduler.py") {
		t.Fatalf("locate probe answered %s (%v)", out, err)
	}

	// Before any server imported the scheduler, there is no bytecode to read.
	out, err = runPython(t, py, env, srpfCodeProbe)
	if err != nil {
		t.Fatalf("code probe: %v: %s", err, out)
	}
	var p srpfProbe
	if err := json.Unmarshal(lastLine(out), &p); err != nil {
		t.Fatal(err)
	}
	if p.PycSourceSize != nil {
		t.Errorf("the probe read bytecode no server wrote: %d", *p.PycSourceSize)
	}
	if p.Size != int64(len(src)) || !p.SRPFKey || p.Env == nil || *p.Env != "1" || p.Starvation == nil || *p.Starvation != "3" {
		t.Errorf("the probe reported %+v", p)
	}

	// A "server" that imported the scheduler and stays up, as the engine core does.
	if err := os.RemoveAll(prefix); err != nil {
		t.Fatal(err)
	}
	server := exec.Command(py, "-c", "import sys, vllm.v1.core.sched.scheduler; print('up', flush=True); sys.stdin.read()")
	// The server's threshold differs from the probe's own, so a probe that reported its own for every process is caught.
	server.Env = append(slices.Clone(env), "VLLM_GPU_SYNC_CHECK=error", "VLLM_SRPF_STARVATION_THRESHOLD=7")
	stdin, _ := server.StdinPipe()
	stdout, _ := server.StdoutPipe()
	if err := server.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = stdin.Close(); _ = server.Wait() })
	if line, _ := bufio.NewReader(stdout).ReadString('\n'); line != "up\n" {
		t.Fatalf("the server printed %q", line)
	}
	out, err = runPython(t, py, env, srpfCodeProbe)
	if err != nil {
		t.Fatalf("code probe: %v: %s", err, out)
	}
	p = srpfProbe{}
	if err := json.Unmarshal(lastLine(out), &p); err != nil {
		t.Fatal(err)
	}
	if p.PycSourceSize == nil || *p.PycSourceSize != int64(len(src)) || p.PycFlags == nil || *p.PycFlags != 0 {
		t.Errorf("the probe did not read the server's bytecode of a %d-byte source: %+v", len(src), p)
	}
	i := slices.IndexFunc(p.Procs, func(pr srpfProbeProc) bool { return pr.PID == server.Process.Pid })
	// Mutation that turns this red: read the starvation variable from the probe's own environment for every process.
	if i < 0 || p.Procs[i].Env == nil || *p.Procs[i].Env != "1" || p.Procs[i].PycachePrefix == nil || *p.Procs[i].PycachePrefix != prefix ||
		p.Procs[i].Starvation == nil || *p.Procs[i].Starvation != "7" ||
		p.Procs[i].SyncCheck == nil || *p.Procs[i].SyncCheck != "error" {
		t.Errorf("the probe did not report the server's environment: %+v", p.Procs)
	}
}

// The observer is Python loaded by site in every engine process, so it is run here against a fake vllm package whose
// Scheduler reads the threshold as the PR's does.
// The "engine core" changes its own os.environ after exec, which /proc does not show, and the record must show what the
// constructed scheduler holds, as codex's review of this sweep reproduced.
// Mutations that turn this red: record the variable instead of the instance's field, or drop the .pth file.
func TestSRPFObserverRecordsWhatTheSchedulerHolds(t *testing.T) {
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 is not installed")
	}
	root := t.TempDir()
	site := filepath.Join(root, "site")
	sched := filepath.Join(site, "vllm", "v1", "core", "sched")
	if err := os.MkdirAll(sched, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, d := range []string{"vllm", "vllm/v1", "vllm/v1/core", "vllm/v1/core/sched"} {
		if err := os.WriteFile(filepath.Join(site, d, "__init__.py"), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// After reading the threshold, this Scheduler sets the variable to 4, so when the observer writes its record the
	// instance holds 9 and the environment says 4, and only a record of the instance's field reports 9.
	src := "import os\nclass Scheduler:\n    def __init__(self):\n        self.srpf_starvation_threshold = int(os.environ.get(\"VLLM_SRPF_STARVATION_THRESHOLD\", \"5\"))\n" +
		"        os.environ[\"VLLM_SRPF_STARVATION_THRESHOLD\"] = \"4\"\n" +
		"    def _get_srpf_key_for_req(self, req):\n        return ()\n"
	if err := os.WriteFile(filepath.Join(sched, "scheduler.py"), []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
	s := &SRPFSweep{Out: filepath.Join(root, "out")}
	if err := os.Mkdir(s.Out, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := s.writeObserver(); err != nil {
		t.Fatal(err)
	}
	// The mounts put both files in the package's site directory, which is what site.addsitedir reads here.
	for _, name := range []string{srpfObserveModule, srpfObservePth} {
		b, err := os.ReadFile(filepath.Join(s.observeDir(), name))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(srpfSitePackages(filepath.Join(sched, "scheduler.py")), name), b, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	records := filepath.Join(root, "records")
	env := append(os.Environ(), "PYTHONPYCACHEPREFIX="+filepath.Join(root, "pycache"), "SRPF_OBSERVE_DIR="+records,
		"VLLM_ENABLE_SRPF=1", "VLLM_SRPF_STARVATION_THRESHOLD=3")
	withSite := "import site; site.addsitedir(" + strconv.Quote(site) + ")\n"
	core := exec.Command(py, "-c", withSite+"import os, sys\nos.environ['VLLM_SRPF_STARVATION_THRESHOLD'] = '9'\n"+
		"import vllm.v1.core.sched.scheduler as m\nm.Scheduler()\nprint('up', flush=True)\nsys.stdin.read()")
	core.Env, core.Dir = env, t.TempDir()
	stdin, _ := core.StdinPipe()
	stdout, _ := core.StdoutPipe()
	core.Stderr = os.Stderr
	if err := core.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = stdin.Close(); _ = core.Wait() })
	if line, _ := bufio.NewReader(stdout).ReadString('\n'); line != "up\n" {
		t.Fatalf("the engine core printed %q", line)
	}
	out, err := runPython(t, py, env, withSite+srpfCodeProbe)
	if err != nil {
		t.Fatalf("code probe: %v: %s", err, out)
	}
	var p srpfProbe
	if err := json.Unmarshal(lastLine(out), &p); err != nil {
		t.Fatal(err)
	}
	if !p.Observed || len(p.Schedulers) != 1 {
		t.Fatalf("the probe saw observed=%t and %d scheduler records: %s", p.Observed, len(p.Schedulers), out)
	}
	r := p.Schedulers[0]
	// Mutation that turns this red: record int(os.environ.get(...)) in place of the instance's srpf_starvation_threshold.
	if r.PID != core.Process.Pid || string(r.Threshold) != "9" || r.Starvation == nil || *r.Starvation != "4" || r.Env == nil || *r.Env != "1" ||
		r.File != filepath.Join(sched, "scheduler.py") {
		t.Errorf("the observer recorded %+v, want pid %d holding 9", r, core.Process.Pid)
	}
	i := slices.IndexFunc(p.Procs, func(pr srpfProbeProc) bool { return pr.PID == core.Process.Pid })
	if i < 0 || p.Procs[i].Starvation == nil || *p.Procs[i].Starvation != "3" {
		t.Errorf("/proc was expected to keep the exec-time 3, which is why the record is needed: %+v", p.Procs)
	}
	// Under the arm that set 3, with every environment /proc shows carrying 3, this record is what refuses it.
	arm := SRPFArm{Name: "srpf-s3", Policy: "fcfs", SRPF: true, Starvation: 3}
	var fake srpfProbe
	_ = json.Unmarshal(lastLine([]byte(srpfProbeJSON(new("1"), new("3"), 170000))), &fake)
	r.PID, r.File = 97, srpfFakePath
	fake.Schedulers = []srpfSchedulerRecord{r}
	b, _ := json.Marshal(fake)
	if err := srpfProbeRefusal(arm, srpfFakePath, true, b); err == nil || !strings.Contains(err.Error(), "holds 9") {
		t.Errorf("an engine core holding 9 under arm srpf-s3 was not refused for it: %v", err)
	}
}

func runPython(t *testing.T, py string, env []string, script string) ([]byte, error) {
	t.Helper()
	cmd := exec.Command(py, "-c", script)
	cmd.Env, cmd.Dir = env, t.TempDir()
	return cmd.CombinedOutput()
}

// srpfRow is a completed raw row on the replay clock, latencies in ms from the schedule.
func srpfRow(tr TraceRow, ttftMs, lastMs float64, tokens int) RawRow {
	intended := tr.OffsetMs * int64(time.Millisecond)
	at := func(ms float64) *int64 { v := intended + int64(ms*float64(time.Millisecond)); return &v }
	return RawRow{
		Index: tr.Index, Study: StudySRPF58420Threshold, Arm: "fcfs", TraceChecksum: SRPFSweepTraceChecksum, Tenant: tr.Tenant, ScheduledOffsetMs: tr.OffsetMs, HTTPStatus: 200, StreamTerminated: true,
		EngineUsageReported: new(true), EngineOutputTokens: tokens, EngineInputTokens: tr.ExactInputTokens,
		Clock: &RequestClock{IntendedNanos: &intended, SendNanos: at(0.5), FirstContentNanos: at(ttftMs), LastContentNanos: at(lastMs)},
	}
}

// The figures are measured from the schedule, a failure counts at +Inf, and a record that is not the trace's is refused.
// Mutation that turns this red: measure TTFT from SendNanos instead of IntendedNanos.
func TestSRPFSweepFigures(t *testing.T) {
	trace := []TraceRow{
		{Index: 0, OffsetMs: 0, Tenant: PremiumTenant, MaxOutputTokens: 64, ExactInputTokens: 68},
		{Index: 1, OffsetMs: 10, Tenant: NoisyTenant, MaxOutputTokens: 16, ExactInputTokens: 7695},
		{Index: 2, OffsetMs: 20, Tenant: PremiumTenant, MaxOutputTokens: 64, ExactInputTokens: 68},
		{Index: 3, OffsetMs: 30, Tenant: PremiumTenant, MaxOutputTokens: 64, ExactInputTokens: 68},
		{Index: 4, OffsetMs: 40, Tenant: NoisyTenant, MaxOutputTokens: 16, ExactInputTokens: 7695},
	}
	rows := []RawRow{
		srpfRow(trace[0], 100, 900, 64),
		srpfRow(trace[1], 2000, 3000, 16),
		srpfRow(trace[2], 300, 900, 64),
		srpfRow(trace[3], 200, 900, 63),
		srpfRow(trace[4], 1000, 5000, 16),
	}
	rows[4].EngineInputTokens = 7700
	f, err := SRPFSweepFigures("fcfs", trace, rows)
	if err != nil {
		t.Fatal(err)
	}
	if f.PremiumTTFTP50.String() != "300.0" || !f.PremiumTTFTP99.Infinite {
		t.Errorf("premium TTFT p50 %s p99 %s, want 300.0 and +Inf (the 63-token row failed)", f.PremiumTTFTP50, f.PremiumTTFTP99)
	}
	if f.ContenderE2EP50.String() != "3000.0" || f.ContenderE2EP95.String() != "5000.0" {
		t.Errorf("contender e2e p50 %s p95 %s, want 3000.0 and 5000.0", f.ContenderE2EP50, f.ContenderE2EP95)
	}
	if f.Premium.Completed != 2 || f.Premium.Failed != 1 || f.Premium.FailedBy["output-tokens"] != 1 || f.Contender.Completed != 2 {
		t.Errorf("counts %+v %+v", f.Premium, f.Contender)
	}
	if f.MaxDispatchLagMs != 0.5 || f.InputTokenMismatches != 1 {
		t.Errorf("lag %g ms and %d mismatches, want 0.5 and 1", f.MaxDispatchLagMs, f.InputTokenMismatches)
	}

	refused := map[string][]RawRow{
		"a missing row": rows[:4],
		"a doubled row": append(slices.Clone(rows[:4]), rows[0]),
		"a row of another tenant": func() []RawRow {
			r := slices.Clone(rows)
			r[1].Tenant = PremiumTenant
			return r
		}(),
		"a row of another arm": func() []RawRow {
			r := slices.Clone(rows)
			r[3].Arm = "srpf"
			return r
		}(),
		"a row of another trace": func() []RawRow {
			r := slices.Clone(rows)
			r[0].TraceChecksum = "x"
			return r
		}(),
		"a row off its schedule": func() []RawRow {
			r := slices.Clone(rows)
			c := *r[2].Clock
			c.IntendedNanos = new(*c.IntendedNanos + int64(time.Second))
			r[2].Clock = &c
			return r
		}(),
		"a row without its clock": func() []RawRow {
			r := slices.Clone(rows)
			r[2].Clock = nil
			return r
		}(),
	}
	for name, r := range refused {
		if _, err := SRPFSweepFigures("fcfs", trace, r); err == nil {
			t.Errorf("%s was scored", name)
		}
	}
	timeout := slices.Clone(rows)
	timeout[1] = RawRow{Index: 1, Study: StudySRPF58420Threshold, Arm: "fcfs", TraceChecksum: SRPFSweepTraceChecksum, Tenant: NoisyTenant, ScheduledOffsetMs: 10, ErrorKind: "timeout", Clock: &RequestClock{IntendedNanos: rows[1].Clock.IntendedNanos}}
	f, err = SRPFSweepFigures("fcfs", trace, timeout)
	if err != nil || !f.ContenderE2EP95.Infinite || f.Contender.FailedBy["timeout"] != 1 {
		t.Errorf("a timed-out contender gave %+v (%v)", f, err)
	}
}

// An absent counter is reported absent, never as zero preemptions.
// Mutation that turns this red: return found=true from PromSum when nothing matched.
func TestPreemptionDelta(t *testing.T) {
	before := "# TYPE vllm:num_preemptions_total counter\nvllm:num_preemptions_total{model_name=\"q\"} 3.0\nvllm:num_preemptions_created{model_name=\"q\"} 1.7e9\n"
	after := "vllm:num_preemptions_total{model_name=\"q\"} 10.0\nvllm:num_preemptions_created{model_name=\"q\"} 1.7e9\n"
	if d, name, err := PreemptionDelta(before, after); err != nil || d != 7 || name != "vllm:num_preemptions_total" {
		t.Errorf("delta %g under %q (%v), want 7", d, name, err)
	}
	if _, _, err := PreemptionDelta("vllm:num_requests_running 0\n", after); err == nil {
		t.Error("a missing counter gave a delta")
	}
	if _, _, err := PreemptionDelta(after, before); err == nil {
		t.Error("a counter that fell gave a delta")
	}
	if v, ok := PromSum("vllm:num_requests_waiting 2\nvllm:num_requests_waiting_by_reason 9\n", "vllm:num_requests_waiting"); !ok || v != 2 {
		t.Errorf("PromSum read %g (%t), want 2 from the exact name only", v, ok)
	}
}

// The arm's manifest is the diagnostic's frozen load under this study's name, and it loads as the replay will load it.
// Mutation that turns this red: keep the archived study in ArmManifest.
func TestArmManifestLoadsAsTheReplayLoadsIt(t *testing.T) {
	archived, err := os.ReadFile(filepath.Join(srpfDiagnosticDir, "manifest-off-3.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	trace, err := filepath.Abs(filepath.Join(srpfDiagnosticDir, "trace-off-3.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	m, err := ArmManifest(archived, "srpf-s3", trace, "http://127.0.0.1:8000")
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "manifest.yaml")
	if err := WriteManifestFile(path, m); err != nil {
		t.Fatal(err)
	}
	got, err := LoadManifest(path)
	if err != nil {
		t.Fatal(err)
	}
	if got.Study != StudySRPF58420Threshold || got.Arm != "srpf-s3" || got.Seed != SRPFSweepTraceSeed || got.GatewaySHA != "" ||
		got.ImageDigests["engine"] != SRPFSweepImage || got.TimeoutMs != 30000 || got.GatewayURL != "http://127.0.0.1:8000" {
		t.Errorf("manifest %+v", got)
	}
	other, err := os.ReadFile(filepath.Join(srpfDiagnosticDir, "manifest-off-1.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ArmManifest(other, "srpf-s5", trace, "http://x"); err == nil {
		t.Error("the manifest of another seed was accepted")
	}
	// Run 8's arm names are not this sweep's, so its srpf arm cannot be replayed under this study.
	for _, arm := range []string{"srpf-t512", "srpf", "srpf-t384"} {
		if _, err := ArmManifest(archived, arm, trace, "http://x"); err == nil {
			t.Errorf("the unregistered arm %s was accepted", arm)
		}
	}
}

// srpfFake is a Docker and an engine for the whole sweep, with no container and no GPU.
type srpfFake struct {
	mu          sync.Mutex
	running     map[string]bool
	argsByID    map[string][]string
	starts      int
	preemptions int
	replays     []string
	removed     []string
	pulls       []string
	// requestIDs are the X-Request-Id headers the engine received.
	requestIDs []string
	// wrongEnvArm makes that arm's container report the SRPF variable it should not have.
	wrongEnvArm string
	// defaultStarvationArm makes that arm's engine core hold the PR's default threshold while its parent carried the arm's.
	defaultStarvationArm string
	// versionHangs makes the version probe print its version and then run past its bound, as `vllm --version` did.
	versionHangs bool
	// promptTokens, when set, is the prompt length the engine reports for every request instead of the trace's.
	promptTokens int
	// replayPromptTokens, when set, is the prompt length every replayed row records instead of the trace's.
	replayPromptTokens *int
}

const srpfFakePath = "/usr/lib/python3/dist-packages/vllm/v1/core/sched/scheduler.py"

func (f *srpfFake) docker(_ context.Context, _ string, args ...string) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	joined := strings.Join(args, " ")
	switch {
	case args[0] == "image" && args[1] == "inspect":
		return nil, errors.New("error: no such image: " + args[len(args)-1])
	case args[0] == "pull":
		f.pulls = append(f.pulls, args[len(args)-1])
		return []byte("pulled\n"), nil
	case args[0] == "run" && args[1] == "--rm":
		switch {
		case strings.Contains(joined, "find_spec(\"vllm\").origin), \"v1\"") && !strings.Contains(joined, "import vllm.v1"):
			return fmt.Appendf(nil, `{"file": %q, "sha256": %q}`+"\n", srpfFakePath, SRPFSweepBaseSchedulerSHA256), nil
		case strings.Contains(joined, "import vllm.v1.core.sched.scheduler"):
			if !strings.Contains(joined, "srpf_observe.py:") || !strings.Contains(joined, "zz_srpf_observe.pth:") {
				return []byte(`{"error": "the observer is not mounted"}` + "\n"), nil
			}
			return fmt.Appendf(nil, `{"file": %q, "sha256": %q, "size": 170000, "srpfKey": true, "observed": true, "schedulers": [], "env": null, "pycachePrefix": %q, "procs": []}`+"\n",
				srpfFakePath, SRPFSweepPRSchedulerSHA256, srpfSweepPycachePrefix), nil
		case strings.Contains(joined, "importlib.metadata"):
			if f.versionHangs {
				return []byte("0.34.0rc1.dev527+g5039f736e\n"), context.DeadlineExceeded
			}
			return []byte("0.34.0rc1.dev527+g5039f736e\n"), nil
		case strings.Contains(joined, "snapshot_download"):
			return []byte("/root/.cache/huggingface/hub/snapshot\n"), nil
		}
	case args[0] == "run" && args[1] == "--detach":
		f.starts++
		id := fmt.Sprintf("cid-%d", f.starts)
		f.running[id], f.argsByID[id] = true, slices.Clone(args)
		return []byte(id + "\n"), nil
	case args[0] == "inspect":
		if f.running[args[len(args)-1]] {
			return []byte("running\n"), nil
		}
		// Docker before 29 capitalises its not-found answer and Docker 29 does not, so the fake speaks both.
		return nil, errors.New("Error: No such object: " + args[len(args)-1])
	case args[0] == "exec":
		run := f.argsByID[args[1]]
		var env *string
		if slices.Contains(run, "--env=VLLM_ENABLE_SRPF=1") || slices.Contains(run, "--name=srpf-"+f.wrongEnvArm) {
			env = new("1")
		}
		// The container reports the threshold its run args set.
		var starvation *string
		for _, a := range run {
			if v, ok := strings.CutPrefix(a, "--env="+SRPFSweepStarvationEnv+"="); ok {
				starvation = new(v)
			}
		}
		out := srpfProbeJSON(env, starvation, 170000)
		// The arm told to lose its threshold keeps it in every environment /proc shows, and its scheduler holds the default.
		if slices.Contains(run, "--name=srpf-"+f.defaultStarvationArm) {
			var p srpfProbe
			_ = json.Unmarshal(lastLine([]byte(out)), &p)
			p.Schedulers[0].Threshold = json.RawMessage("5")
			b, _ := json.Marshal(p)
			out = string(b) + "\n"
		}
		return []byte(out), nil
	case args[0] == "rm":
		delete(f.running, args[len(args)-1])
		f.removed = append(f.removed, args[len(args)-1])
		return nil, nil
	}
	return nil, fmt.Errorf("unexpected docker %v", args)
}

// logs is the engine's log for the container: its non-default args as vLLM prints them, and the chunked-prefill line.
func (f *srpfFake) logs(_ context.Context, id string) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	args := f.argsByID[id]
	line := "INFO non-default args: {'model_tag': 'Qwen/Qwen2.5-3B-Instruct', 'max_num_batched_tokens': 512"
	if slices.Contains(args, "--scheduling-policy=priority") {
		line += ", 'scheduling_policy': 'priority'"
	}
	if slices.Contains(args, "--long-prefill-token-threshold=384") {
		line += ", 'long_prefill_token_threshold': 384"
	}
	return []byte(line + "}\nINFO " + srpfChunkedPrefillLine + "\n"), nil
}

// exec stands in for the replay subcommand: it loads the manifest as the replay does and writes one completed row per trace row.
func (f *srpfFake) exec(_ context.Context, _ string, args ...string) ([]byte, error) {
	flag := func(name string) string { return args[slices.Index(args, name)+1] }
	m, err := LoadManifest(flag("--manifest"))
	if err != nil {
		return nil, err
	}
	trace, err := ReadTraceFileVerified(m.TracePath, m.TraceChecksum)
	if err != nil {
		return nil, err
	}
	var b strings.Builder
	for _, tr := range trace {
		row := srpfRow(tr, 50, 900, tr.MaxOutputTokens)
		row.Arm, row.Study = m.Arm, m.Study
		if f.replayPromptTokens != nil {
			row.EngineInputTokens = *f.replayPromptTokens
		}
		line, _ := json.Marshal(row)
		b.Write(line)
		b.WriteByte('\n')
	}
	if err := os.WriteFile(flag("--raw-out"), []byte(b.String()), 0o600); err != nil {
		return nil, err
	}
	f.mu.Lock()
	f.preemptions += 2
	f.replays = append(f.replays, m.Arm+" "+flag("--priorities"))
	f.mu.Unlock()
	return []byte("replayed\n"), nil
}

func (f *srpfFake) engine(t *testing.T) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(http.ResponseWriter, *http.Request) {})
	for path, body := range identityAnswers {
		if path == "/metrics" {
			continue
		}
		mux.HandleFunc(path, func(w http.ResponseWriter, _ *http.Request) { _, _ = io.WriteString(w, body) })
	}
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, _ *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		_, _ = fmt.Fprintf(w, "vllm:num_requests_running{m=\"q\"} 0\nvllm:num_requests_waiting{m=\"q\"} 0\nvllm:num_preemptions_total{m=\"q\"} %d\n", f.preemptions)
	})
	mux.HandleFunc("/v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			MaxTokens int  `json:"max_tokens"`
			Priority  *int `json:"priority"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.mu.Lock()
		f.requestIDs = append(f.requestIDs, r.Header.Get("X-Request-Id"))
		f.mu.Unlock()
		if body.Priority == nil {
			http.Error(w, "no priority", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, `data: {"choices":[{"delta":{"content":"a"}}]}`+"\n\n")
		// The trace's premium requests are 68 tokens with 64 out, and its contender requests 7,695 with 16 out.
		prompt := 68
		if body.MaxTokens == 16 {
			prompt = 7695
		}
		if f.promptTokens != 0 {
			prompt = f.promptTokens
		}
		_, _ = fmt.Fprintf(w, "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":%d,\"completion_tokens\":%d}}\n\n", prompt, body.MaxTokens)
		_, _ = io.WriteString(w, "data: [DONE]\n\n")
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func srpfSweepAgainst(t *testing.T, f *srpfFake) *SRPFSweep {
	t.Helper()
	f.running, f.argsByID = map[string]bool{}, map[string][]string{}
	srv := f.engine(t)
	root := t.TempDir()
	out := filepath.Join(root, "out")
	if err := os.Mkdir(out, 0o700); err != nil {
		t.Fatal(err)
	}
	overlay := filepath.Join(root, "scheduler.py")
	abs := func(p string) string { a, _ := filepath.Abs(p); return a }
	return &SRPFSweep{
		Docker: f.docker, Exec: f.exec, Self: "/opt/srpf/benchharness",
		HFCache: filepath.Join(root, "hf"), CompileRoot: filepath.Join(root, "compile"), Overlay: overlay,
		Trace: abs(filepath.Join(srpfDiagnosticDir, "trace-off-3.jsonl")), ArchivedManifest: abs(filepath.Join(srpfDiagnosticDir, "manifest-off-3.yaml")),
		Out: out, Port: 8000, EngineURL: srv.URL,
		Health: &http.Client{Timeout: time.Second},
		Logs:   f.logs, PollEvery: 5 * time.Millisecond, StateEvery: 50 * time.Millisecond,
		NewSender: func(url string) (*HTTPSender, error) {
			return NewHTTPSender(url, SRPFSweepModel, nil, 5*time.Second, SenderConn{}), nil
		},
	}
}

// The sweep refuses an overlay that is not the PR head's scheduler before it pulls anything.
// Mutation that turns this red: drop the overlay checksum from refuse.
func TestSRPFSweepRefusesAnOverlayThatIsNotThePRHead(t *testing.T) {
	f := &srpfFake{}
	s := srpfSweepAgainst(t, f)
	if err := os.WriteFile(s.Overlay, []byte("# not the PR\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := s.Run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "not the PR head's scheduler") || f.starts != 0 {
		t.Errorf("run with a wrong overlay: %v after %d starts", err, f.starts)
	}
}

// The archived manifest is checked before the pull, so one of another block cannot reach the paid steps.
// Mutation that turns this red: remove the ArmManifest loop from refuse.
func TestSRPFSweepRefusesAnotherBlocksManifestBeforeThePull(t *testing.T) {
	f := &srpfFake{}
	s := srpfSweepAgainst(t, f)
	s.ArchivedManifest = strings.Replace(s.ArchivedManifest, "manifest-off-3.yaml", "manifest-off-1.yaml", 1)
	_, err := s.Run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "not seed 853") || len(f.pulls) != 0 {
		t.Errorf("run with block 1's manifest: %v after %d pulls", err, len(f.pulls))
	}
}

// One sweep against the fakes: every arm in the frozen order on its own engine, an arm whose container carries the
// wrong SRPF setting and one whose engine runs the default threshold failed before any request, and every container removed.
// Mutation that turns this red: skip srpfProbeRefusal in measureArm.
func TestSRPFSweepRunsEveryArmAndFailsAContaminatedOne(t *testing.T) {
	f := &srpfFake{wrongEnvArm: "fcfs", defaultStarvationArm: "srpf-s8"}
	s := srpfSweepAgainst(t, f)
	// The PR's scheduler is not in the repository, so the sweep is driven from just after its refusals.
	sum, err := s.run(context.Background(), SRPFSweepSummary{Study: StudySRPF58420Threshold, Arms: []SRPFArmResult{}}, SRPFSweepOrder(SRPFSweepOrderSeed))
	if err != nil {
		t.Fatal(err)
	}
	id := sum.Image
	if id.SchedulerPath != srpfFakePath || id.VLLMVersion != "0.34.0rc1.dev527+g5039f736e" || id.OverlaidSHA256 != SRPFSweepPRSchedulerSHA256 {
		t.Errorf("image identity %+v", id)
	}
	results := sum.Arms
	if len(results) != 7 {
		t.Fatalf("%d arm results", len(results))
	}
	for _, name := range []string{"summary.json", "arm-srpf-s2.json", "arm-srpf-s2.pre-replay.json", "start-srpf-s2-1.pre-replay.engine.log", "raw-srpf-s2.jsonl"} {
		if _, err := os.Stat(filepath.Join(s.Out, name)); err != nil {
			t.Errorf("the sweep did not write %s: %v", name, err)
		}
	}
	for _, res := range results {
		switch res.Name {
		case "fcfs":
			if res.Outcome != "failed" || !strings.Contains(res.Reason, "must not set VLLM_ENABLE_SRPF") || res.RawFile != "" {
				t.Errorf("the contaminated fcfs arm was %s (%s), raw %q", res.Outcome, res.Reason, res.RawFile)
			}
		case "srpf-s8":
			if res.Outcome != "failed" || !strings.Contains(res.Reason, "needs srpf_starvation_threshold 8") || res.RawFile != "" {
				t.Errorf("the srpf-s8 arm on the default threshold was %s (%s), raw %q", res.Outcome, res.Reason, res.RawFile)
			}
		default:
			if res.Outcome != "measured" || res.Figures == nil || res.Preemptions == nil || *res.Preemptions != 2 {
				t.Errorf("arm %s was %s (%s), preemptions %v", res.Name, res.Outcome, res.Reason, res.Preemptions)
				continue
			}
			if res.Figures.Premium.Failed != 0 || res.Figures.Premium.Rows != 3917 || res.Figures.Contender.Rows != 185 ||
				res.Figures.PremiumTTFTP99.String() != "50.0" || len(res.Warmup) != 2 {
				t.Errorf("arm %s figures %+v, %d warm-up rows", res.Name, res.Figures, len(res.Warmup))
			}
			// Mutation that turns this red: leave EngineCoreEnv unset in measureArm.
			want := "srpf_starvation_threshold=5 with VLLM_ENABLE_SRPF=unset " + SRPFSweepStarvationEnv + "=unset"
			if res.SRPF {
				want = fmt.Sprintf("srpf_starvation_threshold=%d with VLLM_ENABLE_SRPF=\"1\" %s=%q", res.Starvation, SRPFSweepStarvationEnv, strconv.Itoa(res.Starvation))
			}
			if !strings.HasPrefix(res.EngineCoreEnv, "VLLM::EngineCore 97 initialised ") || !strings.HasSuffix(res.EngineCoreEnv, want) {
				t.Errorf("arm %s recorded its engine core's environment as %q, want it ending %s", res.Name, res.EngineCoreEnv, want)
			}
		}
	}
	want := []string{"priority", "srpf-s10", "srpf-s2", "srpf-s5", "srpf-s3"}
	for i, rep := range f.replays {
		if rep != want[i]+" "+SRPFSweepPriorities {
			t.Errorf("replay %d was %q, want %s with the priorities", i, rep, want[i])
		}
	}
	// Mutation that turns this red: drop SetRequestIDPrefix from warmup.
	if !slices.Contains(f.requestIDs, "warmup-srpf-s2-0") || !slices.Contains(f.requestIDs, "warmup-srpf-s2-1") || slices.Contains(f.requestIDs, "") {
		t.Errorf("the warm-up sent request IDs %v, not the ones its rows record", f.requestIDs)
	}
	if len(f.replays) != len(want) || len(f.running) != 0 || len(f.removed) != 7 {
		t.Errorf("%d replays, %d containers left running, %d removed", len(f.replays), len(f.running), len(f.removed))
	}
}

// A version probe that prints its version and then runs past its bound only loses the record, as on 2026-11-16 when
// `vllm --version` ended a paid run at this step.
// Mutation that turns this red: return the version probe's error from imageIdentity.
func TestSRPFSweepImageIdentitySurvivesAVersionProbeThatDoesNotExit(t *testing.T) {
	f := &srpfFake{versionHangs: true}
	s := srpfSweepAgainst(t, f)
	id, err := s.imageIdentity(context.Background())
	if err != nil {
		t.Fatalf("image identity failed on the version probe: %v", err)
	}
	if !strings.HasPrefix(id.VLLMVersion, "unread: ") || id.OverlaidSHA256 != SRPFSweepPRSchedulerSHA256 {
		t.Errorf("image identity %+v, want the scheduler checks kept and the version marked unread", id)
	}
}

// The trace's prompt lengths are frozen for this model and template, so an engine that counts them otherwise ran another workload.
// Mutation that turns this red: drop the warm-up's prompt-length check.
func TestSRPFSweepFailsAnArmWhoseWarmupPromptIsAnotherLength(t *testing.T) {
	f := &srpfFake{promptTokens: 68}
	s := srpfSweepAgainst(t, f)
	sum, err := s.run(context.Background(), SRPFSweepSummary{Study: StudySRPF58420Threshold, Arms: []SRPFArmResult{}}, SRPFSweepOrder(SRPFSweepOrderSeed))
	if err != nil {
		t.Fatal(err)
	}
	for _, res := range sum.Arms {
		if res.Outcome == "measured" || !strings.Contains(res.Reason, "standard-noisy warm-up's prompt was 68 tokens to the engine, and the trace's is 7695") {
			t.Errorf("arm %s was %s (%s), want it failed on the contender warm-up's prompt length", res.Name, res.Outcome, res.Reason)
		}
	}
	if len(f.replays) != 0 {
		t.Errorf("arms with another workload were replayed: %v", f.replays)
	}
}

// A replay whose rows report another prompt length keeps its rows but is not measured, and a reported zero counts as one.
// Mutations that turn this red: drop the measured outcome's mismatch check, or count only nonzero reported lengths.
func TestSRPFSweepDoesNotMeasureAReplayOfAnotherLength(t *testing.T) {
	for _, tokens := range []int{0, 7700} {
		f := &srpfFake{replayPromptTokens: new(tokens)}
		s := srpfSweepAgainst(t, f)
		sum, err := s.run(context.Background(), SRPFSweepSummary{Study: StudySRPF58420Threshold, Arms: []SRPFArmResult{}}, SRPFSweepOrder(SRPFSweepOrderSeed))
		if err != nil {
			t.Fatal(err)
		}
		for _, res := range sum.Arms {
			if res.Name == "fcfs" && res.RawFile == "" {
				continue
			}
			if res.Outcome == "measured" || !strings.Contains(res.Reason, "rows' prompts were another length") || res.RawFile == "" {
				t.Errorf("rows of %d tokens: arm %s was %s (%s), raw %q", tokens, res.Name, res.Outcome, res.Reason, res.RawFile)
			}
		}
	}
}
