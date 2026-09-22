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
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/util/uuid"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/queuelab"
)

// The storage probe is the third member of the canary/preflight family, and it exists because the other two
// structurally cannot ask its question.
//
// probePodFrom STRIPS the state volume from every probe Pod, and its own comment concedes the consequence:
// "What a run's Pod does with the volume is therefore NOT probed." So until this mode, nothing in this
// repository had ever mounted a real claim twice, and the first thing to exercise the storage path would
// have been a paid run of the resume arms.
//
// docs/superpowers/specs/2026-09-22-the-claim-must-prove-two-pods-share-it.md registers what a pass means
// and, at more length, what it does not.
const (
	// stateProbeToken prefixes the payload the writer stores and the reader must find.
	//
	// The payload is unique per invocation. A fixed one would be satisfied by a previous probe's residue on a
	// reused volume, which is a pass produced by the thing the probe is meant to detect.
	stateProbeToken = "queuelab-smoke-"

	// stateProbeBudget bounds each half: the writer reaching a terminal phase, and the reader after it.
	//
	// Generous for the reason the preflight's is: the first Pod on a fresh node pulls an image, and under
	// WaitForFirstConsumer the claim is provisioned during scheduling, so a cold cluster spends a volume
	// creation here too. A timeout must send an operator to the storage class, not to a phantom hang.
	stateProbeBudget = 6 * time.Minute

	// stateProbeGoneBudget bounds waiting for the writer's object to be ABSENT, not merely deleted.
	//
	// Acceptance of a delete is not absence, and ReadWriteOnce permits two Pods on one node at the same time
	// — so without this wait the reader could start beside a writer that had not released the volume, and a
	// pass would say nothing about succession.
	stateProbeGoneBudget = 2 * time.Minute

	// stateProbePollInterval is how often the probe re-reads what it is waiting for.
	stateProbePollInterval = 2 * time.Second
)

// stateProbeModeTimeout bounds the whole mode, including its cleanup, and is deliberately larger than the
// sum of the budgets so that what decides is a loop that can say why it gave up.
const stateProbeModeTimeout = 2*stateProbeBudget + stateProbeGoneBudget + 4*time.Minute

// stateProbeOutcome is what the probe established, kept apart from what its cleanup managed.
//
// Two fields rather than one error because they answer different questions and an operator acts on them
// differently: a probe that passed and could not clean up leaves storage behind on a cluster that is
// otherwise ready, and reporting that as a failure would send someone to debug the storage class.
type stateProbeOutcome struct {
	// Passed is whether the reader read back exactly what the writer wrote, from the same volume.
	Passed bool
	// LeftBehind names anything this probe created and could not prove gone.
	LeftBehind []string
}

