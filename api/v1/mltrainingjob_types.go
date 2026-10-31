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
//
// The distributed rules sit on the spec, not on the field, because a rule on an absent optional field is never evaluated.
// +kubebuilder:validation:XValidation:rule="has(self.distributed) == has(oldSelf.distributed) && (!has(self.distributed) || self.distributed == oldSelf.distributed)",message="distributed is fixed at creation, because the world size is built into every rank's environment; delete and recreate the MLTrainingJob to change it"
// +kubebuilder:validation:XValidation:rule="!has(self.distributed) || ((!has(self.parallelism) || self.parallelism == 1) && (!has(self.completions) || self.completions == 1))",message="with distributed set, leave parallelism and completions at 1; the controller runs worldSize Pods"
// +kubebuilder:validation:XValidation:rule="!has(self.distributed) || !has(self.distributed.maxRestarts) || self.distributed.maxRestarts == 0 || has(self.stateVolume)",message="distributed.maxRestarts above 0 needs stateVolume: a restart that cannot read a checkpoint starts from step zero and would be reported as recovery"
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

	// distributed runs the job as worldSize Pods, one training process each, that find each other through the platform.
	//
	// Each Pod gets WORLD_SIZE, RANK, MASTER_ADDR and MASTER_PORT (29500), and rank 0 is reachable at MASTER_ADDR.
	// The command must start exactly one process per Pod: a launcher that starts its own group per Pod, such as
	// torchrun --standalone, would train each Pod alone and still print a result.
	// Any rank failing ends the whole attempt; there is never a per-rank retry, because a replaced rank cannot rejoin a
	// group whose other ranks are mid-step.
	// With maxRestarts above 0 the whole job is started again, every rank together, from what the workload wrote to
	// stateVolume; with 0, the default, the first failure fails the job.
	// Fixed at creation, and it cannot be combined with parallelism or completions other than 1.
	// +optional
	Distributed *Distributed `json:"distributed,omitempty"`
}

