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
	"context"
	"fmt"
	"io"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/uuid"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/queuelab"
)

// The preflight is the termination canary's mirror image, and the pair is worth reading together.
//
// The canary STRIPS the device request, because what it qualifies is signal delivery and a probe that needed a
// free card would fail on a node whose devices are legitimately held. The preflight KEEPS it, because the only
// question it asks is whether a real device works here. Everything else -- the Pod template, the placement,
// the toleration, the finalizer that keeps a terminated status readable -- is deliberately identical, so a
// preflight that passes is a statement about the shape a run actually gets rather than about a Pod invented
// for the occasion.
//
// It exists because nothing else in this harness can ask that question. The canary cannot: its probes have no
// device. A run cannot either, not usefully -- it answers only at the end, after the protocol has spent its
// minutes and the meter has run, and it answers with a refused record rather than with which of the eight
// driver calls said no. On rented hardware that difference is the whole cost of the session.
const (
	// preflightDurationSec is how long the workload runs when nobody stops it.
	//
	// Short, because the preflight measures nothing: it asks whether a kernel launches. Long enough that the
	// loop marks its termination log at least once from inside itself, which is what the ignoring arm depends
	// on in a real run and therefore what is worth exercising here too.
	preflightDurationSec = 8

	// preflightStartBudget bounds waiting for the Pod to reach a terminal phase.
	//
	// It is the canary's start budget plus the run itself, and it is generous for one reason: the first Pod on
	// a fresh GPU node pulls an image and initialises a driver context, and a preflight that timed out on a
	// cold cache would send an operator looking for a device fault that is not there.
	preflightBudget = 6 * time.Minute

	// preflightPollInterval is how often the Pod's status is re-read.
	preflightPollInterval = 2 * time.Second
)

// preflightModeTimeout bounds the whole mode, including its cleanup.
const preflightModeTimeout = preflightBudget + 3*time.Minute

// devicePreflight applies one GPU-holding Pod to a worker and reports what the workload said about the device.
//
// It acquires the worker through the ordinary transaction rather than applying a Pod beside whatever is
// running. Two reasons, and the second is the one that matters: a preflight racing a run would take the device
// the run is measuring, and a preflight that found no free device would report a device fault when what it
// actually found was a busy node.
//
// It is not a run and writes no record. The verdict here is a yes/no about hardware, and putting it in a
// document whose schema describes measured intervals would let a reader take it for one.
func devicePreflight(ctx context.Context, c client.Client, nodeName string,
	now func() time.Time, sleep func(time.Duration), out io.Writer) (err error) {
	contract, cerr := harnessTerminationContract()
	if cerr != nil {
		return fmt.Errorf("build the preflight's workload contract: %w", cerr)
	}
	command, cmderr := preflightCommand()
	if cmderr != nil {
		return fmt.Errorf("render the preflight's workload command: %w", cmderr)
	}
	id := string(uuid.NewUUID())
	runID := canaryRunID(id)

	j, aerr := acquireWorker(ctx, c, nodeName, ownerIdentity{
		Kind:      ownerCanary,
		TxID:      newTxID(),
		RunID:     runID,
		Arm:       canaryArm,
		Namespace: canaryNamespace,
		CanaryID:  id,
	})
	if aerr != nil {
		return fmt.Errorf("acquire worker %s to preflight it: %w", nodeName, aerr)
	}
	_, _ = fmt.Fprintf(out, "worker %s acquired for device preflight %s: tx=%s\n"+
		"  (if this process dies, run: queuelabrun -inspect-worker -worker %s)\n",
		nodeName, id, j.TxID, nodeName)
	defer func() {
		// On cleanupContext for the reason every release path in this package is: a signal arriving here must
		// not be what decides whether the worker goes back.
		relCtx, relCancel := cleanupContext()
		defer relCancel()
		rerr := releaseOwned(relCtx, c, j)
		if rerr == nil {
			_, _ = fmt.Fprintf(out, "worker %s released\n", nodeName)
			return
		}
		_, _ = fmt.Fprintf(out, "WORKER NOT RESTORED: %v\n  run: queuelabrun -inspect-worker -worker %s\n",
			rerr, nodeName)
		// Only when nothing else already failed: a preflight that found no usable device AND could not give
		// the worker back is still primarily a preflight that found no usable device, and overwriting its
		// reason would hide the thing an operator needs.
		if err == nil {
			err = fmt.Errorf("release worker %s after the preflight: %w", nodeName, rerr)
		}
	}()

	if nerr := ensureCanaryNamespace(ctx, c); nerr != nil {
		return fmt.Errorf("ensure the preflight namespace: %w", nerr)
	}
	pod, perr := preflightPod(id, nodeName, runID, contract, command)
	if perr != nil {
		return perr
	}
	if cerr := c.Create(ctx, pod); cerr != nil {
		return fmt.Errorf("apply the preflight pod: %w", cerr)
	}
	// releaseProbes removes the finalizer this Pod carries and deletes it, and it is deferred before the wait
	// so a cancelled preflight does not strand a Pod holding a device on the node it was checking.
	defer func() {
		relCtx, relCancel := cleanupContext()
		defer relCancel()
		releaseProbes(relCtx, c, []*corev1.Pod{pod}, out)
	}()

	term, werr := awaitPreflightStopped(ctx, c, pod, now, sleep)
	if werr != nil {
		return werr
	}
	return reportPreflight(out, nodeName, term)
}

