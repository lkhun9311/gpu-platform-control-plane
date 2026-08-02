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
	"bytes"
	"testing"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/exputil"
)

const sec = int64(1_000_000_000)

// reclaimAnyTrace is the frozen offered work Reconstruct is seeded from: a1 and a2 both borrow tenant-a's
// side, b1 is the returning owner. Reconstruct never invents jobs beyond these rows.
func reclaimAnyTrace() []TrainingTraceRow {
	return []TrainingTraceRow{
		{Index: 0, Name: "a1", OffsetMs: 0, Tenant: "tenant-a", GPUCount: 1, DurationSec: 600},
		{Index: 1, Name: "a2", OffsetMs: 1_000, Tenant: "tenant-a", GPUCount: 1, DurationSec: 600},
		{Index: 2, Name: "b1", OffsetMs: 590_000, Tenant: "tenant-b", GPUCount: 1, DurationSec: 60},
	}
}

// reclaimAnyEvents is a synthetic ledger for the reclaim "Any", late-owner-return case:
// a1 runs to completion; a2 borrows then is preempted late (its work discarded, its Pod stopping a couple
// seconds after the decision); b1 the owner is admitted quickly after the preemption and completes.
func reclaimAnyEvents() []LifecycleEvent {
	return []LifecycleEvent{
		{ElapsedNs: 0, Kind: "MLTrainingJob", Type: EventSubmitted, Job: "a1", Tenant: "tenant-a", GPUCount: 1},
		{ElapsedNs: 1 * sec, Kind: "Workload", Type: EventAdmitted, Job: "a1", Tenant: "tenant-a", GPUCount: 1},
		{ElapsedNs: 1*sec + sec/2, Kind: "Pod", Type: EventPodReady, Job: "a1", Tenant: "tenant-a", GPUCount: 1, ObjectUID: "pod-a1"},
		{ElapsedNs: 601 * sec, Kind: "Job", Type: EventCompleted, Job: "a1", Tenant: "tenant-a", GPUCount: 1},

		{ElapsedNs: 1 * sec, Kind: "MLTrainingJob", Type: EventSubmitted, Job: "a2", Tenant: "tenant-a", GPUCount: 1},
		{ElapsedNs: 2 * sec, Kind: "Workload", Type: EventAdmitted, Job: "a2", Tenant: "tenant-a", GPUCount: 1},
		{ElapsedNs: 2*sec + sec/2, Kind: "Pod", Type: EventPodReady, Job: "a2", Tenant: "tenant-a", GPUCount: 1, ObjectUID: "pod-a2"},
		{ElapsedNs: 591 * sec, Kind: "Workload", Type: EventPreempted, Job: "a2", Tenant: "tenant-a", GPUCount: 1, Reason: "InCohortReclamation"},
		// The Pod does not stop the instant Kueue decides to preempt; it keeps running through the
		// termination grace window and only stops here, so the discarded work is measured up to this point.
		{ElapsedNs: 593 * sec, Kind: "Pod", Type: EventAttemptStopped, Job: "a2", Tenant: "tenant-a", GPUCount: 1, ObjectUID: "pod-a2"},

		{ElapsedNs: 590 * sec, Kind: "MLTrainingJob", Type: EventSubmitted, Job: "b1", Tenant: "tenant-b", GPUCount: 1},
		{ElapsedNs: 592 * sec, Kind: "Workload", Type: EventAdmitted, Job: "b1", Tenant: "tenant-b", GPUCount: 1},
		{ElapsedNs: 592*sec + sec/2, Kind: "Pod", Type: EventPodReady, Job: "b1", Tenant: "tenant-b", GPUCount: 1, ObjectUID: "pod-b1"},
		{ElapsedNs: 650 * sec, Kind: "Job", Type: EventCompleted, Job: "b1", Tenant: "tenant-b", GPUCount: 1},
	}
}

