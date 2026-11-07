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

package controller

import (
	"context"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	kueuev1beta1 "sigs.k8s.io/kueue/apis/kueue/v1beta1"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// The states of one attempt; docs/superpowers/specs/2026-11-01-distributed-restart-design.md is the contract.
const (
	attemptPreparing = "Preparing"
	attemptActive    = "Active"
	attemptStopping  = "Stopping"
	attemptStopped   = "Stopped"

	triggerRankFailed = "RankFailed"
	triggerNodeFault  = "NodeFault"
	triggerEvicted    = "Evicted"
	triggerJobDeleted = "JobDeleted"
)

// annFencedNodes is how an operator, or the experiment's runner after reading the instance as terminated, says that
// nodes which stopped answering are really off: a comma-separated list on the MLTrainingJob of node names, each
// optionally bound to the machine it means as name@id, with id the attempt's machineID for that name, and each
// optionally scoped to one attempt as name#N or name@id#N.
//
// It is never inferred. A Node object deleted, or a Pod gone from the API, does not stop a process on a machine the
// control plane cannot reach, and that process may still be writing to the shared checkpoint volume.
// An unscoped entry is spent by the first attempt that stops on it (fencedBy), because the machine it named may come
// back and run a later attempt; and a bare name is refused once another machine of that name ran (fenceVouches).
const annFencedNodes = "platform.lkhun9311.github.io/fenced-nodes"

// finRankStopped is held on every rank Pod of a restartable attempt, from the Pod template, until the controller has
// recorded the node the Pod ran on and knows the rank stopped: the kubelet reported the Pod terminal, the Pod was
// never bound, or its node is fenced for the attempt.
//
// Without it a Pod could leave the API before the controller ever saw it (a controller down while a node is lost and
// the Pod garbage-collected), and the barrier would then have neither the node to fence nor the Pod to wait for.
// It also keeps a Pod force-deleted from a node that is still Ready in the API until its kubelet reports it stopped,
// so a Pod's absence is never taken as a stop nobody reported.
const finRankStopped = "platform.lkhun9311.github.io/rank-stopped"

// AnnRestartHandoff marks a Workload the GPU fault path deactivated and handed to the restart lifecycle, in the same
// update as the deactivation; NodeHealth never reactivates such a Workload, and only this mark, not any deactivation,
// is a restart trigger, so a Workload an operator deactivated stops the job as it always did.
const AnnRestartHandoff = "platform.lkhun9311.github.io/restart-handoff"

// The reasons the restart lifecycle writes on the Admitted condition while no attempt is running.
const (
	mltjReasonRestarting        = "Restarting"
	mltjReasonRestartsExhausted = "RestartsExhausted"
)

// stopPoll is how often a Stopping attempt looks again; the barrier reads uncached and nothing watched announces a
// Pod's disappearance from an unreachable node.
const stopPoll = 2 * time.Second

// nextStep is the requeue after a step that wrote what the next one reads; the write's own watch event usually
// arrives first, and this is the floor if it is lost.
const nextStep = 100 * time.Millisecond

// restartable reports whether a job takes the restart lifecycle; every other job keeps the path it always had.
func restartable(mltj *platformv1.MLTrainingJob) bool {
	return mltj.Spec.Distributed != nil && mltj.Spec.Distributed.MaxRestarts > 0
}

// reconcileRestartable drives one restartable distributed job through its attempts.
//
// Each state is written to status before the action it authorises, so a controller that restarts mid-sequence
// resumes the step it was on instead of repeating an earlier one.
func (r *MLTrainingJobReconciler) reconcileRestartable(ctx context.Context, mltj *platformv1.MLTrainingJob) (ctrl.Result, error) {
	// Terminal only when the work finished or the budget is spent; a Failed written by markFailed for a conflict is
	// meant to recover once the conflict clears, as it does on the ordinary path.
	if mltj.Status.Phase == mltjPhaseSucceeded {
		return ctrl.Result{}, nil
	}
	if c := meta.FindStatusCondition(mltj.Status.Conditions, mltjCondSynced); mltj.Status.Phase == mltjPhaseFailed &&
		c != nil && c.Reason == mltjReasonRestartsExhausted {
		return ctrl.Result{}, nil
	}
	if len(mltj.Status.Attempts) == 0 {
		// The first attempt is recorded before its Job exists; that record is what freezes the template fields.
		return ctrl.Result{RequeueAfter: nextStep}, r.writeAttempts(ctx, mltj, func(a []platformv1.TrainingAttempt) []platformv1.TrainingAttempt {
			return append(a, platformv1.TrainingAttempt{Number: 1, State: attemptPreparing})
		})
	}
	cur := mltj.Status.Attempts[len(mltj.Status.Attempts)-1]
	switch cur.State {
	case attemptPreparing:
		return r.prepareAttempt(ctx, mltj, cur)
	case attemptActive:
		return r.runAttempt(ctx, mltj, cur)
	case attemptStopping:
		return r.stopAttempt(ctx, mltj)
	default:
		return r.afterStopped(ctx, mltj, cur)
	}
}

// prepareAttempt makes the attempt's Service and then its suspended Job, and adopts a Job left by a create whose
// response was lost, but only one carrying this attempt's token.
func (r *MLTrainingJobReconciler) prepareAttempt(ctx context.Context, mltj *platformv1.MLTrainingJob, cur platformv1.TrainingAttempt) (ctrl.Result, error) {
	ready, rendezvous, err := r.ensureRendezvousServiceFor(ctx, mltj, cur.Number)
	if err != nil {
		return ctrl.Result{}, err
	}
	if !ready {
		if rendezvous != nil {
			if err := r.setMLTJPhase(ctx, mltj, mltjPhasePending,
				admittedCondition(metav1.ConditionFalse, "RendezvousServiceUnavailable"), nil, nil, rendezvous); err != nil {
				return ctrl.Result{}, err
			}
		}
		return ctrl.Result{RequeueAfter: time.Second}, nil
	}

	var job batchv1.Job
	err = r.apiReader().Get(ctx, client.ObjectKeyFromObject(mltj), &job)
	switch {
	case apierrors.IsNotFound(err):
		desired := buildJob(mltj, cur.Number)
		desired.Spec.Suspend = new(true)
		if err := controllerutil.SetControllerReference(mltj, desired, r.Scheme); err != nil {
			return ctrl.Result{}, fmt.Errorf("own attempt %d job: %w", cur.Number, err)
		}
		if err := r.Create(ctx, desired); err != nil && !apierrors.IsAlreadyExists(err) {
			return ctrl.Result{}, fmt.Errorf("create attempt %d job %s/%s: %w", cur.Number, mltj.Namespace, mltj.Name, err)
		}
		// Whatever the create returned, the next pass reads the Job back and adopts it by token.
		return ctrl.Result{RequeueAfter: nextStep}, nil
	case err != nil:
		return ctrl.Result{}, fmt.Errorf("get attempt %d job: %w", cur.Number, err)
	}
	if !attemptOwns(&job, mltj, cur.Number) {
		// A Job of this name that is not this attempt's: a retired attempt's still being deleted, or a foreign one.
		// Never adopted and never deleted from here; the barrier that let this attempt start should have made it gone.
		return ctrl.Result{RequeueAfter: stopPoll}, r.setMLTJPhase(ctx, mltj, mltjPhasePending,
			admittedCondition(metav1.ConditionFalse, mltjReasonRestarting), nil, nil, rendezvous)
	}
	now := metav1.Now()
	return ctrl.Result{}, r.writeAttempts(ctx, mltj, func(a []platformv1.TrainingAttempt) []platformv1.TrainingAttempt {
		last := &a[len(a)-1]
		last.State, last.JobUID, last.CreatedAt = attemptActive, string(job.UID), &now
		return a
	})
}

// runAttempt follows an Active attempt: it reports the phase as the ordinary path does, records the attempt's
// Workload and nodes, and moves the attempt to Stopping on a trigger.
func (r *MLTrainingJobReconciler) runAttempt(ctx context.Context, mltj *platformv1.MLTrainingJob, cur platformv1.TrainingAttempt) (ctrl.Result, error) {
	// Kept in place for the whole attempt, as the ordinary path keeps its Service: ranks that have not yet started
	// resolve rank 0 through it, and a Service lost before then would leave them unable to.
	ready, rendezvous, err := r.ensureRendezvousServiceFor(ctx, mltj, cur.Number)
	if err != nil {
		return ctrl.Result{}, err
	}
	var requeue time.Duration
	if !ready {
		requeue = rendezvousRetry
		if rendezvous == nil {
			requeue = time.Second
		}
	}

	var job batchv1.Job
	err = r.apiReader().Get(ctx, client.ObjectKeyFromObject(mltj), &job)
	switch {
	case apierrors.IsNotFound(err):
		return r.trigger(ctx, mltj, triggerJobDeleted)
	case err != nil:
		return ctrl.Result{}, fmt.Errorf("get attempt %d job: %w", cur.Number, err)
	}
	if string(job.UID) != cur.JobUID {
		return r.trigger(ctx, mltj, triggerJobDeleted)
	}

	wl, err := r.getWorkloadForJob(ctx, &job)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("get workload of attempt %d: %w", cur.Number, err)
	}
	// Recorded before any trigger is acted on, so the first pass that sees a failure has not already lost the nodes
	// the stop barrier must account for.
	if err := r.discover(ctx, mltj, wl); err != nil {
		return ctrl.Result{}, err
	}
	// The handoff is read before the Job's failure: the fault path's eviction can fail the Job before this pass, and a
	// Job failed for that reason is a node fault, which RankFailed would misreport (codex census before the full stage).
	if wl != nil && wl.Annotations[AnnRestartHandoff] != "" {
		return r.trigger(ctx, mltj, triggerNodeFault)
	}
	// Kueue suspends an evicted Job and later admits the same Job again, which would start new ranks of this attempt,
	// with its rendezvous and its count, without the stop barrier between them and the old ones.
	// An operator's deactivation is not a trigger: it stops the job, as it does on the ordinary path.
	if wl != nil && evictedForRestart(wl) {
		return r.trigger(ctx, mltj, triggerEvicted)
	}
	if jobFailed(&job) {
		// The Workload above came from the cache, which can lag the fault path's handoff that failed this Job; a
		// failure classified on a stale read is never reclassified, so the handoff is read again uncached.
		handedOff, err := r.handoffUncached(ctx, mltj, &job)
		if err != nil {
			return ctrl.Result{}, err
		}
		if handedOff {
			return r.trigger(ctx, mltj, triggerNodeFault)
		}
		return r.trigger(ctx, mltj, triggerRankFailed)
	}

	phase, cond := computeMLTJPhase(&job, wl, true)
	if phase == mltjPhaseRunning {
		if err := r.recordActive(ctx, mltj, nil, nil, nil, true); err != nil {
			return ctrl.Result{}, err
		}
	}
	var admittedAt *metav1.Time
	if wl != nil {
		admittedAt = kueueAdmittedStamp(wl.Status.Conditions)
	}
	var readyRanks *int32
	if job.Status.Ready != nil {
		readyRanks = new(*job.Status.Ready)
	}
	return ctrl.Result{RequeueAfter: requeue}, r.setMLTJPhase(ctx, mltj, phase, cond, admittedAt, readyRanks, rendezvous)
}