// preflightCommand renders the workload the preflight runs.
//
// It is the HONOURING arm, and the choice is not arbitrary: this Pod is deleted at the end whether it finished
// or not, and an ignoring workload would sit through the full grace period before SIGKILL, adding thirty
// seconds to every preflight for no reading. The device path is identical in both arms.
func preflightCommand() ([]string, error) {
	job, err := queuelab.RenderMLTrainingJobWithContract(queuelab.TrainingTraceRow{
		Index: 0, Name: "device-preflight", Tenant: "canary",
		GPUCount: 1, DurationSec: preflightDurationSec,
	}, canaryNamespace, queuelab.HonorsSIGTERM)
	if err != nil {
		return nil, err
	}
	return job.Spec.Command, nil
}

// preflightPod builds the preflight Pod from the same rendered template the canary probes.
//
// It goes through probePodFrom and then puts the device request BACK, rather than building a Pod here. The
// duplication that would otherwise arise is not cosmetic: probePodFrom carries the placement, the toleration
// that matches the ResourceFlavor a run's Pods are admitted under, the trainer-by-name lookup and the
// finalizer that keeps a terminated status readable after the container stops. A second copy of those would
// drift, and the copy that drifted would be the one nobody runs until a GPU node is already rented.
//
// Exactly one device, not the sentinel's seven and not the row's count: the preflight asks whether A card
// works, and asking for more would turn a working node with a busy neighbour into a preflight failure.
func preflightPod(id, node, runID string, contract canaryContract, command []string) (*corev1.Pod, error) {
	pod, err := probePodFrom(renderedPodTemplate(templateProbeJob()), id, node, runID, contract,
		probeSpec{name: "dp-" + shortID(id), contract: "HonorsSIGTERM", command: command})
	if err != nil {
		return nil, err
	}
	trainer := -1
	for i := range pod.Spec.Containers {
		if pod.Spec.Containers[i].Name == probeTrainerContainer {
			trainer = i
			break
		}
	}
	if trainer < 0 {
		// probePodFrom refuses this case already, so reaching it means the two disagree about which container
		// is the workload -- which would put the device on one container and the command on another.
		return nil, fmt.Errorf("internal error: the preflight pod has no %q container after probePodFrom "+
			"accepted the template", probeTrainerContainer)
	}
	if pod.Spec.Containers[trainer].Resources.Limits == nil {
		pod.Spec.Containers[trainer].Resources.Limits = corev1.ResourceList{}
	}
	pod.Spec.Containers[trainer].Resources.Limits[gpuResourceName] = *resource.NewQuantity(1, resource.DecimalSI)
	return pod, nil
}

