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
	"maps"
	"strconv"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/rand"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
	kueuev1beta1 "sigs.k8s.io/kueue/apis/kueue/v1beta1"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// These run against the API server with the generated CRD, which the BuildJob unit tests cannot: they pin what the
// controller persisted and what the schema refuses, not what a function returned.
//
// No Job controller runs here, so Job status is written by hand where a spec needs it, and no garbage collector
// runs either, which is what lets a Service owned by a deleted incarnation stay around to be refused.
var _ = Describe("MLTrainingJob distributed", func() {
	const ns = "default"

	reconciler := func(c client.Client) *MLTrainingJobReconciler {
		return &MLTrainingJobReconciler{Client: c, Scheme: c.Scheme()}
	}

	// create makes a distributed job of world size 2 and arranges its cleanup.
	create := func(name string) types.NamespacedName {
		GinkgoHelper()
		key := types.NamespacedName{Name: name, Namespace: ns}
		Expect(k8sClient.Create(ctx, &platformv1.MLTrainingJob{
			Name: key.Name, Namespace: key.Namespace,
			Spec: platformv1.MLTrainingJobSpec{
				Queue: "team-a", Image: "trainer:v1", GPUCount: 1,
				Distributed: &platformv1.Distributed{WorldSize: 2},
			},
		})).To(Succeed())
		DeferCleanup(func() {
			mltj := &platformv1.MLTrainingJob{}
			if err := k8sClient.Get(ctx, key, mltj); err == nil {
				mltj.Finalizers = nil
				_ = k8sClient.Update(ctx, mltj)
				_ = k8sClient.Delete(ctx, mltj)
			}
			_ = k8sClient.Delete(ctx, &corev1.Service{Name: key.Name + "-ddp", Namespace: ns})
			_ = k8sClient.Delete(ctx, &batchv1.Job{Name: key.Name, Namespace: ns})
		})
		return key
	}

	reconcileTimes := func(c client.Client, key types.NamespacedName, n int) {
		GinkgoHelper()
		for range n {
			_, err := reconciler(c).Reconcile(ctx, reconcile.Request{NamespacedName: key})
			Expect(err).NotTo(HaveOccurred())
		}
	}

	// untilJob reconciles until the Job exists; the Service read goes through a cache that may lag a create.
	untilJob := func(key types.NamespacedName) *batchv1.Job {
		GinkgoHelper()
		job := &batchv1.Job{}
		Eventually(func() error {
			reconcileTimes(cachedClient, key, 1)
			return k8sClient.Get(ctx, key, job)
		}, 10*time.Second, 50*time.Millisecond).Should(Succeed())
		return job
	}

	getMLTJ := func(key types.NamespacedName) *platformv1.MLTrainingJob {
		GinkgoHelper()
		mltj := &platformv1.MLTrainingJob{}
		Expect(k8sClient.Get(ctx, key, mltj)).To(Succeed())
		return mltj
	}

	foreignService := func(name string, owners ...metav1.OwnerReference) *corev1.Service {
		GinkgoHelper()
		svc := &corev1.Service{
			Name: name, Namespace: ns, OwnerReferences: owners,
			Spec: corev1.ServiceSpec{
				Selector: map[string]string{"app": "someone-else"},
				Ports:    []corev1.ServicePort{{Port: 80}},
			},
		}
		Expect(k8sClient.Create(ctx, svc)).To(Succeed())
		DeferCleanup(func() { _ = k8sClient.Delete(ctx, &corev1.Service{Name: name, Namespace: ns}) })
		return svc
	}

	// expectBlocked asserts the whole of what a conflict is: no Job, Pending not Failed, the condition, the Service untouched.
	expectBlocked := func(key types.NamespacedName, foreign *corev1.Service) {
		GinkgoHelper()
		Eventually(func() string {
			reconcileTimes(cachedClient, key, 1)
			c := meta.FindStatusCondition(getMLTJ(key).Status.Conditions, mltjCondRendezvous)
			if c == nil {
				return ""
			}
			return string(c.Status) + "/" + c.Reason
		}, 10*time.Second, 50*time.Millisecond).Should(Equal("False/" + mltjReasonServiceConflict))

		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, key, &batchv1.Job{}))).To(BeTrue(), "a Job was created behind a foreign Service")
		Expect(getMLTJ(key).Status.Phase).To(Equal(mltjPhasePending))

		var now corev1.Service
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(foreign), &now)).To(Succeed())
		Expect(now.OwnerReferences).To(Equal(foreign.OwnerReferences), "the foreign Service was adopted")
		Expect(now.Spec.Selector).To(Equal(foreign.Spec.Selector), "the foreign Service was modified")
	}

	It("creates its own Service before an Indexed Job that fails on the first failed rank", func() {
		key := create("ddp-" + rand.String(6))
		job := untilJob(key)
		mltj := getMLTJ(key)

		var svc corev1.Service
		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: key.Name + "-ddp", Namespace: ns}, &svc)).To(Succeed())
		Expect(metav1.IsControlledBy(&svc, mltj)).To(BeTrue())
		Expect(svc.Spec.ClusterIP).To(Equal(corev1.ClusterIPNone))
		Expect(svc.Spec.Selector).To(Equal(map[string]string{mltjNameLabel: key.Name, mltjUIDLabel: string(mltj.UID)}))

		// Resource versions are the store's revision, so the Service's being lower says it was written first.
		svcRV, _ := strconv.ParseInt(svc.ResourceVersion, 10, 64)
		jobRV, _ := strconv.ParseInt(job.ResourceVersion, 10, 64)
		Expect(svcRV).To(BeNumerically("<", jobRV))

		// The persisted Job, not BuildJob's return: the create path copies only what it names.
		// Mutation that turns this red: drop either copy from the create branch of Reconcile.
		Expect(job.Spec.CompletionMode).To(HaveValue(Equal(batchv1.IndexedCompletion)))
		Expect(job.Spec.BackoffLimit).To(HaveValue(BeEquivalentTo(0)))
		Expect(job.Spec.Parallelism).To(HaveValue(BeEquivalentTo(2)))
		Expect(job.Spec.Completions).To(HaveValue(BeEquivalentTo(2)))
		Expect(job.Spec.Template.Spec.Subdomain).To(Equal(key.Name + "-ddp"))

		c := meta.FindStatusCondition(mltj.Status.Conditions, mltjCondRendezvous)
		Expect(c).NotTo(BeNil())
		Expect(c.Status).To(Equal(metav1.ConditionTrue))
	})

	It("recreates its Service after it is deleted", func() {
		key := create("ddp-" + rand.String(6))
		untilJob(key)
		svcKey := types.NamespacedName{Name: key.Name + "-ddp", Namespace: ns}
		var old corev1.Service
		Expect(k8sClient.Get(ctx, svcKey, &old)).To(Succeed())
		Expect(k8sClient.Delete(ctx, &old)).To(Succeed())

		Eventually(func() types.UID {
			reconcileTimes(cachedClient, key, 1)
			var svc corev1.Service
			if err := k8sClient.Get(ctx, svcKey, &svc); err != nil {
				return ""
			}
			return svc.UID
		}, 10*time.Second, 50*time.Millisecond).ShouldNot(Or(BeEmpty(), Equal(old.UID)))
	})

	It("does not create its Job behind a Service it does not own, and starts once the name is free", func() {
		name := "ddp-" + rand.String(6)
		foreign := foreignService(name + "-ddp")
		key := create(name)

		expectBlocked(key, foreign)

		Expect(k8sClient.Delete(ctx, foreign)).To(Succeed())
		untilJob(key)
		Eventually(func() metav1.ConditionStatus {
			reconcileTimes(cachedClient, key, 1)
			c := meta.FindStatusCondition(getMLTJ(key).Status.Conditions, mltjCondRendezvous)
			if c == nil {
				return ""
			}
			return c.Status
		}, 10*time.Second, 50*time.Millisecond).Should(Equal(metav1.ConditionTrue))
	})

	It("treats a Service owned by an earlier job of the same name as foreign", func() {
		name := "ddp-" + rand.String(6)
		// Same kind and name, different UID: what a deleted and recreated job leaves when garbage collection lags.
		foreign := foreignService(name+"-ddp", metav1.OwnerReference{
			APIVersion: platformv1.GroupVersion.String(), Kind: "MLTrainingJob", Name: name,
			UID: types.UID("an-earlier-incarnation"), Controller: new(true),
		})
		key := create(name)
		expectBlocked(key, foreign)
	})

	It("does not adopt a Service that appears between its read and its create", func() {
		name := "ddp-" + rand.String(6)
		foreign := foreignService(name + "-ddp")
		key := create(name)

		// A read that always misses Services is a cache that has not seen the foreign one yet.
		// A direct client is enough, because a blocked job returns before the Workload lookup that needs the cache's index.
		direct, err := client.NewWithWatch(cfg, client.Options{Scheme: k8sClient.Scheme()})
		Expect(err).NotTo(HaveOccurred())
		blind := interceptor.NewClient(direct, interceptor.Funcs{
			Get: func(ctx context.Context, c client.WithWatch, k client.ObjectKey, obj client.Object, opts ...client.GetOption) error {
				if _, ok := obj.(*corev1.Service); ok {
					return apierrors.NewNotFound(corev1.Resource("services"), k.Name)
				}
				return c.Get(ctx, k, obj, opts...)
			},
		})
		reconcileTimes(blind, key, 4)

		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, key, &batchv1.Job{}))).To(BeTrue())
		var now corev1.Service
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(foreign), &now)).To(Succeed())
		Expect(now.OwnerReferences).To(BeEmpty())
	})

	It("keeps following an existing Job after its Service is replaced by a foreign one", func() {
		key := create("ddp-" + rand.String(6))
		job := untilJob(key)

		svcKey := types.NamespacedName{Name: key.Name + "-ddp", Namespace: ns}
		Expect(k8sClient.Delete(ctx, &corev1.Service{Name: svcKey.Name, Namespace: ns})).To(Succeed())
		foreignService(svcKey.Name)

		// Both ranks, because a distributed job is Running only when every rank is Ready.
		job.Status.Active = 2
		job.Status.Ready = new(int32(2))
		Expect(k8sClient.Status().Update(ctx, job)).To(Succeed())

		Eventually(func(g Gomega) {
			reconcileTimes(cachedClient, key, 1)
			mltj := getMLTJ(key)
			c := meta.FindStatusCondition(mltj.Status.Conditions, mltjCondRendezvous)
			g.Expect(c).NotTo(BeNil())
			g.Expect(c.Reason).To(Equal(mltjReasonServiceConflict))
			// Mutation that turns this red: return early on a Service conflict even when the Job exists.
			g.Expect(mltj.Status.Phase).To(Equal(mltjPhaseRunning))
			g.Expect(mltj.Status.ReadyRanks).To(HaveValue(BeEquivalentTo(2)))
		}, 10*time.Second, 50*time.Millisecond).Should(Succeed())
	})

	It("stays Admitted with one of two ranks Ready and closes admitToRunning only when both are", func() {
		key := create("ddp-" + rand.String(6))
		job := untilJob(key)

		wl := &kueuev1beta1.Workload{
			Name: key.Name, Namespace: ns,
			Labels: map[string]string{kueueJobUIDLabel: string(job.UID)},
			Spec: kueuev1beta1.WorkloadSpec{PodSets: []kueuev1beta1.PodSet{{
				Name: "main", Count: 2,
				Template: corev1.PodTemplateSpec{Spec: corev1.PodSpec{
					RestartPolicy: corev1.RestartPolicyNever,
					Containers:    []corev1.Container{{Name: "trainer", Image: "trainer:v1"}},
				}},
			}}},
		}
		Expect(k8sClient.Create(ctx, wl)).To(Succeed())
		DeferCleanup(func() { _ = k8sClient.Delete(ctx, wl) })
		wl.Status.Conditions = []metav1.Condition{{
			Type: kueuev1beta1.WorkloadAdmitted, Status: metav1.ConditionTrue, Reason: "Admitted", LastTransitionTime: metav1.Now(),
		}}
		Expect(k8sClient.Status().Update(ctx, wl)).To(Succeed())
		awaitCachedWorkload(wl.Name, wl.Namespace, hasAdmittedCondition)

		// Finding 10's state: one rank placed and Ready, the other with no node.
		Expect(k8sClient.Get(ctx, key, job)).To(Succeed())
		job.Status.Active = 2
		job.Status.Ready = new(int32(1))
		Expect(k8sClient.Status().Update(ctx, job)).To(Succeed())
		Eventually(func(g Gomega) {
			reconcileTimes(cachedClient, key, 1)
			g.Expect(getMLTJ(key).Status.ReadyRanks).To(HaveValue(BeEquivalentTo(1)))
		}, 10*time.Second, 50*time.Millisecond).Should(Succeed())
		half := getMLTJ(key)
		Expect(half.Status.Phase).To(Equal(mltjPhaseAdmitted))
		Expect(half.Status.AdmittedAt).NotTo(BeNil())
		// The latency metric must not close on a rank that cannot start without its peer.
		Expect(half.Status.RunningObservedAt).To(BeNil())
		Expect(half.Status.AdmitToRunningSeconds).To(BeEmpty())

		Expect(k8sClient.Get(ctx, key, job)).To(Succeed())
		job.Status.Ready = new(int32(2))
		Expect(k8sClient.Status().Update(ctx, job)).To(Succeed())
		Eventually(func(g Gomega) {
			reconcileTimes(cachedClient, key, 1)
			g.Expect(getMLTJ(key).Status.Phase).To(Equal(mltjPhaseRunning))
		}, 10*time.Second, 50*time.Millisecond).Should(Succeed())
		full := getMLTJ(key)
		Expect(full.Status.RunningObservedAt).NotTo(BeNil())
		Expect(full.Status.AdmitToRunningSeconds).NotTo(BeEmpty())
	})

	It("writes readyRanks 0 as 0 and leaves it absent for a job without distributed", func() {
		key := create("ddp-" + rand.String(6))
		job := untilJob(key)
		job.Status.Ready = new(int32(0))
		Expect(k8sClient.Status().Update(ctx, job)).To(Succeed())
		Eventually(func() *int32 {
			reconcileTimes(cachedClient, key, 1)
			return getMLTJ(key).Status.ReadyRanks
		}, 10*time.Second, 50*time.Millisecond).Should(HaveValue(BeEquivalentTo(0)))

		plain := types.NamespacedName{Name: "plain-" + rand.String(6), Namespace: ns}
		Expect(k8sClient.Create(ctx, &platformv1.MLTrainingJob{
			Name: plain.Name, Namespace: ns,
			Spec: platformv1.MLTrainingJobSpec{Queue: "team-a", Image: "trainer:v1", GPUCount: 1},
		})).To(Succeed())
		DeferCleanup(func() {
			mltj := &platformv1.MLTrainingJob{}
			if err := k8sClient.Get(ctx, plain, mltj); err == nil {
				mltj.Finalizers = nil
				_ = k8sClient.Update(ctx, mltj)
				_ = k8sClient.Delete(ctx, mltj)
			}
			_ = k8sClient.Delete(ctx, &batchv1.Job{Name: plain.Name, Namespace: ns})
		})
		pjob := untilJob(plain)
		pjob.Status.Active = 1
		pjob.Status.Ready = new(int32(1))
		Expect(k8sClient.Status().Update(ctx, pjob)).To(Succeed())
		Eventually(func() string {
			reconcileTimes(cachedClient, plain, 1)
			return getMLTJ(plain).Status.Phase
		}, 10*time.Second, 50*time.Millisecond).Should(Equal(mltjPhaseRunning))
		Expect(getMLTJ(plain).Status.ReadyRanks).To(BeNil())
		Expect(meta.FindStatusCondition(getMLTJ(plain).Status.Conditions, mltjCondRendezvous)).To(BeNil())
		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Name: plain.Name + "-ddp", Namespace: ns}, &corev1.Service{}))).To(BeTrue())
	})

	It("builds a Service for the longest name the webhook admits", func() {
		// 59 + "-ddp" is 63, the DNS-1035 limit the webhook checks; the API server applies the same limit here.
		key := create("a" + strings.Repeat("b", 58))
		untilJob(key)
	})

	Context("the schema", func() {
		// Raw objects, because the Go client omits a zero and a value struct, which is exactly what these rows need to send.
		raw := func(spec map[string]any) *unstructured.Unstructured {
			base := map[string]any{"queue": "team-a", "image": "trainer:v1", "gpuCount": int64(1)}
			maps.Copy(base, spec)
			u := &unstructured.Unstructured{Object: map[string]any{
				"apiVersion": platformv1.GroupVersion.String(), "kind": "MLTrainingJob",
				"metadata": map[string]any{"name": "cel-" + rand.String(6), "namespace": ns},
				"spec":     base,
			}}
			DeferCleanup(func() { _ = k8sClient.Delete(ctx, u) })
			return u
		}
		world := func(n int64) map[string]any { return map[string]any{"worldSize": n} }

		DescribeTable("refuses at create",
			func(spec map[string]any, wantInMessage string) {
				err := k8sClient.Create(ctx, raw(spec))
				Expect(apierrors.IsInvalid(err)).To(BeTrue(), "accepted: %v", err)
				Expect(err.Error()).To(ContainSubstring(wantInMessage))
			},
			Entry("distributed: {}", map[string]any{"distributed": map[string]any{}}, "worldSize"),
			Entry("worldSize 1", map[string]any{"distributed": world(1)}, "worldSize"),
			Entry("worldSize 9", map[string]any{"distributed": world(9)}, "worldSize"),
			Entry("explicit parallelism 0", map[string]any{"distributed": world(2), "parallelism": int64(0)}, "leave parallelism and completions at 1"),
			Entry("parallelism 2", map[string]any{"distributed": world(2), "parallelism": int64(2)}, "leave parallelism and completions at 1"),
			Entry("completions 2", map[string]any{"distributed": world(2), "completions": int64(2)}, "leave parallelism and completions at 1"),
			Entry("stateVolume", map[string]any{"distributed": world(2),
				"stateVolume": map[string]any{"claimName": "c", "mountPath": "/s"}}, "stateVolume cannot be combined"),
		)

		It("accepts the shapes it is meant to", func() {
			Expect(k8sClient.Create(ctx, raw(map[string]any{"distributed": world(2)}))).To(Succeed())
			Expect(k8sClient.Create(ctx, raw(map[string]any{"distributed": world(8), "parallelism": int64(1), "completions": int64(1)}))).To(Succeed())
			Expect(k8sClient.Create(ctx, raw(map[string]any{"parallelism": int64(2)}))).To(Succeed())
		})

		DescribeTable("refuses changing distributed after creation",
			func(from, to map[string]any) {
				u := raw(from)
				Expect(k8sClient.Create(ctx, u)).To(Succeed())
				spec := u.Object["spec"].(map[string]any)
				delete(spec, "distributed")
				maps.Copy(spec, to)
				err := k8sClient.Update(ctx, u)
				Expect(apierrors.IsInvalid(err)).To(BeTrue(), "accepted: %v", err)
				Expect(err.Error()).To(ContainSubstring("distributed is fixed at creation"))
			},
			Entry("adding it", map[string]any{}, map[string]any{"distributed": world(2)}),
			Entry("removing it", map[string]any{"distributed": world(2)}, map[string]any{}),
			Entry("changing worldSize", map[string]any{"distributed": world(2)}, map[string]any{"distributed": world(3)}),
		)

		It("accepts an update that leaves distributed as it was", func() {
			u := raw(map[string]any{"distributed": world(2)})
			Expect(k8sClient.Create(ctx, u)).To(Succeed())
			u.Object["spec"].(map[string]any)["image"] = "trainer:v2"
			Expect(k8sClient.Update(ctx, u)).To(Succeed())
		})
	})
})
