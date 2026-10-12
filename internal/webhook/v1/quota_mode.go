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

package v1

import (
	"context"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// gpuRequestsResource is the ResourceQuota key that caps how many devices a namespace may request.
//
// Duplicated from internal/controller for the reason kueueQueueLabel is: a webhook importing the controller
// package to read one string would drag the whole reconciler into the admission binary's dependency graph.
const gpuRequestsResource = corev1.ResourceName("requests.nvidia.com/gpu")

// quotaName is how GPUQuotaPolicyReconciler names the ResourceQuota it syncs.
//
// Duplicated for the same reason, and it must not drift: a guard that looks for a differently named object
// finds nothing and concludes there is no cap, which is the reading that refuses legitimate work.
// TestTheQuotaNameMatchesTheController holds the two together.
func quotaName(policyName string) string { return "gpuquota-" + policyName }

// meteredByResourceQuota reports whether this namespace's GPU budget is held by a ResourceQuota rather than
// by a Kueue ClusterQueue, and that the cap is one Kubernetes will actually charge a new Pod against.
//
// The queue-name label is what makes a workload visible to Kueue's accounting, so demanding it is right
// exactly where Kueue is the authority. Where a GPUQuotaPolicy leaves trainingQuota off, the controller does
// the opposite: it KEEPS the namespace ResourceQuota capping requests.nvidia.com/gpu
// (internal/controller/gpuquotapolicy_controller.go, syncNamespaceResourceQuota) and creates no queues at all
// (kueue_quota.go deletes them). Work in such a namespace is charged by the ResourceQuota at creation, whoever
// creates it, and refusing it for carrying no queue label refused work the platform had agreed to count.
//
// It answers true only when every one of these holds, and each is a way the answer was once wrong or could be:
//
//   - No policy over this namespace sets trainingQuota. Two policies may target one namespace, so a mixed
//     namespace is one where Kueue is an authority for something, and the queue requirement stays.
//   - No policy over it is being deleted, because deleting a policy deletes its ResourceQuota.
//   - EVERY ResourceQuota-mode policy's quota exists, not merely one. Policies are conjunctive and the
//     strictest wins; admitting on the first quota found would let a lax ceiling stand in while a strict
//     one is still being created.
//   - Each quota is controlled by its policy, so a foreign object squatting on the expected name, which the
//     controller refuses to adopt, cannot stand in for the policy's ceiling.
//   - Each quota is unscoped. A scoped quota charges only the Pods its scopes select, and this function does
//     not evaluate scopes against a Pod, so a scoped one could admit a Pod nothing then charges.
//   - Each quota's status.hard already carries the GPU key at the value spec.hard asks for. Kubernetes' quota
//     admission matches resources against status.hard, which the API server clears at creation and the
//     quota controller fills in afterwards; until then a GPU Pod does not match the quota and is charged to
//     nothing.
//
// Every read error is returned, never swallowed. The callers fail closed on it, for the reason the webhook's
// failurePolicy is Fail: a guard that stops applying when a read fails admits exactly what it exists to
// refuse, invisibly.
//
// What it cannot see is a change after it answers: a policy created, a quota deleted or a mode switched
// between this read and the Pod's persistence, or a later switch to trainingQuota, which deletes the quota
// without moving the Pods it already admitted into Kueue. Those are lifecycle gaps of the policy, not of this
// read, and no second read here would close them.
func meteredByResourceQuota(ctx context.Context, reader client.Reader, namespace string) (bool, error) {
	if reader == nil {
		return false, fmt.Errorf("no reader wired to consult %q's quota mode", namespace)
	}

	var policies platformv1.GPUQuotaPolicyList
	if err := reader.List(ctx, &policies); err != nil {
		return false, fmt.Errorf("list GPUQuotaPolicy while deciding %q's quota mode: %w", namespace, err)
	}

	var resourceQuotaOnly []platformv1.GPUQuotaPolicy
	for i := range policies.Items {
		p := policies.Items[i]
		if p.Spec.TargetNamespace != namespace {
			continue
		}
		if p.Spec.TrainingQuota || !p.DeletionTimestamp.IsZero() {
			return false, nil
		}
		resourceQuotaOnly = append(resourceQuotaOnly, p)
	}
	if len(resourceQuotaOnly) == 0 {
		// No policy governs this namespace through a ResourceQuota. Nothing here says the work is metered.
		return false, nil
	}

	for i := range resourceQuotaOnly {
		p := &resourceQuotaOnly[i]
		var rq corev1.ResourceQuota
		key := client.ObjectKey{Name: quotaName(p.Name), Namespace: namespace}
		switch err := reader.Get(ctx, key, &rq); {
		case apierrors.IsNotFound(err):
			return false, nil
		case err != nil:
			return false, fmt.Errorf("read ResourceQuota %s while deciding %q's quota mode: %w", key, namespace, err)
		}
		if !chargesEveryGPUPod(&rq, p) {
			return false, nil
		}
	}
	return true, nil
}

// chargesEveryGPUPod reports whether Kubernetes' quota admission will charge any new GPU Pod in its namespace
// against rq, the ResourceQuota policy p owns; see meteredByResourceQuota for why each condition is here.
func chargesEveryGPUPod(rq *corev1.ResourceQuota, p *platformv1.GPUQuotaPolicy) bool {
	if !rq.DeletionTimestamp.IsZero() || !metav1.IsControlledBy(rq, p) {
		return false
	}
	if len(rq.Spec.Scopes) > 0 || rq.Spec.ScopeSelector != nil {
		return false
	}
	want, capped := rq.Spec.Hard[gpuRequestsResource]
	if !capped {
		return false
	}
	have, initialised := rq.Status.Hard[gpuRequestsResource]
	return initialised && have.Cmp(want) == 0
}
