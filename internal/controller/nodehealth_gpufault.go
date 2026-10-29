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
	"slices"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/events"
	"k8s.io/utils/ptr"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/event"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
	kueuev1beta1 "sigs.k8s.io/kueue/apis/kueue/v1beta1"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// gpuFaultTaintKey is the taint a DCGM-reported GPU fault puts on its node.
//
// It is a key of its own rather than the readiness taint, because the readiness path removes its taint
// whenever the kubelet is Ready, and a card can be faulted on a node whose kubelet is perfectly healthy.
const gpuFaultTaintKey = "platform.lkhun9311.github.io/gpu-fault"

// The annotations that carry the platform's own timestamps and the fault it has latched.
//
// They are annotations rather than status fields so that the API does not change for a study, and they hold
// RFC 3339 times with nanoseconds because a condition's lastTransitionTime is truncated to the second, which
// is coarser than the hops being measured.
const (
	gpuFaultAnnotationPrefix = "gpufault.platform.lkhun9311.github.io/"
	// annGPUFaultFingerprint is the latched fault; its presence, not the condition, is what survives a restart.
	annGPUFaultFingerprint = gpuFaultAnnotationPrefix + "fingerprint"
	// annGPUFaultObservedAt is when the first scrape carrying the latched fingerprint returned.
	annGPUFaultObservedAt = gpuFaultAnnotationPrefix + "observed-at"
	// annGPUFaultTaintedAt is written after the Node patch that added the taint succeeded.
	annGPUFaultTaintedAt = gpuFaultAnnotationPrefix + "tainted-at"
	// annGPUFaultClearedAt is when a fresh scrape without the fault, or an acknowledgement, released the latch.
	annGPUFaultClearedAt = gpuFaultAnnotationPrefix + "cleared-at"
	// annGPUFaultAcknowledged is written by an operator: a fingerprint here is not a fault any more.
	annGPUFaultAcknowledged = gpuFaultAnnotationPrefix + "acknowledged"
	// annGPUFaultReading is every value the last fresh scrape carried, written only when it changes.
	//
	// It is the evidence that a value the policy ignores was read and ignored rather than never read: a quiet
	// control proves nothing about an observer that had stopped observing.
	annGPUFaultReading = gpuFaultAnnotationPrefix + "reading"
	// annGPUFaultReadingAt is when the first scrape carrying that reading returned.
	annGPUFaultReadingAt = gpuFaultAnnotationPrefix + "reading-at"

	// annWorkloadDeactivatedAt is when this platform sent the patch deactivating a Workload.
	annWorkloadDeactivatedAt = gpuFaultAnnotationPrefix + "deactivated-at"
	// annWorkloadDeactivatedNode names the faulted node; only Workloads carrying it are ever reactivated.
	annWorkloadDeactivatedNode = gpuFaultAnnotationPrefix + "deactivated-node"
	// annWorkloadFingerprint is the fault that displaced the Workload.
	annWorkloadFingerprint = gpuFaultAnnotationPrefix + "deactivated-fingerprint"
	// annWorkloadReactivatedAt is when this platform sent the patch reactivating it.
	annWorkloadReactivatedAt = gpuFaultAnnotationPrefix + "reactivated-at"
)

// The two conditions the DCGM path adds to NodeHealth.
const (
	// conditionGPUSignal says whether the platform has a fresh reading of the node's cards at all.
	conditionGPUSignal = "GPUSignal"
	// conditionGPUHealthy says what that reading means; Unknown whenever it cannot say.
	conditionGPUHealthy = "GPUHealthy"

	gpuHealthyReasonNoFault        = "NoFault"
	gpuHealthyReasonAcknowledged   = "Acknowledged"
	gpuHealthyReasonSignalNotFresh = "SignalNotFresh"
	gpuHealthyReasonFieldMissing   = "FieldMissing"
	// gpuHealthyReasonLatched is used only when a fault is latched and the condition that named it is gone.
	gpuHealthyReasonLatched = "FaultLatched"
)

// faultSourceDCGM is the faultSignal source while a node is quarantined for a DCGM-reported fault.
const faultSourceDCGM = "dcgm"

// gpuResourceName is the extended resource whose Pods are displaced from a faulted node.
const gpuResourceName corev1.ResourceName = "nvidia.com/gpu"

