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
	"errors"
	"strings"
	"testing"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// The defect these tests pin: a tenant that never asked for Kueue could not submit a GPU Job at all.
//
// GPUQuotaPolicyReconciler labels the namespace gpu-quota-enforced whatever the policy says, and both guards
// select on that label. With trainingQuota off it then deletes the queues and keeps the namespace
// ResourceQuota capping requests.nvidia.com/gpu. So the Job guard demanded a queue label in a namespace
// where no queue exists, the Pod guard refused the Pod for the same reason, and the policy reported Synced
// throughout. Nothing was over-admitted; ordinary metered work was refused with no route open to the tenant.

// policy returns a GPUQuotaPolicy targeting ns, in whichever mode.
func policy(name, ns string, training bool) *platformv1.GPUQuotaPolicy {
	return &platformv1.GPUQuotaPolicy{
		Name: name, Namespace: ns, UID: types.UID(name + "-uid"),
		Spec: platformv1.GPUQuotaPolicySpec{
			TargetNamespace: ns,
			TrainingQuota:   training,
		},
	}
}

// gpuQuotaFor builds the ResourceQuota the controller syncs for a ResourceQuota-mode policy, in the state
// Kubernetes leaves it once the quota controller has run: owned by its policy, and with status.hard filled in.
//
// It used to carry neither, so every test of a "metered" namespace passed a quota Kubernetes would not yet
// charge anything against, and no test could tell an initialised quota from a squatter.
func gpuQuotaFor(policyName, ns string, capped bool) *corev1.ResourceQuota {
	hard := corev1.ResourceList{}
	if capped {
		hard[gpuRequestsResource] = *resource.NewQuantity(4, resource.DecimalSI)
	} else {
		// A quota that exists but caps something else is not a GPU ceiling.
		hard[corev1.ResourceName("pods")] = *resource.NewQuantity(10, resource.DecimalSI)
	}
	yes := true
	return &corev1.ResourceQuota{
		Name: quotaName(policyName), Namespace: ns,
		OwnerReferences: []metav1.OwnerReference{{
			APIVersion: platformv1.GroupVersion.String(), Kind: "GPUQuotaPolicy",
			Name: policyName, UID: types.UID(policyName + "-uid"), Controller: &yes,
		}},
		Spec:   corev1.ResourceQuotaSpec{Hard: hard},
		Status: corev1.ResourceQuotaStatus{Hard: hard.DeepCopy()},
	}
}

// unqueuedJob is a GPU Job with no queue label, which is all a ResourceQuota-mode tenant can write.
func unqueuedJob() *batchv1.Job {
	return gpuJob(2, func(j *batchv1.Job) { j.Labels = nil })
}

// Mutation that turns this red: delete the meteredByResourceQuota branch from the Job guard, or make it
// return false unconditionally.
func TestAnUnqueuedGPUJobIsAdmittedWhereAResourceQuotaMetersIt(t *testing.T) {
	res := askJob(t, unqueuedJob(),
		policy("team-a-quota", "team-a", false),
		gpuQuotaFor("team-a-quota", "team-a", true))
	if !res.Allowed {
		t.Fatalf("refused the only shape a ResourceQuota-mode tenant can submit: %s", res.Result.Message)
	}
}

// The Pod half. Refusing here would move the refusal rather than remove it: the Job controller creates the
// Pod, and the Pod carries no queue label because the Job carries none either.
//
// Mutation that turns this red: delete the meteredByResourceQuota branch from the Pod guard.
func TestAPodFromAnUnqueuedJobIsAdmittedWhereAResourceQuotaMetersIt(t *testing.T) {
	job := &batchv1.Job{Name: "train-1", Namespace: "team-a"}
	v := gpuValidator(t, job,
		policy("team-a-quota", "team-a", false),
		gpuQuotaFor("team-a-quota", "team-a", true))
	res := ask(t, v, jobControllerUser, gpuPod(1, ownedBy("train-1")))
	if !res.Allowed {
		t.Fatalf("refused a Pod the namespace ResourceQuota already counts: %s", res.Result.Message)
	}
}

// One policy with trainingQuota set makes Kueue an authority over this namespace, and two policies may
// target one namespace. Admitting on the first false one found would hand a Kueue-governed namespace an
// unmetered path.
//
// Mutation that turns this red: return true on the first ResourceQuota-mode policy instead of refusing the
// whole namespace when any policy sets trainingQuota.
func TestAMixedNamespaceKeepsTheQueueRequirement(t *testing.T) {
	res := askJob(t, unqueuedJob(),
		policy("team-a-quota", "team-a", false),
		gpuQuotaFor("team-a-quota", "team-a", true),
		policy("team-a-training", "team-a", true))
	if res.Allowed {
		t.Fatal("a namespace Kueue governs admitted a Job no queue would ever charge")
	}
	if !strings.Contains(res.Result.Message, kueueQueueLabel) {
		t.Fatalf("the refusal does not name the label the tenant must add: %s", res.Result.Message)
	}
}

