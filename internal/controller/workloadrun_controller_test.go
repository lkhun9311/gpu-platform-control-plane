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
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// wrSeq keeps object names unique across specs without a random source; envtest keeps the cluster between
// them, and a reused name would let one spec observe another's leftovers.
var wrSeq int

var _ = Describe("WorkloadRun", func() {
	const ns = "default"
	var (
		ctx     context.Context
		clock   time.Time
		rec     *WorkloadRunReconciler
		runName string
		tgtName string
	)

	// tick advances the injected clock and reconciles once, which is how a window is driven without one.
	tick := func(d time.Duration) {
		clock = clock.Add(d)
		_, err := rec.Reconcile(ctx, ctrl.Request{NamespacedName: types.NamespacedName{Name: runName, Namespace: ns}})
		Expect(err).NotTo(HaveOccurred())
	}
	load := func() platformv1.WorkloadRun {
		var run platformv1.WorkloadRun
		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: runName, Namespace: ns}, &run)).To(Succeed())
		return run
	}
	setTargetPhase := func(phase string) {
		var infd platformv1.InferenceDeployment
		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: tgtName, Namespace: ns}, &infd)).To(Succeed())
		infd.Status.Phase = phase
		Expect(k8sClient.Status().Update(ctx, &infd)).To(Succeed())
	}

	BeforeEach(func() {
		ctx = context.Background()
		clock = time.Date(2026, 8, 24, 12, 0, 0, 0, time.UTC)
		rec = &WorkloadRunReconciler{Client: k8sClient, Scheme: k8sClient.Scheme(), Now: func() time.Time { return clock }}

		wrSeq++
		tgtName = fmt.Sprintf("wr-target-%d", wrSeq)
		runName = fmt.Sprintf("wr-run-%d", wrSeq)
		Expect(k8sClient.Create(ctx, &platformv1.InferenceDeployment{
			ObjectMeta: metav1.ObjectMeta{Name: tgtName, Namespace: ns},
			Spec: platformv1.InferenceDeploymentSpec{
				Model:    platformv1.InferenceModel{Name: "demo", StorageURI: "hf://demo"},
				Image:    "registry.k8s.io/pause:3.9",
				GPUCount: 0,
				Replicas: 1,
				Port:     8000,
			},
		})).To(Succeed())
	})

	createRun := func(window, deadline int32, targetName string) {
		Expect(k8sClient.Create(ctx, &platformv1.WorkloadRun{
			ObjectMeta: metav1.ObjectMeta{Name: runName, Namespace: ns},
			Spec: platformv1.WorkloadRunSpec{
				Scenario:                 platformv1.ScenarioServingPodKilled,
				Target:                   platformv1.WorkloadRunTarget{Kind: "InferenceDeployment", Name: targetName, Namespace: ns},
				ObservationWindowSeconds: window,
				RecoversWithinSeconds:    deadline,
			},
		})).To(Succeed())
	}

	It("records only what changed, and calls a recovery inside the deadline Recovered", func() {
		createRun(30, 20, tgtName)
		setTargetPhase("Degraded")

		tick(0) // opens the window
		Expect(load().Status.Phase).To(Equal(platformv1.WorkloadRunObserving))

		// Three polls with nothing changing must not put three entries in the trail: a trail that grew with
		// the poll rate would report how often the controller ran, not what the platform did.
		tick(5 * time.Second)
		tick(5 * time.Second)
		tick(5 * time.Second)
		Expect(load().Status.Observations).To(HaveLen(1))

		setTargetPhase("Ready")
		tick(5 * time.Second)
		run := load()
		Expect(run.Status.Observations).To(HaveLen(2))
		Expect(run.Status.RecoveredAtSeconds).NotTo(BeNil())
		Expect(*run.Status.RecoveredAtSeconds).To(Equal(int32(20)))

		tick(10 * time.Second) // closes the window; every tick stays inside workloadRunMaxGap
		run = load()
		Expect(run.Status.Phase).To(Equal(platformv1.WorkloadRunComplete))
		Expect(run.Status.Verdict).To(Equal(platformv1.VerdictRecovered))
	})

	It("calls a recovery after the declared deadline NotRecovered rather than a slow pass", func() {
		createRun(40, 10, tgtName)
		setTargetPhase("Degraded")
		tick(0)

		// Healthy at 20s against a 10s deadline. The deadline was declared before the run, so this is a fail.
		//
		// Every tick stays inside workloadRunMaxGap. The first version of this spec jumped 25 s in one step
		// and was REFUSED rather than judged -- which is the gap check working, and is why the window is
		// walked rather than skipped to.
		tick(10 * time.Second)
		setTargetPhase("Ready")
		tick(10 * time.Second)
		tick(10 * time.Second)
		tick(10 * time.Second)

		run := load()
		Expect(run.Status.Phase).To(Equal(platformv1.WorkloadRunComplete))
		Expect(run.Status.Verdict).To(Equal(platformv1.VerdictNotRecovered))
		Expect(run.Status.Reason).To(ContainSubstring("after the declared"))
	})

	It("refuses rather than concludes when the trail has a hole", func() {
		createRun(60, 30, tgtName)
		setTargetPhase("Degraded")
		tick(0)

		// The controller was not running for four polls. Whatever the target did in that time, this run did
		// not see it, and a verdict computed across the gap would be a claim about an unwatched window.
		setTargetPhase("Ready")
		tick(4 * workloadRunPoll)

		run := load()
		Expect(run.Status.Phase).To(Equal(platformv1.WorkloadRunRefused))
		Expect(run.Status.Reason).To(ContainSubstring("the trail has a hole"))
		// A refused run answers nothing. A leftover verdict beside it would be read as an answer, and the
		// target HAD gone Ready -- so a controller that kept the verdict would report a pass it did not see.
		Expect(run.Status.Verdict).To(BeEmpty())
	})

	It("refuses a target that never existed instead of blaming the platform", func() {
		createRun(30, 20, fmt.Sprintf("wr-absent-%d", wrSeq))
		tick(0)

		run := load()
		Expect(run.Status.Phase).To(Equal(platformv1.WorkloadRunRefused))
		Expect(run.Status.Reason).To(ContainSubstring("nothing this run could be evidence about"))
		Expect(run.Status.Verdict).To(BeEmpty())
	})

	It("refuses when the target is deleted mid-window", func() {
		createRun(60, 30, tgtName)
		setTargetPhase("Degraded")
		tick(0)

		var infd platformv1.InferenceDeployment
		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: tgtName, Namespace: ns}, &infd)).To(Succeed())
		Expect(k8sClient.Delete(ctx, &infd)).To(Succeed())
		Eventually(func() bool {
			var got platformv1.InferenceDeployment
			return apierrors.IsNotFound(k8sClient.Get(ctx, types.NamespacedName{Name: tgtName, Namespace: ns}, &got))
		}, "20s", "200ms").Should(BeTrue(), "the target must actually be gone before the run looks for it")

		tick(5 * time.Second)
		run := load()
		Expect(run.Status.Phase).To(Equal(platformv1.WorkloadRunRefused))
		Expect(run.Status.Reason).To(ContainSubstring("stopped existing"))
	})

	It("does not re-judge a run that already reached a terminal state", func() {
		createRun(10, 5, tgtName)
		setTargetPhase("Ready")
		tick(0)
		tick(10 * time.Second)
		Expect(load().Status.Phase).To(Equal(platformv1.WorkloadRunComplete))

		// The target degrades afterwards. A completed run is evidence about ITS window and must not be
		// rewritten by what happened later.
		setTargetPhase("Degraded")
		before := load()
		tick(10 * time.Second)
		after := load()
		Expect(after.Status.Verdict).To(Equal(before.Status.Verdict))
		Expect(after.Status.Observations).To(HaveLen(len(before.Status.Observations)))
	})
})
