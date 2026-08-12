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
	"fmt"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
	kueuev1beta2 "sigs.k8s.io/kueue/apis/kueue/v1beta2"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/queuelab"
)

// observationFor finds the observation for a named target, failing the test rather than returning a zero
// value: a missing observation is exactly the defect TestRecoverEmitsOneObservationPerEnumeratedTarget
// exists to catch, and a caller that silently got a zero-value observation back would test the wrong thing.
func observationFor(t *testing.T, obs []observation, name string) observation {
	t.Helper()
	for _, o := range obs {
		if o.Target.Name == name {
			return o
		}
	}
	t.Fatalf("no observation for target %q", name)
	return observation{}
}

// recoverTargets ranges over enumerate's output and emits exactly one observation per target, error paths
// included. The loop is the coverage guarantee: a target that produced no observation would silently not
// appear in the residue, and "no residue" would read as clear.
func TestRecoverEmitsOneObservationPerEnumeratedTarget(t *testing.T) {
	s := testSeed()
	want, err := enumerate(s)
	if err != nil {
		t.Fatalf("enumerate: %v", err)
	}
	c := fake.NewClientBuilder().WithScheme(fullScheme(t)).Build()
	got, err := recoverTargets(context.Background(), c, s, "tx-1")
	if err != nil {
		t.Fatalf("recover: %v", err)
	}
	if len(got) != len(want) {
		t.Fatalf("recover emitted %d observations for %d targets; an unobserved target vanishes from the residue", len(got), len(want))
	}
	seen := map[string]bool{}
	for _, o := range got {
		seen[o.Target.Name] = true
	}
	for _, tg := range want {
		if !seen[tg.Name] {
			t.Errorf("no observation for target %s %q", tg.Kind, tg.Name)
		}
	}
}

// A read that fails must still produce an observation carrying the error, because classifyAbsence turns that
// into absenceUnknown — residue. Skipping it would drop the target out of the audit entirely.
//
// The count check below is load-bearing, not decorative: every Get in this test fails, so a recoverTargets
// that silently dropped a target on read error (a `continue` instead of an append) would leave got empty,
// and the loop that follows would range over nothing and report no failure at all — the exact way a batch
// that "liked the look of nothing" would still read green.
func TestRecoverEmitsAnObservationEvenWhenTheReadFails(t *testing.T) {
	s := testSeed()
	want, err := enumerate(s)
	if err != nil {
		t.Fatalf("enumerate: %v", err)
	}
	c := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithInterceptorFuncs(interceptor.Funcs{
		Get: func(ctx context.Context, cl client.WithWatch, key client.ObjectKey, obj client.Object, opts ...client.GetOption) error {
			return errors.New("etcdserver: request timed out")
		},
	}).Build()
	got, err := recoverTargets(context.Background(), c, s, "tx-1")
	if err != nil {
		t.Fatalf("recover: %v", err)
	}
	if len(got) != len(want) {
		t.Fatalf("recover emitted %d observations for %d targets after every read failed; a dropped observation would misreport the batch as clean", len(got), len(want))
	}
	for _, o := range got {
		if o.Err == nil {
			t.Fatalf("%s carries no error after a failed read; it would classify as absent", o.Target.Name)
		}
		if classifyAbsence(o, o.WantUID) != absenceUnknown {
			t.Fatalf("%s classified as %v after a failed read, want unknown", o.Target.Name, classifyAbsence(o, o.WantUID))
		}
	}
}

// The UID is learned here, not supplied. An object found without our stamp is another run's, and must reach
// the caller as foreign rather than as a deletion candidate.
func TestRecoverLearnsOurUIDAndMarksAForeignObjectForeign(t *testing.T) {
	s := testSeed()
	c := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithObjects(
		&corev1.Namespace{ObjectMeta: metav1.ObjectMeta{
			Name: s.Namespace, UID: "ns-uid", Labels: map[string]string{queuelab.TxLabel: "tx-1"}}},
	).Build()
	got, err := recoverTargets(context.Background(), c, s, "tx-1")
	if err != nil {
		t.Fatalf("recover: %v", err)
	}
	ns := observationFor(t, got, s.Namespace)
	if ns.UID != "ns-uid" || ns.WantUID != "ns-uid" {
		t.Fatalf("namespace observation carries UID %q / WantUID %q, want both ns-uid: the UID is an output of this pass", ns.UID, ns.WantUID)
	}
	if classifyAbsence(ns, ns.WantUID) != absencePresent {
		t.Fatalf("our own stamped namespace classified as %v, want present", classifyAbsence(ns, ns.WantUID))
	}
}

