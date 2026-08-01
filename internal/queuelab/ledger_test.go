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

// reclaimAnyEvents is a synthetic ledger for the reclaim "Any", late-owner-return case:
// a1 runs to completion; a2 borrows then is preempted late (its work discarded); b1 the owner is
// admitted quickly after the preemption and completes.
func reclaimAnyEvents() []LifecycleEvent {
	return []LifecycleEvent{
		{ElapsedNs: 0, Kind: "MLTrainingJob", Type: EventSubmitted, Job: "a1", Tenant: "tenant-a", GPUCount: 1},
		{ElapsedNs: 1 * sec, Kind: "Workload", Type: EventAdmitted, Job: "a1", Tenant: "tenant-a", GPUCount: 1},
		{ElapsedNs: 1*sec + sec/2, Kind: "Pod", Type: EventPodReady, Job: "a1", Tenant: "tenant-a", GPUCount: 1},
		{ElapsedNs: 601 * sec, Kind: "Job", Type: EventCompleted, Job: "a1", Tenant: "tenant-a", GPUCount: 1},

		{ElapsedNs: 1 * sec, Kind: "MLTrainingJob", Type: EventSubmitted, Job: "a2", Tenant: "tenant-a", GPUCount: 1},
		{ElapsedNs: 2 * sec, Kind: "Workload", Type: EventAdmitted, Job: "a2", Tenant: "tenant-a", GPUCount: 1},
		{ElapsedNs: 2*sec + sec/2, Kind: "Pod", Type: EventPodReady, Job: "a2", Tenant: "tenant-a", GPUCount: 1},
		{ElapsedNs: 591 * sec, Kind: "Workload", Type: EventPreempted, Job: "a2", Tenant: "tenant-a", GPUCount: 1},
		// The Pod does not stop the instant Kueue decides to preempt; it keeps running through the
		// termination grace window and only stops here, so the discarded work is measured up to this point.
		{ElapsedNs: 593 * sec, Kind: "Pod", Type: EventAttemptStopped, Job: "a2", Tenant: "tenant-a", GPUCount: 1},

		{ElapsedNs: 590 * sec, Kind: "MLTrainingJob", Type: EventSubmitted, Job: "b1", Tenant: "tenant-b", GPUCount: 1},
		{ElapsedNs: 592 * sec, Kind: "Workload", Type: EventAdmitted, Job: "b1", Tenant: "tenant-b", GPUCount: 1},
		{ElapsedNs: 592*sec + sec/2, Kind: "Pod", Type: EventPodReady, Job: "b1", Tenant: "tenant-b", GPUCount: 1},
		{ElapsedNs: 650 * sec, Kind: "Job", Type: EventCompleted, Job: "b1", Tenant: "tenant-b", GPUCount: 1},
	}
}

func TestReconstructReclaimAny(t *testing.T) {
	horizon := 700 * sec
	res := Reconstruct("Any", reclaimAnyEvents(), horizon)

	if res.Admitted != 3 {
		t.Fatalf("all three jobs were admitted, got %d", res.Admitted)
	}
	if res.Completed != 2 {
		t.Fatalf("a1 and b1 complete, a2 preempted-not-completed, got completed=%d", res.Completed)
	}
	if res.UnfinishedAtHorizon != 1 {
		t.Fatalf("a2 is unfinished at the horizon, got %d", res.UnfinishedAtHorizon)
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
	// decision, so 1 * (593 - 2.5) = 590.5, not 588.5.
	if got := byJob["a2"].WastedGPUSeconds; got < 590.4 || got > 590.6 {
		t.Fatalf("a2 wasted GPU-seconds = %.2f, want ~590.5", got)
	}
	if byJob["a2"].Preemptions != 1 {
		t.Fatalf("a2 should have one preemption, got %d", byJob["a2"].Preemptions)
	}
	if res.TotalWastedGPUSeconds < 590.4 {
		t.Fatalf("total wasted should include a2's discarded work, got %.2f", res.TotalWastedGPUSeconds)
	}
}

func TestWasteFallsBackToDecisionWhenNoStopObserved(t *testing.T) {
	// If the collector never observed the Pod stopping (e.g. the watch desynced right after the
	// preemption decision), waste falls back to the decision time as a conservative lower bound rather
	// than being dropped to zero, so a missing AttemptStopped never flatters the preempting policy.
	events := []LifecycleEvent{
		{ElapsedNs: 0, Kind: "MLTrainingJob", Type: EventSubmitted, Job: "a2", Tenant: "tenant-a", GPUCount: 2},
		{ElapsedNs: 1 * sec, Kind: "Workload", Type: EventAdmitted, Job: "a2", Tenant: "tenant-a", GPUCount: 2},
		{ElapsedNs: 2 * sec, Kind: "Pod", Type: EventPodReady, Job: "a2", Tenant: "tenant-a", GPUCount: 2},
		{ElapsedNs: 100 * sec, Kind: "Workload", Type: EventPreempted, Job: "a2", Tenant: "tenant-a", GPUCount: 2},
		// No AttemptStopped event: the Pod stop was never seen.
	}
	res := Reconstruct("Any", events, 200*sec)
	// 2 GPUs * (100 - 2) = 196, using the decision time as the lower bound.
	if got := res.TotalWastedGPUSeconds; got < 195.9 || got > 196.1 {
		t.Fatalf("fallback waste = %.2f, want ~196 (decision time as lower bound)", got)
	}
}

func TestReconstructNeverHasNoWaste(t *testing.T) {
	// The "Never" arm: the owner waits instead of preempting, so nothing is discarded.
	events := []LifecycleEvent{
		{ElapsedNs: 0, Kind: "MLTrainingJob", Type: EventSubmitted, Job: "a2", Tenant: "tenant-a", GPUCount: 1},
		{ElapsedNs: 1 * sec, Kind: "Workload", Type: EventAdmitted, Job: "a2", Tenant: "tenant-a", GPUCount: 1},
		{ElapsedNs: 2 * sec, Kind: "Pod", Type: EventPodReady, Job: "a2", Tenant: "tenant-a", GPUCount: 1},
		{ElapsedNs: 600 * sec, Kind: "Job", Type: EventCompleted, Job: "a2", Tenant: "tenant-a", GPUCount: 1},
		{ElapsedNs: 590 * sec, Kind: "MLTrainingJob", Type: EventSubmitted, Job: "b1", Tenant: "tenant-b", GPUCount: 1},
	}
	res := Reconstruct("Never", events, 700*sec)
	if res.TotalWastedGPUSeconds != 0 {
		t.Fatalf("Never arm should waste nothing, got %.2f", res.TotalWastedGPUSeconds)
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