// discover records the Workload and the nodes of the current attempt's Pods that are not yet recorded.
//
// It runs on every pass of an Active or Stopping attempt, before the barrier, so a Pod the barrier waits on has had
// its node recorded first and a node that later stops answering cannot be left out of the fencing check.
func (r *MLTrainingJobReconciler) discover(ctx context.Context, mltj *platformv1.MLTrainingJob, wl *kueuev1beta1.Workload) error {
	cur := mltj.Status.Attempts[len(mltj.Status.Attempts)-1]
	pods, err := r.attemptPods(ctx, mltj, cur.Number)
	if err != nil {
		return err
	}
	var nodes []string
	// When each node's first rank was bound there, to tell the Node the rank ran on from one registered later.
	boundAt := map[string]time.Time{}
	for i := range pods {
		n := pods[i].Spec.NodeName
		if n == "" {
			continue
		}
		if !slices.Contains(nodes, n) {
			nodes = append(nodes, n)
		}
		if t, ok := podBoundAt(&pods[i]); ok && (boundAt[n].IsZero() || t.Before(boundAt[n])) {
			boundAt[n] = t
		}
	}
	// Each node's UID is read once, when its rank is first seen there, so the barrier can tell that Node from a later one
	// registered under the same name.
	uids := map[string]string{}
	for _, n := range nodes {
		if _, known := cur.NodeUIDs[n]; known {
			continue
		}
		if boundAt[n].IsZero() {
			// The binding is not published yet; deciding now would compare the Node with nothing, so a node an autoscaler
			// created for a Pending rank would read as a replacement for good. A later pass decides.
			continue
		}
		var node corev1.Node
		switch err := r.apiReader().Get(ctx, types.NamespacedName{Name: n}, &node); {
		case apierrors.IsNotFound(err):
			// Gone already: no Node under this name can vouch for it later.
			uids[n] = nodeUIDAbsent
		case err != nil:
			return fmt.Errorf("get node %s: %w", n, err)
		case node.CreationTimestamp.After(boundAt[n]):
			// Registered after the rank was bound: another machine took the name before this pass saw the rank, and its
			// UID would let the replacement's readiness vouch for the machine the rank really ran on.
			uids[n] = nodeUIDReplaced
		default:
			uids[n] = string(node.UID)
		}
	}
	if err := r.recordActive(ctx, mltj, wl, nodes, uids, false); err != nil {
		return err
	}
	// Only after the record is written: a Pod released first could leave the API with its node never recorded.
	return r.releaseRanks(ctx, mltj, pods)
}

