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

// EDIT THIS FILE!  THIS IS SCAFFOLDING FOR YOU TO OWN!
// NOTE: json tags are required.  Any new fields you add must have json tags for the fields to be serialized.

// GPUQuotaPolicySpec defines the desired state of GPUQuotaPolicy.
type GPUQuotaPolicySpec struct {
	// tenant is the logical tenant (team/org) this policy applies to.
	// A tenant may own multiple namespaces, so this is distinct from targetNamespace.
	// +required
	Tenant string `json:"tenant"`

	// targetNamespace is the namespace into which quota objects are synced.
	// +required
	TargetNamespace string `json:"targetNamespace"`

	// gpuClass scopes the quota to a GPU class (e.g. "l40s"). Empty means all classes.
	// Locally this is backed by simulated capacity (see the dev runbook).
	// +optional
	GPUClass string `json:"gpuClass,omitempty"`

	// limits is the quota ceiling for this tenant in the target namespace.
	// +required
	Limits GPUQuotaLimits `json:"limits"`
}

// GPUQuotaLimits is the quota ceiling for a tenant.
type GPUQuotaLimits struct {
	// gpuCount is the maximum number of GPUs (nvidia.com/gpu) allowed.
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
