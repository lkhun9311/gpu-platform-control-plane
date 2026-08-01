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

// Package queuelab replays deterministic MLTrainingJob traces against a real Kueue on kind and compares
// one queue-policy knob at a time (reclaim, FIFO), using a list/watch lifecycle ledger as the authority.
//
// The traces here are HANDCRAFTED and deterministic, not random: a mechanism experiment must reliably
// exercise late reclaim or FIFO head-of-line blocking, which a random arrival process does poorly.
package queuelab

import (
	"fmt"
	"io"
	"sort"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/exputil"
)

// TrainingTraceRow is one scheduled training submission in an immutable trace.
//
// It carries only what is fixed before a run starts: when the job is submitted, who submits it, how much
// GPU quota it requests, and how long its service would take uninterrupted.
type TrainingTraceRow struct {
	// Index is the row's stable position, used to join raw ledger events back to the trace.
	Index int `json:"index"`
	// Name is a stable per-run job name, so the ledger can attribute events without guessing.
	Name string `json:"name"`
	// OffsetMs is the submission time as a millisecond offset from the run start; offsets are non-decreasing.
	OffsetMs int64 `json:"offsetMs"`
	// Tenant is the submitting tenant, which resolves to its own LocalQueue.
	Tenant string `json:"tenant"`
	// GPUCount is the requested nvidia.com/gpu units (fake capacity on kind).
	GPUCount int `json:"gpuCount"`
	// DurationSec is the uninterrupted service time; the sleeper runs this long unless preempted.
	DurationSec int `json:"durationSec"`
}

// ReclaimScenario builds the trace for the reclaim study (Never vs Any).
//
// Capacity is one nominal unit per tenant in a shared cohort (total 2). Tenant A fills its own unit, then
// borrows tenant B's idle unit, then tenant B submits and forces the borrowed unit's fate.
//
// lateReturn places tenant B's arrival near the end of the borrowed job's service, where preempting it
// discards almost a whole job of work; an early return makes preemption nearly free. That contrast is the
// study's whole point, so both are generated from the same builder.
func ReclaimScenario(lateReturn bool, durationSec int) []TrainingTraceRow {
	ownerOffsetMs := int64(5_000)
	if lateReturn {
		// Return with only a small remainder of the borrowed job's service left.
		ownerOffsetMs = int64(durationSec)*1000 - 10_000
	}
	return []TrainingTraceRow{
		{Index: 0, Name: "a1", OffsetMs: 0, Tenant: "tenant-a", GPUCount: 1, DurationSec: durationSec},
		{Index: 1, Name: "a2-borrow", OffsetMs: 1_000, Tenant: "tenant-a", GPUCount: 1, DurationSec: durationSec},
		{Index: 2, Name: "b1-owner", OffsetMs: ownerOffsetMs, Tenant: "tenant-b", GPUCount: 1, DurationSec: durationSec},
	}
}

// FIFOHeadOfLineScenario builds the trace for the FIFO study (StrictFIFO vs BestEffortFIFO).
//
// Capacity is 2 units for one tenant's queue. A long 1-GPU job holds one unit; a 2-GPU job then queues at
// the head and cannot currently fit; several 1-GPU jobs arrive behind it. StrictFIFO leaves the free unit
// idle to protect the head job's position, while BestEffortFIFO lets the younger fitting jobs bypass it.
//
// The critical arrivals are spaced far enough apart that the asynchronous MLTrainingJob -> Job -> Workload
// creation cannot randomly reverse their intended queue order.
func FIFOHeadOfLineScenario(longDurationSec, smallDurationSec int) []TrainingTraceRow {
	rows := make([]TrainingTraceRow, 0, 5)
	rows = append(rows,
		TrainingTraceRow{Index: 0, Name: "long1", OffsetMs: 0, Tenant: "tenant-a", GPUCount: 1, DurationSec: longDurationSec},
		TrainingTraceRow{Index: 1, Name: "head2", OffsetMs: 3_000, Tenant: "tenant-a", GPUCount: 2, DurationSec: smallDurationSec},
	)
	for i := range 3 {
		rows = append(rows, TrainingTraceRow{
			Index:       2 + i,
			Name:        fmt.Sprintf("small%d", i+1),
			OffsetMs:    int64(6_000 + i*3_000),
			Tenant:      "tenant-a",
			GPUCount:    1,
			DurationSec: smallDurationSec,
		})
	}
	return rows
}

// WriteTrace serializes a trace as JSON Lines.
func WriteTrace(w io.Writer, rows []TrainingTraceRow) error {
	return exputil.WriteJSONL(w, rows)
}

// ReadTrace parses a JSON Lines trace and verifies the offsets are non-decreasing, so a hand-edited trace
// that reorders submissions is rejected rather than replayed out of order.
func ReadTrace(r io.Reader) ([]TrainingTraceRow, error) {
	rows, err := exputil.ReadJSONL[TrainingTraceRow](r)
	if err != nil {
		return nil, err
	}
	if !sort.SliceIsSorted(rows, func(i, j int) bool { return rows[i].OffsetMs < rows[j].OffsetMs }) {
		return nil, fmt.Errorf("trace offsets are not non-decreasing")
	}
	return rows, nil
}