// podBoundAt is when the scheduler bound the Pod, and false while no binding is published.
// The Pod's creation is not a stand-in: a Pod Pending until an autoscaler made a node was created before that node.
func podBoundAt(p *corev1.Pod) (time.Time, bool) {
	for _, c := range p.Status.Conditions {
		if c.Type == corev1.PodScheduled && c.Status == corev1.ConditionTrue && !c.LastTransitionTime.IsZero() {
			return c.LastTransitionTime.Time, true
		}
	}
	return time.Time{}, false
}

// releaseRanks removes finRankStopped from each Pod whose rank is known to have stopped and whose node, if it had
// one, is in the attempt's record.
func (r *MLTrainingJobReconciler) releaseRanks(ctx context.Context, mltj *platformv1.MLTrainingJob, pods []corev1.Pod) error {
	for i := range pods {
		p := &pods[i]
		if !controllerutil.ContainsFinalizer(p, finRankStopped) || !rankStopped(mltj, p, true) {
			continue
		}
		if err := r.releaseRank(ctx, p); err != nil {
			return err
		}
	}
	return nil
}

// releaseRank removes finRankStopped from one Pod.
// The patch is conditioned on the Pod's version, because a merge patch replaces the whole finalizer list and an
// unconditioned one could put back a finalizer the Job controller removed in between.
func (r *MLTrainingJobReconciler) releaseRank(ctx context.Context, p *corev1.Pod) error {
	base := p.DeepCopy()
	controllerutil.RemoveFinalizer(p, finRankStopped)
	if err := r.Patch(ctx, p, client.MergeFromWithOptions(base, client.MergeFromWithOptimisticLock{})); err != nil && !apierrors.IsNotFound(err) {
		return fmt.Errorf("release rank pod %s/%s: %w", p.Namespace, p.Name, err)
	}
	return nil
}

