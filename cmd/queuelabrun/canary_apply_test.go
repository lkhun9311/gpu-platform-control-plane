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

package main

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
)

// fakeKubelet is the double these tests drive the real canary against, and it is worth being exact about what
// it does and does not stand in for.
//
// It models three behaviours of a cluster that the fake client has none of, each of which the canary depends
// on: the apiserver DEFAULTING a Pod's termination grace period (the fake stores what it is given and defaults
// nothing), a container reporting itself Running, and a container reporting a terminal status with an exit
// code some interval after the Pod was asked to stop. That interval is the entire experiment, so it is a
// per-probe parameter here rather than a fixed behaviour: "SIGTERM honoured" and "SIGKILL after the grace
// period" and "everything killed at once" are the same double with different numbers.
//
// What it emphatically does NOT model is whether a real kubelet delivers SIGTERM at all — which is the very
// question the canary exists to answer and cannot be answered by a double. These tests establish that the
// canary reads a cluster correctly and judges what it read; only a run against a real cluster establishes what
// the reading is.
type fakeKubelet struct {
	mu sync.Mutex
	// stopAfter is how long each probe takes to report a terminal status once deleted, keyed by Pod name
	// suffix ("honor" / "ignore"), with the code it ends on.
	stopAfter map[string]time.Duration
	exitCode  map[string]int32
	deletedAt map[string]time.Time
	// defaultGrace is what this cluster's apiserver defaults onto a Pod that names none.
	defaultGrace int64
	now          func() time.Time
}

func newFakeKubelet(now func() time.Time, honorStop, ignoreStop time.Duration,
	honorExit, ignoreExit int32) *fakeKubelet {
	return &fakeKubelet{
		stopAfter:    map[string]time.Duration{"honor": honorStop, "ignore": ignoreStop},
		exitCode:     map[string]int32{"honor": honorExit, "ignore": ignoreExit},
		deletedAt:    map[string]time.Time{},
		defaultGrace: terminationGraceSec,
		now:          now,
	}
}

func (k *fakeKubelet) which(name string) string {
	if strings.HasSuffix(name, "-honor") {
		return "honor"
	}
	return "ignore"
}

// interceptors wires the double into a fake client on the three verbs it has to be present for.
func (k *fakeKubelet) interceptors() interceptor.Funcs {
	return interceptor.Funcs{
		Create: func(ctx context.Context, c client.WithWatch, obj client.Object,
			opts ...client.CreateOption) error {
			if p, ok := obj.(*corev1.Pod); ok && p.Spec.TerminationGracePeriodSeconds == nil {
				// The defaulting the canary reads back out of the Create response, which is the one place the
				// cluster's own grace period becomes visible to it.
				g := k.defaultGrace
				p.Spec.TerminationGracePeriodSeconds = &g
			}
			return c.Create(ctx, obj, opts...)
		},
		Delete: func(ctx context.Context, c client.WithWatch, obj client.Object,
			opts ...client.DeleteOption) error {
			if p, ok := obj.(*corev1.Pod); ok {
				k.mu.Lock()
				if _, seen := k.deletedAt[p.Name]; !seen {
					k.deletedAt[p.Name] = k.now()
				}
				k.mu.Unlock()
			}
			return c.Delete(ctx, obj, opts...)
		},
		Get: func(ctx context.Context, c client.WithWatch, key client.ObjectKey, obj client.Object,
			opts ...client.GetOption) error {
			if err := c.Get(ctx, key, obj, opts...); err != nil {
				return err
			}
			p, ok := obj.(*corev1.Pod)
			if !ok {
				return nil
			}
			k.mu.Lock()
			defer k.mu.Unlock()
			t0, deleted := k.deletedAt[p.Name]
			w := k.which(p.Name)
			switch {
			case deleted && !k.now().Before(t0.Add(k.stopAfter[w])):
				p.Status.Phase = corev1.PodFailed
				p.Status.ContainerStatuses = []corev1.ContainerStatus{{
					Name: "sleeper",
					State: corev1.ContainerState{Terminated: &corev1.ContainerStateTerminated{
						ExitCode: k.exitCode[w], Reason: "Error",
					}},
				}}
			default:
				p.Status.Phase = corev1.PodRunning
				p.Status.ContainerStatuses = []corev1.ContainerStatus{{
					Name:  "sleeper",
					State: corev1.ContainerState{Running: &corev1.ContainerStateRunning{}},
				}}
			}
			return nil
		},
	}
}

