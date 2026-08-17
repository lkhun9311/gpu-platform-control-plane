package main

import (
	"context"
	"strings"
	"testing"

	kueuev1beta2 "sigs.k8s.io/kueue/apis/kueue/v1beta2"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/queuelab"
)

// These specs cover what a SUCCESSFUL create can still get wrong, and what a same-transaction adoption can
// still be wrong about. Both were gaps: createOwned trusted a create that returned no error, and treated a
// matching transaction label as the end of the question.
//
// Neither is hypothetical in shape. Admission plugins rewrite labels, and Kueue has its own webhooks over
// exactly these kinds; a partially applied earlier attempt under the same transaction leaves objects whose
// names match and whose knobs do not.

// kueueScheme is testScheme plus the Kueue kinds, which the fixtures are made of.
func kueueScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	scheme := testScheme(t)
	if err := kueuev1beta2.AddToScheme(scheme); err != nil {
		t.Fatalf("add kueue to scheme: %v", err)
	}
	return scheme
}

// strippingClient returns a client whose Create drops the transaction label, standing in for an admission
// plugin that rewrites metadata.
//
// The response is what the object carries afterwards, because controller-runtime decodes the apiserver's
// answer back into the object passed to Create. That is the whole reason the check needs no second read.
func strippingClient(t *testing.T) client.Client {
	t.Helper()
	scheme := kueueScheme(t)
	return fake.NewClientBuilder().WithScheme(scheme).WithInterceptorFuncs(interceptor.Funcs{
		Create: func(ctx context.Context, c client.WithWatch, obj client.Object, opts ...client.CreateOption) error {
			if err := c.Create(ctx, obj, opts...); err != nil {
				return err
			}
			labels := obj.GetLabels()
			delete(labels, queuelab.TxLabel)
			obj.SetLabels(labels)
			return nil
		},
	}).Build()
}

func TestCreateOwnedRefusesWhenTheStampDidNotLand(t *testing.T) {
	// Mutation that turns this red: drop the post-create label check from createOwned.
	//
	// Without it the run proceeds to measure inside an object its own teardown cannot recognise, and the
	// leak is silent because Create returned no error.
	c := strippingClient(t)
	cq := &kueuev1beta2.ClusterQueue{
		ObjectMeta: metav1.ObjectMeta{Name: "cq-a", Labels: map[string]string{queuelab.TxLabel: "tx-1"}},
	}

	err := createOwned(context.Background(), c, cq, "tx-1")
	if err == nil {
		t.Fatal("accepted a create whose stamp was stripped by admission")
	}
	if !strings.Contains(err.Error(), "tx-1") {
		t.Fatalf("error does not name the transaction that was expected: %v", err)
	}

	// And it must not leave the unstamped object behind, since nothing could later identify it as this run's.
	var left kueuev1beta2.ClusterQueue
	if gerr := c.Get(context.Background(), client.ObjectKey{Name: "cq-a"}, &left); gerr == nil {
		t.Fatal("the unstamped ClusterQueue was left on the cluster")
	}
}

func TestCreateOwnedAcceptsAStampThatLanded(t *testing.T) {
	// The control. Without it a createOwned that refused every create would satisfy the spec above.
	scheme := kueueScheme(t)
	c := fake.NewClientBuilder().WithScheme(scheme).Build()
	cq := &kueuev1beta2.ClusterQueue{
		ObjectMeta: metav1.ObjectMeta{Name: "cq-ok", Labels: map[string]string{queuelab.TxLabel: "tx-1"}},
	}
	if err := createOwned(context.Background(), c, cq, "tx-1"); err != nil {
		t.Fatalf("refused a create whose stamp landed: %v", err)
	}
}

func TestCreateOwnedRefusesAdoptingADifferentMechanism(t *testing.T) {
	// Same transaction, same name, different knob. The label says WHO created it and says nothing about
	// WHAT was created, and what was created is the thing this lab measures.
	//
	// Mutation that turns this red: stop comparing reclaimWithinCohort in sameMechanism.
	scheme := kueueScheme(t)
	never := kueuev1beta2.PreemptionPolicy("Never")
	existing := &kueuev1beta2.ClusterQueue{
		ObjectMeta: metav1.ObjectMeta{Name: "cq-b", Labels: map[string]string{queuelab.TxLabel: "tx-1"}},
		Spec: kueuev1beta2.ClusterQueueSpec{
			CohortName: "cohort-1",
			Preemption: &kueuev1beta2.ClusterQueuePreemption{ReclaimWithinCohort: never},
		},
	}
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(existing).Build()

	any := kueuev1beta2.PreemptionPolicy("Any")
	want := &kueuev1beta2.ClusterQueue{
		ObjectMeta: metav1.ObjectMeta{Name: "cq-b", Labels: map[string]string{queuelab.TxLabel: "tx-1"}},
		Spec: kueuev1beta2.ClusterQueueSpec{
			CohortName: "cohort-1",
			Preemption: &kueuev1beta2.ClusterQueuePreemption{ReclaimWithinCohort: any},
		},
	}

	err := createOwned(context.Background(), c, want, "tx-1")
	if err == nil {
		t.Fatal("adopted a ClusterQueue whose reclaim policy is not the one this arm declared")
	}
	if !strings.Contains(err.Error(), "reclaimWithinCohort") {
		t.Fatalf("error does not name the knob that differed: %v", err)
	}
}

