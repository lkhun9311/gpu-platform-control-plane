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

// MLTrainingJobSpec defines the desired state of MLTrainingJob.
type MLTrainingJobSpec struct {
	// queue is the Kueue LocalQueue name (same namespace) this job is admitted through.
	// +required
	Queue string `json:"queue"`

	// image is the training container image.
	// +required
	Image string `json:"image"`

	// command overrides the container entrypoint.
	// +optional
	Command []string `json:"command,omitempty"`

	// gpuClass is the illustrative GPU class (e.g. "l40s").
	//
	// Locally this is backed by simulated capacity (see the dev runbook).
	// +optional
	GPUClass string `json:"gpuClass,omitempty"`

	// gpuCount is the number of GPUs (nvidia.com/gpu) per pod.
	//
	// Locally this is backed by simulated capacity, not real hardware.
	// +kubebuilder:validation:Minimum=0
	// +required
	GPUCount int32 `json:"gpuCount"`

	// parallelism is the batch/v1 Job parallelism (concurrent pods).
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:default=1
	// +optional
	Parallelism int32 `json:"parallelism,omitempty"`

	// completions is the batch/v1 Job completions (successful pods required).
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:default=1
	// +optional
	Completions int32 `json:"completions,omitempty"`

	// stateVolume mounts storage that outlives the Pod, so a replacement can read what its predecessor wrote.
	//
	// Absent means every Pod starts from nothing, which is what every job in this repository did before the
	// field existed and what all of them still do unless they ask otherwise.
	// +optional
	StateVolume *StateVolume `json:"stateVolume,omitempty"`
}

// StateVolume attaches an EXISTING PersistentVolumeClaim to the trainer container.
//
// It references a claim rather than describing one to provision, and that is a deliberate refusal rather
// than a smaller feature. Provisioning would put a storageClassName into this API, and the only binding
// behaviour anything here has measured is the development cluster's local-path provisioner with
// WaitForFirstConsumer -- which happens to solve node affinity by binding the volume wherever the first
// consumer lands. That is a fact about kind, not about a GPU cluster, and no provisioner for one is recorded
// anywhere in this tree. Naming a claim someone else created keeps the decision where the evidence is.
//
// Nothing here creates, resizes or deletes the claim. A missing one leaves the Pod Pending, which is the
// loud failure; silently falling back to an emptyDir would give a resuming workload a volume that dies with
// its Pod and report the resume as having worked.
type StateVolume struct {
	// claimName is a PersistentVolumeClaim that already exists in the job's own namespace.
	// +kubebuilder:validation:MinLength=1
	// +required
	ClaimName string `json:"claimName"`

	// mountPath is where the claim appears inside the trainer container.
	// +kubebuilder:validation:Pattern=`^/`
	// +required
	MountPath string `json:"mountPath"`
}

// MLTrainingJobStatus defines the observed state of MLTrainingJob.
type MLTrainingJobStatus struct {
	// phase tracks the Kueue admission and run lifecycle.
	// +kubebuilder:validation:Enum=Pending;Admitted;Running;Succeeded;Failed
	// +optional
	Phase string `json:"phase,omitempty"`

	// observedGeneration is the most recent generation observed by the controller.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`

	// lastTransitionTime is the time the phase last changed.
	// +optional
	LastTransitionTime *metav1.Time `json:"lastTransitionTime,omitempty"`

	// admittedAt is when Kueue admitted this job's Workload, taken from Kueue's own condition stamp.
	//
	// It is recorded ONLY on a reconcile that saw this job admitted and not yet running. A controller that
	// was down across the whole admission-to-running window can still read Kueue's stamp afterwards, and
	// using it then would report a duration nobody watched -- which is the defect queuelab's ledger exists
	// to refuse. So the field's presence means the window was observed, not merely that admission happened.
	// +optional
	AdmittedAt *metav1.Time `json:"admittedAt,omitempty"`

	// runningObservedAt is when this controller first saw the Job report an active Pod.
	//
	// Named for what it is. Unlike admittedAt it is not a stamp written by the component that acted: it is
	// this controller's observation, and it carries the watch lag between the kubelet starting a Pod and
	// this reconcile seeing it. The two ends of admitToRunningSeconds are therefore read on different
	// clocks, which is the same thing queuelab reports on two clocks and for the same reason.
	// +optional
	RunningObservedAt *metav1.Time `json:"runningObservedAt,omitempty"`

	// admitToRunningSeconds is how long the tenant waited between having quota and using it.
	//
	// This is the quantity a quota owner cares about and the platform has never reported. The queuelab
	// measured it under preemption -- 2.180 s when the preempted borrower honoured SIGTERM and 31.213 s when
	// it did not -- and the admission webhook caps terminationGracePeriodSeconds because of that. Capping
	// the worst case without reporting the actual one leaves the tenant who paid it unable to see the bill.
	//
	// A string so the value round-trips through YAML exactly, the same reason RunManifest.matchTolerance is
	// one. Empty when the window was not observed, in which case the AdmitToRunningObserved condition says
	// why -- absent and zero must not look alike.
	// +optional
	AdmitToRunningSeconds string `json:"admitToRunningSeconds,omitempty"`

	// conditions represent the current state of the MLTrainingJob resource.
	//
	// The status of each condition is one of True, False, or Unknown.
	// +listType=map
	// +listMapKey=type
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Queue",type=string,JSONPath=`.spec.queue`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

// MLTrainingJob is the Schema for the mltrainingjobs API
type MLTrainingJob struct {
	metav1.TypeMeta `json:",inline"`

	// metadata is a standard object metadata
	// +optional
	metav1.ObjectMeta `json:"metadata,omitzero"`

	// spec defines the desired state of MLTrainingJob
	// +required
	Spec MLTrainingJobSpec `json:"spec"`

	// status defines the observed state of MLTrainingJob
	// +optional
	Status MLTrainingJobStatus `json:"status,omitzero"`
}

// +kubebuilder:object:root=true

// MLTrainingJobList contains a list of MLTrainingJob
type MLTrainingJobList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitzero"`
	Items           []MLTrainingJob `json:"items"`
}

func init() {
	SchemeBuilder.Register(&MLTrainingJob{}, &MLTrainingJobList{})
}