// stateProbe applies a writer Pod and then a reader Pod to one claim, and reports whether the second saw
// what the first wrote.
//
// It acquires the worker through the ordinary transaction, as the preflight does. The reason is not the
// device — this probe holds none — but interference: it consumes node-local volume attachment capacity and
// CSI activity, either of which can perturb a live run's checkpoint timing without either side failing.
// Acquisition excludes other invocations of this harness; it does not isolate the backend, and this function
// claims no more than that.
func stateProbe(ctx context.Context, c client.Client, nodeName, class string,
	now func() time.Time, sleep func(time.Duration), out io.Writer) (err error) {
	if class == "" {
		return fmt.Errorf("-state-probe needs -state-class: the probe exists to test one storage class " +
			"against this worker, and a class chosen by omission is the cluster's default rather than the " +
			"one a run would ask for")
	}
	id := string(uuid.NewUUID())
	runID := canaryRunID(id)
	payload := stateProbeToken + id

	j, aerr := acquireWorker(ctx, c, nodeName, ownerIdentity{
		Kind:      ownerCanary,
		TxID:      newTxID(),
		RunID:     runID,
		Arm:       canaryArm,
		Namespace: canaryNamespace,
		CanaryID:  id,
	})
	if aerr != nil {
		return fmt.Errorf("acquire worker %s to probe its storage: %w", nodeName, aerr)
	}
	_, _ = fmt.Fprintf(out, "worker %s acquired for storage probe %s: tx=%s\n"+
		"  (if this process dies, run: queuelabrun -inspect-worker -worker %s)\n",
		nodeName, id, j.TxID, nodeName)
	defer func() {
		relCtx, relCancel := cleanupContext()
		defer relCancel()
		rerr := releaseOwned(relCtx, c, j)
		if rerr == nil {
			_, _ = fmt.Fprintf(out, "worker %s released\n", nodeName)
			return
		}
		_, _ = fmt.Fprintf(out, "WORKER NOT RESTORED: %v\n  run: queuelabrun -inspect-worker -worker %s\n",
			rerr, nodeName)
		if err == nil {
			err = fmt.Errorf("release worker %s after the storage probe: %w", nodeName, rerr)
		}
	}()

	if nerr := ensureCanaryNamespace(ctx, c); nerr != nil {
		return fmt.Errorf("ensure the probe namespace: %w", nerr)
	}

	fid := queuelab.FixtureIdentity{TxID: j.TxID, RunID: runID, Namespace: canaryNamespace}
	pvc, perr := queuelab.StateClaim(fid, class)
	if perr != nil {
		return fmt.Errorf("render the probe's claim: %w", perr)
	}
	if cerr := c.Create(ctx, pvc); cerr != nil {
		return fmt.Errorf("create the probe's claim %s/%s: %w", pvc.Namespace, pvc.Name, cerr)
	}
	// Reported separately from the probe's verdict, because a probe that passed and left storage behind is a
	// cluster that is ready and an operator who has something to delete.
	outcome := stateProbeOutcome{}
	defer func() {
		relCtx, relCancel := cleanupContext()
		defer relCancel()
		reportStateProbeCleanup(relCtx, c, pvc, &outcome, out)
	}()

	// NOT waiting for the claim to bind first. Under WaitForFirstConsumer there is no first consumer until a
	// Pod is scheduled, so a wait here is a deadlock against the binding mode this lab actually needs.
	_, _ = fmt.Fprintf(out, "  claim %s/%s created for class %q (not waiting for binding: the writer is "+
		"what binds it)\n", pvc.Namespace, pvc.Name, class)

	writer, werr := stateProbePod("sp-"+shortID(id)+"-writer", id, runID, stateProbeWriteCommand(payload))
	if werr != nil {
		return werr
	}
	reader, rerr := stateProbePod("sp-"+shortID(id)+"-reader", id, runID, stateProbeReadCommand(payload))
	if rerr != nil {
		return rerr
	}
	defer func() {
		relCtx, relCancel := cleanupContext()
		defer relCancel()
		releaseProbes(relCtx, c, []*corev1.Pod{writer, reader}, out)
	}()

	// The writer, then its ABSENCE, then the reader. The order is the whole point: ReadWriteOnce permits two
	// Pods on one node at once, so it orders nothing by itself.
	if err := runStateProbeHalf(ctx, c, writer, "writer", now, sleep, out); err != nil {
		return err
	}
	if err := awaitProbeGone(ctx, c, writer, now, sleep); err != nil {
		return fmt.Errorf("the writer would not go away, so a reader started now would not be its "+
			"successor: %w", err)
	}
	_, _ = fmt.Fprintf(out, "  writer gone; the reader is its successor rather than its neighbour\n")

	if err := runStateProbeHalf(ctx, c, reader, "reader", now, sleep, out); err != nil {
		return err
	}

	// Both halves ran on the same claim, and both identities are checked rather than assumed: a reader that
	// bound a different volume would otherwise pass, and so would a payload a previous probe left behind.
	if verr := verifyStateProbe(ctx, c, pvc, writer, reader); verr != nil {
		return verr
	}
	outcome.Passed = true
	reportBoundVolume(ctx, c, pvc, out)
	_, _ = fmt.Fprintf(out, "STORAGE PROBE PASSED on %s: class %q bound a claim, and a second Pod read back "+
		"the exact bytes the first wrote at %s. A run of the checkpointing arms can reach its progress file "+
		"on this worker.\n", nodeName, class, queuelab.StateFilePath)
	return nil
}

