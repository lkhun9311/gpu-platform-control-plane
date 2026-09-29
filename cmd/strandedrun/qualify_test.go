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

// A fixture on which both strategies agree is not a weak control; it is no control.
//
// The probe would land on the expected node whichever strategy the cluster is actually running, so observing it
// there could not refute an unapplied treatment -- which is the single failure this whole command exists to
// catch. Refusing such a fixture is therefore a requirement rather than a nicety.
//
// Mutation that turns this red: make Discriminates return nil unconditionally.
func TestAFixtureBothStrategiesAgreeOnQualifiesNothing(t *testing.T) {
	// One node that fits: both strategies must choose it, because scoring runs after filtering.
	f := QualificationFixture{
		Nodes:   []NodeCapacity{{Name: "a", Allocatable: 4, Reserved: 3}, {Name: "b", Allocatable: 4, Reserved: 4}},
		Request: 1,
	}
	err := f.Discriminates()
	if err == nil {
		t.Fatal("a fixture with one schedulable node was accepted as a qualification")
	}
	if !strings.Contains(err.Error(), "says nothing about which strategy") {
		t.Errorf("the refusal does not explain why the fixture is useless: %v", err)
	}
	// And TreatmentApplied must refuse it too, rather than reporting a pass from a fixture that cannot fail.
	if err := f.TreatmentApplied(GPUAware(MostAllocated), "a"); err == nil {
		t.Error("a placement on the only schedulable node was read as evidence the treatment applied")
	}
}

// The scheduler scores allocation FRACTIONS, not raw free counts, and on heterogeneous nodes the two disagree.
//
// Found by adversarial review against the pinned upstream: Kubernetes v1.31's NodeResourcesFit computes each
// node's post-placement allocated fraction -- (reserved + request) / allocatable -- and MostAllocated prefers
// the highest, LeastAllocated the lowest.
//
// Counterexample: capacities [4,2], reservations [1,0], request 1. Raw free is [3,2], so ranking free counts
// makes the two strategies disagree and this fixture look discriminating. The real post-placement fractions are
// (1+1)/4 = 0.5 and (0+1)/2 = 0.5 -- a TIE, which means an observed placement here proves nothing about which
// strategy ran.
//
// The live fixture used on the cluster, free [2,1,0] over equal-sized nodes, happens to agree under both
// models, which is why this defect never surfaced there.
//
// Mutation that turns this red: rank Free() instead of the post-placement fraction.
func TestScoringIsOverAllocationFractionsNotRawFreeCounts(t *testing.T) {
	f := QualificationFixture{
		Nodes:   []NodeCapacity{{Name: "big", Allocatable: 4, Reserved: 1}, {Name: "small", Allocatable: 2, Reserved: 0}},
		Request: 1,
	}
	err := f.Discriminates()
	if err == nil {
		t.Fatal("a fixture whose post-placement allocation fractions tie was accepted as discriminating; " +
			"ranking raw free counts (3 against 2) invents a preference the scheduler does not have")
	}
	if !strings.Contains(err.Error(), "equally") && !strings.Contains(err.Error(), "tie") {
		t.Errorf("the refusal does not name the tie: %v", err)
	}
	// And a fixture that genuinely discriminates under the fraction model must still be accepted, so the fix
	// is not simply refusing heterogeneous clusters.
	//
	// capacities [4,2], reservations [0,1], request 1: fractions are (0+1)/4 = 0.25 and (1+1)/2 = 1.0.
	// MostAllocated prefers small, LeastAllocated prefers big.
	ok := QualificationFixture{
		Nodes:   []NodeCapacity{{Name: "big", Allocatable: 4, Reserved: 0}, {Name: "small", Allocatable: 2, Reserved: 1}},
		Request: 1,
	}
	if err := ok.Discriminates(); err != nil {
		t.Errorf("a fixture that discriminates under the fraction model was refused: %v", err)
	}
	if got, err := ok.PreferredNode(MostAllocated); err != nil || got != "small" {
		t.Errorf("MostAllocated preferred %q (err %v); the highest post-placement fraction is small at 1.0",
			got, err)
	}
	if got, err := ok.PreferredNode(LeastAllocated); err != nil || got != "big" {
		t.Errorf("LeastAllocated preferred %q (err %v); the lowest post-placement fraction is big at 0.25",
			got, err)
	}

	// The fixture the two models DISAGREE on, which is what actually pins the ordering.
	//
	// The first version of this test pinned nothing: its tie case was caught by the tie detector (also
	// fraction-based, and not mutated), and its ordering case happened to give the same answer under both
	// models. Reverting the comparison to raw free counts left the suite green. Found by running the control.
	//
	// capacities [2,5], reservations [0,2], request 1:
	//   free counts        = [2, 3]      -> MostAllocated (least free) would pick big
	//   post-placement frac = [1/2, 3/5] -> MostAllocated (highest fraction) picks small
	// The two models name different winners, so a revert cannot stay green.
	disagree := QualificationFixture{
		Nodes:   []NodeCapacity{{Name: "big", Allocatable: 2, Reserved: 0}, {Name: "small", Allocatable: 5, Reserved: 2}},
		Request: 1,
	}
	if err := disagree.Discriminates(); err != nil {
		t.Fatalf("the disagreement fixture does not discriminate: %v", err)
	}
	if got, err := disagree.PreferredNode(MostAllocated); err != nil || got != "small" {
		t.Errorf("MostAllocated preferred %q (err %v), want small: fractions are 1/2 and 3/5, and ranking raw "+
			"free counts (2 against 3) would pick big instead", got, err)
	}
	if got, err := disagree.PreferredNode(LeastAllocated); err != nil || got != "big" {
		t.Errorf("LeastAllocated preferred %q (err %v), want big: 1/2 is the lower fraction, while ranking raw "+
			"free counts would pick small", got, err)
	}
}

