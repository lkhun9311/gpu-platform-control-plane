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
	"fmt"
	"strconv"
	"strings"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// sleeperImage is the CPU-only image the trace jobs run, pinned by digest.
//
// The review caught that a mutable tag (busybox:1.36) lets the image drift between runs, so the same study
// re-run months later could execute different bytes; pinning the multi-arch manifest-list digest freezes
// exactly what runs while still resolving on whatever architecture the kind node uses.
// WorkloadImage is exported so a caller that must check it against its own copy has no copy to keep.
//
// cmd/queuelabrun's canary asserted a hardcoded prefix of this string, which is the duplication that test's
// own comment warns against — it broke the moment the workload legitimately changed, and it would not have
// caught the canary drifting to a different pinned image at all.
const WorkloadImage = "python:3.12-alpine@sha256:78098ea6a3a9c6a7727a5d4674e4a44e57e01fac878ee9cb4d24a86bd93916ff"

// workloadScript is the trace's workload, and it computes rather than sleeps.
//
// A sleeping workload holds a device allocation and leaves it idle, so on real hardware the run's headline
// number is discarded RESERVATION rather than discarded work — and nothing in the harness refuses that. The
// simulated cluster cannot show the difference, because there is no device behind the advertised resource and
// "Pod alive" and "device busy" are the same proposition there.
//
// The count is written to /dev/termination-log as well as printed, and that is what makes it survive.
//
// The kubelet copies that file into the container's terminated status, which the collector already watches —
// soleExitCode reads the same struct. So the number arrives inside the Pod object rather than needing the
// logs subresource, a second client, extra RBAC, and a read that races teardown. It is written from INSIDE
// the loop rather than from the termination handler, because the ignoring arm is SIGKILLed at the grace
// boundary and SIGKILL cannot be handled: a count written only on the way out would be missing from exactly
// the arm whose discarded work the experiment is about.
//
// It reports progress, and that half is the point rather than decoration. A compute loop nobody counts is the
// same kind of claim the sleeper was: a loop that silently fell back, or barely advanced, would produce the
// same plausible numbers with no signal anywhere. With a count, discarded GPU-seconds are backed by discarded
// ITERATIONS, and a workload that did nothing says iters=0 out loud.
//
// It is carried in the command rather than baked into an image on purpose. The command is part of the Pod
// template the termination canary fingerprints, so changing the workload forces a re-take; an image would
// only do that when its digest moved, and a script edited inside the same tag would not move it.
//
// The arithmetic is pure Python with no imports beyond the standard library. Stage A establishes the shape —
// compute, count, honour or ignore — on a cluster with no devices; the GPU stage swaps the inner kernel and
// keeps everything around it, which is why the kernel is one line.
const workloadScript = `import signal,sys,time
seconds=float(sys.argv[1]); honor=sys.argv[2]=="honor"; n=0
try: tl=open("/dev/termination-log","w")
except Exception: tl=None
def mark():
    if tl is None: return
    tl.seek(0); tl.write("iters=%d"%n); tl.truncate(); tl.flush()
def stop(*_):
    mark(); print("terminated iters=%d"%n,flush=True); sys.exit(EXITCODE)
if honor: signal.signal(signal.SIGTERM,stop)
end=time.monotonic()+seconds; x=1.0
mark()
while time.monotonic()<end:
    for _ in range(50000): x=(x*1.0000001)%1000000.0
    n+=1
    if n%20==0: mark(); print("iters=%d"%n,flush=True)
mark(); print("finished iters=%d"%n,flush=True)`

// localQueueName is the deterministic LocalQueue name a tenant's jobs are admitted through.
//
// It must match the name BuildFixtures uses for that tenant's LocalQueue, so a submitted job lands in the
// queue whose policy variant is under test.
func localQueueName(tenant string) string {
	return "ql-" + tenant
}

// TerminationContract is how the rendered workload responds to SIGTERM.
//
// It is an explicit parameter because the lab's original sleeper could not be preempted at all: "sh -c
// sleep N" execs sleep as PID 1, and a container's PID 1 gets no default signal disposition, so SIGTERM is
// ignored and only the post-grace SIGKILL can stop it.
// A measured "preemption" against such a workload is not a preemption, so the contract has to be chosen
// deliberately rather than inherited from how the command happened to be written.
type TerminationContract string

