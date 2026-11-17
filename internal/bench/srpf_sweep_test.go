package bench

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
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
	if SRPFSweepArmBound != 1260*time.Second || SRPFSweepBound != 11460*time.Second {
		t.Errorf("the arm bound is %s and the sweep bound %s; the session's stop was sized for 1260 s and 11460 s", SRPFSweepArmBound, SRPFSweepBound)
	}
}

// The order is frozen before the run, so a reader can check it was not chosen after the results.
// Mutation that turns this red: drop the alternation rule in srpfBalanced.
func TestSRPFSweepOrderIsCounterbalancedAndFixed(t *testing.T) {
	var names []string
	order := SRPFSweepOrder(SRPFSweepOrderSeed)
	for _, a := range order {
		names = append(names, a.Name)
	}
	want := []string{"fcfs-t384", "srpf", "priority-t384", "priority", "srpf-t384", "fcfs"}
	if !slices.Equal(names, want) {
		t.Fatalf("order %v, want %v", names, want)
	}
	if !srpfBalanced(order) {
		t.Errorf("order %v does not alternate the threshold or run each policy once per half", names)
	}
	sorted := slices.Clone(names)
	slices.Sort(sorted)
	all := SRPFSweepArmNames()
	slices.Sort(all)
	if !slices.Equal(sorted, all) {
		t.Errorf("order %v is not a permutation of the arms %v", names, all)
	}
}

