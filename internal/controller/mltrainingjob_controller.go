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
	"maps"
	"time"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/equality"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
	kueuev1beta1 "sigs.k8s.io/kueue/apis/kueue/v1beta1"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// MLTrainingJobReconciler reconciles a MLTrainingJob object
type MLTrainingJobReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=platform.lkhun9311.github.io,resources=mltrainingjobs,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=platform.lkhun9311.github.io,resources=mltrainingjobs/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=platform.lkhun9311.github.io,resources=mltrainingjobs/finalizers,verbs=update
// +kubebuilder:rbac:groups=batch,resources=jobs,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=kueue.x-k8s.io,resources=workloads,verbs=get;list;watch

// Reconcile syncs an owned, suspended batch/v1 Job from the MLTrainingJob spec.
//
// Suspend is set true only when the Job is first created.
//
// Kueue flips it to false to admit the workload, and this reconciler never touches it again on update, or the operator and Kueue would fight over the field forever.
func (r *MLTrainingJobReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := logf.FromContext(ctx)

	var mltj platformv1.MLTrainingJob
	if err := r.Get(ctx, req.NamespacedName, &mltj); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// Handle deletion: the owned Job carries a controller owner reference, so garbage collection removes it.
	//
	// The reconciler only needs to drop the finalizer once that has had a chance to happen.
	if !mltj.DeletionTimestamp.IsZero() {
		if controllerutil.ContainsFinalizer(&mltj, mlTrainingJobFinalizer) {
			controllerutil.RemoveFinalizer(&mltj, mlTrainingJobFinalizer)
			if err := r.Update(ctx, &mltj); err != nil {
				return ctrl.Result{}, fmt.Errorf("remove finalizer from mltrainingjob %s: %w", mltj.Name, err)
			}
		}
		return ctrl.Result{}, nil
	}

	// Ensure the finalizer is present before doing any work.
	if !controllerutil.ContainsFinalizer(&mltj, mlTrainingJobFinalizer) {
		controllerutil.AddFinalizer(&mltj, mlTrainingJobFinalizer)
		if err := r.Update(ctx, &mltj); err != nil {
			return ctrl.Result{}, fmt.Errorf("add finalizer to mltrainingjob %s: %w", mltj.Name, err)
		}
		return ctrl.Result{}, nil
	}

	if conflict, err := r.ownedConflict(ctx, &mltj, &batchv1.Job{}); err != nil {
		return ctrl.Result{}, fmt.Errorf("check job ownership %s/%s: %w", mltj.Namespace, mltj.Name, err)
	} else if conflict {
		log.Info("Job exists and is not owned by this MLTrainingJob; refusing to adopt", "name", mltj.Name)
		return r.markFailed(ctx, &mltj, mltjReasonConflict, "a Job of the same name is not owned by this MLTrainingJob")
	}

	desired := r.buildJob(&mltj)
	job := &batchv1.Job{ObjectMeta: metav1.ObjectMeta{Name: mltj.Name, Namespace: mltj.Namespace}}
	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, job, func() error {
		// Suspend and the pod template are set once, on create, and never touched again.
		//
		// Suspend must stay untouched after that so Kueue can unsuspend to admit the workload.
		//
		// The template is immutable once the Job exists (its labels must keep matching the server-assigned selector), so re-sending our locally built copy on every reconcile would fail validation.
		if job.CreationTimestamp.IsZero() {
			job.Spec.Suspend = new(true)
			job.Spec.Template = desired.Spec.Template
		}
		// Merge the desired labels in rather than replacing the map, so any label Kueue or the apiserver adds to the Job is preserved across reconciles.
		if job.Labels == nil {
			job.Labels = map[string]string{}
		}
		maps.Copy(job.Labels, desired.Labels)
		job.Spec.Parallelism = desired.Spec.Parallelism
		job.Spec.Completions = desired.Spec.Completions
		return controllerutil.SetControllerReference(&mltj, job, r.Scheme)
	}); err != nil {
		return ctrl.Result{}, fmt.Errorf("sync training job %s/%s: %w", mltj.Namespace, mltj.Name, err)
	}

	log.Info("Synced training job", "mlTrainingJob", req.String())

	wl, err := r.getWorkloadForJob(ctx, job)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("get kueue workload for job %s/%s: %w", mltj.Namespace, mltj.Name, err)
	}

	phase, cond := computeMLTJPhase(job, wl)
	if err := r.setMLTJPhase(ctx, &mltj, phase, cond); err != nil {
		return ctrl.Result{}, err
	}

	return ctrl.Result{}, nil
}

