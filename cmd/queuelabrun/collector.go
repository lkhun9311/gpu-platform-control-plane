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
	"sync"
	"time"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
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
	c       client.WithWatch
	ns      string
	runID   string
	t0      time.Time
	builder *queuelab.LedgerBuilder

	mu        sync.Mutex
	cache     map[string]queuelab.ObservedObject
	pending   []pendingEvent
	readyAt   map[string]time.Time
	readyPods map[string]bool
	wg        sync.WaitGroup
}

func newCollector(c client.WithWatch, ns, runID string) *collector {
	return &collector{
		c:         c,
		ns:        ns,
		runID:     runID,
		t0:        time.Now(),
		builder:   queuelab.NewLedgerBuilder(),
		cache:     map[string]queuelab.ObservedObject{},
		readyAt:   map[string]time.Time{},
		readyPods: map[string]bool{},
	}
}

func (col *collector) elapsed() time.Duration { return time.Since(col.t0) }

// start launches one watch goroutine per GVR.
func (col *collector) start(ctx context.Context) {
	col.watch(ctx, kindMLTrainingJob, func() client.ObjectList { return &platformv1.MLTrainingJobList{} })
	col.watch(ctx, kindJob, func() client.ObjectList { return &batchv1.JobList{} })
	col.watch(ctx, kindWorkload, func() client.ObjectList { return &kueuev1beta2.WorkloadList{} })
	col.watch(ctx, kindPod, func() client.ObjectList { return &corev1.PodList{} })
}

func (col *collector) wait() { col.wg.Wait() }

func (col *collector) watch(ctx context.Context, kind string, newList func() client.ObjectList) {
	col.wg.Go(func() {
		for ctx.Err() == nil {
			w, err := col.c.Watch(ctx, newList(), client.InNamespace(col.ns))
			if err != nil {
				if ctx.Err() != nil {
					return
				}
				time.Sleep(time.Second)
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
func waitBarriers(ctx context.Context, c client.Client, ns string, after []queuelab.Barrier,
	col *collector, deadline time.Time) error {
	for _, b := range after {
		if err := waitBarrier(ctx, c, ns, b, col, deadline); err != nil {
			return err
		}
	}
	return nil
}

func waitBarrier(ctx context.Context, c client.Client, ns string, b queuelab.Barrier,
	col *collector, deadline time.Time) error {
	for {
		ok, err := barrierHolds(ctx, c, ns, b, col)
		if err == nil && ok {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("barrier %s(job=%s,count=%d,delay=%d) not met before horizon", b.Kind, b.Job, b.Count, b.DelaySec)
		}
		time.Sleep(2 * time.Second)
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
		return false, fmt.Errorf("unknown barrier %s", b.Kind)
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

func ensureNamespace(ctx context.Context, c client.Client, ns string) error {
	err := c.Create(ctx, &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: ns}})
	if err != nil && !apierrors.IsAlreadyExists(err) {
		return err
	}
	return nil
}

func applyFixtures(ctx context.Context, c client.Client, fs *queuelab.FixtureSet) error {
	objs := make([]client.Object, 0, 1+len(fs.ClusterQueue)+len(fs.LocalQueue))
	objs = append(objs, fs.Flavor)
	for _, cq := range fs.ClusterQueue {
		objs = append(objs, cq)
	}
	for _, lq := range fs.LocalQueue {
		objs = append(objs, lq)
	}
	for _, o := range objs {
		if err := c.Create(ctx, o); err != nil && !apierrors.IsAlreadyExists(err) {
			return fmt.Errorf("create %T %s: %w", o, o.GetName(), err)
		}
	}
	return nil
}

const (
	workerLabelKey = "queuelab.gpu-platform/worker"
	workerTaintKey = "queuelab.gpu-platform/dedicated"
)

func dedicateWorker(ctx context.Context, c client.Client, node, runID string) error {
	var n corev1.Node
	if err := c.Get(ctx, client.ObjectKey{Name: node}, &n); err != nil {
		return err
	}
	base := n.DeepCopy()
	if n.Labels == nil {
		n.Labels = map[string]string{}
	}
	n.Labels[workerLabelKey] = runID
	n.Spec.Taints = upsertTaint(n.Spec.Taints,
		corev1.Taint{Key: workerTaintKey, Value: runID, Effect: corev1.TaintEffectNoSchedule})
	return c.Patch(ctx, &n, client.MergeFrom(base))
}

func releaseWorker(ctx context.Context, c client.Client, node string) error {
	var n corev1.Node
	if err := c.Get(ctx, client.ObjectKey{Name: node}, &n); err != nil {
		return err
	}
	base := n.DeepCopy()
	delete(n.Labels, workerLabelKey)
	kept := n.Spec.Taints[:0]
	for _, t := range n.Spec.Taints {
		if t.Key != workerTaintKey {
			kept = append(kept, t)
		}
	}
	n.Spec.Taints = kept
	return c.Patch(ctx, &n, client.MergeFrom(base))
}

func upsertTaint(taints []corev1.Taint, t corev1.Taint) []corev1.Taint {
	for i := range taints {
		if taints[i].Key == t.Key {
			taints[i] = t
			return taints
		}
	}
	return append(taints, t)
}
