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
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
)

func testScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		t.Fatalf("add to scheme: %v", err)
	}
	return scheme
}

func conflictErr(name string) error {
	return apierrors.NewConflict(schema.GroupResource{Resource: "nodes"}, name, fmt.Errorf("conflict"))
}

// lostResponseErr is a non-conflict failure of the kind that proves nothing about whether the write
// committed: this is exactly the class of error resolveAmbiguousAcquire exists to resolve, since retrying
// it blindly could double-apply and refusing it blindly could abandon a node still carrying our markers.
func lostResponseErr() error {
	return apierrors.NewInternalError(fmt.Errorf("connection reset by peer"))
}

// The optimistic lock only does its job if a 409 makes the caller re-read and re-decide rather than resend
// the same patch: this is the mechanism the whole design exists for, and until now nothing exercised it.
func TestAcquireWorkerRetriesConflictWithFreshReadAndDecide(t *testing.T) {
	n := node(nil, nil)
	var getCalls, patchCalls int
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(n).WithInterceptorFuncs(interceptor.Funcs{
		Get: func(ctx context.Context, c client.WithWatch, key client.ObjectKey, obj client.Object,
			opts ...client.GetOption) error {
			getCalls++
			return c.Get(ctx, key, obj, opts...)
		},
		Patch: func(ctx context.Context, c client.WithWatch, obj client.Object, patch client.Patch,
			opts ...client.PatchOption) error {
			patchCalls++
			if patchCalls == 1 {
				return conflictErr(obj.GetName())
			}
			return c.Patch(ctx, obj, patch, opts...)
		},
	}).Build()

	j, err := acquireWorker(context.Background(), fc, "platform-worker", "tx-a", "r1", "A-honor")
	if err != nil {
		t.Fatalf("acquire must succeed once the second attempt lands: %v", err)
	}
	if j.TxID != "tx-a" {
		t.Fatalf("journal txid = %q, want tx-a", j.TxID)
	}
	if patchCalls != 2 {
		t.Fatalf("want exactly 2 patch attempts (1 conflict + 1 success), got %d", patchCalls)
	}
	// One Get per acquire-loop attempt (2) plus verifyAcquired's own Get (1): the second patch attempt can
	// only have succeeded against the tracker's current resourceVersion if it was built from a fresh Get
	// rather than resending the stale patch built from the first Get.
	if getCalls != 3 {
		t.Fatalf("want 3 gets (2 acquire attempts + 1 verify), got %d — the retry did not re-read", getCalls)
	}
}

// A conflict that never clears must not spin forever: it has to refuse once the bound is exhausted.
func TestAcquireWorkerRefusesAfterConflictBoundNotSpin(t *testing.T) {
	n := node(nil, nil)
	var getCalls, patchCalls int
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(n).WithInterceptorFuncs(interceptor.Funcs{
		Get: func(ctx context.Context, c client.WithWatch, key client.ObjectKey, obj client.Object,
			opts ...client.GetOption) error {
			getCalls++
			return c.Get(ctx, key, obj, opts...)
		},
		Patch: func(ctx context.Context, c client.WithWatch, obj client.Object, patch client.Patch,
			opts ...client.PatchOption) error {
			patchCalls++
			return conflictErr(obj.GetName())
		},
	}).Build()

	_, err := acquireWorker(context.Background(), fc, "platform-worker", "tx-b", "r1", "A-honor")
	if err == nil {
		t.Fatal("acquire must refuse once the conflict bound is exhausted")
	}
	if patchCalls != acquireAttempts {
		t.Fatalf("want exactly %d patch attempts (the bound), got %d — it did not stop spinning",
			acquireAttempts, patchCalls)
	}
	if getCalls != acquireAttempts {
		t.Fatalf("want exactly %d gets (one fresh read per attempt), got %d", acquireAttempts, getCalls)
	}
}

