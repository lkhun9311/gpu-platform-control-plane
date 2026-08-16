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

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	kueuev1beta2 "sigs.k8s.io/kueue/apis/kueue/v1beta2"
)

// The lab creates its OWN dedicated Kueue queues rather than reusing the ones the GPUQuotaPolicy
// controller owns, because that controller reconstructs its ClusterQueues and forces
// reclaimWithinCohort:Any, so a variant applied over them would be reverted or race the reconciler.
//
// Each run therefore gets unique queue names (suffixed with a run id) so arms never collide, and only
// ONE policy knob differs between the variants of a study.

const (
	// gpuResource is the extended resource the lab schedules on.
	gpuResource = "nvidia.com/gpu"
	// labWorkerLabel is the node label the ResourceFlavor selects, so every run's quota maps to one
	// dedicated lab worker rather than borrowing capacity from wherever the fake plugin advertises it.
	labWorkerLabel = "queuelab.gpu-platform/worker"
	// labWorkerTaint is the taint key the runner puts on the dedicated worker so no unrelated Pod schedules
	// there. The flavor carries a matching toleration, which Kueue injects into admitted lab Pods, so only
	// this run's jobs land on the isolated node; without the toleration the taint would time out the Ready
	// barriers instead of isolating the run.
	labWorkerTaint = "queuelab.gpu-platform/dedicated"
	// runLabel, studyLabel, variantLabel tag every lab-owned object so a reset audit can prove no prior
	// run's objects survive into a new one.
	runLabel     = "queuelab.gpu-platform/run"
	studyLabel   = "queuelab.gpu-platform/study"
	variantLabel = "queuelab.gpu-platform/variant"
	// TxLabel is the per-attempt transaction id, stamped into the object body at Create so it commits with
	// the object or not at all. runLabel cannot serve: a run id is reused across retries, so it cannot tell
	// this attempt's leftovers from the previous attempt's.
	TxLabel = "queuelab.gpu-platform/tx"
)

// flavorName is the per-run ResourceFlavor name.
//
// It is unique per run so a delayed delete of a previous run's flavor cannot silently back a new run's quota.
func flavorName(runID string) string { return "queuelab-gpu-" + runID }

// cohortName is the per-run cohort name.
//
// The review caught that a single literal cohort shared across runs lets a delayed old ClusterQueue
// contribute quota into a new run, so the cohort is scoped to the run, not just the ClusterQueue names.
func cohortName(runID string) string { return "queuelab-cohort-" + runID }

// Study names which queue-policy knob a run varies.
type Study string

const (
	// StudyReclaim varies ClusterQueue preemption's reclaimWithinCohort (Never vs Any).
	StudyReclaim Study = "reclaim"
	// StudyFIFO varies the ClusterQueue queueingStrategy (StrictFIFO vs BestEffortFIFO).
	StudyFIFO Study = "fifo"
)

// FixtureSet is the frozen set of Kueue objects one arm applies.
//
// It is the "effective policy" the runner reads back and compares against the frozen expectation, so a
// silent server default cannot change the mechanism under test without being detected.
type FixtureSet struct {
	Flavor       *kueuev1beta2.ResourceFlavor
	ClusterQueue []*kueuev1beta2.ClusterQueue
	LocalQueue   []*kueuev1beta2.LocalQueue
}

// FixtureIdentity is the triple that decides which attempt an object belongs to.
//
// It is a struct for the reason operatorModeArgs is one (spine.go): these three were adjacent same-typed
// parameters, and a transposition would not have been caught by the compiler or by any single call site.
// It is worse here than there, because TWO call sites must agree — main renders the fixtures and enumerate
// regenerates the same set from the seed to delete them. Swap TxID and RunID in one and not the other and
// the run stamps objects whose TxLabel no teardown recognises: the run's own fixtures classify
// absenceForeign, the residue reads as somebody else's, and residueHoldsWorker releases a worker whose
// namespace is still live.
type FixtureIdentity struct {
	// TxID stamps every rendered object (see TxLabel), so this attempt's objects are distinguishable from a
	// previous attempt's under the same run id.
	TxID string
	// RunID makes every object NAME unique, so two arms or two repetitions never share a queue.
	RunID string
	// Namespace is where the LocalQueues, and the submitted jobs, live.
	Namespace string
}

// BuildFixtures renders the dedicated queues for one study variant under a unique run id.
//
// id.RunID makes every object name unique so two arms (or two repetitions) never share a queue; namespace is
// where the LocalQueues (and the submitted jobs) live. id.TxID stamps every object it renders (see TxLabel), so
// the caller can tell this attempt's objects from a previous attempt's under the same run id.
func BuildFixtures(study Study, variant string, id FixtureIdentity) (*FixtureSet, error) {
	switch study {
	case StudyReclaim:
		return reclaimFixtures(variant, id)
	case StudyFIFO:
		return fifoFixtures(variant, id)
	default:
		return nil, fmt.Errorf("unknown study %q", study)
	}
}