// stateProbeWriteCommand writes the payload the way the workload writes its progress file: tmp then replace.
//
// The shape is copied deliberately rather than simplified. What the arms depend on is that a replacement Pod
// reads a file its predecessor wrote through os.replace, so a probe that wrote with a plain open would be
// exercising a different operation against the same volume.
func stateProbeWriteCommand(payload string) []string {
	return []string{"python3", "-c", `import os,sys
p,t=sys.argv[1],sys.argv[2]
tmp=p+".tmp"
f=open(tmp,"w"); f.write(t); f.flush(); os.fsync(f.fileno()); f.close()
os.replace(tmp,p)
print("wrote "+t,flush=True)
`, queuelab.StateFilePath, payload}
}

// stateProbeReadCommand reads it back and refuses anything that is not exactly it.
//
// Three outcomes, and they are distinguished rather than collapsed: exit 0 read the payload, exit 2 found no
// file at all, exit 3 found something else. The third is the one that matters most — a volume carrying an
// earlier probe's residue would satisfy a check that only asked whether the file existed.
func stateProbeReadCommand(payload string) []string {
	return []string{"python3", "-c", `import sys
p,t=sys.argv[1],sys.argv[2]
try: got=open(p).read()
except Exception as e: print("unreadable "+repr(e),flush=True); sys.exit(2)
if got!=t: print("mismatch got="+repr(got),flush=True); sys.exit(3)
print("read "+got,flush=True)
`, queuelab.StateFilePath, payload}
}

// stateProbePod builds one probe Pod from the Pod template the operator would actually render.
//
// It goes through the real renderer and then changes three things, and every one of them is the opposite of
// what probePodFrom does with the same template:
//
// The STATE VOLUME IS KEPT. probePodFrom removes it, which is precisely the gap this mode exists to close.
// The mount is therefore the operator's own rendering rather than one constructed here — a probe that built
// its own mount could pass while BuildJob's was wrong, which is the failure the canary's stripped volume
// already leaves open.
//
// The DEVICE REQUEST IS DROPPED, from every container, for the reason the canary drops it: this probe asks
// nothing about a card, and one that held a device would contend with the runs it is clearing the way for.
//
// PLACEMENT IS BY SELECTOR, not by spec.NodeName. That is registered rather than chosen: nodeName removes
// the scheduler, and WaitForFirstConsumer binding is a scheduler decision, so a probe that pinned the node
// would report success on a binding mode no run will use.
func stateProbePod(name, probeID, runID string, command []string) (*corev1.Pod, error) {
	row := queuelab.TrainingTraceRow{
		Index: 0, Name: queuelab.VictimRow, Tenant: "canary",
		GPUCount: 1, DurationSec: stateProbeRowDurationSec,
	}
	// Rendered at the VICTIM's row under the resuming arm, because that is the only row the protocol gives a
	// state volume to; Arm.StateFor refuses a row it does not know.
	job, err := queuelab.RenderForArm(queuelab.ArmEResume, row, canaryNamespace)
	if err != nil {
		return nil, fmt.Errorf("render the probe's job: %w", err)
	}
	tpl := renderedPodTemplate(job)
	spec := *tpl.Spec.DeepCopy()

	trainer := -1
	for i := range spec.Containers {
		if spec.Containers[i].Name == probeTrainerContainer {
			trainer = i
			break
		}
	}
	if trainer < 0 {
		names := make([]string, 0, len(spec.Containers))
		for i := range spec.Containers {
			names = append(names, spec.Containers[i].Name)
		}
		return nil, fmt.Errorf("the operator's pod template has no %q container (it has %v), so this probe "+
			"cannot tell which container would hold a run's workload", probeTrainerContainer, names)
	}
	spec.Containers[trainer].Command = command
	// Args goes with Command for the reason probePodFrom gives: they are one unit, and replacing one while
	// adopting the other leaves half a pair.
	spec.Containers[trainer].Args = nil

	// Every container, because the kubelet admits the POD against the node's allocatable.
	for i := range spec.Containers {
		delete(spec.Containers[i].Resources.Limits, gpuResourceName)
		delete(spec.Containers[i].Resources.Requests, gpuResourceName)
		if len(spec.Containers[i].Resources.Limits) == 0 {
			spec.Containers[i].Resources.Limits = nil
		}
		if len(spec.Containers[i].Resources.Requests) == 0 {
			spec.Containers[i].Resources.Requests = nil
		}
	}

	spec.NodeSelector = map[string]string{workerLabelKey: runID}
	spec.Tolerations = append(spec.Tolerations, corev1.Toleration{
		Key:      workerTaintKey,
		Operator: corev1.TolerationOpEqual,
		Value:    runID,
		Effect:   corev1.TaintEffectNoSchedule,
	})

	meta := *tpl.ObjectMeta.DeepCopy()
	meta.Namespace = canaryNamespace
	meta.Name = name
	if meta.Labels == nil {
		meta.Labels = map[string]string{}
	}
	// The same label every other probe Pod carries, and it is load-bearing rather than decorative:
	// printRecoverable lists a stranded holder's Pods by this label, so a probe without it is invisible to
	// the tool an operator reaches for when the worker will not come back.
	meta.Labels[canaryProbeLabel] = probeID
	meta.Labels["queuelab.gpu-platform/purpose"] = "state-probe"
	// The finalizer keeps the object readable after its container stops, which is what lets the writer's
	// terminal status be read at all. It is also why the handoff has to remove it explicitly before waiting
	// for absence: without that, "gone" would never arrive.
	meta.Finalizers = []string{canaryFinalizer}
	return &corev1.Pod{ObjectMeta: meta, Spec: spec}, nil
}

