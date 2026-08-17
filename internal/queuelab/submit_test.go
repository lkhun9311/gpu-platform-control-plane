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

package queuelab

import (
	"slices"
	"strings"
	"testing"
)

func TestRenderMLTrainingJobMatchesTraceAndQueue(t *testing.T) {
	rows := ReclaimScenario(true, 600)
	borrow := rows[1] // a2-borrow, tenant-a
	job, err := RenderMLTrainingJob(borrow, "run-ns")
	if err != nil {
		t.Fatalf("render: %v", err)
	}

	if job.Name != "a2-borrow" || job.Namespace != "run-ns" {
		t.Fatalf("job identity = %s/%s", job.Namespace, job.Name)
	}
	// The job must target the same LocalQueue name the fixtures created for its tenant, or it would never
	// be admitted through the policy variant under test.
	if job.Spec.Queue != "ql-tenant-a" {
		t.Fatalf("queue = %q, want ql-tenant-a", job.Spec.Queue)
	}
	if job.Spec.GPUCount != 1 {
		t.Fatalf("gpuCount = %d, want 1", job.Spec.GPUCount)
	}
	if job.Spec.Parallelism != 1 || job.Spec.Completions != 1 {
		t.Fatalf("parallelism/completions must be pinned to 1 so gpuCount is the demand")
	}
	// The duration is an ARGUMENT now rather than text inside a shell string, which is what lets the two arms
	// share one script: a workload spelled per-arm could drift between them without the compiler noticing.
	if len(job.Spec.Command) != 5 || job.Spec.Command[0] != "python3" || job.Spec.Command[3] != "600" {
		t.Fatalf("workload command = %v, want python3 -c <script> 600 <contract>", job.Spec.Command)
	}
	if job.Labels["queuelab.gpu-platform/trace-index"] != "1" {
		t.Fatalf("trace-index label = %q, want 1", job.Labels["queuelab.gpu-platform/trace-index"])
	}
}

func TestRenderMLTrainingJobQueuePerTenant(t *testing.T) {
	owner := ReclaimScenario(true, 600)[2] // b1-owner, tenant-b
	job, err := RenderMLTrainingJob(owner, "run-ns")
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	if job.Spec.Queue != "ql-tenant-b" {
		t.Fatalf("tenant-b job should target ql-tenant-b, got %q", job.Spec.Queue)
	}
	// The fixtures must create exactly this LocalQueue name for tenant-b, so submit and fixtures agree.
	fs, err := BuildFixtures(StudyReclaim, "Any", FixtureIdentity{TxID: "tx-1", RunID: "r", Namespace: "run-ns"})
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, lq := range fs.LocalQueue {
		if lq.Name == job.Spec.Queue {
			found = true
		}
	}
	if !found {
		t.Fatalf("submit targets queue %q but no fixture LocalQueue has that name", job.Spec.Queue)
	}
}