// buildJob renders the desired batch/v1 Job for a training job.
//
// Suspend is deliberately absent here: the caller decides whether to set it, since it only applies on the create path and must never be reconciled on update, as Kueue owns it after admission.
func (r *MLTrainingJobReconciler) buildJob(mltj *platformv1.MLTrainingJob) *batchv1.Job {
	labels := map[string]string{kueueQueueLabel: mltj.Spec.Queue}
	return &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{Name: mltj.Name, Namespace: mltj.Namespace, Labels: labels},
		Spec: batchv1.JobSpec{
			Parallelism: new(defaultOne(mltj.Spec.Parallelism)),
			Completions: new(defaultOne(mltj.Spec.Completions)),
			Template: corev1.PodTemplateSpec{
				Spec: corev1.PodSpec{
					RestartPolicy: corev1.RestartPolicyNever,
					Containers: []corev1.Container{{
						Name:    "trainer",
						Image:   mltj.Spec.Image,
						Command: mltj.Spec.Command,
						Resources: corev1.ResourceRequirements{
							Limits: corev1.ResourceList{nvidiaGPUResource: *resource.NewQuantity(int64(mltj.Spec.GPUCount), resource.DecimalSI)},
						},
					}},
				},
			},
		},
	}
}

// defaultOne returns v, or 1 when v is not positive.
//
// The CRD's kubebuilder default of 1 only applies when the field is omitted from a request payload.
//
// It does not backfill a zero-value struct built in Go, so buildJob applies the same default explicitly.
func defaultOne(v int32) int32 {
	if v <= 0 {
		return 1
	}
	return v
}

// markFailed reflects a deterministic failure into status as Failed with the JobSynced condition set to False.
//
// It returns a RequeueAfter so the job recovers automatically once the blocking condition clears, since a conflicting foreign Job is not owned and so does not trigger the owned-Job watch.
func (r *MLTrainingJobReconciler) markFailed(ctx context.Context, mltj *platformv1.MLTrainingJob, reason, msg string) (ctrl.Result, error) {
	desired := mltj.Status.DeepCopy()
	phaseChanged := desired.Phase != mltjPhaseFailed
	desired.Phase = mltjPhaseFailed
	desired.ObservedGeneration = mltj.Generation
	meta.SetStatusCondition(&desired.Conditions, metav1.Condition{
		Type: mltjCondSynced, Status: metav1.ConditionFalse, Reason: reason, Message: msg, ObservedGeneration: mltj.Generation,
	})
	if !equality.Semantic.DeepEqual(mltj.Status, *desired) {
		if phaseChanged {
			now := metav1.Now()
			desired.LastTransitionTime = &now
		}
		mltj.Status = *desired
		if err := r.Status().Update(ctx, mltj); err != nil {
			return ctrl.Result{}, fmt.Errorf("update mltrainingjob status %s/%s to Failed: %w", mltj.Namespace, mltj.Name, err)
		}

		// Count the transition only after the status write succeeds, so a reconcile that finds the object already Failed does not inflate the metric.
		mlTrainingJobFailedTotal.WithLabelValues(reason).Inc()

		// The phase counter tracks every entry into a phase, so a failure reached here counts the same as one reached through the normal phase translation.
		if phaseChanged {
			mlTrainingJobPhaseTotal.WithLabelValues(mltjPhaseFailed).Inc()
		}
	}
	return ctrl.Result{RequeueAfter: time.Minute}, nil
}

// computeMLTJPhase derives the training phase from the Job and its Kueue Workload.
//
// Kueue admission is read from the Workload's Admitted condition, since the Job's suspend flag alone is ambiguous mid-transition.
func computeMLTJPhase(job *batchv1.Job, wl *kueuev1beta1.Workload) (string, metav1.Condition) {
	if isJobConditionTrue(job, batchv1.JobFailed) {
		return mltjPhaseFailed, admittedCondition(metav1.ConditionFalse, "JobFailed")
	}
	if isJobConditionTrue(job, batchv1.JobComplete) {
		return mltjPhaseSucceeded, admittedCondition(metav1.ConditionTrue, "JobComplete")
	}
	if job.Status.Active > 0 {
		return mltjPhaseRunning, admittedCondition(metav1.ConditionTrue, "PodsRunning")
	}
	if wl != nil && meta.IsStatusConditionTrue(wl.Status.Conditions, kueuev1beta1.WorkloadAdmitted) {
		return mltjPhaseAdmitted, admittedCondition(metav1.ConditionTrue, "QuotaReserved")
	}
	return mltjPhasePending, admittedCondition(metav1.ConditionFalse, "QueuedForAdmission")
}

// isJobConditionTrue reports whether the Job carries the given condition type with status True.
func isJobConditionTrue(job *batchv1.Job, condType batchv1.JobConditionType) bool {
	for i := range job.Status.Conditions {
		if job.Status.Conditions[i].Type == condType {
			return job.Status.Conditions[i].Status == corev1.ConditionTrue
		}
	}
	return false
}

// admittedCondition builds the MLTrainingJob Admitted condition for a phase transition.
//
// The message is left empty; the reason and the phase it is paired with already say what happened.
func admittedCondition(status metav1.ConditionStatus, reason string) metav1.Condition {
	return metav1.Condition{Type: mltjCondAdmitted, Status: status, Reason: reason}
}

