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
	"time"

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

const (
	// gpuQuotaFinalizer guards GPUQuotaPolicy cleanup.
	// On deletion the reconciler deletes the synced ResourceQuota before dropping this finalizer.
	// envtest has no GC, so cleanup is explicit.
	gpuQuotaFinalizer = "gpuquotapolicy.platform.lkhun9311.github.io/finalizer"

	// conditionSynced reports whether the namespace ResourceQuota matches the policy.
	conditionSynced     = "Synced"
	reasonQuotaSynced   = "QuotaSynced"
	reasonQuotaConflict = "QuotaConflict"

	// phaseSynced is set once the ResourceQuota matches the policy ceiling.
	// Deterministic enforcement failures (e.g. a name collision with a ResourceQuota this policy does not own) set the shared phaseDegraded;
	// transient API errors are not reflected in status — they are requeued instead, so the phase does not flap on retry.
	phaseSynced = "Synced"

	// gpuRequestsResource is the ResourceQuota key that caps GPU consumption.
	// Extended resources are tracked under requests.<resource>.
	// Locally this caps simulated nvidia.com/gpu capacity.
	gpuRequestsResource = corev1.ResourceName("requests.nvidia.com/gpu")
)

// GPUQuotaPolicyReconciler reconciles a GPUQuotaPolicy object
type GPUQuotaPolicyReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=platform.lkhun9311.github.io,resources=gpuquotapolicies,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=platform.lkhun9311.github.io,resources=gpuquotapolicies/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=platform.lkhun9311.github.io,resources=gpuquotapolicies/finalizers,verbs=update
// +kubebuilder:rbac:groups="",resources=resourcequotas,verbs=get;list;watch;create;update;patch;delete

// Reconcile syncs a namespace ResourceQuota from the GPUQuotaPolicy:
// the GPU ceiling is enforced as a hard requests.nvidia.com/gpu limit, kept in sync against drift, and removed on deletion.
func (r *GPUQuotaPolicyReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := logf.FromContext(ctx)

	var policy platformv1.GPUQuotaPolicy
	if err := r.Get(ctx, req.NamespacedName, &policy); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	rqKey := types.NamespacedName{Name: quotaName(policy.Name), Namespace: policy.Spec.TargetNamespace}

	// Handle deletion: delete the synced ResourceQuota, then drop the finalizer.
	if !policy.DeletionTimestamp.IsZero() {
		if controllerutil.ContainsFinalizer(&policy, gpuQuotaFinalizer) {
			var rq corev1.ResourceQuota
			switch err := r.Get(ctx, rqKey, &rq); {
			case err == nil:
				if err := r.Delete(ctx, &rq); err != nil && !apierrors.IsNotFound(err) {
					return ctrl.Result{}, err
				}
				log.Info("Deleted synced ResourceQuota on deletion", "resourceQuota", rqKey.String())
			case apierrors.IsNotFound(err):
				// already gone
			default:
				return ctrl.Result{}, err
			}
			controllerutil.RemoveFinalizer(&policy, gpuQuotaFinalizer)
			if err := r.Update(ctx, &policy); err != nil {
				return ctrl.Result{}, err
			}
		}
		return ctrl.Result{}, nil
	}

	// Ensure the finalizer is present before creating owned objects.
	if !controllerutil.ContainsFinalizer(&policy, gpuQuotaFinalizer) {
		controllerutil.AddFinalizer(&policy, gpuQuotaFinalizer)
		if err := r.Update(ctx, &policy); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{}, nil
	}

	// Sync the ResourceQuota toward the desired GPU ceiling.
	// NOTE: spec.gpuClass is not yet enforced per class.
	// This milestone caps a single aggregate key (requests.nvidia.com/gpu) regardless of class,
	// so two policies with different gpuClass values targeting one namespace cap the same key (k8s AND-s the quotas, so the strictest wins).
	// Per-class keys depend on how simulated capacity is modeled and are deferred;
	// gpuClass is recorded on the policy but does not scope quota.
	desiredHard := corev1.ResourceList{
		gpuRequestsResource: *resource.NewQuantity(int64(policy.Spec.Limits.GPUCount), resource.DecimalSI),
	}

	var rq corev1.ResourceQuota
	switch err := r.Get(ctx, rqKey, &rq); {
	case apierrors.IsNotFound(err):
		rq = corev1.ResourceQuota{
			ObjectMeta: metav1.ObjectMeta{Name: rqKey.Name, Namespace: rqKey.Namespace},
			Spec:       corev1.ResourceQuotaSpec{Hard: desiredHard},
		}
		if err := controllerutil.SetControllerReference(&policy, &rq, r.Scheme); err != nil {
			return ctrl.Result{}, err
		}
		if err := r.Create(ctx, &rq); err != nil {
			if apierrors.IsAlreadyExists(err) {
				// Lost a race (concurrent reconcile or informer lag): the object now
				// exists, so requeue and reconcile it on the next pass instead of failing.
				return ctrl.Result{RequeueAfter: time.Second}, nil
			}
			return ctrl.Result{}, err
		}
		log.Info("Created ResourceQuota", "resourceQuota", rqKey.String())
	case err != nil:
		return ctrl.Result{}, err
	default:
		// Refuse to hijack a ResourceQuota this policy does not own (name collision with an unrelated object).
		// Overwriting it would clobber someone else's quota, so report Degraded and recheck later instead of taking it over.
		if !metav1.IsControlledBy(&rq, &policy) {
			log.Info("ResourceQuota exists but is not owned by this policy; refusing to overwrite",
				"resourceQuota", rqKey.String())
			return r.markDegraded(ctx, &policy, reasonQuotaConflict,
				fmt.Sprintf("ResourceQuota %s already exists and is not owned by this policy", rqKey.String()))
		}
		if !equality.Semantic.DeepEqual(rq.Spec.Hard, desiredHard) {
			rq.Spec.Hard = desiredHard
			if err := r.Update(ctx, &rq); err != nil {
				return ctrl.Result{}, err
			}
			log.Info("Corrected ResourceQuota drift", "resourceQuota", rqKey.String())
		}
	}

	// Reflect the synced state into status, idempotently.
	desired := policy.Status.DeepCopy()
	desired.ObservedGeneration = policy.Generation
	setQuotaPhase(desired, phaseSynced)
	meta.SetStatusCondition(&desired.Conditions, metav1.Condition{
		Type:               conditionSynced,
		Status:             metav1.ConditionTrue,
		Reason:             reasonQuotaSynced,
		Message:            "ResourceQuota synced from policy",
		ObservedGeneration: policy.Generation,
	})

	if !equality.Semantic.DeepEqual(policy.Status, *desired) {
		policy.Status = *desired
		if err := r.Status().Update(ctx, &policy); err != nil {
			return ctrl.Result{}, err
		}
		log.Info("Updated GPUQuotaPolicy status", "name", policy.Name, "phase", desired.Phase)
	}

	return ctrl.Result{}, nil
}