// A refusal from decideAcquire is a decision about observed state, not a transient failure, so it must
// return on the first read without touching the API server again.
func TestAcquireWorkerReturnsRefusalWithoutRetry(t *testing.T) {
	good, err := encodeJournal(testJournal())
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	n := node(map[string]string{workerLabelKey: "r7"}, map[string]string{journalKey: good}, ourTaint())
	var getCalls, patchCalls int
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(n).WithInterceptorFuncs(interceptor.Funcs{
		Get: func(ctx context.Context, c client.WithWatch, key client.ObjectKey, obj client.Object,
			opts ...client.GetOption) error {
			getCalls++
			return c.Get(ctx, key, obj, opts...)
		},
		Patch: func(ctx context.Context, c client.WithWatch, obj client.Object, patch client.Patch,
			opts ...client.PatchOption) error {
			patchCalls++
			return c.Patch(ctx, obj, patch, opts...)
		},
	}).Build()

	_, err = acquireWorker(context.Background(), fc, "platform-worker", "tx-c", "r9", "A-honor")
	var r *refusal
	if err == nil || !asRefusal(err, &r) || r.Reason != reasonForeignOwner {
		t.Fatalf("want a foreign-owner refusal, got %v", err)
	}
	if getCalls != 1 {
		t.Fatalf("want exactly 1 get, got %d — a refusal must not be retried", getCalls)
	}
	if patchCalls != 0 {
		t.Fatalf("want 0 patches, got %d — a refusal must not attempt to write", patchCalls)
	}
}