// getWorkloadForJob returns the Kueue Workload created for a Job, or nil if Kueue has not created one yet.
//
// Kueue stamps every Workload it creates with the kueue.x-k8s.io/job-uid label, so listing by that label is the primary lookup.
//
// A Workload whose owner reference points at the Job's UID is accepted as a fallback, in case a Workload ever exists without the label.
func (r *MLTrainingJobReconciler) getWorkloadForJob(ctx context.Context, job *batchv1.Job) (*kueuev1beta1.Workload, error) {
	var byLabel kueuev1beta1.WorkloadList
	if err := r.List(ctx, &byLabel, client.InNamespace(job.Namespace), client.MatchingLabels{kueueJobUIDLabel: string(job.UID)}); err != nil {
		return nil, fmt.Errorf("list workloads for job %s/%s by job-uid label: %w", job.Namespace, job.Name, err)
	}
	if len(byLabel.Items) > 0 {
		// Kueue keeps one Workload per Job UID, so more than one match means that invariant was violated upstream.
		//
		// Surface it rather than silently picking one, then take the first so the reconcile still makes progress.
		if len(byLabel.Items) > 1 {
			logf.FromContext(ctx).Info("multiple Kueue Workloads share one job-uid label; using the first",
				"job", job.Namespace+"/"+job.Name, "count", len(byLabel.Items))
		}
		return &byLabel.Items[0], nil
	}

	var all kueuev1beta1.WorkloadList
	if err := r.List(ctx, &all, client.InNamespace(job.Namespace)); err != nil {
		return nil, fmt.Errorf("list workloads in namespace %s: %w", job.Namespace, err)
	}
	for i := range all.Items {
		for _, ref := range all.Items[i].OwnerReferences {
			if ref.UID == job.UID {
				return &all.Items[i], nil
			}
		}
	}
	return nil, nil
}

// setMLTJPhase writes the phase and the Admitted condition to status, but only when either actually changes.
//
// lastTransitionTime is stamped only on a phase transition, not on every reconcile that finds the same phase.
func (r *MLTrainingJobReconciler) setMLTJPhase(ctx context.Context, mltj *platformv1.MLTrainingJob, phase string, cond metav1.Condition) error {
	desired := mltj.Status.DeepCopy()
	phaseChanged := desired.Phase != phase
	desired.Phase = phase
	desired.ObservedGeneration = mltj.Generation

	cond.ObservedGeneration = mltj.Generation
	meta.SetStatusCondition(&desired.Conditions, cond)

	if equality.Semantic.DeepEqual(mltj.Status, *desired) {
		return nil
	}

	if phaseChanged {
		now := metav1.Now()
		desired.LastTransitionTime = &now
	}

	mltj.Status = *desired
	if err := r.Status().Update(ctx, mltj); err != nil {
		return fmt.Errorf("update mltrainingjob status %s/%s to phase %s: %w", mltj.Namespace, mltj.Name, phase, err)
	}

	// Increment the phase transition counter only when the phase actually changed.
	if phaseChanged {
		mlTrainingJobPhaseTotal.WithLabelValues(phase).Inc()
	}

	return nil
}

// mapWorkloadToMLTrainingJob maps a Workload event to a reconcile request for the MLTrainingJob that owns its Job.
//
// A Kueue Workload's owner reference points at the batch/v1 Job it is admitting, and that Job always shares its name with the MLTrainingJob that created it, so no further lookup is needed.
func mapWorkloadToMLTrainingJob(_ context.Context, obj client.Object) []reconcile.Request {
	for _, ref := range obj.GetOwnerReferences() {
		// Match the batch/v1 Job specifically, so a same-named owner from another API group cannot enqueue a spurious request.
		if ref.Kind == "Job" && ref.APIVersion == "batch/v1" {
			return []reconcile.Request{{NamespacedName: types.NamespacedName{Name: ref.Name, Namespace: obj.GetNamespace()}}}
		}
	}
	return nil
}

// ownedConflict reports whether an object of the given name exists but is not controlled by mltj.
func (r *MLTrainingJobReconciler) ownedConflict(ctx context.Context, mltj *platformv1.MLTrainingJob, obj client.Object) (bool, error) {
	err := r.Get(ctx, types.NamespacedName{Name: mltj.Name, Namespace: mltj.Namespace}, obj)
	switch {
	case apierrors.IsNotFound(err):
		return false, nil
	case err != nil:
		return false, err
	default:
		return !metav1.IsControlledBy(obj, mltj), nil
	}
}

// SetupWithManager sets up the controller with the Manager.
func (r *MLTrainingJobReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&platformv1.MLTrainingJob{}).
		Owns(&batchv1.Job{}).
		Watches(&kueuev1beta1.Workload{}, handler.EnqueueRequestsFromMapFunc(mapWorkloadToMLTrainingJob)).
		Named("mltrainingjob").
		Complete(r)
}
