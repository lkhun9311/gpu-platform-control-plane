package main

import (
	"context"
	"fmt"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
)

// These specs cover the recovery printout for a worker held by a PROBE, which had no test at all.
//
// The defect they pin is not hypothetical and was not caused by the change that fixes it. printRecoverable
// rebuilt the termination canary's two Pod names from the journal's id and printed them for every holder of
// kind canary — but the device preflight acquires the worker under that same kind and creates exactly ONE
// Pod, named differently. So the tool an operator reaches for when a node is stuck named two Pods that had
// never existed, and did not name the one that had.

// canaryHeldNode returns a journal of kind canary and the Node carrying it.
//
// Kind canary rather than run because that is what both probes write, and the printout under test is the one
// chosen by that kind.
func canaryHeldNode(t *testing.T, canaryID string) *corev1.Node {
	t.Helper()
	j := journal{
		Schema: journalSchema, TxID: "tx-c", RunID: canaryRunID(canaryID), Arm: canaryArm,
		Kind: ownerCanary, CanaryID: canaryID, Namespace: canaryNamespace,
		Node: "platform-worker", NodeUID: "uid-node", TakenAt: "t0",
		Installed: installedTuple{
			LabelValue: canaryRunID(canaryID), TaintValue: canaryRunID(canaryID),
			TaintEffect: corev1.TaintEffectNoSchedule,
		},
	}
	raw, err := encodeJournal(j)
	if err != nil {
		t.Fatalf("encode journal: %v", err)
	}
	return node(map[string]string{workerLabelKey: canaryRunID(canaryID)},
		map[string]string{journalKey: raw},
		corev1.Taint{
			Key: workerTaintKey, Value: canaryRunID(canaryID), Effect: corev1.TaintEffectNoSchedule,
		})
}

// probePod is one Pod as a probe leaves it: in the shared namespace, carrying the id in the selected label.
func probePod(name, canaryID string) *corev1.Pod {
	return &corev1.Pod{ObjectMeta: metav1.ObjectMeta{
		Name: name, Namespace: canaryNamespace,
		Labels: map[string]string{canaryProbeLabel: canaryID},
	}}
}

// THE defect, in the shape that produced it: a stranded device preflight.
//
// Its Pod is `dp-<short>`, and the old printout named `tc-<short>-honor` and `tc-<short>-ignore` instead —
// two Pods that never existed, while the one holding the namespace went unnamed. An operator following that
// list deletes nothing and concludes the node is stuck for some other reason.
//
// Mutation that turns this red: rebuild the names from canaryProbeSpecs instead of listing by label.
func TestInspectWorkerNamesTheProbePodThatActuallyExists(t *testing.T) {
	const id = "abcdef0123456789"
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).
		WithObjects(canaryHeldNode(t, id), probePod("dp-abcdef01", id)).Build()

	var err error
	out := captureStdout(t, func() { err = inspectWorker(context.Background(), fc, "platform-worker") })
	if err != nil {
		t.Fatalf("inspecting a held node must succeed: %v", err)
	}
	if !strings.Contains(out, "HELD by run") {
		t.Fatalf("the held branch did not run:\n%s", out)
	}
	if !strings.Contains(out, "dp-abcdef01") {
		t.Fatalf("the Pod that is actually standing was not named, so an operator is told to delete "+
			"nothing that exists:\n%s", out)
	}
	// And the names that are NOT there must stay absent, or the repair is a printout that names everything
	// and distinguishes nothing.
	for _, ghost := range []string{"tc-abcdef01-honor", "tc-abcdef01-ignore"} {
		if strings.Contains(out, ghost) {
			t.Fatalf("the printout names %q, which was never created by this holder:\n%s", ghost, out)
		}
	}
	if !strings.Contains(out, "must not be deleted") {
		t.Fatalf("the shared namespace is not marked as not-to-delete, and it sits in a list an operator "+
			"reads top to bottom:\n%s", out)
	}
}

