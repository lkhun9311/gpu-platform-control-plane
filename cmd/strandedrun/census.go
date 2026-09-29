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

// Disposition is what was OBSERVED to have become of one registered submission.
//
// The amendment requires every submission to carry one, and a census with any submission whose disposition was
// not observed is invalid. The reason is the original validity rule's blind spot: a suspended Job has no pod, a
// submission the API rejected has no object at all, and a collector that missed every pod sees an empty pending
// set. All three satisfy "no pod is pending for a non-GPU reason", and all three are "did not run" wearing the
// face of "passed".
type Disposition string

const (
	// DispositionUnobserved is the zero value on purpose: a submission nobody looked at must not read as any
	// outcome, and the zero value is what a struct gets when a field was never filled.
	DispositionUnobserved Disposition = ""
	// DispositionAPIRejected is a submission the API server refused, so no object exists to be pending.
	DispositionAPIRejected Disposition = "api-rejected"
	// DispositionQueuedUnadmitted is admitted to no quota yet, so it holds nothing on any node.
	DispositionQueuedUnadmitted Disposition = "queued-unadmitted"
	// DispositionTopologyAssigned is a Kueue TAS assignment made before the pods are bound. It is recorded
	// separately from Bound and reconciled against it, because Kueue's own capacity calculation counts admitted
	// TAS workloads and counting both would double-charge the same demand.
	DispositionTopologyAssigned Disposition = "topology-assigned"
	// DispositionBound is a pod placed on a node, which is the only disposition that reserves devices.
	DispositionBound Disposition = "bound"
	// DispositionReleased is a workload whose devices have gone back, so it neither reserves nor demands.
	DispositionReleased Disposition = "released"
)

var knownDispositions = map[Disposition]bool{
	DispositionAPIRejected:      true,
	DispositionQueuedUnadmitted: true,
	DispositionTopologyAssigned: true,
	DispositionBound:            true,
	DispositionReleased:         true,
}

// Submission is one registered unit of demand and what became of it.
//
// One pod per workload and a fixed integer GPU request, which is the restriction the amendment places on the
// first study so that reservations can be computed from bound pods at all.
type Submission struct {
	// Name identifies the workload; the amendment requires placed workloads to be identifiable at every census
	// step rather than summarised to a count.
	Name string
	// Request is the workload's GPU request.
	Request int
	// Disposition is what was observed. Unobserved invalidates the census.
	Disposition Disposition
	// Node is where it was bound, required when Disposition is Bound and meaningless otherwise.
	Node string
}

// Census is one settled reading of the cluster plus the ledger that accounts for every submission.
type Census struct {
	// Step names this census point, so a series can be compared rather than a peak quoted.
	Step string
	// Nodes is the per-node accounting: what each advertises and what bound pods reserve on it.
	Nodes []NodeCapacity
	// Submissions is the demand ledger. Every registered submission appears, whatever became of it.
	Submissions []Submission
	// ForeignReserved is GPU capacity held by consumers this study did not submit, per node.
	//
	// The amendment: foreign consumers are either included explicitly or their presence invalidates the census.
	// Declaring them here is the explicit inclusion; a non-empty value the caller did not intend is what the
	// validity check catches.
	ForeignReserved map[string]int
	// Settled says the collector resolved terminating pods and in-flight bindings before taking this reading.
	// A census taken mid-binding describes a cluster that existed at no instant.
	Settled bool
}

// StrandingReport is what one census yields, with the headline separated from the diagnostics.
type StrandingReport struct {
	// Step carries the census point's name, so a report cannot be quoted without saying which reading it came
	// from. The amendment requires a series rather than a peak, and a figure with no step is not in a series.
	Step string
	// StrandedDevices is the REGISTERED figure: free devices on a cluster where no pending workload fits
	// anywhere, which is max(f_i) < q_min.
	StrandedDevices int
	// Blocked names the pending submissions that cannot be placed, for the reader who asks which.
	Blocked []string
	// UnusableGapSum is the per-node gap sum the original registration measured by mistake. It is kept as a
	// DIAGNOSTIC under its own name and is never the headline: with free counts [1,4] and a request of 2 it
	// reports one stranded device while the workload can in fact be placed on the second node.
	UnusableGapSum int
	// Unsatisfiable names pending submissions that would not fit on an empty node of the largest size. They are
	// counted separately: a cluster that never had room for a request is short of capacity, not fragmented.
	Unsatisfiable []string
	// WitnessRequest is the smallest q with max(f_i) < q <= sum(f_i), and WitnessExists says whether any does.
	// Without one the cluster cannot strand, however much is free.
	WitnessRequest int
	WitnessExists  bool
	// NoDemand distinguishes an idle cluster from a stranded one. "Below every pending request" is vacuously
	// true of an empty pending set, so an idle cluster would otherwise report stranding.
	NoDemand bool
	// ReservedTotal and PlacedWorkloads are the control the amendment requires at every census step, because a
	// peak conceals which workloads were admitted and whether the large requests starved.
	ReservedTotal   int
	PlacedWorkloads []string
	// OutstandingDemand is the devices pending submissions still want. Refusing admission does not make
	// stranding zero -- the refused requests are still demand -- and this is where that shows.
	OutstandingDemand int
}

