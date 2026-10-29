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
	"slices"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/utils/ptr"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	kueuev1beta1 "sigs.k8s.io/kueue/apis/kueue/v1beta1"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/gpufault"
)

var gfT0 = time.Date(2026, 10, 27, 1, 0, 0, 0, time.UTC)

func gfScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	s := runtime.NewScheme()
	for _, add := range []func(*runtime.Scheme) error{clientgoscheme.AddToScheme, platformv1.AddToScheme, kueuev1beta1.AddToScheme} {
		if err := add(s); err != nil {
			t.Fatal(err)
		}
	}
	return s
}

func faultAssessment(xid, dbe int64) gpufault.Assessment {
	r := map[string]*gpufault.GPUReading{"GPU-a": {UUID: "GPU-a", GPU: "0", Values: map[string]float64{
		gpufault.FieldXid: float64(xid), gpufault.FieldECCDoubleBit: float64(dbe),
	}}}
	a, err := gpufault.Assess(r)
	if err != nil {
		panic(err)
	}
	return a
}

func TestDecideGPUFault(t *testing.T) {
	const stale = 5 * time.Second
	fault := faultAssessment(79, 0)
	fp := fault.Fingerprint()
	clean := faultAssessment(0, 0)
	missing := gpufault.Assessment{Cards: 1, Missing: []string{"GPU-a/" + gpufault.FieldECCDoubleBit}}
	obs := func(a gpufault.Assessment, age time.Duration) GPUFaultObservation {
		o := GPUFaultObservation{LastSuccess: gfT0.Add(-age), Assessment: a}
		if a.Fingerprint() != "" {
			o.FaultSince = gfT0.Add(-age)
		}
		return o
	}
	cases := []struct {
		name                 string
		o                    GPUFaultObservation
		hasObs               bool
		latched, ack         string
		signal, healthy      metav1.ConditionStatus
		healthyReason, latch string
		newLatch             bool
		taint                int
	}{
		{"no observation", GPUFaultObservation{}, false, "", "", metav1.ConditionFalse, metav1.ConditionUnknown, gpuHealthyReasonSignalNotFresh, "", false, 0},
		{"stale, nothing latched: no action", obs(fault, 6*time.Second), true, "", "", metav1.ConditionFalse, metav1.ConditionUnknown, gpuHealthyReasonSignalNotFresh, "", false, 0},
		{"stale, latched: the fault stays", obs(clean, 6*time.Second), true, fp, "", metav1.ConditionFalse, metav1.ConditionFalse, gpuHealthyReasonLatched, fp, false, +1},
		{"fresh fault latches", obs(fault, time.Second), true, "", "", metav1.ConditionTrue, metav1.ConditionFalse, gpufault.ReasonXid, fp, true, +1},
		{"fresh fault already latched", obs(fault, 0), true, fp, "", metav1.ConditionTrue, metav1.ConditionFalse, gpufault.ReasonXid, fp, false, +1},
		{"fresh clean clears", obs(clean, 0), true, fp, "", metav1.ConditionTrue, metav1.ConditionTrue, gpuHealthyReasonNoFault, "", false, -1},
		{"acknowledged fault clears", obs(fault, 0), true, fp, fp, metav1.ConditionTrue, metav1.ConditionTrue, gpuHealthyReasonAcknowledged, "", false, -1},
		{"a different fault is not covered by the acknowledgement", obs(faultAssessment(79, 1), 0), true, fp, fp, metav1.ConditionTrue, metav1.ConditionFalse, gpufault.ReasonMultipleFault, faultAssessment(79, 1).Fingerprint(), true, +1},
		{"missing field, nothing latched: unknown, no action", obs(missing, 0), true, "", "", metav1.ConditionTrue, metav1.ConditionUnknown, gpuHealthyReasonFieldMissing, "", false, 0},
		{"missing field, latched: the fault stays", obs(missing, 0), true, fp, "", metav1.ConditionTrue, metav1.ConditionFalse, gpuHealthyReasonLatched, fp, false, +1},
		// The registration's escape path: an operator acknowledging the latched fingerprint clears the node even
		// after an application Xid has replaced the fatal one, which only zero fields could clear until 2026-10-29
		// (codex audit, 2026-10-28). Mutation that turns it red: delete the acknowledged-latch case.
		{"an application Xid after a latched fault, acknowledged: clears", obs(faultAssessment(13, 0), 0), true, fp, fp, metav1.ConditionTrue, metav1.ConditionTrue, gpuHealthyReasonAcknowledged, "", false, -1},
		{"an application Xid after a latched fault, not acknowledged: the fault stays", obs(faultAssessment(13, 0), 0), true, fp, "", metav1.ConditionTrue, metav1.ConditionFalse, gpuHealthyReasonLatched, fp, false, +1},
		{"an application Xid, another fingerprint acknowledged: the fault stays", obs(faultAssessment(13, 0), 0), true, fp, faultAssessment(79, 1).Fingerprint(), metav1.ConditionTrue, metav1.ConditionFalse, gpuHealthyReasonLatched, fp, false, +1},
		{"stale, latched and acknowledged: no action", obs(clean, 6*time.Second), true, fp, fp, metav1.ConditionFalse, metav1.ConditionFalse, gpuHealthyReasonLatched, fp, false, +1},
		{"missing field, latched and acknowledged: the fault stays", obs(missing, 0), true, fp, fp, metav1.ConditionTrue, metav1.ConditionFalse, gpuHealthyReasonLatched, fp, false, +1},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			d := decideGPUFault(c.o, c.hasObs, gfT0, stale, c.latched, c.ack, nil)
			if d.signal.Status != c.signal || d.healthy.Status != c.healthy || d.healthy.Reason != c.healthyReason ||
				d.latch != c.latch || d.newLatch != c.newLatch || d.taint != c.taint {
				t.Fatalf("got signal=%s healthy=%s/%s latch=%q new=%v taint=%d",
					d.signal.Status, d.healthy.Status, d.healthy.Reason, d.latch, d.newLatch, d.taint)
			}
			if c.newLatch && !d.observedAt.Equal(c.o.FaultSince) {
				t.Fatalf("observedAt %s, want the scrape that first carried the fault, %s", d.observedAt, c.o.FaultSince)
			}
		})
	}
}

