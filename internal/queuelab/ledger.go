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

import (
	"fmt"
	"slices"
	"sort"
)

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
	// ObjectUID is the observed object's UID; for Pod events it is the attempt identity that preemption
	// waste is paired on, so a duplicate delta or an unrelated Pod stop cannot truncate another attempt.
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
	//
	// It is written by the submitting path right after a successful Create, not by a watch, so it cannot be
	// observed after an admission of the same job; Reconstruct rejects any admitted-before-submitted timeline.
	EventSubmitted EventType = "Submitted"
	// EventAdmitted is the Workload reaching Admitted=True.
	EventAdmitted EventType = "Admitted"
	// EventPodReady is the training Pod becoming Ready (execution start); it carries the Pod UID as the
	// attempt identity.
	EventPodReady EventType = "PodReady"
	// EventPreempted is when Kueue DECIDES to preempt the Workload (Preempted=True).
	//
	// It is the decision, not the moment execution stops; the two are separated because the discarded work
	// continues between the decision and the Pod actually terminating.
	EventPreempted EventType = "Preempted"
	// EventAttemptStopped is when the preempted Pod actually terminates (terminal/deleted observation, not
	// the first deletionTimestamp which merely starts the grace period); it carries the Pod UID.
	//
	// Waste is measured up to here, not up to the preemption decision, so the work done during the grace
	// window is not silently dropped from the discarded total.
	EventAttemptStopped EventType = "AttemptStopped"
	// EventCompleted is the Job reaching successful completion.
	EventCompleted EventType = "Completed"
)

// attempt is one Pod's execution, keyed by Pod UID, so preemption waste is paired to the exact Pod that
// ran rather than to whichever stop happened to be recorded next.
type attempt struct {
	uid      string
	readyNs  int64
	stopped  bool
	stopNs   int64
	consumed bool // a preemption decision has claimed this attempt's discarded work
}

// jobTimeline reconstructs one job's story from its events. It is SEEDED from the frozen trace row, not
// discovered from whatever events arrived, so a job whose events were all missed still appears (censored)
// in the denominators rather than silently vanishing and flattering the worse arm.
type jobTimeline struct {
	tenant   string
	gpuCount int

	submitted   bool
	submittedNs int64
	admitted    bool
	admitNs     int64
	completed   bool
	completedNs int64

	attempts    map[string]*attempt
	attemptSeq  []string // insertion order of attempt UIDs, for deterministic pairing
	preemptedNs []int64
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
	// WastedGPUSeconds is the EXACT discarded work: sum over preempted attempts whose Pod stop was observed
	// at or before the horizon, of gpuCount * (stop - ready).
	WastedGPUSeconds float64
	// WasteLowerBoundGPUSeconds is >= WastedGPUSeconds: it also counts attempts whose stop was not observed
	// in-horizon, charged only up to the horizon. It is a lower bound, never presented as exact.
	WasteLowerBoundGPUSeconds float64
	// WasteCensored is true when at least one preempted attempt lacked an observed in-horizon stop, so the
	// exact total understates this job's discarded work.
	WasteCensored bool
	// CensoredWaitNs is a lower-bound wait for a job never admitted by the horizon (submitted -> horizon).
	CensoredWaitNs int64
}

// LabResult is the censoring-aware reconstruction of one arm's run.
type LabResult struct {
	Arm string
	// Offered is the number of trace rows the arm was asked to run; it is the denominator the other counts
	// are read against, so a missed job cannot shrink the denominator.
	Offered   int
	Outcomes  []WorkloadOutcome
	Admitted  int
	Completed int
	// UnfinishedAtHorizon is the count still pending or running at the horizon; excluding these from
	// latency percentiles would flatter the worse policy, so they are reported explicitly.
	UnfinishedAtHorizon int
	// AdmittedWaitP95Ns is the p95 admission latency over ADMITTED jobs only, in ns. It is a SECONDARY
	// statistic: on a heavily censored arm it is admitted-survivor-biased (0 admissions reads as 0), so it
	// must be read together with WaitP95Estimable and the censored waits, never in place of them.
	AdmittedWaitP95Ns int64
	// WaitP95Estimable is true only when at least 95% of offered jobs were admitted, so the p95 is not just
	// the fastest survivors. When false, AdmittedWaitP95Ns is not a defensible comparison number.
	WaitP95Estimable bool
	// TotalWastedGPUSeconds is the run's total EXACT discarded (restart-from-zero) work.
	TotalWastedGPUSeconds float64
	// TotalWasteLowerBoundGPUSeconds is >= the exact total, counting censored attempts up to the horizon.
	TotalWasteLowerBoundGPUSeconds float64
	// AnyWasteCensored is true when any outcome's waste is censored, so the exact total is a lower bound.
	AnyWasteCensored bool
}

