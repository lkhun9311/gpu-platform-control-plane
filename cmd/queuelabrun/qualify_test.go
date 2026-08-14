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
	"errors"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
	kueuev1beta2 "sigs.k8s.io/kueue/apis/kueue/v1beta2"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/queuelab"
)

// gpuPod is a Pod that asks for devices, in the ordinary shape: the request named on the container.
func gpuPod(namespace, name, nodeName string, gpus int64) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Namespace: namespace, Name: name, UID: types.UID(name + "-uid")},
		Spec: corev1.PodSpec{
			NodeName: nodeName,
			Containers: []corev1.Container{{
				Name:  "train",
				Image: "busybox",
				Resources: corev1.ResourceRequirements{
					Requests: corev1.ResourceList{gpuResourceName: *resource.NewQuantity(gpus, resource.DecimalSI)},
					Limits:   corev1.ResourceList{gpuResourceName: *resource.NewQuantity(gpus, resource.DecimalSI)},
				},
			}},
		},
		Status: corev1.PodStatus{Phase: corev1.PodRunning},
	}
}

// simulatorPod is the gpu-simulator DaemonSet's Pod as config/device-plugin/daemonset.yaml actually declares
// it: 10m of CPU, 32Mi of memory, a toleration for everything, and no device request at all.
//
// It is written out here rather than described in a comment because it is the single most dangerous input
// this check has. The simulator is a device PLUGIN — it is where nvidia.com/gpu on these nodes comes from —
// and it runs on every node, so a predicate that rejected it would refuse every run on every cluster this lab
// has ever used, including the one the reviewer is about to point at it.
func simulatorPod(nodeName string) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Namespace: "system",
			Name:      "gpu-simulator-abcde",
			UID:       types.UID("sim-uid"),
			Labels: map[string]string{
				"app.kubernetes.io/name":      "gpu-platform-control-plane",
				"app.kubernetes.io/component": "gpu-simulator",
			},
		},
		Spec: corev1.PodSpec{
			NodeName:          nodeName,
			PriorityClassName: "system-node-critical",
			Tolerations:       []corev1.Toleration{{Operator: corev1.TolerationOpExists}},
			Containers: []corev1.Container{{
				Name:  "gpu-simulator",
				Image: "gpu-simulator:latest",
				Resources: corev1.ResourceRequirements{
					Requests: corev1.ResourceList{
						corev1.ResourceCPU:    resource.MustParse("10m"),
						corev1.ResourceMemory: resource.MustParse("32Mi"),
					},
					Limits: corev1.ResourceList{
						corev1.ResourceCPU:    resource.MustParse("100m"),
						corev1.ResourceMemory: resource.MustParse("64Mi"),
					},
				},
			}},
		},
		Status: corev1.PodStatus{Phase: corev1.PodRunning},
	}
}

// testFixtures renders the real fixture set for an arm, so the requirement under test is the one the run
// would actually apply rather than a hand-built imitation of it.
func testFixtures(t *testing.T, study queuelab.Study, variant string) *queuelab.FixtureSet {
	t.Helper()
	fs, err := queuelab.BuildFixtures(study, variant, "tx-1111", "r7", "queuelab-r7")
	if err != nil {
		t.Fatalf("build fixtures: %v", err)
	}
	return fs
}