// A failed scrape newer than the last success keeps the signal fresh until StaleAfter, and then names the failure.
func TestDecideGPUFaultNamesTheFailureOnceStale(t *testing.T) {
	o := GPUFaultObservation{LastSuccess: gfT0.Add(-6 * time.Second), Assessment: faultAssessment(0, 0),
		LastFailure: gfT0.Add(-time.Second), FailureReason: signalReasonScrapeFailed, FailureDetail: "connection refused"}
	d := decideGPUFault(o, true, gfT0, 5*time.Second, "", "", nil)
	if d.signal.Reason != signalReasonScrapeFailed || d.healthy.Status != metav1.ConditionUnknown {
		t.Fatalf("signal %s/%s healthy %s", d.signal.Status, d.signal.Reason, d.healthy.Status)
	}
	o.LastSuccess = gfT0.Add(-2 * time.Second)
	if d := decideGPUFault(o, true, gfT0, 5*time.Second, "", "", nil); d.signal.Status != metav1.ConditionTrue {
		t.Fatalf("one failure inside StaleAfter made the signal %s", d.signal.Status)
	}
}

// gfRig is one Ready node with a NodeHealth, a clock and a store, ready to reconcile.
type gfRig struct {
	t     *testing.T
	c     client.Client
	r     *NodeHealthReconciler
	store *GPUFaultStore
	now   time.Time
}

func newGFRig(t *testing.T, evict bool, objs ...client.Object) *gfRig {
	t.Helper()
	node := &corev1.Node{Name: "gpu-1", Status: corev1.NodeStatus{
		Conditions: []corev1.NodeCondition{{Type: corev1.NodeReady, Status: corev1.ConditionTrue}}}}
	nh := &platformv1.NodeHealth{Name: "nh-1", Finalizers: []string{nodeHealthFinalizer},
		Spec: platformv1.NodeHealthSpec{NodeName: "gpu-1"}}
	c := fake.NewClientBuilder().WithScheme(gfScheme(t)).
		WithIndex(&platformv1.NodeHealth{}, NodeNameIndex, indexNodeHealthByNodeName).
		WithIndex(&corev1.Pod{}, "spec.nodeName", func(o client.Object) []string { return []string{o.(*corev1.Pod).Spec.NodeName} }).
		WithStatusSubresource(&platformv1.NodeHealth{}, &kueuev1beta1.Workload{}).
		WithObjects(append([]client.Object{node, nh}, objs...)...).Build()
	g := &gfRig{t: t, c: c, store: NewGPUFaultStore(), now: gfT0}
	g.r = &NodeHealthReconciler{Client: c, Scheme: c.Scheme(), GPUFault: &GPUFaultConfig{
		Store: g.store, StaleAfter: 5 * time.Second, EvictWorkloads: evict, APIReader: c,
		Now: func() time.Time { return g.now },
	}}
	return g
}