// Reconstruct turns a raw event ledger into a censoring-aware result for one arm, up to horizonElapsedNs
// (the monotonic run offset the runner marks as the observation horizon).
//
// It is SEEDED from the frozen trace: every offered row gets exactly one timeline whether or not its events
// arrived, so a job pending or missed at the horizon becomes an unfinished, right-censored outcome rather
// than a silent omission. It returns an error rather than a number on impossible or conflicting evidence
// (an event for an unknown job, a missing or duplicated submission, an admitted-before-submitted or
// completed-before-admitted ordering, or a preemption that pairs to no running attempt), because for an
// experiment tool a plausible wrong number is worse than a refusal.
func Reconstruct(arm string, trace []TrainingTraceRow, events []LifecycleEvent, horizonElapsedNs int64) (LabResult, error) {
	byJob := map[string]*jobTimeline{}
	order := make([]string, 0, len(trace))
	for _, row := range trace {
		if _, dup := byJob[row.Name]; dup {
			return LabResult{}, fmt.Errorf("trace has duplicate job name %q", row.Name)
		}
		byJob[row.Name] = &jobTimeline{
			tenant:   row.Tenant,
			gpuCount: row.GPUCount,
			attempts: map[string]*attempt{},
		}
		order = append(order, row.Name)
	}

	for i := range events {
		if err := foldEvent(byJob, &events[i], horizonElapsedNs); err != nil {
			return LabResult{}, err
		}
	}

	res := LabResult{Arm: arm, Offered: len(trace)}
	var admitWaits []float64
	for _, job := range order {
		t := byJob[job]
		if !t.submitted {
			// Every offered row must carry exactly one Submitted (written after a successful Create). Its
			// absence means the job was never created, which invalidates the run rather than censoring it.
			return LabResult{}, fmt.Errorf("job %q has no Submitted event; the run is invalid", job)
		}
		out := WorkloadOutcome{Job: job, Tenant: t.tenant}
		if t.admitted {
			out.Admitted = true
			out.AdmitLatencyNs = t.admitNs - t.submittedNs
			admitWaits = append(admitWaits, float64(out.AdmitLatencyNs))
			res.Admitted++
		} else {
			out.CensoredWaitNs = horizonElapsedNs - t.submittedNs
		}
		if t.completed {
			out.Completed = true
			res.Completed++
		} else {
			res.UnfinishedAtHorizon++
		}
		if err := chargeWaste(t, horizonElapsedNs, &out); err != nil {
			return LabResult{}, fmt.Errorf("job %q: %w", job, err)
		}
		res.TotalWastedGPUSeconds += out.WastedGPUSeconds
		res.TotalWasteLowerBoundGPUSeconds += out.WasteLowerBoundGPUSeconds
		if out.WasteCensored {
			res.AnyWasteCensored = true
		}
		res.Outcomes = append(res.Outcomes, out)
	}

	sort.Float64s(admitWaits)
	res.AdmittedWaitP95Ns = int64(percentileNs(admitWaits, 0.95))
	// The p95 is only a defensible comparison number when almost everyone was admitted; otherwise it is the
	// latency of the fastest survivors. Require at least 95% of offered jobs admitted.
	if res.Offered > 0 {
		needed := (res.Offered*95 + 99) / 100 // ceil(0.95 * Offered)
		res.WaitP95Estimable = res.Admitted >= needed
	}
	return res, nil
}