// The requirement has to be COMPUTED from the fixtures, and the two real studies cannot prove that on their
// own: reclaim (two ClusterQueues at nominal 1) and FIFO (one at 2) both come to 2, so `return 2` passes for
// both and the check silently stops being about this run's arm. The synthetic set below is what makes the
// derivation observable — 1 + 3 is a number no constant anyone would plausibly type produces.
//
// The quota on a foreign flavor is there for the same reason: only this run's flavor is pinned to this run's
// worker, so a summation that ignored the flavor would size the node against capacity that lives elsewhere.
//
// Mutation that turns this red: replace requiredGPU's body with `return 2, "two GPUs", nil`. The reclaim and
// FIFO cases stay green — they are 2 — and the synthetic case fails at once, which is the whole reason it is
// here alongside them rather than instead of them.
func TestRequiredGPUIsDerivedFromTheFixturesNotHardCoded(t *testing.T) {
	reclaim := testFixtures(t, queuelab.StudyReclaim, "Any")
	got, from, err := requiredGPU(reclaim)
	if err != nil {
		t.Fatalf("reclaim: %v", err)
	}
	if got != 2 {
		t.Fatalf("reclaim needs %d GPUs, want 2: two ClusterQueues at nominal 1 in one cohort is exactly the "+
			"borrow-then-reclaim contrast the arm is named after, and a node that cannot back both never "+
			"produces it", got)
	}
	if !strings.Contains(from, "ClusterQueue") || !strings.Contains(from, reclaim.Flavor.Name) {
		t.Fatalf("the provenance %q names neither the queues it summed nor the flavor it summed them on, so a "+
			"reader cannot tell a derived number from a typed one", from)
	}

	if got, _, err = requiredGPU(testFixtures(t, queuelab.StudyFIFO, "StrictFIFO")); err != nil || got != 2 {
		t.Fatalf("fifo needs %d GPUs (err %v), want 2: one ClusterQueue at nominal 2", got, err)
	}

	// Two quotas on this run's flavor and one on somebody else's, so both halves of the rule are exercised at
	// once: the total is summed, and the foreign flavor contributes nothing.
	synthetic := &queuelab.FixtureSet{
		Flavor: &kueuev1beta2.ResourceFlavor{ObjectMeta: metav1.ObjectMeta{Name: "queuelab-gpu-r7"}},
		ClusterQueue: []*kueuev1beta2.ClusterQueue{
			syntheticCQ("cq-a", "queuelab-gpu-r7", 1),
			syntheticCQ("cq-b", "queuelab-gpu-r7", 3),
			syntheticCQ("cq-elsewhere", "some-other-flavor", 8),
		},
	}
	got, _, err = requiredGPU(synthetic)
	if err != nil {
		t.Fatalf("synthetic: %v", err)
	}
	if got != 4 {
		t.Fatalf("requiredGPU = %d, want 4 (1+3 on this run's flavor, and none of the 8 on another): the "+
			"number is not being summed out of the fixtures", got)
	}
}

func syntheticCQ(name, flavor string, nominal int64) *kueuev1beta2.ClusterQueue {
	return &kueuev1beta2.ClusterQueue{
		ObjectMeta: metav1.ObjectMeta{Name: name},
		Spec: kueuev1beta2.ClusterQueueSpec{
			ResourceGroups: []kueuev1beta2.ResourceGroup{{
				CoveredResources: []corev1.ResourceName{gpuResourceName},
				Flavors: []kueuev1beta2.FlavorQuotas{{
					Name: kueuev1beta2.ResourceFlavorReference(flavor),
					Resources: []kueuev1beta2.ResourceQuota{{
						Name:         gpuResourceName,
						NominalQuota: *resource.NewQuantity(nominal, resource.DecimalSI),
					}},
				}},
			}},
		},
	}
}

// A fixture set covering no GPU would make the capacity check pass on any machine at all, including one with
// no device, which is a bar that reads as a check and is not one. It is a defect in the fixtures rather than
// in the node, and the message has to say so or an operator goes looking at the cluster.
//
// Mutation that turns this red: drop the `total < 1` branch from requiredGPU and return (0, from, nil).
func TestRequiredGPURefusesAFixtureSetThatCoversNoDevice(t *testing.T) {
	empty := &queuelab.FixtureSet{
		Flavor:       &kueuev1beta2.ResourceFlavor{ObjectMeta: metav1.ObjectMeta{Name: "queuelab-gpu-r7"}},
		ClusterQueue: []*kueuev1beta2.ClusterQueue{syntheticCQ("cq-a", "queuelab-gpu-r7", 0)},
	}
	_, _, err := requiredGPU(empty)
	if err == nil {
		t.Fatal("a requirement of zero was accepted: every node passes a bar of zero, so the capacity check " +
			"would still be present and would no longer be checking anything")
	}
	if !strings.Contains(err.Error(), "fixture") {
		t.Fatalf("the refusal %q blames something other than the fixtures, which sends the operator to the "+
			"cluster for a defect that is in this program", err)
	}
}

