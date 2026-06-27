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

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/equality"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/utils/ptr"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	logf "sigs.k8s.io/controller-runtime/pkg/log"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// nvidiaGPUResource is the node extended resource a serving pod requests per GPU.
// This is the pod-level resource, distinct from the GPUQuotaPolicy ResourceQuota key.
const nvidiaGPUResource = corev1.ResourceName("nvidia.com/gpu")

const (
	// instanceLabel selects the pods owned by one InferenceDeployment.
	// It is set once and never changed, because a Deployment's selector is immutable.
	instanceLabel = "app.kubernetes.io/instance"
)

// InferenceDeploymentReconciler reconciles an InferenceDeployment object.
type InferenceDeploymentReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=platform.lkhun9311.github.io,resources=inferencedeployments,verbs=get;list;watch
// +kubebuilder:rbac:groups=platform.lkhun9311.github.io,resources=inferencedeployments/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch
// +kubebuilder:rbac:groups="",resources=services,verbs=get;list;watch;create;update;patch

// Reconcile syncs a Deployment and Service from the InferenceDeployment and reflects readiness into status.
func (r *InferenceDeploymentReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := logf.FromContext(ctx)

	var infd platformv1.InferenceDeployment
	if err := r.Get(ctx, req.NamespacedName, &infd); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	dep := &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: infd.Name, Namespace: infd.Namespace}}
	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, dep, func() error {
		r.mutateDeployment(&infd, dep)
		return controllerutil.SetControllerReference(&infd, dep, r.Scheme)
	}); err != nil {
		return ctrl.Result{}, fmt.Errorf("sync deployment %s/%s: %w", infd.Namespace, infd.Name, err)
	}

	svc := &corev1.Service{ObjectMeta: metav1.ObjectMeta{Name: infd.Name, Namespace: infd.Namespace}}
	if _, err := controllerutil.CreateOrUpdate(ctx, r.Client, svc, func() error {
		r.mutateService(&infd, svc)
		return controllerutil.SetControllerReference(&infd, svc, r.Scheme)
	}); err != nil {
		return ctrl.Result{}, fmt.Errorf("sync service %s/%s: %w", infd.Namespace, infd.Name, err)
	}

	log.Info("Synced serving objects", "inferenceDeployment", req.NamespacedName.String())

	phase, cond := computeInfDPhase(&infd, dep)
	desired := infd.Status.DeepCopy()
	desired.Phase = phase
	desired.ReadyReplicas = dep.Status.ReadyReplicas
	desired.ObservedGeneration = infd.Generation
	meta.SetStatusCondition(&desired.Conditions, cond)

	if !equality.Semantic.DeepEqual(infd.Status, *desired) {
		infd.Status = *desired
		if err := r.Status().Update(ctx, &infd); err != nil {
			return ctrl.Result{}, fmt.Errorf("update inferencedeployment status %s/%s: %w", infd.Namespace, infd.Name, err)
		}
		log.Info("Updated InferenceDeployment status", "name", infd.Name, "phase", phase)
	}
	return ctrl.Result{}, nil
}

// servingPort returns the configured serving port, defaulting to 8080 when unset.
func servingPort(infd *platformv1.InferenceDeployment) int32 {
	if infd.Spec.Port == 0 {
		return 8080
	}
	return infd.Spec.Port
}

// infdLabels is the recommended label set applied to the owned Deployment and Service.
func infdLabels(infd *platformv1.InferenceDeployment) map[string]string {
	return map[string]string{
		"app.kubernetes.io/name":              "inferencedeployment",
		instanceLabel:                         infd.Name,
		"app.kubernetes.io/managed-by":        "gpu-platform-control-plane",
		"platform.lkhun9311.github.io/tenant": infd.Namespace,
	}
}