// txID is a caller-supplied parameter alongside s, which already carries s.TxID; nothing before this test
// forced them to agree. Left unguarded, a caller passing "" would match an unstamped object's absent label
// (both are the empty string) and adopt it as this run's own, collapsing the very refusal
// TestRecoverRefusesAnObjectStampedByAnotherTransaction asserts; a caller passing a mismatched non-empty
// txID would adopt whatever that other transaction stamped instead of this run's own seed. enumerate refuses
// an empty s.TxID at teardown.go:77 on exactly this "empty is not delete less, it is delete a different,
// wrong thing" reasoning, but that guard cannot reach a parameter that routes around the seed entirely.
func TestRecoverRefusesWhenTxIDDisagreesWithTheSeed(t *testing.T) {
	s := testSeed() // s.TxID == "tx-1"

	unstamped := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithObjects(
		&corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: s.Namespace, UID: "somebody-elses"}},
	).Build()
	if _, err := recoverTargets(context.Background(), unstamped, s, ""); err == nil {
		t.Fatal("recovery accepted an empty txID, which matched an unstamped object's absent label and would adopt it as ours")
	}

	theirs := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithObjects(
		&corev1.Namespace{ObjectMeta: metav1.ObjectMeta{
			Name: s.Namespace, UID: "theirs", Labels: map[string]string{queuelab.TxLabel: "tx-99"}}},
	).Build()
	if _, err := recoverTargets(context.Background(), theirs, s, "tx-99"); err == nil {
		t.Fatal("recovery accepted a txID of tx-99 against a seed whose own TxID is tx-1, adopting another transaction's namespace")
	}
}

// Ownership is established here, by stamp, and a foreign stamp is a refusal rather than an observation.
//
// classifyAbsence decides foreignness by UID comparison, which needs a UID we recorded for an object we
// created. For an object we never created there is no such UID, so recovery cannot express "foreign" as an
// observation without inventing one. It refuses instead — the same answer ensureNamespace gives at create.
// absenceForeign remains the executor's: during polling it re-reads with a WantUID this pass established,
// and an object replaced under that name mid-teardown is exactly what it detects.
func TestRecoverRefusesAnObjectStampedByAnotherTransaction(t *testing.T) {
	s := testSeed()
	c := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithObjects(
		&corev1.Namespace{ObjectMeta: metav1.ObjectMeta{
			Name: s.Namespace, UID: "theirs", Labels: map[string]string{queuelab.TxLabel: "tx-2"}}},
	).Build()
	if _, err := recoverTargets(context.Background(), c, s, "tx-1"); err == nil {
		t.Fatal("recovery adopted a namespace stamped by another transaction; deleting it would destroy another run's live state")
	}

	unstamped := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithObjects(
		&corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: s.Namespace, UID: "nobody"}},
	).Build()
	if _, err := recoverTargets(context.Background(), unstamped, s, "tx-1"); err == nil {
		t.Fatal("recovery adopted an unstamped namespace; it predates stamping or was created by something else, and either way is not ours to delete")
	}
}

