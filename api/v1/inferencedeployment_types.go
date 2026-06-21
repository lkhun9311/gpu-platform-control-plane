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

// InferenceDeploymentSpec defines the desired state of InferenceDeployment.
type InferenceDeploymentSpec struct {
	// model is the model to serve.
	// +required
	Model InferenceModel `json:"model"`

	// image is the serving runtime container image (e.g. "vllm/vllm-openai:v0.6.0").
	// +required
	Image string `json:"image"`

	// gpuClass is the illustrative GPU class (e.g. "l40s").
	// Locally this is backed by simulated capacity (see the dev runbook).
	// +optional
	GPUClass string `json:"gpuClass,omitempty"`

	// gpuCount is the number of GPUs (nvidia.com/gpu) per replica.
	// Locally this is backed by simulated capacity, not real hardware.
	// +kubebuilder:validation:Minimum=0
	// +required
	GPUCount int32 `json:"gpuCount"`

	// replicas is the fixed number of serving replicas. Autoscaling lands in M4.
	// +kubebuilder:validation:Minimum=0
	// +required
	Replicas int32 `json:"replicas"`

	// port is the serving container port.
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=65535
	// +kubebuilder:default=8080
	// +optional
	Port int32 `json:"port,omitempty"`
}

// InferenceModel identifies the model to serve.
type InferenceModel struct {
	// name is the logical model name.
	// +required
	Name string `json:"name"`

	// storageUri is where the model weights live (e.g. "s3://bucket/model", "pvc://claim/path").
	// +required
	StorageURI string `json:"storageUri"`
}

// InferenceDeploymentStatus defines the observed state of InferenceDeployment.
type InferenceDeploymentStatus struct {
	// phase is the high-level serving state.
	// +kubebuilder:validation:Enum=Pending;Progressing;Ready;Degraded
	// +optional
	Phase string `json:"phase,omitempty"`

	// observedGeneration is the most recent generation observed by the controller.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`

	// readyReplicas is the observed number of ready serving replicas (populated in M4).
	// +optional
	ReadyReplicas int32 `json:"readyReplicas,omitempty"`

	// lastTransitionTime is the time the phase last changed.
	// +optional
	LastTransitionTime *metav1.Time `json:"lastTransitionTime,omitempty"`

	// conditions represent the current state of the InferenceDeployment resource.
	// The status of each condition is one of True, False, or Unknown.
	// +listType=map
	// +listMapKey=type
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Model",type=string,JSONPath=`.spec.model.name`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
// +kubebuilder:printcolumn:name="Ready",type=integer,JSONPath=`.status.readyReplicas`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

// InferenceDeployment is the Schema for the inferencedeployments API
type InferenceDeployment struct {
	metav1.TypeMeta `json:",inline"`

	// metadata is a standard object metadata
	// +optional
	metav1.ObjectMeta `json:"metadata,omitzero"`

	// spec defines the desired state of InferenceDeployment
	// +required
	Spec InferenceDeploymentSpec `json:"spec"`

	// status defines the observed state of InferenceDeployment
	// +optional
	Status InferenceDeploymentStatus `json:"status,omitzero"`
}

// +kubebuilder:object:root=true

// InferenceDeploymentList contains a list of InferenceDeployment
type InferenceDeploymentList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitzero"`
	Items           []InferenceDeployment `json:"items"`
}

func init() {
	SchemeBuilder.Register(&InferenceDeployment{}, &InferenceDeploymentList{})
}
