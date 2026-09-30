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
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// GpuSharingBenchmark has no controller. These specs exercise the CRD's own refusals, which is where the
// experiment protocol is enforced: three CEL rules and the numeric floors decide whether a run can be
// declared at all, and a rule that lives only in a marker comment enforces nothing.
var _ = Describe("GpuSharingBenchmark", func() {
	ctx := context.Background()

	// validBenchmark is the sample in config/samples, in Go. Each spec below breaks exactly one thing about
	// it, so a refusal names the rule under test rather than whichever check happens to run first.
	validBenchmark := func(name string) *platformv1.GpuSharingBenchmark {
		return &platformv1.GpuSharingBenchmark{
			ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default"},
			Spec: platformv1.GpuSharingBenchmarkSpec{
				GPUClass:    "a10g",
				SharingMode: "sharedInstance",
				Baseline: platformv1.BenchmarkWorkload{
					Tenant: "tenant-premium", Model: "llama3-8b", QPS: "2.0",
					InputTokens: 256, OutputTokens: 128,
				},
				Contender: platformv1.BenchmarkWorkload{
					Tenant: "tenant-standard", Model: "llama3-8b", QPS: "6.0",
					InputTokens: 8192, OutputTokens: 256,
				},
				Repetitions:       5,
				WarmupRequests:    50,
				MinRequestsPerRun: 1000,
				Load: platformv1.LoadSpec{
					Mode: "openLoop", Generator: "genai-perf",
					Streaming: true, TimeoutMs: 60000, Retries: 0,
				},
			},
		}
	}

	It("accepts the registered sample, and admits no status.result of its own accord", func() {
		b := validBenchmark("gsb-valid")
		Expect(k8sClient.Create(ctx, b)).To(Succeed())
		DeferCleanup(func() { Expect(k8sClient.Delete(ctx, b)).To(Succeed()) })

		var got platformv1.GpuSharingBenchmark
		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: "gsb-valid", Namespace: "default"}, &got)).To(Succeed())
		// Nothing writes a result but a real-GPU run, so a freshly created object must not have one. This is
		// the assertion that would fail if a placeholder ever crept into the type's defaults.
		Expect(got.Status.Result).To(BeNil())
		Expect(got.Status.Phase).To(BeEmpty())
	})

	It("refuses a retry, because a retry repairs the tail it measures", func() {
		b := validBenchmark("gsb-retry")
		b.Spec.Load.Retries = 1
		err := k8sClient.Create(ctx, b)
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("spec.load.retries must be 0"))
	})

	It("refuses sharedInstance with two different models, because one instance serves one model", func() {
		b := validBenchmark("gsb-models")
		b.Spec.Contender.Model = "mistral-7b"
		err := k8sClient.Create(ctx, b)
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("baseline.model and contender.model must be equal"))
	})

	It("allows two models when the topology is not one shared instance", func() {
		// The same edit that was refused above, with the mode that makes it coherent: timeSlicing puts
		// separate pods on one GPU, so the two sides may serve different models. Without this the previous
		// spec would also pass against a rule that refused every two-model benchmark.
		b := validBenchmark("gsb-timeslicing")
		b.Spec.SharingMode = "timeSlicing"
		b.Spec.Contender.Model = "mistral-7b"
		Expect(k8sClient.Create(ctx, b)).To(Succeed())
		DeferCleanup(func() { Expect(k8sClient.Delete(ctx, b)).To(Succeed()) })
	})

	It("refuses an edit to the fields that define the experiment", func() {
		b := validBenchmark("gsb-immutable")
		Expect(k8sClient.Create(ctx, b)).To(Succeed())
		DeferCleanup(func() { Expect(k8sClient.Delete(ctx, b)).To(Succeed()) })

		var got platformv1.GpuSharingBenchmark
		key := types.NamespacedName{Name: "gsb-immutable", Namespace: "default"}
		Expect(k8sClient.Get(ctx, key, &got)).To(Succeed())
		got.Spec.Contender.QPS = "9.0"
		err := k8sClient.Update(ctx, &got)
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("immutable"))
	})

	It("allows an edit to a field that does not define the experiment", func() {
		// repetitions and warmupRequests are outside the immutability rule on purpose: raising the repetition
		// count strengthens a result rather than redefining it. This spec is what keeps the rule from being
		// read as "the whole spec is frozen", which the message does not say and the rule does not do.
		b := validBenchmark("gsb-mutable-reps")
		Expect(k8sClient.Create(ctx, b)).To(Succeed())
		DeferCleanup(func() { Expect(k8sClient.Delete(ctx, b)).To(Succeed()) })

		var got platformv1.GpuSharingBenchmark
		key := types.NamespacedName{Name: "gsb-mutable-reps", Namespace: "default"}
		Expect(k8sClient.Get(ctx, key, &got)).To(Succeed())
		got.Spec.Repetitions = 7
		Expect(k8sClient.Update(ctx, &got)).To(Succeed())
	})

	It("refuses repetitions below five and a sample floor below a thousand", func() {
		// Both are p99 claims about sample size rather than style: three repetitions and a few hundred
		// requests produce a tail figure decided by a handful of samples.
		few := validBenchmark("gsb-few-reps")
		few.Spec.Repetitions = 3
		err := k8sClient.Create(ctx, few)
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("spec.repetitions"))

		small := validBenchmark("gsb-small-sample")
		small.Spec.MinRequestsPerRun = 200
		err = k8sClient.Create(ctx, small)
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("spec.minRequestsPerRun"))
	})

	It("refuses a closed-loop arrival mode", func() {
		// The enum admits openLoop alone. A closed-loop client waits for each response before sending the
		// next, so its own queueing delay suppresses the arrivals that would have revealed it.
		b := validBenchmark("gsb-closedloop")
		b.Spec.Load.Mode = "closedLoop"
		err := k8sClient.Create(ctx, b)
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("spec.load.mode"))
	})

	It("refuses an unknown sharing mode", func() {
		b := validBenchmark("gsb-badmode")
		b.Spec.SharingMode = "magic"
		err := k8sClient.Create(ctx, b)
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("spec.sharingMode"))
	})
})
