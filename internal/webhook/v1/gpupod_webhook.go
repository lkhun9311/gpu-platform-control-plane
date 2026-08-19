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

package v1

import (
	"context"
	"fmt"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"
)

// gpuResource is the extended resource a Pod asks for when it wants a device.
const gpuResource = corev1.ResourceName("nvidia.com/gpu")

// kueueQueueLabel is the label Kueue reads to decide which LocalQueue a workload belongs to.
//
// Duplicated from internal/controller rather than imported, because a webhook importing the controller
// package to read one string would drag the whole reconciler into the admission binary's dependency graph.
const kueueQueueLabel = "kueue.x-k8s.io/queue-name"

// QuotaExemptAnnotation marks a Pod that may hold a device outside the tenant quota.
//
// It exists because some Pods legitimately need a device and cannot go through the queue: a device plugin
// DaemonSet, and — in this cluster's current configuration — the serving path, since Kueue's `pod` and
// `deployment` integrations are not enabled and a serving Pod is therefore invisible to it.
//
// It is an annotation someone has to write, not a silent hole. A guard whose exceptions are implicit is a
// guard nobody can audit: this way `kubectl get pods -o json | grep quota-exempt` enumerates every device
// this platform is not accounting for.
const QuotaExemptAnnotation = "platform.lkhun9311.github.io/quota-exempt"

// +kubebuilder:webhook:path=/validate--v1-pod,mutating=false,failurePolicy=fail,sideEffects=None,groups="",resources=pods,verbs=create,versions=v1,name=vgpupod.kb.io,admissionReviewVersions=v1

// GPUPodValidator refuses a Pod that would take a GPU without passing through the tenant's quota.
//
// The hole it closes is the platform's largest. When a GPUQuotaPolicy sets trainingQuota, the controller
// deliberately stops the namespace ResourceQuota from capping GPUs and makes the Kueue ClusterQueue the
// single authority — because otherwise the same GPU is charged twice and half the tenant's budget becomes
// unusable. But Kueue only sees what enters its queues. A Pod created directly, with a device request and no
// queue, is admitted by nobody and counted by nobody.
//
// That was not theoretical. On this cluster a bare Pod requesting two GPUs in a governed namespace was
// created, scheduled and Running, with no Kueue Workload anywhere. "Multi-tenant GPU quota" was a convention
// the platform's own controller followed, not a boundary it enforced.
type GPUPodValidator struct {
	// Reader is uncached, for the reason MLTrainingJobValidator's is: this validator reads the Job a Pod was
	// just created by, and an informer that has not caught up answers NotFound — which is indistinguishable
	// from the Job not existing and would let the Pod through.
	Reader client.Reader
}

var _ admission.Validator[*corev1.Pod] = &GPUPodValidator{}

// podGroupKind names the kind in the errors this validator returns.
var podGroupKind = schema.GroupKind{Group: "", Kind: "Pod"}

// SetupGPUPodWebhookWithManager registers the validator with the manager's webhook server.
func SetupGPUPodWebhookWithManager(mgr ctrl.Manager) error {
	return ctrl.NewWebhookManagedBy(mgr, &corev1.Pod{}).
		WithValidator(&GPUPodValidator{Reader: mgr.GetAPIReader()}).
		Complete()
}

