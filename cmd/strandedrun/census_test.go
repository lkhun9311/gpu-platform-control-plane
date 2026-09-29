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

// nodes is a small helper so a fixture reads as a free-capacity vector rather than as struct literals.
func nodes(spec ...[3]int) []NodeCapacity {
	names := []string{"w1", "w2", "w3", "w4"}
	out := make([]NodeCapacity, 0, len(spec))
	for i, s := range spec {
		out = append(out, NodeCapacity{Name: names[i], Allocatable: s[0], Reserved: s[1]})
	}
	return out
}

// The five qualification fixtures the amendment required be registered WITH their expected verdicts, rather
// than derived after the instrument had been run.
//
// Each is the shortest census that produces its outcome, and each outcome is a different statement: stranded,
// not stranded, short of capacity, idle, and unreadable. The last is the one the original validity rule could
// not tell from the fourth.
//
// Mutation that turns this red: any single one of the five judgements.
func TestTheFiveRegisteredQualificationFixtures(t *testing.T) {
	// The amendment's own example, and the node SIZE is what makes it stranding rather than shortage: "two
	// identical two-GPU nodes each holding one device already block a two-device request with two devices free".
	//
	// My first draft of this fixture used two one-device nodes, which is the shape the amendment classifies as
	// UNSATISFIABLE -- a request that would not fit on an empty node of the largest size was never a placement
	// problem. The code refused it correctly and this test was the thing that was wrong.
	t.Run("positive stranding: two half-empty two-device nodes and a two-device request", func(t *testing.T) {
		c := Census{
			Step: "qualify-positive", Settled: true,
			Nodes: nodes([3]int{2, 1, 0}, [3]int{2, 1, 0}),
			Submissions: []Submission{
				{Name: "holder-a", Request: 1, Disposition: DispositionBound, Node: "w1"},
				{Name: "holder-b", Request: 1, Disposition: DispositionBound, Node: "w2"},
				{Name: "wants-two", Request: 2, Disposition: DispositionQueuedUnadmitted},
			},
		}
		r, err := c.Report()
		if err != nil {
			t.Fatalf("the registered positive fixture was refused: %v", err)
		}
		if r.StrandedDevices != 2 {
			t.Errorf("StrandedDevices = %d, want 2: one device is free on each node and neither can host a "+
				"two-device request", r.StrandedDevices)
		}
		if len(r.Blocked) != 1 || r.Blocked[0] != "wants-two" {
			t.Errorf("Blocked = %v, want [wants-two]", r.Blocked)
		}
		if len(r.Unsatisfiable) != 0 {
			t.Errorf("Unsatisfiable = %v, want none: an empty node of the largest size holds 2, so the "+
				"request could have been placed and this is fragmentation rather than shortage", r.Unsatisfiable)
		}
		if !r.WitnessExists || r.WitnessRequest != 2 {
			t.Errorf("witness = %d (exists=%v), want 2: max(f_i)=1 < 2 <= sum(f_i)=2", r.WitnessRequest,
				r.WitnessExists)
		}
		if r.ReservedTotal != 2 || len(r.PlacedWorkloads) != 2 {
			t.Errorf("ReservedTotal=%d PlacedWorkloads=%v; the two holders are what make the free devices "+
				"unusable and the report has to name them", r.ReservedTotal, r.PlacedWorkloads)
		}
	})

	t.Run("schedulable demand must not count as stranded", func(t *testing.T) {
		// free [1,4], request 2: the original registration's table would report 1 stranded device. The
		// workload fits on the second node, so the registered figure is zero.
		c := Census{
			Step: "qualify-schedulable", Settled: true,
			Nodes: nodes([3]int{1, 0, 0}, [3]int{4, 0, 0}),
			Submissions: []Submission{
				{Name: "wants-two", Request: 2, Disposition: DispositionQueuedUnadmitted},
			},
		}
		r, err := c.Report()
		if err != nil {
			t.Fatalf("refused: %v", err)
		}
		if r.StrandedDevices != 0 {
			t.Errorf("StrandedDevices = %d, want 0: the request fits on w2", r.StrandedDevices)
		}
		if len(r.Blocked) != 0 {
			t.Errorf("Blocked = %v, want none", r.Blocked)
		}
		// And the diagnostic the original measured by mistake still reports its 1, under its own name, so the
		// difference between the two figures is visible rather than hidden.
		if r.UnusableGapSum != 1 {
			t.Errorf("UnusableGapSum = %d, want 1; this is the figure the original registration would have "+
				"published as the headline", r.UnusableGapSum)
		}
	})

	t.Run("aggregate shortage is not fragmentation", func(t *testing.T) {
		// free [1,1], request 3: blocked because the cluster never had three devices.
		c := Census{
			Step: "qualify-shortage", Settled: true,
			Nodes: nodes([3]int{1, 0, 0}, [3]int{1, 0, 0}),
			Submissions: []Submission{
				{Name: "wants-three", Request: 3, Disposition: DispositionQueuedUnadmitted},
			},
		}
		r, err := c.Report()
		if err != nil {
			t.Fatalf("refused: %v", err)
		}
		if len(r.Unsatisfiable) != 1 || r.Unsatisfiable[0] != "wants-three" {
			t.Errorf("Unsatisfiable = %v, want [wants-three]: no node of the largest size could ever host it",
				r.Unsatisfiable)
		}
		if len(r.Blocked) != 0 {
			t.Errorf("Blocked = %v; a request the cluster never had room for is short of capacity, not "+
				"fragmented", r.Blocked)
		}
		// The assertion the first draft of this test was missing, and its absence hid a real defect: q_min was
		// taken over ALL pending requests, so this fixture reported `unsatisfiable: wants-three` together with
		// a headline of 2 stranded devices. A request the cluster never had room for was making free capacity
		// read as fragmented -- the conflation the amendment corrected the original registration for, arriving
		// through the arithmetic instead of the prose.
		if r.StrandedDevices != 0 {
			t.Errorf("StrandedDevices = %d, want 0: the only pending request is beyond the largest node, so "+
				"there is no placement question and nothing is stranded", r.StrandedDevices)
		}
		if r.NoDemand {
			t.Error("NoDemand is true while a submission is pending; an unsatisfiable request is still demand " +
				"and this is not an idle cluster")
		}
		if r.OutstandingDemand != 3 {
			t.Errorf("OutstandingDemand = %d, want 3", r.OutstandingDemand)
		}
	})

	t.Run("empty demand is not stranding of zero", func(t *testing.T) {
		c := Census{
			Step: "qualify-idle", Settled: true,
			Nodes: nodes([3]int{1, 0, 0}, [3]int{1, 0, 0}),
		}
		r, err := c.Report()
		if err != nil {
			t.Fatalf("an idle cluster with a complete ledger was refused: %v", err)
		}
		if !r.NoDemand {
			t.Error("NoDemand is false; 'below every pending request' is vacuously true of an empty pending " +
				"set, so an idle cluster must report no demand-relative stranding rather than stranding")
		}
		if r.StrandedDevices != 0 {
			t.Errorf("StrandedDevices = %d, want 0", r.StrandedDevices)
		}
	})

	t.Run("a deliberately missing observation invalidates rather than passes", func(t *testing.T) {
		c := Census{
			Step: "qualify-unobserved", Settled: true,
			Nodes: nodes([3]int{1, 0, 0}, [3]int{1, 0, 0}),
			Submissions: []Submission{
				{Name: "seen", Request: 1, Disposition: DispositionReleased},
				{Name: "never-looked-at", Request: 1}, // no disposition
			},
		}
		_, err := c.Report()
		if err == nil {
			t.Fatal("a census with an unobserved submission produced a report; that is the fourth fixture's " +
				"outcome (idle) arrived at by not looking, which is what the original rule could not tell apart")
		}
		if !strings.Contains(err.Error(), "never-looked-at") {
			t.Errorf("the refusal does not name the submission: %v", err)
		}
		if !strings.Contains(err.Error(), "accounts for every submission") {
			t.Errorf("the refusal does not say why an empty pending set is not a result here: %v", err)
		}
	})
}