// quotaName is the deterministic name of the ResourceQuota synced for a policy.
func quotaName(policyName string) string {
	return "gpuquota-" + policyName
}

// markDegraded reflects a deterministic enforcement failure into status as Degraded with a Synced=False condition.
// It returns a RequeueAfter so the policy recovers automatically once the blocking condition clears
// (the Owns watch does not fire for a ResourceQuota we do not own).
func (r *GPUQuotaPolicyReconciler) markDegraded(ctx context.Context, policy *platformv1.GPUQuotaPolicy, reason, msg string) (ctrl.Result, error) {
	desired := policy.Status.DeepCopy()
	desired.ObservedGeneration = policy.Generation
	setQuotaPhase(desired, phaseDegraded)
	meta.SetStatusCondition(&desired.Conditions, metav1.Condition{
		Type:               conditionSynced,
		Status:             metav1.ConditionFalse,
		Reason:             reason,
		Message:            msg,
		ObservedGeneration: policy.Generation,
	})
	if !equality.Semantic.DeepEqual(policy.Status, *desired) {
		policy.Status = *desired
		if err := r.Status().Update(ctx, policy); err != nil {
			return ctrl.Result{}, err
		}
	}
	return ctrl.Result{RequeueAfter: time.Minute}, nil
}

// setQuotaPhase updates the phase and bumps lastTransitionTime only when the phase changes.
func setQuotaPhase(status *platformv1.GPUQuotaPolicyStatus, phase string) {
	if status.Phase == phase {
		return
	}
	status.Phase = phase
	now := metav1.Now()
	status.LastTransitionTime = &now
}

// SetupWithManager sets up the controller with the Manager.
func (r *GPUQuotaPolicyReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&platformv1.GPUQuotaPolicy{}).
		Owns(&corev1.ResourceQuota{}).
		Named("gpuquotapolicy").
		Complete(r)
}
