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
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
	kueuev1beta1 "sigs.k8s.io/kueue/apis/kueue/v1beta1"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

var _ = Describe("GPUQuotaPolicy Kueue sync", func() {
	Context("When trainingQuota is set", func() {
		const resourceName = "test-quota-kueue"
		const tenant = "team-kueue"
		const targetNS = "tenant-kueue-ns"
		const gpuFlavor = "gpu"

		ctx := context.Background()
		key := types.NamespacedName{Name: resourceName}
		cqKey := types.NamespacedName{Name: "gpu-" + tenant}
		lqKey := types.NamespacedName{Name: "gpu-" + tenant, Namespace: targetNS}

		reconciler := func() *GPUQuotaPolicyReconciler {
			return &GPUQuotaPolicyReconciler{Client: k8sClient, Scheme: k8sClient.Scheme()}
		}

		reconcileUntilSteady := func() {
			for range 3 {
				_, err := reconciler().Reconcile(ctx, reconcile.Request{NamespacedName: key})
				Expect(err).NotTo(HaveOccurred())
			}
		}

		BeforeEach(func() {
			By("ensuring the target namespace exists")
			ns := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: targetNS}}
			if err := k8sClient.Create(ctx, ns); err != nil && !errors.IsAlreadyExists(err) {
				Expect(err).NotTo(HaveOccurred())
			}

			By("ensuring the shared gpu ResourceFlavor fixture exists")
			flavor := &kueuev1beta1.ResourceFlavor{ObjectMeta: metav1.ObjectMeta{Name: gpuFlavor}}
			if err := k8sClient.Create(ctx, flavor); err != nil && !errors.IsAlreadyExists(err) {
				Expect(err).NotTo(HaveOccurred())
			}
		})

		AfterEach(func() {
			policy := &platformv1.GPUQuotaPolicy{}
			if err := k8sClient.Get(ctx, key, policy); err == nil {
				policy.Finalizers = nil
				Expect(k8sClient.Update(ctx, policy)).To(Succeed())
				Expect(k8sClient.Delete(ctx, policy)).To(Succeed())
			}
			rqKey := types.NamespacedName{Name: "gpuquota-" + resourceName, Namespace: targetNS}
			rq := &corev1.ResourceQuota{}
			if err := k8sClient.Get(ctx, rqKey, rq); err == nil {
				Expect(k8sClient.Delete(ctx, rq)).To(Succeed())
			}
			lq := &kueuev1beta1.LocalQueue{}
			if err := k8sClient.Get(ctx, lqKey, lq); err == nil {
				Expect(k8sClient.Delete(ctx, lq)).To(Succeed())
			}
			cq := &kueuev1beta1.ClusterQueue{}
			if err := k8sClient.Get(ctx, cqKey, cq); err == nil {
				Expect(k8sClient.Delete(ctx, cq)).To(Succeed())
			}
		})

		It("creates a ClusterQueue and LocalQueue when trainingQuota is true", func() {
			policy := &platformv1.GPUQuotaPolicy{
				ObjectMeta: metav1.ObjectMeta{Name: resourceName},
				Spec: platformv1.GPUQuotaPolicySpec{
					Tenant:          tenant,
					TargetNamespace: targetNS,
					Limits:          platformv1.GPUQuotaLimits{GPUCount: 12},
					TrainingQuota:   true,
				},
			}
			Expect(k8sClient.Create(ctx, policy)).To(Succeed())

			reconcileUntilSteady()

			cq := &kueuev1beta1.ClusterQueue{}
			Expect(k8sClient.Get(ctx, cqKey, cq)).To(Succeed())
			Expect(string(cq.Spec.Cohort)).To(Equal("gpu-platform"))
			Expect(cq.Spec.ResourceGroups).To(HaveLen(1))
			Expect(cq.Spec.ResourceGroups[0].CoveredResources).To(ConsistOf(corev1.ResourceName("nvidia.com/gpu")))
			Expect(cq.Spec.ResourceGroups[0].Flavors).To(HaveLen(1))
			Expect(string(cq.Spec.ResourceGroups[0].Flavors[0].Name)).To(Equal(gpuFlavor))
			nominal := cq.Spec.ResourceGroups[0].Flavors[0].Resources[0].NominalQuota
			Expect(nominal.Value()).To(Equal(int64(12)))
			Expect(cq.Spec.Preemption).NotTo(BeNil())
			Expect(cq.Spec.Preemption.ReclaimWithinCohort).To(Equal(kueuev1beta1.PreemptionPolicyAny))
			Expect(cq.Spec.Preemption.WithinClusterQueue).To(Equal(kueuev1beta1.PreemptionPolicyLowerPriority))

			got := &platformv1.GPUQuotaPolicy{}
			Expect(k8sClient.Get(ctx, key, got)).To(Succeed())
			Expect(metav1.IsControlledBy(cq, got)).To(BeTrue())

			lq := &kueuev1beta1.LocalQueue{}
			Expect(k8sClient.Get(ctx, lqKey, lq)).To(Succeed())
			Expect(string(lq.Spec.ClusterQueue)).To(Equal("gpu-" + tenant))
			Expect(metav1.IsControlledBy(lq, got)).To(BeTrue())
		})

		It("creates neither a ClusterQueue nor a LocalQueue when trainingQuota is false", func() {
			policy := &platformv1.GPUQuotaPolicy{
				ObjectMeta: metav1.ObjectMeta{Name: resourceName},
				Spec: platformv1.GPUQuotaPolicySpec{
					Tenant:          tenant,
					TargetNamespace: targetNS,
					Limits:          platformv1.GPUQuotaLimits{GPUCount: 12},
					TrainingQuota:   false,
				},
			}
			Expect(k8sClient.Create(ctx, policy)).To(Succeed())

			reconcileUntilSteady()

			Expect(errors.IsNotFound(k8sClient.Get(ctx, cqKey, &kueuev1beta1.ClusterQueue{}))).To(BeTrue())
			Expect(errors.IsNotFound(k8sClient.Get(ctx, lqKey, &kueuev1beta1.LocalQueue{}))).To(BeTrue())
		})

		It("deletes the ClusterQueue and LocalQueue when trainingQuota flips from true to false", func() {
			policy := &platformv1.GPUQuotaPolicy{
				ObjectMeta: metav1.ObjectMeta{Name: resourceName},
				Spec: platformv1.GPUQuotaPolicySpec{
					Tenant:          tenant,
					TargetNamespace: targetNS,
					Limits:          platformv1.GPUQuotaLimits{GPUCount: 12},
					TrainingQuota:   true,
				},
			}
			Expect(k8sClient.Create(ctx, policy)).To(Succeed())
			reconcileUntilSteady()

			Expect(k8sClient.Get(ctx, cqKey, &kueuev1beta1.ClusterQueue{})).To(Succeed())
			Expect(k8sClient.Get(ctx, lqKey, &kueuev1beta1.LocalQueue{})).To(Succeed())

			got := &platformv1.GPUQuotaPolicy{}
			Expect(k8sClient.Get(ctx, key, got)).To(Succeed())
			got.Spec.TrainingQuota = false
			Expect(k8sClient.Update(ctx, got)).To(Succeed())

			reconcileUntilSteady()

			Expect(errors.IsNotFound(k8sClient.Get(ctx, cqKey, &kueuev1beta1.ClusterQueue{}))).To(BeTrue())
			Expect(errors.IsNotFound(k8sClient.Get(ctx, lqKey, &kueuev1beta1.LocalQueue{}))).To(BeTrue())
		})

		It("deletes the ClusterQueue and LocalQueue on policy deletion", func() {
			policy := &platformv1.GPUQuotaPolicy{
				ObjectMeta: metav1.ObjectMeta{Name: resourceName},
				Spec: platformv1.GPUQuotaPolicySpec{
					Tenant:          tenant,
					TargetNamespace: targetNS,
					Limits:          platformv1.GPUQuotaLimits{GPUCount: 12},
					TrainingQuota:   true,
				},
			}
			Expect(k8sClient.Create(ctx, policy)).To(Succeed())
			reconcileUntilSteady()

			Expect(k8sClient.Get(ctx, cqKey, &kueuev1beta1.ClusterQueue{})).To(Succeed())
			Expect(k8sClient.Get(ctx, lqKey, &kueuev1beta1.LocalQueue{})).To(Succeed())

			toDelete := &platformv1.GPUQuotaPolicy{}
			Expect(k8sClient.Get(ctx, key, toDelete)).To(Succeed())
			Expect(k8sClient.Delete(ctx, toDelete)).To(Succeed())

			reconcileUntilSteady()

			Expect(errors.IsNotFound(k8sClient.Get(ctx, key, &platformv1.GPUQuotaPolicy{}))).To(BeTrue())
			Expect(errors.IsNotFound(k8sClient.Get(ctx, cqKey, &kueuev1beta1.ClusterQueue{}))).To(BeTrue())
			Expect(errors.IsNotFound(k8sClient.Get(ctx, lqKey, &kueuev1beta1.LocalQueue{}))).To(BeTrue())
		})

		It("corrects a mutated ClusterQueue nominal quota (drift recovery)", func() {
			policy := &platformv1.GPUQuotaPolicy{
				ObjectMeta: metav1.ObjectMeta{Name: resourceName},
				Spec: platformv1.GPUQuotaPolicySpec{
					Tenant:          tenant,
					TargetNamespace: targetNS,
					Limits:          platformv1.GPUQuotaLimits{GPUCount: 12},
					TrainingQuota:   true,
				},
			}
			Expect(k8sClient.Create(ctx, policy)).To(Succeed())
			reconcileUntilSteady()

			cq := &kueuev1beta1.ClusterQueue{}
			Expect(k8sClient.Get(ctx, cqKey, cq)).To(Succeed())
			cq.Spec.ResourceGroups[0].Flavors[0].Resources[0].NominalQuota = *resource.NewQuantity(99, resource.DecimalSI)
			Expect(k8sClient.Update(ctx, cq)).To(Succeed())

			reconcileUntilSteady()

			corrected := &kueuev1beta1.ClusterQueue{}
			Expect(k8sClient.Get(ctx, cqKey, corrected)).To(Succeed())
			nominal := corrected.Spec.ResourceGroups[0].Flavors[0].Resources[0].NominalQuota
			Expect(nominal.Value()).To(Equal(int64(12)))
		})
	})
})
