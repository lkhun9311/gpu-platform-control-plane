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
	"sync"
	"time"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/watch"
	"sigs.k8s.io/controller-runtime/pkg/client"
	kueuev1beta2 "sigs.k8s.io/kueue/apis/kueue/v1beta2"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/queuelab"
)

const (
	kindMLTrainingJob = "MLTrainingJob"
	kindJob           = "Job"
	kindWorkload      = "Workload"
	kindPod           = "Pod"
	phaseRunning      = "Running"
)

// pendingEvent is a classified transition whose object could not yet be attributed to a trace job (its
// parent had not been observed); it is retried as more objects arrive, preserving the transition time.
type pendingEvent struct {
	kind    string
	uid     string
	delta   queuelab.DeltaType
	state   queuelab.ObservedState
	elapsed int64
}

// collector watches the four GVRs and drives the fail-closed LedgerBuilder, resolving each object to its
// trace job by the UID chain and classifying it. It is the live half of the runner; the pure builder,
// classifier, join, and adapter are the reviewed units it composes.
type collector struct {
	c     client.WithWatch
	ns    string
	runID string
	t0    time.Time
	// deadline is the end of the observation window as an absolute instant, stamped from t0 before any
	// barrier is waited on.
	//
	// It is one field rather than a value each caller derives because the barrier loop and the censoring
	// boundary must be the SAME instant: two separately computed deadlines can drift apart, and a
	// reconstruction censored against a different horizon than the one the schedule ran to is not a
	// reconstruction of the run that happened.
	deadline time.Time
	builder  *queuelab.LedgerBuilder

	mu        sync.Mutex
	cache     map[string]queuelab.ObservedObject
	pending   []pendingEvent
	readyAt   map[string]time.Time
	readyPods map[string]bool
	wg        sync.WaitGroup
}

func newCollector(c client.WithWatch, ns, runID string, horizon time.Duration) *collector {
	t0 := time.Now()
	return &collector{
		c:         c,
		ns:        ns,
		runID:     runID,
		t0:        t0,
		deadline:  t0.Add(horizon),
		builder:   queuelab.NewLedgerBuilder(),
		cache:     map[string]queuelab.ObservedObject{},
		readyAt:   map[string]time.Time{},
		readyPods: map[string]bool{},
	}
}

func (col *collector) elapsed() time.Duration { return time.Since(col.t0) }

// horizonNs is the censoring boundary the reconstruction is given, as an offset on the collector's own clock.
//
// It is derived from the deadline stamped at construction rather than read off the clock when it is asked
// for, because the run used to pass col.elapsed() AFTER the watches had been cancelled and joined: the
// horizon was then the observation window plus however long shutdown took, a different number on every run
// and a longer one whenever the API server was slow to close the watches.
//
// The subtraction is against t0 specifically because every ledger event's ElapsedNs is measured from t0; a
// boundary taken from any other origin would be offset from the very events it censors.
func (col *collector) horizonNs() int64 { return col.deadline.Sub(col.t0).Nanoseconds() }

// start launches one watch goroutine per GVR.
func (col *collector) start(ctx context.Context) {
	col.watch(ctx, kindMLTrainingJob, func() client.ObjectList { return &platformv1.MLTrainingJobList{} })
	col.watch(ctx, kindJob, func() client.ObjectList { return &batchv1.JobList{} })
	col.watch(ctx, kindWorkload, func() client.ObjectList { return &kueuev1beta2.WorkloadList{} })
	col.watch(ctx, kindPod, func() client.ObjectList { return &corev1.PodList{} })
}

func (col *collector) wait() { col.wg.Wait() }