// mutateDeployment sets only the fields this controller manages on the Deployment.
// The selector is set once and never changed, because it is immutable after create.
func (r *InferenceDeploymentReconciler) mutateDeployment(infd *platformv1.InferenceDeployment, dep *appsv1.Deployment) {
	labels := infdLabels(infd)
	port := servingPort(infd)

	dep.Labels = labels
	dep.Spec.Replicas = ptr.To(infd.Spec.Replicas)
	dep.Spec.ProgressDeadlineSeconds = ptr.To(int32(600))
	if dep.Spec.Selector == nil {
		dep.Spec.Selector = &metav1.LabelSelector{MatchLabels: map[string]string{instanceLabel: infd.Name}}
	}
	dep.Spec.Template.ObjectMeta.Labels = labels

	container := corev1.Container{
		Name:  "server",
		Image: infd.Spec.Image,
		Args:  []string{"--model", infd.Spec.Model.Name, "--model-path", infd.Spec.Model.StorageURI},
		Ports: []corev1.ContainerPort{{Name: "http", ContainerPort: port}},
		ReadinessProbe: &corev1.Probe{ProbeHandler: corev1.ProbeHandler{
			HTTPGet: &corev1.HTTPGetAction{Path: "/health", Port: intstr.FromString("http")},
		}},
		LivenessProbe: &corev1.Probe{ProbeHandler: corev1.ProbeHandler{
			HTTPGet: &corev1.HTTPGetAction{Path: "/health", Port: intstr.FromString("http")},
		}},
	}
	if infd.Spec.GPUCount > 0 {
		q := *resource.NewQuantity(int64(infd.Spec.GPUCount), resource.DecimalSI)
		container.Resources = corev1.ResourceRequirements{
			Requests: corev1.ResourceList{nvidiaGPUResource: q},
			Limits:   corev1.ResourceList{nvidiaGPUResource: q},
		}
	}
	dep.Spec.Template.Spec.Containers = []corev1.Container{container}
}

// mutateService sets only the fields this controller manages on the Service.
func (r *InferenceDeploymentReconciler) mutateService(infd *platformv1.InferenceDeployment, svc *corev1.Service) {
	port := servingPort(infd)
	svc.Labels = infdLabels(infd)
	svc.Spec.Type = corev1.ServiceTypeClusterIP
	svc.Spec.Selector = map[string]string{instanceLabel: infd.Name}
	svc.Spec.Ports = []corev1.ServicePort{{
		Name:       "http",
		Port:       port,
		TargetPort: intstr.FromString("http"),
	}}
}

const (
	infdPhasePending     = "Pending"
	infdPhaseProgressing = "Progressing"
	infdPhaseReady       = "Ready"
	infdPhaseDegraded    = "Degraded"

	infdCondAvailable    = "Available"
	infdReasonScaledZero = "ScaledToZero"
	infdReasonRollout    = "RolloutInProgress"
	infdReasonAvailable  = "MinimumReplicasAvailable"
)

// computeInfDPhase derives the phase and the Available condition from the Deployment status.
// The Deployment status is only trusted once its observedGeneration has caught up to its generation.
func computeInfDPhase(infd *platformv1.InferenceDeployment, dep *appsv1.Deployment) (string, metav1.Condition) {
	avail := func(status metav1.ConditionStatus, reason, msg string) metav1.Condition {
		return metav1.Condition{Type: infdCondAvailable, Status: status, Reason: reason, Message: msg, ObservedGeneration: infd.Generation}
	}
	if infd.Spec.Replicas == 0 {
		return infdPhaseReady, avail(metav1.ConditionTrue, infdReasonScaledZero, "scaled to zero replicas")
	}
	if dep.Status.ObservedGeneration < dep.Generation {
		return infdPhaseProgressing, avail(metav1.ConditionFalse, infdReasonRollout, "deployment not yet observed")
	}
	if dep.Status.ReadyReplicas == 0 {
		return infdPhasePending, avail(metav1.ConditionFalse, infdReasonRollout, "no replicas ready yet")
	}
	if dep.Status.UpdatedReplicas < infd.Spec.Replicas || dep.Status.ReadyReplicas < infd.Spec.Replicas {
		return infdPhaseProgressing, avail(metav1.ConditionFalse, infdReasonRollout, "rollout in progress")
	}
	return infdPhaseReady, avail(metav1.ConditionTrue, infdReasonAvailable, "all replicas ready")
}

// SetupWithManager sets up the controller with the Manager.
func (r *InferenceDeploymentReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&platformv1.InferenceDeployment{}).
		Owns(&appsv1.Deployment{}).
		Owns(&corev1.Service{}).
		Named("inferencedeployment").
		Complete(r)
}