// The whole point of the check: the ownership taint reserves the node against FUTURE placement and evicts
// nothing, so a Pod that was already holding a device keeps holding it for the entire run.
//
// Mutation that turns this red: drop the `len(consumers) > 0` branch from qualify. The node is Ready,
// schedulable and advertises two devices, so nothing else in qualify has anything to object to and the run
// proceeds onto a machine with one of its two GPUs already spoken for.
func TestQualifyRefusesAWorkerThatAlreadyHoldsAForeignGPUPod(t *testing.T) {
	q, err := qualify(node(nil, nil), []corev1.Pod{*gpuPod("tenant-a", "train-7", "platform-worker", 1)},
		2, "test")
	if err == nil {
		t.Fatal("a worker running somebody else's GPU Pod qualified: the run would admit against capacity it " +
			"does not have and report a number measured on a different machine")
	}
	if !strings.Contains(err.Error(), "train-7") {
		t.Fatalf("the refusal %q does not name what is on the node, so the operator is told to look and not "+
			"told where", err)
	}
	if len(q.GPUConsumers) != 1 || q.GPUConsumers[0].Name != "train-7" || q.GPUConsumers[0].GPUs != 1 {
		t.Fatalf("the observation must carry what was found, got %+v", q.GPUConsumers)
	}
}

// The trap, pinned as a test rather than as a comment.
//
// The simulator is where nvidia.com/gpu comes from on these nodes, it runs on every node, and it requests no
// device — so the predicate has to be "what does this Pod REQUEST", never "is this Pod something to do with
// GPUs". Rejecting the provider of the resource would make every run on every one of this lab's clusters
// refuse, and it would refuse for a reason that reads entirely plausible in the log.
//
// Mutation that turns this red: change gpuConsumersOn's test from `podGPURequest(&p.Spec) == 0` to something
// keyed on the node advertising the resource, on the priority class, or on the Pod's own name — every
// variant that "looks GPU-ish" rather than asking what was requested.
func TestQualifyDoesNotRejectTheDevicePluginThatProvidesTheResource(t *testing.T) {
	q, err := qualify(node(nil, nil), []corev1.Pod{*simulatorPod("platform-worker")}, 2, "test")
	if err != nil {
		t.Fatalf("the gpu-simulator DaemonSet was treated as a GPU consumer, so every run against every "+
			"cluster this lab has would refuse: %v", err)
	}
	if len(q.GPUConsumers) != 0 {
		t.Fatalf("the simulator was counted as a consumer: %+v", q.GPUConsumers)
	}
	if q.PodsOnNode != 1 {
		t.Fatalf("PodsOnNode = %d, want 1: a clean verdict with no denominator cannot be told apart from a "+
			"List that looked in the wrong place", q.PodsOnNode)
	}
}