const (
	// HonorsSIGTERM keeps the shell as PID 1 with a TERM trap, so a preemption actually stops the work.
	HonorsSIGTERM TerminationContract = "HonorsSIGTERM"
	// IgnoresSIGTERM is the original command, retained deliberately as the contrast arm.
	IgnoresSIGTERM TerminationContract = "IgnoresSIGTERM"
)

// termExitCode is the exit status the honoring workload uses when the trap fires.
//
// It is the conventional 128+SIGTERM, and it matters for measurement rather than convention: exiting zero
// would leave the Pod in phase Succeeded, indistinguishable from natural completion, which is exactly the
// ambiguity that let a completed run be reported as discarded work.
const termExitCode = 143

// RenderMLTrainingJob renders a trace row with the original ignoring contract.
//
// The default is deliberately the ignoring form so no existing caller silently switches arms; callers that
// want a preemptible workload must ask for it.
func RenderMLTrainingJob(row TrainingTraceRow, namespace string) (*platformv1.MLTrainingJob, error) {
	// The contract is a constant here, so the error cannot fire; it is returned rather than dropped so this
	// wrapper does not become the one place an unknown contract is silently tolerated.
	return RenderMLTrainingJobWithContract(row, namespace, IgnoresSIGTERM)
}

// RenderMLTrainingJobWithContract turns one immutable trace row into the MLTrainingJob to submit into
// namespace, with an explicit workload termination contract.
//
// The sleeper is CPU-only busybox that just holds its quota for the row's duration, so the whole study runs
// on kind with fake nvidia.com/gpu capacity and no real GPU; the point under test is Kueue admission and
// reclaim, not GPU computation.
//
// Parallelism and completions are pinned to 1 so a row's gpuCount is exactly its demand (one Pod), which the
// occupancy and demand-satisfaction accounting assumes.
func RenderMLTrainingJobWithContract(
	row TrainingTraceRow, namespace string, contract TerminationContract,
) (*platformv1.MLTrainingJob, error) {
	command, err := sleeperCommand(row.DurationSec, contract)
	if err != nil {
		return nil, err
	}
	return &platformv1.MLTrainingJob{
		ObjectMeta: metav1.ObjectMeta{
			Name:      row.Name,
			Namespace: namespace,
			// The trace index and tenant are stamped as labels so the list/watch collector can join an
			// observed object back to its trace row without parsing the name.
			Labels: map[string]string{
				"queuelab.gpu-platform/trace-index": fmt.Sprintf("%d", row.Index),
				"queuelab.gpu-platform/tenant":      row.Tenant,
			},
		},
		Spec: platformv1.MLTrainingJobSpec{
			Queue:       localQueueName(row.Tenant),
			Image:       WorkloadImage,
			Command:     command,
			GPUCount:    int32(row.GPUCount),
			Parallelism: 1,
			Completions: 1,
		},
	}, nil
}

// sleeperCommand builds the container command for a duration under the given termination contract.
//
// The two arms differ by ONE argument, and that is deliberate. The ignoring arm installs no handler at all,
// because the reason the old `sh -c "sleep N"` ignored SIGTERM was never the command: PID 1 has its default
// signal dispositions dropped by the kernel, so a process that registers nothing is a process that ignores.
// Spelling it as an explicit SIG_IGN would ignore for a DIFFERENT reason than the shell form did, and the
// arms would then differ by two things rather than one.
//
// Measured on kind with a 15 s grace before this was written: no handler survived 16 s and was killed at the
// boundary, a handler exited in 2 s.
//
// The contract is the experimental axis of this study, so an unrecognized value must not fall through to the
// ignoring arm: that would run the contrast arm under the honoring arm's label and produce a plausible wrong
// result, which is the exact failure class the measurement work exists to eliminate.
func sleeperCommand(durationSec int, contract TerminationContract) ([]string, error) {
	// Substituted rather than formatted: the script is full of Python %d verbs and handing it to fmt.Sprintf
	// makes Go try to interpret them, which go vet catches and a reader would not.
	script := strings.Replace(workloadScript, "EXITCODE", strconv.Itoa(termExitCode), 1)
	switch contract {
	case HonorsSIGTERM:
		return []string{"python3", "-c", script, strconv.Itoa(durationSec), "honor"}, nil
	case IgnoresSIGTERM:
		return []string{"python3", "-c", script, strconv.Itoa(durationSec), "ignore"}, nil
	default:
		return nil, fmt.Errorf("unknown TerminationContract %q", contract)
	}
}
