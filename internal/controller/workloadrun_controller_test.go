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
	"testing"
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
	// setTargetPhase reports a phase AND a replica count consistent with it.
	//
	// The count used to be left at zero, and that was the same hole a cold review found in the product: phase
	// Ready with no ready replica is a scaled-to-zero InferenceDeployment, which serves nothing. Every recovery
	// these specs asserted was therefore a recovery to a target that was not carrying work -- the fixture
	// agreed with the defect instead of catching it. Ready now means one ready replica; anything else means
	// none, which is what a degraded or pending deployment reports.
	setTargetPhase := func(phase string) {
		var infd platformv1.InferenceDeployment
		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: tgtName, Namespace: ns}, &infd)).To(Succeed())
		infd.Status.Phase = phase
		if phase == "Ready" {
			infd.Status.ReadyReplicas = 1
		} else {
			infd.Status.ReadyReplicas = 0
		}
		Expect(k8sClient.Status().Update(ctx, &infd)).To(Succeed())
	}

	// setTargetScaledToZero reports exactly what an InferenceDeployment says when someone edits spec.replicas
	// to 0: phase Ready, and nothing serving.
	setTargetScaledToZero := func() {
		var infd platformv1.InferenceDeployment
		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: tgtName, Namespace: ns}, &infd)).To(Succeed())
		infd.Status.Phase = "Ready"
		infd.Status.ReadyReplicas = 0
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

	// The deadline must sit inside the window, and until 2026-09-26 nothing enforced it.
	//
	// recoversWithinSeconds' own comment has said so since the type was written. There is no WorkloadRun
	// webhook, and the only CEL rules on the spec were the two immutability ones, so a run whose deadline
	// ran past its window was accepted -- and then judged against a moment the controller had stopped
	// watching before. A constraint a document states and no machine checks is worth exactly nothing.
	//
	// Mutation that turns this red: remove the XValidation rule from WorkloadRunSpec and regenerate.
	It("refuses a deadline that outlives the observation window", func() {
		err := k8sClient.Create(ctx, &platformv1.WorkloadRun{
			ObjectMeta: metav1.ObjectMeta{Name: runName + "-past-window", Namespace: ns},
			Spec: platformv1.WorkloadRunSpec{
				Scenario:                 platformv1.ScenarioServingPodKilled,
				Target:                   platformv1.WorkloadRunTarget{Kind: "InferenceDeployment", Name: tgtName, Namespace: ns},
				ObservationWindowSeconds: 30,
				RecoversWithinSeconds:    31,
			},
		})
		Expect(err).To(HaveOccurred(), "a deadline past the window was accepted; the run would judge a moment it stopped watching")
		Expect(err.Error()).To(ContainSubstring("recoversWithinSeconds must not exceed observationWindowSeconds"))
	})

	// The boundary is allowed on purpose: a deadline exactly at the edge is still inside the window, and a
	// rule that excluded it would refuse the most natural way to say "by the end".
	It("accepts a deadline exactly at the end of the window", func() {
		Expect(k8sClient.Create(ctx, &platformv1.WorkloadRun{
			ObjectMeta: metav1.ObjectMeta{Name: runName + "-at-edge", Namespace: ns},
			Spec: platformv1.WorkloadRunSpec{
				Scenario:                 platformv1.ScenarioServingPodKilled,
				Target:                   platformv1.WorkloadRunTarget{Kind: "InferenceDeployment", Name: tgtName, Namespace: ns},
				ObservationWindowSeconds: 30,
				RecoversWithinSeconds:    30,
			},
		})).To(Succeed(), "a deadline at the window's edge is inside it and must be allowed")
	})

	// The attack path a cold security review traced, pinned as a spec.
	//
	// Observe the target failing, then instead of letting it recover, remove the service: edit spec.replicas to
	// 0. The InferenceDeployment controller correctly reports that as phase Ready -- nobody asked for replicas
	// -- and until the watcher required a ready replica it read that as health, credited a recovery, and
	// awarded Recovered. No status-write permission is needed for this, only the ability to edit the target CR,
	// and the ledger then preserved the false recovery as evidence.
	It("does not call a target scaled to zero a recovery", func() {
		createRun(30, 25, tgtName)
		setTargetPhase("Degraded")
		tick(0) // opens the window on an observed failure
		Expect(load().Status.ObservedUnhealthy).To(BeTrue())

		setTargetScaledToZero()
		tick(5 * time.Second)
		tick(5 * time.Second)

		run := load()
		Expect(run.Status.RecoveredAtSeconds).To(BeNil(),
			"scaling the target to zero was credited as a recovery; the run would report a recovery to nothing")

		tick(10 * time.Second)
		tick(10 * time.Second) // closes the window
		run = load()
		Expect(run.Status.Verdict).NotTo(Equal(platformv1.VerdictRecovered))
		Expect(run.Status.Verdict).To(Equal(platformv1.VerdictNotRecovered))

		// The trail holds the target's own word beside this controller's reading of it, which is what makes the
		// record legible afterwards: the object said Ready and was serving nothing.
		last := run.Status.Observations[len(run.Status.Observations)-1]
		Expect(last.State).To(Equal("Ready"))
		Expect(last.Healthy).To(BeFalse())
	})

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
		// Degraded then Ready, so the run has a failure to recover from and reaches Complete. Starting it
		// healthy would now end in Refused -- correctly, since nothing was observed to fail -- and this spec
		// is about terminality rather than about the verdict.
		createRun(10, 5, tgtName)
		setTargetPhase("Degraded")
		tick(0)
		setTargetPhase("Ready")
		tick(4 * time.Second)
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