func TestCreateOwnedAdoptsAMatchingMechanism(t *testing.T) {
	// The control that keeps the check from being "refuse every adoption". Retrying after a partial setup is
	// the reason adoption exists at all, and a spec comparison that never passes would remove it.
	//
	// Mutation that turns this red: make sameMechanism return an error unconditionally.
	scheme := kueueScheme(t)
	any := kueuev1beta2.PreemptionPolicy("Any")
	spec := kueuev1beta2.ClusterQueueSpec{
		CohortName: "cohort-1",
		Preemption: &kueuev1beta2.ClusterQueuePreemption{ReclaimWithinCohort: any},
	}
	existing := &kueuev1beta2.ClusterQueue{
		ObjectMeta: metav1.ObjectMeta{Name: "cq-c", Labels: map[string]string{queuelab.TxLabel: "tx-1"}},
		Spec:       spec,
	}
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(existing).Build()

	want := &kueuev1beta2.ClusterQueue{
		ObjectMeta: metav1.ObjectMeta{Name: "cq-c", Labels: map[string]string{queuelab.TxLabel: "tx-1"}},
		Spec:       spec,
	}
	if err := createOwned(context.Background(), c, want, "tx-1"); err != nil {
		t.Fatalf("refused to adopt an object this transaction created with the same mechanism: %v", err)
	}
}

func TestCreateOwnedRefusesALocalQueuePointingElsewhere(t *testing.T) {
	// A LocalQueue aimed at another ClusterQueue routes this arm's jobs into another arm's quota, which is a
	// contaminated measurement rather than a failed one — the kind that still produces a number.
	//
	// Mutation that turns this red: stop comparing ClusterQueue in sameMechanism.
	scheme := kueueScheme(t)
	existing := &kueuev1beta2.LocalQueue{
		ObjectMeta: metav1.ObjectMeta{
			Name: "lq-a", Namespace: "ns", Labels: map[string]string{queuelab.TxLabel: "tx-1"},
		},
		Spec: kueuev1beta2.LocalQueueSpec{ClusterQueue: "cq-other"},
	}
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(existing).Build()

	want := &kueuev1beta2.LocalQueue{
		ObjectMeta: metav1.ObjectMeta{
			Name: "lq-a", Namespace: "ns", Labels: map[string]string{queuelab.TxLabel: "tx-1"},
		},
		Spec: kueuev1beta2.LocalQueueSpec{ClusterQueue: "cq-mine"},
	}
	err := createOwned(context.Background(), c, want, "tx-1")
	if err == nil {
		t.Fatal("adopted a LocalQueue pointing at a different ClusterQueue")
	}
	if !strings.Contains(err.Error(), "cq-other") {
		t.Fatalf("error does not name the ClusterQueue it actually points at: %v", err)
	}
}

// cqWith builds a ClusterQueue carrying the full set of fields the experiment is defined by, so each spec
// below can vary exactly one of them.
func cqWith(mutate func(*kueuev1beta2.ClusterQueue)) *kueuev1beta2.ClusterQueue {
	q := resource.NewQuantity(2, resource.DecimalSI)
	cq := &kueuev1beta2.ClusterQueue{
		ObjectMeta: metav1.ObjectMeta{Name: "cq-x", Labels: map[string]string{queuelab.TxLabel: "tx-1"}},
		Spec: kueuev1beta2.ClusterQueueSpec{
			CohortName:        "cohort-1",
			QueueingStrategy:  kueuev1beta2.BestEffortFIFO,
			NamespaceSelector: &metav1.LabelSelector{},
			Preemption: &kueuev1beta2.ClusterQueuePreemption{
				ReclaimWithinCohort: kueuev1beta2.PreemptionPolicy("Any"),
				WithinClusterQueue:  kueuev1beta2.PreemptionPolicyLowerPriority,
			},
			ResourceGroups: []kueuev1beta2.ResourceGroup{{
				CoveredResources: []corev1.ResourceName{"nvidia.com/gpu"},
				Flavors: []kueuev1beta2.FlavorQuotas{{
					Name: "flavor-a",
					Resources: []kueuev1beta2.ResourceQuota{{
						Name: "nvidia.com/gpu", NominalQuota: *q,
					}},
				}},
			}},
		},
	}
	if mutate != nil {
		mutate(cq)
	}
	return cq
}