func TestReconstructReclaimAny(t *testing.T) {
	horizon := 700 * sec
	res, err := Reconstruct("Any", reclaimAnyTrace(), reclaimAnyEvents(), horizon)
	if err != nil {
		t.Fatal(err)
	}

	if res.Offered != 3 {
		t.Fatalf("offered = %d, want 3 (the trace rows)", res.Offered)
	}
	if res.Admitted != 3 {
		t.Fatalf("all three jobs were admitted, got %d", res.Admitted)
	}
	if res.Completed != 2 {
		t.Fatalf("a1 and b1 complete, a2 preempted-not-completed, got completed=%d", res.Completed)
	}
	if res.UnfinishedAtHorizon != 1 {
		t.Fatalf("a2 is unfinished at the horizon, got %d", res.UnfinishedAtHorizon)
	}
	if !res.WaitP95FullyObserved {
		t.Fatalf("all offered jobs admitted, p95 should be fully observed")
	}

	byJob := map[string]WorkloadOutcome{}
	for _, o := range res.Outcomes {
		byJob[o.Job] = o
	}
	// b1 owner admission latency: 592 - 590 = 2s.
	if byJob["b1"].AdmitLatencyNs != 2*sec {
		t.Fatalf("b1 admit latency = %d ns, want %d", byJob["b1"].AdmitLatencyNs, 2*sec)
	}
	// a2 wasted GPU-seconds: measured from PodReady to the Pod actually stopping, not the preemption
	// decision, so 1 * (593 - 2.5) = 590.5, not 588.5. The stop was observed in-horizon, so it is EXACT.
	if got := byJob["a2"].WastedGPUSeconds; got < 590.4 || got > 590.6 {
		t.Fatalf("a2 wasted GPU-seconds = %.2f, want ~590.5", got)
	}
	if byJob["a2"].WasteCensored {
		t.Fatalf("a2 stop was observed in-horizon, waste must not be censored")
	}
	if byJob["a2"].Preemptions != 1 {
		t.Fatalf("a2 should have one preemption, got %d", byJob["a2"].Preemptions)
	}
	if res.AnyWasteCensored {
		t.Fatalf("no attempt was censored in this ledger")
	}
	if res.TotalWastedGPUSeconds < 590.4 {
		t.Fatalf("total wasted should include a2's discarded work, got %.2f", res.TotalWastedGPUSeconds)
	}
}

func TestWasteNoStopChargesToHorizonAsLowerBound(t *testing.T) {
	// No AttemptStopped was observed by the horizon. Under the fail-closed collector contract (every
	// terminal transition is observed or the run is invalidated), an absent stop means the attempt still
	// held the GPU at the horizon, so the floor is Ready->horizon, reported as a lower bound and flagged
	// censored, never as the exact total.
	trace := []TrainingTraceRow{{Index: 0, Name: "a2", OffsetMs: 0, Tenant: "tenant-a", GPUCount: 2, DurationSec: 300}}
	events := []LifecycleEvent{
		{ElapsedNs: 0, Kind: "MLTrainingJob", Type: EventSubmitted, Job: "a2", GPUCount: 2},
		{ElapsedNs: 1 * sec, Kind: "Workload", Type: EventAdmitted, Job: "a2", GPUCount: 2},
		{ElapsedNs: 2 * sec, Kind: "Pod", Type: EventPodReady, Job: "a2", GPUCount: 2, ObjectUID: "pod-a2"},
		{ElapsedNs: 100 * sec, Kind: "Workload", Type: EventPreempted, Job: "a2", GPUCount: 2, Reason: "InCohortReclamation"},
	}
	res, err := Reconstruct("Any", trace, events, 200*sec)
	if err != nil {
		t.Fatal(err)
	}
	if res.TotalWastedGPUSeconds != 0 {
		t.Fatalf("exact total must be 0 when no stop was observed, got %.2f", res.TotalWastedGPUSeconds)
	}
	// 2 GPUs * (200 - 2) = 396, the horizon floor.
	if got := res.TotalWasteLowerBoundGPUSeconds; got < 395.9 || got > 396.1 {
		t.Fatalf("lower-bound waste = %.2f, want ~396 (horizon floor)", got)
	}
	if !res.AnyWasteCensored {
		t.Fatalf("a run with an unobserved stop must be flagged censored")
	}
}