// This is the regression test for the critical finding in Task 3's review: acquireWorker's self-release
// must run on a fresh background context, never on ctx itself. A signal landing the instant after the
// acquire Patch commits is exactly what makes verifyAcquired fail via its ctx.Done() branch, and if the
// self-release that follows reused the same cancelled ctx, its own first Get would fail immediately, the
// release Patch would never even be attempted, and the label, taint and journal would be stranded on the
// node with nothing left to undo them — the exact failure this task exists to prevent.
//
// The interceptor simulates what a real REST client does on a cancelled context (the fake client does not
// check ctx on its own): a Get issued after ctx is cancelled fails immediately, exactly like the trace the
// review walked.
func TestAcquireWorkerSelfReleaseSurvivesContextCancelledDuringVerify(t *testing.T) {
	n := node(nil, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var patched bool
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(n).WithInterceptorFuncs(interceptor.Funcs{
		Get: func(ctx context.Context, c client.WithWatch, key client.ObjectKey, obj client.Object,
			opts ...client.GetOption) error {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return c.Get(ctx, key, obj, opts...)
		},
		Patch: func(ctx context.Context, c client.WithWatch, obj client.Object, patch client.Patch,
			opts ...client.PatchOption) error {
			if err := c.Patch(ctx, obj, patch, opts...); err != nil {
				return err
			}
			patched = true
			// The signal lands the instant after the acquire Patch commits — exactly the window
			// verifyAcquired's ctx.Done() branch, and this test, exist for.
			cancel()
			return nil
		},
	}).Build()

	if _, err := acquireWorker(ctx, fc, "platform-worker", "tx-cancel", "r1", "A-honor"); err == nil {
		t.Fatal("a cancelled verify must refuse acquisition")
	}
	if !patched {
		t.Fatal("test did not exercise the patch-then-cancel window it depends on")
	}

	var got corev1.Node
	if err := fc.Get(context.Background(), client.ObjectKey{Name: "platform-worker"}, &got); err != nil {
		t.Fatalf("get node: %v", err)
	}
	if _, ok := got.Labels[workerLabelKey]; ok {
		t.Fatalf("self-release did not run: node still carries the ownership label: %+v", got.Labels)
	}
	if _, ok := got.Annotations[journalKey]; ok {
		t.Fatalf("self-release did not run: node still carries the journal: %+v", got.Annotations)
	}
	for _, tt := range got.Spec.Taints {
		if tt.Key == workerTaintKey {
			t.Fatalf("self-release did not run: node still carries the ownership taint: %+v", tt)
		}
	}
}

// A script wrapping -inspect-worker treats a nil error as "healthy"; an unreadable quarantine record needs
// a human, and printing the warning while still returning nil would make that state indistinguishable from
// FREE or HELD to anything checking the exit code rather than reading the output.
func TestInspectWorkerReturnsErrorOnUnreadableQuarantine(t *testing.T) {
	n := node(nil, map[string]string{quarantineKey: "{not valid json"})
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(n).Build()

	if err := inspectWorker(context.Background(), fc, "platform-worker"); err == nil {
		t.Fatal("an unreadable quarantine record must return an error, not exit 0")
	}
}

// This is the round-4 finding the two-step quarantine design exists to satisfy: a second force must never
// even attempt a write, because a retry that reached the API server would overwrite the original record
// with one describing an already-emptied node, destroying the only surviving evidence of who held it.
func TestForceQuarantineRefusesWhenAlreadyQuarantinedWithoutPatching(t *testing.T) {
	q := quarantine{Schema: quarantineSchema, QuarantineID: "q1", ForcedAt: "t", Node: "platform-worker",
		NodeUID: "uid-node"}
	raw, err := encodeQuarantine(q)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	n := node(nil, map[string]string{quarantineKey: raw})
	var patchCalls int
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(n).WithInterceptorFuncs(interceptor.Funcs{
		Patch: func(ctx context.Context, c client.WithWatch, obj client.Object, patch client.Patch,
			opts ...client.PatchOption) error {
			patchCalls++
			return c.Patch(ctx, obj, patch, opts...)
		},
	}).Build()

	if err := forceQuarantine(context.Background(), fc, "platform-worker", "uid-node"); err == nil {
		t.Fatal("forcing an already-quarantined node must refuse")
	}
	if patchCalls != 0 {
		t.Fatalf("want 0 patch attempts, got %d — a refusal must never touch the API server", patchCalls)
	}

	var got corev1.Node
	if err := fc.Get(context.Background(), client.ObjectKey{Name: "platform-worker"}, &got); err != nil {
		t.Fatalf("get node: %v", err)
	}
	if got.Annotations[quarantineKey] != raw {
		t.Fatalf("the original quarantine record must survive untouched, got %q", got.Annotations[quarantineKey])
	}
}

// The happy path: forcing a held node preserves what it removes in the quarantine record and leaves the
// node carrying no label, no journal and no ownership taint — never a free node in one step.
func TestForceQuarantineBreaksAHeldNodeIntoAQuarantineRecord(t *testing.T) {
	good, err := encodeJournal(testJournal())
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	n := node(map[string]string{workerLabelKey: "r7"}, map[string]string{journalKey: good}, ourTaint())

	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(n).Build()
	if err := forceQuarantine(context.Background(), fc, "platform-worker", "uid-node"); err != nil {
		t.Fatalf("force: %v", err)
	}

	var got corev1.Node
	if err := fc.Get(context.Background(), client.ObjectKey{Name: "platform-worker"}, &got); err != nil {
		t.Fatalf("get node: %v", err)
	}
	if _, ok := got.Labels[workerLabelKey]; ok {
		t.Fatalf("force must remove the label, got %+v", got.Labels)
	}
	if _, ok := got.Annotations[journalKey]; ok {
		t.Fatalf("force must remove the journal, got %+v", got.Annotations)
	}
	for _, tt := range got.Spec.Taints {
		if tt.Key == workerTaintKey {
			t.Fatalf("force must remove the ownership taint, got %+v", tt)
		}
	}
	raw, ok := got.Annotations[quarantineKey]
	if !ok {
		t.Fatal("force must leave a quarantine record")
	}
	q, err := decodeQuarantine(raw)
	if err != nil {
		t.Fatalf("decode quarantine: %v", err)
	}
	if q.PriorJournal != good || q.ObservedLabel != "r7" {
		t.Fatalf("quarantine record does not preserve what was removed: %+v", q)
	}
}

// clearQuarantine must remove only the exact record the operator names, leaving the node otherwise free.
func TestClearQuarantineRemovesTheNamedRecord(t *testing.T) {
	q := quarantine{Schema: quarantineSchema, QuarantineID: "q1", ForcedAt: "t", Node: "platform-worker",
		NodeUID: "uid-node"}
	raw, err := encodeQuarantine(q)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	n := node(nil, map[string]string{quarantineKey: raw})
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(n).Build()

	if err := clearQuarantine(context.Background(), fc, "platform-worker", "q1"); err != nil {
		t.Fatalf("clear: %v", err)
	}

	var got corev1.Node
	if err := fc.Get(context.Background(), client.ObjectKey{Name: "platform-worker"}, &got); err != nil {
		t.Fatalf("get node: %v", err)
	}
	if _, ok := got.Annotations[quarantineKey]; ok {
		t.Fatalf("clear must remove the quarantine record, got %+v", got.Annotations)
	}
}

// releaseStale is the ordinary recovery path: it must restore the node once the operator names the correct
// transaction id, and must refuse without writing anything for the wrong one.
func TestReleaseStaleRestoresTheNamedTransaction(t *testing.T) {
	good, err := encodeJournal(testJournal())
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	n := node(map[string]string{workerLabelKey: "r7"}, map[string]string{journalKey: good}, ourTaint())
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(n).Build()

	if err := releaseStale(context.Background(), fc, "platform-worker", "tx-1111"); err != nil {
		t.Fatalf("release: %v", err)
	}

	var got corev1.Node
	if err := fc.Get(context.Background(), client.ObjectKey{Name: "platform-worker"}, &got); err != nil {
		t.Fatalf("get node: %v", err)
	}
	if _, ok := got.Labels[workerLabelKey]; ok {
		t.Fatalf("release must remove the label, got %+v", got.Labels)
	}
	if _, ok := got.Annotations[journalKey]; ok {
		t.Fatalf("release must remove the journal, got %+v", got.Annotations)
	}
}

func TestReleaseStaleRefusesTheWrongTxIDWithoutWriting(t *testing.T) {
	good, err := encodeJournal(testJournal())
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	n := node(map[string]string{workerLabelKey: "r7"}, map[string]string{journalKey: good}, ourTaint())
	var patchCalls int
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(n).WithInterceptorFuncs(interceptor.Funcs{
		Patch: func(ctx context.Context, c client.WithWatch, obj client.Object, patch client.Patch,
			opts ...client.PatchOption) error {
			patchCalls++
			return c.Patch(ctx, obj, patch, opts...)
		},
	}).Build()

	if err := releaseStale(context.Background(), fc, "platform-worker", "tx-wrong"); err == nil {
		t.Fatal("releasing the wrong tx id must refuse")
	}
	if patchCalls != 0 {
		t.Fatalf("want 0 patch attempts, got %d — a refusal must not write", patchCalls)
	}
}

// Dedicating the worker must not delete anything else the cluster put on it, and the pure-helper test in
// ownership_test.go is not enough to pin that: the merge patch replaces spec.taints wholesale, so building
// the new list from the ownership-key subset instead of the whole observed list would silently strip this
// repository's own nodehealth unhealthy taint from the worker as a side effect. Every fake-client acquire
// test elsewhere in this file uses a Node with no taints, so that substitution would pass all of them.
//
// It runs the real acquire and the real release end to end, because the two patches are where the whole
// list is actually written, and asserts an unrelated taint, label and annotation survive both.
func TestAcquireAndReleasePreserveUnrelatedNodeState(t *testing.T) {
	unrelated := corev1.Taint{Key: "gpu-platform/unhealthy", Value: "true", Effect: corev1.TaintEffectNoSchedule}
	n := node(map[string]string{"unrelated-label": "keep"}, map[string]string{"unrelated-ann": "keep"}, unrelated)
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(n).Build()

	j, err := acquireWorker(context.Background(), fc, "platform-worker", "tx-preserve", "r1", "A-honor")
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}

	var got corev1.Node
	if err := fc.Get(context.Background(), client.ObjectKey{Name: "platform-worker"}, &got); err != nil {
		t.Fatalf("get node: %v", err)
	}
	if len(got.Spec.Taints) != 2 {
		t.Fatalf("acquire must add its taint alongside the unrelated one, got %+v", got.Spec.Taints)
	}
	if !hasTaint(got.Spec.Taints, unrelated) {
		t.Fatalf("acquire deleted the unrelated taint: %+v", got.Spec.Taints)
	}
	if got.Labels["unrelated-label"] != "keep" {
		t.Fatalf("acquire deleted the unrelated label: %+v", got.Labels)
	}
	if got.Annotations["unrelated-ann"] != "keep" {
		t.Fatalf("acquire deleted the unrelated annotation: %+v", got.Annotations)
	}

	if err := releaseOwned(context.Background(), fc, j); err != nil {
		t.Fatalf("release: %v", err)
	}
	if err := fc.Get(context.Background(), client.ObjectKey{Name: "platform-worker"}, &got); err != nil {
		t.Fatalf("get node: %v", err)
	}
	if len(got.Spec.Taints) != 1 || got.Spec.Taints[0] != unrelated {
		t.Fatalf("release must leave exactly the unrelated taint, got %+v", got.Spec.Taints)
	}
	if got.Labels["unrelated-label"] != "keep" || got.Annotations["unrelated-ann"] != "keep" {
		t.Fatalf("release deleted unrelated state: labels %+v annotations %+v", got.Labels, got.Annotations)
	}
	if _, ok := got.Labels[workerLabelKey]; ok {
		t.Fatalf("release must remove the ownership label, got %+v", got.Labels)
	}
	if _, ok := got.Annotations[journalKey]; ok {
		t.Fatalf("release must remove the journal, got %+v", got.Annotations)
	}
}

