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
	triggerJobDeleted = "JobDeleted"
)

// annFencedNodes is how an operator, or the experiment's runner after reading the instance as terminated, says that
// nodes which stopped answering are really off: a comma-separated list of node names on the MLTrainingJob.
//
// It is never inferred. A Node object deleted, or a Pod gone from the API, does not stop a process on a machine the
// control plane cannot reach, and that process may still be writing to the shared checkpoint volume.
const annFencedNodes = "platform.lkhun9311.github.io/fenced-nodes"

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
	if jobFailed(&job) {
		return r.trigger(ctx, mltj, triggerRankFailed)
	}
	if wl != nil && wl.Annotations[AnnRestartHandoff] != "" {
		return r.trigger(ctx, mltj, triggerNodeFault)
	}

	phase, cond := computeMLTJPhase(&job, wl, true)
	if phase == mltjPhaseRunning {
		if err := r.recordActive(ctx, mltj, nil, nil, true); err != nil {
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
	nodes, err := r.rankNodes(ctx, mltj, cur.Number)
	if err != nil {
		return err
	}
	return r.recordActive(ctx, mltj, wl, nodes, false)
}

// recordActive writes what the attempt learned while running: its Workload, the nodes its ranks were on, and the
// first time every rank was Ready.
func (r *MLTrainingJobReconciler) recordActive(ctx context.Context, mltj *platformv1.MLTrainingJob, wl *kueuev1beta1.Workload, nodes []string, allReady bool) error {
	cur := mltj.Status.Attempts[len(mltj.Status.Attempts)-1]
	changed := wl != nil && cur.WorkloadUID == ""
	for _, n := range nodes {
		if !slices.Contains(cur.Nodes, n) {
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
		if allReady && last.AllRanksReadyAt == nil {
			last.AllRanksReadyAt = &now
		}
		return a
	})
}

// trigger moves the current attempt to Stopping, once.
func (r *MLTrainingJobReconciler) trigger(ctx context.Context, mltj *platformv1.MLTrainingJob, why string) (ctrl.Result, error) {
	now := metav1.Now()
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
	waiting, err := r.stopBarrier(ctx, mltj, cur)
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
		last.State, last.WaitingFor, last.StopConfirmedAt = attemptStopped, "", &now
		return a
	})
}

// stopBarrier deletes the attempt's Job if it is still there and returns what the attempt still waits on, or "".
//
// Every condition is read uncached, because a cache that has not yet seen a Pod or a Workload answers NotFound for
// it, and NotFound is exactly the answer that would let the next attempt start next to a running rank.
func (r *MLTrainingJobReconciler) stopBarrier(ctx context.Context, mltj *platformv1.MLTrainingJob, cur platformv1.TrainingAttempt) (string, error) {
	var job batchv1.Job
	err := r.apiReader().Get(ctx, client.ObjectKeyFromObject(mltj), &job)
	switch {
	case err == nil && string(job.UID) == cur.JobUID:
		if job.DeletionTimestamp.IsZero() {
			// Conditioned on the UID, so a delete replayed after a lost response can never remove a newer attempt's Job.
			uid := job.UID
			if err := r.Delete(ctx, &job, client.Preconditions{UID: &uid}, client.PropagationPolicy(metav1.DeletePropagationForeground)); err != nil && !apierrors.IsNotFound(err) && !apierrors.IsConflict(err) {
				return "", fmt.Errorf("delete attempt %d job: %w", cur.Number, err)
			}
		}
		return "job " + job.Name + " to be deleted", nil
	case err == nil:
		// A Job of this name with another UID was created after this attempt's: not ours to wait for or delete.
	case !apierrors.IsNotFound(err):
		return "", fmt.Errorf("get attempt %d job: %w", cur.Number, err)
	}

	var pods corev1.PodList
	if err := r.apiReader().List(ctx, &pods, client.InNamespace(mltj.Namespace), client.MatchingLabels{
		mltjUIDLabel: string(mltj.UID), mltjAttemptLabel: strconv.Itoa(int(cur.Number)),
	}); err != nil {
		return "", fmt.Errorf("list attempt %d pods: %w", cur.Number, err)
	}
	if len(pods.Items) > 0 {
		names := make([]string, 0, len(pods.Items))
		for i := range pods.Items {
			names = append(names, pods.Items[i].Name)
		}
		slices.Sort(names)
		return "pods " + strings.Join(names, ",") + " to be gone", nil
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
			return "workload " + wl.Name + " to be gone", nil
		case err != nil && !apierrors.IsNotFound(err):
			return "", fmt.Errorf("get attempt %d workload: %w", cur.Number, err)
		}
	}
	if cur.JobUID != "" {
		var wls kueuev1beta1.WorkloadList
		if err := r.apiReader().List(ctx, &wls, client.InNamespace(mltj.Namespace),
			client.MatchingLabels{kueueJobUIDLabel: cur.JobUID}); err != nil {
			return "", fmt.Errorf("list attempt %d workloads: %w", cur.Number, err)
		}
		if len(wls.Items) > 0 {
			return "workload " + wls.Items[0].Name + " to be gone", nil
		}
	}

	unfenced, err := r.unfencedNodes(ctx, mltj, cur.Nodes)
	if err != nil {
		return "", err
	}
	if len(unfenced) > 0 {
		return "node " + strings.Join(unfenced, ",") + " to be fenced (annotation " + annFencedNodes + ")", nil
	}
	return "", nil
}

