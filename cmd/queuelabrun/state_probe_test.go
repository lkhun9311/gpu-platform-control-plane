package main

import (
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/controller"
	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/queuelab"
)

// The probe Pod must KEEP the state volume, and that is the single thing separating it from every other
// probe in this package.
//
// probePodFrom strips the volume from the canary's and the preflight's Pods, deliberately, and concedes the
// consequence in its own comment: "What a run's Pod does with the volume is therefore NOT probed." This mode
// exists to close exactly that gap, so a version of it that reused that function — or rebuilt the mount by
// hand — would test something no run performs.
//
// The mount is asserted against the renderer's own constants rather than against literals, because a probe
// that constructed a correct mount while BuildJob's was wrong would pass and prove nothing.
//
// Mutations that turn this red: build the Pod through probePodFrom; drop the volume; write the mount path
// as a literal that drifts from StateMountPath.
func TestTheStateProbePodMountsTheClaimARunWouldMount(t *testing.T) {
	pod, err := stateProbePod("sp-abcdef01-writer", "abcdef0123456789", "canary-abcdef01",
		stateProbeWriteCommand("payload"))
	if err != nil {
		t.Fatalf("stateProbePod: %v", err)
	}

	var claim string
	for i := range pod.Spec.Volumes {
		if v := pod.Spec.Volumes[i]; v.Name == controller.StateVolumeName && v.PersistentVolumeClaim != nil {
			claim = v.PersistentVolumeClaim.ClaimName
		}
	}
	if claim != queuelab.StateClaimName {
		t.Fatalf("the probe mounts claim %q, not the %q a run's victim mounts; it would be testing a "+
			"different object", claim, queuelab.StateClaimName)
	}

	var mount string
	for i := range pod.Spec.Containers {
		for _, m := range pod.Spec.Containers[i].VolumeMounts {
			if m.Name == controller.StateVolumeName {
				mount = m.MountPath
			}
		}
	}
	if mount != queuelab.StateMountPath {
		t.Fatalf("the probe mounts at %q, not the %q the renderer produces; a probe that built its own "+
			"mount could pass while the renderer's was wrong", mount, queuelab.StateMountPath)
	}

	// And the command writes INSIDE that mount, or the probe would exercise the container filesystem and
	// report success for a volume it never touched.
	// The trainer BY NAME, as the builder finds it. Reading Containers[0] would check the wrong container's
	// command the day the operator's template grows a sidecar in front of the trainer -- which is the same
	// index-versus-name trap probeTrainerContainer's own comment describes.
	var cmd []string
	for i := range pod.Spec.Containers {
		if pod.Spec.Containers[i].Name == probeTrainerContainer {
			cmd = pod.Spec.Containers[i].Command
		}
	}
	if cmd == nil {
		t.Fatalf("the probe has no %q container, so nothing carries the workload's command", probeTrainerContainer)
	}
	if len(cmd) < 2 || !strings.HasPrefix(cmd[len(cmd)-2], queuelab.StateMountPath+"/") {
		t.Fatalf("the probe's target path %v is not inside the mount, so it would write into the container "+
			"filesystem and lose it with the Pod", cmd)
	}
}

// Placement must be by SELECTOR, never by spec.NodeName, and this is registered rather than preferred.
//
// spec.NodeName removes the scheduler, and WaitForFirstConsumer binding is a scheduler decision — so a probe
// that pinned the node would report success on a binding mode no run will ever use. Both frozen pages that
// owed this probe name that constraint in those words.
//
// Mutations that turn this red: set spec.NodeName; drop the node selector; drop the toleration, which leaves
// the Pod unschedulable on the very worker the transaction just tainted.
func TestTheStateProbePodLetsTheSchedulerPlaceIt(t *testing.T) {
	const runID = "canary-abcdef01"
	pod, err := stateProbePod("sp-abcdef01-writer", "abcdef0123456789", runID,
		stateProbeWriteCommand("payload"))
	if err != nil {
		t.Fatalf("stateProbePod: %v", err)
	}
	if pod.Spec.NodeName != "" {
		t.Fatalf("the probe pins spec.nodeName=%q, which bypasses the scheduler and so defeats "+
			"WaitForFirstConsumer binding — the one thing this probe exists to exercise", pod.Spec.NodeName)
	}
	if got := pod.Spec.NodeSelector[workerLabelKey]; got != runID {
		t.Fatalf("the probe selects %s=%q, not this transaction's %q, so it could land anywhere",
			workerLabelKey, got, runID)
	}
	var tolerated bool
	for _, tol := range pod.Spec.Tolerations {
		if tol.Key == workerTaintKey && tol.Value == runID && tol.Effect == corev1.TaintEffectNoSchedule {
			tolerated = true
		}
	}
	if !tolerated {
		t.Fatalf("the probe does not tolerate %s=%s:NoSchedule, which acquisition just installed, so it "+
			"would stay Pending on the node it is meant to probe: %v", workerTaintKey, runID, pod.Spec.Tolerations)
	}
}

// A storage probe must hold no device, or it contends with the runs it is clearing the way for.
//
// Every container, because the kubelet admits the POD against the node's allocatable: a sidecar holding a
// request makes the probe unschedulable exactly as the trainer's would.
//
// Mutation that turns this red: strip the request from the trainer alone, or not at all.
func TestTheStateProbePodHoldsNoDevice(t *testing.T) {
	pod, err := stateProbePod("sp-abcdef01-reader", "abcdef0123456789", "canary-abcdef01",
		stateProbeReadCommand("payload"))
	if err != nil {
		t.Fatalf("stateProbePod: %v", err)
	}
	for i := range pod.Spec.Containers {
		c := &pod.Spec.Containers[i]
		if _, ok := c.Resources.Limits[gpuResourceName]; ok {
			t.Fatalf("container %q asks for %s; a storage probe that took a card would contend with the runs "+
				"it is checking for", c.Name, gpuResourceName)
		}
		if _, ok := c.Resources.Requests[gpuResourceName]; ok {
			t.Fatalf("container %q requests %s", c.Name, gpuResourceName)
		}
	}
}