// shortID trims an id to the prefix the probe names use.
func shortID(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

// awaitPreflightStopped waits for the preflight's trainer container to terminate and returns its final state.
//
// It waits for a TERMINAL container state rather than for the Pod to be Running, because a workload that
// starts and then cannot reach the driver is exactly the case this exists to catch: it runs, it reports, and
// it exits zero. Readiness would have called that a pass.
func awaitPreflightStopped(ctx context.Context, c client.Client, pod *corev1.Pod,
	now func() time.Time, sleep func(time.Duration)) (*corev1.ContainerStateTerminated, error) {
	deadline := now().Add(preflightBudget)
	var last string
	for {
		var live corev1.Pod
		err := c.Get(ctx, types.NamespacedName{Namespace: pod.Namespace, Name: pod.Name}, &live)
		switch {
		case apierrors.IsNotFound(err):
			// Deleted by something other than this process, so the reading is gone rather than negative.
			return nil, fmt.Errorf("the preflight pod %s/%s disappeared before it terminated; something "+
				"outside this invocation deleted it, and no verdict about the device can come from that",
				pod.Namespace, pod.Name)
		case err != nil:
			return nil, fmt.Errorf("read the preflight pod: %w", err)
		}
		if t := terminatedState(&live); t != nil {
			return t, nil
		}
		if trouble := probeTrouble(&live); trouble != "" {
			last = trouble
		}
		if !now().Before(deadline) {
			if last == "" {
				last = fmt.Sprintf("phase %s", live.Status.Phase)
			}
			return nil, fmt.Errorf("the preflight pod did not terminate within %s: %s. A device request that "+
				"no node can satisfy looks exactly like this, so check that %s advertises %s before reading it "+
				"as a driver fault", preflightBudget, last, pod.Spec.NodeName, gpuResourceName)
		}
		sleep(preflightPollInterval)
	}
}

// reportPreflight turns the workload's own report into the verdict an operator acts on.
//
// The failing case names the DEVICE STATUS token rather than saying the device did not work, and that is the
// entire value of this mode. "no-libcuda" is a base image or a container runtime that never injected the
// driver; "no-device" is a card that was not passed through; "ptx-load-failed" is a kernel this driver would
// not compile. Those send an operator to three different places, and a session that discovered the difference
// from a refused record would have paid for the protocol to find out.
func reportPreflight(out io.Writer, nodeName string, t *corev1.ContainerStateTerminated) error {
	iters, kind, device := queuelab.ReportFromMessage(t.Message)
	if iters == nil {
		return fmt.Errorf("the preflight workload left no report this build can read (exit %d, message %q). "+
			"That is not a statement about the device: it is the workload and this harness disagreeing about "+
			"the wire format, and a run on this node would record its provenance as unreported",
			t.ExitCode, t.Message)
	}
	if kind != queuelab.KindCUDAFMA {
		return fmt.Errorf("DEVICE NOT USABLE on %s: the workload fell back to the CPU loop, reporting dev=%q "+
			"after %d iterations. A run here would complete and refuse to attribute device work, so its "+
			"GPU-seconds would be seconds of RESERVATION exactly as they are on a cluster with no cards",
			nodeName, device, *iters)
	}
	if device != queuelab.DeviceOK {
		return fmt.Errorf("DEVICE UNRELIABLE on %s: kernels launched and then stopped (dev=%q after %d "+
			"launches). A run here would abort mid-protocol rather than produce a refused record",
			nodeName, device, *iters)
	}
	_, _ = fmt.Fprintf(out, "DEVICE USABLE: on %s the workload loaded its PTX through the CUDA driver and "+
		"completed %d kernel launches in %d s. A run on this node can establish device work, given an "+
		"observer that covers the hold.\n", nodeName, *iters, preflightDurationSec)
	return nil
}