// desync invalidates the run from the main goroutine, which is the only caller that does not already hold mu.
//
// LedgerBuilder has no locking of its own — invalid, events, lastEvent and ready are plain fields — and the
// four watch goroutines call Observe through flush under this mutex for the whole run. Calling Desync
// directly from the main goroutine is therefore a data race on the single field that decides whether the run
// is allowed to produce a number at all, which is the one thing this package may not get wrong. The lock
// belongs here rather than inside internal/queuelab because mu already serialises every other access to the
// builder, and a second, independent mutex would only make that ownership ambiguous.
func (col *collector) desync(reason string) {
	col.mu.Lock()
	defer col.mu.Unlock()
	col.builder.Desync(reason)
}

func (col *collector) watch(ctx context.Context, kind string, newList func() client.ObjectList) {
	col.wg.Go(func() {
		for ctx.Err() == nil {
			w, err := col.c.Watch(ctx, newList(), client.InNamespace(col.ns))
			if err != nil {
				if ctx.Err() != nil {
					return
				}
				select {
				case <-ctx.Done():
					return
				case <-time.After(time.Second):
				}
				continue
			}
			for ev := range w.ResultChan() {
				if ev.Type == watch.Error {
					// The apiserver ended this watch (a periodic timeout or a stale resourceVersion). Break
					// to re-establish it with a fresh list+watch rather than invalidating the run; the
					// re-list below re-observes current state so a Ready Pod that vanished during the gap is
					// still caught by the vanished check.
					break
				}
				obj, ok := ev.Object.(client.Object)
				if !ok {
					continue
				}
				col.handle(kind, ev.Type, obj)
			}
			w.Stop()
			col.relistCheck(ctx, kind, newList())
		}
	})
}

// handle folds one watch event: it updates the object cache, classifies the object, and (re)attempts to
// attribute pending transitions to their trace jobs now that the cache has grown.
func (col *collector) handle(kind string, et watch.EventType, obj client.Object) {
	col.mu.Lock()
	defer col.mu.Unlock()

	uid := string(obj.GetUID())
	col.cache[uid] = queuelab.ObservedFrom(kind, obj)

	state := classify(kind, obj)
	delta := queuelab.DeltaUpsert
	if et == watch.Deleted {
		delta = queuelab.DeltaDelete
	}
	if state.Event != "" || state.Invalid || delta == queuelab.DeltaDelete {
		col.pending = append(col.pending, pendingEvent{kind, uid, delta, state, col.elapsed().Nanoseconds()})
	}
	col.flush()
}

// flush attributes as many pending transitions as the current cache allows, keeping the rest for later.
func (col *collector) flush() {
	objs := make([]queuelab.ObservedObject, 0, len(col.cache))
	for _, o := range col.cache {
		objs = append(objs, o)
	}
	names, err := queuelab.ResolveTraceJobs(objs)
	if err != nil {
		// The chain is incomplete (a child observed before its parent) or corrupt; keep pending and retry.
		return
	}
	kept := col.pending[:0]
	for _, pe := range col.pending {
		if name, ok := names[pe.uid]; ok {
			col.builder.Observe(pe.delta, pe.kind, pe.uid, name, pe.state, pe.elapsed)
			if pe.kind == kindPod {
				switch pe.state.Event {
				case queuelab.EventPodReady:
					col.readyPods[pe.uid] = true
				case queuelab.EventAttemptStopped:
					delete(col.readyPods, pe.uid)
				}
			}
		} else {
			kept = append(kept, pe)
		}
	}
	col.pending = kept
}

// relistCheck re-lists a GVR after its watch was re-established and, for Pods, invalidates the run if a
// previously-Ready Pod is no longer present without a recorded terminal state, so a stop missed during the
// watch gap is caught rather than silently charged to the horizon.
func (col *collector) relistCheck(ctx context.Context, kind string, list client.ObjectList) {
	if kind != kindPod || ctx.Err() != nil {
		return
	}
	if err := col.c.List(ctx, list, client.InNamespace(col.ns)); err != nil {
		return
	}
	present := map[string]bool{}
	for _, o := range list.(*corev1.PodList).Items {
		present[string(o.UID)] = true
	}
	col.mu.Lock()
	defer col.mu.Unlock()
	for uid := range col.readyPods {
		if !present[uid] {
			col.builder.MarkVanished(uid)
			delete(col.readyPods, uid)
		}
	}
}