// Distributed sizes a job whose ranks run in separate Pods.
//
// A pointer field, so an unset value is absent rather than an empty object every Go caller would send.
type Distributed struct {
	// worldSize is the number of Pods, and so of ranks; rank i runs in the Pod with completion index i.
	//
	// gpuCount stays per Pod, so the queue must admit worldSize times gpuCount.
	// +kubebuilder:validation:Minimum=2
	// +kubebuilder:validation:Maximum=8
	// +required
	WorldSize int32 `json:"worldSize"`

	// maxRestarts is how many times the whole job may be started again after an attempt fails, is evicted, or loses
	// a node; absent or 0 means the first failure fails the job, as before the field existed.
	//
	// A restart starts every rank again from the workload's own checkpoint, so a value above 0 requires stateVolume.
	// The claim must be ReadWriteMany: ranks run on different nodes and all of them read and write it.
	// The bound is deliberate: a fault that recurs on every attempt is not one more restart will cure.
	//
	// The default stores an absent field as 0, because the Go type omits a 0 and the rule fixing distributed compares
	// the stored object with what the controller sends back; without it an explicit 0 refuses every typed update.
	// +kubebuilder:default=0
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=10
	// +optional
	MaxRestarts int32 `json:"maxRestarts,omitempty"`
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

	// runningObservedAt is when this controller first saw the job Running: one ready Pod, or for a
	// distributed job every rank ready or succeeded with at least one still ready.
	//
	// A distributed job used to be stamped on its first ready rank, which for a rank waiting at the
	// rendezvous for a peer with no node is not the start of any work. The field is written once, so a job
	// stamped under that rule before the change keeps its stamp.
	//
	// Named for what it is. Unlike admittedAt it is not a stamp written by the component that acted: it is
	// this controller's observation, and it carries the watch lag between the kubelet starting a Pod and
	// this reconcile seeing it. The two ends of admitToRunningSeconds are therefore read on different
	// clocks, which is the same thing queuelab reports on two clocks and for the same reason.
	//
	// It used to say "an active Pod", and that was the defect, not just the wording: the phase read
	// .status.active, which counts PENDING Pods, so this field was stamped for Pods no node had accepted.
	// It now follows .status.ready, which counts active Pods whose Ready condition is true. That is
	// stricter than "scheduled", so the lag this carries includes readiness as well as the watch -- and a
	// job that finishes without ever being seen ready records no time here at all, with the
	// AdmitToRunningObserved condition saying RunningNotObserved rather than leaving the field silently
	// empty.
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

	// readyRanks is how many of a distributed job's Pods were Ready and not terminating at the last reconcile.
	//
	// A snapshot, not a claim that the group formed: ranks that finish in seconds may never all be Ready at once.
	// Only the workload's own output can say the ranks communicated.
	// Absent for a job without distributed, and for one whose Job has not reported readiness; 0 is written as 0.
	// +optional
	ReadyRanks *int32 `json:"readyRanks,omitempty"`

	// attempts records every start of a distributed job with maxRestarts above 0, oldest first.
	//
	// The first entry is written before the first Job is created, which is also what freezes the fields baked into
	// the Pod template: between two attempts no Job exists, and the presence of an attempt is what still says one ran.
	// Absent for every other job.
	// +listType=atomic
	// +kubebuilder:validation:MaxItems=11
	// +optional
	Attempts []TrainingAttempt `json:"attempts,omitempty"`

	// conditions represent the current state of the MLTrainingJob resource.
	//
	// The status of each condition is one of True, False, or Unknown.
	// +listType=map
	// +listMapKey=type
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// TrainingAttempt is one start of a restartable distributed job: its Job, why it ended, and when each step was seen.
//
// Every time is this controller's observation, written on the reconcile that saw the event, so each carries that
// reconcile's lag. None of them is "training resumed": readiness is not training, and the first optimizer step of an
// attempt is in the workload's own record, which the experiment reads; the controller never writes it.
type TrainingAttempt struct {
	// number counts attempts from 1; attempt n+1 starts only after attempt n is Stopped.
	// +kubebuilder:validation:Minimum=1
	// +required
	Number int32 `json:"number"`

	// state is where the attempt is.
	//
	// Preparing: recorded, its Job not yet seen. Active: its Job exists. Stopping: a trigger was seen and the controller
	// is retiring the Job and waiting for its Pods, its Workload and any unreachable node to be gone. Stopped: all of that
	// is confirmed, and the next attempt may start or the job fails.
	// +kubebuilder:validation:Enum=Preparing;Active;Stopping;Stopped
	// +required
	State string `json:"state"`

	// jobUID is the UID of this attempt's Job, recorded once the controller sees it; deletes are conditioned on it.
	// +optional
	JobUID string `json:"jobUID,omitempty"`

	// workloadName and workloadUID identify this attempt's Kueue Workload; the next attempt waits until it is gone.
	// +optional
	WorkloadName string `json:"workloadName,omitempty"`
	// +optional
	WorkloadUID string `json:"workloadUID,omitempty"`

	// nodes are the nodes this attempt's ranks were seen on.
	//
	// A node that stops answering cannot be shown to have stopped its rank, so the attempt waits for it to be fenced.
	// +listType=set
	// +kubebuilder:validation:MaxItems=8
	// +optional
	Nodes []string `json:"nodes,omitempty"`

	// trigger is why the attempt ended: RankFailed (the Job failed), NodeFault (the platform's GPU fault path
	// handed its Workload over), or JobDeleted (its Job went away while it was running).
	// +kubebuilder:validation:Enum=RankFailed;NodeFault;JobDeleted
	// +optional
	Trigger string `json:"trigger,omitempty"`

	// waitingFor says, while the attempt is Stopping, what it still waits on.
	// +optional
	WaitingFor string `json:"waitingFor,omitempty"`

	// createdAt is when the controller saw this attempt's Job created.
	// +optional
	CreatedAt *metav1.Time `json:"createdAt,omitempty"`

	// allRanksReadyAt is when the controller first saw every rank Ready, the same rule runningObservedAt uses.
	// +optional
	AllRanksReadyAt *metav1.Time `json:"allRanksReadyAt,omitempty"`

	// failureObservedAt is when the controller saw the trigger.
	// +optional
	FailureObservedAt *metav1.Time `json:"failureObservedAt,omitempty"`

	// stopConfirmedAt is when every condition for starting the next attempt was confirmed.
	// +optional
	StopConfirmedAt *metav1.Time `json:"stopConfirmedAt,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Queue",type=string,JSONPath=`.spec.queue`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
// +kubebuilder:printcolumn:name="Ready Ranks",type=integer,JSONPath=`.status.readyRanks`
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