func TestReconstructRejectsAmbiguousPreemptionPairing(t *testing.T) {
	// Two attempts are both running when a preemption is decided (an inconsistent one-Pod history). A
	// Workload preemption delta names no Pod UID, so pairing is ambiguous; Reconstruct refuses rather than
	// heuristically charging one attempt's waste.
	trace := []TrainingTraceRow{{Index: 0, Name: "a2", OffsetMs: 0, Tenant: "tenant-a", GPUCount: 1, DurationSec: 300}}
	events := []LifecycleEvent{
		{ElapsedNs: 0, Kind: "MLTrainingJob", Type: EventSubmitted, Job: "a2", GPUCount: 1},
		{ElapsedNs: 1 * sec, Kind: "Workload", Type: EventAdmitted, Job: "a2", GPUCount: 1},
		{ElapsedNs: 10 * sec, Kind: "Pod", Type: EventPodReady, Job: "a2", GPUCount: 1, ObjectUID: "pod-A"},
		{ElapsedNs: 20 * sec, Kind: "Pod", Type: EventPodReady, Job: "a2", GPUCount: 1, ObjectUID: "pod-B"},
		{ElapsedNs: 30 * sec, Kind: "Workload", Type: EventPreempted, Job: "a2", GPUCount: 1, Reason: "InCohortReclamation"},
	}
	if _, err := Reconstruct("Any", trace, events, 100*sec); err == nil {
		t.Fatalf("two concurrently-running attempts at a preemption must error as ambiguous")
	}
}

func TestReconstructRejectsPostHorizonUnknownJob(t *testing.T) {
	// Corruption is rejected whether it lands before OR after the horizon: a post-horizon event for a job
	// not in the trace must still error, not be silently skipped by the horizon rule.
	trace := []TrainingTraceRow{{Index: 0, Name: "a1", OffsetMs: 0, Tenant: "tenant-a", GPUCount: 1, DurationSec: 10}}
	events := []LifecycleEvent{
		{ElapsedNs: 0, Kind: "MLTrainingJob", Type: EventSubmitted, Job: "a1", GPUCount: 1},
		{ElapsedNs: 500 * sec, Kind: "Pod", Type: EventAttemptStopped, Job: "ghost", GPUCount: 1, ObjectUID: "pod-x"},
	}
	if _, err := Reconstruct("Any", trace, events, 100*sec); err == nil {
		t.Fatalf("a post-horizon event for an unknown job must error")
	}
}

func TestWasteStopBeyondHorizonChargesToHorizon(t *testing.T) {
	// The stop is observed but beyond the horizon, so the attempt is KNOWN to have run through the horizon:
	// the lower bound includes the whole in-horizon interval (grace period included), still flagged.
	trace := []TrainingTraceRow{{Index: 0, Name: "a2", OffsetMs: 0, Tenant: "tenant-a", GPUCount: 1, DurationSec: 800}}
	events := []LifecycleEvent{
		{ElapsedNs: 0, Kind: "MLTrainingJob", Type: EventSubmitted, Job: "a2", GPUCount: 1},
		{ElapsedNs: 1 * sec, Kind: "Workload", Type: EventAdmitted, Job: "a2", GPUCount: 1},
		{ElapsedNs: 2 * sec, Kind: "Pod", Type: EventPodReady, Job: "a2", GPUCount: 1, ObjectUID: "pod-a2"},
		{ElapsedNs: 699 * sec, Kind: "Workload", Type: EventPreempted, Job: "a2", GPUCount: 1, Reason: "InCohortReclamation"},
		{ElapsedNs: 704 * sec, Kind: "Pod", Type: EventAttemptStopped, Job: "a2", GPUCount: 1, ObjectUID: "pod-a2"},
	}
	res, err := Reconstruct("Any", trace, events, 700*sec)
	if err != nil {
		t.Fatal(err)
	}
	if res.TotalWastedGPUSeconds != 0 {
		t.Fatalf("exact total must be 0 when the stop is beyond the horizon, got %.2f", res.TotalWastedGPUSeconds)
	}
	// 1 GPU * (700 - 2) = 698, the horizon floor including [699,700].
	if got := res.TotalWasteLowerBoundGPUSeconds; got < 697.9 || got > 698.1 {
		t.Fatalf("lower-bound waste = %.2f, want ~698 (horizon floor)", got)
	}
	if !res.AnyWasteCensored {
		t.Fatalf("a stop beyond the horizon must be flagged censored")
	}
}