// The companion of the test above, for the case where our taint is the only one: the resulting empty list
// is what a real API server has to accept for a worker to end the run schedulable again.
func TestReleaseEmptiesTheTaintListWhenOnlyOursWasPresent(t *testing.T) {
	n := node(nil, nil)
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(n).Build()

	j, err := acquireWorker(context.Background(), fc, "platform-worker", "tx-only", "r1", "A-honor")
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	if err := releaseOwned(context.Background(), fc, j); err != nil {
		t.Fatalf("release: %v", err)
	}

	var got corev1.Node
	if err := fc.Get(context.Background(), client.ObjectKey{Name: "platform-worker"}, &got); err != nil {
		t.Fatalf("get node: %v", err)
	}
	if len(got.Spec.Taints) != 0 {
		t.Fatalf("release must leave no taints, got %+v", got.Spec.Taints)
	}
}

func hasTaint(taints []corev1.Taint, want corev1.Taint) bool {
	for _, t := range taints {
		if t == want {
			return true
		}
	}
	return false
}

// This is the critical finding of the whole-branch review, and the exact shape of the failure this branch
// exists to stop: a run whose markers are removed under it must not be able to report a clean release and
// publish a number.
//
// The removal is reachable three realistic ways — an operator running -release-stale against a transaction
// they believe is dead but is not, the -force-release then -clear-quarantine pair run while a run is live,
// or the Node being deleted and recreated — and all three land on the same observable state: a free node.
// Note the asymmetry that makes this the dangerous window rather than an obvious one: if a second run has
// already acquired by the time this run releases, decideRelease refuses with not-our-transaction and the
// run correctly invalidates. It is precisely the case where the node is left FREE that used to publish.
func TestReleaseOwnedInvalidatesWhenMarkersVanishMidRun(t *testing.T) {
	n := node(nil, nil)
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(n).Build()

	j, err := acquireWorker(context.Background(), fc, "platform-worker", "tx-vanish", "r1", "A-honor")
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	// An operator frees the node while this run is still holding it, using the tool's own stale release.
	if err := releaseStale(context.Background(), fc, "platform-worker", j.TxID); err != nil {
		t.Fatalf("stale release: %v", err)
	}

	err = releaseOwned(context.Background(), fc, j)
	var r *refusal
	if err == nil || !asRefusal(err, &r) || r.Reason != reasonOwnershipLost {
		t.Fatalf("the run's own release must invalidate once its markers are gone, got %v", err)
	}
	if !strings.Contains(err.Error(), j.TxID) {
		t.Fatalf("the invalidation must name the transaction that lost the worker: %v", err)
	}

	// The operator paths keep the opposite contract on the very same state, which is why this is fixed at
	// the call site and not in decideRelease: a node with nothing of ours on it is still a clean success for
	// a stale release racing a genuine one, and for acquire's own self-release.
	act, err := releaseAcquired(context.Background(), fc, j)
	if err != nil || act != releaseAlreadyDone {
		t.Fatalf("releaseAcquired on a clean node = %v, %v; want releaseAlreadyDone, nil", act, err)
	}
}

