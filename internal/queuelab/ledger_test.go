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
		{ObservedUnixNanos: 0, Kind: "MLTrainingJob", Type: EventSubmitted, Job: "a1", Tenant: "tenant-a", GPUCount: 1},
		{ObservedUnixNanos: 1 * sec, Kind: "Workload", Type: EventAdmitted, Job: "a1", Tenant: "tenant-a", GPUCount: 1},
		{ObservedUnixNanos: 1*sec + sec/2, Kind: "Pod", Type: EventPodReady, Job: "a1", Tenant: "tenant-a", GPUCount: 1},
		{ObservedUnixNanos: 601 * sec, Kind: "Job", Type: EventCompleted, Job: "a1", Tenant: "tenant-a", GPUCount: 1},

		{ObservedUnixNanos: 1 * sec, Kind: "MLTrainingJob", Type: EventSubmitted, Job: "a2", Tenant: "tenant-a", GPUCount: 1},
		{ObservedUnixNanos: 2 * sec, Kind: "Workload", Type: EventAdmitted, Job: "a2", Tenant: "tenant-a", GPUCount: 1},
		{ObservedUnixNanos: 2*sec + sec/2, Kind: "Pod", Type: EventPodReady, Job: "a2", Tenant: "tenant-a", GPUCount: 1},
		{ObservedUnixNanos: 591 * sec, Kind: "Workload", Type: EventPreempted, Job: "a2", Tenant: "tenant-a", GPUCount: 1},

		{ObservedUnixNanos: 590 * sec, Kind: "MLTrainingJob", Type: EventSubmitted, Job: "b1", Tenant: "tenant-b", GPUCount: 1},
		{ObservedUnixNanos: 592 * sec, Kind: "Workload", Type: EventAdmitted, Job: "b1", Tenant: "tenant-b", GPUCount: 1},
		{ObservedUnixNanos: 592*sec + sec/2, Kind: "Pod", Type: EventPodReady, Job: "b1", Tenant: "tenant-b", GPUCount: 1},
		{ObservedUnixNanos: 650 * sec, Kind: "Job", Type: EventCompleted, Job: "b1", Tenant: "tenant-b", GPUCount: 1},
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
	// a2 wasted GPU-seconds: 1 * (591 - 2.5) = 588.5.
	if got := byJob["a2"].WastedGPUSeconds; got < 588.4 || got > 588.6 {
		t.Fatalf("a2 wasted GPU-seconds = %.2f, want ~588.5", got)
	}
	if byJob["a2"].Preemptions != 1 {
		t.Fatalf("a2 should have one preemption, got %d", byJob["a2"].Preemptions)
	}
	if res.TotalWastedGPUSeconds < 588.4 {
		t.Fatalf("total wasted should include a2's discarded work, got %.2f", res.TotalWastedGPUSeconds)
	}
}

func TestReconstructNeverHasNoWaste(t *testing.T) {
	// The "Never" arm: the owner waits instead of preempting, so nothing is discarded.
	events := []LifecycleEvent{
		{ObservedUnixNanos: 0, Kind: "MLTrainingJob", Type: EventSubmitted, Job: "a2", Tenant: "tenant-a", GPUCount: 1},
		{ObservedUnixNanos: 1 * sec, Kind: "Workload", Type: EventAdmitted, Job: "a2", Tenant: "tenant-a", GPUCount: 1},
		{ObservedUnixNanos: 2 * sec, Kind: "Pod", Type: EventPodReady, Job: "a2", Tenant: "tenant-a", GPUCount: 1},
		{ObservedUnixNanos: 600 * sec, Kind: "Job", Type: EventCompleted, Job: "a2", Tenant: "tenant-a", GPUCount: 1},
		{ObservedUnixNanos: 590 * sec, Kind: "MLTrainingJob", Type: EventSubmitted, Job: "b1", Tenant: "tenant-b", GPUCount: 1},
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