// A Pod with a deletionTimestamp is still Running and still holds its device until the kubelet is finished
// with it — and it is invisible to a taint, which is why it is the state a previous run's stuck teardown
// leaves behind and the state this check most needs to see.
//
// Mutation that turns this red: skip Pods with a deletionTimestamp in gpuConsumersOn (the natural "it is
// going away anyway" reading), or test holdsDevices on the deletion timestamp instead of on the phase.
func TestQualifyCountsATerminatingGPUPodBecauseItStillHoldsTheDevice(t *testing.T) {
	dying := gpuPod("tenant-a", "train-8", "platform-worker", 2)
	ts := metav1.NewTime(time.Now())
	dying.DeletionTimestamp = &ts
	dying.Finalizers = []string{"kubernetes"}

	q, err := qualify(node(nil, nil), []corev1.Pod{*dying}, 2, "test")
	if err == nil {
		t.Fatal("a terminating GPU Pod was treated as gone: it holds both devices until the kubelet finishes, " +
			"and the run would have measured against nothing at all")
	}
	if len(q.GPUConsumers) != 1 || !q.GPUConsumers[0].Terminating {
		t.Fatalf("the observation must record that it was terminating, since that is what tells the operator " +
			"to wait rather than to go looking for whose job it is")
	}
	if !strings.Contains(err.Error(), "terminating") {
		t.Fatalf("the refusal %q does not distinguish a Pod that will clear itself from one that will not", err)
	}
}

// Two exclusions, both of which would otherwise refuse runs on perfectly good clusters: a GPU Pod on the
// OTHER worker is not on this run's machine at all, and a Succeeded one has already had its device released
// by the kubelet and is only waiting to be garbage collected. This lab's clusters accumulate both.
//
// Mutation that turns this red: drop the `p.Spec.NodeName != node` guard, or drop the holdsDevices guard.
// Either one alone makes this test fail, and either one alone would make a run refuse over a Pod on another
// machine or a Pod that finished days ago.
func TestQualifyIgnoresPodsOnOtherNodesAndPodsThatHaveFinished(t *testing.T) {
	elsewhere := gpuPod("tenant-a", "train-9", "platform-worker2", 2)
	finished := gpuPod("tenant-b", "train-old", "platform-worker", 2)
	finished.Status.Phase = corev1.PodSucceeded
	failed := gpuPod("tenant-b", "train-crashed", "platform-worker", 2)
	failed.Status.Phase = corev1.PodFailed

	q, err := qualify(node(nil, nil), []corev1.Pod{*elsewhere, *finished, *failed}, 2, "test")
	if err != nil {
		t.Fatalf("a worker whose only GPU Pods are on another node or already finished was refused: %v", err)
	}
	if len(q.GPUConsumers) != 0 {
		t.Fatalf("nothing on this node holds a device, got %+v", q.GPUConsumers)
	}
	if q.PodsOnNode != 2 {
		t.Fatalf("PodsOnNode = %d, want 2: the Pod on the other worker must not be counted in this node's "+
			"denominator either", q.PodsOnNode)
	}
}

// The run installs its own NoSchedule taint moments before this check, so a qualification that objected to
// taints would refuse every run on the marker the run itself put there — and it would do it AFTER the worker
// was acquired, so every invocation would also have to be recovered by hand.
//
// Mutation that turns this red: add a "the node carries no NoSchedule taint" condition to qualify.
func TestQualifyAcceptsTheRunsOwnOwnershipTaint(t *testing.T) {
	ours := node(map[string]string{workerLabelKey: "r7"}, nil, ourTaint())
	if _, err := qualify(ours, nil, 2, "test"); err != nil {
		t.Fatalf("the worker was refused for the marker this run installed on it a moment earlier: %v", err)
	}
}

// Capacity is derived, and a node that cannot back the whole arm is a node the arm completes on while
// measuring something else: with one device the two reclaim queues never both hold a workload, so the
// borrow-then-reclaim contrast never happens and the run reports its absence as a result.
//
// Mutation that turns this red: drop the `q.AllocatableGPU < required` branch from qualify.
func TestQualifyRefusesANodeTooSmallForTheArm(t *testing.T) {
	small := node(nil, nil)
	small.Status.Allocatable[gpuResourceName] = *resource.NewQuantity(1, resource.DecimalSI)

	q, err := qualify(small, nil, 2, "nominal quota over 2 ClusterQueue(s)")
	if err == nil {
		t.Fatal("a one-device node was accepted for a two-device arm: the run completes and reports the " +
			"contrast it structurally could not produce")
	}
	if !strings.Contains(err.Error(), "ClusterQueue") {
		t.Fatalf("the refusal %q does not say where the requirement came from, which is what tells the "+
			"operator whether to grow the node or fix the fixtures", err)
	}
	if q.AllocatableGPU != 1 || q.RequiredGPU != 2 {
		t.Fatalf("the observation must carry both numbers, got %+v", q)
	}
}