var _ = Describe("WorkloadRun recovery semantics", func() {
	const ns = "default"
	var (
		ctx     context.Context
		clock   time.Time
		rec     *WorkloadRunReconciler
		runName string
		tgtName string
	)

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
	// setPhase reports a phase AND a replica count consistent with it.
	//
	// The count used to be left at zero, which made every "Ready" here a scaled-to-zero backend -- serving
	// nothing -- while the specs asserted recoveries against it. The fixture agreed with the defect a cold
	// review later found in the product rather than catching it.
	setPhase := func(phase string) {
		var infd platformv1.InferenceDeployment
		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: tgtName, Namespace: ns}, &infd)).To(Succeed())
		infd.Status.Phase = phase
		if phase == "Ready" {
			infd.Status.ReadyReplicas = 1
		} else {
			infd.Status.ReadyReplicas = 0
		}
		Expect(k8sClient.Status().Update(ctx, &infd)).To(Succeed())
	}

	BeforeEach(func() {
		ctx = context.Background()
		clock = time.Date(2026, 8, 24, 12, 0, 0, 0, time.UTC)
		rec = &WorkloadRunReconciler{Client: k8sClient, Scheme: k8sClient.Scheme(), Now: func() time.Time { return clock }}
		wrSeq++
		tgtName = fmt.Sprintf("wr-rec-target-%d", wrSeq)
		runName = fmt.Sprintf("wr-rec-run-%d", wrSeq)
		Expect(k8sClient.Create(ctx, &platformv1.InferenceDeployment{
			ObjectMeta: metav1.ObjectMeta{Name: tgtName, Namespace: ns},
			Spec: platformv1.InferenceDeploymentSpec{
				Model:    platformv1.InferenceModel{Name: "demo", StorageURI: "stub://demo"},
				Image:    "registry.k8s.io/pause:3.9",
				GPUCount: 0, Replicas: 1, Port: 8090,
			},
		})).To(Succeed())
		Expect(k8sClient.Create(ctx, &platformv1.WorkloadRun{
			ObjectMeta: metav1.ObjectMeta{Name: runName, Namespace: ns},
			Spec: platformv1.WorkloadRunSpec{
				Scenario:                 platformv1.ScenarioServingPodKilled,
				Target:                   platformv1.WorkloadRunTarget{Kind: "InferenceDeployment", Name: tgtName, Namespace: ns},
				ObservationWindowSeconds: 30,
				RecoversWithinSeconds:    25,
			},
		})).To(Succeed())
	})

	// The defect the first end-to-end run exposed, and the reason envtest had not.
	//
	// Every run starts with its target healthy, so crediting the FIRST healthy observation makes the
	// recovery second zero -- before the failure was even injected. The specs above all start their target
	// Degraded, which is the one shape where "first healthy" and "first healthy after failing" agree.
	It("does not credit the healthy state it started in as a recovery", func() {
		setPhase("Ready")
		tick(0)
		tick(10 * time.Second)
		setPhase("Pending")
		tick(5 * time.Second)
		setPhase("Ready")
		tick(5 * time.Second)

		run := load()
		Expect(run.Status.RecoveredAtSeconds).NotTo(BeNil())
		Expect(*run.Status.RecoveredAtSeconds).To(Equal(int32(20)),
			"the recovery is the return to health after the failure, not the state the run began in")
	})

	// A run whose target never moved has not measured a recovery, and must not report one.
	It("refuses when nothing was ever observed to fail", func() {
		setPhase("Ready")
		tick(0)
		for range 4 {
			tick(10 * time.Second)
		}

		run := load()
		Expect(run.Status.Phase).To(Equal(platformv1.WorkloadRunRefused))
		Expect(run.Status.Reason).To(ContainSubstring("never observed unhealthy"))
		Expect(run.Status.Verdict).To(BeEmpty(),
			"a pass here would be the strongest claim resting on the weakest evidence: the platform's phase never moved")
	})

	// A target that fails and stays failed is NotRecovered, not refused: the failure was observed, so there
	// is a recovery to judge and its answer is no.
	It("calls a failure that never comes back NotRecovered rather than refusing", func() {
		setPhase("Ready")
		tick(0)
		setPhase("Pending")
		for range 4 {
			tick(10 * time.Second)
		}

		run := load()
		Expect(run.Status.Phase).To(Equal(platformv1.WorkloadRunComplete))
		Expect(run.Status.Verdict).To(Equal(platformv1.VerdictNotRecovered))
	})
})

