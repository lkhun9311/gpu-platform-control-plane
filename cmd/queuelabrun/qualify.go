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
	"context"
	"fmt"
	"strings"

	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/queuelab"
)

// The ownership transaction proves the worker is OURS. It does not prove the worker is EMPTY, and those are
// different claims: the dedication label and the NoSchedule taint reserve the node against future placement,
// and neither evicts a Pod that was already running when they were installed. A GPU Pod that predates the
// acquisition keeps its device for the whole run, so the arm's queues admit against capacity the run does not
// actually have, and it reports a number measured on a machine that is not the one it thinks it has — with no
// signal anywhere. This file is the check that the premise held before the first Create, not after.

// gpuResourceName mirrors internal/queuelab's private gpuResource, duplicated for the same reason spine.go
// duplicates terminationGraceSec and variantLabelKey: that package is measurement code that must not change
// for this, and it does not export the constant.
const gpuResourceName = corev1.ResourceName("nvidia.com/gpu")

// gpuConsumer is one Pod already holding devices on the worker, in the spelling the run record persists.
//
// The phase and the terminating flag are both carried because they are what tells an operator which cluster
// they are looking at. A Running Pod is somebody else's live work and this run must wait or move; a
// Terminating one is almost always the previous run's stuck teardown, which will clear on its own and needs
// no action beyond patience. Collapsing them into "a Pod was there" would send the operator to the wrong
// remedy for whichever case they actually have.
type gpuConsumer struct {
	Namespace string `json:"namespace"`
	Name      string `json:"name"`
	Phase     string `json:"phase"`
	// Terminating is deletionTimestamp being set, not the phase. A Pod deleted a moment ago is still Running
	// and still holds its device until the kubelet finishes with it, which is exactly the state a stuck
	// teardown leaves behind and exactly the state a taint cannot see.
	Terminating bool `json:"terminating,omitempty"`
	// GPUs is what the Pod asked for. It is recorded rather than merely counted because "one Pod" and "one Pod
	// holding both devices" are different amounts of contamination, and a record that only said a Pod was
	// present could not tell them apart afterwards.
	GPUs int64 `json:"gpus"`
}

// qualification is what the run observed about its worker before it created anything on it.
//
// It is persisted whether the worker qualified or not, and the refusal path is the more valuable of the two:
// a run that refused is precisely the run whose evidence would otherwise be a sentence on somebody's
// terminal. The later validity-bearing-artifact gate is then serialization of what each gate already wrote,
// rather than a second investigation.
//
// It is written into the record directly rather than through a projection type, unlike recordResidue. That
// projection exists because `residue` carries an `error` — an interface field that encodes asymmetrically and
// does not decode at all — and because its verdict is an iota whose declaration order would have become a
// wire format. Neither applies here: every field below is a string, a bool or an int64, and the one
// enumerated value (Phase) is already the apiserver's own name for it. A second type would be a copy to keep
// in sync for no guarantee.
type qualification struct {
	Node    string `json:"node"`
	NodeUID string `json:"nodeUID"`
	// AllocatableGPU is what the node advertises, which is the total rather than the free amount. It is only
	// the available amount BECAUSE GPUConsumers below is empty; the two fields are one claim, and a reader who
	// has one without the other has been told nothing about what this run could actually schedule.
	AllocatableGPU int64 `json:"allocatableGPU"`
	RequiredGPU    int64 `json:"requiredGPU"`
	// RequiredFrom names where the requirement came from, because a bare number invites exactly the hard-coded
	// constant this derivation exists to avoid: a later reader has to be able to tell whether 2 was computed
	// from this run's own fixtures or typed in by somebody who knew what the cluster happened to have. It
	// quotes BOTH lower bounds and their numbers, not just the one that won, so the margin between them is
	// legible rather than having to be reconstructed from the fixtures afterwards.
	RequiredFrom string `json:"requiredFrom"`
	// RequiredBoundBy is which of the two bounds decided, as a name rather than as a sentence to be parsed —
	// the same reason the disposition is a constant and not free text. A run refused for capacity reads
	// completely differently depending on this: bound by the quota sum means the node cannot hold the whole
	// arm at once, bound by a single row means one Pod in the trace could never be scheduled at all.
	RequiredBoundBy string `json:"requiredBoundBy"`
	Ready           bool   `json:"ready"`
	Schedulable     bool   `json:"schedulable"`
	// PodsOnNode is the denominator for the empty GPUConsumers list.
	//
	// "No foreign GPU consumer" is a negative, and a negative that was never given a count is indistinguishable
	// from a List that returned nothing because it was pointed at the wrong node, or filtered on a name the
	// cluster does not use. A run that inspected fourteen Pods and found none holding a device has established
	// something; a run that inspected zero has established that it looked in an empty place.
	PodsOnNode int `json:"podsOnNode"`
	// GPUConsumers is empty on every qualified run, which is why it is omitempty: a record carrying one is
	// always a record of a refusal.
	GPUConsumers []gpuConsumer `json:"gpuConsumers,omitempty"`
}