// canaryCluster builds a fake worker plus the double, and returns the client and the clock the canary runs on.
func canaryCluster(t *testing.T, k *fakeKubelet, objs ...client.Object) client.WithWatch {
	t.Helper()
	// The worker starts with NO recorded qualification: this is the cluster before anybody has canaried it,
	// which is the state the mode exists to change.
	all := []client.Object{node(nil, map[string]string{canaryAnnotationKey: ""})}
	all = append(all, objs...)
	return fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(all...).
		WithInterceptorFuncs(k.interceptors()).Build()
}

// readCanary pulls the qualification back off the node, the way a later run's qualify would.
func readCanary(t *testing.T, c client.Client) canaryQualification {
	t.Helper()
	var n corev1.Node
	if err := c.Get(context.Background(), client.ObjectKey{Name: "platform-worker"}, &n); err != nil {
		t.Fatalf("read the worker back: %v", err)
	}
	raw := n.Annotations[canaryAnnotationKey]
	if raw == "" {
		t.Fatal("the canary recorded nothing on the worker, so nothing it observed survives the process that " +
			"observed it")
	}
	q, err := decodeCanary(raw)
	if err != nil {
		t.Fatalf("the canary wrote a document it cannot read back: %v (%s)", err, raw)
	}
	return q
}

// The whole mode, end to end, against a cluster that behaves the way the arms need it to: the honouring probe
// stops in under a second, the ignoring one spends the grace period and is killed at the end of it.
//
// What this establishes is that the reading reaches the cluster and comes back: a qualification the next run
// can consult is on the Node, the probes are gone, and the worker is free again. Everything the canary
// concluded is derived from what the double reported, so the double is the only thing pretending here.
//
// Mutation that turns this red: skip stampCanary (the qualification never reaches the node and no run could
// consult it); or release the worker before the stamp (the stamp then fails ownership verification).
func TestTheCanaryRecordsAPassingQualificationOnTheWorkerItsProbes(t *testing.T) {
	now, sleep := fakeClock(time.Unix(0, 0))
	k := newFakeKubelet(now, 700*time.Millisecond, 30*time.Second+400*time.Millisecond,
		honorExitCode, killExitCode)
	c := canaryCluster(t, k)
	var out bytes.Buffer

	if err := terminationCanary(context.Background(), c, "platform-worker", now, sleep, &out); err != nil {
		t.Fatalf("a cluster that stops a workload when asked did not qualify: %v\n%s", err, out.String())
	}

	q := readCanary(t, c)
	if len(q.Failures) != 0 {
		t.Fatalf("the recorded qualification names failures: %v", q.Failures)
	}
	if !q.Honor.Terminated || q.Honor.ExitCode != honorExitCode {
		t.Fatalf("the honouring probe's own reading must be recorded, got %+v", q.Honor)
	}
	if !q.Ignore.Terminated || q.Ignore.ExitCode != killExitCode {
		t.Fatalf("the ignoring probe's own reading must be recorded, got %+v", q.Ignore)
	}
	// The separation is the product. Anything that collapsed it would still have produced two readings.
	if q.Ignore.StoppedAfterMs-q.Honor.StoppedAfterMs < canarySurvivesAtLeast.Milliseconds() {
		t.Fatalf("the recorded contrast is %dms against %dms, which is not a separation the arms could be "+
			"built on", q.Honor.StoppedAfterMs, q.Ignore.StoppedAfterMs)
	}
	if q.Key.GraceSec != terminationGraceSec || q.Key.NodeUID != "uid-node" ||
		q.Key.KubeletVersion != testKubeletVersion || q.Key.ContainerRuntime != testContainerRuntime {
		t.Fatalf("the key must record the combination the reading was taken on, got %+v", q.Key)
	}

	// A later run must be able to stand on what was just written, through the real consult rather than by
	// inspection: this is the join between the two halves of the feature, and it is where a key the canary
	// writes but the run cannot match would show up.
	var worker corev1.Node
	if err := c.Get(context.Background(), client.ObjectKey{Name: "platform-worker"}, &worker); err != nil {
		t.Fatalf("read the worker: %v", err)
	}
	ref, err := checkTerminationCanary(&worker, harnessTerminationContract())
	if err != nil {
		t.Fatalf("the qualification this canary just recorded does not satisfy the gate that consults it: %v", err)
	}
	if ref.CanaryID != q.CanaryID {
		t.Fatalf("the reference names canary %q, the node carries %q", ref.CanaryID, q.CanaryID)
	}

	// Nothing of the canary's is left running, and the worker is back.
	var pods corev1.PodList
	if err := c.List(context.Background(), &pods); err != nil {
		t.Fatalf("list pods: %v", err)
	}
	if len(pods.Items) != 0 {
		t.Fatalf("the canary left %d probe Pod(s) behind: its finalizer is what keeps them readable, and "+
			"nothing else removes it", len(pods.Items))
	}
	obs := observe(&worker)
	if obs.HasLabel || len(obs.Taints) > 0 || obs.JournalRaw != "" {
		t.Fatalf("the canary did not give the worker back: %+v", obs)
	}
}