// submit creates the MLTrainingJob and records the Submitted event from the create response (not a watch),
// so the offered-work clock cannot be observed after admission.
func (col *collector) submitObserved(row queuelab.TrainingTraceRow, uid string, mltj *platformv1.MLTrainingJob) {
	col.mu.Lock()
	defer col.mu.Unlock()
	col.cache[uid] = queuelab.ObservedFrom(kindMLTrainingJob, mltj)
	col.builder.Observe(queuelab.DeltaUpsert, kindMLTrainingJob, uid, row.Name,
		queuelab.ObservedState{Event: queuelab.EventSubmitted}, col.elapsed().Nanoseconds())
}

func classify(kind string, obj client.Object) queuelab.ObservedState {
	switch kind {
	case kindJob:
		return queuelab.ClassifyJob(obj.(*batchv1.Job))
	case kindWorkload:
		return queuelab.ClassifyWorkload(obj.(*kueuev1beta2.Workload))
	case kindPod:
		return queuelab.ClassifyPod(obj.(*corev1.Pod))
	default:
		return queuelab.ObservedState{}
	}
}

// ---- schedule execution (barrier polling against the live cluster) ----

// waitBarriers blocks until every barrier in after holds, polling the cluster, or errors on the deadline.
//
// The deadline is the collector's own stamped one rather than a parameter, so the window the schedule runs
// to and the horizon the reconstruction censors against cannot be two different instants.
func waitBarriers(ctx context.Context, c client.Client, ns string, after []queuelab.Barrier,
	col *collector) error {
	for _, b := range after {
		if err := waitBarrier(ctx, c, ns, b, col); err != nil {
			return err
		}
	}
	return nil
}

// errUnknownBarrier marks a barrier kind this executable has no check for.
//
// It is a sentinel rather than a bare message so waitBarrier can recognise it as terminal: polling a kind
// nothing can ever evaluate would burn the whole observation window on a programming error and then report
// it as a protocol outcome.
var errUnknownBarrier = errors.New("unknown barrier kind")

// barrierTerminal reports whether an error from barrierHolds is one that no amount of further polling can
// clear.
//
// The distinction is the point: a barrier waits for an object to APPEAR, so the ordinary failure while it
// waits is a NotFound (already folded into "not met" by phaseIs) and every transient API error is worth
// retrying. But an authorization failure, a kind the cluster or the scheme does not know, and a barrier this
// tool cannot evaluate are all states that will still hold at the deadline, and polling them until the
// horizon expires spends the entire run to report an infrastructure failure as "barrier not met".
//
// NotFound is deliberately NOT terminal: it is indistinguishable from an object that has not been created
// yet, which is exactly what a barrier exists to wait for.
func barrierTerminal(err error) bool {
	switch {
	case errors.Is(err, errUnknownBarrier):
		return true
	case apierrors.IsUnauthorized(err), apierrors.IsForbidden(err):
		return true
	case meta.IsNoMatchError(err), runtime.IsNotRegisteredError(err):
		// The CRD is absent from the cluster, or its kind from this client's scheme; either way no request
		// this loop can issue will ever succeed.
		return true
	default:
		return false
	}
}