// rankStopped reports whether a rank Pod is known to have stopped: never bound and already being deleted, so no
// scheduler will bind it; reported terminal by its kubelet; or being deleted from a node fenced for its attempt.
// With recorded, a bound Pod counts only once its node is in its attempt's record, which the barrier needs.
func rankStopped(mltj *platformv1.MLTrainingJob, p *corev1.Pod, recorded bool) bool {
	deleting := !p.DeletionTimestamp.IsZero()
	n := p.Spec.NodeName
	if n == "" {
		return deleting
	}
	attempt, err := strconv.Atoi(p.Labels[mltjAttemptLabel])
	if err != nil {
		return false
	}
	var rec *platformv1.TrainingAttempt
	for i := range mltj.Status.Attempts {
		if mltj.Status.Attempts[i].Number == int32(attempt) {
			rec = &mltj.Status.Attempts[i]
		}
	}
	if recorded && (rec == nil || !slices.Contains(rec.Nodes, n)) {
		return false
	}
	if p.Status.Phase == corev1.PodSucceeded || p.Status.Phase == corev1.PodFailed {
		return true
	}
	if !deleting {
		return false
	}
	fenced := fenceEntries(strings.Split(mltj.Annotations[annFencedNodes], ","), mltj.Status.Attempts, int32(attempt))
	vouched, _ := fenceVouches(fenced, mltj.Status.Attempts, int32(attempt), n)
	return vouched
}

// evictedForRestart reports whether Kueue evicted the Workload for a reason the restart lifecycle answers: anything but
// a deactivation, which is an operator's stop or the fault path's, and the fault path's carries its own handoff.
//
// A Workload that is inactive now is never one: an operator who deactivated it after an earlier eviction stopped the
// job, and Kueue may still show the earlier reason.
// Kueue writes a deactivation as "Deactivated" or "DeactivatedDueTo<cause>" and matches both by the prefix, as here.
func evictedForRestart(wl *kueuev1beta1.Workload) bool {
	if wl.Spec.Active != nil && !*wl.Spec.Active {
		return false
	}
	c := meta.FindStatusCondition(wl.Status.Conditions, kueuev1beta1.WorkloadEvicted)
	return c != nil && c.Status == metav1.ConditionTrue && !strings.HasPrefix(c.Reason, kueuev1beta1.WorkloadDeactivated)
}

// handoffUncached reports whether any Workload of the Job carries the fault path's handoff, read past the cache.
func (r *MLTrainingJobReconciler) handoffUncached(ctx context.Context, mltj *platformv1.MLTrainingJob, job *batchv1.Job) (bool, error) {
	var wls kueuev1beta1.WorkloadList
	if err := r.apiReader().List(ctx, &wls, client.InNamespace(mltj.Namespace),
		client.MatchingLabels{kueueJobUIDLabel: string(job.UID)}); err != nil {
		return false, fmt.Errorf("list workloads of job %s/%s: %w", job.Namespace, job.Name, err)
	}
	for i := range wls.Items {
		if wls.Items[i].Annotations[AnnRestartHandoff] != "" {
			return true, nil
		}
	}
	return false, nil
}

// nodeUIDAbsent records a rank's node that no longer existed when the rank was first seen on it, and nodeUIDReplaced
// one whose Node was registered after the rank was bound there; neither names a machine any Node can answer for.
const (
	nodeUIDAbsent   = "absent"
	nodeUIDReplaced = "replaced"
)

// recordActive writes what the attempt learned while running: its Workload, the nodes its ranks were on, and the
// first time every rank was Ready.
func (r *MLTrainingJobReconciler) recordActive(ctx context.Context, mltj *platformv1.MLTrainingJob, wl *kueuev1beta1.Workload, nodes []string, uids map[string]string, allReady bool) error {
	cur := mltj.Status.Attempts[len(mltj.Status.Attempts)-1]
	changed := wl != nil && cur.WorkloadUID == ""
	for _, n := range nodes {
		if !slices.Contains(cur.Nodes, n) {
			changed = true
		}
	}
	for n := range uids {
		if _, known := cur.NodeUIDs[n]; !known {
			changed = true
		}
	}
	if allReady && cur.AllRanksReadyAt == nil {
		changed = true
	}
	if !changed {
		return nil
	}
	now := metav1.Now()
	return r.writeAttempts(ctx, mltj, func(a []platformv1.TrainingAttempt) []platformv1.TrainingAttempt {
		last := &a[len(a)-1]
		if wl != nil && last.WorkloadUID == "" {
			last.WorkloadName, last.WorkloadUID = wl.Name, string(wl.UID)
		}
		for _, n := range nodes {
			if !slices.Contains(last.Nodes, n) && len(last.Nodes) < 8 {
				last.Nodes = append(last.Nodes, n)
			}
		}
		slices.Sort(last.Nodes)
		for n, uid := range uids {
			if _, known := last.NodeUIDs[n]; known || !slices.Contains(last.Nodes, n) {
				continue
			}
			if last.NodeUIDs == nil {
				last.NodeUIDs = map[string]string{}
			}
			last.NodeUIDs[n] = uid
		}
		if allReady && last.AllRanksReadyAt == nil {
			last.AllRanksReadyAt = &now
		}
		return a
	})
}