func (g *gfRig) scrape(a gpufault.Assessment) {
	g.store.recordSuccess("gpu-1", g.now, a)
}

func (g *gfRig) reconcile() {
	g.t.Helper()
	if _, err := g.r.Reconcile(context.Background(), ctrl.Request{Name: "nh-1"}); err != nil {
		g.t.Fatalf("reconcile: %v", err)
	}
}

func (g *gfRig) state() (*platformv1.NodeHealth, *corev1.Node) {
	g.t.Helper()
	var nh platformv1.NodeHealth
	var node corev1.Node
	if err := g.c.Get(context.Background(), types.NamespacedName{Name: "nh-1"}, &nh); err != nil {
		g.t.Fatal(err)
	}
	if err := g.c.Get(context.Background(), types.NamespacedName{Name: "gpu-1"}, &node); err != nil {
		g.t.Fatal(err)
	}
	return &nh, &node
}

func TestGPUFaultLatchesTaintsAndStampsEachHop(t *testing.T) {
	g := newGFRig(t, false)
	g.scrape(faultAssessment(79, 0))
	g.now = gfT0.Add(30 * time.Millisecond)
	g.reconcile()
	nh, node := g.state()
	if !slices.ContainsFunc(node.Spec.Taints, isGPUFaultTaint) {
		t.Fatalf("no gpu-fault taint: %v", node.Spec.Taints)
	}
	if nh.Status.Phase != phaseQuarantine || nh.Status.FaultSignal == nil || nh.Status.FaultSignal.Source != faultSourceDCGM {
		t.Fatalf("phase %s fault %+v", nh.Status.Phase, nh.Status.FaultSignal)
	}
	h := meta.FindStatusCondition(nh.Status.Conditions, conditionGPUHealthy)
	if h == nil || h.Status != metav1.ConditionFalse || h.Reason != gpufault.ReasonXid {
		t.Fatalf("GPUHealthy %+v", h)
	}
	// The observation time is the scrape's, not the reconcile's, and the taint time follows it.
	if got := nh.Annotations[annGPUFaultObservedAt]; got != gfT0.Format(time.RFC3339Nano) {
		t.Fatalf("observed-at %q", got)
	}
	if got := nh.Annotations[annGPUFaultTaintedAt]; got != g.now.Format(time.RFC3339Nano) {
		t.Fatalf("tainted-at %q", got)
	}
	if nh.Annotations[annGPUFaultFingerprint] != "GPU-a/DCGM_FI_DEV_XID_ERRORS=79" {
		t.Fatalf("fingerprint %q", nh.Annotations[annGPUFaultFingerprint])
	}

	// A second reconcile with the same fault changes nothing it recorded.
	g.now = gfT0.Add(2 * time.Second)
	g.reconcile()
	nh2, _ := g.state()
	if nh2.Annotations[annGPUFaultTaintedAt] != nh.Annotations[annGPUFaultTaintedAt] || nh2.Status.LastTransitionTime.Time != nh.Status.LastTransitionTime.Time {
		t.Fatalf("a repeated reconcile moved a recorded time")
	}

	// A clean fresh scrape clears it and removes the taint, and only that taint.
	g.scrape(faultAssessment(0, 0))
	g.reconcile()
	nh, node = g.state()
	if slices.ContainsFunc(node.Spec.Taints, isGPUFaultTaint) || nh.Status.Phase != phaseReady || nh.Status.FaultSignal != nil {
		t.Fatalf("not cleared: taints %v phase %s", node.Spec.Taints, nh.Status.Phase)
	}
	if nh.Annotations[annGPUFaultFingerprint] != "" || nh.Annotations[annGPUFaultClearedAt] == "" {
		t.Fatalf("annotations after clear: %v", nh.Annotations)
	}
}