// The two names a requirement can be bound by. They are constants because the record persists one of them and
// a reader classifies on it; a reworded string would silently become a different value.
const (
	boundByQuotaSum   = "nominal-quota-sum"
	boundByLargestRow = "largest-trace-row"
)

// gpuRequirement is how much of the device this run needs, and which of its two independent lower bounds
// decided that.
type gpuRequirement struct {
	Total   int64
	BoundBy string
	From    string
}

// requiredGPU derives how much of the device this run needs from its OWN fixtures and its OWN trace.
//
// It is derived rather than written down because the number is a property of the arm, not of the cluster: the
// reclaim study builds two ClusterQueues at nominal 1 in one per-run cohort and the FIFO study one at 2, and a
// constant here would be a second copy of the fixtures' sizing that nothing keeps in step with them. A node
// advertising 1 would still let a reclaim run complete — it would simply never produce the borrow-then-reclaim
// contrast the arm is named after, and would report the run that did not happen as the run that did.
//
// There are TWO independent lower bounds and the requirement is the larger:
//
//   - The nominal quota SUM across this run's ClusterQueues. Summing is right precisely because a study's
//     queues share one per-run cohort and one per-run flavor, so their quotas are simultaneously admissible
//     against the same node and the node has to back their total. Quotas on any other flavor are skipped,
//     since this run's flavor is the only one pinned to this run's worker.
//   - The LARGEST SINGLE trace row. A Pod is scheduled whole onto one node, so a row asking for more than the
//     node advertises can never be scheduled at all, however much aggregate quota exists — and this is not a
//     hypothetical shape: FIFOHeadOfLineScenario emits a 2-GPU head row, and ValidateTrace REQUIRES one,
//     because head-of-line blocking is the mechanism that study is about.
//
// Neither bound implies the other, and today they happen to coincide — the FIFO sum is 2 and its largest row
// is 2 — which is exactly the coincidence that would let the missing bound go unnoticed. A study with a 3-GPU
// row against a 2-GPU nominal sum would pass a sum-only check, run, and contain a Pod that could never be
// scheduled: the arm would report the head-of-line comparison it structurally never made.
//
// To be exact about what is and is not exercised today: run() pins `study := queuelab.StudyReclaim`, so the
// FIFO trace — the one whose head row is 2 GPUs — is not reachable through this binary at all yet, and the
// row bound therefore never decides for any run this build can perform. It is written now because the study
// switch is a smaller change than remembering this constraint at the time, and because the bound is a
// property of how Kubernetes schedules a Pod rather than of which study is wired up. The tests reach it
// directly for the same reason.
//
// On a tie the quota sum is named as the binding one, because it is the bound that always exists.
func requiredGPU(fs *queuelab.FixtureSet, trace []queuelab.TrainingTraceRow) (gpuRequirement, error) {
	if fs == nil || fs.Flavor == nil {
		return gpuRequirement{}, fmt.Errorf("fixture set has no ResourceFlavor to size the worker against")
	}
	flavor := fs.Flavor.Name
	var sum int64
	// Counted rather than taken from len(fs.ClusterQueue), because only the queues that actually carried a
	// quota on THIS run's flavor were added: a count of every queue in the set would describe a sum that was
	// not taken over them, in the one field whose entire job is to be trustworthy about where a number came
	// from.
	contributing := 0
	for _, cq := range fs.ClusterQueue {
		if cq == nil {
			continue
		}
		before := sum
		for _, rg := range cq.Spec.ResourceGroups {
			for _, fq := range rg.Flavors {
				if string(fq.Name) != flavor {
					continue
				}
				for _, r := range fq.Resources {
					if r.Name == gpuResourceName {
						sum += r.NominalQuota.Value()
					}
				}
			}
		}
		if sum != before {
			contributing++
		}
	}

	var largest int64
	largestRow := "(no rows)"
	for _, row := range trace {
		if int64(row.GPUCount) > largest {
			largest = int64(row.GPUCount)
			largestRow = row.Name
		}
	}

	req := gpuRequirement{Total: sum, BoundBy: boundByQuotaSum}
	if largest > sum {
		req = gpuRequirement{Total: largest, BoundBy: boundByLargestRow}
	}
	req.From = fmt.Sprintf(
		"nominal %s quota summed over %d ClusterQueue(s) on flavor %s = %d; largest single trace row %q = %d",
		gpuResourceName, contributing, flavor, sum, largestRow, largest)
	if req.Total < 1 {
		// A zero requirement would make this whole check pass on any node at all, including one advertising no
		// device — so it is refused rather than accepted as a trivially satisfiable bar. Reaching it means the
		// fixtures cover no GPU and the trace asks for none, which is a bug in this program rather than anything
		// about the machine, and the message says so rather than blaming the node.
		return req, fmt.Errorf("this run's fixtures and trace request no %s at all (%s); "+
			"that is a defect in the protocol, not a property of the worker", gpuResourceName, req.From)
	}
	return req, nil
}

