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
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// EDIT THIS FILE!
//
// THIS IS SCAFFOLDING FOR YOU TO OWN!
//
// NOTE: json tags are required.
//
// Any new fields you add must have json tags for the fields to be serialized.

// GPUQuotaPolicySpec defines the desired state of GPUQuotaPolicy.
//
// The trainingQuota rule sits here rather than on the field because the field is omitempty: false is never stored, and a rule on an absent field is not evaluated, so false-to-true would pass unchecked.
// +kubebuilder:validation:XValidation:rule="(has(self.trainingQuota) && self.trainingQuota) == (has(oldSelf.trainingQuota) && oldSelf.trainingQuota)",message="trainingQuota is immutable: delete the policy, drain the namespace's GPU workloads, and create it again in the other mode"
type GPUQuotaPolicySpec struct {
	// tenant is the logical tenant (team/org) this policy applies to.
	//
	// It is distinct from targetNamespace, but the platform supports one policy per tenant, not a tenant across namespaces.
	// A second training policy for the same tenant is Degraded, because the cluster-scoped gpu-<tenant> ClusterQueue already belongs to the first.
	// The gateway rate-limits and routes a tenant by its oldest policy alone, so models in another policy's namespace are unreachable under that tenant.
	//
	// It is immutable, for the reason targetNamespace is: the Kueue queues are named after the tenant, so changing it created gpu-<new> queues beside the gpu-<old> ones.
	// The old queues kept their nominal quota and stayed owned by the policy, which still exists, so nothing removed them and the tenant held two reservations.
	// To rename a tenant, delete the policy and create it again.
	// +required
	// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="tenant is immutable"
	Tenant string `json:"tenant"`

	// targetNamespace is the namespace into which quota objects are synced.
	//
	// It is immutable: a policy enforces quota in exactly one namespace for its lifetime.
	//
	// Changing it would orphan the ResourceQuota already synced into the old namespace (the reconciler only ever reconciles the namespace named here), so migration is done by deleting and recreating the policy rather than mutating this field.
	// +required
	// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="targetNamespace is immutable"
	TargetNamespace string `json:"targetNamespace"`

	// gpuClass records the GPU class (e.g. "l40s") this policy is intended for.
	//
	// Empty means all classes.
	//
	// NOTE: per-class quota scoping is not yet enforced.
	//
	// This milestone caps a single aggregate ceiling (requests.nvidia.com/gpu) regardless of class; the field is recorded for a later milestone that will enforce per-class resource keys (see the gpuClass note in the reconciler).
	// +optional
	GPUClass string `json:"gpuClass,omitempty"`

	// limits is the quota ceiling for this tenant in the target namespace.
	// +required
	Limits GPUQuotaLimits `json:"limits"`

	// rateLimit caps the per-tenant serving request rate enforced at the gateway (admission Layer 4).
	//
	// It is optional: a policy without rateLimit means the tenant has no gateway rate limit.
	// +optional
	RateLimit *GPUQuotaRateLimit `json:"rateLimit,omitempty"`

	// trainingQuota, when true, also publishes this tenant's GPU ceiling as a Kueue ClusterQueue for training admission.
	//
	// Training GPU quota then lives in Kueue rather than the namespace ResourceQuota, so the same GPUs are not counted twice.
	//
	// It is immutable, for the reason targetNamespace is: changing it in place moved the ceiling from one ledger to the other in a single reconcile, and GPU Pods already running under the namespace ResourceQuota stayed running with Kueue never counting them.
	//
	// To change it, delete the policy, let the namespace's GPU workloads finish or be removed, and create the policy again in the other mode.
	// Creating a policy over a namespace that still runs GPU Pods is not checked, so the drain is the operator's step.
	// +optional
	TrainingQuota bool `json:"trainingQuota,omitempty"`
}

// GPUQuotaRateLimit is the per-tenant token-bucket configuration consumed by the serving gateway.
type GPUQuotaRateLimit struct {
	// requestsPerMinute is the sustained request rate allowed for the tenant.
	// +kubebuilder:validation:Minimum=1
	RequestsPerMinute int32 `json:"requestsPerMinute"`

	// burst is the maximum momentary burst the bucket allows above the sustained rate.
	// +kubebuilder:validation:Minimum=1
	Burst int32 `json:"burst"`
}

// GPUQuotaLimits is the quota ceiling for a tenant.
type GPUQuotaLimits struct {
	// gpuCount is the maximum number of GPUs (nvidia.com/gpu) allowed.
	//
	// Locally this is backed by simulated capacity, not real hardware.
	// +kubebuilder:validation:Minimum=0
	// +required
	GPUCount int32 `json:"gpuCount"`
}

// GPUQuotaPolicyStatus defines the observed state of GPUQuotaPolicy.
type GPUQuotaPolicyStatus struct {
	// phase is the high-level sync state of the policy.
	// +kubebuilder:validation:Enum=Pending;Synced;Degraded
	// +optional
	Phase string `json:"phase,omitempty"`

	// observedGeneration is the most recent generation observed by the controller.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`

	// lastTransitionTime is the time the phase last changed.
	// +optional
	LastTransitionTime *metav1.Time `json:"lastTransitionTime,omitempty"`

	// conditions represent the current state of the GPUQuotaPolicy resource.
	//
	// The status of each condition is one of True, False, or Unknown.
	// +listType=map
	// +listMapKey=type
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Cluster
// +kubebuilder:printcolumn:name="Tenant",type=string,JSONPath=`.spec.tenant`
// +kubebuilder:printcolumn:name="Namespace",type=string,JSONPath=`.spec.targetNamespace`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

// GPUQuotaPolicy is the Schema for the gpuquotapolicies API
type GPUQuotaPolicy struct {
	metav1.TypeMeta `json:",inline"`

	// metadata is a standard object metadata
	// +optional
	metav1.ObjectMeta `json:"metadata,omitzero"`

	// spec defines the desired state of GPUQuotaPolicy
	// +required
	Spec GPUQuotaPolicySpec `json:"spec"`

	// status defines the observed state of GPUQuotaPolicy
	// +optional
	Status GPUQuotaPolicyStatus `json:"status,omitzero"`
}

// +kubebuilder:object:root=true

// GPUQuotaPolicyList contains a list of GPUQuotaPolicy
type GPUQuotaPolicyList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitzero"`
	Items           []GPUQuotaPolicy `json:"items"`
}

func init() {
	SchemeBuilder.Register(&GPUQuotaPolicy{}, &GPUQuotaPolicyList{})
}