func TestReconstructNeverHasNoWaste(t *testing.T) {
	// The "Never" arm: the owner waits instead of preempting, so nothing is discarded.
	trace := []TrainingTraceRow{
		{Index: 0, Name: "a2", OffsetMs: 0, Tenant: "tenant-a", GPUCount: 1, DurationSec: 600},
		{Index: 1, Name: "b1", OffsetMs: 590_000, Tenant: "tenant-b", GPUCount: 1, DurationSec: 60},
	}
	events := []LifecycleEvent{
		{ElapsedNs: 0, Kind: "MLTrainingJob", Type: EventSubmitted, Job: "a2", Tenant: "tenant-a", GPUCount: 1},
		{ElapsedNs: 1 * sec, Kind: "Workload", Type: EventAdmitted, Job: "a2", Tenant: "tenant-a", GPUCount: 1},
		{ElapsedNs: 2 * sec, Kind: "Pod", Type: EventPodReady, Job: "a2", Tenant: "tenant-a", GPUCount: 1, ObjectUID: "pod-a2"},
		{ElapsedNs: 600 * sec, Kind: "Job", Type: EventCompleted, Job: "a2", Tenant: "tenant-a", GPUCount: 1},
		{ElapsedNs: 590 * sec, Kind: "MLTrainingJob", Type: EventSubmitted, Job: "b1", Tenant: "tenant-b", GPUCount: 1},
	}
	res, err := Reconstruct("Never", trace, events, 700*sec)
	if err != nil {
		t.Fatal(err)
	}
	if res.TotalWastedGPUSeconds != 0 {
		t.Fatalf("Never arm should waste nothing, got %.2f", res.TotalWastedGPUSeconds)
	}
	// b1 is submitted but never admitted, so the arm is censored: p95 must NOT be marked fully observed, or
	// the fastest admitted survivor would be reported as the arm's p95.
	if res.WaitP95FullyObserved {
		t.Fatalf("only 1 of 2 offered jobs admitted, p95 must not be fully observed")
	}
	// b1 never admitted by the horizon -> unfinished + right-censored wait, not dropped.
	var b1 WorkloadOutcome
	for _, o := range res.Outcomes {
		if o.Job == "b1" {
			b1 = o
		}
	}
	if b1.Admitted {
		t.Fatalf("b1 should not be admitted in this censored case")
	}
	if b1.CensoredWaitNs != 700*sec-590*sec {
		t.Fatalf("b1 censored wait = %d, want %d", b1.CensoredWaitNs, 700*sec-590*sec)
	}
	if res.UnfinishedAtHorizon != 1 {
		t.Fatalf("b1 is unfinished, got %d", res.UnfinishedAtHorizon)
	}
}

func TestReconstructRejectsUnknownJob(t *testing.T) {
	// An event for a job not in the frozen trace means the collector joined to something the run did not
	// offer; that is corruption, so Reconstruct refuses rather than inventing a denominator entry.
	trace := []TrainingTraceRow{{Index: 0, Name: "a1", OffsetMs: 0, Tenant: "tenant-a", GPUCount: 1, DurationSec: 10}}
	events := []LifecycleEvent{
		{ElapsedNs: 0, Kind: "MLTrainingJob", Type: EventSubmitted, Job: "a1", GPUCount: 1},
		{ElapsedNs: 1 * sec, Kind: "Workload", Type: EventAdmitted, Job: "ghost", GPUCount: 1},
	}
	if _, err := Reconstruct("Any", trace, events, 100*sec); err == nil {
		t.Fatalf("an event for a job absent from the trace must error")
	}
}