// Ready and schedulable are two separate facts and both are reported, because an operator who cordoned a node
// and also let it go NotReady should not have to run the tool twice to find that out. The missing-condition
// case is in here deliberately: a Node object with no Ready condition at all must fail toward the refusal,
// the same way an unclassifiable teardown target holds the worker.
//
// Mutation that turns this red: make nodeReady return true when no Ready condition is present, or drop the
// Schedulable branch from qualify.
func TestQualifyRefusesANodeThatIsNotReadyOrIsCordoned(t *testing.T) {
	notReady := node(nil, nil)
	notReady.Status.Conditions = []corev1.NodeCondition{{Type: corev1.NodeReady, Status: corev1.ConditionFalse}}
	if _, err := qualify(notReady, nil, 2, "test"); err == nil {
		t.Fatal("a NotReady worker was accepted")
	}

	silent := node(nil, nil)
	silent.Status.Conditions = nil
	if _, err := qualify(silent, nil, 2, "test"); err == nil {
		t.Fatal("a Node reporting no Ready condition at all was accepted: an unclassifiable machine must fail " +
			"toward the refusal, not toward the measurement")
	}

	cordoned := node(nil, nil)
	cordoned.Spec.Unschedulable = true
	q, err := qualify(cordoned, nil, 2, "test")
	if err == nil {
		t.Fatal("a cordoned worker was accepted: nothing this run submits can land on it, so the whole run " +
			"would time out at its first barrier with no explanation")
	}
	if q.Schedulable {
		t.Fatal("the observation must record the cordon it refused on")
	}
	if !strings.Contains(err.Error(), "cordoned") {
		t.Fatalf("the refusal %q does not name the cordon", err)
	}
}

// One node, three things wrong with it. Reporting only the first would make an operator pay a round trip
// against a real cluster per defect, which on a lab whose runs are minutes long is the difference between one
// correction and three.
//
// Mutation that turns this red: return on the first failed condition in qualify instead of accumulating them.
func TestQualifyReportsEveryConditionItFailedNotJustTheFirst(t *testing.T) {
	bad := node(nil, nil)
	bad.Status.Allocatable[gpuResourceName] = *resource.NewQuantity(1, resource.DecimalSI)
	bad.Spec.Unschedulable = true

	_, err := qualify(bad, []corev1.Pod{*gpuPod("tenant-a", "train-7", "platform-worker", 1)}, 2, "test")
	if err == nil {
		t.Fatal("a node that failed three conditions qualified")
	}
	for _, want := range []string{"cordoned", "allocatable", "train-7"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("the refusal does not mention %q, so the operator fixes one thing and meets the next on "+
				"the following run:\n%s", want, err)
		}
	}
}

// A Pod may name only the limit and have the request defaulted to match it, which is how a great many GPU
// Pods are actually written. Reading Requests alone scores exactly those Pods as consuming nothing, and they
// are the ones most likely to be sitting on a shared lab worker.
//
// Mutation that turns this red: delete the Limits fallback from gpuOf.
func TestPodGPURequestReadsALimitOnlyPod(t *testing.T) {
	limitOnly := gpuPod("tenant-a", "train-10", "platform-worker", 1)
	limitOnly.Spec.Containers[0].Resources.Requests = nil
	if got := podGPURequest(&limitOnly.Spec); got != 1 {
		t.Fatalf("podGPURequest = %d, want 1: a Pod that names only its limit has its request defaulted to "+
			"match, and reading Requests alone makes it invisible", got)
	}

	// An init container's device is held while it runs, and it is the only thing running at that moment, so
	// the effective request is the larger of the two rather than the regular containers' sum alone.
	initOnly := gpuPod("tenant-a", "train-11", "platform-worker", 0)
	initOnly.Spec.Containers[0].Resources = corev1.ResourceRequirements{}
	initOnly.Spec.InitContainers = []corev1.Container{{
		Name: "fetch",
		Resources: corev1.ResourceRequirements{
			Requests: corev1.ResourceList{gpuResourceName: *resource.NewQuantity(2, resource.DecimalSI)},
		},
	}}
	if got := podGPURequest(&initOnly.Spec); got != 2 {
		t.Fatalf("podGPURequest = %d, want 2: an init container holds its device while it runs", got)
	}
}