// trigger moves the current attempt to Stopping, once.
func (r *MLTrainingJobReconciler) trigger(ctx context.Context, mltj *platformv1.MLTrainingJob, why string) (ctrl.Result, error) {
	now := metav1.Now()
	// An attempt that ends admitted but never seen running leaves an admission stamp the next attempt's Running would
	// be measured from, a window holding the failure, the stop barrier and the requeue (codex review r8).
	// Cleared in the same write, so the admission-to-running window is always one attempt's; the first attempt
	// seen running is the one the fields report.
	if mltj.Status.RunningObservedAt == nil {
		mltj.Status.AdmittedAt = nil
	}
	if err := r.writeAttempts(ctx, mltj, func(a []platformv1.TrainingAttempt) []platformv1.TrainingAttempt {
		last := &a[len(a)-1]
		last.State, last.Trigger, last.FailureObservedAt = attemptStopping, why, &now
		return a
	}); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{RequeueAfter: nextStep}, r.setMLTJPhase(ctx, mltj, mltjPhasePending,
		admittedCondition(metav1.ConditionFalse, mltjReasonRestarting), nil, nil, nil)
}

// stopAttempt retires the attempt's Job and confirms, on uncached reads, that nothing of the attempt is left.
func (r *MLTrainingJobReconciler) stopAttempt(ctx context.Context, mltj *platformv1.MLTrainingJob) (ctrl.Result, error) {
	if err := r.discover(ctx, mltj, nil); err != nil {
		return ctrl.Result{}, err
	}
	// Read after discover, which may have just recorded a node the barrier must check.
	cur := mltj.Status.Attempts[len(mltj.Status.Attempts)-1]
	waiting, used, err := r.stopBarrier(ctx, mltj, cur)
	if err != nil {
		return ctrl.Result{}, err
	}
	if waiting != "" {
		if waiting != cur.WaitingFor {
			if err := r.writeAttempts(ctx, mltj, func(a []platformv1.TrainingAttempt) []platformv1.TrainingAttempt {
				a[len(a)-1].WaitingFor = waiting
				return a
			}); err != nil {
				return ctrl.Result{}, err
			}
		}
		return ctrl.Result{RequeueAfter: stopPoll}, nil
	}
	now := metav1.Now()
	return ctrl.Result{RequeueAfter: nextStep}, r.writeAttempts(ctx, mltj, func(a []platformv1.TrainingAttempt) []platformv1.TrainingAttempt {
		last := &a[len(a)-1]
		// In the same write as Stopped, so no later attempt can see this one stopped and its entries unspent.
		last.State, last.WaitingFor, last.StopConfirmedAt, last.FencedBy = attemptStopped, "", &now, used
		return a
	})
}

// heldRanks names the Pods finRankStopped still holds because their stop is neither reported nor fenced, for the
// condition an operator reads.
func heldRanks(mltj *platformv1.MLTrainingJob, pods []corev1.Pod) string {
	var held []string
	for i := range pods {
		p := &pods[i]
		if controllerutil.ContainsFinalizer(p, finRankStopped) && !rankStopped(mltj, p, true) {
			held = append(held, p.Name+"@"+p.Spec.NodeName)
		}
	}
	if len(held) == 0 {
		return ""
	}
	slices.Sort(held)
	return "; held until their kubelet reports them stopped or their node is fenced: " + strings.Join(held, ",")
}