// The last-Xid field holds one Xid; an application Xid replacing a fatal one is not a repair and must not clear.
func TestGPUFaultApplicationXidAfterAFatalOneKeepsTheLatch(t *testing.T) {
	g := newGFRig(t, false)
	g.scrape(faultAssessment(79, 0))
	g.reconcile()
	g.now = g.now.Add(time.Second)
	g.scrape(faultAssessment(13, 0))
	g.reconcile()
	nh, node := g.state()
	if !slices.ContainsFunc(node.Spec.Taints, isGPUFaultTaint) || nh.Annotations[annGPUFaultFingerprint] == "" {
		t.Fatalf("Xid 13 after Xid 79 cleared the fault")
	}
	// Without a latch the same Xid 13 is no fault at all.
	g2 := newGFRig(t, false)
	g2.scrape(faultAssessment(13, 0))
	g2.reconcile()
	nh2, _ := g2.state()
	if h := meta.FindStatusCondition(nh2.Status.Conditions, conditionGPUHealthy); h == nil || h.Status != metav1.ConditionTrue {
		t.Fatalf("an application Xid alone: %+v", h)
	}
	// Zero, which a reset leaves, clears it.
	g.now = g.now.Add(time.Second)
	g.scrape(faultAssessment(0, 0))
	g.reconcile()
	if nh, _ = g.state(); nh.Annotations[annGPUFaultFingerprint] != "" {
		t.Fatalf("zero did not clear the latch")
	}
}

// A faulted card that drops out of the scrape while a healthy one stays has not recovered (codex review).
func TestGPUFaultLatchHoldsWhenTheFaultedCardDisappears(t *testing.T) {
	g := newGFRig(t, false)
	g.scrape(faultAssessment(79, 0)) // GPU-a
	g.reconcile()
	only := map[string]*gpufault.GPUReading{"GPU-b": {UUID: "GPU-b", Values: map[string]float64{
		gpufault.FieldXid: 0, gpufault.FieldECCDoubleBit: 0}}}
	a, err := gpufault.Assess(only)
	if err != nil {
		t.Fatal(err)
	}
	g.now = g.now.Add(time.Second)
	g.scrape(a)
	g.reconcile()
	nh, node := g.state()
	if !slices.ContainsFunc(node.Spec.Taints, isGPUFaultTaint) || nh.Annotations[annGPUFaultFingerprint] == "" {
		t.Fatalf("a scrape without the faulted card cleared its fault")
	}
}

// A benign change is recorded as read, so a quiet control can be told from a blind one.
func TestGPUFaultRecordsTheReadingItIgnored(t *testing.T) {
	g := newGFRig(t, false)
	r := map[string]*gpufault.GPUReading{"GPU-a": {UUID: "GPU-a", Values: map[string]float64{
		gpufault.FieldXid: 0, gpufault.FieldECCDoubleBit: 0, gpufault.FieldECCSingleBit: 1}}}
	a, err := gpufault.Assess(r)
	if err != nil {
		t.Fatal(err)
	}
	g.scrape(a)
	g.reconcile()
	nh, node := g.state()
	if len(node.Spec.Taints) != 0 || !strings.Contains(nh.Annotations[annGPUFaultReading], gpufault.FieldECCSingleBit+"=1") ||
		nh.Annotations[annGPUFaultReadingAt] != gfT0.Format(time.RFC3339Nano) {
		t.Fatalf("taints %v annotations %v", node.Spec.Taints, nh.Annotations)
	}
}