// stateProbeRowDurationSec is the row duration the probe renders at.
//
// It reaches the rendered command and nothing else: both halves replace that command outright, so the value
// decides no timing. It is non-zero because the renderer refuses a row that would sleep for no time, and
// small so that a reader of the manifest is not invited to think the probe waits for it.
const stateProbeRowDurationSec = 8

// runStateProbeHalf creates one half of the probe and waits for it to finish, reporting what the container
// said.
func runStateProbeHalf(ctx context.Context, c client.Client, pod *corev1.Pod, half string,
	now func() time.Time, sleep func(time.Duration), out io.Writer) error {
	if err := c.Create(ctx, pod); err != nil {
		return fmt.Errorf("apply the probe's %s: %w", half, err)
	}
	term, err := awaitStateProbeStopped(ctx, c, pod, now, sleep)
	if err != nil {
		return fmt.Errorf("the %s did not finish: %w", half, err)
	}
	if term.ExitCode != 0 {
		return fmt.Errorf("STORAGE PROBE FAILED at the %s: it exited %d (%s). The claim's class did not give "+
			"this Pod a usable volume at %s, so a checkpointing arm on this worker would write into nothing "+
			"or read back something that is not its predecessor's",
			half, term.ExitCode, strings.TrimSpace(term.Message), queuelab.StateFilePath)
	}
	_, _ = fmt.Fprintf(out, "  %-6s : exited 0 (%s)\n", half, strings.TrimSpace(term.Message))
	return nil
}

// awaitStateProbeStopped waits for the probe's trainer container to reach a terminal state.
func awaitStateProbeStopped(ctx context.Context, c client.Client, pod *corev1.Pod,
	now func() time.Time, sleep func(time.Duration)) (*corev1.ContainerStateTerminated, error) {
	deadline := now().Add(stateProbeBudget)
	var last string
	for {
		var got corev1.Pod
		if err := c.Get(ctx, client.ObjectKeyFromObject(pod), &got); err != nil {
			last = fmt.Sprintf("could not be read: %v", err)
		} else {
			if t := terminatedState(&got); t != nil {
				return t, nil
			}
			last = probeTrouble(&got)
		}
		if !now().Before(deadline) {
			return nil, fmt.Errorf("it did not reach a terminal state within %s: %s. Under "+
				"WaitForFirstConsumer the claim is provisioned while this Pod is scheduled, so a Pod stuck "+
				"Pending here is usually the storage class rather than the node", stateProbeBudget, last)
		}
		if err := ctx.Err(); err != nil {
			return nil, fmt.Errorf("waiting for the probe to finish: %w", err)
		}
		sleep(stateProbePollInterval)
	}
}