// reclaimFixtures builds two per-tenant ClusterQueues in one per-run cohort, identical except that the whole
// set's reclaimWithinCohort is Never or Any (the one knob), with unlimited borrowing (no borrowingLimit).
func reclaimFixtures(variant string, id FixtureIdentity) (*FixtureSet, error) {
	var policy kueuev1beta2.PreemptionPolicy
	switch variant {
	case "Never":
		policy = kueuev1beta2.PreemptionPolicyNever
	case "Any":
		policy = kueuev1beta2.PreemptionPolicyAny
	default:
		return nil, fmt.Errorf("reclaim variant must be Never or Any, got %q", variant)
	}

	fs := &FixtureSet{Flavor: labResourceFlavor(id, StudyReclaim, variant)}
	for _, tenant := range []string{"tenant-a", "tenant-b"} {
		cqName := fmt.Sprintf("ql-%s-%s-%s", StudyReclaim, tenant, id.RunID)
		cq := baseClusterQueue(cqName, 1, id, StudyReclaim, variant)
		cq.Spec.CohortName = kueuev1beta2.CohortReference(cohortName(id.RunID))
		cq.Spec.Preemption = &kueuev1beta2.ClusterQueuePreemption{
			ReclaimWithinCohort: policy,
			WithinClusterQueue:  kueuev1beta2.PreemptionPolicyLowerPriority,
		}
		fs.ClusterQueue = append(fs.ClusterQueue, cq)
		fs.LocalQueue = append(fs.LocalQueue, localQueue(tenant, cqName, id, StudyReclaim, variant))
	}
	return fs, nil
}

// fifoFixtures builds one ClusterQueue of capacity 2 whose only varied knob is the queueingStrategy.
func fifoFixtures(variant string, id FixtureIdentity) (*FixtureSet, error) {
	var strategy kueuev1beta2.QueueingStrategy
	switch variant {
	case "StrictFIFO":
		strategy = kueuev1beta2.StrictFIFO
	case "BestEffortFIFO":
		strategy = kueuev1beta2.BestEffortFIFO
	default:
		return nil, fmt.Errorf("fifo variant must be StrictFIFO or BestEffortFIFO, got %q", variant)
	}

	cqName := fmt.Sprintf("ql-%s-%s", StudyFIFO, id.RunID)
	cq := baseClusterQueue(cqName, 2, id, StudyFIFO, variant)
	cq.Spec.QueueingStrategy = strategy
	return &FixtureSet{
		Flavor:       labResourceFlavor(id, StudyFIFO, variant),
		ClusterQueue: []*kueuev1beta2.ClusterQueue{cq},
		LocalQueue:   []*kueuev1beta2.LocalQueue{localQueue("tenant-a", cqName, id, StudyFIFO, variant)},
	}, nil
}

// labLabels tags a lab-owned object with its transaction, run, study, and variant, so a reset audit can
// prove no prior run's objects survive and a teardown can tell this attempt's objects from a previous
// attempt's under the same run id.
func labLabels(id FixtureIdentity, study Study, variant string) map[string]string {
	return map[string]string{
		TxLabel:      id.TxID,
		runLabel:     id.RunID,
		studyLabel:   string(study),
		variantLabel: variant,
	}
}

// labResourceFlavor is the per-run flavor that selects the one dedicated lab worker, so quota maps to a
// single node (a 2-GPU Pod cannot span nodes) rather than to wherever the fake plugin advertises capacity.
//
// It selects the worker by label AND carries a taint plus the matching toleration: the runner taints the
// worker so nothing else schedules there, and Kueue injects this toleration into admitted lab Pods so they
// still land on it. Taint without the paired toleration would isolate the node but also time out the run's
// own Ready barriers, so the two must be defined together with the flavor.
func labResourceFlavor(id FixtureIdentity, study Study, variant string) *kueuev1beta2.ResourceFlavor {
	return &kueuev1beta2.ResourceFlavor{
		ObjectMeta: metav1.ObjectMeta{Name: flavorName(id.RunID), Labels: labLabels(id, study, variant)},
		Spec: kueuev1beta2.ResourceFlavorSpec{
			NodeLabels: map[string]string{labWorkerLabel: id.RunID},
			NodeTaints: []corev1.Taint{{
				Key:    labWorkerTaint,
				Value:  id.RunID,
				Effect: corev1.TaintEffectNoSchedule,
			}},
			Tolerations: []corev1.Toleration{{
				Key:      labWorkerTaint,
				Operator: corev1.TolerationOpEqual,
				Value:    id.RunID,
				Effect:   corev1.TaintEffectNoSchedule,
			}},
		},
	}
}

// baseClusterQueue is a ClusterQueue covering nvidia.com/gpu with the given nominal quota on the run's flavor.
func baseClusterQueue(name string, nominal int64, id FixtureIdentity, study Study, variant string) *kueuev1beta2.ClusterQueue {
	q := resource.NewQuantity(nominal, resource.DecimalSI)
	return &kueuev1beta2.ClusterQueue{
		ObjectMeta: metav1.ObjectMeta{Name: name, Labels: labLabels(id, study, variant)},
		Spec: kueuev1beta2.ClusterQueueSpec{
			NamespaceSelector: &metav1.LabelSelector{},
			ResourceGroups: []kueuev1beta2.ResourceGroup{{
				CoveredResources: []corev1.ResourceName{gpuResource},
				Flavors: []kueuev1beta2.FlavorQuotas{{
					Name: kueuev1beta2.ResourceFlavorReference(flavorName(id.RunID)),
					Resources: []kueuev1beta2.ResourceQuota{{
						Name:         gpuResource,
						NominalQuota: *q,
					}},
				}},
			}},
		},
	}
}

// localQueue binds a tenant's namespace queue to the given ClusterQueue.
func localQueue(tenant, clusterQueue string, id FixtureIdentity, study Study, variant string) *kueuev1beta2.LocalQueue {
	return &kueuev1beta2.LocalQueue{
		ObjectMeta: metav1.ObjectMeta{Name: "ql-" + tenant, Namespace: id.Namespace, Labels: labLabels(id, study, variant)},
		Spec:       kueuev1beta2.LocalQueueSpec{ClusterQueue: kueuev1beta2.ClusterQueueReference(clusterQueue)},
	}
}