// Stale data must neither set nor clear a fault: it is its own condition.
func TestGPUFaultStaleDataTakesNoAction(t *testing.T) {
	g := newGFRig(t, false)
	g.scrape(faultAssessment(79, 0))
	g.now = gfT0.Add(10 * time.Second)
	g.reconcile()
	nh, node := g.state()
	if slices.ContainsFunc(node.Spec.Taints, isGPUFaultTaint) || nh.Status.Phase != phaseReady {
		t.Fatalf("a stale fault reading tainted the node")
	}
	s := meta.FindStatusCondition(nh.Status.Conditions, conditionGPUSignal)
	if s == nil || s.Status != metav1.ConditionFalse || s.Reason != signalReasonStale {
		t.Fatalf("GPUSignal %+v", s)
	}
	if h := meta.FindStatusCondition(nh.Status.Conditions, conditionGPUHealthy); h == nil || h.Status != metav1.ConditionUnknown {
		t.Fatalf("GPUHealthy %+v, want Unknown", h)
	}

	// Latched, then the exporter goes away: the fault stays latched and the taint stays on.
	g.now = gfT0.Add(20 * time.Second)
	g.scrape(faultAssessment(79, 0))
	g.reconcile()
	g.store.recordSuccess("gpu-1", g.now, faultAssessment(0, 0)) // the clean reading is about to go stale
	g.now = g.now.Add(10 * time.Second)
	g.reconcile()
	nh, node = g.state()
	if !slices.ContainsFunc(node.Spec.Taints, isGPUFaultTaint) || nh.Annotations[annGPUFaultFingerprint] == "" {
		t.Fatalf("stale data cleared a latched fault")
	}
}

// The path off is the reconciler as it was: no GPU conditions, no taint, whatever the store says.
func TestGPUFaultOffChangesNothing(t *testing.T) {
	g := newGFRig(t, false)
	g.scrape(faultAssessment(79, 0))
	g.r.GPUFault = nil
	g.reconcile()
	nh, node := g.state()
	if len(node.Spec.Taints) != 0 || meta.FindStatusCondition(nh.Status.Conditions, conditionGPUHealthy) != nil || nh.Status.Phase != phaseReady {
		t.Fatalf("the path acted while off: taints %v conditions %v", node.Spec.Taints, nh.Status.Conditions)
	}
}

func gpuPod(name, node string, jobUID types.UID, gpus string) *corev1.Pod {
	p := &corev1.Pod{Name: name, Namespace: "t", Spec: corev1.PodSpec{NodeName: node,
		Containers: []corev1.Container{{Name: "c", Resources: corev1.ResourceRequirements{}}}},
		Status: corev1.PodStatus{Phase: corev1.PodRunning}}
	if gpus != "" {
		p.Spec.Containers[0].Resources.Limits = corev1.ResourceList{gpuResourceName: resource.MustParse(gpus)}
	}
	if jobUID != "" {
		p.OwnerReferences = []metav1.OwnerReference{{APIVersion: "batch/v1", Kind: "Job", Name: "j", UID: jobUID, Controller: new(true)}}
	}
	return p
}

func workload(name string, jobUID types.UID) *kueuev1beta1.Workload {
	return &kueuev1beta1.Workload{Name: name, Namespace: "t",
		Labels: map[string]string{kueueJobUIDLabel: string(jobUID)},
		Status: kueuev1beta1.WorkloadStatus{Conditions: []metav1.Condition{
			{Type: kueuev1beta1.WorkloadQuotaReserved, Status: metav1.ConditionTrue, Reason: "QuotaReserved", LastTransitionTime: metav1.NewTime(gfT0)}}}}
}

