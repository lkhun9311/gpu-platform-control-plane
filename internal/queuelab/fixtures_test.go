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
	"strings"
	"testing"

	kueuev1beta2 "sigs.k8s.io/kueue/apis/kueue/v1beta2"
)

const runA = "runA"

func TestReclaimFixturesVaryOnlyReclaimPolicy(t *testing.T) {
	never, err := BuildFixtures(StudyReclaim, "Never", "r1", "ns")
	if err != nil {
		t.Fatal(err)
	}
	any, err := BuildFixtures(StudyReclaim, "Any", "r1", "ns")
	if err != nil {
		t.Fatal(err)
	}

	if len(never.ClusterQueue) != 2 || len(never.LocalQueue) != 2 {
		t.Fatalf("reclaim study needs two per-tenant queues")
	}
	// Both tenants share one cohort so borrowing/reclaim is possible.
	for _, cq := range never.ClusterQueue {
		if string(cq.Spec.CohortName) != cohortName("r1") {
			t.Fatalf("ClusterQueue %s not in the shared cohort", cq.Name)
		}
		if cq.Spec.Preemption.ReclaimWithinCohort != kueuev1beta2.PreemptionPolicyNever {
			t.Fatalf("Never variant should set ReclaimWithinCohort=Never")
		}
	}
	// The one varied knob: Never vs Any.
	for i := range any.ClusterQueue {
		if any.ClusterQueue[i].Spec.Preemption.ReclaimWithinCohort != kueuev1beta2.PreemptionPolicyAny {
			t.Fatalf("Any variant should set ReclaimWithinCohort=Any")
		}
		// Everything else (name, cohort, nominal quota) is identical between the two variants at the same runID.
		if any.ClusterQueue[i].Name != never.ClusterQueue[i].Name {
			t.Fatalf("variants must share queue names at the same runID")
		}
		nq := any.ClusterQueue[i].Spec.ResourceGroups[0].Flavors[0].Resources[0].NominalQuota
		if nq.Value() != 1 {
			t.Fatalf("reclaim tenant nominal quota should be 1, got %d", nq.Value())
		}
	}
}

func TestFIFOFixturesVaryQueueingStrategy(t *testing.T) {
	strict, err := BuildFixtures(StudyFIFO, "StrictFIFO", "f1", "ns")
	if err != nil {
		t.Fatal(err)
	}
	best, err := BuildFixtures(StudyFIFO, "BestEffortFIFO", "f1", "ns")
	if err != nil {
		t.Fatal(err)
	}
	if len(strict.ClusterQueue) != 1 {
		t.Fatalf("fifo study uses one ClusterQueue")
	}
	if strict.ClusterQueue[0].Spec.QueueingStrategy != kueuev1beta2.StrictFIFO {
		t.Fatalf("StrictFIFO variant not set")
	}
	if best.ClusterQueue[0].Spec.QueueingStrategy != kueuev1beta2.BestEffortFIFO {
		t.Fatalf("BestEffortFIFO variant not set")
	}
	nq := strict.ClusterQueue[0].Spec.ResourceGroups[0].Flavors[0].Resources[0].NominalQuota
	if nq.Value() != 2 {
		t.Fatalf("fifo capacity should be 2, got %d", nq.Value())
	}
}

func TestFixtureNamesAreUniquePerRun(t *testing.T) {
	a, _ := BuildFixtures(StudyReclaim, "Any", runA, "ns")
	b, _ := BuildFixtures(StudyReclaim, "Any", "runB", "ns")
	if a.ClusterQueue[0].Name == b.ClusterQueue[0].Name {
		t.Fatalf("different runs must not share queue names: %s", a.ClusterQueue[0].Name)
	}
	if !strings.Contains(a.ClusterQueue[0].Name, runA) {
		t.Fatalf("queue name should carry the run id, got %s", a.ClusterQueue[0].Name)
	}
	// The review's isolation fix: different runs must be in DIFFERENT cohorts and use DIFFERENT flavors,
	// so a delayed old ClusterQueue cannot contribute quota into a new run's cohort.
	if a.ClusterQueue[0].Spec.CohortName == b.ClusterQueue[0].Spec.CohortName {
		t.Fatalf("different runs must not share a cohort: %s", a.ClusterQueue[0].Spec.CohortName)
	}
	if a.Flavor.Name == b.Flavor.Name {
		t.Fatalf("different runs must not share a ResourceFlavor: %s", a.Flavor.Name)
	}
	// The flavor must pin one dedicated worker so a 2-GPU pod maps to a single node.
	if a.Flavor.Spec.NodeLabels[labWorkerLabel] != runA {
		t.Fatalf("flavor should select the run's dedicated worker, got %v", a.Flavor.Spec.NodeLabels)
	}
	// The flavor must taint the worker AND carry the matching toleration Kueue injects, or admitted pods
	// could not schedule onto the isolated node.
	if len(a.Flavor.Spec.NodeTaints) != 1 || a.Flavor.Spec.NodeTaints[0].Value != runA {
		t.Fatalf("flavor should taint the dedicated worker for the run, got %v", a.Flavor.Spec.NodeTaints)
	}
	if len(a.Flavor.Spec.Tolerations) != 1 || a.Flavor.Spec.Tolerations[0].Value != runA {
		t.Fatalf("flavor should tolerate its own worker taint, got %v", a.Flavor.Spec.Tolerations)
	}
	if a.Flavor.Spec.NodeTaints[0].Key != a.Flavor.Spec.Tolerations[0].Key {
		t.Fatalf("taint and toleration keys must match for admitted pods to schedule")
	}
	// Lab objects must be labelled for the reset audit.
	if a.ClusterQueue[0].Labels[runLabel] != runA {
		t.Fatalf("ClusterQueue should carry the run label")
	}
}

func TestBuildFixturesRejectsBadInput(t *testing.T) {
	if _, err := BuildFixtures(StudyReclaim, "sometimes", "r", "ns"); err == nil {
		t.Fatalf("bad reclaim variant should error")
	}
	if _, err := BuildFixtures("nope", "Any", "r", "ns"); err == nil {
		t.Fatalf("unknown study should error")
	}
}