// A backend scaled to zero is NOT healthy, and the run says so rather than passing or crediting a recovery.
//
// This spec used to pin the opposite as an intended limit: the InferenceDeployment controller reports a
// deliberate zero-replica state as READY -- correctly, since nobody asked for replicas -- so a recovery
// watcher saw it healthy for the whole window and ended Refused by construction. Its comment named the
// condition under which that would change: "if this test ever fails because a scaled-to-zero backend stops
// reporting Ready, the scenario becomes recordable".
//
// What changed is subtler than the comment predicted, and worse than a missing scenario. The backend still
// reports Ready; the WATCHER stopped reading that as health, because it now requires a ready replica
// (isServing). Until it did, editing a target's spec.replicas to 0 mid-run -- which needs no status-write
// permission -- turned an observed failure into verdict Recovered, and the ledger preserved that as evidence.
// A cold security review found it by tracing the code.
//
// Whether BackendFallback should now return to the scenario enum is a separate API decision and is NOT taken
// here: a scenario needs something that injects it, not just a watcher that could see it.
var _ = Describe("WorkloadRun scenario coverage", func() {
	It("does not read a backend scaled to zero as healthy", func() {
		ctx := context.Background()
		wrSeq++
		name := fmt.Sprintf("wr-zero-%d", wrSeq)

		infd := &platformv1.InferenceDeployment{
			ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default"},
			Spec: platformv1.InferenceDeploymentSpec{
				Model:    platformv1.InferenceModel{Name: "demo", StorageURI: "stub://demo"},
				Image:    "registry.k8s.io/pause:3.9",
				GPUCount: 0, Replicas: 0, Port: 8090,
			},
		}
		Expect(k8sClient.Create(ctx, infd)).To(Succeed())

		// The phase the operator publishes for a deliberately empty backend.
		infd.Status.Phase = "Ready"
		Expect(k8sClient.Status().Update(ctx, infd)).To(Succeed())

		clock := time.Date(2026, 8, 26, 12, 0, 0, 0, time.UTC)
		rec := &WorkloadRunReconciler{Client: k8sClient, Scheme: k8sClient.Scheme(), Now: func() time.Time { return clock }}
		runName := fmt.Sprintf("wr-zero-run-%d", wrSeq)
		Expect(k8sClient.Create(ctx, &platformv1.WorkloadRun{
			ObjectMeta: metav1.ObjectMeta{Name: runName, Namespace: "default"},
			Spec: platformv1.WorkloadRunSpec{
				Scenario:                 platformv1.ScenarioServingPodKilled,
				Target:                   platformv1.WorkloadRunTarget{Kind: "InferenceDeployment", Name: name, Namespace: "default"},
				ObservationWindowSeconds: 20,
				RecoversWithinSeconds:    15,
			},
		})).To(Succeed())

		for range 4 {
			_, err := rec.Reconcile(ctx, ctrl.Request{NamespacedName: types.NamespacedName{Name: runName, Namespace: "default"}})
			Expect(err).NotTo(HaveOccurred())
			clock = clock.Add(10 * time.Second)
		}

		var run platformv1.WorkloadRun
		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: runName, Namespace: "default"}, &run)).To(Succeed())

		// Not Refused any more: a target that serves nothing IS an observed failure, so there is something to
		// judge and the answer is no. What must never happen is Recovered.
		Expect(run.Status.Verdict).NotTo(Equal(platformv1.VerdictRecovered),
			"a backend serving nothing was credited with a recovery")
		Expect(run.Status.Phase).To(Equal(platformv1.WorkloadRunComplete))
		Expect(run.Status.Verdict).To(Equal(platformv1.VerdictNotRecovered))
		Expect(run.Status.ObservedUnhealthy).To(BeTrue(),
			"zero ready replicas is the unhealthy observation; without it the window would close on nothing")

		// The trail keeps the target's own word AND this controller's reading of it, side by side. That pair is
		// the whole point: the object said Ready, and it was not serving.
		Expect(run.Status.Observations).NotTo(BeEmpty())
		Expect(run.Status.Observations[0].State).To(Equal("Ready"),
			"the target's vocabulary is recorded verbatim, not normalised into the watcher's opinion")
		Expect(run.Status.Observations[0].Healthy).To(BeFalse())
	})
})

