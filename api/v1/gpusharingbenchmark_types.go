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
	//
	// Required, and serialized even at zero. As an optional field with omitempty it was the second half of a
	// trap: the whole spec is compared against oldSelf on update, that comparison is over API values and
	// counts field presence, and a Go round-trip drops an omitempty zero -- so an object created with an
	// explicit zero could never be updated again, for any field. Making it required removes the only
	// remaining optional field in the spec alongside streaming.
	// +kubebuilder:validation:Minimum=0
	// +required
	WarmupRequests int32 `json:"warmupRequests"`

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

	// qps is the arrival rate as a positive plain decimal string (e.g. "2.0", "0.01").
	//
	// A string rather than a float: the value appears verbatim in the report, and a float would print back
	// differently than it was written. The cost of that choice is that the spelling is part of the
	// experiment's identity -- "2" and "2.00" name the same rate and are different values to the
	// immutability rule -- which is accepted deliberately and is why the grammar is narrow.
	//
	// The pattern admits only digits with at most one decimal point, and the second rule refuses every
	// spelling of zero. Without them the field was an unrestricted string: "", " 2.0", "NaN", "-1", "2e0",
	// "0" and "abc" were all accepted, measured against a real apiserver.
	//
	// Zero is refused rather than read as "this side is off". The control condition is the harness running
	// the baseline with the contender disabled; the registered rate describes the active condition, and a
	// zero that meant absence would make one field carry two meanings.
	// +kubebuilder:validation:MaxLength=16
	// +kubebuilder:validation:Pattern=`^[0-9]+(\.[0-9]+)?$`
	// +kubebuilder:validation:XValidation:rule="self.matches('[1-9]')",message="qps must be greater than zero; a control condition is the harness disabling the contender, not a rate of zero"
	// +required
	QPS string `json:"qps"`

	// inputTokens is the prompt length per request.
	// +kubebuilder:validation:Minimum=1
	// +required
	InputTokens int32 `json:"inputTokens"`

	// outputTokens is the requested generation CEILING per request, not a guaranteed length.
	//
	// The load generator sends it as the engine's max_tokens, which is an upper bound: a response that hits a
	// stop condition earlier is shorter, and nothing makes the engine emit this many. So a run whose
	// responses average well under this value has not violated the protocol, and a reading that assumed this
	// many tokens per response would be wrong about the work the card did.
	//
	// This comment said "the generation length per request" until 2026-09-30, which is a promise the sender
	// does not keep -- and field comments are copied into the generated CRD description, so it was a promise
	// shipped to operators. Recorded here rather than silently corrected because the wording is what a reader
	// would have relied on.
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
	//
	// Required, and serialized even when false, for the reason given on warmupRequests: an omitempty zero
	// vanishes on a Go round-trip and the whole-spec immutability comparison then sees a field that has
	// disappeared. An object created with an explicit streaming: false was frozen against every later
	// update, including to fields documented as mutable -- confirmed against a real apiserver before this
	// change.
	// +required
	Streaming bool `json:"streaming"`

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
//
// The completion invariant is enforced here rather than left to prose. Before this rule, a status update
// carrying nothing but phase: Completed was accepted, so the type's own documentation ("Completed requires
// result.reportUri") was a claim the schema did not make. It refuses a completion with no result, no URI or
// an empty URI. It does not and cannot say the report exists or that its number is right.
// Emptiness is tested with size(...) > 0 rather than by comparing against an empty string literal.
//
// Go's doc-comment reformatting turns a pair of ASCII apostrophes in a comment into a single closing curly
// quote (U+201D), and a curly quote inside a CEL expression is a broken expression. gofmt offered that edit,
// I applied it without reading the bytes, and the generated CRD only stayed correct because it had been
// written before. Avoiding the literal avoids the rewrite; no apostrophe pair belongs in these comments.
// The invariant demands the ratio interval too, because the third amendment of 2026-09-30 made it the
// primary reported object. A field nothing requires gets omitted in silence, and then a benchmark reaches
// Completed carrying a point ratio with no spread -- which is the shape this rule was written to refuse in
// the first place, one field over.
// +kubebuilder:validation:XValidation:rule="!has(self.phase) || self.phase != 'Completed' || (has(self.result) && has(self.result.reportUri) && size(self.result.reportUri) > 0 && has(self.result.interferenceRatioCI95) && size(self.result.interferenceRatioCI95) > 0)",message="phase Completed requires a non-empty status.result.reportUri and a non-empty status.result.interferenceRatioCI95"
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
	// baselineP99Ms is the MEDIAN of the per-repetition victim TTFT p99s with the contender absent.
	//
	// A median of repetition-level tails, not a p99 pooled over every request of every repetition. Pooling
	// re-weights repetitions by how many requests each happened to complete, which answers a different
	// question from the one this type registered by giving repetitions equal standing.
	// +optional
	BaselineP99Ms int64 `json:"baselineP99Ms,omitempty"`

	// colocatedP99Ms is the same median with the contender present.
	// +optional
	ColocatedP99Ms int64 `json:"colocatedP99Ms,omitempty"`

	// interferenceRatio is colocatedP99Ms / baselineP99Ms as a decimal string.
	// +optional
	InterferenceRatio string `json:"interferenceRatio,omitempty"`

	// p99CI95 is the nominal bootstrap 95% interval for the colocated median p99, in milliseconds,
	// e.g. "2210-2440".
	//
	// Recorded beside the ratio because a ratio without a spread invites a reader to treat run-to-run
	// variation as an effect. It is NOT the interval for the ratio: this one carries no uncertainty from the
	// denominator, so it cannot bound the quantity the experiment reports. That is interferenceRatioCI95.
	// The units stay milliseconds for exactly this reason -- redefining this field as a dimensionless ratio
	// would silently change the meaning of a field whose description ships to operators in the CRD.
	// +optional
	P99CI95 string `json:"p99CI95,omitempty"`

	// interferenceRatioCI95 is the nominal bootstrap 95% interval for interferenceRatio, e.g. "1.82-2.31".
	//
	// This is the primary reported object of the experiment, fixed by the design spec third amendment of
	// 2026-09-30 before any result existed that could influence the choice. The baseline is measured rather
	// than known, so an interval on the colocated tail alone cannot bound the relative interference the
	// benchmark exists to report.
	//
	// It comes from a PAIRED repetition bootstrap: complete (baseline, colocated) repetition blocks are
	// resampled with replacement, both medians and their ratio recomputed, and the 2.5th and 97.5th
	// percentiles taken. Pairing is by the repetition identity the run schedule records, never inferred from
	// two arrays having equal length.
	//
	// NOMINAL, and the word is load-bearing. Five repetitions are enough to compute this interval and not
	// enough to establish 95% coverage, and more bootstrap draws do not create more repetitions. The report
	// this points at must publish every per-repetition p99 so a reader can see the sample it came from.
	// +optional
	InterferenceRatioCI95 string `json:"interferenceRatioCI95,omitempty"`

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
// +kubebuilder:validation:XValidation:rule="self.spec.baseline.tenant != self.spec.contender.tenant",message="baseline.tenant and contender.tenant must differ; one tenant on both sides measures intra-tenant contention, not isolation between tenants"
// +kubebuilder:validation:XValidation:rule="self.spec == oldSelf.spec",message="the spec is a registration and is immutable once created; register a new GpuSharingBenchmark rather than editing this one"

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