// The failure this whole file exists to catch, driven through the real mode: a cluster that stops every
// container the instant it is asked. Both probes end promptly with plausible codes, and the honouring half is
// impeccable — which is exactly why the verdict must not be taken from it alone.
//
// The recorded document is the point. A canary that printed its refusal and wrote nothing would leave a
// worker carrying whatever qualification it had before, so the next run would consult a document this canary
// had just falsified.
//
// Mutation that turns this red: return before stampCanary when the judgement failed, which is the natural
// "only record successes" reading.
func TestAFailingCanaryOverwritesTheQualificationItJustFalsified(t *testing.T) {
	now, sleep := fakeClock(time.Unix(0, 0))
	// The killing runtime: both stop at once, and the honouring one even carries 143 — which an untrapped
	// SIGTERM also produces.
	k := newFakeKubelet(now, 300*time.Millisecond, 400*time.Millisecond, honorExitCode, honorExitCode)
	c := canaryCluster(t, k)
	// A qualification from before the cluster broke, which this canary must replace rather than leave standing.
	var before corev1.Node
	if err := c.Get(context.Background(), client.ObjectKey{Name: "platform-worker"}, &before); err != nil {
		t.Fatalf("read the worker: %v", err)
	}
	before.Annotations[canaryAnnotationKey] = qualifiedCanaryAnnotation()
	if err := c.Update(context.Background(), &before); err != nil {
		t.Fatalf("seed the previous qualification: %v", err)
	}

	var out bytes.Buffer
	err := terminationCanary(context.Background(), c, "platform-worker", now, sleep, &out)
	if err == nil {
		t.Fatalf("a cluster that kills everything immediately qualified:\n%s", out.String())
	}

	q := readCanary(t, c)
	if len(q.Failures) == 0 {
		t.Fatal("the previous, passing qualification is still on the node: runs would keep consulting a " +
			"document this canary has just shown to be false")
	}
	if !strings.Contains(strings.Join(q.Failures, "\n"), "ignoring probe") {
		t.Fatalf("the recorded failure must name the half that broke, got %v", q.Failures)
	}

	// And the gate refuses on it, which is the behaviour the record exists for.
	var after corev1.Node
	if err := c.Get(context.Background(), client.ObjectKey{Name: "platform-worker"}, &after); err != nil {
		t.Fatalf("read the worker: %v", err)
	}
	if _, cerr := checkTerminationCanary(&after, harnessTerminationContract()); cerr == nil {
		t.Fatal("a worker carrying a failed canary passed the consult")
	}
	if !strings.Contains(out.String(), "NOT QUALIFIED") {
		t.Fatalf("the operator must be told on their terminal too, got:\n%s", out.String())
	}
}