func TestGPUFaultDeactivatesOnlyKueueGPUWorkOnTheFaultedNode(t *testing.T) {
	g := newGFRig(t, true,
		gpuPod("on-node", "gpu-1", "uid-1", "1"),
		gpuPod("elsewhere", "gpu-2", "uid-2", "1"),
		gpuPod("cpu-only", "gpu-1", "uid-3", ""),
		gpuPod("no-owner", "gpu-1", "", "1"),
		workload("wl-1", "uid-1"), workload("wl-2", "uid-2"), workload("wl-3", "uid-3"),
	)
	g.scrape(faultAssessment(0, 1))
	g.reconcile()
	get := func(name string) *kueuev1beta1.Workload {
		var wl kueuev1beta1.Workload
		if err := g.c.Get(context.Background(), types.NamespacedName{Namespace: "t", Name: name}, &wl); err != nil {
			t.Fatal(err)
		}
		return &wl
	}
	wl := get("wl-1")
	if ptr.Deref(wl.Spec.Active, true) || wl.Annotations[annWorkloadDeactivatedNode] != "gpu-1" || wl.Annotations[annWorkloadDeactivatedAt] == "" {
		t.Fatalf("the faulted node's GPU workload was not deactivated: active=%v %v", wl.Spec.Active, wl.Annotations)
	}
	for _, n := range []string{"wl-2", "wl-3"} {
		if w := get(n); !ptr.Deref(w.Spec.Active, true) {
			t.Fatalf("%s was deactivated", n)
		}
	}

	// Not reactivated until Kueue has evicted it and released the quota.
	g.reconcile()
	if wl = get("wl-1"); ptr.Deref(wl.Spec.Active, true) {
		t.Fatalf("reactivated before Kueue evicted it")
	}
	meta.SetStatusCondition(&wl.Status.Conditions, metav1.Condition{Type: kueuev1beta1.WorkloadEvicted, Status: metav1.ConditionTrue, Reason: "Deactivated"})
	meta.SetStatusCondition(&wl.Status.Conditions, metav1.Condition{Type: kueuev1beta1.WorkloadQuotaReserved, Status: metav1.ConditionFalse, Reason: "Pending"})
	if err := g.c.Status().Update(context.Background(), wl); err != nil {
		t.Fatal(err)
	}
	// The Pod is gone from the node by now, as the suspended Job's Pods are.
	if err := g.c.Delete(context.Background(), &corev1.Pod{Name: "on-node", Namespace: "t"}); err != nil {
		t.Fatal(err)
	}
	g.reconcile()
	wl = get("wl-1")
	if !ptr.Deref(wl.Spec.Active, true) || wl.Annotations[annWorkloadReactivatedAt] == "" {
		t.Fatalf("not reactivated after eviction: active=%v %v", wl.Spec.Active, wl.Annotations)
	}
}

// A Workload a person deactivated carries no deactivated-node and must stay deactivated.
func TestGPUFaultNeverReactivatesAWorkloadItDidNotDeactivate(t *testing.T) {
	wl := workload("manual", "uid-9")
	wl.Spec.Active = new(false)
	wl.Status.Conditions = []metav1.Condition{{Type: kueuev1beta1.WorkloadEvicted, Status: metav1.ConditionTrue, Reason: "Deactivated", LastTransitionTime: metav1.NewTime(gfT0)}}
	g := newGFRig(t, true, wl)
	g.scrape(faultAssessment(0, 0))
	g.reconcile()
	var got kueuev1beta1.Workload
	if err := g.c.Get(context.Background(), types.NamespacedName{Namespace: "t", Name: "manual"}, &got); err != nil {
		t.Fatal(err)
	}
	if ptr.Deref(got.Spec.Active, true) {
		t.Fatalf("a manually deactivated workload was reactivated")
	}
}

// Without --gpu-fault-evict-workloads a fault taints and evicts nothing.
func TestGPUFaultDoesNotEvictUnlessAskedTo(t *testing.T) {
	g := newGFRig(t, false, gpuPod("on-node", "gpu-1", "uid-1", "1"), workload("wl-1", "uid-1"))
	g.scrape(faultAssessment(79, 0))
	g.reconcile()
	var wl kueuev1beta1.Workload
	if err := g.c.Get(context.Background(), types.NamespacedName{Namespace: "t", Name: "wl-1"}, &wl); err != nil {
		t.Fatal(err)
	}
	if !ptr.Deref(wl.Spec.Active, true) {
		t.Fatalf("evicted without the flag")
	}
}

func TestGPUFaultTaintGoesWithTheNodeHealth(t *testing.T) {
	g := newGFRig(t, false)
	g.scrape(faultAssessment(79, 0))
	g.reconcile()
	nh, _ := g.state()
	if err := g.c.Delete(context.Background(), nh); err != nil {
		t.Fatal(err)
	}
	g.r.GPUFault = nil // even with the path turned off since
	g.reconcile()
	var node corev1.Node
	if err := g.c.Get(context.Background(), types.NamespacedName{Name: "gpu-1"}, &node); err != nil {
		t.Fatal(err)
	}
	if slices.ContainsFunc(node.Spec.Taints, isGPUFaultTaint) {
		t.Fatalf("deleting the NodeHealth left its gpu-fault taint")
	}
}
