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
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
	kueuev1beta2 "sigs.k8s.io/kueue/apis/kueue/v1beta2"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/queuelab"
)

// A signal landing while a barrier is unmet must be reported as itself, not swallowed by the 2-second poll:
// this proves waitBarrier returns on the first cancelled select rather than continuing to poll toward the
// horizon, which is exactly what would make a Ctrl-C during a long barrier wait look hung.
func TestWaitBarrierReturnsPromptlyOnCancelledContext(t *testing.T) {
	scheme := testScheme(t)
	if err := platformv1.AddToScheme(scheme); err != nil {
		t.Fatalf("add platformv1 to scheme: %v", err)
	}
	fc := fake.NewClientBuilder().WithScheme(scheme).Build()
	// The horizon is far enough out that only the cancelled select, not the deadline, could end this quickly.
	// The job named here does not exist, so barrierHolds's first check reports "not met" (not an error) and
	// the wait would otherwise poll every 2 s until the deadline.
	col := newCollector(fc, "ns", "r1", time.Hour)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	b := queuelab.Barrier{Kind: queuelab.BarrierPending, Job: "does-not-exist"}

	start := time.Now()
	err := waitBarrier(ctx, fc, "ns", b, col)
	elapsed := time.Since(start)

	if !errors.Is(err, context.Canceled) {
		t.Fatalf("want an error wrapping context.Canceled, got %v", err)
	}
	if elapsed > 500*time.Millisecond {
		t.Fatalf("waitBarrier took %v to return on an already-cancelled context; it must not poll to the deadline", elapsed)
	}
}

// Gate 0 item 19: an error the barrier loop can never poll its way out of used to burn the whole observation
// window and then be reported as "barrier not met before horizon" — an infrastructure failure dressed up as a
// protocol outcome, and a run's worth of GPU time spent finding out.
//
// A missing RBAC binding is the realistic case: it holds for the entire run, and the operator needs to see it
// now rather than 150 seconds later under a different name.
func TestWaitBarrierReturnsAtOnceOnATerminalError(t *testing.T) {
	scheme := testScheme(t)
	if err := platformv1.AddToScheme(scheme); err != nil {
		t.Fatalf("add platformv1 to scheme: %v", err)
	}
	forbidden := apierrors.NewForbidden(schema.GroupResource{Resource: "mltrainingjobs"}, "victim",
		fmt.Errorf("mltrainingjob reader is not bound"))
	fc := fake.NewClientBuilder().WithScheme(scheme).WithInterceptorFuncs(interceptor.Funcs{
		Get: func(ctx context.Context, c client.WithWatch, key client.ObjectKey, obj client.Object,
			opts ...client.GetOption) error {
			return forbidden
		},
	}).Build()
	// An hour out, so only an immediate return can be quick: reaching the deadline is the bug.
	col := newCollector(fc, "ns", "r1", time.Hour)

	start := time.Now()
	err := waitBarrier(context.Background(), fc, "ns",
		queuelab.Barrier{Kind: queuelab.BarrierPending, Job: "victim"}, col)
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("an authorization failure must fail the run, not be polled")
	}
	if elapsed > 500*time.Millisecond {
		t.Fatalf("waitBarrier took %v; a terminal error must not be retried toward the horizon", elapsed)
	}
	// Preserved with %w, so the caller can tell an infrastructure failure from a protocol one rather than
	// having to read the sentence.
	if !apierrors.IsForbidden(err) {
		t.Fatalf("the underlying error must survive unwrapping, got %v", err)
	}
	if strings.Contains(err.Error(), "not met before horizon") {
		t.Fatalf("a terminal error must not be reported as a barrier miss: %v", err)
	}
}