// The probe's Pods must carry the label recovery lists them by, and this is a live dependency rather than
// tidiness.
//
// printRecoverable no longer rebuilds probe Pod names from the journal — it LISTS them by this label — so a
// probe whose Pods lack it is invisible to the tool an operator reaches for when the worker will not come
// back. The finalizer matters for a different reason: it is what keeps the writer's terminal status readable
// after its container stops, which is the reading the handoff depends on.
//
// Mutation that turns this red: drop either overlay from stateProbePod.
func TestTheStateProbePodIsFindableWhenItIsStranded(t *testing.T) {
	const id = "abcdef0123456789"
	pod, err := stateProbePod("sp-abcdef01-writer", id, "canary-abcdef01", stateProbeWriteCommand("payload"))
	if err != nil {
		t.Fatalf("stateProbePod: %v", err)
	}
	if pod.Labels[canaryProbeLabel] != id {
		t.Fatalf("the probe carries %s=%q, not the id its journal records; a stranded probe would not be "+
			"listed by -inspect-worker at all", canaryProbeLabel, pod.Labels[canaryProbeLabel])
	}
	if pod.Namespace != canaryNamespace {
		t.Fatalf("the probe is in namespace %q, not the shared %q recovery searches", pod.Namespace, canaryNamespace)
	}
	// And NO finalizer, which is the opposite of what the canary's probes carry.
	//
	// The canary needs one because it deletes its probe in order to measure the response, so the object has
	// to outlive that delete. Nothing deletes this probe's Pods before their terminal status is read, so a
	// finalizer here buys nothing and leaves an object that cannot go away until something releases it. A
	// first version copied it across with the canary's reason written on it, which was a false invariant.
	//
	// Mutation that turns this red: put canaryFinalizer back on the probe's Pods.
	for _, f := range pod.Finalizers {
		if f == canaryFinalizer {
			t.Fatalf("the probe carries the canary's %q finalizer; nothing deletes these Pods before they "+
				"are read, so it only makes them un-removable until something remembers to strip it",
				canaryFinalizer)
		}
	}
}

// The two halves must be told apart by their payload, not merely by their names.
//
// A reader that only checked whether the file existed would be satisfied by a previous probe's residue on a
// reused volume — a pass produced by the very thing the probe is meant to detect. The payload carries the
// invocation id for that reason, and the reader compares it exactly.
//
// Mutation that turns this red: have the reader test for existence rather than equality.
func TestTheStateProbeReaderDemandsThisInvocationsPayload(t *testing.T) {
	const payload = stateProbeToken + "abcdef0123456789"
	read := strings.Join(stateProbeReadCommand(payload), " ")
	if !strings.Contains(read, "got!=t") {
		t.Fatalf("the reader does not compare what it read against the payload, so stale residue on a "+
			"reused volume would satisfy it:\n%s", read)
	}
	if !strings.Contains(read, payload) {
		t.Fatalf("the reader was not given this invocation's payload:\n%s", read)
	}
	// The writer must use the same replace-then-rename shape the workload uses, or the probe exercises a
	// different operation against the same volume than the arms depend on.
	write := strings.Join(stateProbeWriteCommand(payload), " ")
	if !strings.Contains(write, "os.replace") || !strings.Contains(write, "fsync") {
		t.Fatalf("the writer does not write the way the workload's save() does:\n%s", write)
	}
}

// The mode is selected, refused in combination like every other operator mode, and has a budget large enough
// for what it contains.
//
// Its budget covers TWO Pods and the wait for the first to be absent between them, so a mode inheriting the
// one-minute recovery timeout would be cut off mid-handoff and strand a claim.
//
// Mutation that turns this red: leave modeStateProbe out of operatorModeContext.
func TestTheStateProbeIsAnOperatorModeLikeTheOthers(t *testing.T) {
	if m, err := decideOperatorMode(operatorModeArgs{
		StateProbe: true, StateClass: "fast-ssd", Worker: "w",
	}); err != nil || m != modeStateProbe {
		t.Fatalf("mode = %v, err = %v", m, err)
	}
	ctx, cancel := operatorModeContext(modeStateProbe)
	defer cancel()
	d, ok := ctx.Deadline()
	if !ok {
		t.Fatal("the storage probe runs on a context with no deadline")
	}
	// Two halves and a handoff, so the mode's bound must exceed their sum or the loops can never report why
	// they gave up — the context would expire first.
	if d.Before(time.Now().Add(2*stateProbeBudget + stateProbeGoneBudget)) {
		t.Fatalf("the mode's budget is shorter than the waits it contains, so it can only ever time out")
	}
}

// A class is required before the cluster is touched, and the refusal has to say which flag is missing.
//
// Mutation that turns this red: let stateProbe proceed with an empty class and rely on the claim renderer to
// refuse — which it does, but only after the worker has been acquired and a node taken out of service.
func TestTheStateProbeRefusesWithoutAClassBeforeTouchingAnything(t *testing.T) {
	err := stateProbe(t.Context(), nil, "platform-worker", "", time.Now, func(time.Duration) {}, &strings.Builder{})
	if err == nil {
		t.Fatal("the probe accepted an empty storage class; it would have taken the worker and created a " +
			"claim under whatever the cluster defaults to")
	}
	if !strings.Contains(err.Error(), "-state-class") {
		t.Fatalf("the refusal does not name the flag that fixes it: %v", err)
	}
}