// unfencedNodes returns the nodes that held a rank, cannot be shown to have stopped it, and are not acknowledged as off.
//
// A node that is Ready answered for its own Pods, so their absence from the API is the kubelet's report that they
// stopped. A node that is not Ready, or no longer exists, reported nothing; only the annotation can vouch for it.
func (r *MLTrainingJobReconciler) unfencedNodes(ctx context.Context, mltj *platformv1.MLTrainingJob, nodes []string) ([]string, error) {
	fenced := strings.Split(mltj.Annotations[annFencedNodes], ",")
	var out []string
	for _, n := range nodes {
		if slices.Contains(fenced, n) {
			continue
		}
		var node corev1.Node
		err := r.apiReader().Get(ctx, types.NamespacedName{Name: n}, &node)
		switch {
		case apierrors.IsNotFound(err):
			out = append(out, n)
		case err != nil:
			return nil, fmt.Errorf("get node %s: %w", n, err)
		default:
			if c := nodeReady(&node); c == nil || c.Status != corev1.ConditionTrue {
				out = append(out, n)
			}
		}
	}
	return out, nil
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

// +kubebuilder:rbac:groups="",resources=pods,verbs=get;list
// +kubebuilder:rbac:groups="",resources=nodes,verbs=get

// rankNodes lists the nodes this attempt's Pods were scheduled to.
//
// Read uncached: a list through the manager's client would start a cluster-wide Pod informer this controller has no
// watch permission for, and the barrier reads the same Pods uncached anyway.
func (r *MLTrainingJobReconciler) rankNodes(ctx context.Context, mltj *platformv1.MLTrainingJob, attempt int32) ([]string, error) {
	var pods corev1.PodList
	if err := r.apiReader().List(ctx, &pods, client.InNamespace(mltj.Namespace), client.MatchingLabels{
		mltjUIDLabel: string(mltj.UID), mltjAttemptLabel: strconv.Itoa(int(attempt)),
	}); err != nil {
		return nil, fmt.Errorf("list attempt %d pods: %w", attempt, err)
	}
	var nodes []string
	for i := range pods.Items {
		if n := pods.Items[i].Spec.NodeName; n != "" && !slices.Contains(nodes, n) {
			nodes = append(nodes, n)
		}
	}
	return nodes, nil
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
