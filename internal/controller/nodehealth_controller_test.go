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

package controller

import (
	"context"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

var _ = Describe("NodeHealth Controller", func() {
	Context("When reconciling a resource", func() {
		const resourceName = "test-nodehealth"
		const nodeName = "test-node"

		ctx := context.Background()
		nhKey := types.NamespacedName{Name: resourceName}
		nodeKey := types.NamespacedName{Name: nodeName}

		reconciler := func() *NodeHealthReconciler {
			return &NodeHealthReconciler{Client: k8sClient, Scheme: k8sClient.Scheme()}
		}

		// reconcileUntilSteady drives Reconcile a few times so the finalizer is added and
		// the status reaches its steady value.
		reconcileUntilSteady := func() {
			for range 3 {
				_, err := reconciler().Reconcile(ctx, reconcile.Request{NamespacedName: nhKey})
				Expect(err).NotTo(HaveOccurred())
			}
		}

		makeNode := func(ready corev1.ConditionStatus) *corev1.Node {
			return &corev1.Node{
				ObjectMeta: metav1.ObjectMeta{Name: nodeName},
				Status: corev1.NodeStatus{
					Conditions: []corev1.NodeCondition{
						{Type: corev1.NodeReady, Status: ready},
					},
				},
			}
		}

		BeforeEach(func() {
			By("creating a NodeHealth pointing at the target node")
			nh := &platformv1.NodeHealth{
				ObjectMeta: metav1.ObjectMeta{Name: resourceName},
				Spec:       platformv1.NodeHealthSpec{NodeName: nodeName},
			}
			Expect(k8sClient.Create(ctx, nh)).To(Succeed())
		})

		AfterEach(func() {
			nh := &platformv1.NodeHealth{}
			if err := k8sClient.Get(ctx, nhKey, nh); err == nil {
				nh.Finalizers = nil
				Expect(k8sClient.Update(ctx, nh)).To(Succeed())
				Expect(k8sClient.Delete(ctx, nh)).To(Succeed())
			}
			node := &corev1.Node{}
			if err := k8sClient.Get(ctx, nodeKey, node); err == nil {
				Expect(k8sClient.Delete(ctx, node)).To(Succeed())
			}
		})

		It("adds a finalizer and reports Ready for a ready node", func() {
			node := makeNode(corev1.ConditionTrue)
			Expect(k8sClient.Create(ctx, node)).To(Succeed())
			Expect(k8sClient.Status().Update(ctx, node)).To(Succeed())

			reconcileUntilSteady()

			got := &platformv1.NodeHealth{}
			Expect(k8sClient.Get(ctx, nhKey, got)).To(Succeed())
			Expect(got.Finalizers).To(ContainElement(nodeHealthFinalizer))
			Expect(got.Status.Phase).To(Equal(phaseReady))
			Expect(got.Status.ObservedGeneration).To(Equal(got.Generation))
			cond := findCondition(got.Status.Conditions, conditionReady)
			Expect(cond).NotTo(BeNil())
			Expect(cond.Status).To(Equal(metav1.ConditionTrue))
		})

		It("is idempotent once steady", func() {
			node := makeNode(corev1.ConditionTrue)
			Expect(k8sClient.Create(ctx, node)).To(Succeed())
			Expect(k8sClient.Status().Update(ctx, node)).To(Succeed())

			reconcileUntilSteady()

			before := &platformv1.NodeHealth{}
			Expect(k8sClient.Get(ctx, nhKey, before)).To(Succeed())

			_, err := reconciler().Reconcile(ctx, reconcile.Request{NamespacedName: nhKey})
			Expect(err).NotTo(HaveOccurred())

			after := &platformv1.NodeHealth{}
			Expect(k8sClient.Get(ctx, nhKey, after)).To(Succeed())
			Expect(after.ResourceVersion).To(Equal(before.ResourceVersion))
		})

		It("recovers from manual status drift", func() {
			node := makeNode(corev1.ConditionTrue)
			Expect(k8sClient.Create(ctx, node)).To(Succeed())
			Expect(k8sClient.Status().Update(ctx, node)).To(Succeed())

			reconcileUntilSteady()

			drifted := &platformv1.NodeHealth{}
			Expect(k8sClient.Get(ctx, nhKey, drifted)).To(Succeed())
			drifted.Status.Phase = "Quarantine"
			Expect(k8sClient.Status().Update(ctx, drifted)).To(Succeed())

			_, err := reconciler().Reconcile(ctx, reconcile.Request{NamespacedName: nhKey})
			Expect(err).NotTo(HaveOccurred())

			got := &platformv1.NodeHealth{}
			Expect(k8sClient.Get(ctx, nhKey, got)).To(Succeed())
			Expect(got.Status.Phase).To(Equal(phaseReady))
		})

		It("reports Degraded for a not-ready node", func() {
			node := makeNode(corev1.ConditionFalse)
			Expect(k8sClient.Create(ctx, node)).To(Succeed())
			Expect(k8sClient.Status().Update(ctx, node)).To(Succeed())

			reconcileUntilSteady()

			got := &platformv1.NodeHealth{}
			Expect(k8sClient.Get(ctx, nhKey, got)).To(Succeed())
			Expect(got.Status.Phase).To(Equal(phaseDegraded))
		})

		It("reports Pending when the target node is absent", func() {
			reconcileUntilSteady()

			got := &platformv1.NodeHealth{}
			Expect(k8sClient.Get(ctx, nhKey, got)).To(Succeed())
			Expect(got.Status.Phase).To(Equal(phasePending))
		})

		It("removes the finalizer on deletion", func() {
			reconcileUntilSteady()

			toDelete := &platformv1.NodeHealth{}
			Expect(k8sClient.Get(ctx, nhKey, toDelete)).To(Succeed())
			Expect(k8sClient.Delete(ctx, toDelete)).To(Succeed())

			_, err := reconciler().Reconcile(ctx, reconcile.Request{NamespacedName: nhKey})
			Expect(err).NotTo(HaveOccurred())

			err = k8sClient.Get(ctx, nhKey, &platformv1.NodeHealth{})
			Expect(errors.IsNotFound(err)).To(BeTrue())
		})
	})

	Context("mapNodeToNodeHealth", func() {
		ctx := context.Background()

		It("returns requests only for NodeHealths matching the node name", func() {
			r := &NodeHealthReconciler{Client: k8sClient, Scheme: k8sClient.Scheme()}

			match := &platformv1.NodeHealth{
				ObjectMeta: metav1.ObjectMeta{Name: "map-match"},
				Spec:       platformv1.NodeHealthSpec{NodeName: "map-node"},
			}
			other := &platformv1.NodeHealth{
				ObjectMeta: metav1.ObjectMeta{Name: "map-other"},
				Spec:       platformv1.NodeHealthSpec{NodeName: "different-node"},
			}
			Expect(k8sClient.Create(ctx, match)).To(Succeed())
			Expect(k8sClient.Create(ctx, other)).To(Succeed())
			defer func() {
				Expect(k8sClient.Delete(ctx, match)).To(Succeed())
				Expect(k8sClient.Delete(ctx, other)).To(Succeed())
			}()

			node := &corev1.Node{ObjectMeta: metav1.ObjectMeta{Name: "map-node"}}
			reqs := r.mapNodeToNodeHealth(ctx, node)

			Expect(reqs).To(HaveLen(1))
			Expect(reqs[0].Name).To(Equal("map-match"))
		})
	})
})

// findCondition returns a pointer to the condition of the given type, or nil.
func findCondition(conds []metav1.Condition, condType string) *metav1.Condition {
	for i := range conds {
		if conds[i].Type == condType {
			return &conds[i]
		}
	}
	return nil
}