// stopBarrier deletes the attempt's Job if it is still there and returns what the attempt still waits on, or "", with
// the fenced-nodes entries its stop relied on.
//
// Every condition is read uncached, because a cache that has not yet seen a Pod or a Workload answers NotFound for
// it, and NotFound is exactly the answer that would let the next attempt start next to a running rank.
func (r *MLTrainingJobReconciler) stopBarrier(ctx context.Context, mltj *platformv1.MLTrainingJob, cur platformv1.TrainingAttempt) (string, []string, error) {
	var job batchv1.Job
	err := r.apiReader().Get(ctx, client.ObjectKeyFromObject(mltj), &job)
	switch {
	case err == nil && string(job.UID) == cur.JobUID:
		if job.DeletionTimestamp.IsZero() {
			// Conditioned on the UID, so a delete replayed after a lost response can never remove a newer attempt's Job.
			uid := job.UID
			if err := r.Delete(ctx, &job, client.Preconditions{UID: &uid}, client.PropagationPolicy(metav1.DeletePropagationForeground)); err != nil && !apierrors.IsNotFound(err) && !apierrors.IsConflict(err) {
				return "", nil, fmt.Errorf("delete attempt %d job: %w", cur.Number, err)
			}
		}
		return "job " + job.Name + " to be deleted", nil, nil
	case err == nil:
		// A Job of this name with another UID was created after this attempt's: not ours to wait for or delete.
	case !apierrors.IsNotFound(err):
		return "", nil, fmt.Errorf("get attempt %d job: %w", cur.Number, err)
	}

	var pods corev1.PodList
	if err := r.apiReader().List(ctx, &pods, client.InNamespace(mltj.Namespace), client.MatchingLabels{
		mltjUIDLabel: string(mltj.UID), mltjAttemptLabel: strconv.Itoa(int(cur.Number)),
	}); err != nil {
		return "", nil, fmt.Errorf("list attempt %d pods: %w", cur.Number, err)
	}
	if len(pods.Items) > 0 {
		names := make([]string, 0, len(pods.Items))
		for i := range pods.Items {
			names = append(names, pods.Items[i].Name)
		}
		slices.Sort(names)
		return "pods " + strings.Join(names, ",") + " to be gone" + heldRanks(mltj, pods.Items), nil, nil
	}

	// Kueue finds a Job's Workload by the owner's name, so a Workload left by this attempt would be matched to the
	// next attempt's Job of the same name and could hand it this attempt's state.
	// Two reads, because either alone can miss it: the recorded one may have lost Kueue's job-uid label, and one
	// created after the attempt's last Active pass was never recorded at all.
	if cur.WorkloadName != "" {
		var wl kueuev1beta1.Workload
		err := r.apiReader().Get(ctx, types.NamespacedName{Name: cur.WorkloadName, Namespace: mltj.Namespace}, &wl)
		switch {
		case err == nil && string(wl.UID) == cur.WorkloadUID:
			return "workload " + wl.Name + " to be gone", nil, nil
		case err != nil && !apierrors.IsNotFound(err):
			return "", nil, fmt.Errorf("get attempt %d workload: %w", cur.Number, err)
		}
	}
	if cur.JobUID != "" {
		var wls kueuev1beta1.WorkloadList
		if err := r.apiReader().List(ctx, &wls, client.InNamespace(mltj.Namespace),
			client.MatchingLabels{kueueJobUIDLabel: cur.JobUID}); err != nil {
			return "", nil, fmt.Errorf("list attempt %d workloads: %w", cur.Number, err)
		}
		if len(wls.Items) > 0 {
			return "workload " + wls.Items[0].Name + " to be gone", nil, nil
		}
	}

	unfenced, bound, used, err := r.unfencedNodes(ctx, mltj, cur)
	if err != nil {
		return "", nil, err
	}
	if len(unfenced) > 0 {
		waiting := "node " + strings.Join(unfenced, ",") + " to be fenced (annotation " + annFencedNodes + ")"
		if len(bound) > 0 {
			// Said in the condition, because the bare name an operator would write is the one this refuses.
			waiting += "; an earlier attempt ran on another machine of the same name, so name it as " + strings.Join(bound, ",")
		}
		if spentFor(mltj, cur.Number, unfenced) {
			// Said in the condition, because an operator who sees their entry still on the object would expect it to count.
			waiting += "; an entry an earlier attempt stopped on is spent, so scope one to this attempt as name#" +
				strconv.Itoa(int(cur.Number))
		}
		return waiting, nil, nil
	}
	return "", used, nil
}

// unfencedNodes returns the nodes that held a rank of attempt cur, cannot be shown to have stopped it, and are not
// acknowledged as off, and for those a bare name can no longer acknowledge, the name@uid entry that would.
//
// A node that is Ready answered for its own Pods, so their absence from the API is the kubelet's report that they
// stopped. A node that is not Ready, or no longer exists, reported nothing; only the annotation can vouch for it.
func (r *MLTrainingJobReconciler) unfencedNodes(ctx context.Context, mltj *platformv1.MLTrainingJob, cur platformv1.TrainingAttempt) ([]string, []string, []string, error) {
	fenced := fenceEntries(strings.Split(mltj.Annotations[annFencedNodes], ","), mltj.Status.Attempts, cur.Number)
	var out, bound, used []string
	for _, n := range cur.Nodes {
		vouched, needsUID := fenceVouches(fenced, mltj.Status.Attempts, cur.Number, n)
		if vouched {
			// Recorded as spent, so the same words cannot vouch for this machine again in a later attempt.
			if e := n + "@" + machineID(cur, n); slices.Contains(fenced, e) {
				used = append(used, e)
			} else {
				used = append(used, n)
			}
			continue
		}
		var node corev1.Node
		err := r.apiReader().Get(ctx, types.NamespacedName{Name: n}, &node)
		switch {
		case apierrors.IsNotFound(err):
		case err != nil:
			return nil, nil, nil, fmt.Errorf("get node %s: %w", n, err)
		default:
			// Another Node under the recorded name is another machine, whose readiness says nothing of the rank's.
			// An attempt recorded before nodeUIDs existed has none to compare, and is judged by the name as it was.
			want, known := cur.NodeUIDs[n]
			if c := nodeReady(&node); (!known || want == string(node.UID)) && c != nil && c.Status == corev1.ConditionTrue {
				continue
			}
		}
		out = append(out, n)
		if needsUID {
			bound = append(bound, n+"@"+machineID(cur, n))
		}
	}
	return out, bound, used, nil
}