// The recorder and the kinds it watches must agree on the word for healthy.
//
// workloadRunHealthyPhase is deliberately a separate constant from either controller's, so that a rename on
// either side is a decision rather than a silent reinterpretation of every recorded run. This is the test
// that turns it into one.
//
// The failure it guards is not loud. If NodeHealth renamed its ready phase, the recorder would read every
// sample as unhealthy: the target would be observed to fail, never observed to recover, and every
// DegradedNode run would report NotRecovered -- blaming the platform for a vocabulary mismatch. Nothing in
// the trail would say otherwise, because the trail would be accurate about what the recorder saw.
func TestTheRecorderAndTheWatchedKindsAgreeOnHealthy(t *testing.T) {
	if workloadRunHealthyPhase != phaseReady {
		t.Errorf("the recorder treats %q as healthy and NodeHealth publishes %q; a DegradedNode run would "+
			"read every sample as unhealthy and report NotRecovered for a rename",
			workloadRunHealthyPhase, phaseReady)
	}
	if workloadRunHealthyPhase != infdPhaseReady {
		t.Errorf("the recorder treats %q as healthy and InferenceDeployment publishes %q; a ServingPodKilled "+
			"run would never observe a recovery", workloadRunHealthyPhase, infdPhaseReady)
	}
	// And the phases that are NOT healthy must not be, or a degradation is invisible and the run refuses for
	// having seen nothing fail.
	for _, unhealthy := range []string{phasePending, phaseQuarantine} {
		if unhealthy == workloadRunHealthyPhase {
			t.Errorf("%q is treated as healthy; a target in that state would not register as a failure and "+
				"the run would refuse for having observed nothing to recover from", unhealthy)
		}
	}
}
