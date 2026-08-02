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
	"fmt"
	"sort"
	"strings"

	kueuev1beta2 "sigs.k8s.io/kueue/apis/kueue/v1beta2"
)

// runToken replaces the per-run identifier so two arms with DIFFERENT run ids can be compared on their
// mechanism alone; a raw DeepEqual would always differ on run-scoped names, cohorts, and flavors.
const runToken = "<RUN>"

// CQPolicy is the mechanism-defining projection of a ClusterQueue: the fields that decide how the queue
// admits, borrows, reclaims, and orders, with all run-scoped identifiers canonicalized to runToken.
//
// The review's contradiction was that a literal "exactly one JSON path differs" check must fail across
// arms whose names and references all differ by run id. Projecting to this canonical policy, then diffing
// the projections, compares the mechanism and nothing else, so the one intended knob is the only diff.
type CQPolicy struct {
	// Cohort and Flavor are canonicalized (run id -> runToken) so borrowing scope and the backing flavor
	// are compared structurally, not by their per-run names.
	Cohort string
	Flavor string
	// NominalQuota is the covered GPU quota; a silent server default that changed it would surface here.
	NominalQuota int64
	// ReclaimWithinCohort, WithinClusterQueue, QueueingStrategy are the three policy knobs a study varies.
	ReclaimWithinCohort string
	WithinClusterQueue  string
	QueueingStrategy    string
	// NamespaceSelectorEmpty records whether the queue admits from all namespaces, so a defaulted selector
	// that silently narrowed admission is caught.
	NamespaceSelectorEmpty bool
}

// ProjectCQPolicy canonicalizes one ClusterQueue into its mechanism projection under the given run id.
func ProjectCQPolicy(cq *kueuev1beta2.ClusterQueue, runID string) CQPolicy {
	p := CQPolicy{
		Cohort:           canonicalize(string(cq.Spec.CohortName), runID),
		QueueingStrategy: string(cq.Spec.QueueingStrategy),
		NamespaceSelectorEmpty: cq.Spec.NamespaceSelector != nil &&
			len(cq.Spec.NamespaceSelector.MatchLabels) == 0 &&
			len(cq.Spec.NamespaceSelector.MatchExpressions) == 0,
	}
	if cq.Spec.Preemption != nil {
		p.ReclaimWithinCohort = string(cq.Spec.Preemption.ReclaimWithinCohort)
		p.WithinClusterQueue = string(cq.Spec.Preemption.WithinClusterQueue)
	}
	if len(cq.Spec.ResourceGroups) > 0 && len(cq.Spec.ResourceGroups[0].Flavors) > 0 {
		f := cq.Spec.ResourceGroups[0].Flavors[0]
		p.Flavor = canonicalize(string(f.Name), runID)
		if len(f.Resources) > 0 {
			p.NominalQuota = f.Resources[0].NominalQuota.Value()
		}
	}
	return p
}

// canonicalize replaces the run id inside an identifier with runToken, leaving structure intact.
func canonicalize(name, runID string) string {
	if runID == "" {
		return name
	}
	return strings.ReplaceAll(name, runID, runToken)
}

// DiffCQPolicy returns the sorted names of the projection fields that differ between two policies, so a
// caller can assert the difference is EXACTLY the study's intended knob and nothing leaked.
func DiffCQPolicy(a, b CQPolicy) []string {
	var diffs []string
	add := func(name string, differ bool) {
		if differ {
			diffs = append(diffs, name)
		}
	}
	add("Cohort", a.Cohort != b.Cohort)
	add("Flavor", a.Flavor != b.Flavor)
	add("NominalQuota", a.NominalQuota != b.NominalQuota)
	add("ReclaimWithinCohort", a.ReclaimWithinCohort != b.ReclaimWithinCohort)
	add("WithinClusterQueue", a.WithinClusterQueue != b.WithinClusterQueue)
	add("QueueingStrategy", a.QueueingStrategy != b.QueueingStrategy)
	add("NamespaceSelectorEmpty", a.NamespaceSelectorEmpty != b.NamespaceSelectorEmpty)
	sort.Strings(diffs)
	return diffs
}

// studyKnobField is the single projection field each study is allowed to vary between its variants.
func studyKnobField(study Study) (string, error) {
	switch study {
	case StudyReclaim:
		return "ReclaimWithinCohort", nil
	case StudyFIFO:
		return "QueueingStrategy", nil
	default:
		return "", fmt.Errorf("unknown study %q", study)
	}
}

// AssertOneKnobDiff verifies that two variants of a study differ, across their ClusterQueues, in EXACTLY
// the study's one intended policy field and nowhere else.
//
// It pairs the two fixture sets' ClusterQueues by their canonicalized name (so it works whether the arms
// share a run id or not), projects each to its mechanism, and requires every paired queue to differ only
// in the study's knob. A queue present in one arm but not the other, or any leaked difference, is an error.
func AssertOneKnobDiff(study Study, a, b *FixtureSet, runIDa, runIDb string) error {
	knob, err := studyKnobField(study)
	if err != nil {
		return err
	}
	aByName := map[string]CQPolicy{}
	for _, cq := range a.ClusterQueue {
		aByName[canonicalize(cq.Name, runIDa)] = ProjectCQPolicy(cq, runIDa)
	}
	bByName := map[string]CQPolicy{}
	for _, cq := range b.ClusterQueue {
		bByName[canonicalize(cq.Name, runIDb)] = ProjectCQPolicy(cq, runIDb)
	}
	if len(aByName) != len(bByName) {
		return fmt.Errorf("arms have different ClusterQueue counts: %d vs %d", len(aByName), len(bByName))
	}
	sawKnob := false
	for name, ap := range aByName {
		bp, ok := bByName[name]
		if !ok {
			return fmt.Errorf("ClusterQueue %q present in one arm but not the other", name)
		}
		diffs := DiffCQPolicy(ap, bp)
		for _, d := range diffs {
			if d != knob {
				return fmt.Errorf("ClusterQueue %q leaks an unintended policy difference %q (only %q may differ)", name, d, knob)
			}
			sawKnob = true
		}
	}
	if !sawKnob {
		return fmt.Errorf("the variants do not differ in the study's knob %q at all", knob)
	}
	return nil
}