// A barrier kind nothing can evaluate is a programming error, and polling it for the whole window is the
// worst possible way to report one.
func TestWaitBarrierReturnsAtOnceOnAnUnknownBarrierKind(t *testing.T) {
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).Build()
	col := newCollector(fc, "ns", "r1", time.Hour)

	start := time.Now()
	err := waitBarrier(context.Background(), fc, "ns", queuelab.Barrier{Kind: "NoSuchBarrier"}, col)

	if err == nil || !errors.Is(err, errUnknownBarrier) {
		t.Fatalf("an unevaluable barrier kind must fail at once as itself, got %v", err)
	}
	if elapsed := time.Since(start); elapsed > 500*time.Millisecond {
		t.Fatalf("waitBarrier took %v on an unknown barrier kind", elapsed)
	}
}

// The other direction, which the classification must not break: an object the barrier is WAITING to appear is
// absent, which is the ordinary state of every barrier before it holds. That must keep polling and end as a
// barrier miss at the horizon, not as a terminal failure.
func TestWaitBarrierKeepsPollingWhileTheObjectIsMerelyAbsent(t *testing.T) {
	scheme := testScheme(t)
	if err := platformv1.AddToScheme(scheme); err != nil {
		t.Fatalf("add platformv1 to scheme: %v", err)
	}
	var gets int
	fc := fake.NewClientBuilder().WithScheme(scheme).WithInterceptorFuncs(interceptor.Funcs{
		Get: func(ctx context.Context, c client.WithWatch, key client.ObjectKey, obj client.Object,
			opts ...client.GetOption) error {
			gets++
			return c.Get(ctx, key, obj, opts...)
		},
	}).Build()
	// A horizon short enough that the poll loop reaches it, but long enough to require more than one check.
	col := newCollector(fc, "ns", "r1", 2500*time.Millisecond)

	err := waitBarrier(context.Background(), fc, "ns",
		queuelab.Barrier{Kind: queuelab.BarrierPending, Job: "never-created"}, col)

	if err == nil {
		t.Fatal("a barrier that never holds must fail at the horizon")
	}
	if !strings.Contains(err.Error(), "not met before horizon") {
		t.Fatalf("an absent object is a barrier miss, not a terminal failure: %v", err)
	}
	if gets < 2 {
		t.Fatalf("want the barrier polled more than once (gets=%d); a NotFound must not end the wait", gets)
	}
}

// The main goroutine used to call col.builder.Desync directly while the four watch goroutines were still
// running and still calling Observe through flush under col.mu, and LedgerBuilder has no locking of its own:
// invalid, events, lastEvent and ready are plain fields. That is a data race on the single field that
// decides whether the run may produce a number at all.
//
// The whole test suite was green under -race before this fix and proved nothing, because no test ran the
// live collector with concurrent watch goroutines. This one does: one goroutine plays the watch side
// (submitObserved takes col.mu and calls Observe, exactly as flush does) while the test goroutine plays the
// main side. Run under -race it fails on the unlocked Desync and passes on the locked one.
func TestCollectorDesyncIsSerialisedWithTheWatchGoroutines(t *testing.T) {
	scheme := testScheme(t)
	if err := platformv1.AddToScheme(scheme); err != nil {
		t.Fatalf("add platformv1 to scheme: %v", err)
	}
	fc := fake.NewClientBuilder().WithScheme(scheme).Build()
	col := newCollector(fc, "ns", "r1", time.Hour)

	const rounds = 500
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < rounds; i++ {
			col.submitObserved(queuelab.TrainingTraceRow{Name: "victim"}, fmt.Sprintf("uid-%d", i),
				&platformv1.MLTrainingJob{})
		}
	}()
	for i := 0; i < rounds; i++ {
		col.desync("barrier before step 0 (victim): deadline")
	}
	<-done

	// Reading the builder is safe only now, which is the same discipline run() follows after col.wait().
	if col.builder.Err() == nil {
		t.Fatal("the desync must have invalidated the run; the test did not exercise what it exists for")
	}
}