// Every target kind must actually be read back as itself, not just Namespace: every other test in this file
// seeds at most a Namespace, so a ClusterQueue or ResourceFlavor read under the wrong empty object type (a
// kind-confusion in emptyObjectFor), or looked up by the wrong name (e.g. always Get-ing s.Namespace instead
// of each target's own tg.Name), would come back NotFound against a cluster that actually holds it — and
// nothing before this test could see that, because nothing before this test put one there.
func TestRecoverReadsEveryTargetKindByItsOwnKindAndName(t *testing.T) {
	s := testSeed()
	fs, err := queuelab.BuildFixtures(s.Study, s.Variant, s.TxID, s.RunID, s.Namespace)
	if err != nil {
		t.Fatalf("build fixtures: %v", err)
	}
	b := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithObjects(
		&corev1.Namespace{ObjectMeta: metav1.ObjectMeta{
			Name: s.Namespace, UID: "ns-uid", Labels: map[string]string{queuelab.TxLabel: s.TxID}}},
		&kueuev1beta2.ResourceFlavor{ObjectMeta: metav1.ObjectMeta{
			Name: fs.Flavor.GetName(), UID: "rf-uid", Labels: map[string]string{queuelab.TxLabel: s.TxID}}},
	)
	for i, cq := range fs.ClusterQueue {
		b = b.WithObjects(&kueuev1beta2.ClusterQueue{ObjectMeta: metav1.ObjectMeta{
			Name: cq.GetName(), UID: types.UID(fmt.Sprintf("cq-uid-%d", i)),
			Labels: map[string]string{queuelab.TxLabel: s.TxID}}})
	}
	wantUID := map[string]string{s.Namespace: "ns-uid", fs.Flavor.GetName(): "rf-uid"}
	for i, cq := range fs.ClusterQueue {
		wantUID[cq.GetName()] = fmt.Sprintf("cq-uid-%d", i)
	}
	got, err := recoverTargets(context.Background(), b.Build(), s, s.TxID)
	if err != nil {
		t.Fatalf("recover: %v", err)
	}
	if len(fs.ClusterQueue) == 0 {
		t.Fatalf("fixture set built no ClusterQueue; this test needs at least one to exercise that kind")
	}
	for _, o := range got {
		if !o.Found {
			t.Errorf("%s %q not found though it was seeded on the cluster", o.Target.Kind, o.Target.Name)
			continue
		}
		// The UID must be THIS object's, not merely some non-empty string: the executor feeds WantUID to
		// client.Preconditions{UID:}, so a cross-wired or constant UID makes every delete precondition miss
		// and leaves a deletable object sitting in the residue.
		if o.UID != wantUID[o.Target.Name] || o.WantUID != o.UID {
			t.Errorf("%s %q learned UID %q / WantUID %q, want both %q", o.Target.Kind, o.Target.Name, o.UID, o.WantUID, wantUID[o.Target.Name])
		}
		// Nothing here was seeded with a deletionTimestamp. An observation that claims otherwise would make
		// an executor treat every object as already-deleting and never issue a Delete at all.
		if o.Terminating {
			t.Errorf("%s %q came back Terminating though it was seeded live", o.Target.Kind, o.Target.Name)
		}
		if classifyAbsence(o, o.WantUID) != absencePresent {
			t.Errorf("%s %q classified as %v, want present", o.Target.Kind, o.Target.Name, classifyAbsence(o, o.WantUID))
		}
	}
}

// The ownership check applies to every kind, not just Namespace: a ClusterQueue or ResourceFlavor stamped by
// another transaction is exactly as much a name collision as a Namespace is, and deleting it destroys that
// other run's live quota just as surely.
func TestRecoverRefusesAForeignClusterQueue(t *testing.T) {
	s := testSeed()
	fs, err := queuelab.BuildFixtures(s.Study, s.Variant, s.TxID, s.RunID, s.Namespace)
	if err != nil {
		t.Fatalf("build fixtures: %v", err)
	}
	if len(fs.ClusterQueue) == 0 {
		t.Fatalf("fixture set built no ClusterQueue; this test needs at least one to exercise that kind")
	}
	c := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithObjects(
		&corev1.Namespace{ObjectMeta: metav1.ObjectMeta{
			Name: s.Namespace, UID: "ns-uid", Labels: map[string]string{queuelab.TxLabel: s.TxID}}},
		&kueuev1beta2.ClusterQueue{ObjectMeta: metav1.ObjectMeta{
			Name: fs.ClusterQueue[0].GetName(), UID: "theirs", Labels: map[string]string{queuelab.TxLabel: "tx-2"}}},
	).Build()
	if _, err := recoverTargets(context.Background(), c, s, s.TxID); err == nil {
		t.Fatal("recovery adopted a ClusterQueue stamped by another transaction; deleting it would destroy another run's live quota")
	}
}