// The exit code is read off a Pod that has already been deleted, and it is only readable because the canary
// hangs its own finalizer on the probe: without one the object is removed as soon as its containers stop, and
// the code the whole reading turns on goes with it.
//
// This test drives that directly — the double removes the terminal status the moment the object would have
// been collected — so it fails for the reason the finalizer exists rather than by inspecting a field.
//
// Mutation that turns this red: drop the Finalizers line from canaryPod. The fake client then removes each
// probe on Delete exactly as a real apiserver does once the kubelet is finished, every subsequent read is a
// NotFound, and the canary records two probes it never saw stop.
func TestTheCanaryCanStillReadAProbeThatHasBeenDeleted(t *testing.T) {
	now, sleep := fakeClock(time.Unix(0, 0))
	k := newFakeKubelet(now, 500*time.Millisecond, 30*time.Second, honorExitCode, killExitCode)
	c := canaryCluster(t, k)

	if err := terminationCanary(context.Background(), c, "platform-worker", now, sleep, &bytes.Buffer{}); err != nil {
		t.Fatalf("canary: %v", err)
	}
	q := readCanary(t, c)
	for _, p := range []canaryProbe{q.Honor, q.Ignore} {
		if !p.Terminated {
			t.Fatalf("probe %s was deleted and its ending was never read (%s); the exit code exists only "+
				"between the container stopping and the object being collected", p.Pod, p.Unobserved)
		}
	}
}

// The Pod the canary probes has to be the one a run's Pod would be, on the machine being qualified.
//
// spec.nodeName rather than a selector, because what is under test is THIS node's kubelet and runtime and a
// probe that landed elsewhere would qualify a machine nobody asked about. And no explicit grace period,
// because the controller that renders a run's Job sets none either: pinning one here would measure a
// configuration no run ever uses and would hide the cluster default the whole horizon is derived from.
//
// Mutation that turns this red: set TerminationGracePeriodSeconds on the probe (the assertion below fails, and
// so does the point of reading it back from the Create response), or swap nodeName for a NodeSelector.
func TestTheProbePodIsTheWorkloadAsTheRunWouldSubmitIt(t *testing.T) {
	c := harnessTerminationContract()
	honor, _ := canaryProbeSpecs("abcd1234-5678", c)
	p := canaryPod("abcd1234-5678", "platform-worker", "canary-abcd1234", c, honor)

	if p.Spec.NodeName != "platform-worker" {
		t.Fatalf("the probe does not name the node it is qualifying (nodeName %q): a probe that ran elsewhere "+
			"would report another machine's runtime", p.Spec.NodeName)
	}
	if p.Spec.TerminationGracePeriodSeconds != nil {
		t.Fatalf("the probe pins a %d second grace period; a run's Pods take the apiserver's default because "+
			"nothing in this harness sets one, and pinning it here measures a configuration no run uses",
			*p.Spec.TerminationGracePeriodSeconds)
	}
	if p.Spec.RestartPolicy != corev1.RestartPolicyNever {
		t.Fatalf("restart policy %q: a probe that restarts after being killed has no terminal status to read",
			p.Spec.RestartPolicy)
	}
	if len(p.Finalizers) != 1 || p.Finalizers[0] != canaryFinalizer {
		t.Fatalf("the probe carries finalizers %v; without the canary's own the exit code is collected along "+
			"with the object", p.Finalizers)
	}
	if p.Spec.Containers[0].Image != c.Image {
		t.Fatalf("the probe runs image %q, not the pinned sleeper %q", p.Spec.Containers[0].Image, c.Image)
	}
	if strings.Join(p.Spec.Containers[0].Command, " ") != strings.Join(c.HonorCommand, " ") {
		t.Fatalf("the probe runs %v, not the honouring command the arm submits (%v)",
			p.Spec.Containers[0].Command, c.HonorCommand)
	}
	// The node is tainted by the canary's own acquisition moments before the probe is created, and the
	// toleration is the same shape internal/queuelab's ResourceFlavor gives the arm's Pods.
	if len(p.Spec.Tolerations) != 1 || p.Spec.Tolerations[0].Key != workerTaintKey ||
		p.Spec.Tolerations[0].Value != "canary-abcd1234" {
		t.Fatalf("the probe does not tolerate the ownership taint this canary installed: %+v", p.Spec.Tolerations)
	}
}