// A bare namespace has no identity at all, so a later Get cannot tell ours from one someone else created
// under the same derived name — and the name is derived from the run id alone.
func TestEnsureNamespaceStampsWhatItCreates(t *testing.T) {
	c := fake.NewClientBuilder().WithScheme(fullScheme(t)).Build()
	if err := ensureNamespace(context.Background(), c, "queuelab-r1", "tx-1"); err != nil {
		t.Fatalf("ensure namespace: %v", err)
	}
	var ns corev1.Namespace
	if err := c.Get(context.Background(), client.ObjectKey{Name: "queuelab-r1"}, &ns); err != nil {
		t.Fatalf("get namespace: %v", err)
	}
	if got := ns.Labels[queuelab.TxLabel]; got != "tx-1" {
		t.Fatalf("namespace carries tx stamp %q, want tx-1", got)
	}
}

// Swallowing AlreadyExists is how a previous run's leftovers came to satisfy a new run's barriers. An
// existing object is ours only if it carries our stamp; anything else is a refusal, not a shrug.
func TestEnsureNamespaceAdoptsOnlyItsOwnStamp(t *testing.T) {
	for _, tc := range []struct {
		name       string
		labels     map[string]string
		wantAdopt  bool
		wantErrSub string // required when !wantAdopt, so a wrong-reason refusal cannot pass as this one
	}{
		{"our own stamp", map[string]string{queuelab.TxLabel: "tx-1"}, true, ""},
		{"another transaction", map[string]string{queuelab.TxLabel: "tx-2"}, false, "transaction"},
		{"no stamp at all", nil, false, "transaction"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithObjects(
				&corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: "queuelab-r1", Labels: tc.labels}},
			).Build()
			err := ensureNamespace(context.Background(), c, "queuelab-r1", "tx-1")
			if tc.wantAdopt && err != nil {
				t.Fatalf("our own namespace was refused: %v", err)
			}
			if !tc.wantAdopt {
				if err == nil {
					t.Fatal("a namespace this run did not create was adopted; a previous run's leftovers can then satisfy this run's barriers")
				}
				if !strings.Contains(err.Error(), tc.wantErrSub) {
					t.Fatalf("refusal %q does not name the reason %q; a wrong-reason refusal must not pass", err, tc.wantErrSub)
				}
			}
		})
	}
}