// A run that could not read the Pods on its worker has not established the premise it is about to measure
// under. Treating an unreadable cluster as a clean one is the substitution — absence of evidence for evidence
// of absence — that this whole gate exists to stop, and it is the shape an RBAC gap takes: the runner is
// newly required to list Pods cluster-wide, and a cluster where it may not is the cluster where this would
// silently pass.
//
// Mutation that turns this red: swallow the List error in qualifyWorker and carry on with no Pods.
func TestQualifyWorkerRefusesWhenItCannotSeeThePods(t *testing.T) {
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(node(nil, nil)).
		WithInterceptorFuncs(interceptor.Funcs{
			List: func(ctx context.Context, c client.WithWatch, list client.ObjectList,
				opts ...client.ListOption) error {
				if _, ok := list.(*corev1.PodList); ok {
					return apierrors.NewForbidden(schema.GroupResource{Resource: "pods"}, "",
						errors.New("no list permission on pods at cluster scope"))
				}
				return c.List(ctx, list, opts...)
			},
		}).Build()

	q, err := qualifyWorker(context.Background(), fc, "platform-worker", 2, "test")
	if err == nil {
		t.Fatal("a worker whose Pods could not be listed was qualified, which is exactly how an RBAC gap on " +
			"Pods would present itself: as a clean cluster")
	}
	if q != nil {
		t.Fatal("no qualification may be returned from a read that failed: a document full of zero values " +
			"claims a node advertising nothing and carrying no Pods was inspected and found fine")
	}
}

// The observation has to be returned alongside the refusal, not instead of it. A refused run is precisely the
// run whose evidence would otherwise be a sentence on somebody's terminal, and the later
// validity-bearing-artifact gate can only be serialization of what each gate wrote if each gate wrote.
//
// Mutation that turns this red: return `nil, err` from qualifyWorker when qualify refuses.
func TestQualifyWorkerReturnsWhatItSawEvenWhenItRefuses(t *testing.T) {
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).
		WithObjects(node(nil, nil), gpuPod("tenant-a", "train-7", "platform-worker", 2),
			simulatorPod("platform-worker")).
		Build()

	q, err := qualifyWorker(context.Background(), fc, "platform-worker", 2, "nominal quota")
	if err == nil {
		t.Fatal("the contaminated worker qualified")
	}
	if q == nil {
		t.Fatal("a refusal with no observation leaves the record saying only that something was wrong")
	}
	if q.Node != "platform-worker" || q.NodeUID != "uid-node" {
		t.Fatalf("the observation must identify the machine it is about, got %+v", q)
	}
	if q.AllocatableGPU != 2 || q.RequiredGPU != 2 || q.RequiredFrom != "nominal quota" {
		t.Fatalf("the observation must carry the capacity claim and where the requirement came from, got %+v", q)
	}
	if !q.Ready || !q.Schedulable {
		t.Fatalf("readiness must be recorded even when it was not the reason for the refusal, got %+v", q)
	}
	if q.PodsOnNode != 2 || len(q.GPUConsumers) != 1 {
		t.Fatalf("PodsOnNode = %d and %d consumer(s): the verdict and its denominator are one claim",
			q.PodsOnNode, len(q.GPUConsumers))
	}
}