// A canary cannot run on a worker somebody else is holding, and the reason is not tidiness: two probe Pods
// appearing on a node in the middle of a measured run are exactly the foreign contamination the capacity gate
// refuses runs over, and the grace period being exercised by a stranger is the one thing that run is
// measuring.
//
// Mutation that turns this red: create the probes without acquiring the worker first.
func TestTheCanaryRefusesAWorkerSomebodyElseIsHolding(t *testing.T) {
	held := testJournal()
	raw, err := encodeJournal(held)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	now, sleep := fakeClock(time.Unix(0, 0))
	k := newFakeKubelet(now, time.Second, 30*time.Second, honorExitCode, killExitCode)
	c := fake.NewClientBuilder().WithScheme(testScheme(t)).
		WithObjects(node(map[string]string{workerLabelKey: held.Installed.LabelValue},
			map[string]string{canaryAnnotationKey: "", journalKey: raw}, ourTaint())).
		WithInterceptorFuncs(k.interceptors()).Build()

	var out bytes.Buffer
	err = terminationCanary(context.Background(), c, "platform-worker", now, sleep, &out)
	if err == nil {
		t.Fatal("the canary ran on a node another transaction holds: its probes would be foreign Pods on " +
			"somebody else's measured run")
	}
	var r *refusal
	if !asRefusal(err, &r) || r.Reason != reasonForeignOwner {
		t.Fatalf("the refusal must be the ownership transaction's own, classifiable by reason, got %v", err)
	}
	var pods corev1.PodList
	if lerr := c.List(context.Background(), &pods); lerr != nil {
		t.Fatalf("list: %v", lerr)
	}
	if len(pods.Items) != 0 {
		t.Fatalf("the canary created %d Pod(s) on a worker it does not hold", len(pods.Items))
	}
}

// Every exit path has to release the probes, and the refusal paths most of all: the finalizer is the one thing
// this mode leaves behind that does not clean itself up, and a probe stuck under it holds a name the next
// canary attempt would collide with.
//
// This drives the path where the probes never start at all — an image that will not pull, in the double's
// terms a Pod that never reports Running — so the failure happens with two live Pods outstanding.
//
// Mutation that turns this red: move releaseProbes out of a defer and onto the success path only.
func TestTheCanaryClearsItsProbesEvenWhenItRefuses(t *testing.T) {
	now, sleep := fakeClock(time.Unix(0, 0))
	k := newFakeKubelet(now, time.Second, 30*time.Second, honorExitCode, killExitCode)
	// Nothing ever runs: the Get double is replaced by one that leaves every probe Pending with a waiting
	// container, which is what an ImagePullBackOff looks like from here.
	stuck := fake.NewClientBuilder().WithScheme(testScheme(t)).
		WithObjects(node(nil, map[string]string{canaryAnnotationKey: ""})).
		WithInterceptorFuncs(interceptor.Funcs{
			Create: k.interceptors().Create,
			Delete: k.interceptors().Delete,
			Get: func(ctx context.Context, cl client.WithWatch, key client.ObjectKey, obj client.Object,
				opts ...client.GetOption) error {
				if err := cl.Get(ctx, key, obj, opts...); err != nil {
					return err
				}
				if p, ok := obj.(*corev1.Pod); ok {
					p.Status.Phase = corev1.PodPending
					p.Status.ContainerStatuses = []corev1.ContainerStatus{{
						Name: "sleeper",
						State: corev1.ContainerState{Waiting: &corev1.ContainerStateWaiting{
							Reason: "ImagePullBackOff", Message: "manifest unknown",
						}},
					}}
				}
				return nil
			},
		}).Build()

	var out bytes.Buffer
	err := terminationCanary(context.Background(), stuck, "platform-worker", now, sleep, &out)
	if err == nil {
		t.Fatal("probes that never started produced a qualification")
	}
	if !strings.Contains(err.Error(), "ImagePullBackOff") {
		t.Fatalf("the refusal must carry what the cluster said was wrong, or the operator is told only that "+
			"three minutes passed: %v", err)
	}

	var pods corev1.PodList
	if lerr := stuck.List(context.Background(), &pods); lerr != nil {
		t.Fatalf("list: %v", lerr)
	}
	if len(pods.Items) != 0 {
		t.Fatalf("%d probe Pod(s) survived a refused canary, held by a finalizer only this tool removes: the "+
			"next attempt collides with them and an operator has to patch them by hand", len(pods.Items))
	}
	// And the worker goes back, or a failed canary costs the lab a node.
	var worker corev1.Node
	if gerr := stuck.Get(context.Background(), client.ObjectKey{Name: "platform-worker"}, &worker); gerr != nil {
		t.Fatalf("read the worker: %v", gerr)
	}
	if obs := observe(&worker); obs.HasLabel || len(obs.Taints) > 0 || obs.JournalRaw != "" {
		t.Fatalf("a refused canary kept the worker: %+v", obs)
	}
}