// machineID is how attempt a's record names the machine its rank ran on as node n: the Node's UID, or "" for an
// attempt recorded before UIDs were.
// A node already gone, or already replaced, when the rank was first seen has no UID of its own, and the word recorded
// for it is the same for every such machine, so it is pinned to the attempt: an acknowledgement for it can never carry
// over to a later one.
func machineID(a platformv1.TrainingAttempt, n string) string {
	if id := a.NodeUIDs[n]; id != nodeUIDAbsent && id != nodeUIDReplaced {
		return id
	}
	return a.NodeUIDs[n] + "-a" + strconv.Itoa(int(a.Number))
}

// spentFor reports whether an unscoped entry naming one of nodes is on the object but spent by an earlier attempt.
func spentFor(mltj *platformv1.MLTrainingJob, cur int32, nodes []string) bool {
	live := fenceEntries(strings.Split(mltj.Annotations[annFencedNodes], ","), mltj.Status.Attempts, cur)
	for e := range strings.SplitSeq(mltj.Annotations[annFencedNodes], ",") {
		e = strings.TrimSpace(e)
		name, _, _ := strings.Cut(e, "@")
		if e != "" && !strings.Contains(e, "#") && slices.Contains(nodes, name) && !slices.Contains(live, e) {
			return true
		}
	}
	return false
}

// fenceEntries returns the fenced-nodes entries that may speak for attempt cur, with any scope removed: an entry
// scoped to another attempt is dropped, one scoped to cur is kept, and an unscoped one is kept unless an earlier
// attempt has already stopped on it.
func fenceEntries(raw []string, attempts []platformv1.TrainingAttempt, cur int32) []string {
	var out []string
	for _, e := range raw {
		e = strings.TrimSpace(e)
		if e == "" {
			continue
		}
		if base, scope, ok := strings.Cut(e, "#"); ok {
			if scope == strconv.Itoa(int(cur)) {
				out = append(out, base)
			}
			continue
		}
		spent := false
		for _, a := range attempts {
			if a.Number < cur && slices.Contains(a.FencedBy, e) {
				spent = true
			}
		}
		if !spent {
			out = append(out, e)
		}
	}
	return out
}

// fenceVouches reports whether the fenced-nodes entries acknowledge node n of attempt number cur as off, and whether
// only n@id, with id that attempt's machineID, could.
//
// An entry n@id names one machine and always vouches for it.
// A bare name says nothing of which machine it meant, and it is never consumed: written for a machine lost in one
// attempt, it would still stand when another machine registered under the name is lost in a later one.
// So a bare name vouches only while every attempt that ran on n names the same machine, meaning the job has seen one
// machine of that name; an attempt recorded before UIDs were is judged by the name alone, as it was.
func fenceVouches(fenced []string, attempts []platformv1.TrainingAttempt, cur int32, n string) (bool, bool) {
	var id string
	for _, a := range attempts {
		if a.Number == cur {
			id = machineID(a, n)
		}
	}
	if id == "" {
		return slices.Contains(fenced, n), false
	}
	if slices.Contains(fenced, n+"@"+id) {
		return true, false
	}
	for _, a := range attempts {
		if a.Number != cur && slices.Contains(a.Nodes, n) && machineID(a, n) != id {
			return false, true
		}
	}
	return slices.Contains(fenced, n), false
}

// nodeReady returns the node's Ready condition, or nil.
func nodeReady(node *corev1.Node) *corev1.NodeCondition {
	for i := range node.Status.Conditions {
		if node.Status.Conditions[i].Type == corev1.NodeReady {
			return &node.Status.Conditions[i]
		}
	}
	return nil
}

// afterStopped starts the next attempt, or fails the job once the budget is spent.
//
// The budget is counted from the attempts that exist: attempt n is restart n-1, and maxRestarts restarts allow
// maxRestarts+1 attempts in all.
func (r *MLTrainingJobReconciler) afterStopped(ctx context.Context, mltj *platformv1.MLTrainingJob, cur platformv1.TrainingAttempt) (ctrl.Result, error) {
	if err := r.deleteAttemptService(ctx, mltj, cur.Number); err != nil {
		return ctrl.Result{}, err
	}
	if cur.Number > mltj.Spec.Distributed.MaxRestarts {
		_, err := r.markFailed(ctx, mltj, mltjReasonRestartsExhausted, fmt.Sprintf(
			"attempt %d ended (%s) and maxRestarts %d is spent", cur.Number, cur.Trigger, mltj.Spec.Distributed.MaxRestarts))
		return ctrl.Result{}, err
	}
	return ctrl.Result{RequeueAfter: nextStep}, r.writeAttempts(ctx, mltj, func(a []platformv1.TrainingAttempt) []platformv1.TrainingAttempt {
		return append(a, platformv1.TrainingAttempt{Number: cur.Number + 1, State: attemptPreparing})
	})
}

// +kubebuilder:rbac:groups="",resources=services,verbs=delete

// deleteAttemptService removes a stopped attempt's rendezvous Service, which nothing will resolve again.
func (r *MLTrainingJobReconciler) deleteAttemptService(ctx context.Context, mltj *platformv1.MLTrainingJob, attempt int32) error {
	key := types.NamespacedName{Name: rendezvousServiceNameFor(mltj, attempt), Namespace: mltj.Namespace}
	var svc corev1.Service
	if err := r.Get(ctx, key, &svc); err != nil {
		return client.IgnoreNotFound(err)
	}
	if !metav1.IsControlledBy(&svc, mltj) {
		return nil
	}
	return client.IgnoreNotFound(r.Delete(ctx, &svc))
}