// resolveAmbiguousAcquire is the only path that can return "acquired" without going through verifyAcquired,
// and it answers one of the five adversarial findings this branch exists to close: a non-conflict Patch
// error may still have committed. These four tests cover its three-way switch and its cancellation branch.
//
// First: the write landed and only the response was lost, which must resolve to acquired rather than
// abandoning a node that now carries our markers.
func TestResolveAmbiguousAcquireAcceptsAPatchWhoseResponseWasLost(t *testing.T) {
	n := node(nil, nil)
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(n).WithInterceptorFuncs(interceptor.Funcs{
		Patch: func(ctx context.Context, c client.WithWatch, obj client.Object, patch client.Patch,
			opts ...client.PatchOption) error {
			if err := c.Patch(ctx, obj, patch, opts...); err != nil {
				return err
			}
			// The patch committed; the caller never learns that.
			return lostResponseErr()
		},
	}).Build()

	j, err := acquireWorker(context.Background(), fc, "platform-worker", "tx-lost", "r1", "A-honor")
	if err != nil {
		t.Fatalf("a committed patch with a lost response must resolve to acquired: %v", err)
	}
	if j.TxID != "tx-lost" {
		t.Fatalf("journal txid = %q, want tx-lost", j.TxID)
	}
}

// Second: the error was real and the write never committed. The node is free, so there is nothing of ours
// to undo and the refusal must say so rather than leaving the operator to wonder.
func TestResolveAmbiguousAcquireRefusesAPatchThatDidNotLand(t *testing.T) {
	n := node(nil, nil)
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(n).WithInterceptorFuncs(interceptor.Funcs{
		Patch: func(ctx context.Context, c client.WithWatch, obj client.Object, patch client.Patch,
			opts ...client.PatchOption) error {
			return lostResponseErr()
		},
	}).Build()

	_, err := acquireWorker(context.Background(), fc, "platform-worker", "tx-nolanding", "r1", "A-honor")
	if err == nil {
		t.Fatal("a patch that did not land must refuse acquisition")
	}
	if !strings.Contains(err.Error(), "did not land") || !strings.Contains(err.Error(), "tx-nolanding") {
		t.Fatalf("the refusal must say it did not land and name the transaction, got: %v", err)
	}

	var got corev1.Node
	if err := fc.Get(context.Background(), client.ObjectKey{Name: "platform-worker"}, &got); err != nil {
		t.Fatalf("get node: %v", err)
	}
	if len(got.Labels) != 0 || len(got.Annotations) != 0 || len(got.Spec.Taints) != 0 {
		t.Fatalf("nothing may have been written: %+v %+v %+v", got.Labels, got.Annotations, got.Spec.Taints)
	}
}

