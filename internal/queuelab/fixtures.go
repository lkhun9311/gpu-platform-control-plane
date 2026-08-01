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
	// labFlavor is the shared, empty ResourceFlavor every lab ClusterQueue references.
	//
	// An empty flavor matches any node advertising nvidia.com/gpu, including the fake device plugin.
	labFlavor = "queuelab-gpu"
	// labCohort is the single cohort the reclaim study's per-tenant ClusterQueues join, so borrowing and reclaim are possible.
	labCohort = "queuelab-cohort"
	// gpuResource is the extended resource the lab schedules on.
	gpuResource = "nvidia.com/gpu"
)

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

// BuildFixtures renders the dedicated queues for one study variant under a unique run id.
//
// runID makes every object name unique so two arms (or two repetitions) never share a queue; namespace is
// where the LocalQueues (and the submitted jobs) live.
func BuildFixtures(study Study, variant, runID, namespace string) (*FixtureSet, error) {
	switch study {
	case StudyReclaim:
		return reclaimFixtures(variant, runID, namespace)
	case StudyFIFO:
		return fifoFixtures(variant, runID, namespace)
	default:
		return nil, fmt.Errorf("unknown study %q", study)
	}
}

// reclaimFixtures builds two per-tenant ClusterQueues in one cohort, identical except that the whole set's
// reclaimWithinCohort is Never or Any (the one knob), with unlimited borrowing (no borrowingLimit).
func reclaimFixtures(variant, runID, namespace string) (*FixtureSet, error) {
	var policy kueuev1beta2.PreemptionPolicy
	switch variant {
	case "Never":
		policy = kueuev1beta2.PreemptionPolicyNever
	case "Any":
		policy = kueuev1beta2.PreemptionPolicyAny
	default:
		return nil, fmt.Errorf("reclaim variant must be Never or Any, got %q", variant)
	}

	fs := &FixtureSet{Flavor: labResourceFlavor()}
	for _, tenant := range []string{"tenant-a", "tenant-b"} {
		cqName := fmt.Sprintf("ql-%s-%s-%s", StudyReclaim, tenant, runID)
		cq := baseClusterQueue(cqName, 1)
		cq.Spec.CohortName = labCohort
		cq.Spec.Preemption = &kueuev1beta2.ClusterQueuePreemption{
			ReclaimWithinCohort: policy,
			WithinClusterQueue:  kueuev1beta2.PreemptionPolicyLowerPriority,
		}
		fs.ClusterQueue = append(fs.ClusterQueue, cq)
		fs.LocalQueue = append(fs.LocalQueue, localQueue(tenant, namespace, cqName))
	}
	return fs, nil
}

// fifoFixtures builds one ClusterQueue of capacity 2 whose only varied knob is the queueingStrategy.
func fifoFixtures(variant, runID, namespace string) (*FixtureSet, error) {
	var strategy kueuev1beta2.QueueingStrategy
	switch variant {
	case "StrictFIFO":
		strategy = kueuev1beta2.StrictFIFO
	case "BestEffortFIFO":
		strategy = kueuev1beta2.BestEffortFIFO
	default:
		return nil, fmt.Errorf("fifo variant must be StrictFIFO or BestEffortFIFO, got %q", variant)
	}

	cqName := fmt.Sprintf("ql-%s-%s", StudyFIFO, runID)
	cq := baseClusterQueue(cqName, 2)
	cq.Spec.QueueingStrategy = strategy
	return &FixtureSet{
		Flavor:       labResourceFlavor(),
		ClusterQueue: []*kueuev1beta2.ClusterQueue{cq},
		LocalQueue:   []*kueuev1beta2.LocalQueue{localQueue("tenant-a", namespace, cqName)},
	}, nil
}

// labResourceFlavor is the shared empty flavor.
func labResourceFlavor() *kueuev1beta2.ResourceFlavor {
	return &kueuev1beta2.ResourceFlavor{ObjectMeta: metav1.ObjectMeta{Name: labFlavor}}
}

// baseClusterQueue is a ClusterQueue covering nvidia.com/gpu with the given nominal quota on the shared flavor.
func baseClusterQueue(name string, nominal int64) *kueuev1beta2.ClusterQueue {
	q := resource.NewQuantity(nominal, resource.DecimalSI)
	return &kueuev1beta2.ClusterQueue{
		ObjectMeta: metav1.ObjectMeta{Name: name},
		Spec: kueuev1beta2.ClusterQueueSpec{
			NamespaceSelector: &metav1.LabelSelector{},
			ResourceGroups: []kueuev1beta2.ResourceGroup{{
				CoveredResources: []corev1.ResourceName{gpuResource},
				Flavors: []kueuev1beta2.FlavorQuotas{{
					Name: kueuev1beta2.ResourceFlavorReference(labFlavor),
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
func localQueue(tenant, namespace, clusterQueue string) *kueuev1beta2.LocalQueue {
	return &kueuev1beta2.LocalQueue{
		ObjectMeta: metav1.ObjectMeta{Name: "ql-" + tenant, Namespace: namespace},
		Spec:       kueuev1beta2.LocalQueueSpec{ClusterQueue: kueuev1beta2.ClusterQueueReference(clusterQueue)},
	}
}