// A cluster that defaults something other than 30 seconds is not running this protocol, and the canary is
// where that becomes visible: nothing in this harness sets a grace period, so the default is what every Pod a
// run creates takes, and spine.go's horizon is arithmetic over it being 30.
//
// Mutation that turns this red: read the grace period out of the terminationGraceSec constant instead of out
// of the Create response. The probe then records 30 whatever the cluster did, and the reading that would have
// caught it agrees with itself.
func TestTheCanaryReadsTheGracePeriodTheClusterActuallyDefaulted(t *testing.T) {
	now, sleep := fakeClock(time.Unix(0, 0))
	k := newFakeKubelet(now, 700*time.Millisecond, 60*time.Second, honorExitCode, killExitCode)
	k.defaultGrace = 60
	c := canaryCluster(t, k)

	var out bytes.Buffer
	err := terminationCanary(context.Background(), c, "platform-worker", now, sleep, &out)
	if err == nil {
		t.Fatalf("a cluster defaulting a 60 second grace period qualified against a protocol timed on 30:\n%s",
			out.String())
	}
	q := readCanary(t, c)
	if q.Honor.GraceSec != 60 || q.Key.GraceSec != 60 {
		t.Fatalf("the canary recorded a %ds grace period on the probe and %ds in its key; both must be what "+
			"the cluster stored, not what this build wanted", q.Honor.GraceSec, q.Key.GraceSec)
	}
	if !strings.Contains(strings.Join(q.Failures, "\n"), "grace period") {
		t.Fatalf("the failure must name the grace period, got %v", q.Failures)
	}
}

// A probe still running when the budget expires is recorded as unobserved rather than as anything else, and
// the canary refuses on it. The alternative — treating a probe nobody watched to the end as fine — is the
// substitution this entire package exists to refuse.
//
// Mutation that turns this red: leave the budget-expiry branch of awaitProbesStopped without setting
// Unobserved. Terminated stays false and StoppedAfterMs stays 0, and 0ms passes the promptness threshold.
func TestAProbeThatOutlastsTheBudgetIsRecordedAsUnobserved(t *testing.T) {
	now, sleep := fakeClock(time.Unix(0, 0))
	// Neither probe ever reports a terminal status inside the budget the canary allows.
	k := newFakeKubelet(now, time.Hour, time.Hour, honorExitCode, killExitCode)
	c := canaryCluster(t, k)

	err := terminationCanary(context.Background(), c, "platform-worker", now, sleep, &bytes.Buffer{})
	if err == nil {
		t.Fatal("a canary that watched neither probe to its end qualified the worker")
	}
	q := readCanary(t, c)
	for _, p := range []canaryProbe{q.Honor, q.Ignore} {
		if p.Terminated {
			t.Fatalf("probe %s was recorded as terminated by a double that never terminated it", p.Pod)
		}
		if p.Unobserved == "" {
			t.Fatalf("probe %s carries no reason for having been unobserved, which is indistinguishable from "+
				"a probe that was never run at all", p.Pod)
		}
	}
}