// emptyObjectFor must fail loudly on a kind it does not recognize, per its own comment: silently defaulting
// to some other kind's empty object would misread whatever is actually at that name.
func TestEmptyObjectForRejectsAnUnknownKind(t *testing.T) {
	if _, err := emptyObjectFor(target{Kind: "Workload", Name: "whatever"}); err == nil {
		t.Fatal("emptyObjectFor accepted an unregistered kind instead of erroring; a new target kind added to enumerate would silently misread")
	}
}

// A target absent from the cluster must classify as absent, not merely be Found:false and left for the
// caller to reclassify correctly; the case order in recoverTargets's switch (NotFound checked before the
// general error case) is what makes that distinction, and residual must actually drop it.
func TestRecoverNotFoundClassifiesAbsentAndDropsFromResidual(t *testing.T) {
	s := testSeed()
	c := fake.NewClientBuilder().WithScheme(fullScheme(t)).Build()
	got, err := recoverTargets(context.Background(), c, s, s.TxID)
	if err != nil {
		t.Fatalf("recover: %v", err)
	}
	if len(got) == 0 {
		t.Fatalf("recover returned no observations against an empty cluster")
	}
	for _, o := range got {
		if o.Found {
			t.Errorf("%s %q reported Found on an empty cluster", o.Target.Kind, o.Target.Name)
		}
		if classifyAbsence(o, o.WantUID) != absenceAbsent {
			t.Errorf("%s %q classified as %v on an empty cluster, want absent", o.Target.Kind, o.Target.Name, classifyAbsence(o, o.WantUID))
		}
	}
	if r := residual(got); len(r) != 0 {
		t.Errorf("residual reported %d leftovers on an empty cluster, want 0", len(r))
	}
}

// Terminating must survive from the read into the observation: the executor needs it to tell "deletion
// already requested, keep polling" from "issue the Delete," and to explain a stuck finalizer in the residue
// record. classifyAbsence does not depend on it today (a terminating object still classifies present, same
// as an ordinary one), which is exactly why dropping it silently would pass every other test in this file.
func TestRecoverCarriesTerminatingThrough(t *testing.T) {
	s := testSeed()
	now := metav1.NewTime(time.Now())
	c := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithObjects(
		&corev1.Namespace{ObjectMeta: metav1.ObjectMeta{
			Name: s.Namespace, UID: "ns-uid", DeletionTimestamp: &now,
			Finalizers: []string{"queuelab.gpu-platform/hold"},
			Labels:     map[string]string{queuelab.TxLabel: s.TxID}}},
	).Build()
	got, err := recoverTargets(context.Background(), c, s, s.TxID)
	if err != nil {
		t.Fatalf("recover: %v", err)
	}
	ns := observationFor(t, got, s.Namespace)
	if !ns.Terminating {
		t.Fatal("a namespace with a deletionTimestamp did not come back Terminating")
	}
}

// enumerate documents its return value as the ordered deletion set, and the executor's plan-mandated
// interface is the slice recoverTargets returns — the natural reading is that the order survives unchanged
// so the executor can trust it without re-sorting on Target.Phase itself. A silent reorder (e.g. the
// ResourceFlavor observation ending up before the Namespace one) would invert phase-ordered deletes: an
// executor trusting the slice would issue the ResourceFlavor delete first, and it would block on its own
// finalizer because every referencing ClusterQueue is still there.
func TestRecoverPreservesEnumeratesOrder(t *testing.T) {
	s := testSeed()
	want, err := enumerate(s)
	if err != nil {
		t.Fatalf("enumerate: %v", err)
	}
	c := fake.NewClientBuilder().WithScheme(fullScheme(t)).Build()
	got, err := recoverTargets(context.Background(), c, s, s.TxID)
	if err != nil {
		t.Fatalf("recover: %v", err)
	}
	if len(got) != len(want) {
		t.Fatalf("recover returned %d observations, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i].Target.Name != want[i].Name || got[i].Target.Kind != want[i].Kind {
			t.Fatalf("recover reordered position %d: got %s %q, want %s %q",
				i, got[i].Target.Kind, got[i].Target.Name, want[i].Kind, want[i].Name)
		}
	}
}
