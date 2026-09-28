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

package main

import (
	"strings"
	"testing"
)

// The reading the registration demanded in those words: verify by reading allocatable BACK, not by trusting the
// manifest.
//
// A DaemonSet that never became ready, an image that would not pull, a label that did not reach the kubelet and
// a registration the kubelet refused all leave the manifest saying one thing and the node saying another. Only
// the node's word decides where the scheduler can place, so a label-only check would qualify a cluster with no
// capacity at all.
//
// Mutation that turns this red: compare labels to labels and drop the allocatable comparison.
func TestACapacityTheClusterDoesNotAdvertiseIsRefused(t *testing.T) {
	want := NodeLayout{2, 1, 1}
	// Every label is right and one plugin never came up.
	got := []ObservedNode{
		{Name: "w1", Labelled: 2, Present: true, Allocatable: 2},
		{Name: "w2", Labelled: 1, Present: true, Allocatable: 1},
		{Name: "w3", Labelled: 1, Present: true, Allocatable: 0},
	}
	err := VerifyLayout(want, got)
	if err == nil {
		t.Fatal("a node advertising nothing under a label promising one device was accepted")
	}
	if !strings.Contains(err.Error(), "w3 labelled 1 advertises 0") {
		t.Errorf("the refusal does not name the node or the discrepancy: %v", err)
	}
	if !strings.Contains(err.Error(), "the manifest is not evidence about capacity") {
		t.Errorf("the refusal does not say why the label alone is insufficient: %v", err)
	}
	// And the same cluster, once the plugin is up, passes.
	got[2].Allocatable = 1
	if err := VerifyLayout(want, got); err != nil {
		t.Errorf("a cluster advertising exactly the registered layout was refused: %v", err)
	}
}

// An unlabelled worker is refused rather than treated as a node with no capacity.
//
// The device plugin selects on the label, so an unlabelled worker advertises nothing -- and its emptiness would
// read as capacity this study had reserved, which is the exact inversion the census must never make.
//
// Mutation that turns this red: skip nodes whose label is absent.
func TestAnUnlabelledWorkerIsRefusedRatherThanReadAsEmpty(t *testing.T) {
	err := VerifyLayout(NodeLayout{2, 1}, []ObservedNode{
		{Name: "w1", Labelled: 2, Present: true, Allocatable: 2},
		{Name: "w2", Present: false, Allocatable: 0},
	})
	if err == nil {
		t.Fatal("a worker with no device-count label was accepted")
	}
	if !strings.Contains(err.Error(), "w2") || !strings.Contains(err.Error(), NodeLabelKey) {
		t.Errorf("the refusal names neither the node nor the label: %v", err)
	}
}

// The cluster must hold exactly the sizes the layout registered -- no more, no fewer.
//
// An extra worker of any size changes which requests can be placed, so a cluster that merely CONTAINS the
// registered layout is not the registered layout.
//
// Mutation that turns this red: check only that every wanted size is present.
func TestAClusterWithAnExtraSizeIsNotTheOneRegistered(t *testing.T) {
	err := VerifyLayout(NodeLayout{1, 1}, []ObservedNode{
		{Name: "w1", Labelled: 1, Present: true, Allocatable: 1},
		{Name: "w2", Labelled: 1, Present: true, Allocatable: 1},
		{Name: "w3", Labelled: 4, Present: true, Allocatable: 4},
	})
	if err == nil {
		t.Fatal("a cluster with an unregistered worker size was accepted")
	}
	if !strings.Contains(err.Error(), "changes which requests can be placed") {
		t.Errorf("the refusal does not say why an extra size matters: %v", err)
	}

	// Too few of a size is the same defect in the other direction.
	err = VerifyLayout(NodeLayout{1, 1, 1}, []ObservedNode{
		{Name: "w1", Labelled: 1, Present: true, Allocatable: 1},
		{Name: "w2", Labelled: 1, Present: true, Allocatable: 1},
	})
	if err == nil {
		t.Fatal("a cluster missing a registered worker was accepted")
	}
	if !strings.Contains(err.Error(), "not the one registered") {
		t.Errorf("the refusal does not name the mismatch: %v", err)
	}
}

// An empty census is a census that did not happen, not a cluster with no capacity.
//
// This is the shape the whole study keeps guarding against: an absent observation reading as a negative one.
//
// Mutation that turns this red: return nil for an empty observation slice.
func TestAnEmptyCensusIsNotAClusterWithNoCapacity(t *testing.T) {
	err := VerifyLayout(NodeLayout{1, 1}, nil)
	if err == nil {
		t.Fatal("an empty reading was accepted as a verified layout")
	}
	if !strings.Contains(err.Error(), "census that did not happen") {
		t.Errorf("an empty census was not distinguished from an empty cluster: %v", err)
	}
}

// The witness request separates fragmentation from aggregate shortage, which the original registration
// conflated.
//
// With free counts [1,1] a request for 3 is blocked because the cluster does not have three devices at all;
// counting that as stranding reports a shortage as a placement problem. The witness is the smallest q with
// max(f_i) < q <= sum(f_i) -- the weakest demand that still demonstrates the phenomenon.
//
// Mutation that turns this red: return maxFree, or drop the q > total guard.
func TestTheWitnessRequestSeparatesFragmentationFromShortage(t *testing.T) {
	for _, tc := range []struct {
		name string
		free []int
		want int
		ok   bool
	}{
		{"two singletons: a two-device request is blocked with two free", []int{1, 1}, 2, true},
		{"the amendment's own example", []int{1, 4}, 5, true},
		{"everything free on one node cannot strand", []int{0, 3}, 0, false},
		{"one node only", []int{4}, 0, false},
		{"nothing free anywhere", []int{0, 0}, 0, false},
		{"three singletons", []int{1, 1, 1}, 2, true},
		{"no nodes at all", nil, 0, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := WitnessRequest(tc.free)
			if ok != tc.ok {
				t.Fatalf("WitnessRequest(%v) ok = %v, want %v (got q=%d)", tc.free, ok, tc.ok, got)
			}
			if ok && got != tc.want {
				t.Errorf("WitnessRequest(%v) = %d, want %d", tc.free, got, tc.want)
			}
			if ok {
				// The property, restated from the amendment, so a future edit cannot satisfy the table while
				// breaking the definition.
				maxFree, total := 0, 0
				for _, f := range tc.free {
					if f > maxFree {
						maxFree = f
					}
					total += f
				}
				// Spelled as the negation of each half rather than as !(a && b). The amendment states the
				// property as max(f_i) < q <= sum(f_i) and the first draft mirrored that text exactly, which
				// staticcheck rejects; the condition below is the same predicate, and the sentence it checks
				// stays readable in the failure message rather than in the expression.
				if maxFree >= got || got > total {
					t.Errorf("q=%d violates max(f_i)=%d < q <= sum(f_i)=%d", got, maxFree, total)
				}
			}
		})
	}
}