// GPUFaultConfig turns on the DCGM fault path; a nil one on the reconciler leaves it exactly as it was.
type GPUFaultConfig struct {
	Store *GPUFaultStore
	// StaleAfter must be the source's, so that the reconciler and the scraper agree on what fresh means.
	StaleAfter time.Duration
	// EvictWorkloads lets the reconciler deactivate the Kueue Workloads of GPU Pods on a faulted node.
	EvictWorkloads bool
	// APIReader lists a node's Pods without a cluster-wide Pod informer.
	APIReader client.Reader
	// Recorder may be nil, in which case no events are emitted.
	Recorder events.EventRecorder
	// Events is the scraper's wake-up channel; the controller watches it.
	Events chan event.GenericEvent
	// Now is the clock; nil means time.Now.
	Now func() time.Time
}

func (c *GPUFaultConfig) now() time.Time {
	if c.Now != nil {
		return c.Now()
	}
	return time.Now()
}

func (c *GPUFaultConfig) event(obj runtime.Object, eventtype, reason, action, note string, args ...any) {
	if c.Recorder != nil {
		c.Recorder.Eventf(obj, nil, eventtype, reason, action, note, args...)
	}
}

// gpuFaultDecision is what one observation means for one node.
type gpuFaultDecision struct {
	signal  metav1.Condition
	healthy metav1.Condition
	// latch is the fingerprint to hold after this reconcile, "" for none.
	latch string
	// newLatch is true when latch is a fingerprint that was not held before.
	newLatch bool
	// observedAt is when the scraper first saw latch; set only with newLatch.
	observedAt time.Time
	// taint is +1 to ensure the taint, -1 to remove it, 0 to leave it as it is.
	taint int
	// reading and readingAt are the fresh scrape's values and when they first appeared; empty when not fresh.
	reading   string
	readingAt time.Time
}

// decideGPUFault applies the rules the registration states, and nothing else:
// a fresh fault latches and taints; a fresh reading whose fault fields all read zero, or that carries exactly
// the acknowledged fault, or that carries no fault while the latched one is acknowledged, releases the latch;
// anything that is not fresh, or not complete, changes neither the latch nor the taint.
func decideGPUFault(obs GPUFaultObservation, hasObs bool, now time.Time, staleAfter time.Duration,
	latched, acknowledged string, prevHealthy *metav1.Condition) gpuFaultDecision {
	d := gpuFaultDecision{latch: latched}
	keepLatch := func(reason, msg string) {
		// While a fault is latched the card stays faulted, whatever the signal does; the reason and message are
		// the fault's, not the signal's, so that what an operator reads is what the taint is for.
		if latched != "" {
			r, m := gpuHealthyReasonLatched, "fault "+latched+" is latched"
			if prevHealthy != nil && prevHealthy.Status == metav1.ConditionFalse {
				r, m = prevHealthy.Reason, prevHealthy.Message
			}
			d.healthy = metav1.Condition{Type: conditionGPUHealthy, Status: metav1.ConditionFalse, Reason: r, Message: m}
			d.taint = +1
			return
		}
		d.healthy = metav1.Condition{Type: conditionGPUHealthy, Status: metav1.ConditionUnknown, Reason: reason, Message: msg}
	}

	fresh := hasObs && !obs.LastSuccess.IsZero() && now.Sub(obs.LastSuccess) <= staleAfter
	if !fresh {
		reason, msg := signalReasonNoObservation, "no scrape of this node's exporter has succeeded since the operator started"
		switch {
		case hasObs && obs.LastFailure.After(obs.LastSuccess) && obs.FailureReason != "":
			reason, msg = obs.FailureReason, obs.FailureDetail
		case hasObs && !obs.LastSuccess.IsZero():
			// The message names the bound, not the age: an age would change on every reconcile and turn each one
			// into a status write.
			reason, msg = signalReasonStale, fmt.Sprintf("no successful scrape for more than %s", staleAfter)
		}
		d.signal = metav1.Condition{Type: conditionGPUSignal, Status: metav1.ConditionFalse, Reason: reason, Message: msg}
		keepLatch(gpuHealthyReasonSignalNotFresh, "no fresh reading of this node's cards: "+reason)
		return d
	}
	d.signal = metav1.Condition{Type: conditionGPUSignal, Status: metav1.ConditionTrue, Reason: signalReasonFresh,
		Message: fmt.Sprintf("%d card(s) read within %s", obs.Assessment.Cards, staleAfter)}
	d.reading, d.readingAt = obs.Assessment.Reading(), obs.ReadingSince

	fp := obs.Assessment.Fingerprint()
	switch {
	case fp != "" && fp != acknowledged:
		d.healthy = metav1.Condition{Type: conditionGPUHealthy, Status: metav1.ConditionFalse,
			Reason: obs.Assessment.Reason(), Message: "fault " + fp}
		d.taint = +1
		if fp != latched {
			d.latch, d.newLatch, d.observedAt = fp, true, obs.FaultSince
		}
	case fp != "":
		// Exactly the acknowledged fault: the operator has taken it, and a different one would not match.
		d.healthy = metav1.Condition{Type: conditionGPUHealthy, Status: metav1.ConditionTrue,
			Reason: gpuHealthyReasonAcknowledged, Message: "fault " + fp + " is acknowledged"}
		d.latch, d.taint = "", -1
	case len(obs.Assessment.Missing) > 0:
		// No fault among the fields that were read, and a fault field not read: health cannot be judged.
		keepLatch(gpuHealthyReasonFieldMissing, fmt.Sprintf("no readable value for %v", obs.Assessment.Missing))
	case latched != "" && latched == acknowledged:
		// No fault now, and the operator has taken the one that is latched. The case above ran only while the
		// reading still carried that fault, so an application Xid replacing it left the acknowledgement with
		// nothing to match, and the registration's "only an operator's acknowledgement clears the node" did not
		// hold (codex audit, 2026-10-28).
		d.healthy = metav1.Condition{Type: conditionGPUHealthy, Status: metav1.ConditionTrue,
			Reason: gpuHealthyReasonAcknowledged, Message: "fault " + latched + " is acknowledged"}
		d.latch, d.taint = "", -1
	case latched != "" && (!obs.Assessment.Pristine() || !obs.Assessment.Covers(latched)):
		// No fault now, and not zero either: an application Xid has replaced the fatal one in the last-Xid field.
		// That is not a repair, so the latch holds until the fields read zero or the fault is acknowledged.
		// Nor is a scrape that no longer carries the faulted card: its absence says nothing about its recovery.
		keepLatch("", "")
	default:
		d.healthy = metav1.Condition{Type: conditionGPUHealthy, Status: metav1.ConditionTrue,
			Reason: gpuHealthyReasonNoFault, Message: "no fault field set on any card"}
		d.latch, d.taint = "", -1
	}
	return d
}