// Each arm's engine differs from the earlier runs' only by its policy, its threshold and the SRPF variable.
// Mutation that turns this red: add the SRPF variable whenever Policy is fcfs.
func TestSRPFSweepRunArgsDifferOnlyByTheArm(t *testing.T) {
	s := &SRPFSweep{HFCache: "/hf", CompileRoot: "/compile", Overlay: "/opt/srpf/scheduler.py", Port: 8000}
	const path = "/usr/local/lib/python3.12/dist-packages/vllm/v1/core/sched/scheduler.py"
	args, err := s.RunArgs(SRPFArm{Name: "srpf-t384", Policy: "fcfs", Threshold: 384, SRPF: true}, path)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"run", "--detach", "--name=srpf-srpf-t384", "--gpus=all", "--shm-size=1g", "--workdir=/",
		"--env=VLLM_SERVER_DEV_MODE=1", "--env=PYTHONPYCACHEPREFIX=/tmp/srpf-pycache", "--env=VLLM_ENABLE_SRPF=1",
		"--publish=127.0.0.1:8000:8000", "--volume=/hf:/root/.cache/huggingface", "--volume=/compile/srpf-t384:/root/.cache/vllm",
		"--volume=/opt/srpf/scheduler.py:" + path + ":ro", "--label=study=srpf-sweep", "--entrypoint=env", SRPFSweepImage, "-u", "VLLM_GPU_SYNC_CHECK", "vllm", "serve",
		"Qwen/Qwen2.5-3B-Instruct", "--dtype=half", "--max-model-len=16384", "--max-num-seqs=64", "--gpu-memory-utilization=0.90",
		"--no-enable-prefix-caching", "--max-num-batched-tokens=512", "--scheduling-policy=fcfs", "--no-async-scheduling",
		"--port=8000", "--served-model-name=Qwen/Qwen2.5-3B-Instruct", "--revision=" + SRPFSweepRevision,
		"--tokenizer-revision=" + SRPFSweepRevision, "--long-prefill-token-threshold=384",
	}
	if !slices.Equal(args, want) {
		t.Errorf("srpf-t384 runs\n%q\nwant\n%q", args, want)
	}
	rel := engineargs.Releases()[platformv1.VLLMReleaseV0271]
	for _, a := range SRPFSweepArms() {
		args, err := s.RunArgs(a, path)
		if err != nil {
			t.Fatal(err)
		}
		if got := slices.Contains(args, "--env=VLLM_ENABLE_SRPF=1"); got != a.SRPF {
			t.Errorf("%s sets the SRPF variable: %t", a.Name, got)
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

// srpfProbeJSON is a serving probe's answer for the PR's scheduler, with env for every process.
func srpfProbeJSON(env *string, pycSize int64) string {
	p := srpfProbe{
		File: srpfFakePath, SHA256: SRPFSweepPRSchedulerSHA256, Size: 170000, SRPFKey: true,
		Env: env, PycachePrefix: new(srpfSweepPycachePrefix), PycFlags: new(int64(0)), PycSourceSize: new(pycSize),
		Procs: []srpfProbeProc{{PID: 1, EnvCount: 12, Cmd: "vllm serve", Env: env, PycachePrefix: new(srpfSweepPycachePrefix)}},
	}
	b, _ := json.Marshal(p)
	return "WARNING noise\n" + string(b) + "\n"
}

// The probe is what stops a wrong build or a wrong SRPF setting from being measured under an arm's name.
// Mutation that turns this red: drop the pyc size comparison in srpfProbeRefusal.
func TestSRPFProbeRefusal(t *testing.T) {
	const path = srpfFakePath
	srpf, fcfs := SRPFArm{Name: "srpf", Policy: "fcfs", SRPF: true}, SRPFArm{Name: "fcfs", Policy: "fcfs"}
	one := new("1")
	if err := srpfProbeRefusal(srpf, path, true, []byte(srpfProbeJSON(one, 170000))); err != nil {
		t.Errorf("a conforming srpf probe was refused: %v", err)
	}
	if err := srpfProbeRefusal(fcfs, path, true, []byte(srpfProbeJSON(nil, 170000))); err != nil {
		t.Errorf("a conforming fcfs probe was refused: %v", err)
	}
	mutate := func(f func(p *srpfProbe)) []byte {
		var p srpfProbe
		_ = json.Unmarshal(lastLine([]byte(srpfProbeJSON(one, 170000))), &p)
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
		{"srpf arm without the variable", srpf, []byte(srpfProbeJSON(nil, 170000)), true, "needs VLLM_ENABLE_SRPF=1"},
		{"fcfs arm with the variable", fcfs, []byte(srpfProbeJSON(one, 170000)), true, "must not set VLLM_ENABLE_SRPF"},
		{"the merge base's scheduler", srpf, mutate(func(p *srpfProbe) { p.SHA256 = SRPFSweepBaseSchedulerSHA256 }), true, "not the PR head's"},
		{"another file", srpf, mutate(func(p *srpfProbe) { p.File = "/vllm-workspace/vllm/v1/core/sched/scheduler.py" }), true, "not the overlaid"},
		{"the server compiled another source", srpf, mutate(func(p *srpfProbe) { p.PycSourceSize = new(int64(160000)) }), true, "compiled a scheduler of 160000 bytes"},
		{"no server bytecode", srpf, mutate(func(p *srpfProbe) { p.PycSourceSize, p.PycFlags = nil, nil }), true, "no server process wrote bytecode"},
		{"a process without the variable", srpf, mutate(func(p *srpfProbe) {
			p.Procs = append(p.Procs, srpfProbeProc{PID: 7, PPID: 1, EnvCount: 12, Cmd: "EngineCore", PycachePrefix: new(srpfSweepPycachePrefix)})
		}), true, "process 7"},
		// An unreadable environment is excused only through a readable, checked ancestor.
		{"an unreadable process with no readable ancestor", srpf, mutate(func(p *srpfProbe) {
			p.Procs = append(p.Procs, srpfProbeProc{PID: 8, PPID: 99, Cmd: "VLLM::EngineCore"})
		}), true, "no ancestor"},
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
	// vLLM's engine core renames itself with setproctitle, which leaves /proc showing no environment, as on 2026-11-16.
	renamed := mutate(func(p *srpfProbe) {
		p.Procs = append(p.Procs, srpfProbeProc{PID: 97, PPID: 1, Cmd: "VLLM::EngineCore"})
	})
	if err := srpfProbeRefusal(srpf, path, true, renamed); err != nil {
		t.Errorf("an engine core renamed under a checked server was refused: %v", err)
	}
	// Before any server ran, the image check has no bytecode or process to read.
	if err := srpfProbeRefusal(SRPFArm{Name: "image"}, path, false, mutate(func(p *srpfProbe) {
		p.Env, p.PycSourceSize, p.PycFlags, p.Procs = nil, nil, nil, nil
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
	env := append(os.Environ(), "PYTHONPATH="+filepath.Join(root, "site"), "PYTHONPYCACHEPREFIX="+prefix, "VLLM_ENABLE_SRPF=1")

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
	if p.Size != int64(len(src)) || !p.SRPFKey || p.Env == nil || *p.Env != "1" {
		t.Errorf("the probe reported %+v", p)
	}

	// A "server" that imported the scheduler and stays up, as the engine core does.
	if err := os.RemoveAll(prefix); err != nil {
		t.Fatal(err)
	}
	server := exec.Command(py, "-c", "import sys, vllm.v1.core.sched.scheduler; print('up', flush=True); sys.stdin.read()")
	server.Env = append(slices.Clone(env), "VLLM_GPU_SYNC_CHECK=error")
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
	if i < 0 || p.Procs[i].Env == nil || *p.Procs[i].Env != "1" || p.Procs[i].PycachePrefix == nil || *p.Procs[i].PycachePrefix != prefix ||
		p.Procs[i].SyncCheck == nil || *p.Procs[i].SyncCheck != "error" {
		t.Errorf("the probe did not report the server's environment: %+v", p.Procs)
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
		Index: tr.Index, Study: StudySRPF58420, Arm: "fcfs", TraceChecksum: SRPFSweepTraceChecksum, Tenant: tr.Tenant, ScheduledOffsetMs: tr.OffsetMs, HTTPStatus: 200, StreamTerminated: true,
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
	timeout[1] = RawRow{Index: 1, Study: StudySRPF58420, Arm: "fcfs", TraceChecksum: SRPFSweepTraceChecksum, Tenant: NoisyTenant, ScheduledOffsetMs: 10, ErrorKind: "timeout", Clock: &RequestClock{IntendedNanos: rows[1].Clock.IntendedNanos}}
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
	m, err := ArmManifest(archived, "srpf-t384", trace, "http://127.0.0.1:8000")
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
	if got.Study != StudySRPF58420 || got.Arm != "srpf-t384" || got.Seed != SRPFSweepTraceSeed || got.GatewaySHA != "" ||
		got.ImageDigests["engine"] != SRPFSweepImage || got.TimeoutMs != 30000 || got.GatewayURL != "http://127.0.0.1:8000" {
		t.Errorf("manifest %+v", got)
	}
	other, err := os.ReadFile(filepath.Join(srpfDiagnosticDir, "manifest-off-1.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ArmManifest(other, "srpf", trace, "http://x"); err == nil {
		t.Error("the manifest of another seed was accepted")
	}
	if _, err := ArmManifest(archived, "srpf-t512", trace, "http://x"); err == nil {
		t.Error("an unregistered arm was accepted")
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
	// versionHangs makes the version probe print its version and then run past its bound, as `vllm --version` did.
	versionHangs bool
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
			return fmt.Appendf(nil, `{"file": %q, "sha256": %q, "size": 170000, "srpfKey": true, "env": null, "pycachePrefix": %q, "procs": []}`+"\n",
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
		return []byte(srpfProbeJSON(env, 170000)), nil
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
		_, _ = fmt.Fprintf(w, "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":68,\"completion_tokens\":%d}}\n\n", body.MaxTokens)
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
// wrong SRPF setting failed before any request, and every container removed.
// Mutation that turns this red: skip srpfProbeRefusal in measureArm.
func TestSRPFSweepRunsEveryArmAndFailsAContaminatedOne(t *testing.T) {
	f := &srpfFake{wrongEnvArm: "fcfs"}
	s := srpfSweepAgainst(t, f)
	// The PR's scheduler is not in the repository, so the sweep is driven from just after its refusals.
	sum, err := s.run(context.Background(), SRPFSweepSummary{Study: StudySRPF58420, Arms: []SRPFArmResult{}}, SRPFSweepOrder(SRPFSweepOrderSeed))
	if err != nil {
		t.Fatal(err)
	}
	id := sum.Image
	if id.SchedulerPath != srpfFakePath || id.VLLMVersion != "0.34.0rc1.dev527+g5039f736e" || id.OverlaidSHA256 != SRPFSweepPRSchedulerSHA256 {
		t.Errorf("image identity %+v", id)
	}
	results := sum.Arms
	if len(results) != 6 {
		t.Fatalf("%d arm results", len(results))
	}
	for _, name := range []string{"summary.json", "arm-srpf.json", "arm-srpf.pre-replay.json", "start-srpf-1.pre-replay.engine.log", "raw-srpf.jsonl"} {
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
		default:
			if res.Outcome != "measured" || res.Figures == nil || res.Preemptions == nil || *res.Preemptions != 2 {
				t.Errorf("arm %s was %s (%s), preemptions %v", res.Name, res.Outcome, res.Reason, res.Preemptions)
				continue
			}
			if res.Figures.Premium.Failed != 0 || res.Figures.Premium.Rows != 3917 || res.Figures.Contender.Rows != 185 ||
				res.Figures.PremiumTTFTP99.String() != "50.0" || len(res.Warmup) != 2 {
				t.Errorf("arm %s figures %+v, %d warm-up rows", res.Name, res.Figures, len(res.Warmup))
			}
		}
	}
	want := []string{"fcfs-t384", "srpf", "priority-t384", "priority", "srpf-t384"}
	for i, rep := range f.replays {
		if rep != want[i]+" "+SRPFSweepPriorities {
			t.Errorf("replay %d was %q, want %s with the priorities", i, rep, want[i])
		}
	}
	// Mutation that turns this red: drop SetRequestIDPrefix from warmup.
	if !slices.Contains(f.requestIDs, "warmup-srpf-0") || !slices.Contains(f.requestIDs, "warmup-srpf-1") || slices.Contains(f.requestIDs, "") {
		t.Errorf("the warm-up sent request IDs %v, not the ones its rows record", f.requestIDs)
	}
	if len(f.replays) != len(want) || len(f.running) != 0 || len(f.removed) != 6 {
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