// "Could not be read" and "would not stop" are different facts about a cluster and send an operator to
// different places, so a probe whose reads never succeed must not be recorded as one that outlasted its
// budget. The refusal is the same either way; the diagnosis is not.
//
// The blip half is the other side of it: a single failed read against a real apiserver must not throw away a
// probe that stopped perfectly well a moment later, which is what returning on the first error would do.
//
// Mutation that turns this red: set Unobserved on the first read error instead of keeping it (the blip half
// fails), or report the still-running message regardless of what the last read did (the unreadable half).
func TestAProbeThatCouldNotBeReadIsNotAProbeThatWouldNotStop(t *testing.T) {
	// Every read of a Pod fails from the moment the probes are deleted onward.
	now, sleep := fakeClock(time.Unix(0, 0))
	k := newFakeKubelet(now, 500*time.Millisecond, 30*time.Second, honorExitCode, killExitCode)
	base := k.interceptors()
	var deleted bool
	unreadable := fake.NewClientBuilder().WithScheme(testScheme(t)).
		WithObjects(node(nil, map[string]string{canaryAnnotationKey: ""})).
		WithInterceptorFuncs(interceptor.Funcs{
			Create: base.Create,
			Delete: func(ctx context.Context, c client.WithWatch, obj client.Object,
				opts ...client.DeleteOption) error {
				if _, ok := obj.(*corev1.Pod); ok {
					deleted = true
				}
				return base.Delete(ctx, c, obj, opts...)
			},
			Get: func(ctx context.Context, c client.WithWatch, key client.ObjectKey, obj client.Object,
				opts ...client.GetOption) error {
				if _, ok := obj.(*corev1.Pod); ok && deleted {
					return errors.New("etcdserver: request timed out")
				}
				return base.Get(ctx, c, key, obj, opts...)
			},
		}).Build()

	if err := terminationCanary(context.Background(), unreadable, "platform-worker", now, sleep,
		&bytes.Buffer{}); err == nil {
		t.Fatal("a canary that could not read either probe qualified the worker")
	}
	q := readCanary(t, unreadable)
	for _, p := range []canaryProbe{q.Honor, q.Ignore} {
		if !strings.Contains(p.Unobserved, "request timed out") {
			t.Fatalf("probe %s records %q; a probe nobody could read must not be reported as one that would "+
				"not stop", p.Pod, p.Unobserved)
		}
	}

	// And one blip in the middle of an otherwise healthy reading changes nothing.
	now2, sleep2 := fakeClock(time.Unix(0, 0))
	k2 := newFakeKubelet(now2, 500*time.Millisecond, 30*time.Second, honorExitCode, killExitCode)
	base2 := k2.interceptors()
	var reads int
	blippy := fake.NewClientBuilder().WithScheme(testScheme(t)).
		WithObjects(node(nil, map[string]string{canaryAnnotationKey: ""})).
		WithInterceptorFuncs(interceptor.Funcs{
			Create: base2.Create,
			Delete: base2.Delete,
			Get: func(ctx context.Context, c client.WithWatch, key client.ObjectKey, obj client.Object,
				opts ...client.GetOption) error {
				if _, ok := obj.(*corev1.Pod); ok {
					reads++
					if reads == 3 {
						return errors.New("connection reset by peer")
					}
				}
				return base2.Get(ctx, c, key, obj, opts...)
			},
		}).Build()

	if err := terminationCanary(context.Background(), blippy, "platform-worker", now2, sleep2,
		&bytes.Buffer{}); err != nil {
		t.Fatalf("one failed read cost a healthy cluster its qualification: %v", err)
	}
}

// The two probes must be distinguishable by name, because everything downstream — the double above, an
// operator reading `kubectl get pods`, and the leaked-probe recovery hint — keys off the suffix.
//
// Mutation that turns this red: give both probes the same name. One Create then overwrites the other and the
// contrast is measured between a Pod and itself.
func TestTheTwoProbesAreNamedApart(t *testing.T) {
	honor, ignore := canaryProbeSpecs("0123456789abcdef", harnessTerminationContract())
	if honor.name == ignore.name {
		t.Fatal("both probes carry the same name, so one Create would overwrite the other and the contrast " +
			"would be a Pod against itself")
	}
	for _, n := range []string{honor.name, ignore.name} {
		if len(n) > 63 || strings.ToLower(n) != n {
			t.Fatalf("probe name %q is not a DNS label, so the Create is refused before anything is measured", n)
		}
	}
	if !strings.HasSuffix(honor.name, "-honor") || !strings.HasSuffix(ignore.name, "-ignore") {
		t.Fatalf("the probes must say which contract they carry in their names: %q and %q", honor.name, ignore.name)
	}
}

// releaseProbes must survive a probe that is already gone. It runs from a defer on every path, including the
// ones where the probes were never created, and a cleanup that errored on NotFound would print an alarming
// recovery instruction for an object nobody has to recover.
//
// Mutation that turns this red: return the Get error from releaseProbe without testing for NotFound.
func TestReleasingAProbeThatIsAlreadyGoneIsNotAFailure(t *testing.T) {
	c := fake.NewClientBuilder().WithScheme(testScheme(t)).Build()
	var out bytes.Buffer
	releaseProbes(context.Background(), c, []*corev1.Pod{{
		ObjectMeta: metav1.ObjectMeta{Namespace: canaryNamespace, Name: "tc-none-honor"},
	}}, &out)
	if out.Len() != 0 {
		t.Fatalf("cleanup of an absent probe reported a problem: %s", out.String())
	}
}