// A census the ledger cannot account for is refused, node by node.
//
// The premise of every free count is that the study knows who holds the reservations. An unaccounted holder
// makes each free number a guess, and the amendment requires foreign consumers to be declared explicitly or to
// invalidate the reading.
//
// Mutation that turns this red: drop the boundPer reconciliation.
func TestReservationsTheLedgerCannotAccountForAreRefused(t *testing.T) {
	base := func() Census {
		return Census{
			Step: "reconcile", Settled: true,
			Nodes: nodes([3]int{2, 1, 0}, [3]int{1, 0, 0}),
			Submissions: []Submission{
				{Name: "holder", Request: 1, Disposition: DispositionBound, Node: "w1"},
			},
		}
	}
	if err := base().Validate(); err != nil {
		t.Fatalf("a census whose ledger matches its nodes was refused: %v", err)
	}

	// Someone else holds a device and nobody declared it.
	undeclared := base()
	undeclared.Nodes[1].Reserved = 1
	err := undeclared.Validate()
	if err == nil {
		t.Fatal("a node reserving a device no submission claims was accepted")
	}
	if !strings.Contains(err.Error(), "unaccounted holder") {
		t.Errorf("the refusal does not name the problem: %v", err)
	}

	// Declared explicitly, it is accepted -- that is the amendment's other branch.
	declared := base()
	declared.Nodes[1].Reserved = 1
	declared.ForeignReserved = map[string]int{"w2": 1}
	if err := declared.Validate(); err != nil {
		t.Errorf("an explicitly declared foreign holder was still refused: %v", err)
	}

	// And a bound submission must say where, and where must be a node this census saw.
	nowhere := base()
	nowhere.Submissions[0].Node = ""
	if err := nowhere.Validate(); err == nil {
		t.Error("a bound submission with no node was accepted")
	}
	elsewhere := base()
	elsewhere.Submissions[0].Node = "w9"
	if err := elsewhere.Validate(); err == nil {
		t.Error("a submission bound to a node this census did not observe was accepted")
	}
	// A disposition that does not reserve must not carry a node either: it would suggest a placement that
	// the reservation arithmetic deliberately ignores.
	pendingWithNode := base()
	pendingWithNode.Submissions = append(pendingWithNode.Submissions,
		Submission{Name: "queued", Request: 1, Disposition: DispositionQueuedUnadmitted, Node: "w2"})
	if err := pendingWithNode.Validate(); err == nil {
		t.Error("an unadmitted submission carrying a node was accepted")
	}
}

