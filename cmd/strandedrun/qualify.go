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
	"fmt"
	"sort"
	"strings"
)

// NodeCapacity is one node's GPU accounting at a census instant.
//
// Free is derived rather than read: the amendment requires it, because AllocatableGPU is what a node ADVERTISES
// and the scheduler places against allocatable minus the requests of pods already bound there. A field called
// "free" read straight off the API would be the total.
type NodeCapacity struct {
	Name        string
	Allocatable int
	Reserved    int
}

// Free is the devices a further pod could be placed against on this node.
func (n NodeCapacity) Free() int { return n.Allocatable - n.Reserved }

// QualificationFixture is a placement with a KNOWN unequal preference between the two strategies.
//
// It is the instrument's own control, and the registration requires it to pass before any comparative run. A
// study whose treatment silently did not apply reports three identical arms and reads as a null result, so the
// fixture has to be a case where LeastAllocated and MostAllocated demonstrably disagree -- if they agree, the
// fixture cannot discriminate and observing the expected node proves nothing about which strategy ran.
type QualificationFixture struct {
	// Nodes is the cluster's GPU state before the probe pod is submitted.
	Nodes []NodeCapacity
	// Request is the probe pod's GPU request.
	Request int
}

// PreferredNode is the node the given strategy scores highest for the fixture's probe pod.
//
// Only nodes that can FIT the request are candidates: scoring runs after filtering, so a node with less free
// capacity than the request is not "scored low", it is not scored at all. Getting that wrong would make the
// prediction disagree with the scheduler for a reason unrelated to the strategy.
//
// Ties are refused rather than broken. The scheduler breaks them by its own rules, which this function does not
// model, so a fixture whose outcome depends on a tiebreak is one whose observed placement cannot be read as
// evidence about the strategy.
func (f QualificationFixture) PreferredNode(s ScoringStrategy) (string, error) {
	if f.Request <= 0 {
		return "", fmt.Errorf("the probe requests %d devices; a fixture that asks for nothing places anywhere "+
			"and discriminates between no strategies", f.Request)
	}
	var fits []NodeCapacity
	for _, n := range f.Nodes {
		if n.Allocatable < 0 || n.Reserved < 0 || n.Reserved > n.Allocatable {
			return "", fmt.Errorf("node %q reports allocatable=%d reserved=%d, which is not a state a census "+
				"can take", n.Name, n.Allocatable, n.Reserved)
		}
		if n.Free() >= f.Request {
			fits = append(fits, n)
		}
	}
	if len(fits) == 0 {
		return "", fmt.Errorf("no node has %d free devices, so the probe would not be placed at all and the "+
			"fixture measures filtering rather than scoring", f.Request)
	}
	// LeastAllocated prefers the most free; MostAllocated prefers the least free among those that still fit.
	best := fits[0]
	for _, n := range fits[1:] {
		switch s {
		case LeastAllocated:
			if n.Free() > best.Free() {
				best = n
			}
		case MostAllocated:
			if n.Free() < best.Free() {
				best = n
			}
		default:
			return "", fmt.Errorf("unknown scoring strategy %q", s)
		}
	}
	for _, n := range fits {
		if n.Name != best.Name && n.Free() == best.Free() {
			return "", fmt.Errorf("nodes %q and %q both have %d free devices, so %s scores them equally and "+
				"the winner would come from a tiebreak this fixture does not model", best.Name, n.Name,
				best.Free(), s)
		}
	}
	return best.Name, nil
}

// Discriminates reports whether this fixture can tell the two strategies apart at all.
//
// A fixture where both strategies prefer the same node is not a weak control, it is no control: the probe would
// land on the expected node whichever strategy the cluster is actually running, so the observation could not
// refute an unapplied treatment. Refusing such a fixture is the point of this function.
func (f QualificationFixture) Discriminates() error {
	least, err := f.PreferredNode(LeastAllocated)
	if err != nil {
		return fmt.Errorf("%s: %w", LeastAllocated, err)
	}
	most, err := f.PreferredNode(MostAllocated)
	if err != nil {
		return fmt.Errorf("%s: %w", MostAllocated, err)
	}
	if least == most {
		return fmt.Errorf("both strategies prefer node %q for this fixture (free devices: %s), so observing "+
			"the probe there says nothing about which strategy the cluster ran", least, f.freeSummary())
	}
	return nil
}

func (f QualificationFixture) freeSummary() string {
	parts := make([]string, 0, len(f.Nodes))
	for _, n := range f.Nodes {
		parts = append(parts, fmt.Sprintf("%s=%d", n.Name, n.Free()))
	}
	sort.Strings(parts)
	return strings.Join(parts, " ")
}

// TreatmentApplied judges an observed placement against the profile the run asked for.
//
// This is the check the registration says must be built first, and it answers the question a scheduler-config
// readback cannot: whether the configuration the cluster accepted actually MOVED a placement. A scheduler that
// loaded the right strategy over the wrong resource list reports the right configuration and behaves like the
// default, so reading the config back is necessary and not sufficient.
func (f QualificationFixture) TreatmentApplied(p SchedulerProfile, observedNode string) error {
	if err := p.Validate(); err != nil {
		return fmt.Errorf("the profile itself would not apply: %w", err)
	}
	if err := f.Discriminates(); err != nil {
		return fmt.Errorf("the fixture cannot qualify anything: %w", err)
	}
	want, err := f.PreferredNode(p.Strategy)
	if err != nil {
		return err
	}
	if observedNode == "" {
		return fmt.Errorf("no placement was observed; an unplaced probe is not a null result about %s, it is "+
			"a census that did not happen", p.Strategy)
	}
	if observedNode != want {
		other := LeastAllocated
		if p.Strategy == LeastAllocated {
			other = MostAllocated
		}
		alt, altErr := f.PreferredNode(other)
		if altErr == nil && observedNode == alt {
			return fmt.Errorf("the probe landed on %q, which is what %s prefers, while this run asked for %s "+
				"(free devices: %s); the requested treatment did not apply", observedNode, other, p.Strategy,
				f.freeSummary())
		}
		return fmt.Errorf("the probe landed on %q and %s prefers %q (free devices: %s); the placement matches "+
			"neither strategy, so something outside this study's model moved it", observedNode, p.Strategy,
			want, f.freeSummary())
	}
	return nil
}