// A policy saying false while its ResourceQuota is missing describes a namespace with no ceiling at all.
// That is the state the guard exists to refuse, not a licence to admit.
//
// Mutation that turns this red: trust policy.Spec.TrainingQuota alone and skip the ResourceQuota read.
func TestAMissingResourceQuotaIsNotAMeteredNamespace(t *testing.T) {
	res := askJob(t, unqueuedJob(), policy("team-a-quota", "team-a", false))
	if res.Allowed {
		t.Fatal("admitted a GPU Job into a namespace with neither a queue nor a ceiling")
	}
}

// A ResourceQuota that exists but caps something else is the same hole wearing the right name.
//
// Mutation that turns this red: check only that the ResourceQuota exists, not that it holds the GPU key.
func TestAQuotaWithoutTheGPUKeyIsNotAMeteredNamespace(t *testing.T) {
	res := askJob(t, unqueuedJob(),
		policy("team-a-quota", "team-a", false),
		gpuQuotaFor("team-a-quota", "team-a", false))
	if res.Allowed {
		t.Fatal("a ResourceQuota capping pods was read as a GPU ceiling")
	}
}

// A guard that stops applying when a read fails admits exactly what it exists to refuse, invisibly. The
// webhook's failurePolicy is Fail for the same reason.
//
// Mutation that turns this red: swallow the error from meteredByResourceQuota and treat it as false, or as
// true.
func TestAFailedQuotaModeReadRefusesRatherThanGuesses(t *testing.T) {
	// The owner Job reads back fine, so the guard reaches the quota-mode question and fails THERE.
	//
	// The first version of this test used erroringClient, whose Get fails — so tracesToAQueue errored first
	// and the quota-mode read was never reached. It passed while the branch it names was never executed,
	// which a mutation confirmed: swallowing the List error left the test green. Checking only !Allowed would
	// have hidden it even here, because swallowing the error as "not metered" still produces a refusal. The
	// assertion is therefore on the cause the refusal carries.
	job := &batchv1.Job{Name: "train-1", Namespace: "team-a"}
	v := &GPUPodValidator{
		Reader:  listErroringReader{fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(job).Build()},
		decoder: admission.NewDecoder(scheme.Scheme),
	}
	res := ask(t, v, jobControllerUser, gpuPod(1, ownedBy("train-1")))
	if res.Allowed {
		t.Fatal("admitted a device request without establishing how the namespace meters GPUs")
	}
	if !strings.Contains(res.Result.Message, "meters GPUs") {
		t.Fatalf("the refusal does not carry the cause, so an outage reads as a policy decision: %s",
			res.Result.Message)
	}
}

// listErroringReader answers Get from a real fake client and fails every List.
//
// The guards read one object by name and list policies; separating the two is what lets a test reach the
// second read with the first one working.
type listErroringReader struct{ client.Reader }

func (listErroringReader) List(_ context.Context, _ client.ObjectList, _ ...client.ListOption) error {
	return errors.New("apiserver unreachable")
}

// The ResourceQuota path is an accounting decision. Grace is not: a Pod admitted through it holds its device
// against a reclaiming owner exactly as long as one admitted through a queue.
//
// Mutation that turns this red: move the meteredByResourceQuota branch above the graceTooLong check in the
// Job guard, which is how the Pod guard's own header records this going wrong once already.
func TestTheResourceQuotaPathIsStillCappedOnGrace(t *testing.T) {
	long := int64(600)
	j := gpuJob(2, func(j *batchv1.Job) {
		j.Labels = nil
		j.Spec.Template.Spec.TerminationGracePeriodSeconds = &long
	})
	res := askJob(t, j,
		policy("team-a-quota", "team-a", false),
		gpuQuotaFor("team-a-quota", "team-a", true))
	if res.Allowed {
		t.Fatal("a Job admitted through the ResourceQuota path escaped the grace cap")
	}
	if !strings.Contains(res.Result.Message, "600") {
		t.Fatalf("the refusal does not name the grace that caused it: %s", res.Result.Message)
	}
}