// Third: another transaction holds the node by the time we look, so our patch demonstrably lost the race
// and the refusal must name the holder instead of resolving to acquired.
func TestResolveAmbiguousAcquireRefusesWhenAnotherTransactionHoldsTheNode(t *testing.T) {
	foreign := testJournal()
	foreign.TxID = "tx-other"
	foreign.RunID = "r9"
	foreign.Installed = installedTuple{LabelValue: "r9", TaintValue: "r9", TaintEffect: corev1.TaintEffectNoSchedule}
	foreignRaw, err := encodeJournal(foreign)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}

	n := node(nil, nil)
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(n).WithInterceptorFuncs(interceptor.Funcs{
		Patch: func(ctx context.Context, c client.WithWatch, obj client.Object, patch client.Patch,
			opts ...client.PatchOption) error {
			// Our patch never reaches the API server, and by the time we look a second run has acquired.
			var other corev1.Node
			if err := c.Get(ctx, client.ObjectKey{Name: "platform-worker"}, &other); err != nil {
				return err
			}
			other.Labels = map[string]string{workerLabelKey: "r9"}
			other.Annotations = map[string]string{journalKey: foreignRaw}
			other.Spec.Taints = []corev1.Taint{
				{Key: workerTaintKey, Value: "r9", Effect: corev1.TaintEffectNoSchedule},
			}
			if err := c.Update(ctx, &other); err != nil {
				return err
			}
			return lostResponseErr()
		},
	}).Build()

	if _, err := acquireWorker(context.Background(), fc, "platform-worker", "tx-loser", "r1", "A-honor"); err == nil {
		t.Fatal("acquisition must refuse when another transaction holds the node")
	} else if !strings.Contains(err.Error(), "tx-other") {
		t.Fatalf("the refusal must name the holding transaction, got: %v", err)
	}
}

