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
	"fmt"
	"os"
	"path/filepath"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/yaml"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// GpuSharingBenchmark has no controller. These specs exercise the CRD's own refusals, which is where the
// experiment protocol is enforced: the spec is a registration, and what the schema will not accept is the
// only part of that registration the cluster can keep.
//
// Several of these exist because an external review constructed the case and a run against a real apiserver
// confirmed it. Those are marked where they sit.
var _ = Describe("GpuSharingBenchmark", func() {
	ctx := context.Background()

	// validBenchmark mirrors config/samples. One spec below loads that YAML itself rather than this copy,
	// because a hand-written Go twin passes while the sample drifts away from it.
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

	It("accepts the registered sample as it is committed, not a copy of it", func() {
		// Read as unstructured, so an omitted field and an explicit zero stay distinguishable -- decoding
		// into the Go type collapses them, which is exactly the distinction the immutability rule turns on.
		path := filepath.Join("..", "..", "config", "samples", "platform_v1_gpusharingbenchmark.yaml")
		raw, err := os.ReadFile(path)
		Expect(err).NotTo(HaveOccurred())

		var obj map[string]any
		Expect(yaml.Unmarshal(raw, &obj)).To(Succeed())
		u := &unstructured.Unstructured{Object: obj}
		u.SetNamespace("default")
		Expect(k8sClient.Create(ctx, u)).To(Succeed())
		DeferCleanup(func() { Expect(k8sClient.Delete(ctx, u)).To(Succeed()) })

		var got platformv1.GpuSharingBenchmark
		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: u.GetName(), Namespace: "default"}, &got)).To(Succeed())
		// Nothing writes a result but a real-GPU run. This is not much of a guard while no writer exists,
		// and it is kept as the place a placeholder default would be caught.
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
		// The same edit that was refused above, with the mode that makes it coherent. Without this, a rule
		// that refused every two-model benchmark would look correct.
		b := validBenchmark("gsb-timeslicing")
		b.Spec.SharingMode = "timeSlicing"
		b.Spec.Contender.Model = "mistral-7b"
		Expect(k8sClient.Create(ctx, b)).To(Succeed())
		DeferCleanup(func() { Expect(k8sClient.Delete(ctx, b)).To(Succeed()) })
	})

	It("refuses one tenant on both sides of the comparison", func() {
		// Found by review: both identity lookups succeed, the requests share a quota and a metrics label, and
		// the result measures intra-tenant contention while claiming to measure isolation between tenants.
		b := validBenchmark("gsb-same-tenant")
		b.Spec.Contender.Tenant = b.Spec.Baseline.Tenant
		err := k8sClient.Create(ctx, b)
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("must differ"))
	})

	Context("the spec is a registration and cannot be edited", func() {
		// Every field is frozen, not only the four that obviously define the experiment. Raising a
		// repetition count after seeing an inconclusive result changes the stopping rule, and changing
		// gpuClass mid-comparison compares different hardware -- so a protocol change is a new CR.
		//
		// One spec per field, deliberately. A single edit to contender.qps would pass even if only one
		// conjunct of an older four-way rule survived.
		DescribeTable("refuses an edit to",
			func(mutate func(*platformv1.GpuSharingBenchmark)) {
				name := fmt.Sprintf("gsb-frozen-%d", GinkgoRandomSeed()%100000)
				b := validBenchmark(name)
				Expect(k8sClient.Create(ctx, b)).To(Succeed())
				DeferCleanup(func() { Expect(k8sClient.Delete(ctx, b)).To(Succeed()) })

				var got platformv1.GpuSharingBenchmark
				Expect(k8sClient.Get(ctx, types.NamespacedName{Name: name, Namespace: "default"}, &got)).To(Succeed())
				mutate(&got)
				err := k8sClient.Update(ctx, &got)
				Expect(err).To(HaveOccurred())
				Expect(err.Error()).To(ContainSubstring("the spec is a registration and is immutable"))
			},
			Entry("gpuClass", func(b *platformv1.GpuSharingBenchmark) { b.Spec.GPUClass = "h100" }),
			Entry("sharingMode", func(b *platformv1.GpuSharingBenchmark) { b.Spec.SharingMode = "timeSlicing" }),
			Entry("baseline.qps", func(b *platformv1.GpuSharingBenchmark) { b.Spec.Baseline.QPS = "3.0" }),
			Entry("contender.qps", func(b *platformv1.GpuSharingBenchmark) { b.Spec.Contender.QPS = "9.0" }),
			Entry("load.generator", func(b *platformv1.GpuSharingBenchmark) { b.Spec.Load.Generator = "other" }),
			Entry("load.timeoutMs", func(b *platformv1.GpuSharingBenchmark) { b.Spec.Load.TimeoutMs = 30000 }),
			Entry("repetitions", func(b *platformv1.GpuSharingBenchmark) { b.Spec.Repetitions = 7 }),
			Entry("warmupRequests", func(b *platformv1.GpuSharingBenchmark) { b.Spec.WarmupRequests = 0 }),
			Entry("minRequestsPerRun", func(b *platformv1.GpuSharingBenchmark) { b.Spec.MinRequestsPerRun = 2000 }),
		)

		It("still allows a metadata edit, and an object with explicit zero values is not frozen out", func() {
			// The regression for the trap this type shipped with. streaming and warmupRequests were optional
			// with omitempty; an object created with streaming: false lost the field on a Go round-trip, the
			// whole-spec comparison saw a field disappear, and every later update was refused -- including to
			// fields the documentation called mutable. Both are required now, and this proves the round-trip
			// is faithful rather than asserting it.
			u := &unstructured.Unstructured{Object: map[string]any{
				"apiVersion": "platform.lkhun9311.github.io/v1",
				"kind":       "GpuSharingBenchmark",
				"metadata":   map[string]any{"name": "gsb-explicit-zeros", "namespace": "default"},
				"spec": map[string]any{
					"gpuClass":    "a10g",
					"sharingMode": "sharedInstance",
					"baseline":    map[string]any{"tenant": "tp", "model": "m", "qps": "2.0", "inputTokens": int64(256), "outputTokens": int64(128)},
					"contender":   map[string]any{"tenant": "ts", "model": "m", "qps": "6.0", "inputTokens": int64(8192), "outputTokens": int64(256)},
					"repetitions": int64(5), "warmupRequests": int64(0), "minRequestsPerRun": int64(1000),
					"load": map[string]any{
						"mode": "openLoop", "generator": "g", "streaming": false,
						"timeoutMs": int64(60000), "retries": int64(0),
					},
				},
			}}
			Expect(k8sClient.Create(ctx, u)).To(Succeed())
			DeferCleanup(func() { Expect(k8sClient.Delete(ctx, u)).To(Succeed()) })

			var got platformv1.GpuSharingBenchmark
			key := types.NamespacedName{Name: "gsb-explicit-zeros", Namespace: "default"}
			Expect(k8sClient.Get(ctx, key, &got)).To(Succeed())
			Expect(got.Spec.Load.Streaming).To(BeFalse())
			Expect(got.Spec.WarmupRequests).To(BeZero())

			// A label is not the spec, so this must succeed. Under the old shape it did not.
			got.Labels = map[string]string{"run": "1"}
			Expect(k8sClient.Update(ctx, &got)).To(Succeed())
		})
	})

	Context("the completion invariant lives on status", func() {
		// Status writes go through the status subresource; an ordinary Update does not carry them, so a rule
		// on status can only be exercised through Status().Update.
		newStanding := func(name string) *platformv1.GpuSharingBenchmark {
			b := validBenchmark(name)
			Expect(k8sClient.Create(ctx, b)).To(Succeed())
			DeferCleanup(func() { Expect(k8sClient.Delete(ctx, b)).To(Succeed()) })
			return b
		}

		It("refuses Completed with no result at all", func() {
			b := newStanding("gsb-done-noresult")
			b.Status.Phase = "Completed"
			err := k8sClient.Status().Update(ctx, b)
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("non-empty status.result.reportUri"))
		})

		It("refuses Completed with a result that has no reportUri", func() {
			b := newStanding("gsb-done-nouri")
			b.Status.Phase = "Completed"
			b.Status.Result = &platformv1.BenchmarkResult{BaselineP99Ms: 100, ColocatedP99Ms: 900}
			err := k8sClient.Status().Update(ctx, b)
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("non-empty status.result.reportUri"))
		})

		It("refuses Completed with an empty reportUri", func() {
			b := newStanding("gsb-done-emptyuri")
			b.Status.Phase = "Completed"
			b.Status.Result = &platformv1.BenchmarkResult{ReportURI: ""}
			err := k8sClient.Status().Update(ctx, b)
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("non-empty status.result.reportUri"))
		})

		It("accepts Completed once a report is named, and accepts Running without one", func() {
			b := newStanding("gsb-done-ok")
			b.Status.Phase = "Running"
			Expect(k8sClient.Status().Update(ctx, b)).To(Succeed())

			b.Status.Phase = "Completed"
			b.Status.Result = &platformv1.BenchmarkResult{
				BaselineP99Ms: 100, ColocatedP99Ms: 900,
				InterferenceRatio: "9.0", P99CI95: "820-980",
				ReportURI: "s3://reports/premium-vs-longcontext-shared",
			}
			Expect(k8sClient.Status().Update(ctx, b)).To(Succeed())
		})
	})

	Context("the numbers a p99 claim depends on", func() {
		It("refuses repetitions below five and a sample floor below a thousand", func() {
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

		It("refuses zero token counts and a zero timeout", func() {
			// Boundary refusals the schema already carried and nothing tested.
			zeroIn := validBenchmark("gsb-zero-in")
			zeroIn.Spec.Baseline.InputTokens = 0
			Expect(k8sClient.Create(ctx, zeroIn)).NotTo(Succeed())

			zeroOut := validBenchmark("gsb-zero-out")
			zeroOut.Spec.Contender.OutputTokens = 0
			Expect(k8sClient.Create(ctx, zeroOut)).NotTo(Succeed())

			zeroTimeout := validBenchmark("gsb-zero-timeout")
			zeroTimeout.Spec.Load.TimeoutMs = 0
			Expect(k8sClient.Create(ctx, zeroTimeout)).NotTo(Succeed())
		})

		DescribeTable("refuses a qps that is not a positive plain decimal",
			func(qps string) {
				b := validBenchmark(fmt.Sprintf("gsb-qps-%d", GinkgoRandomSeed()%100000))
				b.Spec.Contender.QPS = qps
				err := k8sClient.Create(ctx, b)
				Expect(err).To(HaveOccurred())
				Expect(err.Error()).To(ContainSubstring("spec.contender.qps"))
			},
			// Every one of these was accepted before the pattern landed, measured against a real apiserver.
			Entry("empty", ""),
			Entry("leading space", " 2.0"),
			Entry("not a number", "NaN"),
			Entry("negative", "-1"),
			Entry("exponent", "2e0"),
			Entry("letters", "abc"),
			// Zero in each spelling: a rate of zero is not how this type says "the contender is off".
			Entry("zero", "0"),
			Entry("zero with a point", "0.0"),
			Entry("zero, more decimals", "0.000"),
		)

		It("accepts a small positive fraction", func() {
			// The zero rules must not take the whole sub-one range with them.
			b := validBenchmark("gsb-small-qps")
			b.Spec.Baseline.QPS = "0.01"
			Expect(k8sClient.Create(ctx, b)).To(Succeed())
			DeferCleanup(func() { Expect(k8sClient.Delete(ctx, b)).To(Succeed()) })
		})
	})
})
