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
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

var _ = Describe("GPUQuotaPolicy Controller", func() {
	Context("When reconciling a resource", func() {
		const resourceName = "test-resource"

		ctx := context.Background()

		// Cluster-scoped: no namespace.
		typeNamespacedName := types.NamespacedName{
			Name: resourceName,
		}
		gpuquotapolicy := &platformv1.GPUQuotaPolicy{}

		BeforeEach(func() {
			By("creating the custom resource for the Kind GPUQuotaPolicy")
			err := k8sClient.Get(ctx, typeNamespacedName, gpuquotapolicy)
			if err != nil && errors.IsNotFound(err) {
				resource := &platformv1.GPUQuotaPolicy{
					ObjectMeta: metav1.ObjectMeta{
						Name: resourceName,
					},
					Spec: platformv1.GPUQuotaPolicySpec{
						Tenant:          "team-vision",
						TargetNamespace: "team-vision",
						GPUClass:        "l40s",
						Limits: platformv1.GPUQuotaLimits{
							GPUCount: 8,
						},
					},
				}
				Expect(k8sClient.Create(ctx, resource)).To(Succeed())
			}
		})

		AfterEach(func() {
			resource := &platformv1.GPUQuotaPolicy{}
			err := k8sClient.Get(ctx, typeNamespacedName, resource)
			Expect(err).NotTo(HaveOccurred())

			By("Cleanup the specific resource instance GPUQuotaPolicy")
			Expect(k8sClient.Delete(ctx, resource)).To(Succeed())
		})
		It("should round-trip the spec and reconcile without error", func() {
			By("reading the created resource back")
			fetched := &platformv1.GPUQuotaPolicy{}
			Expect(k8sClient.Get(ctx, typeNamespacedName, fetched)).To(Succeed())
			Expect(fetched.Spec.Tenant).To(Equal("team-vision"))
			Expect(fetched.Spec.TargetNamespace).To(Equal("team-vision"))
			Expect(fetched.Spec.Limits.GPUCount).To(Equal(int32(8)))

			By("Reconciling the created resource")
			controllerReconciler := &GPUQuotaPolicyReconciler{
				Client: k8sClient,
				Scheme: k8sClient.Scheme(),
			}
			_, err := controllerReconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: typeNamespacedName,
			})
			Expect(err).NotTo(HaveOccurred())
		})

		It("should persist a status phase via the status subresource", func() {
			fetched := &platformv1.GPUQuotaPolicy{}
			Expect(k8sClient.Get(ctx, typeNamespacedName, fetched)).To(Succeed())

			fetched.Status.Phase = "Pending"
			Expect(k8sClient.Status().Update(ctx, fetched)).To(Succeed())

			updated := &platformv1.GPUQuotaPolicy{}
			Expect(k8sClient.Get(ctx, typeNamespacedName, updated)).To(Succeed())
			Expect(updated.Status.Phase).To(Equal("Pending"))
		})
	})
})
