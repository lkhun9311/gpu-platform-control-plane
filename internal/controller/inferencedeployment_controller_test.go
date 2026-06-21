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

var _ = Describe("InferenceDeployment Controller", func() {
	Context("When reconciling a resource", func() {
		const resourceName = "test-inference"
		const resourceNamespace = "default"

		ctx := context.Background()

		typeNamespacedName := types.NamespacedName{
			Name:      resourceName,
			Namespace: resourceNamespace,
		}
		inferencedeployment := &platformv1.InferenceDeployment{}

		BeforeEach(func() {
			By("creating the custom resource for the Kind InferenceDeployment")
			err := k8sClient.Get(ctx, typeNamespacedName, inferencedeployment)
			if err != nil && errors.IsNotFound(err) {
				resource := &platformv1.InferenceDeployment{
					ObjectMeta: metav1.ObjectMeta{
						Name:      resourceName,
						Namespace: resourceNamespace,
					},
					Spec: platformv1.InferenceDeploymentSpec{
						Model: platformv1.InferenceModel{
							Name:       "llama3-8b",
							StorageURI: "s3://models/llama3-8b",
						},
						Image:    "vllm/vllm-openai:v0.6.0",
						GPUClass: "l40s",
						GPUCount: 1,
						Replicas: 2,
						Port:     8080,
					},
				}
				Expect(k8sClient.Create(ctx, resource)).To(Succeed())
			}
		})

		AfterEach(func() {
			resource := &platformv1.InferenceDeployment{}
			err := k8sClient.Get(ctx, typeNamespacedName, resource)
			Expect(err).NotTo(HaveOccurred())

			By("Cleanup the specific resource instance InferenceDeployment")
			Expect(k8sClient.Delete(ctx, resource)).To(Succeed())
		})
		It("should round-trip the spec and reconcile without error", func() {
			By("reading the created resource back")
			fetched := &platformv1.InferenceDeployment{}
			Expect(k8sClient.Get(ctx, typeNamespacedName, fetched)).To(Succeed())
			Expect(fetched.Spec.Model.Name).To(Equal("llama3-8b"))
			Expect(fetched.Spec.Model.StorageURI).To(Equal("s3://models/llama3-8b"))
			Expect(fetched.Spec.Image).To(Equal("vllm/vllm-openai:v0.6.0"))
			Expect(fetched.Spec.GPUCount).To(Equal(int32(1)))
			Expect(fetched.Spec.Replicas).To(Equal(int32(2)))
			Expect(fetched.Spec.Port).To(Equal(int32(8080)))

			By("Reconciling the created resource")
			controllerReconciler := &InferenceDeploymentReconciler{
				Client: k8sClient,
				Scheme: k8sClient.Scheme(),
			}
			_, err := controllerReconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: typeNamespacedName,
			})
			Expect(err).NotTo(HaveOccurred())
		})

		It("should persist status phase and readyReplicas via the status subresource", func() {
			fetched := &platformv1.InferenceDeployment{}
			Expect(k8sClient.Get(ctx, typeNamespacedName, fetched)).To(Succeed())

			fetched.Status.Phase = "Pending"
			fetched.Status.ReadyReplicas = 0
			Expect(k8sClient.Status().Update(ctx, fetched)).To(Succeed())

			updated := &platformv1.InferenceDeployment{}
			Expect(k8sClient.Get(ctx, typeNamespacedName, updated)).To(Succeed())
			Expect(updated.Status.Phase).To(Equal("Pending"))
			Expect(updated.Status.ReadyReplicas).To(Equal(int32(0)))
		})
	})
})
