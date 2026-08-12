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

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/queuelab"
)

// teardownSeedSchema pins the shape enumerate reads.
//
// The schema is checked against the seed rather than assumed, because it pins which enumerate produced a
// residue record; a naming change to the fixture builder without a schema bump would strand old residue
// permanently — a later enumerate would compute different names for it and never find it again.
const teardownSeedSchema = 1

// teardownPhase orders deletion so Kueue's own finalizers never block a run's cleanup.
type teardownPhase int

const (
	phaseNamespace      teardownPhase = iota // the namespace, and everything it contains
	phaseClusterQueue                        // after the namespace is absent: no Workload reserves them
	phaseResourceFlavor                      // last: every referencing ClusterQueue must be absent
)

// target is one object enumerate says must be deleted, and the phase it must be deleted in.
type target struct {
	Phase      teardownPhase
	Kind       string // "Namespace", "ClusterQueue", "ResourceFlavor"
	Name       string
	Namespaced bool
}

// seed is the durable record of what a run created, written before the run's first Create so a crash mid-run
// still leaves enough behind to compute the same deletion set enumerate would have produced live.
type seed struct {
	Schema    int
	TxID      string
	RunID     string
	Arm       string
	Study     queuelab.Study
	Variant   string
	Namespace string
}

// enumerate turns a seed into the ordered set of objects a run's teardown must delete.
//
// The set comes from re-running the same builder the run itself used to create its fixtures, not from a
// List against the cluster: a List would return whatever the cluster currently holds, including objects a
// concurrent or later run happens to own, so the deletion set would drift from "what THIS run created" to
// "what currently matches a label selector" — exactly the ambiguity a seed recorded before creation exists
// to remove.
func enumerate(s seed) ([]target, error) {
	if s.Schema != teardownSeedSchema {
		return nil, fmt.Errorf("seed schema %d does not match enumerate's schema %d: "+
			"the fixture names this schema computes may not match what created the residue", s.Schema, teardownSeedSchema)
	}
	// Every field below feeds fixture or namespace naming. An empty one is not "delete less" — it is
	// "delete a different, wrong thing": e.g. an empty RunID makes the namespace "queuelab-" (via the
	// caller) or a flavor name "queuelab-gpu-", which can match an unrelated run's leftovers and widen the
	// blast radius past this run's own objects.
	if s.TxID == "" {
		return nil, fmt.Errorf("seed has an empty TxID")
	}
	if s.RunID == "" {
		return nil, fmt.Errorf("seed has an empty RunID")
	}
	if s.Arm == "" {
		return nil, fmt.Errorf("seed has an empty Arm")
	}
	if s.Study == "" {
		return nil, fmt.Errorf("seed has an empty Study")
	}
	if s.Variant == "" {
		return nil, fmt.Errorf("seed has an empty Variant")
	}
	if s.Namespace == "" {
		return nil, fmt.Errorf("seed has an empty Namespace")
	}

	fs, err := queuelab.BuildFixtures(s.Study, s.Variant, s.RunID, s.Namespace)
	if err != nil {
		return nil, fmt.Errorf("rebuild fixture names from seed: %w", err)
	}

	targets := []target{{Phase: phaseNamespace, Kind: "Namespace", Name: s.Namespace, Namespaced: false}}

	// LocalQueues are deliberately not enumerated: they are namespaced objects that live inside s.Namespace,
	// so deleting the namespace already removes them. Listing them here as separate targets would make the
	// deletion set claim an authority (deleting a LocalQueue) that the namespace delete already has, and
	// would need its own ordering rule for no reason.
	//
	// Phase order below follows Kueue's finalizers, not this code's preference: a ClusterQueue carries a
	// resource-in-use finalizer that only clears once no Workload reserves it, and a Workload's reservation
	// is only released once the namespace holding it is gone — so the namespace must be deleted, and
	// confirmed absent, before a ClusterQueue delete can complete. ResourceFlavor carries the same kind of
	// finalizer, clearing only once every ClusterQueue that references it is gone, so it must be last.
	for _, cq := range fs.ClusterQueue {
		targets = append(targets, target{Phase: phaseClusterQueue, Kind: "ClusterQueue", Name: cq.GetName(), Namespaced: false})
	}
	targets = append(targets, target{Phase: phaseResourceFlavor, Kind: "ResourceFlavor", Name: fs.Flavor.GetName(), Namespaced: false})

	return targets, nil
}