// quotaName is duplicated from internal/controller, and a guard looking for a differently named object finds
// nothing and concludes there is no cap — which refuses legitimate work rather than admitting it, but
// refuses it for a reason no tenant can act on.
//
// Mutation that turns this red: change either copy of the prefix.
func TestTheQuotaNameMatchesTheController(t *testing.T) {
	if got := quotaName("team-a-quota"); got != "gpuquota-team-a-quota" {
		t.Fatalf("the webhook looks for %q; GPUQuotaPolicyReconciler syncs gpuquota-<policy>", got)
	}
}

// replicaSetController is the identity an InferenceDeployment's Pods are created under.
const replicaSetController = "system:serviceaccount:kube-system:replicaset-controller"

// meteredNamespace is a ResourceQuota-mode namespace whose quota Kubernetes is already charging against.
func meteredNamespace() []client.Object {
	return []client.Object{policy("team-a-quota", "team-a", false), gpuQuotaFor("team-a-quota", "team-a", true)}
}

// The defect this change exists for: a GPU serving Pod in the namespace the gateway routes to was refused,
// because only the Job controller's Pods were ever asked whether a ResourceQuota meters them.
//
// Mutation that turns this red: ask meteredByResourceQuota only for the Job controller again.
func TestAServingPodIsAdmittedWhereAResourceQuotaMetersIt(t *testing.T) {
	res := ask(t, gpuValidator(t, meteredNamespace()...), replicaSetController, gpuPod(1, nil))
	if !res.Allowed {
		t.Fatalf("refused a serving Pod the namespace ResourceQuota charges at creation: %s", res.Result.Message)
	}
}

// The requester adds nothing where the quota charges every Pod: a tenant's bare Pod is charged the same way.
func TestABarePodIsAdmittedWhereAResourceQuotaMetersIt(t *testing.T) {
	res := ask(t, gpuValidator(t, meteredNamespace()...), tenantUser, gpuPod(1, nil))
	if !res.Allowed {
		t.Fatalf("refused a Pod the namespace ResourceQuota charges at creation: %s", res.Result.Message)
	}
}