// decideGPUFaultFor reads the inputs of decideGPUFault off the NodeHealth and the store.
func (r *NodeHealthReconciler) decideGPUFaultFor(nh *platformv1.NodeHealth) gpuFaultDecision {
	obs, ok := r.GPUFault.Store.Get(nh.Spec.NodeName)
	return decideGPUFault(obs, ok, r.GPUFault.now(), r.GPUFault.StaleAfter,
		nh.Annotations[annGPUFaultFingerprint], nh.Annotations[annGPUFaultAcknowledged],
		meta.FindStatusCondition(nh.Status.Conditions, conditionGPUHealthy))
}

// applyGPUFaultToNode changes the node's taints as decided and reports whether they changed.
func applyGPUFaultToNode(node *corev1.Node, d gpuFaultDecision) bool {
	switch d.taint {
	case +1:
		return ensureGPUFaultTaint(node)
	case -1:
		return removeGPUFaultTaint(node)
	}
	return false
}

func isGPUFaultTaint(t corev1.Taint) bool {
	return t.Key == gpuFaultTaintKey && t.Effect == corev1.TaintEffectNoSchedule
}

func ensureGPUFaultTaint(node *corev1.Node) bool {
	if slices.ContainsFunc(node.Spec.Taints, isGPUFaultTaint) {
		return false
	}
	node.Spec.Taints = append(node.Spec.Taints, corev1.Taint{
		Key: gpuFaultTaintKey, Value: "true", Effect: corev1.TaintEffectNoSchedule,
	})
	return true
}

func removeGPUFaultTaint(node *corev1.Node) bool {
	before := len(node.Spec.Taints)
	node.Spec.Taints = slices.DeleteFunc(node.Spec.Taints, isGPUFaultTaint)
	return len(node.Spec.Taints) != before
}

// applyGPUFaultToStatus writes the two conditions; the phase a latched fault means is set by the caller.
func applyGPUFaultToStatus(status *platformv1.NodeHealthStatus, d gpuFaultDecision, generation int64) {
	d.signal.ObservedGeneration = generation
	d.healthy.ObservedGeneration = generation
	meta.SetStatusCondition(&status.Conditions, d.signal)
	meta.SetStatusCondition(&status.Conditions, d.healthy)
}