// Fourth, and the regression this whole path most needs: our journal is present under our own TxID but an
// installed value was altered — a mutating webhook is the realistic actor — and that must NOT resolve to
// acquired. Treating "journal present with our TxID" as acquired is the exact shortcut the design forbids,
// because the run would then hold a node that no longer routes work the way the flavor expects.
//
// The context is cancelled once the resolve loop has seen the state, which both bounds the test and covers
// the cancellation branch: it must report UNRESOLVED and hand the node to the operator modes by name.
func TestResolveAmbiguousAcquireRefusesAPartiallyLandedPatch(t *testing.T) {
	n := node(nil, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var gets int
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(n).WithInterceptorFuncs(interceptor.Funcs{
		Get: func(ctx context.Context, c client.WithWatch, key client.ObjectKey, obj client.Object,
			opts ...client.GetOption) error {
			err := c.Get(ctx, key, obj, opts...)
			gets++
			if gets >= 2 {
				// The resolve loop has now observed the partial state once; cancelling here stands in for the
				// operator's Ctrl-C and keeps the test off the full resolve bound.
				cancel()
			}
			return err
		},
		Patch: func(ctx context.Context, c client.WithWatch, obj client.Object, patch client.Patch,
			opts ...client.PatchOption) error {
			// A mutating webhook keeps our journal and rewrites the label the flavor selects on.
			if nd, ok := obj.(*corev1.Node); ok {
				nd.Labels[workerLabelKey] = "someone-else"
			}
			if err := c.Patch(ctx, obj, patch, opts...); err != nil {
				return err
			}
			return lostResponseErr()
		},
	}).Build()

	j, err := acquireWorker(ctx, fc, "platform-worker", "tx-partial", "r1", "A-honor")
	if err == nil {
		t.Fatal("a partially landed patch must never resolve to acquired")
	}
	if j.TxID != "" {
		t.Fatalf("a refused acquisition must return no journal, got %+v", j)
	}
	if !strings.Contains(err.Error(), "UNRESOLVED") || !strings.Contains(err.Error(), "tx-partial") {
		t.Fatalf("the refusal must be UNRESOLVED and name the transaction, got: %v", err)
	}
	if !strings.Contains(err.Error(), "-inspect-worker -worker platform-worker") {
		t.Fatalf("the refusal must hand the operator a runnable command, got: %v", err)
	}

	var got corev1.Node
	if err := fc.Get(context.Background(), client.ObjectKey{Name: "platform-worker"}, &got); err != nil {
		t.Fatalf("get node: %v", err)
	}
	if got.Annotations[journalKey] == "" || got.Labels[workerLabelKey] != "someone-else" {
		t.Fatalf("the test did not produce the partial state it exists for: %+v %+v", got.Labels, got.Annotations)
	}
}
