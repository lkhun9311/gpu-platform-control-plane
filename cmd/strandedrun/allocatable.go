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

// ObservedNode is one node's advertised GPU capacity as the API server reports it.
//
// Read back from the cluster rather than taken from the manifest, which the registration requires in those
// words. A DaemonSet that never became ready, an image that would not pull, a label that did not reach the
// kubelet and a plugin whose registration the kubelet refused all leave the manifest saying one thing and the
// node saying another -- and only the node's word decides where the scheduler can place.
type ObservedNode struct {
	Name string
	// Labelled is the device count the node's own label claims, and Present says whether the label exists at
	// all. A node with no label is a different fact from one labelled zero.
	Labelled int
	Present  bool
	// Allocatable is the nvidia.com/gpu quantity the node advertises.
	Allocatable int
}

// VerifyLayout compares what the cluster advertises against what the run asked for.
//
// Every mismatch is refused rather than reported as a smaller cluster, because the layout is the independent
// variable: a study that ran on capacity it did not intend measured a different cluster from the one it
// registered, and the numbers would be internally consistent while describing nothing.
func VerifyLayout(want NodeLayout, got []ObservedNode) error {
	if err := want.Validate(); err != nil {
		return fmt.Errorf("the layout asked for is not one this study can run: %w", err)
	}
	if len(got) == 0 {
		return fmt.Errorf("no nodes were observed; an empty reading is not a cluster with no capacity, it is " +
			"a census that did not happen")
	}

	var unlabelled []string
	labelled := map[int][]ObservedNode{}
	for _, n := range got {
		if !n.Present {
			unlabelled = append(unlabelled, n.Name)
			continue
		}
		labelled[n.Labelled] = append(labelled[n.Labelled], n)
	}
	if len(unlabelled) > 0 {
		sort.Strings(unlabelled)
		return fmt.Errorf("node(s) %s carry no %s label; the device plugin selects on it, so an unlabelled "+
			"worker advertises nothing and its emptiness would read as capacity this study reserved",
			strings.Join(unlabelled, ", "), NodeLabelKey)
	}

	// The multiset of labels must equal the multiset the layout asked for. Comparing counts per value rather
	// than node-by-node, because which worker got which label is kind's to decide and does not matter; how
	// many workers of each size exist is the whole independent variable.
	wantPer := map[int]int{}
	for _, n := range want {
		wantPer[n]++
	}
	gotPer := map[int]int{}
	for v, ns := range labelled {
		gotPer[v] = len(ns)
	}
	for v, w := range wantPer {
		if gotPer[v] != w {
			return fmt.Errorf("the layout asks for %d worker(s) advertising %d device(s) and %d carry that "+
				"label; the cluster is not the one registered", w, v, gotPer[v])
		}
	}
	for v, g := range gotPer {
		if wantPer[v] == 0 {
			return fmt.Errorf("%d worker(s) carry %s=%d, which the layout does not ask for; an extra size "+
				"changes which requests can be placed", g, NodeLabelKey, v)
		}
	}

	// And the reading the registration actually demanded: the label is what the manifest promised, allocatable
	// is what the kubelet grants. They disagree whenever the plugin did not come up.
	var wrong []string
	for _, ns := range labelled {
		for _, n := range ns {
			if n.Allocatable != n.Labelled {
				wrong = append(wrong, fmt.Sprintf("%s labelled %d advertises %d", n.Name, n.Labelled,
					n.Allocatable))
			}
		}
	}
	if len(wrong) > 0 {
		sort.Strings(wrong)
		return fmt.Errorf("the cluster does not advertise what the layout asked for (%s); the manifest is not "+
			"evidence about capacity, the node is", strings.Join(wrong, "; "))
	}
	return nil
}

// WitnessRequest is a GPU request that the cluster could satisfy if its free devices were on one node and
// cannot satisfy as they lie.
//
// It is what separates fragmentation from aggregate shortage, which the original registration conflated: with
// free counts [1,1] a request for 3 is blocked because the cluster does not have three devices at all, and
// counting that as stranding would report a shortage as a placement problem. The amendment requires a witness
// q with max(f_i) < q <= sum(f_i), and this returns the smallest one -- the weakest demand that still
// demonstrates the phenomenon.
//
// Zero and false mean no such request exists, which is a legitimate state: a cluster whose free capacity all
// sits on one node cannot strand, however much of it there is.
func WitnessRequest(free []int) (int, bool) {
	if len(free) == 0 {
		return 0, false
	}
	maxFree, total := 0, 0
	for _, f := range free {
		if f < 0 {
			return 0, false
		}
		if f > maxFree {
			maxFree = f
		}
		total += f
	}
	q := maxFree + 1
	if q > total {
		return 0, false
	}
	return q, true
}