// recordGPUFault writes the platform's timestamps, displaces GPU work from a faulted node and brings back
// what it displaced. It runs after the Node patch, so that tainted-at is a time the taint existed.
func (r *NodeHealthReconciler) recordGPUFault(ctx context.Context, nh *platformv1.NodeHealth, d gpuFaultDecision,
	node *corev1.Node) error {
	cfg := r.GPUFault
	base := nh.DeepCopy()
	if nh.Annotations == nil {
		nh.Annotations = map[string]string{}
	}
	prevLatch := nh.Annotations[annGPUFaultFingerprint]
	stamp := func(t time.Time) string { return t.UTC().Format(time.RFC3339Nano) }
	switch {
	case d.newLatch:
		nh.Annotations[annGPUFaultFingerprint] = d.latch
		nh.Annotations[annGPUFaultObservedAt] = stamp(d.observedAt)
		delete(nh.Annotations, annGPUFaultTaintedAt)
		delete(nh.Annotations, annGPUFaultClearedAt)
		gpuFaultTransitionsTotal.WithLabelValues(d.healthy.Reason).Inc()
		cfg.event(nh, corev1.EventTypeWarning, "GPUFaultObserved", "Observe", "node %s: %s", nh.Spec.NodeName, d.latch)
	case prevLatch != "" && d.latch == "":
		delete(nh.Annotations, annGPUFaultFingerprint)
		nh.Annotations[annGPUFaultClearedAt] = stamp(cfg.now())
		gpuFaultTransitionsTotal.WithLabelValues("Cleared").Inc()
		cfg.event(nh, corev1.EventTypeNormal, "GPUFaultCleared", "Clear", "node %s: %s (%s)", nh.Spec.NodeName,
			prevLatch, d.healthy.Reason)
	}
	if d.reading != "" && nh.Annotations[annGPUFaultReading] != d.reading {
		nh.Annotations[annGPUFaultReading] = d.reading
		nh.Annotations[annGPUFaultReadingAt] = stamp(d.readingAt)
	}
	if d.latch != "" && nh.Annotations[annGPUFaultTaintedAt] == "" && slices.ContainsFunc(node.Spec.Taints, isGPUFaultTaint) {
		at := cfg.now()
		nh.Annotations[annGPUFaultTaintedAt] = stamp(at)
		if obs, err := time.Parse(time.RFC3339Nano, nh.Annotations[annGPUFaultObservedAt]); err == nil {
			gpuFaultObserveToTaintSeconds.Observe(at.Sub(obs).Seconds())
		}
	}
	if !equalStringMaps(base.Annotations, nh.Annotations) {
		if err := r.Patch(ctx, nh, client.MergeFrom(base)); err != nil {
			return fmt.Errorf("record gpu fault on nodehealth %s: %w", nh.Name, err)
		}
	}
	if cfg.EvictWorkloads && d.latch != "" {
		if err := r.displaceGPUWork(ctx, nh, d.latch); err != nil {
			return err
		}
	}
	return r.reactivateDisplaced(ctx, nh)
}

func equalStringMaps(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if w, ok := b[k]; !ok || w != v {
			return false
		}
	}
	return true
}

// displaceGPUWork deactivates the Kueue Workload of every GPU Pod still on the faulted node.
//
// Deactivation is Kueue's own eviction: it suspends the Job, which stops its Pods and releases the quota, and
// reactivating the Workload requeues it. Deleting the Pods instead would have the Job recreate them inside the
// same admission, so Kueue would never learn that the placement failed.
// A GPU Pod with no Workload is reported and left alone: nothing here may stop work Kueue did not admit.
func (r *NodeHealthReconciler) displaceGPUWork(ctx context.Context, nh *platformv1.NodeHealth, fp string) error {
	cfg := r.GPUFault
	log := logf.FromContext(ctx)
	var pods corev1.PodList
	if err := cfg.APIReader.List(ctx, &pods, client.MatchingFields{"spec.nodeName": nh.Spec.NodeName}); err != nil {
		return fmt.Errorf("list pods on faulted node %s: %w", nh.Spec.NodeName, err)
	}
	for i := range pods.Items {
		p := &pods.Items[i]
		if p.Status.Phase == corev1.PodSucceeded || p.Status.Phase == corev1.PodFailed || !requestsGPU(p) {
			continue
		}
		owner := metav1.GetControllerOf(p)
		if owner == nil || owner.Kind != "Job" {
			cfg.event(nh, corev1.EventTypeWarning, "GPUFaultPodNotDisplaced", "Displace",
				"pod %s/%s uses a GPU on the faulted node and has no Job owner, so no Kueue Workload to evict", p.Namespace, p.Name)
			continue
		}
		var wls kueuev1beta1.WorkloadList
		if err := r.List(ctx, &wls, client.InNamespace(p.Namespace), client.MatchingLabels{kueueJobUIDLabel: string(owner.UID)}); err != nil {
			return fmt.Errorf("list workloads for pod %s/%s: %w", p.Namespace, p.Name, err)
		}
		if len(wls.Items) == 0 {
			cfg.event(nh, corev1.EventTypeWarning, "GPUFaultPodNotDisplaced", "Displace",
				"pod %s/%s uses a GPU on the faulted node and its Job has no Kueue Workload", p.Namespace, p.Name)
			continue
		}
		for j := range wls.Items {
			wl := &wls.Items[j]
			if !ptr.Deref(wl.Spec.Active, true) {
				continue
			}
			base := wl.DeepCopy()
			wl.Spec.Active = new(false)
			if wl.Annotations == nil {
				wl.Annotations = map[string]string{}
			}
			at := cfg.now()
			wl.Annotations[annWorkloadDeactivatedAt] = at.UTC().Format(time.RFC3339Nano)
			wl.Annotations[annWorkloadDeactivatedNode] = nh.Spec.NodeName
			wl.Annotations[annWorkloadFingerprint] = fp
			delete(wl.Annotations, annWorkloadReactivatedAt)
			if err := r.Patch(ctx, wl, client.MergeFrom(base)); err != nil {
				return fmt.Errorf("deactivate workload %s/%s: %w", wl.Namespace, wl.Name, err)
			}
			gpuFaultWorkloadActionsTotal.WithLabelValues("deactivated").Inc()
			log.Info("Deactivated Workload on a faulted node", "workload", wl.Namespace+"/"+wl.Name, "node", nh.Spec.NodeName)
			cfg.event(wl, corev1.EventTypeWarning, "GPUFaultDeactivated", "Displace",
				"its pod %s ran on node %s, which carries GPU fault %s", p.Name, nh.Spec.NodeName, fp)
		}
	}
	return nil
}