// gpuOf reads one container's device request.
//
// Requests is preferred and Limits is the fallback, because for an extended resource a Pod may name only the
// limit and have the request defaulted to match it — reading Requests alone would score exactly that Pod, the
// ordinary way a GPU Pod is written, as consuming nothing.
func gpuOf(r corev1.ResourceRequirements) int64 {
	if q, ok := r.Requests[gpuResourceName]; ok {
		return q.Value()
	}
	if q, ok := r.Limits[gpuResourceName]; ok {
		return q.Value()
	}
	return 0
}

// podGPURequest is the device count the kubelet reserves for a Pod.
//
// Init containers run one at a time and before the rest, so the Pod's effective request is the larger of the
// regular containers' sum and the largest single init container — the same rule the scheduler applies. A
// restartable init container (a sidecar) would properly be added to the sum rather than maximised over, and
// this does not model that; it cannot change the verdict, because the only question asked of this number is
// whether it is above zero, and the maximum is above zero exactly when the sum would be.
func podGPURequest(spec *corev1.PodSpec) int64 {
	var regular int64
	for _, c := range spec.Containers {
		regular += gpuOf(c.Resources)
	}
	var largestInit int64
	for _, c := range spec.InitContainers {
		if v := gpuOf(c.Resources); v > largestInit {
			largestInit = v
		}
	}
	if largestInit > regular {
		return largestInit
	}
	return regular
}

// holdsDevices reports whether a Pod's device is still the kubelet's to account for.
//
// The test is on the PHASE, not on the deletion timestamp: a Pod that has been deleted but has not finished
// is still Running and still holds its device, which is the whole reason a terminating Pod has to count here.
// Succeeded and Failed are the two phases where the kubelet has already released the device and the object is
// only awaiting garbage collection, so counting them would refuse runs over Pods that finished days ago.
// Pending counts, because a Pod already assigned to this node has the resource reserved for it by the
// scheduler and will take it the moment it starts.
func holdsDevices(p *corev1.Pod) bool {
	return p.Status.Phase != corev1.PodSucceeded && p.Status.Phase != corev1.PodFailed
}

// gpuConsumersOn finds every Pod already holding devices on the named node.
//
// The predicate is what a Pod REQUESTS, never what the node advertises or what a Pod is named. That
// distinction is the trap this check has to walk past rather than into: the cluster runs a gpu-simulator
// DaemonSet which is where nvidia.com/gpu on these nodes comes from at all, and it requests 10m CPU and 32Mi
// of memory and no device whatsoever — it is a device plugin, it publishes capacity rather than consuming it.
// Any predicate keyed on "is associated with GPUs" rather than on the resource request would reject the
// provider of the resource on every node it runs on, which is every node, and every run would refuse.
//
// Nothing is excluded as "this run's own". Nothing of this run's exists yet: this is called after the worker
// is acquired and before the run's first Create, so ownership of everything found here is decided by
// position rather than by a label filter — and a filter keyed on this attempt's transaction id would be a
// filter that can never match, which is worse than none because it reads as a check.
func gpuConsumersOn(pods []corev1.Pod, node string) (consumers []gpuConsumer, onNode int) {
	for i := range pods {
		p := &pods[i]
		if p.Spec.NodeName != node {
			continue
		}
		onNode++
		if !holdsDevices(p) {
			continue
		}
		n := podGPURequest(&p.Spec)
		if n == 0 {
			continue
		}
		consumers = append(consumers, gpuConsumer{
			Namespace:   p.Namespace,
			Name:        p.Name,
			Phase:       string(p.Status.Phase),
			Terminating: p.DeletionTimestamp != nil,
			GPUs:        n,
		})
	}
	return consumers, onNode
}

// nodeReady reports whether the node's Ready condition is True.
//
// A missing condition is not ready. The zero value of a status this decision rests on must fail toward the
// refusal, for the same reason absenceUnknown holds the worker in teardown: a node nobody could classify is
// not a node to measure on.
func nodeReady(n *corev1.Node) bool {
	for _, c := range n.Status.Conditions {
		if c.Type == corev1.NodeReady {
			return c.Status == corev1.ConditionTrue
		}
	}
	return false
}