// Each case is a namespace that looks metered and is not, and a serving Pod must be refused in every one.
// The serving Pod rather than a Job's, because the Job controller's Pod also has the queue path to fall to,
// and a refusal here must come from the quota reading alone.
func TestAServingPodIsRefusedWhereNoQuotaChargesIt(t *testing.T) {
	now := metav1.Now()
	quota := func(mutate func(*corev1.ResourceQuota)) *corev1.ResourceQuota {
		q := gpuQuotaFor("team-a-quota", "team-a", true)
		mutate(q)
		return q
	}
	cases := []struct {
		name string
		// mutation names the change to meteredByResourceQuota that turns this case green.
		mutation string
		objs     []client.Object
	}{
		{"no policy at all", "admit when no policy is found", nil},
		{"a training policy", "ignore trainingQuota", []client.Object{policy("team-a-quota", "team-a", true)}},
		{"a mixed namespace", "admit on the first ResourceQuota-mode policy", append(meteredNamespace(),
			policy("team-a-training", "team-a", true))},
		{"the quota is missing", "skip a missing quota", []client.Object{policy("team-a-quota", "team-a", false)}},
		{"the quota caps something else", "check only that the quota exists", []client.Object{
			policy("team-a-quota", "team-a", false), gpuQuotaFor("team-a-quota", "team-a", false)}},
		{"status.hard not filled in yet", "read spec.hard alone", []client.Object{policy("team-a-quota", "team-a", false),
			quota(func(q *corev1.ResourceQuota) { q.Status = corev1.ResourceQuotaStatus{} })}},
		{"the GPU key added to spec.hard and not yet to status.hard", "read spec.hard alone", []client.Object{
			policy("team-a-quota", "team-a", false), quota(func(q *corev1.ResourceQuota) {
				q.Status.Hard = corev1.ResourceList{corev1.ResourcePods: *resource.NewQuantity(10, resource.DecimalSI)}
			})}},
		{"a scoped quota", "ignore spec.scopes", []client.Object{policy("team-a-quota", "team-a", false),
			quota(func(q *corev1.ResourceQuota) {
				q.Spec.Scopes = []corev1.ResourceQuotaScope{corev1.ResourceQuotaScopeNotBestEffort}
			})}},
		{"a quota with a scope selector", "ignore spec.scopeSelector", []client.Object{policy("team-a-quota", "team-a", false),
			quota(func(q *corev1.ResourceQuota) {
				q.Spec.ScopeSelector = &corev1.ScopeSelector{MatchExpressions: []corev1.ScopedResourceSelectorRequirement{{
					ScopeName: corev1.ResourceQuotaScopePriorityClass, Operator: corev1.ScopeSelectorOpIn,
					Values: []string{"restricted"},
				}}}
			})}},
		{"a quota the policy does not own", "skip the ownership check", []client.Object{policy("team-a-quota", "team-a", false),
			quota(func(q *corev1.ResourceQuota) { q.OwnerReferences = nil })}},
		{"a quota controlled by another object of the same name", "match the owner by name rather than UID",
			[]client.Object{policy("team-a-quota", "team-a", false), quota(func(q *corev1.ResourceQuota) {
				q.OwnerReferences[0].UID = "someone-else"
			})}},
		{"a quota the policy owns without controlling it", "accept any ownerReference", []client.Object{
			policy("team-a-quota", "team-a", false), quota(func(q *corev1.ResourceQuota) {
				q.OwnerReferences[0].Controller = nil
			})}},
		{"a quota being deleted", "ignore the quota's deletion", []client.Object{policy("team-a-quota", "team-a", false),
			quota(func(q *corev1.ResourceQuota) {
				q.DeletionTimestamp = &now
				q.Finalizers = []string{"test/hold"}
			})}},
		{"a policy being deleted", "ignore the policy's deletion", []client.Object{
			func() *platformv1.GPUQuotaPolicy {
				p := policy("team-a-quota", "team-a", false)
				p.DeletionTimestamp = &now
				p.Finalizers = []string{"test/hold"}
				return p
			}(), gpuQuotaFor("team-a-quota", "team-a", true)}},
		{"a training policy whose earlier quota still stands", "ignore trainingQuota", []client.Object{
			policy("team-a-quota", "team-a", true), gpuQuotaFor("team-a-quota", "team-a", true)}},
		{"a second policy's quota is missing", "admit on the first quota in place", append(meteredNamespace(),
			policy("team-a-strict", "team-a", false))},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			res := ask(t, gpuValidator(t, c.objs...), replicaSetController, gpuPod(1, nil))
			if res.Allowed {
				t.Fatalf("admitted a serving Pod nothing charges (would pass under: %s)", c.mutation)
			}
			if !strings.Contains(res.Result.Message, "no ResourceQuota") {
				t.Fatalf("refused for a reason other than the quota reading: %s", res.Result.Message)
			}
			// The Job guard asks the same question before a reservation is made, and must answer it the same way.
			res = askJob(t, unqueuedJob(), c.objs...)
			if res.Allowed {
				t.Fatalf("admitted an unqueued GPU Job nothing charges (would pass under: %s)", c.mutation)
			}
			if !strings.Contains(res.Result.Message, "no ResourceQuota") {
				t.Fatalf("the Job was refused for a reason other than the quota reading: %s", res.Result.Message)
			}
		})
	}
}

// A changed ceiling reaches status.hard after spec.hard. In between, Kubernetes still charges a Pod against the
// key status.hard carries, at its old value, so the Pod is charged and refusing it would only make the tenant
// retry.
//
// Mutation that turns this red: require status.hard to equal spec.hard.
func TestAPodIsAdmittedWhileAChangedCeilingPropagates(t *testing.T) {
	q := gpuQuotaFor("team-a-quota", "team-a", true)
	q.Status.Hard[gpuRequestsResource] = *resource.NewQuantity(8, resource.DecimalSI)
	res := ask(t, gpuValidator(t, policy("team-a-quota", "team-a", false), q), replicaSetController, gpuPod(1, nil))
	if !res.Allowed {
		t.Fatalf("refused a Pod Kubernetes charges against the ceiling still in status.hard: %s", res.Result.Message)
	}
}

// The new path is an accounting decision, and grace is not one; see TestTheResourceQuotaPathIsStillCappedOnGrace.
//
// Mutation that turns this red: move the meteredByResourceQuota branch above graceTooLong in the Pod guard.
func TestTheServingPathIsStillCappedOnGrace(t *testing.T) {
	long := int64(600)
	res := ask(t, gpuValidator(t, meteredNamespace()...), replicaSetController, gpuPod(1, func(p *corev1.Pod) {
		p.Spec.TerminationGracePeriodSeconds = &long
	}))
	if res.Allowed {
		t.Fatal("a serving Pod admitted through the ResourceQuota path escaped the grace cap")
	}
	if !strings.Contains(res.Result.Message, "600") {
		t.Fatalf("the refusal does not name the grace that caused it: %s", res.Result.Message)
	}
}