func TestRenderMLTrainingJobTerminationContract(t *testing.T) {
	row := TrainingTraceRow{Index: 0, Name: "a1", Tenant: "tenant-a", GPUCount: 1, DurationSec: 40}

	ignoring, err := RenderMLTrainingJobWithContract(row, "queuelab", IgnoresSIGTERM)
	if err != nil {
		t.Fatalf("render ignoring: %v", err)
	}
	honoring, err := RenderMLTrainingJobWithContract(row, "queuelab", HonorsSIGTERM)
	if err != nil {
		t.Fatalf("render honoring: %v", err)
	}

	// The arms must differ by EXACTLY ONE element, and that is the property the whole contrast rests on. A
	// second difference — a different script, a different duration, a different interpreter — would make the
	// measured gap attributable to something other than the termination contract, which is the one thing this
	// study varies.
	if len(ignoring.Spec.Command) != len(honoring.Spec.Command) {
		t.Fatalf("the arms have different command lengths: %d and %d",
			len(ignoring.Spec.Command), len(honoring.Spec.Command))
	}
	diff := 0
	for i := range ignoring.Spec.Command {
		if ignoring.Spec.Command[i] != honoring.Spec.Command[i] {
			diff++
		}
	}
	if diff != 1 {
		t.Fatalf("the arms differ in %d command elements, want exactly 1:\n ignore=%q\n honor=%q",
			diff, ignoring.Spec.Command, honoring.Spec.Command)
	}
	if ignoring.Spec.Command[4] != "ignore" || honoring.Spec.Command[4] != "honor" {
		t.Fatalf("the differing element must be the contract argument: %q vs %q",
			ignoring.Spec.Command[4], honoring.Spec.Command[4])
	}

	// The ignoring arm must install NOTHING. The reason the old `sh -c "sleep N"` ignored SIGTERM was never
	// the command: PID 1 has its default signal dispositions dropped by the kernel, so a process registering
	// no handler is a process that ignores. An explicit SIG_IGN would ignore for a different reason than the
	// form it replaces, and the two arms would then differ in mechanism as well as in label.
	script := honoring.Spec.Command[2]
	if strings.Contains(script, "SIG_IGN") {
		t.Fatalf("the workload installs SIG_IGN; the ignoring arm must ignore because PID 1 has no handler, " +
			"which is the mechanism the shell form used and the only one this translation preserves")
	}
	if !strings.Contains(script, "signal.signal(signal.SIGTERM") {
		t.Fatalf("the honouring arm installs no SIGTERM handler, so it would ignore the signal exactly as the "+
			"contrast arm does: %q", script)
	}
	// Progress is what turns occupancy from an assumption into evidence: a workload that computed nothing
	// reports iters=0 rather than being indistinguishable from one that saturated the device.
	//
	// The PERIODIC emit is asserted separately from the final ones, and the ignoring arm is why. It is killed
	// by SIGKILL at the end of the grace period, and SIGKILL cannot be handled — so no final line is ever
	// printed for it, and the last periodic line is the only progress evidence that arm leaves behind.
	// Checking for "iters=" alone passes on a script whose loop reports nothing, because the two exit lines
	// carry the same substring; that mutation survived until this assertion existed.
	if !strings.Contains(script, "flush=True") {
		t.Fatal("progress is not flushed, so a killed workload's last line may never leave the buffer")
	}
	loopEmit := false
	for line := range strings.SplitSeq(script, "\n") {
		t := strings.TrimSpace(line)
		if strings.HasPrefix(t, "if n%") && strings.Contains(t, "iters=") {
			loopEmit = true
		}
	}
	if !loopEmit {
		t.Fatal("the workload never reports progress from inside its loop; the ignoring arm is SIGKILLed and " +
			"prints no final line, so that arm would leave no evidence it computed anything at all")
	}
	got := strings.Join(honoring.Spec.Command, " ")
	// A trapped stop must be distinguishable from natural completion by exit status, or the ledger cannot
	// tell "the preemption stopped it" from "it finished on its own".
	if !strings.Contains(got, "sys.exit(143)") {
		t.Fatalf("honoring command %q must exit 143 on TERM so the stop is distinguishable", got)
	}

	// The default wrapper stays on the ignoring contract so existing callers do not silently change arms.
	defaulted, err := RenderMLTrainingJob(row, "queuelab")
	if err != nil {
		t.Fatalf("render default: %v", err)
	}
	if !slices.Equal(defaulted.Spec.Command, ignoring.Spec.Command) {
		t.Fatal("RenderMLTrainingJob must keep the IgnoresSIGTERM contract")
	}
}

// The exported renderer must refuse an unknown contract rather than take the process down with it.
//
// It is exported and takes the contract from its caller, so an invalid value is caller input, not an
// impossible internal state. It used to panic, which in a measurement binary loses the whole run over an
// argument the function could simply have rejected.
//
// Mutation that turns this red: restore the panic in sleeperCommand's default branch.
func TestRenderRefusesAnUnknownContract(t *testing.T) {
	row := TrainingTraceRow{Index: 0, Name: "x", Tenant: "t", GPUCount: 1, DurationSec: 10}

	job, err := RenderMLTrainingJobWithContract(row, "queuelab", TerminationContract("neither"))
	if err == nil {
		t.Fatal("an unknown contract was rendered instead of refused")
	}
	if job != nil {
		t.Fatal("a job was returned alongside the error")
	}
	if !strings.Contains(err.Error(), "neither") {
		t.Fatalf("the error does not name the contract it rejected: %v", err)
	}

	// The control: the two real contracts must still render, or the guard has become "refuse everything".
	for _, c := range []TerminationContract{HonorsSIGTERM, IgnoresSIGTERM} {
		if _, err := RenderMLTrainingJobWithContract(row, "queuelab", c); err != nil {
			t.Fatalf("contract %q was refused: %v", c, err)
		}
	}
}
