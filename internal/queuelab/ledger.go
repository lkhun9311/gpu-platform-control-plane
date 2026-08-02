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

// StopReasonSucceeded and StopReasonFailed are the terminal Pod phases the collector stamps onto an
// AttemptStopped event.
//
// They are the ONLY evidence in the ledger that distinguishes "the preemption stopped this attempt" from
// "this attempt finished its own service while marked preempted", and the second case is not discarded work.
const (
	StopReasonSucceeded = "Succeeded"
	StopReasonFailed    = "Failed"
)

// attempt is one Pod's execution, keyed by Pod UID, so preemption waste is paired to the exact Pod that
// ran rather than to whichever stop happened to be recorded next.
type attempt struct {
	uid        string
	readyNs    int64
	stopped    bool
	stopNs     int64
	stopReason string // the terminal Pod phase, which is what makes a stop attributable or not
	consumed   bool   // a preemption decision has claimed this attempt's discarded work
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
	// Executed is true when the row reached Pod Ready, which is the harness's execution-start proxy.
	//
	// It is NOT service restoration: a busybox sleeper has no application readiness contract.
	Executed bool
	// ReadyLatencyNs is submitted -> first observed Pod Ready, a client-observed propagation gap; valid only
	// when Executed is true.
	ReadyLatencyNs int64
	// AdmitToReadyNs is admission -> first observed Pod Ready, a client-observed propagation gap.
	//
	// It exists because admission is a QUOTA RESERVATION, not the start of execution: a preempted victim can
	// still hold the physical device while the owner's Workload is already admitted, so reporting admission
	// alone overstates how quickly the owner was actually restored.
	AdmitToReadyNs int64
	Completed      bool
	// Preemptions counts how many times the job was preempted.
	Preemptions int
	// WastedGPUSeconds is the EXACT discarded work ATTRIBUTABLE to preemption: sum over preempted attempts
	// whose Pod stop was observed at or before the horizon AND whose stop was caused by the preemption, of
	// gpuCount * (stop - ready).
	//
	// The attribution clause is not pedantry. A workload that ignores SIGTERM keeps running after the
	// preemption decision and reaches a terminal Succeeded phase on its own; charging that run as discarded
	// work reports a completed job as destroyed progress, which is exactly the error this field's earlier
	// definition produced.
	WastedGPUSeconds float64
	// UnattributedOccupancyGPUSeconds is the occupancy of attempts that were preempted on paper but observed
	// to terminate as Succeeded, so their work was not cut short. It is reported, never folded into waste.
	UnattributedOccupancyGPUSeconds float64
	// PreemptionIneffective is true when at least one preemption decision was followed by that attempt
	// completing successfully, meaning the platform decided to reclaim and the workload did not comply.
	PreemptionIneffective bool
	// WasteLowerBoundGPUSeconds is >= WastedGPUSeconds: it also counts attempts whose stop was not observed
	// in-horizon, charged only up to the horizon. It is a lower bound, never presented as exact.
	WasteLowerBoundGPUSeconds float64
	// WasteCensored is true when at least one preempted attempt lacked an observed in-horizon stop, so the
	// exact total understates this job's discarded work.
	WasteCensored bool
	// CensoredWaitNs is a lower-bound wait for a job never admitted by the horizon (submitted -> horizon).
	CensoredWaitNs int64
	// Attempts is how many Pod attempts this row ran.
	//
	// More than one means the platform re-ran work it had already executed, which a report limited to the
	// first attempt would hide entirely.
	Attempts int
	// ReExecuted is true when the row ran more than one attempt.
	ReExecuted bool
	// TotalOccupancyGPUSeconds is gpuCount-weighted execution time summed over ALL attempts, censored
	// attempts charged only to the horizon. It is the row's real cost to the pool regardless of attribution.
	TotalOccupancyGPUSeconds float64
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
	// statistic: on a censored arm it is admitted-survivor-biased (0 admissions reads as 0), so it must be
	// read together with WaitP95FullyObserved and the censored waits, never in place of them.
	AdmittedWaitP95Ns int64
	// WaitP95FullyObserved is true only when EVERY offered job was admitted, which is the only case where
	// the admitted-only p95 equals the offered-work p95. Any unadmitted job is right-censored with an
	// unknown true wait that could occupy the p95 rank, so an admission fraction below 100% cannot make the
	// admitted-only p95 a defensible estimate of the offered-work p95; when false, treat AdmittedWaitP95Ns
	// as a within-survivors descriptor only.
	WaitP95FullyObserved bool
	// TotalWastedGPUSeconds is the run's total EXACT discarded (restart-from-zero) work.
	TotalWastedGPUSeconds float64
	// TotalWasteLowerBoundGPUSeconds is >= the exact total, counting censored attempts up to the horizon.
	TotalWasteLowerBoundGPUSeconds float64
	// AnyWasteCensored is true when any outcome's waste is censored, so the exact total is a lower bound.
	AnyWasteCensored bool
	// TotalUnattributedOccupancyGPUSeconds is the run's total occupancy that a preemption was decided over
	// but did not actually stop.
	TotalUnattributedOccupancyGPUSeconds float64
	// AnyPreemptionIneffective is true when any preemption in the run failed to stop its target.
	AnyPreemptionIneffective bool
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
//
// It assumes its input came from a fail-closed collector that observes every terminal Pod transition and
// invalidates a run on any unexplained one (the live runner's contract). That precondition is what makes
// "no in-horizon stop" mean the attempt still held the GPU at the horizon, so the censored waste lower
// bound is a true lower bound rather than a guess; on a raw hand-authored ledger that guarantee is absent.
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
		res.TotalUnattributedOccupancyGPUSeconds += out.UnattributedOccupancyGPUSeconds
		if out.PreemptionIneffective {
			res.AnyPreemptionIneffective = true
		}
		res.Outcomes = append(res.Outcomes, out)
	}

	sort.Float64s(admitWaits)
	res.AdmittedWaitP95Ns = int64(percentileNs(admitWaits, 0.95))
	// The admitted-only p95 equals the offered-work p95 only when nothing is censored. With any unadmitted
	// job the offered p95 is not identifiable from admitted data, so the fully-observed flag is exactly
	// "every offered job was admitted", not an admission-fraction threshold.
	res.WaitP95FullyObserved = res.Offered > 0 && res.Admitted == res.Offered
	return res, nil
}