func waitBarrier(ctx context.Context, c client.Client, ns string, b queuelab.Barrier, col *collector) error {
	// The most recent check error is kept so the horizon refusal can carry it: a barrier that was failing for
	// a retryable reason right up to the deadline used to report only "not met", which tells the operator
	// nothing about why it was never met.
	var lastErr error
	for {
		ok, err := barrierHolds(ctx, c, ns, b, col)
		if err == nil && ok {
			return nil
		}
		if err != nil {
			lastErr = err
			// Cancellation is reported as itself rather than as a barrier outcome, whether it arrives through
			// the select below or through the API call this check just made; Task 3 established that and it
			// must survive this classification.
			if ctxErr := ctx.Err(); ctxErr != nil {
				return fmt.Errorf("barrier %s(job=%s) observation cancelled (last check: %v): %w",
					b.Kind, b.Job, err, ctxErr)
			}
			if barrierTerminal(err) {
				return fmt.Errorf("barrier %s(job=%s,count=%d,delay=%d) cannot be met: %w",
					b.Kind, b.Job, b.Count, b.DelaySec, err)
			}
		}
		if time.Now().After(col.deadline) {
			if lastErr != nil {
				return fmt.Errorf("barrier %s(job=%s,count=%d,delay=%d) not met before horizon; the last check failed: %w",
					b.Kind, b.Job, b.Count, b.DelaySec, lastErr)
			}
			return fmt.Errorf("barrier %s(job=%s,count=%d,delay=%d) not met before horizon", b.Kind, b.Job, b.Count, b.DelaySec)
		}
		// Cancellation is reported as itself rather than as "barrier not met", which would misread an
		// operator's Ctrl-C as a protocol failure in the ledger's desync note.
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}
}

func barrierHolds(ctx context.Context, c client.Client, ns string, b queuelab.Barrier, col *collector) (bool, error) {
	switch b.Kind {
	case queuelab.BarrierAdmittedReady:
		running, err := phaseIs(ctx, c, ns, b.Job, phaseRunning)
		if err == nil && running {
			col.mu.Lock()
			if _, seen := col.readyAt[b.Job]; !seen {
				col.readyAt[b.Job] = time.Now()
			}
			col.mu.Unlock()
		}
		return running, err
	case queuelab.BarrierPending:
		return phaseIs(ctx, c, ns, b.Job, "Pending")
	case queuelab.BarrierFlavorUsage:
		n, err := runningCount(ctx, c, ns)
		return n >= b.Count, err
	case queuelab.BarrierDelayFromReady:
		col.mu.Lock()
		ready, ok := col.readyAt[b.Job]
		col.mu.Unlock()
		if !ok {
			return false, nil
		}
		return time.Since(ready) >= time.Duration(b.DelaySec)*time.Second, nil
	default:
		return false, fmt.Errorf("%w %s", errUnknownBarrier, b.Kind)
	}
}

func phaseIs(ctx context.Context, c client.Client, ns, name, want string) (bool, error) {
	var mltj platformv1.MLTrainingJob
	if err := c.Get(ctx, client.ObjectKey{Namespace: ns, Name: name}, &mltj); err != nil {
		if apierrors.IsNotFound(err) {
			return false, nil
		}
		return false, err
	}
	return mltj.Status.Phase == want, nil
}

func runningCount(ctx context.Context, c client.Client, ns string) (int, error) {
	var list platformv1.MLTrainingJobList
	if err := c.List(ctx, &list, client.InNamespace(ns)); err != nil {
		return 0, err
	}
	n := 0
	for i := range list.Items {
		if list.Items[i].Status.Phase == phaseRunning {
			n += int(list.Items[i].Spec.GPUCount)
		}
	}
	return n, nil
}

// submit renders and creates the trace job under its own row's contract, then records its Submitted event.
func submit(ctx context.Context, c client.Client, col *collector, arm queuelab.Arm,
	row queuelab.TrainingTraceRow, ns string) error {
	// The contract is resolved per row rather than per arm because the treatment is the VICTIM's behaviour;
	// rendering the whole arm with one contract would change all three manifests when exactly one is meant
	// to differ.
	contract, err := arm.ContractFor(row.Name)
	if err != nil {
		return err
	}
	mltj := queuelab.RenderMLTrainingJobWithContract(row, ns, contract)
	if err := c.Create(ctx, mltj); err != nil {
		return err
	}
	col.submitObserved(row, string(mltj.UID), mltj)
	return nil
}

// ---- cluster setup ----

