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

package queuelab

import "sort"

// LifecycleEvent is one observed transition in the run's authoritative ledger.
//
// The list/watch collector (a later slice) records these for MLTrainingJob, Job, Workload, and Pod.
// Workload and Pod events are the primary evidence; the MLTrainingJob phase is a derived cross-check.
//
// Every latency, occupancy, and waste number the report makes is reconstructed from these events, never
// from an aggregated Prometheus histogram.
type LifecycleEvent struct {
	// ElapsedNs is the transition time as a monotonic offset from the run's t0.
	//
	// The review caught that a wall-clock UnixNano is not monotonic (it drops Go's monotonic component), so
	// the collector stamps this elapsed offset as the timing authority and keeps the wall clock separately.
	ElapsedNs int64 `json:"elapsedNs"`
	// WallUnixNanos is the wall-clock observation time, kept for provenance only, never for arithmetic.
	WallUnixNanos int64 `json:"wallUnixNanos,omitempty"`
	// Kind is the object kind: "Workload" | "Pod" | "Job" | "MLTrainingJob".
	Kind string `json:"kind"`
	// Type is the transition within the closed vocabulary below.
	Type EventType `json:"type"`
	// Job is the trace job name this event belongs to, resolved by the collector through the UID chain.
	Job string `json:"job"`
	// Tenant is the submitting tenant.
	Tenant string `json:"tenant"`
	// GPUCount is the job's requested quota, carried so occupancy and waste can be weighted.
	GPUCount int `json:"gpuCount"`
	// ObjectUID is the observed object's UID; the collector joins events to a trace job through the UID chain
	// (MLTrainingJob -> Job kueue.x-k8s.io/job-uid -> Workload -> Pod), not by name alone.
	ObjectUID string `json:"objectUID,omitempty"`
	// ResourceVersion and Reason carry the condition provenance so a duplicate delta or the preemption
	// mechanism (e.g. InCohortReclamation) can be checked.
	ResourceVersion string `json:"resourceVersion,omitempty"`
	Reason          string `json:"reason,omitempty"`
}

// EventType is the closed vocabulary of lifecycle transitions the ledger records.
type EventType string

const (
	// EventSubmitted is the MLTrainingJob API acceptance (the offered-work clock start).
	EventSubmitted EventType = "Submitted"
	// EventAdmitted is the Workload reaching Admitted=True.
	EventAdmitted EventType = "Admitted"
	// EventPodReady is the training Pod becoming Ready (execution start).
	EventPodReady EventType = "PodReady"
	// EventPreempted is when Kueue DECIDES to preempt the Workload (Preempted=True).
	//
	// It is the decision, not the moment execution stops; the two are separated because the discarded work
	// continues between the decision and the Pod actually terminating.
	EventPreempted EventType = "Preempted"
	// EventAttemptStopped is when the preempted Pod actually terminates (deletion/termination).
	//
	// Waste is measured up to here, not up to the preemption decision, so the work done during the grace
	// window is not silently dropped from the discarded total.
	EventAttemptStopped EventType = "AttemptStopped"
	// EventCompleted is the Job reaching successful completion.
	EventCompleted EventType = "Completed"
)

// jobTimeline reconstructs one job's story from its events.
//
// Presence is tracked with explicit bools rather than a zero-timestamp sentinel, because a legitimate
// observation can land at offset zero on a synthetic clock and must not be mistaken for "never happened".
type jobTimeline struct {
	tenant       string
	gpuCount     int
	submitted    bool
	submittedNs  int64
	admitted     bool
	firstAdmitNs int64
	completed    bool
	// readyNs, preemptedNs, stoppedNs let preemption waste be measured from the last PodReady up to the Pod
	// actually stopping, not merely up to Kueue's preemption decision.
	readyNs     []int64
	preemptedNs []int64
	stoppedNs   []int64
}

// WorkloadOutcome is one job's reconstructed, censoring-aware result.
type WorkloadOutcome struct {
	Job    string
	Tenant string
	// AdmitLatencyNs is submitted -> first admitted; valid only when Admitted is true.
	AdmitLatencyNs int64
	Admitted       bool
	Completed      bool
	// Preemptions counts how many times the job was preempted.
	Preemptions int
	// WastedGPUSeconds is sum over preempted attempts of gpuCount * (preempted - podReady): work thrown away.
	WastedGPUSeconds float64
	// CensoredWaitNs is a lower-bound wait for a job never admitted by the horizon (submitted -> horizon).
	CensoredWaitNs int64
}