func TestReconstructRejectsMissingSubmission(t *testing.T) {
	// Every offered row must carry a Submitted (written after a successful Create). A row with no submission
	// evidence means the job was never created, which invalidates the run instead of censoring it.
	trace := []TrainingTraceRow{{Index: 0, Name: "a1", OffsetMs: 0, Tenant: "tenant-a", GPUCount: 1, DurationSec: 10}}
	if _, err := Reconstruct("Any", trace, nil, 100*sec); err == nil {
		t.Fatalf("a trace row with no Submitted event must error")
	}
}

func TestReconstructRejectsAdmittedBeforeSubmitted(t *testing.T) {
	// Independent GVR watchers could journal an admission before the submission; a real run cannot admit
	// what was never submitted, so this impossible ordering is an error, not a negative latency.
	trace := []TrainingTraceRow{{Index: 0, Name: "a1", OffsetMs: 0, Tenant: "tenant-a", GPUCount: 1, DurationSec: 10}}
	events := []LifecycleEvent{
		{ElapsedNs: 5 * sec, Kind: "MLTrainingJob", Type: EventSubmitted, Job: "a1", GPUCount: 1},
		{ElapsedNs: 1 * sec, Kind: "Workload", Type: EventAdmitted, Job: "a1", GPUCount: 1},
	}
	if _, err := Reconstruct("Any", trace, events, 100*sec); err == nil {
		t.Fatalf("admitted-before-submitted must error")
	}
}

func TestReconstructRejectsUnpairedPreemption(t *testing.T) {
	// A preemption decision with no attempt running at that time cannot be attributed to discarded work;
	// silently charging zero would hide a collector gap, so it errors.
	trace := []TrainingTraceRow{{Index: 0, Name: "a1", OffsetMs: 0, Tenant: "tenant-a", GPUCount: 1, DurationSec: 10}}
	events := []LifecycleEvent{
		{ElapsedNs: 0, Kind: "MLTrainingJob", Type: EventSubmitted, Job: "a1", GPUCount: 1},
		{ElapsedNs: 1 * sec, Kind: "Workload", Type: EventAdmitted, Job: "a1", GPUCount: 1},
		{ElapsedNs: 5 * sec, Kind: "Workload", Type: EventPreempted, Job: "a1", GPUCount: 1},
	}
	if _, err := Reconstruct("Any", trace, events, 100*sec); err == nil {
		t.Fatalf("a preemption with no running attempt must error")
	}
}

func TestLedgerJSONLRoundTrip(t *testing.T) {
	var buf bytes.Buffer
	if err := exputil.WriteJSONL(&buf, reclaimAnyEvents()); err != nil {
		t.Fatal(err)
	}
	got, err := exputil.ReadJSONL[LifecycleEvent](bytes.NewReader(buf.Bytes()))
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != len(reclaimAnyEvents()) {
		t.Fatalf("round-trip lost events: %d vs %d", len(got), len(reclaimAnyEvents()))
	}
}

