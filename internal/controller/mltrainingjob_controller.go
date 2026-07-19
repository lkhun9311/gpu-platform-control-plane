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
	logf "sigs.k8s.io/controller-runtime/pkg/log"

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
		job.Labels = desired.Labels
		job.Spec.Parallelism = desired.Spec.Parallelism
		job.Spec.Completions = desired.Spec.Completions
		return controllerutil.SetControllerReference(&mltj, job, r.Scheme)
	}); err != nil {
		return ctrl.Result{}, fmt.Errorf("sync training job %s/%s: %w", mltj.Namespace, mltj.Name, err)
	}

	log.Info("Synced training job", "mlTrainingJob", req.String())

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
func (r *MLTrainingJobReconciler) markFailed(ctx context.Context, mltj *platformv1.MLTrainingJob, reason, msg string) (ctrl.Result, error) {
	desired := mltj.Status.DeepCopy()
	desired.Phase = mltjPhaseFailed
	desired.ObservedGeneration = mltj.Generation
	meta.SetStatusCondition(&desired.Conditions, metav1.Condition{
		Type: mltjCondSynced, Status: metav1.ConditionFalse, Reason: reason, Message: msg, ObservedGeneration: mltj.Generation,
	})
	if !equality.Semantic.DeepEqual(mltj.Status, *desired) {
		mltj.Status = *desired
		if err := r.Status().Update(ctx, mltj); err != nil {
			return ctrl.Result{}, fmt.Errorf("update mltrainingjob status %s/%s to Failed: %w", mltj.Namespace, mltj.Name, err)
		}

		// Count the transition only after the status write succeeds, so a reconcile that finds the object already Failed does not inflate the metric.
		mlTrainingJobFailedTotal.WithLabelValues(reason).Inc()
	}
	return ctrl.Result{}, nil
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
		Named("mltrainingjob").
		Complete(r)
}