// Validate refuses a census that cannot support a reading.
//
// Each refusal is a case that the original validity rule accepted, and every one of them is an absent
// observation that would otherwise read as a negative result.
func (c Census) Validate() error {
	if c.Step == "" {
		return fmt.Errorf("the census names no step; a series cannot be compared and a peak quoted from " +
			"unnamed readings is not a series")
	}
	if !c.Settled {
		return fmt.Errorf("census %q was not settled: terminating pods and in-flight bindings must be resolved "+
			"before a reading is accepted, or it describes a cluster that existed at no instant", c.Step)
	}
	if len(c.Nodes) == 0 {
		return fmt.Errorf("census %q observed no nodes; an empty reading is not a cluster with no capacity, it "+
			"is a census that did not happen", c.Step)
	}
	names := map[string]bool{}
	for _, n := range c.Nodes {
		if n.Name == "" {
			return fmt.Errorf("census %q has a node with no name", c.Step)
		}
		if names[n.Name] {
			return fmt.Errorf("census %q names node %q twice", c.Step, n.Name)
		}
		names[n.Name] = true
		if n.Allocatable < 0 || n.Reserved < 0 || n.Reserved > n.Allocatable {
			return fmt.Errorf("census %q: node %q reports allocatable=%d reserved=%d, which is not a state a "+
				"census can take", c.Step, n.Name, n.Allocatable, n.Reserved)
		}
	}

	var unobserved, unknown []string
	for _, s := range c.Submissions {
		if s.Name == "" {
			return fmt.Errorf("census %q has a submission with no name; a placed workload has to be "+
				"identifiable, not counted", c.Step)
		}
		if s.Request <= 0 {
			return fmt.Errorf("census %q: submission %q requests %d devices; this study's first campaign is "+
				"one pod per workload with a fixed positive integer request", c.Step, s.Name, s.Request)
		}
		switch {
		case s.Disposition == DispositionUnobserved:
			unobserved = append(unobserved, s.Name)
		case !knownDispositions[s.Disposition]:
			unknown = append(unknown, fmt.Sprintf("%s=%s", s.Name, s.Disposition))
		}
		if s.Disposition == DispositionBound {
			if s.Node == "" {
				return fmt.Errorf("census %q: submission %q is bound to no node; a bound pod is the only "+
					"disposition that reserves devices and it has to say where", c.Step, s.Name)
			}
			if !names[s.Node] {
				return fmt.Errorf("census %q: submission %q is bound to %q, which this census did not observe",
					c.Step, s.Name, s.Node)
			}
		} else if s.Node != "" {
			return fmt.Errorf("census %q: submission %q carries node %q while its disposition is %q; only a "+
				"bound submission holds a node", c.Step, s.Name, s.Node, s.Disposition)
		}
	}
	if len(unobserved) > 0 {
		sort.Strings(unobserved)
		return fmt.Errorf("census %q: submission(s) %s carry no observed disposition; an empty pending set is a "+
			"result only when the ledger accounts for every submission, so this reading is invalid rather than "+
			"a cluster with nothing pending", c.Step, strings.Join(unobserved, ", "))
	}
	if len(unknown) > 0 {
		sort.Strings(unknown)
		return fmt.Errorf("census %q: disposition(s) %s are outside the registered set; a disposition this "+
			"build cannot classify is not a weaker observation, it is an unreadable one", c.Step,
			strings.Join(unknown, ", "))
	}

	// Bound submissions must account for the reservations the nodes report, once declared foreign holders are
	// subtracted. A mismatch means someone else is holding devices, and the amendment says such a presence is
	// either included explicitly or invalidates the census.
	boundPer := map[string]int{}
	for _, s := range c.Submissions {
		if s.Disposition == DispositionBound {
			boundPer[s.Node] += s.Request
		}
	}
	for _, n := range c.Nodes {
		foreign := c.ForeignReserved[n.Name]
		if foreign < 0 {
			return fmt.Errorf("census %q: node %q declares %d foreign reservations", c.Step, n.Name, foreign)
		}
		if want := boundPer[n.Name] + foreign; want != n.Reserved {
			return fmt.Errorf("census %q: node %q reserves %d devices and the ledger accounts for %d (%d bound "+
				"by this study, %d declared foreign); an unaccounted holder makes every free count on this "+
				"node a guess", c.Step, n.Name, n.Reserved, want, boundPer[n.Name], foreign)
		}
	}
	return nil
}