// ineffectivePreemptionEvents is the case the live run actually produced: a preemption is decided while the
// borrower runs, but the borrower ignores the signal and reaches a terminal Succeeded phase on its own.
func ineffectivePreemptionEvents() []LifecycleEvent {
	return []LifecycleEvent{
		{ElapsedNs: 0, Kind: "MLTrainingJob", Type: EventSubmitted, Job: "a1", Tenant: "tenant-a", GPUCount: 1},
		{ElapsedNs: 1 * sec, Kind: "Workload", Type: EventAdmitted, Job: "a1", Tenant: "tenant-a", GPUCount: 1},
		{ElapsedNs: 2 * sec, Kind: "Pod", Type: EventPodReady, Job: "a1", Tenant: "tenant-a", GPUCount: 1, ObjectUID: "pod-a1"},
		{ElapsedNs: 601 * sec, Kind: "Job", Type: EventCompleted, Job: "a1", Tenant: "tenant-a", GPUCount: 1},

		{ElapsedNs: 1 * sec, Kind: "MLTrainingJob", Type: EventSubmitted, Job: "a2", Tenant: "tenant-a", GPUCount: 1},
		{ElapsedNs: 2 * sec, Kind: "Workload", Type: EventAdmitted, Job: "a2", Tenant: "tenant-a", GPUCount: 1},
		{ElapsedNs: 3 * sec, Kind: "Pod", Type: EventPodReady, Job: "a2", Tenant: "tenant-a", GPUCount: 1, ObjectUID: "pod-a2"},
		{ElapsedNs: 34 * sec, Kind: "Workload", Type: EventPreempted, Job: "a2", Tenant: "tenant-a", GPUCount: 1, Reason: "InCohortReclamation"},
		// The workload ignored the signal and finished its own service, so this stop was NOT caused by the
		// preemption and its occupancy must not be reported as discarded work.
		{ElapsedNs: 43 * sec, Kind: "Pod", Type: EventAttemptStopped, Job: "a2", Tenant: "tenant-a", GPUCount: 1, ObjectUID: "pod-a2", Reason: StopReasonSucceeded},

		{ElapsedNs: 34 * sec, Kind: "MLTrainingJob", Type: EventSubmitted, Job: "b1", Tenant: "tenant-b", GPUCount: 1},
		{ElapsedNs: 34 * sec, Kind: "Workload", Type: EventAdmitted, Job: "b1", Tenant: "tenant-b", GPUCount: 1},
		{ElapsedNs: 44 * sec, Kind: "Pod", Type: EventPodReady, Job: "b1", Tenant: "tenant-b", GPUCount: 1, ObjectUID: "pod-b1"},
		{ElapsedNs: 90 * sec, Kind: "Job", Type: EventCompleted, Job: "b1", Tenant: "tenant-b", GPUCount: 1},
	}
}

func TestReconstructDoesNotChargeIneffectivePreemptionAsWaste(t *testing.T) {
	res, err := Reconstruct("Any", reclaimAnyTrace(), ineffectivePreemptionEvents(), 200*sec)
	if err != nil {
		t.Fatal(err)
	}
	var a2 WorkloadOutcome
	for _, o := range res.Outcomes {
		if o.Job == "a2" {
			a2 = o
		}
	}
	if a2.Preemptions != 1 {
		t.Fatalf("a2 preemptions = %d, want 1", a2.Preemptions)
	}
	if a2.WastedGPUSeconds != 0 {
		t.Fatalf("a2 waste = %.1f, want 0: a Succeeded stop is not preemption-caused loss", a2.WastedGPUSeconds)
	}
	if a2.WasteLowerBoundGPUSeconds != 0 {
		t.Fatalf("a2 waste lower bound = %.1f, want 0", a2.WasteLowerBoundGPUSeconds)
	}
	// The occupancy is still real and still reported, just not as discarded work.
	if got := a2.UnattributedOccupancyGPUSeconds; got != 40 {
		t.Fatalf("a2 unattributed occupancy = %.1f, want 40", got)
	}
	if !a2.PreemptionIneffective {
		t.Fatal("a2 must be flagged as an ineffective preemption")
	}
	if res.TotalWastedGPUSeconds != 0 {
		t.Fatalf("total waste = %.1f, want 0", res.TotalWastedGPUSeconds)
	}
	if res.TotalUnattributedOccupancyGPUSeconds != 40 {
		t.Fatalf("total unattributed occupancy = %.1f, want 40", res.TotalUnattributedOccupancyGPUSeconds)
	}
	if !res.AnyPreemptionIneffective {
		t.Fatal("result must flag that a preemption was ineffective")
	}
}