// The termination canary's own case, which the old code got right by construction and must keep getting
// right now that the names come from the cluster.
//
// Mutation that turns this red: list without the label selector, or in the wrong namespace.
func TestInspectWorkerNamesBothCanaryProbePods(t *testing.T) {
	const id = "0123456789abcdef"
	honor, ignore := canaryProbeSpecs(id, canaryContract{})
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(
		canaryHeldNode(t, id), probePod(honor.name, id), probePod(ignore.name, id),
		// A Pod of ANOTHER probe attempt, which must not be listed: the id is what scopes the deletion list,
		// and a printout that swept the shared namespace would invite an operator to delete a live probe.
		probePod("tc-ffffffff-honor", "ffffffffffffffff"),
	).Build()

	var err error
	out := captureStdout(t, func() { err = inspectWorker(context.Background(), fc, "platform-worker") })
	if err != nil {
		t.Fatalf("inspecting a held node must succeed: %v", err)
	}
	for _, want := range []string{honor.name, ignore.name} {
		if !strings.Contains(out, want) {
			t.Fatalf("probe Pod %q was not named:\n%s", want, out)
		}
	}
	if strings.Contains(out, "tc-ffffffff-honor") {
		t.Fatalf("another attempt's Pod was listed as this holder's, and the list is one an operator "+
			"deletes from:\n%s", out)
	}
}

// An empty result is a different fact from a failed list, and collapsing them is what the repair must not do.
//
// Nothing to delete means the journal alone is holding the worker, which points the operator at
// -release-stale rather than at kubectl. The old code printed two Pod names here unconditionally.
//
// Mutation that turns this red: print the deletion list regardless of how many Pods came back.
func TestInspectWorkerSaysWhenAProbeLeftNoPods(t *testing.T) {
	const id = "fedcba9876543210"
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(canaryHeldNode(t, id)).Build()

	var err error
	out := captureStdout(t, func() { err = inspectWorker(context.Background(), fc, "platform-worker") })
	if err != nil {
		t.Fatalf("inspecting a held node must succeed: %v", err)
	}
	if !strings.Contains(out, "already gone") {
		t.Fatalf("an empty result must say so; a held node with nothing of its own left is a different "+
			"state from one with Pods standing:\n%s", out)
	}
	if strings.Contains(out, "Pod tc-") || strings.Contains(out, "Pod dp-") {
		t.Fatalf("a Pod was named although none exists:\n%s", out)
	}
}

// A list that failed must say it failed, and must not fall back to the reconstruction it replaced.
//
// A guess printed where a reading failed is the exact shape of the defect being repaired: it looks like an
// answer. The operator gets the label to search by instead, which is true whatever the apiserver did.
//
// Mutation that turns this red: swallow the List error, or print rebuilt names as a fallback.
func TestInspectWorkerAdmitsWhenItCouldNotListTheProbePods(t *testing.T) {
	const id = "aaaabbbbccccdddd"
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(canaryHeldNode(t, id)).
		WithInterceptorFuncs(interceptor.Funcs{
			List: func(ctx context.Context, c client.WithWatch, list client.ObjectList,
				opts ...client.ListOption) error {
				if _, ok := list.(*corev1.PodList); ok {
					return fmt.Errorf("apiserver unreachable")
				}
				return c.List(ctx, list, opts...)
			},
		}).Build()

	var err error
	out := captureStdout(t, func() { err = inspectWorker(context.Background(), fc, "platform-worker") })
	if err != nil {
		t.Fatalf("a failed Pod listing must not turn the whole inspection into an error: %v", err)
	}
	if !strings.Contains(out, "could not be listed") {
		t.Fatalf("the failure was not reported, so the absence of a Pod list reads as an absence of "+
			"Pods:\n%s", out)
	}
	if !strings.Contains(out, canaryProbeLabel) || !strings.Contains(out, id) {
		t.Fatalf("the operator was not told what to search for:\n%s", out)
	}
	if strings.Contains(out, "Pod tc-") || strings.Contains(out, "Pod dp-") {
		t.Fatalf("a name was reconstructed after the listing failed, which is a guess wearing the shape of "+
			"a reading:\n%s", out)
	}
}