// The equivalent confound for fixtures: an object left behind by a different transaction under the same run
// id (only the namespace is ever cleaned up by hand between attempts) must not be adopted, or applyFixtures
// proceeds as if this run created a quota mapping, queue, or binding it never wrote.
//
// Every fixture kind is covered, not just the ResourceFlavor: applyFixtures applies createOwned's ownership
// check to every object in its loop, and a mutation that special-cased only the first object (the Flavor)
// would leave the ClusterQueue and LocalQueue cases silently adoptive while this test still passed if they
// were untested. The "no stamp at all" case is the one a lenient reading of the ownership check (treat an
// absent label as "not yet stamped, adopt it") would pass: every fixture created before this task carries no
// TxLabel at all, so that is not a hypothetical, it is what a rerun against real leftover objects hits.
//
// checkFlavorVariant's own pre-check is exercised too ("our tx, wrong variant"), so a mutation that deleted
// that block would not sail through on the strength of the ownership check alone covering applyFixtures.
func TestApplyFixturesAdoptsOnlyItsOwnStamp(t *testing.T) {
	newFixtures := func(t *testing.T) *queuelab.FixtureSet {
		t.Helper()
		fs, err := queuelab.BuildFixtures(queuelab.StudyReclaim, "Any", "tx-1", "r1", "queuelab-r1")
		if err != nil {
			t.Fatalf("build fixtures: %v", err)
		}
		return fs
	}

	for _, tc := range []struct {
		name       string
		preexist   func(fs *queuelab.FixtureSet) client.Object
		wantAdopt  bool
		wantErrSub string // required when !wantAdopt, so a wrong-reason refusal cannot pass as this one
	}{
		{
			name: "our own stamp",
			preexist: func(fs *queuelab.FixtureSet) client.Object {
				return &kueuev1beta2.ResourceFlavor{ObjectMeta: metav1.ObjectMeta{
					Name: fs.Flavor.GetName(), Labels: map[string]string{queuelab.TxLabel: "tx-1", variantLabelKey: "Any"},
				}}
			},
			wantAdopt: true,
		},
		{
			name: "another transaction",
			preexist: func(fs *queuelab.FixtureSet) client.Object {
				return &kueuev1beta2.ResourceFlavor{ObjectMeta: metav1.ObjectMeta{
					Name: fs.Flavor.GetName(), Labels: map[string]string{queuelab.TxLabel: "tx-2", variantLabelKey: "Any"},
				}}
			},
			wantAdopt:  false,
			wantErrSub: "transaction",
		},
		{
			// Every fixture BuildFixtures produced before this task carries no TxLabel, so this is what a
			// rerun against real leftovers hits, not a hypothetical.
			name: "no stamp at all",
			preexist: func(fs *queuelab.FixtureSet) client.Object {
				return &kueuev1beta2.ResourceFlavor{ObjectMeta: metav1.ObjectMeta{
					Name: fs.Flavor.GetName(), Labels: map[string]string{variantLabelKey: "Any"},
				}}
			},
			wantAdopt:  false,
			wantErrSub: "transaction",
		},
		{
			// Our own transaction is not enough on its own: checkFlavorVariant's pre-check must still catch
			// a same-transaction flavor built for a different arm's variant.
			name: "our tx, wrong variant",
			preexist: func(fs *queuelab.FixtureSet) client.Object {
				return &kueuev1beta2.ResourceFlavor{ObjectMeta: metav1.ObjectMeta{
					Name: fs.Flavor.GetName(), Labels: map[string]string{queuelab.TxLabel: "tx-1", variantLabelKey: "Never"},
				}}
			},
			wantAdopt:  false,
			wantErrSub: "variant",
		},
		{
			// The Flavor is absent here, so its Create succeeds outright; only the ClusterQueue pre-exists,
			// which is what isolates createOwned's check on THIS kind rather than the Flavor's.
			name: "foreign cluster queue",
			preexist: func(fs *queuelab.FixtureSet) client.Object {
				cq := fs.ClusterQueue[0]
				return &kueuev1beta2.ClusterQueue{ObjectMeta: metav1.ObjectMeta{
					Name: cq.GetName(), Labels: map[string]string{queuelab.TxLabel: "tx-2"},
				}}
			},
			wantAdopt:  false,
			wantErrSub: "transaction",
		},
		{
			// Flavor and ClusterQueues are both absent, so only the LocalQueue's own ownership check can be
			// what refuses this case.
			name: "foreign local queue",
			preexist: func(fs *queuelab.FixtureSet) client.Object {
				lq := fs.LocalQueue[0]
				return &kueuev1beta2.LocalQueue{ObjectMeta: metav1.ObjectMeta{
					Name: lq.GetName(), Namespace: lq.GetNamespace(), Labels: map[string]string{queuelab.TxLabel: "tx-2"},
				}}
			},
			wantAdopt:  false,
			wantErrSub: "transaction",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			fs := newFixtures(t)
			c := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithObjects(tc.preexist(fs)).Build()
			err := applyFixtures(context.Background(), c, fs, "Any", "tx-1")
			if tc.wantAdopt && err != nil {
				t.Fatalf("our own fixture was refused: %v", err)
			}
			if !tc.wantAdopt {
				if err == nil {
					t.Fatal("a fixture this run did not create was adopted; a previous transaction's leftovers can then satisfy this run's barriers")
				}
				if !strings.Contains(err.Error(), tc.wantErrSub) {
					t.Fatalf("refusal %q does not name the reason %q; a wrong-reason refusal must not pass", err, tc.wantErrSub)
				}
			}
		})
	}
}
