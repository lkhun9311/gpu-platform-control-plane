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

// GpuSharingBenchmarkSpec declares one A/B contention experiment.
//
// The design of record is docs/superpowers/specs/2026-07-04-gpusharingbenchmark-crd-design.md, and the field
// names, units and validation rules here follow it rather than restating it.
//
// The spec carries the protocol, not just the parameters. Several of the rules below exist because a
// plausible-looking run that breaks them produces a tail-latency number that is wrong in a direction nobody
// notices: retries repair the tail, a closed-loop client hides the queueing delay it is meant to measure, and
// a p99 from too few requests or too few repetitions is noise wearing a decimal point.
type GpuSharingBenchmarkSpec struct {
	// gpuClass is the GPU class the experiment runs on (e.g. "a10g").
	//
	// Spelled as in the rest of api/v1, so one vocabulary covers quota, serving and this.
	// +required
	GPUClass string `json:"gpuClass"`

	// sharingMode is the topology under test.
	//
	// sharedInstance means both tenants reach ONE vLLM instance through the gateway, so the contention is in
	// a shared KV-cache pool and the vLLM waiting queue. timeSlicing and mps put separate pods on one GPU,
	// where the contention is GPU time and the KV caches are separate. They answer different questions and
	// their numbers are not comparable, which is why the mode is part of the experiment's identity below.
	// +kubebuilder:validation:Enum=exclusive;timeSlicing;mps;sharedInstance
	// +required
	SharingMode string `json:"sharingMode"`

	// baseline is the latency-sensitive victim whose p99 the experiment reports.
	// +required
	Baseline BenchmarkWorkload `json:"baseline"`

	// contender is the noisy neighbour placed alongside the baseline.
	// +required
	Contender BenchmarkWorkload `json:"contender"`

	// repetitions is how many times each condition is run.
	//
	// At least five: a p99 from three repetitions is noise, and the report is a median-of-runs with a
	// bootstrap interval rather than a best run.
	// +kubebuilder:validation:Minimum=5
	// +required
	Repetitions int32 `json:"repetitions"`

	// warmupRequests are sent before measurement starts and are not counted.
	// +kubebuilder:validation:Minimum=0
	// +optional
	WarmupRequests int32 `json:"warmupRequests,omitempty"`

	// minRequestsPerRun is the sample-size floor for the victim tenant in one run.
	//
	// A p99 needs the tail populated; below a thousand requests the figure is decided by a handful of
	// samples.
	// +kubebuilder:validation:Minimum=1000
	// +required
	MinRequestsPerRun int32 `json:"minRequestsPerRun"`

	// load is the arrival protocol every run obeys.
	// +required
	Load LoadSpec `json:"load"`
}

// BenchmarkWorkload is one side of the experiment.
type BenchmarkWorkload struct {
	// tenant must resolve through the identity chain: a GPUQuotaPolicy with this spec.tenant, and an entry in
	// the gateway-api-keys Secret.
	//
	// The harness resolves both tenants before starting load and fails the benchmark with
	// TenantNotProvisioned rather than proceeding, because a run that quietly bypasses the gateway identity
	// model is not measuring this platform.
	// +required
	Tenant string `json:"tenant"`

	// model is the served model name.
	// +required
	Model string `json:"model"`

	// qps is the arrival rate as a decimal string (e.g. "2.0").
	//
	// A string rather than a float: the value appears verbatim in the report, and a float would print back
	// differently than it was written.
	// +required
	QPS string `json:"qps"`

	// inputTokens is the prompt length per request.
	// +kubebuilder:validation:Minimum=1
	// +required
	InputTokens int32 `json:"inputTokens"`

	// outputTokens is the generation length per request.
	// +kubebuilder:validation:Minimum=1
	// +required
	OutputTokens int32 `json:"outputTokens"`
}

// LoadSpec is the arrival protocol, enforced rather than documented.
type LoadSpec struct {
	// mode is openLoop and nothing else.
	//
	// A closed-loop client waits for each response before sending the next request, so its own queueing delay
	// suppresses the arrivals that would have revealed it -- coordinated omission. Tail-latency claims from
	// closed-loop load are invalid, so the enum admits one value instead of leaving the choice open.
	// +kubebuilder:validation:Enum=openLoop
	// +required
	Mode string `json:"mode"`

	// generator is the pinned load tool and version (e.g. "genai-perf vX.Y").
	// +required
	Generator string `json:"generator"`

	// streaming says whether the generator streams responses.
	// +optional
	Streaming bool `json:"streaming,omitempty"`

	// timeoutMs is the per-request timeout; a timeout is recorded as an error and never dropped.
	// +kubebuilder:validation:Minimum=1
	// +required
	TimeoutMs int32 `json:"timeoutMs"`

	// retries must be zero.
	//
	// A retry replaces a slow response with a fast one and repairs the tail the experiment exists to measure.
	// The CEL rule on the spec refuses any other value.
	// +kubebuilder:validation:Minimum=0
	// +required
	Retries int32 `json:"retries"`
}

