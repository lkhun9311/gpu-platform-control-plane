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

	fs, err := queuelab.BuildFixtures(s.Study, s.Variant, s.TxID, s.RunID, s.Namespace)
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

// observation is what a single read of a target found, or failed to find. It carries no client and no
// context: whatever produced it already did the I/O, and this layer only judges the result.
type observation struct {
	Target      target
	Found       bool
	UID         string // the UID observed, when Found
	Terminating bool   // a deletionTimestamp was set
	Err         error  // the read failed
	// WantUID is the UID this run recorded for the target, carried on the observation so that residual can
	// classify a batch without a second lookup structure the caller could populate inconsistently.
	WantUID string
}

// absence classifies what a single observation of a target proves about whether it is gone.
type absence int

const (
	// absenceUnknown is the zero value on purpose: an observation nobody has classified must never read as
	// absence by default. A new field left unset by a caller, or a code path that forgets to classify at
	// all, fails toward "still here" rather than toward "safe to report gone".
	absenceUnknown absence = iota
	absencePresent
	absenceAbsent
	// absenceForeign: the name is held by an object this run did not create. It is neither evidence ours is
	// gone nor a target to delete — deleting it would destroy another run's live state under a name
	// collision this run's own UID check (below) exists to catch, whatever refused or admitted the create.
	absenceForeign
)

// classifyAbsence decides what one observation of a target proves, against the UID this run recorded for
// it. It performs no I/O and reads no clock: the observation is the only input, so the same observation
// always classifies the same way.
func classifyAbsence(obs observation, wantUID string) absence {
	// A failed read says nothing about the object's state. Classifying it as absent would let an etcd
	// timeout or an RBAC hiccup during teardown report a clean deletion of something that is still there;
	// classifying it as present would be an equally fabricated claim in the other direction. Unknown is the
	// only claim the observation actually supports.
	if obs.Err != nil {
		return absenceUnknown
	}
	if !obs.Found {
		return absenceAbsent
	}
	// The seed is written before the first Create, so an unrecovered UID means ownership is unproven, not
	// refuted: a name match with no recorded UID to check it against must not be waved through as ours
	// either, so deletion has to wait for UID recovery rather than proceed on the name alone.
	if wantUID == "" {
		return absenceUnknown
	}
	// Checked before Terminating: a foreign object that is itself terminating is still foreign — someone
	// else's object being torn down is not our residue to wait on, and must not be reported present (which
	// would make the executor poll someone else's deletion) or absent (which would make it declare our own
	// object gone because a different one under the same name happens to be going away).
	//
	// A found object under our recorded UID is ours and still present; a found object under any other UID
	// is a name collision this run must refuse to touch, and it must never become a deletion target on the
	// strength of the name matching alone. This is the case a create-time stamp cannot rule out on its own:
	// our own object could be deleted and a DIFFERENT object recreated under the same name, between the
	// recovery pass that established wantUID and this poll — a different object's create, stamped or not,
	// so only comparing the UID this run actually observed catches it.
	if obs.UID != wantUID {
		return absenceForeign
	}
	// Found, under our own UID, and either ordinary or terminating: a deletionTimestamp means deletion was
	// requested, not that it completed — the object is still readable, still holds whatever it held, and a
	// finalizer may be blocking it indefinitely. Reporting it absent would let teardown declare victory on
	// the exact objects still stuck, so both cases classify present.
	return absencePresent
}

// residue is one target's remaining teardown work: the observation and the verdict residual reached on it.
// The verdict travels with the observation because this record is what the executor persists and what the
// next run refuses to start on, and those two consumers must not re-derive it — a consumer that recomputes
// with a different wantUID reaches a different answer than the one this record was built from.
//
// Rejected alternatives: parallel slices can desynchronize; an Absence field on observation lets a caller
// construct a read carrying a contradictory pre-set verdict and makes a zero value meaningful on an input
// type; a map[target]absence loses the declared phase order Task 1 exists to establish and returns the
// zero value on a miss.
type residue struct {
	Observation observation
	Absence     absence
}

// residual is what an executor persists as the run's remaining teardown work: everything not proven absent,
// including the unknowns that a hurried reader would otherwise wave through as fine, each carrying the
// verdict residual itself reached rather than leaving every consumer to recompute one.
func residual(obs []observation) []residue {
	var out []residue
	for _, o := range obs {
		a := classifyAbsence(o, o.WantUID)
		if a == absenceAbsent {
			continue
		}
		out = append(out, residue{Observation: o, Absence: a})
	}
	return out
}
