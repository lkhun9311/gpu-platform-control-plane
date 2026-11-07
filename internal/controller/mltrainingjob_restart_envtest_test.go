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
	"strconv"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/rand"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
	kueuev1beta1 "sigs.k8s.io/kueue/apis/kueue/v1beta1"
	"sigs.k8s.io/yaml"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// The restart lifecycle against the API server.
//
// No garbage collector, Job controller or kubelet runs here, so each spec plays them by hand: it removes the
// foreground-deletion finalizer the way the collector would, deletes Pods and Workloads, and writes Job and Node
// status itself.
// That is also what lets a spec hold each barrier condition open on its own and see the attempt wait for exactly it.
var _ = Describe("MLTrainingJob restart", func() {
	const ns = "default"

	// The reconciler acts as a user bound to config/rbac/role.yaml, the role the manager is deployed with.
	// The suite's own clients are cluster admin, and a verb missing from the role would pass every spec here and then
	// leave a deployed attempt stuck: the delete of a stopped attempt's Service did exactly that.
	var asManager, asManagerUncached client.Client
	BeforeEach(func() {
		if asManager != nil {
			return
		}
		raw, err := os.ReadFile(filepath.Join("..", "..", "config", "rbac", "role.yaml"))
		Expect(err).NotTo(HaveOccurred())
		role := &rbacv1.ClusterRole{}
		Expect(yaml.Unmarshal(raw, role)).To(Succeed())
		Expect(role.Rules).NotTo(BeEmpty())
		const user = "restart-test-manager"
		role.ObjectMeta = metav1.ObjectMeta{Name: user}
		Expect(k8sClient.Create(ctx, role)).To(Succeed())
		Expect(k8sClient.Create(ctx, &rbacv1.ClusterRoleBinding{
			Name:     user,
			RoleRef:  rbacv1.RoleRef{APIGroup: rbacv1.GroupName, Kind: "ClusterRole", Name: user},
			Subjects: []rbacv1.Subject{{APIGroup: rbacv1.GroupName, Kind: rbacv1.UserKind, Name: user}},
		})).To(Succeed())
		imp := rest.CopyConfig(cfg)
		imp.Impersonate = rest.ImpersonationConfig{UserName: user}
		asManagerUncached, err = client.New(imp, client.Options{Scheme: scheme.Scheme})
		Expect(err).NotTo(HaveOccurred())
		asManager, err = client.New(imp, client.Options{Scheme: scheme.Scheme, Cache: &client.CacheOptions{
			Reader:     workloadCache,
			DisableFor: []client.Object{&platformv1.MLTrainingJob{}, &batchv1.Job{}, &corev1.Pod{}, &corev1.Node{}},
		}})
		Expect(err).NotTo(HaveOccurred())
		// The binding is only worth anything if the server enforces it: the role must not reach what it was not given.
		Expect(apierrors.IsForbidden(asManagerUncached.List(ctx, &rbacv1.ClusterRoleList{}))).To(BeTrue(),
			"the impersonated user was not refused a list the role does not grant, so RBAC is not enforced here")
	})

	reconciler := func() *MLTrainingJobReconciler {
		return &MLTrainingJobReconciler{Client: asManager, Scheme: scheme.Scheme, APIReader: asManagerUncached}
	}

	step := func(key types.NamespacedName) {
		GinkgoHelper()
		_, err := reconciler().Reconcile(ctx, reconcile.Request{NamespacedName: key})
		Expect(err).NotTo(HaveOccurred())
	}

	getMLTJ := func(key types.NamespacedName) *platformv1.MLTrainingJob {
		GinkgoHelper()
		mltj := &platformv1.MLTrainingJob{}
		Expect(k8sClient.Get(ctx, key, mltj)).To(Succeed())
		return mltj
	}

	attempts := func(key types.NamespacedName) []platformv1.TrainingAttempt {
		GinkgoHelper()
		return getMLTJ(key).Status.Attempts
	}

	last := func(key types.NamespacedName) platformv1.TrainingAttempt {
		GinkgoHelper()
		a := attempts(key)
		Expect(a).NotTo(BeEmpty())
		return a[len(a)-1]
	}

	// collect plays the garbage collector for a Job deleted in the foreground: without it the Job never goes.
	// It deletes the Job first when nothing has, so cleanup can use it too.
	collect := func(key types.NamespacedName) {
		GinkgoHelper()
		_ = k8sClient.Delete(ctx, &batchv1.Job{Name: key.Name, Namespace: key.Namespace}, client.PropagationPolicy(metav1.DeletePropagationBackground))
		var job batchv1.Job
		if err := k8sClient.Get(ctx, key, &job); err != nil {
			Expect(apierrors.IsNotFound(err)).To(BeTrue())
			return
		}
		job.Finalizers = nil
		Expect(client.IgnoreNotFound(k8sClient.Update(ctx, &job))).To(Succeed())
		Eventually(func() bool {
			return apierrors.IsNotFound(k8sClient.Get(ctx, key, &batchv1.Job{}))
		}, 10*time.Second, 50*time.Millisecond).Should(BeTrue())
	}

	create := func(maxRestarts int32) types.NamespacedName {
		GinkgoHelper()
		key := types.NamespacedName{Name: "rs-" + rand.String(6), Namespace: ns}
		Expect(k8sClient.Create(ctx, &platformv1.MLTrainingJob{
			Name: key.Name, Namespace: key.Namespace,
			Spec: platformv1.MLTrainingJobSpec{
				Queue: "team-a", Image: "trainer:v1", GPUCount: 1,
				Distributed: &platformv1.Distributed{WorldSize: 2, MaxRestarts: maxRestarts},
				StateVolume: &platformv1.StateVolume{ClaimName: "ckpt", MountPath: "/ckpt"},
			},
		})).To(Succeed())
		DeferCleanup(func() {
			mltj := &platformv1.MLTrainingJob{}
			if err := k8sClient.Get(ctx, key, mltj); err == nil {
				mltj.Finalizers = nil
				_ = k8sClient.Update(ctx, mltj)
				_ = k8sClient.Delete(ctx, mltj)
			}
			collect(key)
			_ = k8sClient.Delete(ctx, &batchv1.Job{Name: key.Name, Namespace: ns})
			for n := range maxRestarts + 2 {
				_ = k8sClient.Delete(ctx, &corev1.Service{Name: key.Name + "-ddp-a" + strconv.Itoa(int(n)), Namespace: ns})
			}
		})
		return key
	}

	// untilActive reconciles until the current attempt's Job exists and the attempt has adopted it.
	// The Service read goes through a cache that may lag the create, so the number of passes is not fixed.
	untilActive := func(key types.NamespacedName) *batchv1.Job {
		GinkgoHelper()
		Eventually(func() string {
			step(key)
			a := attempts(key)
			if len(a) == 0 {
				return ""
			}
			return a[len(a)-1].State
		}, 10*time.Second, 50*time.Millisecond).Should(Equal(attemptActive))
		job := &batchv1.Job{}
		Expect(k8sClient.Get(ctx, key, job)).To(Succeed())
		return job
	}

	node := func(ready corev1.ConditionStatus) string {
		GinkgoHelper()
		n := &corev1.Node{Name: "rs-node-" + rand.String(6)}
		Expect(k8sClient.Create(ctx, n)).To(Succeed())
		DeferCleanup(func() { _ = k8sClient.Delete(ctx, &corev1.Node{Name: n.Name}) })
		n.Status.Conditions = []corev1.NodeCondition{{Type: corev1.NodeReady, Status: ready, LastHeartbeatTime: metav1.Now()}}
		Expect(k8sClient.Status().Update(ctx, n)).To(Succeed())
		return n.Name
	}

	// bind writes what the scheduler publishes when it binds a Pod, which the controller reads as the binding time.
	bind := func(p *corev1.Pod) {
		GinkgoHelper()
		p.Status.Conditions = []corev1.PodCondition{{Type: corev1.PodScheduled, Status: corev1.ConditionTrue, LastTransitionTime: metav1.Now()}}
		Expect(k8sClient.Status().Update(ctx, p)).To(Succeed())
	}

	rankPod := func(mltj *platformv1.MLTrainingJob, attempt int, onNode string) *corev1.Pod {
		GinkgoHelper()
		p := &corev1.Pod{
			Name: mltj.Name + "-" + rand.String(5), Namespace: ns,
			Labels: map[string]string{mltjUIDLabel: string(mltj.UID), mltjAttemptLabel: strconv.Itoa(attempt)},
			Spec: corev1.PodSpec{
				NodeName:   onNode,
				Containers: []corev1.Container{{Name: "trainer", Image: "trainer:v1"}},
			},
		}
		Expect(k8sClient.Create(ctx, p)).To(Succeed())
		DeferCleanup(func() { _ = k8sClient.Delete(ctx, p, client.GracePeriodSeconds(0)) })
		bind(p)
		return p
	}

	workloadFor := func(job *batchv1.Job, annotations map[string]string) *kueuev1beta1.Workload {
		GinkgoHelper()
		wl := &kueuev1beta1.Workload{
			Name: "job-" + job.Name + "-" + rand.String(5), Namespace: ns,
			Labels:      map[string]string{kueueJobUIDLabel: string(job.UID)},
			Annotations: annotations,
			Spec: kueuev1beta1.WorkloadSpec{PodSets: []kueuev1beta1.PodSet{{
				Name: "main", Count: 2,
				Template: corev1.PodTemplateSpec{Spec: corev1.PodSpec{
					RestartPolicy: corev1.RestartPolicyNever,
					Containers:    []corev1.Container{{Name: "trainer", Image: "trainer:v1"}},
				}},
			}}},
		}
		Expect(k8sClient.Create(ctx, wl)).To(Succeed())
		DeferCleanup(func() { _ = k8sClient.Delete(ctx, &kueuev1beta1.Workload{Name: wl.Name, Namespace: ns}) })
		awaitCachedWorkload(wl.Name, ns, func(*kueuev1beta1.Workload) bool { return true })
		return wl
	}

	// failRank writes what the Job controller writes when a rank fails with backoffLimit 0.
	failRank := func(job *batchv1.Job) {
		GinkgoHelper()
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(job), job)).To(Succeed())
		job.Spec.Suspend = new(false)
		Expect(k8sClient.Update(ctx, job)).To(Succeed())
		now := metav1.Now()
		job.Status.StartTime = &now
		job.Status.Failed = 1
		job.Status.Conditions = append(job.Status.Conditions, batchv1.JobCondition{
			Type: batchv1.JobFailureTarget, Status: corev1.ConditionTrue, Reason: "BackoffLimitExceeded", LastTransitionTime: now,
		})
		Expect(k8sClient.Status().Update(ctx, job)).To(Succeed())
	}

	It("records attempt 1 before any Job, then creates that attempt's own Service and suspended Job", func() {
		key := create(1)
		step(key) // the finalizer
		step(key)
		Expect(attempts(key)).To(HaveLen(1))
		Expect(last(key).Number).To(BeEquivalentTo(1))
		Expect(last(key).State).To(Equal(attemptPreparing))
		// The record comes first; it is what freezes the template fields while no Job exists.
		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, key, &batchv1.Job{}))).To(BeTrue(), "a Job was created before its attempt was recorded")

		job := untilActive(key)
		mltj := getMLTJ(key)
		Expect(last(key).JobUID).To(Equal(string(job.UID)))
		Expect(last(key).CreatedAt).NotTo(BeNil())
		Expect(metav1.IsControlledBy(job, mltj)).To(BeTrue())
		Expect(job.Spec.Suspend).To(HaveValue(BeTrue()))
		Expect(job.Labels).To(HaveKeyWithValue(mltjAttemptLabel, "1"))
		Expect(job.Spec.Template.Labels).To(HaveKeyWithValue(mltjAttemptLabel, "1"))
		Expect(job.Spec.Template.Spec.Subdomain).To(Equal(key.Name + "-ddp-a1"))
		Expect(job.Spec.Template.Spec.Containers[0].Env).To(ContainElements(
			corev1.EnvVar{Name: "TRAINING_ATTEMPT", Value: "1"},
			corev1.EnvVar{Name: "MASTER_ADDR", Value: key.Name + "-0." + key.Name + "-ddp-a1." + ns + ".svc"},
		))

		var svc corev1.Service
		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: key.Name + "-ddp-a1", Namespace: ns}, &svc)).To(Succeed())
		Expect(metav1.IsControlledBy(&svc, mltj)).To(BeTrue())
		// The selector carries the attempt, so a retired attempt's rank that has not yet exited is not an endpoint.
		Expect(svc.Spec.Selector).To(HaveKeyWithValue(mltjAttemptLabel, "1"))
	})

	It("adopts a Job its lost create left behind, but not one without this attempt's token", func() {
		key := create(1)
		step(key)
		step(key)
		mltj := getMLTJ(key)

		By("a Job of this name owned by the job but carrying no attempt is never adopted")
		stray := buildJob(mltj, 0)
		Expect(controllerutil.SetControllerReference(mltj, stray, k8sClient.Scheme())).To(Succeed())
		Expect(k8sClient.Create(ctx, stray)).To(Succeed())
		for range 5 {
			step(key)
		}
		Expect(last(key).State).To(Equal(attemptPreparing))
		c := meta.FindStatusCondition(getMLTJ(key).Status.Conditions, mltjCondAdmitted)
		Expect(c).NotTo(BeNil())
		Expect(c.Reason).To(Equal(mltjReasonRestarting))

		By("the same Job carrying attempt 1 is what a lost create leaves, and is adopted")
		Expect(k8sClient.Delete(ctx, stray, client.PropagationPolicy(metav1.DeletePropagationBackground))).To(Succeed())
		Eventually(func() bool { return apierrors.IsNotFound(k8sClient.Get(ctx, key, &batchv1.Job{})) }, 10*time.Second, 50*time.Millisecond).Should(BeTrue())
		lost := buildJob(getMLTJ(key), 1)
		Expect(controllerutil.SetControllerReference(mltj, lost, k8sClient.Scheme())).To(Succeed())
		Expect(k8sClient.Create(ctx, lost)).To(Succeed())
		untilActive(key)
		Expect(last(key).JobUID).To(Equal(string(lost.UID)))
	})

	It("after a failed rank waits for the Job, the Pods, the Workload and an unreachable node, then starts attempt 2", func() {
		key := create(1)
		job := untilActive(key)
		mltj := getMLTJ(key)

		unreachable, ready := node(corev1.ConditionFalse), node(corev1.ConditionTrue)
		onUnreachable, onReady := rankPod(mltj, 1, unreachable), rankPod(mltj, 1, ready)
		// A Pod of attempt 2 must not hold attempt 1's barrier.
		rankPod(mltj, 2, ready)
		wl := workloadFor(job, nil)

		step(key)
		Expect(last(key).Nodes).To(ConsistOf(unreachable, ready))
		Expect(last(key).WorkloadName).To(Equal(wl.Name))
		Expect(last(key).WorkloadUID).To(Equal(string(wl.UID)))

		failRank(job)
		step(key)
		Expect(last(key).State).To(Equal(attemptStopping))
		Expect(last(key).Trigger).To(Equal(triggerRankFailed))
		Expect(last(key).FailureObservedAt).NotTo(BeNil())
		Expect(getMLTJ(key).Status.Phase).To(Equal(mltjPhasePending))

		By("the Job, deleted in the foreground and held by its finalizer until the collector runs")
		step(key)
		Expect(k8sClient.Get(ctx, key, job)).To(Succeed())
		Expect(job.DeletionTimestamp).NotTo(BeNil(), "the barrier did not delete the attempt's Job")
		Expect(job.Finalizers).To(ContainElement(metav1.FinalizerDeleteDependents))
		Expect(last(key).WaitingFor).To(ContainSubstring("job " + key.Name))
		collect(key)

		By("the Pods, read uncached")
		step(key)
		Expect(last(key).WaitingFor).To(Equal("pods " + min(onReady.Name, onUnreachable.Name) + "," + max(onReady.Name, onUnreachable.Name) + " to be gone"))
		Expect(k8sClient.Delete(ctx, onUnreachable, client.GracePeriodSeconds(0))).To(Succeed())
		Expect(k8sClient.Delete(ctx, onReady, client.GracePeriodSeconds(0))).To(Succeed())
		Eventually(func() bool {
			return apierrors.IsNotFound(k8sClient.Get(ctx, client.ObjectKeyFromObject(onReady), &corev1.Pod{})) &&
				apierrors.IsNotFound(k8sClient.Get(ctx, client.ObjectKeyFromObject(onUnreachable), &corev1.Pod{}))
		}, 10*time.Second, 50*time.Millisecond).Should(BeTrue())

		By("the Workload, which Kueue would otherwise match to the next Job of the same name")
		step(key)
		Expect(last(key).WaitingFor).To(Equal("workload " + wl.Name + " to be gone"))
		Expect(k8sClient.Delete(ctx, wl)).To(Succeed())

		By("only the node that is not Ready: a Ready node's kubelet reported its Pods gone")
		step(key)
		Expect(last(key).WaitingFor).To(Equal("node " + unreachable + " to be fenced (annotation " + annFencedNodes + ")"))
		Expect(last(key).State).To(Equal(attemptStopping))
		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, key, &batchv1.Job{}))).To(BeTrue(), "the next attempt started behind the barrier")

		mltj = getMLTJ(key)
		mltj.Annotations = map[string]string{annFencedNodes: "some-other-node," + unreachable}
		Expect(k8sClient.Update(ctx, mltj)).To(Succeed())
		step(key)
		Expect(last(key).State).To(Equal(attemptStopped))
		Expect(last(key).WaitingFor).To(BeEmpty())
		Expect(last(key).StopConfirmedAt).NotTo(BeNil())

		By("attempt 2, on a Service of its own")
		step(key)
		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Name: key.Name + "-ddp-a1", Namespace: ns}, &corev1.Service{}))).To(BeTrue())
		Expect(attempts(key)).To(HaveLen(2))
		job2 := untilActive(key)
		Expect(job2.UID).NotTo(Equal(job.UID))
		Expect(job2.Labels).To(HaveKeyWithValue(mltjAttemptLabel, "2"))
		Expect(job2.Spec.Template.Spec.Subdomain).To(Equal(key.Name + "-ddp-a2"))
		Expect(attempts(key)[0].State).To(Equal(attemptStopped), "attempt 1's record was rewritten")
	})

	It("waits on a rank's node and a Workload it first sees after the trigger", func() {
		key := create(1)
		job := untilActive(key)
		mltj := getMLTJ(key)

		// The failure is the first thing seen: no pass of the Active attempt ever recorded a node or a Workload.
		failRank(job)
		step(key)
		Expect(last(key).State).To(Equal(attemptStopping))
		Expect(last(key).Nodes).To(BeEmpty())

		unreachable := node(corev1.ConditionFalse)
		late := rankPod(mltj, 1, unreachable)
		wl := workloadFor(job, nil)
		step(key)
		Expect(last(key).Nodes).To(ConsistOf(unreachable), "a rank seen only while stopping was not recorded")
		collect(key)
		Expect(k8sClient.Delete(ctx, late, client.GracePeriodSeconds(0))).To(Succeed())
		Eventually(func() bool {
			return apierrors.IsNotFound(k8sClient.Get(ctx, client.ObjectKeyFromObject(late), &corev1.Pod{}))
		}, 10*time.Second, 50*time.Millisecond).Should(BeTrue())

		// Found by the attempt's Job UID, uncached, even with the Job gone and no name recorded while it existed.
		step(key)
		Expect(last(key).WaitingFor).To(Equal("workload " + wl.Name + " to be gone"))
		Expect(k8sClient.Delete(ctx, wl)).To(Succeed())

		// Its Pod is gone from the API, but the node never said so: only the annotation releases the barrier.
		step(key)
		Expect(last(key).WaitingFor).To(ContainSubstring("node " + unreachable + " to be fenced"))
	})

	It("puts back the attempt's Service while the attempt runs", func() {
		key := create(1)
		untilActive(key)
		svcKey := types.NamespacedName{Name: key.Name + "-ddp-a1", Namespace: ns}
		Expect(k8sClient.Delete(ctx, &corev1.Service{Name: svcKey.Name, Namespace: ns})).To(Succeed())
		Eventually(func() error {
			step(key)
			return k8sClient.Get(ctx, svcKey, &corev1.Service{})
		}, 10*time.Second, 50*time.Millisecond).Should(Succeed())
		Expect(last(key).State).To(Equal(attemptActive))
	})

	It("fails the job once maxRestarts is spent, and starts nothing more", func() {
		key := create(1)
		for n := 1; n <= 2; n++ {
			job := untilActive(key)
			Expect(job.Labels).To(HaveKeyWithValue(mltjAttemptLabel, strconv.Itoa(n)))
			// A Job deleted from under the attempt is a trigger too, and with nothing else left the barrier passes at once.
			Expect(k8sClient.Delete(ctx, job, client.PropagationPolicy(metav1.DeletePropagationBackground))).To(Succeed())
			Eventually(func() bool { return apierrors.IsNotFound(k8sClient.Get(ctx, key, &batchv1.Job{})) }, 10*time.Second, 50*time.Millisecond).Should(BeTrue())
			step(key)
			Expect(last(key).Trigger).To(Equal(triggerJobDeleted))
			step(key)
			Expect(last(key).State).To(Equal(attemptStopped))
			step(key)
		}
		mltj := getMLTJ(key)
		Expect(mltj.Status.Phase).To(Equal(mltjPhaseFailed))
		c := meta.FindStatusCondition(mltj.Status.Conditions, mltjCondSynced)
		Expect(c).NotTo(BeNil())
		Expect(c.Reason).To(Equal(mltjReasonRestartsExhausted))
		for range 3 {
			step(key)
		}
		Expect(attempts(key)).To(HaveLen(2))
		Expect(apierrors.IsNotFound(k8sClient.Get(ctx, key, &batchv1.Job{}))).To(BeTrue(), "a third attempt started")
	})

	It("takes a Workload deactivated by an operator as no trigger, and one handed off by the fault path as NodeFault", func() {
		key := create(1)
		job := untilActive(key)

		wl := workloadFor(job, nil)
		wl.Spec.Active = new(false)
		Expect(k8sClient.Update(ctx, wl)).To(Succeed())
		awaitCachedWorkload(wl.Name, ns, func(w *kueuev1beta1.Workload) bool { return w.Spec.Active != nil && !*w.Spec.Active })
		for range 3 {
			step(key)
		}
		Expect(last(key).State).To(Equal(attemptActive))

		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(wl), wl)).To(Succeed())
		wl.Annotations = map[string]string{AnnRestartHandoff: "fp-1"}
		Expect(k8sClient.Update(ctx, wl)).To(Succeed())
		awaitCachedWorkload(wl.Name, ns, func(w *kueuev1beta1.Workload) bool { return w.Annotations[AnnRestartHandoff] != "" })
		step(key)
		Expect(last(key).State).To(Equal(attemptStopping))
		Expect(last(key).Trigger).To(Equal(triggerNodeFault))
	})

	It("does not take a new Node under a recorded node's name as that node having stopped its rank", func() {
		key := create(1)
		job := untilActive(key)
		mltj := getMLTJ(key)

		name := node(corev1.ConditionTrue)
		var old corev1.Node
		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: name}, &old)).To(Succeed())
		onIt := rankPod(mltj, 1, name)
		wl := workloadFor(job, nil)
		step(key)
		Expect(last(key).Nodes).To(ConsistOf(name))
		Expect(last(key).NodeUIDs).To(HaveKeyWithValue(name, string(old.UID)))

		failRank(job)
		step(key)
		step(key)
		collect(key)
		Expect(k8sClient.Delete(ctx, onIt, client.GracePeriodSeconds(0))).To(Succeed())
		Eventually(func() bool {
			return apierrors.IsNotFound(k8sClient.Get(ctx, client.ObjectKeyFromObject(onIt), &corev1.Pod{}))
		}, 10*time.Second, 50*time.Millisecond).Should(BeTrue())
		Expect(k8sClient.Delete(ctx, wl)).To(Succeed())

		By("a new machine registering under the old name, Ready")
		Expect(k8sClient.Delete(ctx, &corev1.Node{Name: name})).To(Succeed())
		Eventually(func() bool {
			return apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Name: name}, &corev1.Node{}))
		}, 10*time.Second, 50*time.Millisecond).Should(BeTrue())
		reborn := &corev1.Node{Name: name}
		Expect(k8sClient.Create(ctx, reborn)).To(Succeed())
		reborn.Status.Conditions = []corev1.NodeCondition{{Type: corev1.NodeReady, Status: corev1.ConditionTrue, LastHeartbeatTime: metav1.Now()}}
		Expect(k8sClient.Status().Update(ctx, reborn)).To(Succeed())
		Expect(reborn.UID).NotTo(Equal(old.UID))

		step(key)
		Expect(last(key).WaitingFor).To(Equal("node " + name + " to be fenced (annotation " + annFencedNodes + ")"))
		Expect(last(key).State).To(Equal(attemptStopping))

		mltj = getMLTJ(key)
		mltj.Annotations = map[string]string{annFencedNodes: name}
		Expect(k8sClient.Update(ctx, mltj)).To(Succeed())
		step(key)
		Expect(last(key).State).To(Equal(attemptStopped))
	})

	It("does not let a bare fenced name written for one machine stand for another machine of that name in a later attempt", func() {
		key := create(1)
		job := untilActive(key)
		mltj := getMLTJ(key)
		setReady := func(name string, status corev1.ConditionStatus) {
			GinkgoHelper()
			var n corev1.Node
			Expect(k8sClient.Get(ctx, types.NamespacedName{Name: name}, &n)).To(Succeed())
			n.Status.Conditions = []corev1.NodeCondition{{Type: corev1.NodeReady, Status: status, LastHeartbeatTime: metav1.Now()}}
			Expect(k8sClient.Status().Update(ctx, &n)).To(Succeed())
		}
		retire := func(pod *corev1.Pod, wl *kueuev1beta1.Workload) {
			GinkgoHelper()
			collect(key)
			Expect(k8sClient.Delete(ctx, pod, client.GracePeriodSeconds(0))).To(Succeed())
			Eventually(func() bool {
				return apierrors.IsNotFound(k8sClient.Get(ctx, client.ObjectKeyFromObject(pod), &corev1.Pod{}))
			}, 10*time.Second, 50*time.Millisecond).Should(BeTrue())
			Expect(k8sClient.Delete(ctx, wl)).To(Succeed())
		}

		By("attempt 1 loses the first machine of the name, and a bare name fences it")
		name := node(corev1.ConditionTrue)
		onIt := rankPod(mltj, 1, name)
		wl := workloadFor(job, nil)
		step(key)
		first := last(key).NodeUIDs[name]
		failRank(job)
		step(key)
		step(key)
		setReady(name, corev1.ConditionFalse)
		retire(onIt, wl)
		step(key)
		Expect(last(key).WaitingFor).To(Equal("node " + name + " to be fenced (annotation " + annFencedNodes + ")"))
		mltj = getMLTJ(key)
		mltj.Annotations = map[string]string{annFencedNodes: name}
		Expect(k8sClient.Update(ctx, mltj)).To(Succeed())
		step(key)
		Expect(last(key).State).To(Equal(attemptStopped))

		By("attempt 2 runs on another machine registered under the same name, which is then lost too")
		job = untilActive(key)
		Expect(last(key).Number).To(BeEquivalentTo(2))
		Expect(k8sClient.Delete(ctx, &corev1.Node{Name: name})).To(Succeed())
		Eventually(func() bool {
			return apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Name: name}, &corev1.Node{}))
		}, 10*time.Second, 50*time.Millisecond).Should(BeTrue())
		Expect(k8sClient.Create(ctx, &corev1.Node{Name: name})).To(Succeed())
		setReady(name, corev1.ConditionTrue)
		mltj = getMLTJ(key)
		onIt = rankPod(mltj, 2, name)
		wl = workloadFor(job, nil)
		step(key)
		second := last(key).NodeUIDs[name]
		Expect(second).NotTo(BeEmpty())
		Expect(second).NotTo(Equal(first))
		failRank(job)
		step(key)
		step(key)
		setReady(name, corev1.ConditionFalse)
		retire(onIt, wl)

		step(key)
		Expect(last(key).State).To(Equal(attemptStopping), "the bare name written for the first machine stopped the barrier for the second")
		Expect(last(key).WaitingFor).To(Equal("node " + name + " to be fenced (annotation " + annFencedNodes +
			"); an earlier attempt ran on another machine of the same name, so name it as " + name + "@" + second +
			"; an entry an earlier attempt stopped on is spent, so scope one to this attempt as name#2"))
		Expect(attempts(key)[0].FencedBy).To(Equal([]string{name}), "attempt 1 did not record the entry it stopped on")

		By("an entry bound to the first machine does not fence the second either")
		mltj = getMLTJ(key)
		mltj.Annotations = map[string]string{annFencedNodes: name + "," + name + "@" + first}
		Expect(k8sClient.Update(ctx, mltj)).To(Succeed())
		step(key)
		Expect(last(key).State).To(Equal(attemptStopping))

		mltj = getMLTJ(key)
		mltj.Annotations = map[string]string{annFencedNodes: name + "," + name + "@" + second}
		Expect(k8sClient.Update(ctx, mltj)).To(Succeed())
		step(key)
		Expect(last(key).State).To(Equal(attemptStopped))
	})

	It("takes a failed Job whose Workload the fault path handed off as NodeFault, not RankFailed", func() {
		key := create(1)
		job := untilActive(key)

		// The fault path's eviction can fail the Job before this controller next looks, and both are then true at once.
		wl := workloadFor(job, nil)
		wl.Annotations = map[string]string{AnnRestartHandoff: "fp-1"}
		Expect(k8sClient.Update(ctx, wl)).To(Succeed())
		awaitCachedWorkload(wl.Name, ns, func(w *kueuev1beta1.Workload) bool { return w.Annotations[AnnRestartHandoff] != "" })
		failRank(job)
		step(key)
		Expect(last(key).State).To(Equal(attemptStopping))
		Expect(last(key).Trigger).To(Equal(triggerNodeFault))
	})

	// The Pods below carry finRankStopped from the start, as the Job controller copies it from the template.
	heldRankPod := func(mltj *platformv1.MLTrainingJob, attempt int, onNode string) *corev1.Pod {
		GinkgoHelper()
		p := &corev1.Pod{
			Name: mltj.Name + "-" + rand.String(5), Namespace: ns, Finalizers: []string{finRankStopped},
			Labels: map[string]string{mltjUIDLabel: string(mltj.UID), mltjAttemptLabel: strconv.Itoa(attempt)},
			Spec: corev1.PodSpec{
				NodeName:   onNode,
				Containers: []corev1.Container{{Name: "trainer", Image: "trainer:v1"}},
			},
		}
		Expect(k8sClient.Create(ctx, p)).To(Succeed())
		DeferCleanup(func() {
			var cur corev1.Pod
			if k8sClient.Get(ctx, client.ObjectKeyFromObject(p), &cur) == nil {
				cur.Finalizers = nil
				_ = k8sClient.Update(ctx, &cur)
			}
			_ = k8sClient.Delete(ctx, p, client.GracePeriodSeconds(0))
		})
		bind(p)
		return p
	}
	gone := func(p *corev1.Pod) bool {
		return apierrors.IsNotFound(k8sClient.Get(ctx, client.ObjectKeyFromObject(p), &corev1.Pod{}))
	}

	It("renders the rank Pods of an attempt with finRankStopped, and the ordinary Job without it", func() {
		mltj := &platformv1.MLTrainingJob{Name: "t", Namespace: ns, Spec: platformv1.MLTrainingJobSpec{
			Queue: "q", Image: "i", GPUCount: 1, Distributed: &platformv1.Distributed{WorldSize: 2, MaxRestarts: 1},
			StateVolume: &platformv1.StateVolume{ClaimName: "c", MountPath: "/c"},
		}}
		Expect(buildJob(mltj, 1).Spec.Template.Finalizers).To(Equal([]string{finRankStopped}))
		Expect(buildJob(mltj, 0).Spec.Template.Finalizers).To(BeEmpty())
	})

	It("keeps a rank Pod it never saw until it has recorded the Pod's node and the node is fenced", func() {
		key := create(1)
		job := untilActive(key)
		mltj := getMLTJ(key)

		By("the controller is away while a rank is bound, its machine is lost and its Pod deleted")
		name := node(corev1.ConditionTrue)
		p := heldRankPod(mltj, 1, name)
		wl := workloadFor(job, nil)
		Expect(k8sClient.Delete(ctx, p, client.GracePeriodSeconds(0))).To(Succeed())
		Expect(k8sClient.Delete(ctx, &corev1.Node{Name: name})).To(Succeed())
		Eventually(func() bool {
			return apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Name: name}, &corev1.Node{}))
		}, 10*time.Second, 50*time.Millisecond).Should(BeTrue())
		Expect(gone(p)).To(BeFalse(), "the finalizer did not keep the Pod")

		By("on its return it records the node and does not let the Pod go")
		failRank(job)
		step(key)
		step(key)
		collect(key)
		step(key)
		Expect(last(key).NodeUIDs).To(HaveKeyWithValue(name, nodeUIDAbsent))
		Expect(last(key).State).To(Equal(attemptStopping))
		Expect(last(key).WaitingFor).To(ContainSubstring("held until their kubelet reports them stopped or their node is fenced: " + p.Name + "@" + name))
		Expect(gone(p)).To(BeFalse())

		By("fenced, the Pod is released and the attempt stops")
		mltj = getMLTJ(key)
		mltj.Annotations = map[string]string{annFencedNodes: name}
		Expect(k8sClient.Update(ctx, mltj)).To(Succeed())
		step(key)
		Eventually(func() bool { return gone(p) }, 10*time.Second, 50*time.Millisecond).Should(BeTrue())
		Expect(k8sClient.Delete(ctx, wl)).To(Succeed())
		step(key)
		Expect(last(key).State).To(Equal(attemptStopped))
	})

	It("keeps a Pod force-deleted from a Ready node until its kubelet reports it stopped", func() {
		key := create(1)
		job := untilActive(key)
		mltj := getMLTJ(key)
		name := node(corev1.ConditionTrue)
		p := heldRankPod(mltj, 1, name)
		wl := workloadFor(job, nil)
		step(key)
		failRank(job)
		step(key)
		step(key)
		collect(key)
		Expect(k8sClient.Delete(ctx, p, client.GracePeriodSeconds(0))).To(Succeed())
		step(key)
		Expect(last(key).State).To(Equal(attemptStopping))
		Expect(last(key).WaitingFor).To(ContainSubstring(p.Name + "@" + name))
		Expect(gone(p)).To(BeFalse(), "a Ready node's force-deleted Pod was released with no stop reported")

		By("its kubelet reports the Pod terminal")
		var cur corev1.Pod
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(p), &cur)).To(Succeed())
		cur.Status.Phase = corev1.PodFailed
		Expect(k8sClient.Status().Update(ctx, &cur)).To(Succeed())
		step(key)
		Eventually(func() bool { return gone(p) }, 10*time.Second, 50*time.Millisecond).Should(BeTrue())
		Expect(k8sClient.Delete(ctx, wl)).To(Succeed())
		step(key)
		Expect(last(key).State).To(Equal(attemptStopped), "a Ready node whose Pod reported its stop still needed fencing")
	})

	It("does not take a Node registered after the rank was bound for the machine the rank ran on", func() {
		key := create(1)
		job := untilActive(key)
		mltj := getMLTJ(key)
		name := node(corev1.ConditionTrue)
		p := heldRankPod(mltj, 1, name)
		// Bound an hour before the Node that now carries the name was registered.
		p.Status.Conditions = []corev1.PodCondition{{Type: corev1.PodScheduled, Status: corev1.ConditionTrue,
			LastTransitionTime: metav1.NewTime(time.Now().Add(-time.Hour))}}
		Expect(k8sClient.Status().Update(ctx, p)).To(Succeed())
		wl := workloadFor(job, nil)
		step(key)
		Expect(last(key).NodeUIDs).To(HaveKeyWithValue(name, nodeUIDReplaced))

		failRank(job)
		step(key)
		step(key)
		collect(key)
		var cur corev1.Pod
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(p), &cur)).To(Succeed())
		cur.Status.Phase = corev1.PodFailed
		Expect(k8sClient.Status().Update(ctx, &cur)).To(Succeed())
		// Grace 0 stands for the kubelet's own final delete, which no kubelet here issues.
		Expect(k8sClient.Delete(ctx, &cur, client.GracePeriodSeconds(0))).To(Succeed())
		step(key)
		Eventually(func() bool { return gone(p) }, 10*time.Second, 50*time.Millisecond).Should(BeTrue())
		Expect(k8sClient.Delete(ctx, wl)).To(Succeed())
		step(key)
		Expect(last(key).State).To(Equal(attemptStopping), "the replacement Node's readiness vouched for the machine the rank ran on")
		Expect(last(key).WaitingFor).To(HavePrefix("node " + name + " to be fenced"))
	})

	It("spends a fence entry, so the same machine lost again in a later attempt needs one scoped to that attempt", func() {
		key := create(2)
		job := untilActive(key)
		mltj := getMLTJ(key)
		name := node(corev1.ConditionTrue)
		setReady := func(status corev1.ConditionStatus) {
			GinkgoHelper()
			var n corev1.Node
			Expect(k8sClient.Get(ctx, types.NamespacedName{Name: name}, &n)).To(Succeed())
			n.Status.Conditions = []corev1.NodeCondition{{Type: corev1.NodeReady, Status: status, LastHeartbeatTime: metav1.Now()}}
			Expect(k8sClient.Status().Update(ctx, &n)).To(Succeed())
		}
		lose := func(attempt int) {
			GinkgoHelper()
			onIt := rankPod(mltj, attempt, name)
			wl := workloadFor(job, nil)
			step(key)
			failRank(job)
			step(key)
			step(key)
			setReady(corev1.ConditionFalse)
			collect(key)
			Expect(k8sClient.Delete(ctx, onIt, client.GracePeriodSeconds(0))).To(Succeed())
			Eventually(func() bool { return gone(onIt) }, 10*time.Second, 50*time.Millisecond).Should(BeTrue())
			Expect(k8sClient.Delete(ctx, wl)).To(Succeed())
			step(key)
		}

		By("attempt 1 stops on a bare name")
		lose(1)
		mltj = getMLTJ(key)
		mltj.Annotations = map[string]string{annFencedNodes: name}
		Expect(k8sClient.Update(ctx, mltj)).To(Succeed())
		step(key)
		Expect(last(key).State).To(Equal(attemptStopped))
		Expect(last(key).FencedBy).To(Equal([]string{name}))

		By("the same machine comes back, runs attempt 2 and is lost again")
		job = untilActive(key)
		setReady(corev1.ConditionTrue)
		mltj = getMLTJ(key)
		lose(2)
		Expect(last(key).State).To(Equal(attemptStopping), "attempt 1's acknowledgement stood for attempt 2")
		Expect(last(key).WaitingFor).To(ContainSubstring("scope one to this attempt as name#2"))

		mltj = getMLTJ(key)
		mltj.Annotations = map[string]string{annFencedNodes: name + "," + name + "#1"}
		Expect(k8sClient.Update(ctx, mltj)).To(Succeed())
		step(key)
		Expect(last(key).State).To(Equal(attemptStopping), "an entry scoped to attempt 1 stood for attempt 2")

		mltj = getMLTJ(key)
		mltj.Annotations = map[string]string{annFencedNodes: name + "," + name + "#2"}
		Expect(k8sClient.Update(ctx, mltj)).To(Succeed())
		step(key)
		Expect(last(key).State).To(Equal(attemptStopped))
	})

	It("takes a Kueue eviction as Evicted, and an operator's deactivation as no trigger", func() {
		evict := func(reason string, active bool) types.NamespacedName {
			GinkgoHelper()
			key := create(1)
			job := untilActive(key)
			wl := workloadFor(job, nil)
			if !active {
				wl.Spec.Active = new(false)
				Expect(k8sClient.Update(ctx, wl)).To(Succeed())
			}
			meta.SetStatusCondition(&wl.Status.Conditions, metav1.Condition{
				Type: kueuev1beta1.WorkloadEvicted, Status: metav1.ConditionTrue, Reason: reason, Message: "test",
			})
			Expect(k8sClient.Status().Update(ctx, wl)).To(Succeed())
			awaitCachedWorkload(wl.Name, ns, func(w *kueuev1beta1.Workload) bool {
				return meta.IsStatusConditionTrue(w.Status.Conditions, kueuev1beta1.WorkloadEvicted)
			})
			step(key)
			return key
		}
		key := evict(kueuev1beta1.WorkloadEvictedByPreemption, true)
		Expect(last(key).State).To(Equal(attemptStopping))
		Expect(last(key).Trigger).To(Equal(triggerEvicted))

		key = evict(kueuev1beta1.WorkloadDeactivated, false)
		Expect(last(key).State).To(Equal(attemptActive))

		By("Kueue's derived deactivation reasons are deactivations too")
		key = evict(kueuev1beta1.WorkloadDeactivated+"DueToRequeuingLimitExceeded", true)
		Expect(last(key).State).To(Equal(attemptActive))

		By("an operator's stop after an earlier preemption, with Kueue still showing the preemption")
		key = evict(kueuev1beta1.WorkloadEvictedByPreemption, false)
		Expect(last(key).State).To(Equal(attemptActive), "a deactivated Workload's old eviction restarted the job")
	})

	It("releases the ranks of a deleted job whose Job the stop barrier is already deleting in the foreground", func() {
		key := create(1)
		job := untilActive(key)
		mltj := getMLTJ(key)
		name := node(corev1.ConditionTrue)
		p := heldRankPod(mltj, 1, name)
		workloadFor(job, nil)
		step(key)
		failRank(job)
		step(key)
		step(key)
		Expect(last(key).WaitingFor).To(HavePrefix("job "), "the barrier was not deleting the Job")
		Expect(k8sClient.Delete(ctx, getMLTJ(key))).To(Succeed())
		var cur corev1.Pod
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(p), &cur)).To(Succeed())
		cur.Status.Phase = corev1.PodFailed
		Expect(k8sClient.Status().Update(ctx, &cur)).To(Succeed())
		Expect(k8sClient.Delete(ctx, &cur, client.GracePeriodSeconds(0))).To(Succeed())
		step(key)
		Eventually(func() bool { return gone(p) }, 10*time.Second, 50*time.Millisecond).Should(BeTrue(),
			"a stopped rank stayed held behind the Job that waits for it")
	})

	It("decides a node's identity only once the rank's binding is published", func() {
		key := create(1)
		untilActive(key)
		mltj := getMLTJ(key)
		p := &corev1.Pod{
			Name: mltj.Name + "-" + rand.String(5), Namespace: ns,
			Labels: map[string]string{mltjUIDLabel: string(mltj.UID), mltjAttemptLabel: "1"},
			Spec:   corev1.PodSpec{Containers: []corev1.Container{{Name: "trainer", Image: "trainer:v1"}}},
		}
		Expect(k8sClient.Create(ctx, p)).To(Succeed())
		DeferCleanup(func() { _ = k8sClient.Delete(ctx, p, client.GracePeriodSeconds(0)) })
		// Pending for a while, then an autoscaler's new node, and the Pod bound to it before the binding is published.
		time.Sleep(1100 * time.Millisecond)
		name := node(corev1.ConditionTrue)
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(p), p)).To(Succeed())
		Expect(k8sClient.SubResource("binding").Create(ctx, p, &corev1.Binding{
			Name: p.Name, Namespace: ns,
			Target: corev1.ObjectReference{Kind: "Node", Name: name},
		})).To(Succeed())
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(p), p)).To(Succeed())
		p.Status.Conditions = nil
		Expect(k8sClient.Status().Update(ctx, p)).To(Succeed())
		step(key)
		Expect(last(key).Nodes).To(ContainElement(name))
		Expect(last(key).NodeUIDs).NotTo(HaveKey(name), "an identity was decided with no binding time")

		bind(p)
		step(key)
		var n corev1.Node
		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: name}, &n)).To(Succeed())
		Expect(last(key).NodeUIDs).To(HaveKeyWithValue(name, string(n.UID)), "the autoscaler's node was taken for a replacement")
	})

	It("reads the handoff past a cache that has not seen it before calling a failed Job RankFailed", func() {
		key := create(1)
		job := untilActive(key)
		wl := workloadFor(job, nil)
		wl.Annotations = map[string]string{AnnRestartHandoff: "fp-1"}
		Expect(k8sClient.Update(ctx, wl)).To(Succeed())
		awaitCachedWorkload(wl.Name, ns, func(w *kueuev1beta1.Workload) bool { return w.Annotations[AnnRestartHandoff] != "" })
		failRank(job)
		// A reconciler whose cached reads still show the Workload as it was before the handoff.
		r := reconciler()
		r.Client = staleHandoff{Client: r.Client}
		_, err := r.Reconcile(ctx, reconcile.Request{NamespacedName: key})
		Expect(err).NotTo(HaveOccurred())
		Expect(last(key).Trigger).To(Equal(triggerNodeFault))
	})

	It("holds a deleted job until every rank Pod is known stopped", func() {
		key := create(1)
		job := untilActive(key)
		mltj := getMLTJ(key)
		name := node(corev1.ConditionTrue)
		p := heldRankPod(mltj, 1, name)
		step(key)
		Expect(k8sClient.Delete(ctx, mltj)).To(Succeed())
		step(key)
		collect(key)
		step(key)
		Expect(getMLTJ(key).Finalizers).To(ContainElement(mlTrainingJobFinalizer), "the job went while its rank had not stopped")
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(job), &batchv1.Job{})).NotTo(Succeed())

		var cur corev1.Pod
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(p), &cur)).To(Succeed())
		Expect(k8sClient.Delete(ctx, &cur, client.GracePeriodSeconds(0))).To(Succeed())
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(p), &cur)).To(Succeed())
		cur.Status.Phase = corev1.PodFailed
		Expect(k8sClient.Status().Update(ctx, &cur)).To(Succeed())
		step(key)
		Eventually(func() bool { return gone(p) }, 10*time.Second, 50*time.Millisecond).Should(BeTrue())
		step(key)
		Eventually(func() bool {
			return apierrors.IsNotFound(k8sClient.Get(ctx, key, &platformv1.MLTrainingJob{}))
		}, 10*time.Second, 50*time.Millisecond).Should(BeTrue())
	})

	// Mutation that turns this red: drop the AdmittedAt reset in trigger.
	It("does not carry an attempt's admission stamp into the next attempt's admission-to-running window", func() {
		key := create(1)
		job := untilActive(key)
		wl := workloadFor(job, nil)
		wl.Status.Conditions = []metav1.Condition{{
			Type: kueuev1beta1.WorkloadAdmitted, Status: metav1.ConditionTrue, Reason: "Admitted",
			LastTransitionTime: metav1.NewTime(time.Now().Add(-time.Minute)),
		}}
		Expect(k8sClient.Status().Update(ctx, wl)).To(Succeed())
		awaitCachedWorkload(wl.Name, ns, hasAdmittedCondition)
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(job), job)).To(Succeed())
		job.Spec.Suspend = new(false)
		Expect(k8sClient.Update(ctx, job)).To(Succeed())
		Eventually(func() *metav1.Time {
			step(key)
			return getMLTJ(key).Status.AdmittedAt
		}, 10*time.Second, 50*time.Millisecond).ShouldNot(BeNil(), "attempt 1's admission was never recorded")
		Expect(getMLTJ(key).Status.RunningObservedAt).To(BeNil())

		failRank(job)
		step(key)
		Expect(last(key).State).To(Equal(attemptStopping))
		Expect(getMLTJ(key).Status.AdmittedAt).To(BeNil(), "attempt 1's admission stamp survived its failure")
	})

	// The design's first failure row: two attempts at once after a conflict or a crash between steps. Every second
	// status write here fails, half of them as a conflict and half as a write the server never answered, and the
	// first create of each attempt's Job lands but loses its response. Exactly one Job per attempt must exist,
	// adopted by its token, and the budget spent once (codex review r10, finding 7).
	//
	// Mutations that turn this red: adopt a Job without checking its attempt token, or let trigger append an
	// attempt instead of moving the current one to Stopping.
	It("keeps one attempt per step through failed status writes, conflicts and a create whose response was lost", func() {
		key := create(1)
		f := &flakyWrites{Client: asManager}
		r := reconciler()
		r.Client = f
		flaky := func() {
			GinkgoHelper()
			_, _ = r.Reconcile(ctx, reconcile.Request{NamespacedName: key})
		}
		jobsOf := func() []batchv1.Job {
			GinkgoHelper()
			var jobs batchv1.JobList
			Expect(k8sClient.List(ctx, &jobs, client.InNamespace(ns))).To(Succeed())
			var out []batchv1.Job
			for _, j := range jobs.Items {
				if j.Name == key.Name && j.DeletionTimestamp.IsZero() {
					out = append(out, j)
				}
			}
			return out
		}

		Eventually(func() string {
			flaky()
			a := attempts(key)
			if len(a) == 0 {
				return ""
			}
			return a[len(a)-1].State
		}, 20*time.Second, 50*time.Millisecond).Should(Equal(attemptActive))
		Expect(f.lostCreates).To(BeNumerically(">=", 1), "no create lost its response, so adoption was not exercised")
		Expect(f.failedStatus).To(BeNumerically(">=", 1), "no status write failed")
		Expect(attempts(key)).To(HaveLen(1))
		jobs := jobsOf()
		Expect(jobs).To(HaveLen(1))
		Expect(last(key).JobUID).To(Equal(string(jobs[0].UID)), "the attempt did not adopt the Job its lost create made")

		By("a rank fails, and the trigger, the stop and the next attempt all go through the same failing writes")
		job := jobs[0]
		failRank(&job)
		// The trigger first: collect deletes the Job, and a Job deleted before the trigger is recorded is JobDeleted.
		Eventually(func() string {
			flaky()
			return attempts(key)[0].State
		}, 20*time.Second, 50*time.Millisecond).Should(Equal(attemptStopping))
		Expect(attempts(key)[0].Trigger).To(Equal(triggerRankFailed))
		Eventually(func() string {
			flaky()
			// The garbage collector's part, for attempt 1's Job only; attempt 2's Job is the one being checked.
			a := attempts(key)
			if len(a) == 1 {
				collect(key)
				return ""
			}
			return a[len(a)-1].State
		}, 30*time.Second, 50*time.Millisecond).Should(Equal(attemptActive))
		a := attempts(key)
		Expect(a).To(HaveLen(2), "the budget was spent more than once")
		Expect(a[0].State).To(Equal(attemptStopped))
		Expect(a[0].Trigger).To(Equal(triggerRankFailed))
		jobs = jobsOf()
		Expect(jobs).To(HaveLen(1))
		Expect(jobs[0].Labels[mltjAttemptLabel]).To(Equal("2"))
		Expect(a[1].JobUID).To(Equal(string(jobs[0].UID)))
		Expect(f.failedStatus).To(BeNumerically(">=", 2), "the conflict was never injected")
		Expect(f.lostCreates).To(Equal(2), "attempt 2's create did not lose its response")
	})
})