func TestReconstructChargesSignalledStopAsWaste(t *testing.T) {
	events := ineffectivePreemptionEvents()
	for i := range events {
		if events[i].Job == "a2" && events[i].Type == EventAttemptStopped {
			// A workload that honors the signal terminates non-zero, which IS attributable to the preemption.
			events[i].Reason = StopReasonFailed
		}
	}
	res, err := Reconstruct("Any", reclaimAnyTrace(), events, 200*sec)
	if err != nil {
		t.Fatal(err)
	}
	var a2 WorkloadOutcome
	for _, o := range res.Outcomes {
		if o.Job == "a2" {
			a2 = o
		}
	}
	if a2.WastedGPUSeconds != 40 {
		t.Fatalf("a2 waste = %.1f, want 40 for a signalled stop", a2.WastedGPUSeconds)
	}
	if a2.UnattributedOccupancyGPUSeconds != 0 {
		t.Fatalf("a2 unattributed occupancy = %.1f, want 0", a2.UnattributedOccupancyGPUSeconds)
	}
	if a2.PreemptionIneffective {
		t.Fatal("a signalled stop is an effective preemption")
	}
}

func TestReconstructAccountsForReExecution(t *testing.T) {
	events := ineffectivePreemptionEvents()
	// After the ineffective preemption the victim was re-admitted and re-executed its whole service, which
	// is the occupancy a report showing only the first attempt would hide.
	events = append(events,
		LifecycleEvent{ElapsedNs: 45 * sec, Kind: "Workload", Type: EventAdmitted, Job: "a2", Tenant: "tenant-a", GPUCount: 1},
		LifecycleEvent{ElapsedNs: 46 * sec, Kind: "Pod", Type: EventPodReady, Job: "a2", Tenant: "tenant-a", GPUCount: 1, ObjectUID: "pod-a2-retry"},
		LifecycleEvent{ElapsedNs: 87 * sec, Kind: "Pod", Type: EventAttemptStopped, Job: "a2", Tenant: "tenant-a", GPUCount: 1, ObjectUID: "pod-a2-retry", Reason: StopReasonSucceeded},
		LifecycleEvent{ElapsedNs: 88 * sec, Kind: "Job", Type: EventCompleted, Job: "a2", Tenant: "tenant-a", GPUCount: 1},
	)
	res, err := Reconstruct("Any", reclaimAnyTrace(), events, 200*sec)
	if err != nil {
		t.Fatal(err)
	}
	var a2 WorkloadOutcome
	for _, o := range res.Outcomes {
		if o.Job == "a2" {
			a2 = o
		}
	}
	if a2.Attempts != 2 {
		t.Fatalf("a2 attempts = %d, want 2", a2.Attempts)
	}
	if !a2.ReExecuted {
		t.Fatal("a2 must be flagged as re-executed")
	}
	// 40 s for the first attempt (3 s -> 43 s) plus 41 s for the second (46 s -> 87 s).
	if got := a2.TotalOccupancyGPUSeconds; got != 81 {
		t.Fatalf("a2 total occupancy = %.1f, want 81", got)
	}
	// a1 ran once and must not be flagged.
	for _, o := range res.Outcomes {
		if o.Job == "a1" && o.ReExecuted {
			t.Fatal("a1 ran a single attempt and must not be flagged as re-executed")
		}
	}
}

func TestReconstructChargesUnstoppedAttemptOccupancyToHorizon(t *testing.T) {
	// No AttemptStopped observed by the horizon.
	// Occupancy is charged only from ready (3s) to the horizon (50s), without overflow.
	// WasteCensored flags the censored lower bound of an unobserved stop.
	events := ineffectivePreemptionEvents()
	var filtered []LifecycleEvent
	for _, e := range events {
		// Exclude a2's EventAttemptStopped to simulate an attempt never observed stopping.
		if e.Job == "a2" && e.Type == EventAttemptStopped {
			continue
		}
		filtered = append(filtered, e)
	}
	res, err := Reconstruct("Any", reclaimAnyTrace(), filtered, 50*sec)
	if err != nil {
		t.Fatal(err)
	}
	var a2 WorkloadOutcome
	for _, o := range res.Outcomes {
		if o.Job == "a2" {
			a2 = o
		}
	}
	// Ready at 3s, horizon at 50s: 1 GPU * (50 - 3) = 47.
	if a2.TotalOccupancyGPUSeconds != 47 {
		t.Fatalf("a2 occupancy = %.1f, want 47 (ready at 3s, charged to 50s horizon)", a2.TotalOccupancyGPUSeconds)
	}
	// An attempt with no in-horizon stop is a censored lower bound.
	if !a2.WasteCensored {
		t.Fatalf("a2 must be flagged censored when no stop was observed by horizon")
	}
}