// +kubebuilder:rbac:groups="",resources=pods,verbs=get;list;patch
// +kubebuilder:rbac:groups="",resources=nodes,verbs=get

// attemptPods lists this attempt's Pods.
//
// Read uncached: a list through the manager's client would start a cluster-wide Pod informer this controller has no
// watch permission for, and the barrier reads the same Pods uncached anyway.
func (r *MLTrainingJobReconciler) attemptPods(ctx context.Context, mltj *platformv1.MLTrainingJob, attempt int32) ([]corev1.Pod, error) {
	var pods corev1.PodList
	if err := r.apiReader().List(ctx, &pods, client.InNamespace(mltj.Namespace), client.MatchingLabels{
		mltjUIDLabel: string(mltj.UID), mltjAttemptLabel: strconv.Itoa(int(attempt)),
	}); err != nil {
		return nil, fmt.Errorf("list attempt %d pods: %w", attempt, err)
	}
	return pods.Items, nil
}

// retireOnDelete runs while a restartable job is being deleted, before its finalizer goes: it deletes the current
// Job and releases each rank Pod only once that rank is known to have stopped, so the job's objects are gone only
// when no rank of it can still be writing to the state volume.
// It returns true once nothing of the job is left.
func (r *MLTrainingJobReconciler) retireOnDelete(ctx context.Context, mltj *platformv1.MLTrainingJob) (bool, error) {
	// The Pods first, whatever the Job is doing: a Job the stop barrier already deletes in the foreground waits for its
	// Pods, and Pods this controller holds would then hold the Job, and the job, for good.
	var pods corev1.PodList
	if err := r.apiReader().List(ctx, &pods, client.InNamespace(mltj.Namespace),
		client.MatchingLabels{mltjUIDLabel: string(mltj.UID)}); err != nil {
		return false, fmt.Errorf("list pods of deleted mltrainingjob %s/%s: %w", mltj.Namespace, mltj.Name, err)
	}
	for i := range pods.Items {
		p := &pods.Items[i]
		// No next attempt needs the node recorded, so only the stop itself is asked for.
		if controllerutil.ContainsFinalizer(p, finRankStopped) && rankStopped(mltj, p, false) {
			if err := r.releaseRank(ctx, p); err != nil {
				return false, err
			}
		}
	}
	var job batchv1.Job
	switch err := r.apiReader().Get(ctx, client.ObjectKeyFromObject(mltj), &job); {
	case err == nil && metav1.IsControlledBy(&job, mltj):
		if job.DeletionTimestamp.IsZero() {
			uid := job.UID
			if err := r.Delete(ctx, &job, client.Preconditions{UID: &uid}, client.PropagationPolicy(metav1.DeletePropagationBackground)); err != nil && !apierrors.IsNotFound(err) && !apierrors.IsConflict(err) {
				return false, fmt.Errorf("delete job of deleted mltrainingjob %s/%s: %w", mltj.Namespace, mltj.Name, err)
			}
		}
		return false, nil
	case err != nil && !apierrors.IsNotFound(err):
		return false, fmt.Errorf("get job of deleted mltrainingjob %s/%s: %w", mltj.Namespace, mltj.Name, err)
	}
	return len(pods.Items) == 0, nil
}

// attemptOwns reports whether a Job is this attempt's: controlled by this MLTrainingJob and carrying its attempt.
func attemptOwns(job *batchv1.Job, mltj *platformv1.MLTrainingJob, attempt int32) bool {
	return metav1.IsControlledBy(job, mltj) && job.Labels[mltjAttemptLabel] == strconv.Itoa(int(attempt))
}

// jobFailed reports whether the Job controller has decided the Job failed: Failed, or FailureTarget, which it sets
// first and which already means the remaining ranks are being terminated.
func jobFailed(job *batchv1.Job) bool {
	for _, c := range job.Status.Conditions {
		if (c.Type == batchv1.JobFailed || c.Type == batchv1.JobFailureTarget) && c.Status == corev1.ConditionTrue {
			return true
		}
	}
	return false
}

// writeAttempts applies a change to the attempts list and writes status, honouring the resource version so two
// reconciles cannot both believe they advanced the same attempt.
func (r *MLTrainingJobReconciler) writeAttempts(ctx context.Context, mltj *platformv1.MLTrainingJob, change func([]platformv1.TrainingAttempt) []platformv1.TrainingAttempt) error {
	mltj.Status.Attempts = change(slices.Clone(mltj.Status.Attempts))
	mltj.Status.ObservedGeneration = mltj.Generation
	if err := r.Status().Update(ctx, mltj); err != nil {
		return fmt.Errorf("update attempts of mltrainingjob %s/%s: %w", mltj.Namespace, mltj.Name, err)
	}
	return nil
}

// apiReader is the uncached reader the barrier needs; tests that construct a reconciler without one read through
// the client they gave it.
func (r *MLTrainingJobReconciler) apiReader() client.Reader {
	if r.APIReader != nil {
		return r.APIReader
	}
	return r.Client
}