// Every field this table varies DEFINES the experiment, and adopting an object that differs in any of them
// makes the run report an arm it did not execute.
//
// The queueingStrategy row is the one that mattered most: it is the FIFO study's ONLY varied knob, and the
// first version of sameMechanism did not compare it — so a StrictFIFO queue satisfied a BestEffortFIFO arm
// while the check read as coverage.
//
// Mutation that turns each row red: remove that field's comparison from sameClusterQueue or sameQuota.
func TestCreateOwnedRefusesEveryExperimentDefiningDifference(t *testing.T) {
	rows := []struct {
		name   string
		differ func(*kueuev1beta2.ClusterQueue)
		blames string
	}{
		{"queueingStrategy", func(c *kueuev1beta2.ClusterQueue) {
			c.Spec.QueueingStrategy = kueuev1beta2.StrictFIFO
		}, "queueingStrategy"},
		{"reclaimWithinCohort", func(c *kueuev1beta2.ClusterQueue) {
			c.Spec.Preemption.ReclaimWithinCohort = kueuev1beta2.PreemptionPolicy("Never")
		}, "reclaimWithinCohort"},
		{"withinClusterQueue", func(c *kueuev1beta2.ClusterQueue) {
			c.Spec.Preemption.WithinClusterQueue = kueuev1beta2.PreemptionPolicyNever
		}, "withinClusterQueue"},
		{"cohort", func(c *kueuev1beta2.ClusterQueue) { c.Spec.CohortName = "cohort-other" }, "cohort"},
		{"nominal quota", func(c *kueuev1beta2.ClusterQueue) {
			c.Spec.ResourceGroups[0].Flavors[0].Resources[0].NominalQuota = *resource.NewQuantity(8, resource.DecimalSI)
		}, "nominal quota"},
		{"flavor the quota is charged against", func(c *kueuev1beta2.ClusterQueue) {
			c.Spec.ResourceGroups[0].Flavors[0].Name = "flavor-other"
		}, "flavor"},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			scheme := kueueScheme(t)
			c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(cqWith(row.differ)).Build()
			err := createOwned(context.Background(), c, cqWith(nil), "tx-1")
			if err == nil {
				t.Fatalf("adopted a ClusterQueue differing in %s", row.name)
			}
			if !strings.Contains(err.Error(), row.blames) {
				t.Fatalf("error does not name %s: %v", row.blames, err)
			}
		})
	}

	// The control: an identical queue must still be adopted, or the check has become "refuse everything" and
	// retrying after a partial setup stops working.
	scheme := kueueScheme(t)
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(cqWith(nil)).Build()
	if err := createOwned(context.Background(), c, cqWith(nil), "tx-1"); err != nil {
		t.Fatalf("refused to adopt an identical ClusterQueue: %v", err)
	}
}

// A flavor's variant label says which arm it was BUILT for and nothing about whether its isolation survived.
// Adopting one without its node selector, taint or toleration lets this run's pods land beside another run's,
// which contaminates every timing the run reports rather than failing it.
//
// Mutation that turns this red: return nil from sameFlavor.
func TestCreateOwnedRefusesAFlavorThatLostItsIsolation(t *testing.T) {
	base := func(mutate func(*kueuev1beta2.ResourceFlavor)) *kueuev1beta2.ResourceFlavor {
		rf := &kueuev1beta2.ResourceFlavor{
			ObjectMeta: metav1.ObjectMeta{Name: "rf-x", Labels: map[string]string{queuelab.TxLabel: "tx-1"}},
			Spec: kueuev1beta2.ResourceFlavorSpec{
				NodeLabels: map[string]string{"queuelab/worker": "run-a"},
				NodeTaints: []corev1.Taint{{
					Key: "queuelab/dedicated", Value: "run-a", Effect: corev1.TaintEffectNoSchedule,
				}},
				Tolerations: []corev1.Toleration{{
					Key: "queuelab/dedicated", Value: "run-a", Effect: corev1.TaintEffectNoSchedule,
				}},
			},
		}
		if mutate != nil {
			mutate(rf)
		}
		return rf
	}

	rows := []struct {
		name   string
		differ func(*kueuev1beta2.ResourceFlavor)
		blames string
	}{
		{"node labels", func(r *kueuev1beta2.ResourceFlavor) {
			r.Spec.NodeLabels = map[string]string{"queuelab/worker": "run-b"}
		}, "nodeLabels"},
		{"taint dropped", func(r *kueuev1beta2.ResourceFlavor) { r.Spec.NodeTaints = nil }, "node taints"},
		{"toleration dropped", func(r *kueuev1beta2.ResourceFlavor) { r.Spec.Tolerations = nil }, "tolerations"},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			scheme := kueueScheme(t)
			c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(base(row.differ)).Build()
			err := createOwned(context.Background(), c, base(nil), "tx-1")
			if err == nil {
				t.Fatalf("adopted a ResourceFlavor whose %s differed", row.name)
			}
			if !strings.Contains(err.Error(), row.blames) {
				t.Fatalf("error does not name %s: %v", row.blames, err)
			}
		})
	}

	scheme := kueueScheme(t)
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(base(nil)).Build()
	if err := createOwned(context.Background(), c, base(nil), "tx-1"); err != nil {
		t.Fatalf("refused to adopt an identical ResourceFlavor: %v", err)
	}
}