// foldEvent validates one event against the seeded timelines and folds it in, returning an error on any
// evidence that could not have happened in a real run.
func foldEvent(byJob map[string]*jobTimeline, e *LifecycleEvent, horizonElapsedNs int64) error {
	if e.ElapsedNs > horizonElapsedNs {
		// A post-horizon delta is provenance for the causal tail (e.g. a stop that closes a pre-horizon
		// preemption); it is folded so waste can pair to it, but it never creates in-horizon outcomes.
		if e.Type != EventAttemptStopped {
			return nil
		}
	}
	t, ok := byJob[e.Job]
	if !ok {
		return fmt.Errorf("event for job %q is not in the trace", e.Job)
	}
	switch e.Type {
	case EventSubmitted:
		if t.submitted && t.submittedNs != e.ElapsedNs {
			return fmt.Errorf("job %q submitted twice at %d and %d", e.Job, t.submittedNs, e.ElapsedNs)
		}
		t.submitted = true
		t.submittedNs = e.ElapsedNs
	case EventAdmitted:
		if !t.admitted {
			t.admitted = true
			t.admitNs = e.ElapsedNs
		} else if e.ElapsedNs < t.admitNs {
			t.admitNs = e.ElapsedNs
		}
	case EventPodReady:
		if e.ObjectUID == "" {
			return fmt.Errorf("job %q PodReady has no Pod UID", e.Job)
		}
		a, ok := t.attempts[e.ObjectUID]
		if !ok {
			a = &attempt{uid: e.ObjectUID, readyNs: e.ElapsedNs}
			t.attempts[e.ObjectUID] = a
			t.attemptSeq = append(t.attemptSeq, e.ObjectUID)
		} else if e.ElapsedNs < a.readyNs {
			a.readyNs = e.ElapsedNs
		}
	case EventPreempted:
		t.preemptedNs = append(t.preemptedNs, e.ElapsedNs)
	case EventAttemptStopped:
		if e.ObjectUID == "" {
			return fmt.Errorf("job %q AttemptStopped has no Pod UID", e.Job)
		}
		a, ok := t.attempts[e.ObjectUID]
		if !ok {
			return fmt.Errorf("job %q AttemptStopped for unknown Pod %q (no PodReady seen)", e.Job, e.ObjectUID)
		}
		if !a.stopped || e.ElapsedNs < a.stopNs {
			a.stopped = true
			a.stopNs = e.ElapsedNs
		}
	case EventCompleted:
		t.completed = true
		t.completedNs = e.ElapsedNs
	default:
		return fmt.Errorf("job %q has unknown event type %q", e.Job, e.Type)
	}
	return nil
}

// chargeWaste runs the per-job ordering checks and the attempt-paired preemption accounting, writing the
// exact and lower-bound waste onto out.
func chargeWaste(t *jobTimeline, horizonElapsedNs int64, out *WorkloadOutcome) error {
	if t.admitted && t.admitNs < t.submittedNs {
		return fmt.Errorf("admitted at %d before submitted at %d", t.admitNs, t.submittedNs)
	}
	if t.completed && (!t.admitted || t.completedNs < t.admitNs) {
		return fmt.Errorf("completed at %d before admitted", t.completedNs)
	}

	out.Preemptions = len(t.preemptedNs)
	decisions := append([]int64(nil), t.preemptedNs...)
	slices.Sort(decisions)
	for _, d := range decisions {
		a := openAttemptAt(t, d)
		if a == nil {
			return fmt.Errorf("preemption at %d pairs to no running attempt", d)
		}
		a.consumed = true
		gpu := float64(t.gpuCount)
		switch {
		case a.stopped && a.stopNs <= horizonElapsedNs:
			// The Pod stop was observed in-horizon: the discarded work is exact, from Ready to the stop.
			exact := gpu * float64(a.stopNs-a.readyNs) / 1e9
			out.WastedGPUSeconds += exact
			out.WasteLowerBoundGPUSeconds += exact
		case a.stopped:
			// The stop was observed beyond the horizon, so the attempt is KNOWN to have run through the
			// horizon: charge a lower bound to the horizon (including the grace period up to it) and flag it.
			out.WasteLowerBoundGPUSeconds += gpu * float64(horizonElapsedNs-a.readyNs) / 1e9
			out.WasteCensored = true
		default:
			// No stop was observed at all: the attempt could have stopped early in the grace window, so the
			// only defensible floor is up to the preemption DECISION, which it provably ran to. Flag it.
			out.WasteLowerBoundGPUSeconds += gpu * float64(d-a.readyNs) / 1e9
			out.WasteCensored = true
		}
	}
	return nil
}

// openAttemptAt returns the unconsumed attempt that was Ready before decision time d and had not already
// stopped before d (so it was still running when the preemption was decided), choosing the most recently
// Ready such attempt. It returns nil when no attempt was running, which is an invalid preemption.
func openAttemptAt(t *jobTimeline, d int64) *attempt {
	var best *attempt
	for _, uid := range t.attemptSeq {
		a := t.attempts[uid]
		if a.consumed || a.readyNs >= d {
			continue
		}
		if a.stopped && a.stopNs < d {
			continue
		}
		if best == nil || a.readyNs > best.readyNs {
			best = a
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