// foldEvent validates one event against the seeded timelines and folds it in, returning an error on any
// evidence that could not have happened in a real run.
//
// Shape validation (known job, known type, Pod events carry a UID, non-negative timestamp) runs BEFORE the
// horizon rule, so a corrupt event is rejected whether it lands before or after the horizon. Only a valid
// post-horizon AttemptStopped is then folded, as the causal tail that closes a pre-horizon preemption; any
// other post-horizon delta is validated but not folded into in-horizon state.
func foldEvent(byJob map[string]*jobTimeline, e *LifecycleEvent, horizonElapsedNs int64) error {
	if e.ElapsedNs < 0 {
		return fmt.Errorf("job %q event has negative elapsed time %d", e.Job, e.ElapsedNs)
	}
	t, ok := byJob[e.Job]
	if !ok {
		return fmt.Errorf("event for job %q is not in the trace", e.Job)
	}
	switch e.Type {
	case EventSubmitted, EventAdmitted, EventPreempted, EventCompleted:
	case EventPodReady, EventAttemptStopped:
		if e.ObjectUID == "" {
			return fmt.Errorf("job %q %s has no Pod UID", e.Job, e.Type)
		}
	default:
		return fmt.Errorf("job %q has unknown event type %q", e.Job, e.Type)
	}

	if e.ElapsedNs > horizonElapsedNs && e.Type != EventAttemptStopped {
		return nil
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
		a, ok := t.attempts[e.ObjectUID]
		if !ok {
			return fmt.Errorf("job %q AttemptStopped for unknown Pod %q (no PodReady seen)", e.Job, e.ObjectUID)
		}
		if !a.stopped || e.ElapsedNs < a.stopNs {
			a.stopped = true
			a.stopNs = e.ElapsedNs
			a.stopReason = e.Reason
		}
	case EventCompleted:
		if t.completed && t.completedNs != e.ElapsedNs {
			return fmt.Errorf("job %q completed twice at %d and %d", e.Job, t.completedNs, e.ElapsedNs)
		}
		t.completed = true
		t.completedNs = e.ElapsedNs
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
	out.Attempts = len(t.attemptSeq)
	out.ReExecuted = out.Attempts > 1
	if len(t.attemptSeq) > 0 {
		firstReady := t.attempts[t.attemptSeq[0]].readyNs
		out.Executed = true
		out.ReadyLatencyNs = firstReady - t.submittedNs
		if t.admitted {
			out.AdmitToReadyNs = firstReady - t.admitNs
		}
	}
	for _, uid := range t.attemptSeq {
		a := t.attempts[uid]
		end := horizonElapsedNs
		if a.stopped && a.stopNs <= horizonElapsedNs {
			end = a.stopNs
		}
		out.TotalOccupancyGPUSeconds += float64(t.gpuCount) * float64(end-a.readyNs) / 1e9
	}
	decisions := append([]int64(nil), t.preemptedNs...)
	slices.Sort(decisions)
	for _, d := range decisions {
		a, err := openAttemptAt(t, d)
		if err != nil {
			return err
		}
		a.consumed = true
		gpu := float64(t.gpuCount)
		switch {
		case a.stopped && a.stopNs <= horizonElapsedNs && a.stopReason == StopReasonSucceeded:
			// The attempt reached a successful terminal phase, so it finished its own service rather than
			// being stopped by the preemption. Its occupancy is real but it is not discarded work, and
			// folding it into waste would report a completed run as destroyed progress.
			out.UnattributedOccupancyGPUSeconds += gpu * float64(a.stopNs-a.readyNs) / 1e9
			out.PreemptionIneffective = true
		case a.stopped && a.stopNs <= horizonElapsedNs:
			// The Pod stop was observed in-horizon and was not a successful completion: the discarded work
			// is exact, from Ready to the stop.
			exact := gpu * float64(a.stopNs-a.readyNs) / 1e9
			out.WastedGPUSeconds += exact
			out.WasteLowerBoundGPUSeconds += exact
		default:
			// No in-horizon stop was observed. Because the collector is fail-closed and observes every
			// terminal Pod transition (the runner's contract; a run with an unexplained missing stop is
			// invalidated upstream), the absence of a stop by the horizon means the attempt still held the
			// GPU at the horizon. So the discarded work is at least Ready->horizon: a lower bound, flagged,
			// never folded into the exact total. A stop recorded beyond the horizon is the same case.
			out.WasteLowerBoundGPUSeconds += gpu * float64(horizonElapsedNs-a.readyNs) / 1e9
			out.WasteCensored = true
		}
	}
	return nil
}

// openAttemptAt returns the single unconsumed attempt that was Ready before decision time d and had not
// already stopped before d, so it was still running when the preemption was decided.
//
// It requires EXACTLY ONE such attempt. A Workload preemption delta does not name a Pod UID, so if two
// attempts were both running at the decision the pairing is ambiguous; rather than pick one heuristically
// (which can misattribute discarded work), it errors, because for one training row Kueue runs one attempt
// at a time and two concurrently-running attempts mean the ledger is inconsistent. It also errors when no
// attempt was running, which is an unpaired preemption.
func openAttemptAt(t *jobTimeline, d int64) (*attempt, error) {
	var found *attempt
	for _, uid := range t.attemptSeq {
		a := t.attempts[uid]
		if a.consumed || a.readyNs >= d {
			continue
		}
		if a.stopped && a.stopNs < d {
			continue
		}
		if found != nil {
			return nil, fmt.Errorf("preemption at %d has two running attempts (%s, %s); ambiguous pairing", d, found.uid, a.uid)
		}
		found = a
	}
	if found == nil {
		return nil, fmt.Errorf("preemption at %d pairs to no running attempt", d)
	}
	return found, nil
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