// GpuSharingBenchmarkStatus is the observed state.
//
// result is absent until a real-GPU run writes it. There are deliberately no placeholder numbers: a reader who
// finds a ratio here must be able to trust that hardware produced it.
type GpuSharingBenchmarkStatus struct {
	// phase is the high-level state of the experiment.
	//
	// Completed requires result.reportUri -- a benchmark that finished without saying where its report is has
	// not completed, it has stopped.
	// +kubebuilder:validation:Enum=Pending;Running;Completed;Failed
	// +optional
	Phase string `json:"phase,omitempty"`

	// observedGeneration is the most recent generation observed.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`

	// result is written only by a real-GPU run.
	// +optional
	Result *BenchmarkResult `json:"result,omitempty"`

	// conditions represent the current state of the GpuSharingBenchmark resource.
	//
	// The status of each condition is one of True, False, or Unknown.
	// +listType=map
	// +listMapKey=type
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// BenchmarkResult is what a measured run recorded.
type BenchmarkResult struct {
	// baselineP99Ms is the victim's p99 with the contender absent.
	// +optional
	BaselineP99Ms int64 `json:"baselineP99Ms,omitempty"`

	// colocatedP99Ms is the victim's p99 with the contender present.
	// +optional
	ColocatedP99Ms int64 `json:"colocatedP99Ms,omitempty"`

	// interferenceRatio is colocatedP99Ms / baselineP99Ms as a decimal string.
	// +optional
	InterferenceRatio string `json:"interferenceRatio,omitempty"`

	// p99CI95 is the bootstrap 95% interval for the colocated p99, e.g. "2210-2440".
	//
	// Recorded beside the ratio because a ratio without a spread invites a reader to treat run-to-run
	// variation as an effect.
	// +optional
	P99CI95 string `json:"p99CI95,omitempty"`

	// reportUri points at the committed report and its raw data.
	// +optional
	ReportURI string `json:"reportUri,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Mode",type=string,JSONPath=`.spec.sharingMode`
// +kubebuilder:printcolumn:name="Class",type=string,JSONPath=`.spec.gpuClass`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
// +kubebuilder:printcolumn:name="Ratio",type=string,JSONPath=`.status.result.interferenceRatio`
// +kubebuilder:validation:XValidation:rule="self.spec.load.retries == 0",message="spec.load.retries must be 0; a retry repairs the tail latency this benchmark measures"
// +kubebuilder:validation:XValidation:rule="self.spec.sharingMode != 'sharedInstance' || self.spec.baseline.model == self.spec.contender.model",message="sharedInstance means one vLLM instance, so baseline.model and contender.model must be equal"
// +kubebuilder:validation:XValidation:rule="self.spec.sharingMode == oldSelf.spec.sharingMode && self.spec.baseline == oldSelf.spec.baseline && self.spec.contender == oldSelf.spec.contender && self.spec.load == oldSelf.spec.load",message="sharingMode, baseline, contender and load define the experiment and are immutable; create a new GpuSharingBenchmark instead"

// GpuSharingBenchmark declares one A/B contention experiment and records its result.
type GpuSharingBenchmark struct {
	metav1.TypeMeta `json:",inline"`

	// metadata is a standard object metadata
	// +optional
	metav1.ObjectMeta `json:"metadata,omitzero"`

	// spec defines the desired state of GpuSharingBenchmark
	// +required
	Spec GpuSharingBenchmarkSpec `json:"spec"`

	// status defines the observed state of GpuSharingBenchmark
	// +optional
	Status GpuSharingBenchmarkStatus `json:"status,omitzero"`
}

// +kubebuilder:object:root=true

// GpuSharingBenchmarkList contains a list of GpuSharingBenchmark
type GpuSharingBenchmarkList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitzero"`
	Items           []GpuSharingBenchmark `json:"items"`
}

func init() {
	SchemeBuilder.Register(&GpuSharingBenchmark{}, &GpuSharingBenchmarkList{})
}