// A tie is refused rather than broken, because the scheduler breaks ties by rules this does not model.
//
// Mutation that turns this red: return the first best node instead of detecting the tie.
func TestATiedFixtureIsRefusedRatherThanGuessed(t *testing.T) {
	f := QualificationFixture{
		Nodes: []NodeCapacity{
			{Name: "a", Allocatable: 4, Reserved: 1},
			{Name: "b", Allocatable: 4, Reserved: 1},
			{Name: "c", Allocatable: 4, Reserved: 2},
		},
		Request: 1,
	}
	_, err := f.PreferredNode(LeastAllocated)
	if err == nil {
		t.Fatal("a fixture with two equally-free nodes produced a confident prediction")
	}
	if !strings.Contains(err.Error(), "tiebreak") {
		t.Errorf("the refusal does not name the reason: %v", err)
	}
}

// The discriminating fixture the study will actually use, and both directions of its verdict.
//
// Free devices a=3, b=1: LeastAllocated prefers a, MostAllocated prefers b. Observing the wrong one must be
// reported as the treatment not applying, and the message must name the strategy that WOULD have produced it --
// because "the placement was unexpected" and "the cluster ran the other arm" are different diagnoses.
//
// Mutation that turns this red: compare against the wrong strategy, or drop the alternative-strategy branch.
func TestAWrongPlacementNamesTheStrategyThatWouldHaveProducedIt(t *testing.T) {
	f := QualificationFixture{
		Nodes:   []NodeCapacity{{Name: "a", Allocatable: 4, Reserved: 1}, {Name: "b", Allocatable: 4, Reserved: 3}},
		Request: 1,
	}
	if err := f.Discriminates(); err != nil {
		t.Fatalf("the fixture the rest of this test relies on does not discriminate: %v", err)
	}

	// Asked for packing, got spreading.
	err := f.TreatmentApplied(GPUAware(MostAllocated), "a")
	if err == nil {
		t.Fatal("a probe on the spread-preferred node passed while the run asked for packing")
	}
	if !strings.Contains(err.Error(), string(LeastAllocated)) || !strings.Contains(err.Error(), "did not apply") {
		t.Errorf("the failure does not say the other arm produced this placement: %v", err)
	}

	// Asked for spreading, got packing.
	err = f.TreatmentApplied(GPUAware(LeastAllocated), "b")
	if err == nil {
		t.Fatal("a probe on the pack-preferred node passed while the run asked for spreading")
	}
	if !strings.Contains(err.Error(), string(MostAllocated)) {
		t.Errorf("the failure does not name the strategy that would have produced it: %v", err)
	}

	// And the two passing cases, so the check is not simply refusing everything.
	if err := f.TreatmentApplied(GPUAware(MostAllocated), "b"); err != nil {
		t.Errorf("the packing arm's own placement was rejected: %v", err)
	}
	if err := f.TreatmentApplied(GPUAware(LeastAllocated), "a"); err != nil {
		t.Errorf("the spreading arm's own placement was rejected: %v", err)
	}
}