// awaitProbeGone removes the probe's finalizer, deletes it, and waits until the object is ABSENT.
//
// Deleting and moving on would be the defect this whole mode is arranged against: acceptance of a delete is
// not absence, and ReadWriteOnce lets two Pods hold one volume on the same node — so a reader started on
// acceptance alone would be the writer's neighbour rather than its successor, and a pass would say nothing
// about succession.
func awaitProbeGone(ctx context.Context, c client.Client, pod *corev1.Pod,
	now func() time.Time, sleep func(time.Duration)) error {
	if err := releaseProbe(ctx, c, pod); err != nil {
		return fmt.Errorf("release it: %w", err)
	}
	deadline := now().Add(stateProbeGoneBudget)
	for {
		var got corev1.Pod
		err := c.Get(ctx, client.ObjectKeyFromObject(pod), &got)
		switch {
		case apierrors.IsNotFound(err):
			return nil
		case err != nil:
			// Retried rather than returned, for the reason the start loop keeps its last error: one blip
			// against the apiserver must not end a handoff that is going fine, and the budget decides.
			if !now().Before(deadline) {
				return fmt.Errorf("its absence could not be established within %s: %w", stateProbeGoneBudget, err)
			}
		default:
			if !now().Before(deadline) {
				return fmt.Errorf("it was still present after %s (phase %s, finalizers %v)",
					stateProbeGoneBudget, got.Status.Phase, got.Finalizers)
			}
		}
		if err := ctx.Err(); err != nil {
			return fmt.Errorf("waiting for it to go away: %w", err)
		}
		sleep(stateProbePollInterval)
	}
}

// verifyStateProbe checks the two identities a successful read could otherwise be wrong about.
//
// The reader exiting zero establishes that it found the payload. It does not establish that it found it on
// the volume the writer used: a reader bound to a different PersistentVolume, or one whose Pod was somehow
// the writer itself, would exit zero just the same. Both are checked here rather than assumed.
func verifyStateProbe(ctx context.Context, c client.Client, pvc *corev1.PersistentVolumeClaim,
	writer, reader *corev1.Pod) error {
	var w, r corev1.Pod
	for _, p := range []struct {
		into *corev1.Pod
		of   *corev1.Pod
		name string
	}{{&w, writer, "writer"}, {&r, reader, "reader"}} {
		if err := c.Get(ctx, client.ObjectKeyFromObject(p.of), p.into); err != nil {
			// The writer is deleted by the handoff, so its object may legitimately be gone by now. What
			// matters is that the two UIDs differ, and the UID this process created is enough for that.
			p.into.UID = p.of.UID
		}
	}
	if writer.UID != "" && reader.UID != "" && writer.UID == reader.UID {
		return fmt.Errorf("the writer and the reader are the same Pod (%s), so nothing was handed over",
			writer.UID)
	}
	var bound corev1.PersistentVolumeClaim
	if err := c.Get(ctx, client.ObjectKeyFromObject(pvc), &bound); err != nil {
		return fmt.Errorf("read the probe's claim back to confirm both Pods used it: %w", err)
	}
	if bound.Status.Phase != corev1.ClaimBound {
		return fmt.Errorf("the reader read the payload but the claim is %s rather than Bound, so what it "+
			"read did not come from the volume this probe provisioned", bound.Status.Phase)
	}
	if bound.Spec.VolumeName == "" {
		return fmt.Errorf("the claim is Bound and names no volume, so this probe cannot say what the two " +
			"Pods shared")
	}
	return nil
}

