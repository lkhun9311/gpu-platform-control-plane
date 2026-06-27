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
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

var _ = Describe("InferenceDeployment Controller", func() {
	Context("When reconciling a resource", func() {
		const resourceName = "llama3-8b"
		const ns = "default"

		ctx := context.Background()
		key := types.NamespacedName{Name: resourceName, Namespace: ns}

		reconciler := func() *InferenceDeploymentReconciler {
			return &InferenceDeploymentReconciler{Client: k8sClient, Scheme: k8sClient.Scheme()}
		}

		newInfD := func(replicas, gpu int32) *platformv1.InferenceDeployment {
			return &platformv1.InferenceDeployment{
				ObjectMeta: metav1.ObjectMeta{Name: resourceName, Namespace: ns},
				Spec: platformv1.InferenceDeploymentSpec{
					Model:    platformv1.InferenceModel{Name: "llama3-8b", StorageURI: "s3://models/llama3-8b/v1"},
					Image:    "vllm/vllm-openai:test",
					GPUClass: "a10g",
					GPUCount: gpu,
					Replicas: replicas,
					Port:     8080,
				},
			}
		}

		AfterEach(func() {
			infd := &platformv1.InferenceDeployment{}
			if err := k8sClient.Get(ctx, key, infd); err == nil {
				Expect(k8sClient.Delete(ctx, infd)).To(Succeed())
			}
			for _, obj := range []client.Object{&appsv1.Deployment{}, &corev1.Service{}} {
				_ = k8sClient.DeleteAllOf(ctx, obj, client.InNamespace(ns))
			}
		})

		It("creates an owned Deployment and Service with the model spec", func() {
			Expect(k8sClient.Create(ctx, newInfD(2, 1))).To(Succeed())

			_, err := reconciler().Reconcile(ctx, reconcile.Request{NamespacedName: key})
			Expect(err).NotTo(HaveOccurred())

			dep := &appsv1.Deployment{}
			Expect(k8sClient.Get(ctx, key, dep)).To(Succeed())
			Expect(*dep.Spec.Replicas).To(Equal(int32(2)))
			Expect(dep.Spec.Selector.MatchLabels).To(HaveKeyWithValue("app.kubernetes.io/instance", resourceName))
			c := dep.Spec.Template.Spec.Containers[0]
			Expect(c.Image).To(Equal("vllm/vllm-openai:test"))
			Expect(c.Ports[0].Name).To(Equal("http"))
			Expect(c.Ports[0].ContainerPort).To(Equal(int32(8080)))
			gpuReq := c.Resources.Requests[nvidiaGPUResource]
			gpuLim := c.Resources.Limits[nvidiaGPUResource]
			Expect(gpuReq.Value()).To(Equal(int64(1)))
			Expect(gpuLim.Value()).To(Equal(int64(1)))
			Expect(metav1.IsControlledBy(dep, mustGet(ctx, key))).To(BeTrue())

			svc := &corev1.Service{}
			Expect(k8sClient.Get(ctx, key, svc)).To(Succeed())
			Expect(svc.Spec.Selector).To(HaveKeyWithValue("app.kubernetes.io/instance", resourceName))
			Expect(svc.Spec.Ports[0].Name).To(Equal("http"))
			Expect(svc.Spec.Ports[0].Port).To(Equal(int32(8080)))
			Expect(metav1.IsControlledBy(svc, mustGet(ctx, key))).To(BeTrue())
		})

		It("omits the GPU resource when GPUCount is zero", func() {
			Expect(k8sClient.Create(ctx, newInfD(1, 0))).To(Succeed())
			_, err := reconciler().Reconcile(ctx, reconcile.Request{NamespacedName: key})
			Expect(err).NotTo(HaveOccurred())
			dep := &appsv1.Deployment{}
			Expect(k8sClient.Get(ctx, key, dep)).To(Succeed())
			_, hasReq := dep.Spec.Template.Spec.Containers[0].Resources.Requests[nvidiaGPUResource]
			Expect(hasReq).To(BeFalse())
		})
	})
})

func mustGet(ctx context.Context, key types.NamespacedName) *platformv1.InferenceDeployment {
	infd := &platformv1.InferenceDeployment{}
	Expect(k8sClient.Get(ctx, key, infd)).To(Succeed())
	return infd
}
