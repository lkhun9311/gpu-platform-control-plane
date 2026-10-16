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

// InferenceDeploymentSpec defines the desired state of InferenceDeployment.
// +kubebuilder:validation:XValidation:rule="!has(self.admission) || self.admission.mode != 'HoldCap' || has(self.engine)",message="admission.mode HoldCap requires spec.engine: the cap is guaranteed only on an engine this controller renders"
// +kubebuilder:validation:XValidation:rule="!has(self.admission) || has(self.admission.maxHold) == (self.admission.mode == 'HoldCap')",message="admission.maxHold is set exactly when admission.mode is HoldCap"
// +kubebuilder:validation:XValidation:rule="!has(self.admission) || self.admission.mode != 'HoldCap' || self.replicas <= 1",message="admission.mode HoldCap requires replicas at most 1: serial-prefill keys on the Service, so two engines behind it would be serialized as one"
// +kubebuilder:validation:XValidation:rule="!has(self.engine) || self.gpuCount == 1",message="spec.engine requires gpuCount 1: its only profile is one engine on one A10G"
// +kubebuilder:validation:XValidation:rule="!has(self.engine) || self.model.storageUri.matches('^hf://[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$')",message="spec.engine requires model.storageUri of the form hf://<org>/<repo>"
// +kubebuilder:validation:XValidation:rule="!has(self.engine) || self.image.endsWith('@sha256:0a51ea5b4ae2dc5d81890e5173f54203d2a3ae0cfffe51b8fd2afd4391bfd967')",message="spec.engine requires spec.image pinned to the vLLM v0.27.1 digest the profile was measured on, from any registry"
type InferenceDeploymentSpec struct {
	// model is the model to serve.
	// +required
	Model InferenceModel `json:"model"`

	// image is the serving runtime container image (e.g. "vllm/vllm-openai:v0.6.0").
	// +required
	Image string `json:"image"`

	// gpuClass is the illustrative GPU class (e.g. "l40s").
	//
	// Locally this is backed by simulated capacity (see the dev runbook).
	// +optional
	GPUClass string `json:"gpuClass,omitempty"`

	// gpuCount is the number of GPUs (nvidia.com/gpu) per replica.
	//
	// Locally this is backed by simulated capacity, not real hardware.
	// +kubebuilder:validation:Minimum=0
	// +required
	GPUCount int32 `json:"gpuCount"`

	// replicas is the fixed number of serving replicas.
	//
	// Autoscaling lands in M4.
	// +kubebuilder:validation:Minimum=0
	// +required
	Replicas int32 `json:"replicas"`

	// port is the serving container port.
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=65535
	// +kubebuilder:default=8080
	// +optional
	Port int32 `json:"port,omitempty"`

	// engine has the controller render an engine itself instead of the generic serving container.
	// Absent keeps the generic container, unchanged.
	// +optional
	Engine *InferenceEngine `json:"engine,omitempty"`

	// admission selects how the gateway admits requests to this deployment.
	// Absent leaves the gateway's own process-wide mode in charge.
	// +optional
	Admission *InferenceAdmission `json:"admission,omitempty"`
}

// The admission modes an InferenceDeployment can ask for.
const (
	AdmissionModeOff     = "Off"
	AdmissionModeHoldCap = "HoldCap"
)

// ConditionEngineInForce is True when every Pod serving the Service runs a template rendered from spec.engine, for the
// generation in its observedGeneration. The gateway binds a tenant's tier only on such a backend, because every engine
// the controller renders schedules by priority and an engine it did not render may refuse a priority.
const ConditionEngineInForce = "EngineInForce"

// VLLMProfileV0271A10G is the engine configuration the admission study measured, and the only one offered.
const VLLMProfileV0271A10G = "v0.27.1-a10g"

// VLLMV0271Digest is the image digest config/vllm/deployment.yaml pins; the CEL rule on the spec repeats it.
const VLLMV0271Digest = "sha256:0a51ea5b4ae2dc5d81890e5173f54203d2a3ae0cfffe51b8fd2afd4391bfd967"

// VLLMV0271Image is that digest on Docker Hub; a mirror of the same digest is accepted too.
const VLLMV0271Image = "vllm/vllm-openai@" + VLLMV0271Digest

// InferenceEngine selects an engine the controller renders.
type InferenceEngine struct {
	// vllm renders the pinned vLLM profile.
	// +required
	VLLM *VLLMEngine `json:"vllm"`
}

// VLLMEngine is a pinned vLLM configuration.
// It has no free-form arguments: a list would let HoldCap run on an engine the evidence says nothing about.
type VLLMEngine struct {
	// profile is the engine configuration measured on one A10G with Qwen2.5-3B-Instruct; it is the only one offered.
	// +kubebuilder:validation:Enum=v0.27.1-a10g
	// +required
	Profile string `json:"profile"`

	// modelRevision pins the model and tokenizer to a Hub commit, as the admission sessions' engine validator required.
	// +kubebuilder:validation:Pattern=`^[0-9a-f]{40}$`
	// +required
	ModelRevision string `json:"modelRevision"`
}

// InferenceAdmission selects the gateway's admission for this deployment.
// +kubebuilder:validation:XValidation:rule="!has(self.maxHold) || (duration(self.maxHold) >= duration('1s') && duration(self.maxHold) <= duration('25s'))",message="admission.maxHold must lie between 1s and 25s, the longest hold measured"
type InferenceAdmission struct {
	// mode is Off or HoldCap.
	// HoldCap pairs the gateway's serial-prefill admission with the engine's --long-prefill-token-threshold=384.
	// It was measured on one A10G, one engine version, one model (Qwen2.5-3B-Instruct) and one streaming load, in three registered blocks, against no admission.
	// There its premium-tier p99 time to first token was about 0.30 of no admission.
	// A fixed spacing tuned for that load tied with it within the registered 15%, so HoldCap offers protection that needs no tuning, not the lowest tail and not an SLO.
	// It raises standard-tier latency, refuses a standard request held longer than maxHold, and refuses standard requests that do not stream or ask for other than one choice.
	// +kubebuilder:validation:Enum=Off;HoldCap
	// +required
	Mode string `json:"mode"`

	// maxHold is how long a standard request may wait for its turn before it is refused with 429.
	// It has no default: zero would refuse every request that ever had to wait.
	// +optional
	MaxHold *metav1.Duration `json:"maxHold,omitempty"`
}

// InferenceAdmissionStatus is the admission in force, which is not always the admission asked for.
type InferenceAdmissionStatus struct {
	// mode is HoldCap only once a rollout of an engine rendered with the cap has completed; otherwise Off.
	// +kubebuilder:validation:Enum=Off;HoldCap
	// +required
	Mode string `json:"mode"`

	// observedGeneration is the generation this mode was decided for; the gateway trusts it only when it is current.
	// +required
	ObservedGeneration int64 `json:"observedGeneration"`
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

	// admission is the admission in force for this deployment; absent when the spec asks for none.
	// +optional
	Admission *InferenceAdmissionStatus `json:"admission,omitempty"`

	// conditions represent the current state of the InferenceDeployment resource.
	//
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
