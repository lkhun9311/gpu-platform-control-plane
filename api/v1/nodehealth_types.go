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

// NodeHealthSpec defines the desired state of NodeHealth.
type NodeHealthSpec struct {
	// nodeName is the name of the target Node object this resource tracks.
	// It is immutable: a NodeHealth manages the unhealthy taint on exactly one node for its lifetime.
	// Changing it would orphan the taint already applied to the old node, since cleanup only ever targets the node named here.
	// +required
	// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="nodeName is immutable"
	NodeName string `json:"nodeName"`

	// gpuClass is the illustrative GPU class of the node (e.g. "l40s").
	// Locally this is backed by simulated capacity (see the dev runbook).
	// +optional
	GPUClass string `json:"gpuClass,omitempty"`
}

// NodeHealthStatus defines the observed state of NodeHealth.
type NodeHealthStatus struct {
	// phase is the high-level health state of the node.
	// M3 emits Pending, Ready, and Quarantine.
	// Intake and Degraded are reserved for the node intake and degrade lifecycle stages (see docs/03) and are not emitted yet.
	// +kubebuilder:validation:Enum=Pending;Intake;Ready;Degraded;Quarantine
	// +optional
	Phase string `json:"phase,omitempty"`

	// observedGeneration is the most recent generation observed by the controller.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`

	// faultSignal records the origin of the current fault signal. It is recorded
	// for honesty: locally the signal is simulated, not a real hardware signal.
	// +optional
	FaultSignal *FaultSignal `json:"faultSignal,omitempty"`

	// lastTransitionTime is the time the phase last changed.
	// +optional
	LastTransitionTime *metav1.Time `json:"lastTransitionTime,omitempty"`

	// conditions represent the current state of the NodeHealth resource.
	// The status of each condition is one of True, False, or Unknown.
	// +listType=map
	// +listMapKey=type
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// FaultSignal records where a node fault signal originated.
type FaultSignal struct {
	// source is the origin of the signal (e.g. "simulated").
	// +optional
	Source string `json:"source,omitempty"`

	// code is an optional fault code.
	// +optional
	Code string `json:"code,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Cluster
// +kubebuilder:printcolumn:name="Node",type=string,JSONPath=`.spec.nodeName`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

// NodeHealth is the Schema for the nodehealths API
type NodeHealth struct {
	metav1.TypeMeta `json:",inline"`

	// metadata is a standard object metadata
	// +optional
	metav1.ObjectMeta `json:"metadata,omitzero"`

	// spec defines the desired state of NodeHealth
	// +required
	Spec NodeHealthSpec `json:"spec"`

	// status defines the observed state of NodeHealth
	// +optional
	Status NodeHealthStatus `json:"status,omitzero"`
}

// +kubebuilder:object:root=true

// NodeHealthList contains a list of NodeHealth
type NodeHealthList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitzero"`
	Items           []NodeHealth `json:"items"`
}

func init() {
	SchemeBuilder.Register(&NodeHealth{}, &NodeHealthList{})
}