// A reading taken before the cluster settled describes a cluster that existed at no instant.
//
// Mutation that turns this red: default Settled to true, or drop the check.
func TestAnUnsettledCensusIsRefused(t *testing.T) {
	c := Census{Step: "mid-binding", Nodes: nodes([3]int{1, 0, 0}, [3]int{1, 0, 0})}
	err := c.Validate()
	if err == nil {
		t.Fatal("a census taken mid-binding was accepted")
	}
	if !strings.Contains(err.Error(), "existed at no instant") {
		t.Errorf("the refusal does not say why: %v", err)
	}
	// And a census with no step cannot be placed in a series.
	unnamed := Census{Settled: true, Nodes: nodes([3]int{1, 0, 0}, [3]int{1, 0, 0})}
	if err := unnamed.Validate(); err == nil {
		t.Error("a census with no step name was accepted")
	}
}

// A disposition outside the registered set is unreadable, not a weaker observation.
//
// Mutation that turns this red: treat an unknown disposition as pending.
func TestADispositionThisBuildCannotClassifyIsRefused(t *testing.T) {
	c := Census{
		Step: "unknown-disposition", Settled: true,
		Nodes: nodes([3]int{1, 0, 0}, [3]int{1, 0, 0}),
		Submissions: []Submission{
			{Name: "odd", Request: 1, Disposition: Disposition("preempted-maybe")},
		},
	}
	err := c.Validate()
	if err == nil {
		t.Fatal("an unregistered disposition was accepted")
	}
	if !strings.Contains(err.Error(), "outside the registered set") {
		t.Errorf("the refusal does not say why: %v", err)
	}
}