// A placement that matches neither strategy is reported as such, not as the other arm.
//
// It means something outside this study's model moved the pod -- a taint, a quota, an affinity rule -- and
// saying "the treatment did not apply" would attribute it to the one cause the run was varying.
//
// Mutation that turns this red: collapse the two branches into one message.
func TestAPlacementMatchingNeitherStrategyIsNotBlamedOnTheTreatment(t *testing.T) {
	f := QualificationFixture{
		Nodes: []NodeCapacity{
			{Name: "a", Allocatable: 4, Reserved: 1},
			{Name: "b", Allocatable: 4, Reserved: 3},
			{Name: "c", Allocatable: 4, Reserved: 2},
		},
		Request: 1,
	}
	err := f.TreatmentApplied(GPUAware(MostAllocated), "c")
	if err == nil {
		t.Fatal("a placement on neither preferred node was accepted")
	}
	if !strings.Contains(err.Error(), "matches neither strategy") {
		t.Errorf("the failure blames the treatment for a placement outside the model: %v", err)
	}
}

// An unplaced probe is a census that did not happen, not a null result about the strategy.
//
// This is the study's recurring shape: an absent observation reading as a negative one. A pod that never got
// scheduled says nothing about scoring, because scoring runs after filtering.
//
// Mutation that turns this red: treat an empty observed node as a mismatch.
func TestAnUnplacedProbeIsNotANullResult(t *testing.T) {
	f := QualificationFixture{
		Nodes:   []NodeCapacity{{Name: "a", Allocatable: 4, Reserved: 1}, {Name: "b", Allocatable: 4, Reserved: 3}},
		Request: 1,
	}
	err := f.TreatmentApplied(GPUAware(MostAllocated), "")
	if err == nil {
		t.Fatal("an unobserved placement was read as a passing qualification")
	}
	if !strings.Contains(err.Error(), "census that did not happen") {
		t.Errorf("an unplaced probe was not distinguished from a wrong placement: %v", err)
	}
}

// Scoring runs after filtering, so a node that cannot fit the request is not a candidate at all.
//
// Modelling it as "scored low" would make the prediction disagree with the scheduler for a reason that has
// nothing to do with the strategy under test.
//
// Mutation that turns this red: score every node regardless of whether it fits.
func TestANodeThatCannotFitIsNotACandidate(t *testing.T) {
	// b has the least free capacity, which MostAllocated would prefer -- but it cannot hold a 2-device request.
	f := QualificationFixture{
		Nodes:   []NodeCapacity{{Name: "a", Allocatable: 4, Reserved: 0}, {Name: "b", Allocatable: 4, Reserved: 3}},
		Request: 2,
	}
	got, err := f.PreferredNode(MostAllocated)
	if err != nil {
		t.Fatalf("the prediction refused a fixture with exactly one fitting node: %v", err)
	}
	if got != "a" {
		t.Errorf("PreferredNode = %q, want a; b has 1 free device and cannot hold a request for 2", got)
	}
	// With nothing able to fit, the fixture measures filtering rather than scoring and must refuse.
	none := QualificationFixture{Nodes: f.Nodes, Request: 5}
	if _, err := none.PreferredNode(LeastAllocated); err == nil {
		t.Error("a fixture no node can satisfy produced a prediction about scoring")
	}
}

// A census this command cannot read is refused rather than defaulted.
//
// Mutation that turns this red: skip the malformed entries instead of failing.
func TestACensusThatCannotBeReadIsRefused(t *testing.T) {
	for _, tc := range []struct{ name, in string }{
		{"empty", ""},
		{"missing a field", "a:4"},
		{"a non-numeric allocatable", "a:four:1"},
		{"a non-numeric reserved", "a:4:one"},
		{"the same node twice", "a:4:1,a:4:2"},
	} {
		if _, err := parseNodes(tc.in); err == nil {
			t.Errorf("%s (%q) was accepted as a census", tc.name, tc.in)
		}
	}
	got, err := parseNodes("a:4:1, b:4:3")
	if err != nil {
		t.Fatalf("a well-formed census was refused: %v", err)
	}
	if len(got) != 2 || got[0].Free() != 3 || got[1].Free() != 1 {
		t.Errorf("parsed census = %+v; free should be allocatable minus reserved", got)
	}
}

// Reserved beyond allocatable is not a state a census can take, and reading it as negative free capacity would
// put an impossible node into a prediction.
//
// Mutation that turns this red: drop the bounds check in PreferredNode.
func TestAnImpossibleNodeStateIsRefused(t *testing.T) {
	f := QualificationFixture{
		Nodes:   []NodeCapacity{{Name: "a", Allocatable: 2, Reserved: 5}, {Name: "b", Allocatable: 4, Reserved: 1}},
		Request: 1,
	}
	if _, err := f.PreferredNode(LeastAllocated); err == nil {
		t.Error("a node reserving more devices than it advertises was accepted into a prediction")
	}
}