// flakyWrites fails every second MLTrainingJob status write, alternating a conflict with an error the server sent
// no answer for, and lets each Job create land on the server while reporting it failed.
type flakyWrites struct {
	client.Client
	statusCalls, failedStatus, lostCreates int
	createdFor                             map[string]bool
}

func (f *flakyWrites) Create(ctx context.Context, obj client.Object, opts ...client.CreateOption) error {
	err := f.Client.Create(ctx, obj, opts...)
	job, ok := obj.(*batchv1.Job)
	if err != nil || !ok {
		return err
	}
	if f.createdFor == nil {
		f.createdFor = map[string]bool{}
	}
	if attempt := job.Labels[mltjAttemptLabel]; !f.createdFor[attempt] {
		f.createdFor[attempt] = true
		f.lostCreates++
		return fmt.Errorf("the create's response was lost")
	}
	return nil
}

func (f *flakyWrites) Status() client.SubResourceWriter {
	return flakyStatus{SubResourceWriter: f.Client.Status(), f: f}
}

type flakyStatus struct {
	client.SubResourceWriter
	f *flakyWrites
}

func (s flakyStatus) Update(ctx context.Context, obj client.Object, opts ...client.SubResourceUpdateOption) error {
	if _, ok := obj.(*platformv1.MLTrainingJob); ok {
		s.f.statusCalls++
		if s.f.statusCalls%2 == 0 {
			s.f.failedStatus++
			if s.f.failedStatus%2 == 0 {
				return apierrors.NewConflict(schema.GroupResource{Group: platformv1.GroupVersion.Group, Resource: "mltrainingjobs"},
					obj.GetName(), fmt.Errorf("injected"))
			}
			return fmt.Errorf("injected: the status write was not answered")
		}
	}
	return s.SubResourceWriter.Update(ctx, obj, opts...)
}

// staleHandoff is a client whose Workload reads have not yet seen the fault path's handoff.
type staleHandoff struct{ client.Client }

func (s staleHandoff) List(ctx context.Context, list client.ObjectList, opts ...client.ListOption) error {
	if err := s.Client.List(ctx, list, opts...); err != nil {
		return err
	}
	if wls, ok := list.(*kueuev1beta1.WorkloadList); ok {
		for i := range wls.Items {
			delete(wls.Items[i].Annotations, AnnRestartHandoff)
		}
	}
	return nil
}
