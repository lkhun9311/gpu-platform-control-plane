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
	if !res.WaitP95Estimable {
		t.Fatalf("all offered jobs admitted, p95 should be estimable")
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

func TestWasteNoStopChargesToDecisionAsLowerBound(t *testing.T) {
	// No AttemptStopped was observed, so the attempt could have stopped early in the grace window: the only
	// defensible floor is up to the preemption DECISION, reported as a lower bound and flagged censored,
	// never as the exact total.
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
	// 2 GPUs * (100 - 2) = 196, the decision-time floor.
	if got := res.TotalWasteLowerBoundGPUSeconds; got < 195.9 || got > 196.1 {
		t.Fatalf("lower-bound waste = %.2f, want ~196 (decision-time floor)", got)
	}
	if !res.AnyWasteCensored {
		t.Fatalf("a run with an unobserved stop must be flagged censored")
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
	// b1 is submitted but never admitted, so the arm is heavily censored: p95 must NOT be estimable, or the
	// fastest admitted survivor would be reported as the arm's p95.
	if res.WaitP95Estimable {
		t.Fatalf("only 1 of 2 offered jobs admitted, p95 must not be estimable")
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