// Refused admission is still outstanding demand, and the report says so.
//
// The original registration's control assumed an arm could drive stranding to zero by admitting less. It
// cannot: the refused requests remain demand, and only a collector that dropped them from the pending set
// would hide the metric.
//
// Mutation that turns this red: treat api-rejected as released.
func TestRefusedAdmissionRemainsOutstandingDemand(t *testing.T) {
	// Two-device nodes, each holding one. The node SIZE is deliberate and this fixture had it wrong at first:
	// with one-device nodes a two-device request is unsatisfiable rather than stranded, so the case would have
	// been testing capacity shortage while claiming to test refused demand. Third fixture in this file to make
	// that same mistake.
	c := Census{
		Step: "refusal", Settled: true,
		Nodes: nodes([3]int{2, 1, 0}, [3]int{2, 1, 0}),
		Submissions: []Submission{
			{Name: "holder-a", Request: 1, Disposition: DispositionBound, Node: "w1"},
			{Name: "holder-b", Request: 1, Disposition: DispositionBound, Node: "w2"},
			{Name: "rejected", Request: 2, Disposition: DispositionAPIRejected},
			{Name: "released", Request: 2, Disposition: DispositionReleased},
		},
	}
	r, err := c.Report()
	if err != nil {
		t.Fatalf("refused: %v", err)
	}
	if r.OutstandingDemand != 2 {
		t.Errorf("OutstandingDemand = %d, want 2: the rejected request still wants two devices and the "+
			"released one wants none", r.OutstandingDemand)
	}
	if r.NoDemand {
		t.Error("NoDemand is true while a rejected submission is outstanding; an arm cannot make stranding " +
			"disappear by refusing work")
	}
	if r.StrandedDevices != 2 {
		t.Errorf("StrandedDevices = %d, want 2: the rejected request fits nowhere and both devices are free",
			r.StrandedDevices)
	}
}

// Every census step records who is placed and how much is reserved, because a peak conceals both.
//
// The traces [8,8,8] and [8,2,2] share a peak of 8 and describe very different occupancy.
//
// Mutation that turns this red: stop collecting PlacedWorkloads, or sum reservations only at the peak.
func TestEveryStepRecordsWhoIsPlacedAndHowMuchIsHeld(t *testing.T) {
	c := Census{
		Step: "step-3", Settled: true,
		Nodes: nodes([3]int{2, 2, 0}, [3]int{1, 1, 0}, [3]int{1, 0, 0}),
		Submissions: []Submission{
			{Name: "big", Request: 2, Disposition: DispositionBound, Node: "w1"},
			{Name: "small", Request: 1, Disposition: DispositionBound, Node: "w2"},
			{Name: "waiting", Request: 2, Disposition: DispositionQueuedUnadmitted},
		},
	}
	r, err := c.Report()
	if err != nil {
		t.Fatalf("refused: %v", err)
	}
	if r.Step != "step-3" {
		t.Errorf("Step = %q; a figure with no step is not in a series", r.Step)
	}
	if r.ReservedTotal != 3 {
		t.Errorf("ReservedTotal = %d, want 3", r.ReservedTotal)
	}
	if len(r.PlacedWorkloads) != 2 || r.PlacedWorkloads[0] != "big" || r.PlacedWorkloads[1] != "small" {
		t.Errorf("PlacedWorkloads = %v, want [big small]: a count would not say whether the large requests "+
			"starved", r.PlacedWorkloads)
	}
	// One device free on w3, and the pending request wants two: stranded.
	if r.StrandedDevices != 1 {
		t.Errorf("StrandedDevices = %d, want 1", r.StrandedDevices)
	}
}