// qualify decides whether the acquired worker is a machine this run may measure on, and returns what it saw
// either way.
//
// The observation is returned alongside the refusal deliberately: the record has to carry what was observed
// rather than only that something was wrong, or the operator is left with a sentence and the next reader with
// nothing. Every failing condition is reported together rather than the first one alone, because they are
// independent facts about one node and an operator who fixes a cordon only to be told about a leftover Pod on
// the next run has been made to pay for two round trips against a cluster this could have described in one.
//
// The node's taints are deliberately not examined. This run installed a NoSchedule taint on this node moments
// ago, so a check for "no taints" would refuse every run on the marker the run itself put there; and the
// question a taint could answer — will something new land here — is already answered by the acquisition. What
// a taint cannot answer, and what is asked here instead, is what is on the node already.
func qualify(n *corev1.Node, pods []corev1.Pod, req gpuRequirement) (qualification, error) {
	allocatable := n.Status.Allocatable[gpuResourceName]
	consumers, onNode := gpuConsumersOn(pods, n.Name)
	q := qualification{
		Node:            n.Name,
		NodeUID:         string(n.UID),
		AllocatableGPU:  allocatable.Value(),
		RequiredGPU:     req.Total,
		RequiredFrom:    req.From,
		RequiredBoundBy: req.BoundBy,
		Ready:           nodeReady(n),
		Schedulable:     !n.Spec.Unschedulable,
		PodsOnNode:      onNode,
		GPUConsumers:    consumers,
	}

	var failed []string
	if !q.Ready {
		failed = append(failed, "its Ready condition is not True")
	}
	if !q.Schedulable {
		failed = append(failed, "it is cordoned (spec.unschedulable), so nothing this run submits can land on it")
	}
	if q.AllocatableGPU < req.Total {
		failed = append(failed, fmt.Sprintf(
			"it advertises %d allocatable %s and this run needs %d, bound by the %s (%s); the arm would "+
				"complete against a smaller machine and report the contrast it never produced",
			q.AllocatableGPU, gpuResourceName, req.Total, req.BoundBy, req.From))
	}
	if len(consumers) > 0 {
		// Every field below came out of the apiserver and this sentence is printed straight to an operator's
		// terminal beside commands they are being invited to run, so the names are quoted for the reason
		// residueNote quotes everything it decoded: reading a string out of the cluster does not make it safe to
		// splice into instructions.
		var b strings.Builder
		fmt.Fprintf(&b, "%d Pod(s) already hold %s on it, which the ownership taint does not evict:",
			len(consumers), gpuResourceName)
		for _, c := range consumers {
			state := c.Phase
			if c.Terminating {
				// Named separately from the phase because a Terminating Pod resolves itself and a Running one does
				// not, and the operator's next move differs entirely between the two.
				state += ", terminating"
			}
			fmt.Fprintf(&b, "\n    %q/%q (%s, %d gpu)", c.Namespace, c.Name, state, c.GPUs)
		}
		failed = append(failed, b.String())
	}
	if len(failed) == 0 {
		return q, nil
	}
	return q, fmt.Errorf("worker %s is not a machine this run can measure on:\n  - %s",
		n.Name, strings.Join(failed, "\n  - "))
}

// qualifyWorker reads the cluster and applies qualify to what it finds.
//
// It returns the observation even when it refuses, so run() can carry it into the record; it returns nil only
// when the read itself failed, because a qualification built from a failed read would be a document full of
// zero values claiming a node advertises nothing and carries no Pods.
//
// Pods are listed cluster-wide and filtered here rather than through a spec.nodeName field selector. The
// local comparison is what decides either way — a server-side selector this code cannot verify would still
// have to be re-checked against each returned Pod — so the selector would add a dependency without changing
// a verdict, on a lab cluster of a few dozen Pods. The RBAC is the same either way: a field-selected List of
// Pods still requires list on pods at cluster scope, which is what this adds to whatever credential the
// runner uses.
func qualifyWorker(ctx context.Context, c client.Client, nodeName string,
	req gpuRequirement) (*qualification, error) {
	var n corev1.Node
	if err := c.Get(ctx, client.ObjectKey{Name: nodeName}, &n); err != nil {
		return nil, fmt.Errorf("get node %s: %w", nodeName, err)
	}
	var pods corev1.PodList
	if err := c.List(ctx, &pods); err != nil {
		// Refused rather than skipped. A run that could not see the Pods on its worker has not established the
		// premise it is about to measure under, and treating an unreadable cluster as a clean one is the exact
		// substitution — absence of evidence for evidence of absence — that this gate exists to stop.
		return nil, fmt.Errorf("list pods to check %s for foreign GPU consumers: %w", nodeName, err)
	}
	q, err := qualify(&n, pods.Items, req)
	return &q, err
}