func TestReconstructChargesPostHorizonStopOccupancyToHorizon(t *testing.T) {
	// An in-horizon ready (3s) with a post-horizon stop (60s) observed.
	// Occupancy is charged only from ready to the horizon, same as no stop at all.
	// A stop beyond the horizon must be charged as if it still ran through the boundary.
	events := ineffectivePreemptionEvents()
	for i := range events {
		if events[i].Job == "a2" && events[i].Type == EventAttemptStopped {
			// Move the stop beyond the horizon.
			events[i].ElapsedNs = 60 * sec
		}
	}
	res, err := Reconstruct("Any", reclaimAnyTrace(), events, 50*sec)
	if err != nil {
		t.Fatal(err)
	}
	var a2 WorkloadOutcome
	for _, o := range res.Outcomes {
		if o.Job == "a2" {
			a2 = o
		}
	}
	// Ready at 3s, horizon at 50s: 1 GPU * (50 - 3) = 47.
	// Post-horizon stop does not extend the charged interval.
	if a2.TotalOccupancyGPUSeconds != 47 {
		t.Fatalf("a2 occupancy = %.1f, want 47 (ready at 3s, charged to 50s horizon, post-horizon stop)", a2.TotalOccupancyGPUSeconds)
	}
	// A post-horizon stop means the attempt definitely ran through the horizon, so it is censored.
	if !a2.WasteCensored {
		t.Fatalf("a2 must be flagged censored when stop is observed beyond horizon")
	}
}

func TestReconstructRecordsAdmissionToExecutionGap(t *testing.T) {
	res, err := Reconstruct("Any", reclaimAnyTrace(), ineffectivePreemptionEvents(), 200*sec)
	if err != nil {
		t.Fatal(err)
	}
	var b1 WorkloadOutcome
	for _, o := range res.Outcomes {
		if o.Job == "b1" {
			b1 = o
		}
	}
	if !b1.Executed {
		t.Fatal("b1 reached Pod Ready and must be marked executed")
	}
	// Submitted at 34 s, admitted at 34 s, Pod Ready at 44 s: admission is a quota reservation and says
	// nothing about when execution began.
	if b1.AdmitLatencyNs != 0 {
		t.Fatalf("b1 admit latency = %d, want 0", b1.AdmitLatencyNs)
	}
	if b1.ReadyLatencyNs != 10*sec {
		t.Fatalf("b1 ready latency = %d, want %d", b1.ReadyLatencyNs, 10*sec)
	}
	if b1.AdmitToReadyNs != 10*sec {
		t.Fatalf("b1 admit-to-ready gap = %d, want %d", b1.AdmitToReadyNs, 10*sec)
	}
}

func TestReconstructLeavesGapZeroWhenNeverExecuted(t *testing.T) {
	events := ineffectivePreemptionEvents()
	kept := events[:0]
	for _, e := range events {
		if e.Job == "b1" && (e.Type == EventPodReady || e.Type == EventCompleted) {
			continue
		}
		kept = append(kept, e)
	}
	res, err := Reconstruct("Any", reclaimAnyTrace(), kept, 200*sec)
	if err != nil {
		t.Fatal(err)
	}
	for _, o := range res.Outcomes {
		if o.Job != "b1" {
			continue
		}
		if o.Executed {
			t.Fatal("b1 never reached Pod Ready and must not be marked executed")
		}
		if o.ReadyLatencyNs != 0 || o.AdmitToReadyNs != 0 {
			t.Fatalf("b1 gaps must stay zero when unexecuted, got ready=%d gap=%d", o.ReadyLatencyNs, o.AdmitToReadyNs)
		}
	}
}