// ValidateCreate refuses a device request that is not accounted for.
func (v *GPUPodValidator) ValidateCreate(ctx context.Context, pod *corev1.Pod) (admission.Warnings, error) {
	if gpuRequest(pod) == 0 {
		return nil, nil
	}
	if _, exempt := pod.Annotations[QuotaExemptAnnotation]; exempt {
		// Recorded as a warning so the exemption is visible at the moment it is used rather than only to
		// someone who thinks to go looking for the annotation.
		return admission.Warnings{fmt.Sprintf(
			"this Pod holds %d %s outside the tenant quota, by %s",
			gpuRequest(pod), gpuResource, QuotaExemptAnnotation)}, nil
	}

	queued, err := v.tracesToAQueue(ctx, pod)
	if err != nil {
		// Fail closed, for the same reason the webhook's failurePolicy is Fail: a guard that stops applying
		// whenever a read fails admits exactly what it exists to refuse, and does so invisibly.
		return nil, fmt.Errorf("establish whether pod %s/%s passes through a queue: %w",
			pod.Namespace, pod.Name, err)
	}
	if queued {
		return nil, nil
	}
	return nil, apierrors.NewForbidden(
		schema.GroupResource{Group: podGroupKind.Group, Resource: "pods"}, pod.Name,
		fmt.Errorf("this namespace's GPU budget is held by a Kueue ClusterQueue, and this Pod asks for %d %s "+
			"without belonging to a queue, so nothing would charge it: submit an MLTrainingJob, or label the "+
			"owning Job %s=<queue>, or annotate the Pod %s to take the device outside the budget on purpose",
			gpuRequest(pod), gpuResource, kueueQueueLabel, QuotaExemptAnnotation))
}

// ValidateUpdate and ValidateDelete admit everything.
//
// A Pod's resource requests are immutable, so an update cannot introduce a device request that CREATE did not
// already see; and refusing a delete could strand a Pod nobody can remove, which is worse than anything this
// guard prevents.
func (v *GPUPodValidator) ValidateUpdate(context.Context, *corev1.Pod, *corev1.Pod) (admission.Warnings, error) {
	return nil, nil
}

func (v *GPUPodValidator) ValidateDelete(context.Context, *corev1.Pod) (admission.Warnings, error) {
	return nil, nil
}

// tracesToAQueue reports whether this Pod reaches Kueue's accounting through its controller.
//
// The label is looked for on the OWNER rather than on the Pod, and that is not a detail. BuildJob puts the
// queue label on the Job's own metadata; Pods are created by the Job controller from spec.template, which
// carries no such label. A guard reading the Pod alone would refuse every legitimate training Pod this
// platform creates.
//
// Only a batch/v1 Job owner is accepted, because in this cluster that is the only shape Kueue governs: its
// `pod` and `deployment` integrations are not among the enabled frameworks, so a Pod owned by a ReplicaSet is
// invisible to Kueue however it is labelled. Admitting it on a label Kueue never reads would be a guard that
// checks a string rather than a fact.
func (v *GPUPodValidator) tracesToAQueue(ctx context.Context, pod *corev1.Pod) (bool, error) {
	owner := metav1.GetControllerOf(pod)
	if owner == nil {
		return false, nil
	}
	if owner.Kind != "Job" || owner.APIVersion != batchv1.SchemeGroupVersion.String() {
		return false, nil
	}
	var job batchv1.Job
	err := v.Reader.Get(ctx, client.ObjectKey{Name: owner.Name, Namespace: pod.Namespace}, &job)
	switch {
	case apierrors.IsNotFound(err):
		// The Pod names an owner that does not exist. Refusing is the safe reading: the alternative is
		// trusting an ownerReference anyone can write to describe a Job nobody can check.
		return false, nil
	case err != nil:
		return false, err
	}
	return job.Labels[kueueQueueLabel] != "", nil
}

// gpuRequest is how many devices this Pod would hold.
//
// Limits rather than requests, because an extended resource's request is defaulted from its limit and a Pod
// may set only the limit — which is exactly what BuildJob does.
func gpuRequest(pod *corev1.Pod) int64 {
	var total int64
	for _, c := range append(append([]corev1.Container{}, pod.Spec.InitContainers...), pod.Spec.Containers...) {
		if q, ok := c.Resources.Limits[gpuResource]; ok {
			total += q.Value()
			continue
		}
		if q, ok := c.Resources.Requests[gpuResource]; ok {
			total += q.Value()
		}
	}
	return total
}