// ensureNamespace creates the run's namespace, stamped, and refuses one it did not create.
//
// The stamp is in the Create body rather than a follow-up patch because a second write is a window a crash
// can land in, and an object created without its stamp is one no later teardown can recognise or delete.
func ensureNamespace(ctx context.Context, c client.Client, ns, txID string) error {
	err := c.Create(ctx, &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{
		Name:   ns,
		Labels: map[string]string{queuelab.TxLabel: txID},
	}})
	if err == nil {
		return nil
	}
	if !apierrors.IsAlreadyExists(err) {
		return err
	}
	// AlreadyExists is an ownership question, not a shrug: the namespace name is derived from the run id
	// alone, so the same name is exactly what a reused run id or a crashed previous attempt leaves behind.
	var existing corev1.Namespace
	if gerr := c.Get(ctx, client.ObjectKey{Name: ns}, &existing); gerr != nil {
		return fmt.Errorf("namespace %s exists but could not be read to check ownership: %w", ns, gerr)
	}
	if got := existing.Labels[queuelab.TxLabel]; got != txID {
		return fmt.Errorf("namespace %s already exists under transaction %q, not this run's %q; "+
			"clear it before rerunning rather than running inside another attempt's namespace", ns, got, txID)
	}
	return nil
}

// applyFixtures creates the run's Kueue fixtures, first checking that a cluster-scoped ResourceFlavor left
// behind by an earlier run under this run id (only the namespace is ever cleaned up by hand) was built for
// the same policy variant this arm requires, so a reused run id cannot silently execute under a different
// arm's mechanism. That check is about the VARIANT a name was built for; createOwned below is a separate
// question about which TRANSACTION created the name, and both must hold before an existing object is
// treated as this run's own.
func applyFixtures(ctx context.Context, c client.Client, fs *queuelab.FixtureSet, wantVariant, txID string) error {
	var existing kueuev1beta2.ResourceFlavor
	err := c.Get(ctx, client.ObjectKey{Name: fs.Flavor.GetName()}, &existing)
	switch {
	case err == nil:
		if verr := checkFlavorVariant(existing.Labels, wantVariant); verr != nil {
			return fmt.Errorf("resource flavor %s: %w", fs.Flavor.GetName(), verr)
		}
	case !apierrors.IsNotFound(err):
		return fmt.Errorf("get resource flavor %s: %w", fs.Flavor.GetName(), err)
	}

	objs := make([]client.Object, 0, 1+len(fs.ClusterQueue)+len(fs.LocalQueue))
	objs = append(objs, fs.Flavor)
	for _, cq := range fs.ClusterQueue {
		objs = append(objs, cq)
	}
	for _, lq := range fs.LocalQueue {
		objs = append(objs, lq)
	}
	for _, o := range objs {
		if err := createOwned(ctx, c, o, txID); err != nil {
			return fmt.Errorf("create %T %s: %w", o, o.GetName(), err)
		}
	}
	return nil
}

// createOwned creates o and, on AlreadyExists, refuses unless the object already there carries this run's
// own transaction stamp — the same shape as ensureNamespace, generalised over every fixture kind so a
// leftover from a different attempt under the same run id cannot silently satisfy this one.
func createOwned(ctx context.Context, c client.Client, o client.Object, txID string) error {
	err := c.Create(ctx, o)
	if err == nil {
		return nil
	}
	if !apierrors.IsAlreadyExists(err) {
		return err
	}
	if gerr := c.Get(ctx, client.ObjectKey{Namespace: o.GetNamespace(), Name: o.GetName()}, o); gerr != nil {
		return fmt.Errorf("exists but could not be read to check ownership: %w", gerr)
	}
	if got := o.GetLabels()[queuelab.TxLabel]; got != txID {
		return fmt.Errorf("already exists under transaction %q, not this run's %q; "+
			"clear it before rerunning rather than running inside another attempt's object", got, txID)
	}
	return nil
}