// Report computes the registered figure and its diagnostics from a valid census.
//
// It refuses rather than returning a zero report for an invalid census, because a plausible wrong number is
// worse here than a refusal -- the rule internal/queuelab and internal/bench are already arranged around.
func (c Census) Report() (StrandingReport, error) {
	if err := c.Validate(); err != nil {
		return StrandingReport{}, err
	}

	var free []int
	largest := 0
	totalFree := 0
	r := StrandingReport{Step: c.Step}
	for _, n := range c.Nodes {
		f := n.Free()
		free = append(free, f)
		totalFree += f
		r.ReservedTotal += n.Reserved
		if n.Allocatable > largest {
			largest = n.Allocatable
		}
	}
	maxFree := 0
	for _, f := range free {
		if f > maxFree {
			maxFree = f
		}
	}
	r.WitnessRequest, r.WitnessExists = WitnessRequest(free)

	// Pending demand is everything the ledger has not placed or released. A refused submission is still demand:
	// refusing admission does not make stranding zero, it only hides it if the collector drops the request.
	var pending []Submission
	for _, s := range c.Submissions {
		switch s.Disposition {
		case DispositionBound:
			r.PlacedWorkloads = append(r.PlacedWorkloads, s.Name)
		case DispositionReleased:
			// neither reserves nor demands
		default:
			pending = append(pending, s)
			r.OutstandingDemand += s.Request
		}
	}
	sort.Strings(r.PlacedWorkloads)

	if len(pending) == 0 {
		// Not stranding of zero: no demand-relative stranding, which is a different outcome from a cluster
		// whose demand observations are missing -- that one is refused by Validate above.
		r.NoDemand = true
		return r, nil
	}

	// q_min is taken over the SATISFIABLE pending requests only, and that exclusion is the amendment's
	// "aggregate shortage is not fragmentation" made arithmetic.
	//
	// Measured rather than reasoned: the first version took q_min over all pending requests, so the shortage
	// fixture -- free [1,1] with a request of 3 -- reported `unsatisfiable: wants-three` AND a headline of 2
	// stranded devices. A request the cluster never had room for was making the free capacity look fragmented,
	// which is exactly the conflation the amendment corrected the original registration for. The unit test did
	// not catch it because it asserted Unsatisfiable and Blocked and never looked at StrandedDevices.
	var satisfiable []Submission
	for _, s := range pending {
		if s.Request > largest {
			r.Unsatisfiable = append(r.Unsatisfiable, s.Name)
			continue
		}
		satisfiable = append(satisfiable, s)
	}
	sort.Strings(r.Unsatisfiable)

	if len(satisfiable) == 0 {
		// Every pending request is beyond this cluster's largest node. That is a capacity shortage with no
		// placement question in it, so there is no stranding to report -- and it is NOT the same outcome as an
		// idle cluster, which NoDemand marks.
		return r, nil
	}

	qMin := satisfiable[0].Request
	// witnessed is the narrower question the headline actually needs: does the PENDING ledger contain a request
	// that the cluster could satisfy if its free devices were on one node, and cannot satisfy as they lie?
	//
	// WitnessRequest(free) answers whether such a q EXISTS hypothetically, and adversarial review showed that
	// is not the same claim. Counterexample: capacities [4,2], reservations [3,1], pending request 3. Free is
	// [1,1] -- two devices in the whole cluster -- and the request survives the unsatisfiable exclusion because
	// it would fit an empty four-device node, so max(f_i)=1 < q_min=3 reported two stranded devices for demand
	// the cluster cannot meet at all. Aggregate shortage back in the headline, through a second door.
	witnessed := false
	for _, s := range satisfiable {
		if s.Request < qMin {
			qMin = s.Request
		}
		fits := false
		for _, f := range free {
			if f >= s.Request {
				fits = true
				break
			}
		}
		if !fits {
			r.Blocked = append(r.Blocked, s.Name)
			// A blocked request witnesses fragmentation only if the cluster currently holds enough free
			// devices to satisfy it somewhere -- max(f_i) < request <= sum(f_i). Below that sum it is short of
			// capacity now, whatever an empty node could once have held.
			if s.Request <= totalFree {
				witnessed = true
			}
		}
	}
	sort.Strings(r.Blocked)

	// The headline: the cluster-wide blockage, max(f_i) < q_min, and only when a pending request witnesses it.
	if maxFree < qMin && witnessed {
		r.StrandedDevices = totalFree
	}
	// WitnessExists now reports the pending-demand witness rather than a hypothetical one, so a reader cannot
	// take it as a claim about demand the ledger does not contain.
	if !witnessed {
		r.WitnessRequest, r.WitnessExists = 0, false
	}
	// The diagnostic the original registration measured by mistake, kept under its own name.
	for _, f := range free {
		if f < qMin {
			r.UnusableGapSum += f
		}
	}
	return r, nil
}