// LabResult is the censoring-aware reconstruction of one arm's run.
type LabResult struct {
	Arm       string
	Outcomes  []WorkloadOutcome
	Admitted  int
	Completed int
	// UnfinishedAtHorizon is the count still pending or running at the horizon; excluding these from
	// latency percentiles would flatter the worse policy, so they are reported explicitly.
	UnfinishedAtHorizon int
	// AdmittedWaitP95Ns is the p95 admission latency over ADMITTED jobs only, in ns.
	//
	// It is reported alongside UnfinishedAtHorizon and the censored waits, never in place of them.
	AdmittedWaitP95Ns int64
	// TotalWastedGPUSeconds is the run's total discarded (restart-from-zero) work.
	TotalWastedGPUSeconds float64
}

// Reconstruct turns a raw event ledger into a censoring-aware result for one arm, up to horizonElapsedNs
// (the monotonic run offset the runner marks as the observation horizon).
//
// It never drops a job: a job pending at the horizon becomes an unfinished, right-censored outcome rather
// than a silent omission, because those slow jobs are exactly what a fair comparison must account for.
func Reconstruct(arm string, events []LifecycleEvent, horizonElapsedNs int64) LabResult {
	byJob := map[string]*jobTimeline{}
	order := []string{}
	for _, e := range events {
		if e.ElapsedNs > horizonElapsedNs {
			continue
		}
		t, ok := byJob[e.Job]
		if !ok {
			t = &jobTimeline{tenant: e.Tenant, gpuCount: e.GPUCount}
			byJob[e.Job] = t
			order = append(order, e.Job)
		}
		switch e.Type {
		case EventSubmitted:
			t.submitted = true
			t.submittedNs = e.ElapsedNs
		case EventAdmitted:
			if !t.admitted {
				t.admitted = true
				t.firstAdmitNs = e.ElapsedNs
			}
		case EventPodReady:
			t.readyNs = append(t.readyNs, e.ElapsedNs)
		case EventPreempted:
			t.preemptedNs = append(t.preemptedNs, e.ElapsedNs)
		case EventAttemptStopped:
			t.stoppedNs = append(t.stoppedNs, e.ElapsedNs)
		case EventCompleted:
			t.completed = true
		}
	}

	res := LabResult{Arm: arm}
	var admitWaits []float64
	for _, job := range order {
		t := byJob[job]
		out := WorkloadOutcome{Job: job, Tenant: t.tenant}
		if t.admitted && t.submitted {
			out.Admitted = true
			out.AdmitLatencyNs = t.firstAdmitNs - t.submittedNs
			admitWaits = append(admitWaits, float64(out.AdmitLatencyNs))
			res.Admitted++
		} else if t.submitted {
			out.CensoredWaitNs = horizonElapsedNs - t.submittedNs
		}
		if t.completed {
			out.Completed = true
			res.Completed++
		} else {
			res.UnfinishedAtHorizon++
		}
		out.Preemptions = len(t.preemptedNs)
		out.WastedGPUSeconds = wastedGPUSeconds(t)
		res.TotalWastedGPUSeconds += out.WastedGPUSeconds
		res.Outcomes = append(res.Outcomes, out)
	}

	sort.Float64s(admitWaits)
	res.AdmittedWaitP95Ns = int64(percentileNs(admitWaits, 0.95))
	return res
}

// wastedGPUSeconds sums, over each preemption, the GPU-seconds discarded from the most recent PodReady up to
// the Pod actually STOPPING (not the preemption decision), so the work done during the termination grace
// window is counted rather than dropped.
//
// Each preempted attempt counts, matching restart-from-zero semantics: the work between becoming Ready and
// stopping is thrown away. If no Pod stop was observed for a decision, the decision time is used as a
// conservative lower bound.
func wastedGPUSeconds(t *jobTimeline) float64 {
	var waste float64
	for _, pre := range t.preemptedNs {
		ready := latestReadyBefore(t.readyNs, pre)
		if ready == 0 {
			continue
		}
		end := firstStoppedAtOrAfter(t.stoppedNs, pre)
		if end == 0 {
			// The Pod stop was not observed, so fall back to the decision time as a lower bound.
			end = pre
		}
		waste += float64(t.gpuCount) * float64(end-ready) / 1e9
	}
	return waste
}

// firstStoppedAtOrAfter returns the earliest recorded Pod-stop time at or after t, or 0 if none.
func firstStoppedAtOrAfter(stops []int64, t int64) int64 {
	var best int64
	for _, s := range stops {
		if s >= t && (best == 0 || s < best) {
			best = s
		}
	}
	return best
}

// latestReadyBefore returns the most recent PodReady time strictly before t, or 0 if none.
func latestReadyBefore(readys []int64, t int64) int64 {
	var best int64
	for _, r := range readys {
		if r < t && r > best {
			best = r
		}
	}
	return best
}

// percentileNs is a nearest-rank percentile over a sorted slice, returning 0 for empty input.
func percentileNs(sorted []float64, q float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	rank := int(float64(len(sorted))*q+0.9999) - 1
	rank = max(rank, 0)
	rank = min(rank, len(sorted)-1)
	return sorted[rank]
}