// requestsGPU reports whether any container asks for a GPU, by request or by limit.
func requestsGPU(p *corev1.Pod) bool {
	for _, cs := range [][]corev1.Container{p.Spec.InitContainers, p.Spec.Containers} {
		for _, c := range cs {
			if q, ok := c.Resources.Requests[gpuResourceName]; ok && !q.IsZero() {
				return true
			}
			if q, ok := c.Resources.Limits[gpuResourceName]; ok && !q.IsZero() {
				return true
			}
		}
	}
	return false
}

// reactivateDisplaced reactivates each Workload this platform deactivated for this node, once Kueue has
// finished evicting it.
//
// Waiting for Evicted and for the quota to be gone is what makes the requeue a new admission: reactivating
// while the old one is still being torn down would race Kueue's own eviction.
// Only Workloads carrying deactivated-node are touched, so a Workload a person deactivated stays deactivated.
func (r *NodeHealthReconciler) reactivateDisplaced(ctx context.Context, nh *platformv1.NodeHealth) error {
	cfg := r.GPUFault
	var wls kueuev1beta1.WorkloadList
	if err := r.List(ctx, &wls); err != nil {
		return fmt.Errorf("list workloads to reactivate: %w", err)
	}
	for i := range wls.Items {
		wl := &wls.Items[i]
		if wl.Annotations[annWorkloadDeactivatedNode] != nh.Spec.NodeName || wl.Annotations[annWorkloadReactivatedAt] != "" ||
			ptr.Deref(wl.Spec.Active, true) ||
			!meta.IsStatusConditionTrue(wl.Status.Conditions, kueuev1beta1.WorkloadEvicted) ||
			meta.IsStatusConditionTrue(wl.Status.Conditions, kueuev1beta1.WorkloadQuotaReserved) {
			continue
		}
		base := wl.DeepCopy()
		wl.Spec.Active = new(true)
		wl.Annotations[annWorkloadReactivatedAt] = cfg.now().UTC().Format(time.RFC3339Nano)
		if err := r.Patch(ctx, wl, client.MergeFrom(base)); err != nil {
			return fmt.Errorf("reactivate workload %s/%s: %w", wl.Namespace, wl.Name, err)
		}
		gpuFaultWorkloadActionsTotal.WithLabelValues("reactivated").Inc()
		cfg.event(wl, corev1.EventTypeNormal, "GPUFaultReactivated", "Requeue",
			"evicted from faulted node %s; requeued so Kueue can admit it again", nh.Spec.NodeName)
	}
	return nil
}

// mapWorkloadToNodeHealth wakes the NodeHealth of the node a displaced Workload was taken from, so that its
// eviction finishing is what triggers the reactivation.
func (r *NodeHealthReconciler) mapWorkloadToNodeHealth(ctx context.Context, obj client.Object) []reconcile.Request {
	node := obj.GetAnnotations()[annWorkloadDeactivatedNode]
	if node == "" {
		return nil
	}
	return r.mapNodeToNodeHealth(ctx, &metav1.PartialObjectMetadata{Name: node})
}