// reportBoundVolume prints the PersistentVolume the claim bound and, above all, its reclaim policy.
//
// The policy is reported rather than acted on. Under Retain the backing storage outlives the claim, so a
// cluster where this probe runs often is accumulating volumes nothing in this repository removes — and the
// probe must not quietly change the policy to make its own cleanup tidier.
func reportBoundVolume(ctx context.Context, c client.Client, pvc *corev1.PersistentVolumeClaim, out io.Writer) {
	var bound corev1.PersistentVolumeClaim
	if err := c.Get(ctx, client.ObjectKeyFromObject(pvc), &bound); err != nil {
		_, _ = fmt.Fprintf(out, "  volume     : could not be read back: %v\n", err)
		return
	}
	var pv corev1.PersistentVolume
	if err := c.Get(ctx, client.ObjectKey{Name: bound.Spec.VolumeName}, &pv); err != nil {
		_, _ = fmt.Fprintf(out, "  volume     : %s (its reclaim policy could not be read: %v)\n",
			bound.Spec.VolumeName, err)
		return
	}
	_, _ = fmt.Fprintf(out, "  volume     : %s, reclaimPolicy=%s\n", pv.Name, pv.Spec.PersistentVolumeReclaimPolicy)
	if pv.Spec.PersistentVolumeReclaimPolicy == corev1.PersistentVolumeReclaimRetain {
		_, _ = fmt.Fprintf(out, "               Retain: deleting the claim leaves this volume and its backing "+
			"storage behind. Nothing in this repository removes them, and every run of the checkpointing "+
			"arms on this class adds one.\n")
	}
}

// reportStateProbeCleanup deletes the probe's claim and says whether it could establish that it is gone.
//
// Separate from the verdict, and that separation is the point. Calling a delete is not completing one:
// deletion of a bound claim waits on the volume, and a probe that reported "cleaned up" on acceptance would
// be making the same unchecked claim its own read-side refusal exists to catch.
func reportStateProbeCleanup(ctx context.Context, c client.Client, pvc *corev1.PersistentVolumeClaim,
	outcome *stateProbeOutcome, out io.Writer) {
	name := pvc.Namespace + "/" + pvc.Name
	if err := c.Delete(ctx, pvc); err != nil && !apierrors.IsNotFound(err) {
		outcome.LeftBehind = append(outcome.LeftBehind, name)
		_, _ = fmt.Fprintf(out, "CLEANUP INCOMPLETE: the probe's claim %s could not be deleted: %v\n"+
			"  kubectl -n %s delete pvc %s\n", name, err, pvc.Namespace, pvc.Name)
		return
	}
	var got corev1.PersistentVolumeClaim
	err := c.Get(ctx, client.ObjectKeyFromObject(pvc), &got)
	switch {
	case apierrors.IsNotFound(err):
		_, _ = fmt.Fprintf(out, "  cleanup    : claim %s is gone\n", name)
	case err != nil:
		outcome.LeftBehind = append(outcome.LeftBehind, name)
		_, _ = fmt.Fprintf(out, "CLEANUP UNVERIFIED: the probe's claim %s was deleted and its absence could "+
			"not be confirmed: %v\n", name, err)
	default:
		// Deleting a bound claim is asynchronous, so this is ordinary rather than alarming — but it is
		// reported, because "the delete was accepted" and "the storage is gone" are different sentences and
		// only one of them is what an operator wants to hear.
		outcome.LeftBehind = append(outcome.LeftBehind, name)
		_, _ = fmt.Fprintf(out, "CLEANUP PENDING: the probe's claim %s is deleting (phase %s). Its volume "+
			"goes when the class's reclaim policy says so, which this probe reports and does not change.\n",
			name, got.Status.Phase)
	}
}

// The claim is rendered through queuelab.StateClaim at the one call site above rather than through a helper
// here, and that is deliberate after a first draft did the opposite. A wrapper "exposed so a test can assert
// the shape" had no caller but the test, which makes the test assert a function nothing in the probe's real
// path uses — the hollow check this repository argues against elsewhere. The shape is pinned by asserting
// what the probe actually creates.
