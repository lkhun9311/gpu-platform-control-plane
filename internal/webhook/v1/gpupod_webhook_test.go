package v1

import (
	"context"
	"encoding/json"
	admissionv1 "k8s.io/api/admission/v1"
	authenticationv1 "k8s.io/api/authentication/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"
	"strings"
	"testing"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

// gpuPod builds a Pod asking for n devices, with whatever owner and annotations the spec needs.
func gpuPod(n int64, mutate func(*corev1.Pod)) *corev1.Pod {
	p := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "p1", Namespace: "team-a"},
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{{
				Name:  "trainer",
				Image: "trainer:v1",
				Resources: corev1.ResourceRequirements{
					Limits: corev1.ResourceList{gpuResource: *resource.NewQuantity(n, resource.DecimalSI)},
				},
			}},
		},
	}
	if mutate != nil {
		mutate(p)
	}
	return p
}

// ownedBy attaches a controlling Job ownerReference, as the Job controller does.
func ownedBy(name string) func(*corev1.Pod) {
	return func(p *corev1.Pod) {
		yes := true
		p.OwnerReferences = []metav1.OwnerReference{{
			APIVersion: batchv1.SchemeGroupVersion.String(), Kind: "Job",
			Name: name, UID: "job-uid", Controller: &yes,
		}}
	}
}

func gpuValidator(t *testing.T, objs ...client.Object) *GPUPodValidator {
	t.Helper()
	return &GPUPodValidator{
		Reader:  fake.NewClientBuilder().WithScheme(scheme.Scheme).WithObjects(objs...).Build(),
		decoder: admission.NewDecoder(scheme.Scheme),
	}
}

// ask puts a Pod through the handler as `user` would.
//
// The user is a parameter and not a constant because it is the only thing in an admission request a tenant
// cannot forge, and every decision below turns on it.
func ask(t *testing.T, v *GPUPodValidator, user string, pod *corev1.Pod) admission.Response {
	t.Helper()
	raw, err := json.Marshal(pod)
	if err != nil {
		t.Fatalf("marshal pod: %v", err)
	}
	return v.Handle(context.Background(), admission.Request{
		AdmissionRequest: admissionv1.AdmissionRequest{
			Operation: admissionv1.Create,
			UserInfo:  authenticationv1.UserInfo{Username: user},
			Object:    runtime.RawExtension{Raw: raw},
		},
	})
}

// tenantUser is an ordinary namespace-scoped identity: it can create Pods and Jobs and nothing else.
const tenantUser = "system:serviceaccount:team-a:default"

func queuedJob(name, queue string) *batchv1.Job {
	j := &batchv1.Job{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "team-a"}}
	if queue != "" {
		j.Labels = map[string]string{kueueQueueLabel: queue}
	}
	return j
}

// The bypass itself, demonstrated on a live cluster before this guard existed: a Pod asking for two devices
// in a governed namespace, owned by nothing, was created and Running with no Kueue Workload anywhere.
func TestABareGPUPodIsRefused(t *testing.T) {
	v := gpuValidator(t)
	res := ask(t, v, tenantUser, gpuPod(2, nil))
	if res.Allowed {
		t.Fatal("a Pod took two devices without belonging to any queue")
	}
	for _, want := range []string{"MLTrainingJob", kueueQueueLabel} {
		if !strings.Contains(res.Result.Message, want) {
			t.Fatalf("the refusal does not mention %q, so it names a rule without a remedy: %s", want, res.Result.Message)
		}
	}
}

// The bypass the FIRST version of this guard did not close, found by attacking it rather than by reasoning
// about it: a tenant writes an ownerReference naming a real, queued Job, and the guard reads it as evidence.
//
// ownerReferences are supplied by whoever creates the object and Kubernetes does not check that the named
// owner had anything to do with it. One kubectl apply obtained two devices.
//
// Mutation that turns this red: drop the requester check and trust the ownerReference again.
func TestAForgedOwnerReferenceIsRefused(t *testing.T) {
	v := gpuValidator(t, queuedJob("train-1", "team-a-queue"))
	res := ask(t, v, tenantUser, gpuPod(2, ownedBy("train-1")))
	if res.Allowed {
		t.Fatal("a tenant obtained devices by naming a queued Job it did not create")
	}
	if !strings.Contains(res.Result.Message, tenantUser) {
		t.Fatalf("the refusal does not name who asked, which is the whole basis of the decision: %s",
			res.Result.Message)
	}
}

// The same Pod, presented by the Job controller, is the legitimate path.
//
// This is also the case a Pod-level label check would have broken: BuildJob puts the queue label on the JOB,
// and the Job controller creates Pods from spec.template, which carries no such label.
//
// Mutation that turns this red: look for the label on the Pod instead of on its owner.
func TestAPodFromAQueuedJobIsAdmitted(t *testing.T) {
	v := gpuValidator(t, queuedJob("train-1", "team-a-queue"))
	res := ask(t, v, jobControllerUser, gpuPod(1, ownedBy("train-1")))
	if !res.Allowed {
		t.Fatalf("refused a Pod the Job controller created for a queued Job: %s", res.Result.Message)
	}
	if len(res.Warnings) != 0 {
		t.Fatalf("an ordinary training Pod produced warnings: %v", res.Warnings)
	}
}

// A Job with no queue label is not on the quota path either, however it was created.
func TestAPodFromAnUnqueuedJobIsRefused(t *testing.T) {
	v := gpuValidator(t, queuedJob("raw-1", ""))
	if ask(t, v, jobControllerUser, gpuPod(1, ownedBy("raw-1"))).Allowed {
		t.Fatal("a Job outside every queue was allowed to take a device through its Pod")
	}
}

// Even from the Job controller, an owner that does not exist is not evidence.
func TestAPodNamingAJobThatDoesNotExistIsRefused(t *testing.T) {
	v := gpuValidator(t)
	if ask(t, v, jobControllerUser, gpuPod(1, ownedBy("ghost"))).Allowed {
		t.Fatal("a Pod was admitted on an ownerReference to a Job nobody could find")
	}
}

// Pods with no device request are the overwhelming majority and must not pay for this guard, nor be able to
// fail it — including ones a tenant creates directly.
func TestAPodWithNoDeviceRequestIsUntouched(t *testing.T) {
	v := gpuValidator(t)
	res := ask(t, v, tenantUser, gpuPod(0, func(p *corev1.Pod) {
		p.Spec.Containers[0].Resources.Limits = corev1.ResourceList{}
	}))
	if !res.Allowed {
		t.Fatalf("a Pod asking for no device was refused: %s", res.Result.Message)
	}
}

// The exemption is for cluster infrastructure, and a tenant can annotate their own Pod. Honoured for anyone,
// it is the bypass with an extra step.
//
// Mutation that turns this red: honour the annotation whoever sets it.
func TestATenantCannotExemptItself(t *testing.T) {
	v := gpuValidator(t)
	res := ask(t, v, tenantUser, gpuPod(4, func(p *corev1.Pod) {
		p.Annotations = map[string]string{QuotaExemptAnnotation: "please"}
	}))
	if res.Allowed {
		t.Fatal("a tenant annotated its way out of the budget")
	}
}

// A kube-system service account may, and it announces itself: a device leaving the budget silently is the
// same hole this guard closes, moved behind an annotation.
func TestASystemComponentMayBeExemptAndIsWarnedAbout(t *testing.T) {
	v := gpuValidator(t)
	res := ask(t, v, "system:serviceaccount:kube-system:device-plugin", gpuPod(4, func(p *corev1.Pod) {
		p.Annotations = map[string]string{QuotaExemptAnnotation: "device-plugin"}
	}))
	if !res.Allowed {
		t.Fatalf("refused an exemption held by cluster infrastructure: %s", res.Result.Message)
	}
	if len(res.Warnings) == 0 {
		t.Fatal("an exempt Pod took devices outside the budget and said nothing")
	}
}

// A device request can arrive as a limit, as a request, or on an init container, and BuildJob sets only the
// limit. A guard that read one of the three would be bypassed by writing the other.
func TestEveryShapeOfDeviceRequestIsCounted(t *testing.T) {
	for _, row := range []struct {
		name   string
		mutate func(*corev1.Pod)
	}{
		{"limit only", nil},
		{"request only", func(p *corev1.Pod) {
			p.Spec.Containers[0].Resources.Limits = corev1.ResourceList{}
			p.Spec.Containers[0].Resources.Requests = corev1.ResourceList{
				gpuResource: *resource.NewQuantity(1, resource.DecimalSI),
			}
		}},
		{"init container", func(p *corev1.Pod) {
			p.Spec.Containers[0].Resources.Limits = corev1.ResourceList{}
			p.Spec.InitContainers = []corev1.Container{{
				Name: "warm", Image: "busybox",
				Resources: corev1.ResourceRequirements{
					Limits: corev1.ResourceList{gpuResource: *resource.NewQuantity(1, resource.DecimalSI)},
				},
			}}
		}},
	} {
		t.Run(row.name, func(t *testing.T) {
			v := gpuValidator(t)
			if ask(t, v, tenantUser, gpuPod(1, row.mutate)).Allowed {
				t.Fatalf("a device requested as %s was not counted, so the guard is bypassed by writing it that way",
					row.name)
			}
		})
	}
}

// A read that fails must refuse, for the same reason the webhook's failurePolicy is Fail.
func TestALookupFailureRefusesAndSaysWhy(t *testing.T) {
	v := &GPUPodValidator{Reader: erroringClient{}, decoder: admission.NewDecoder(scheme.Scheme)}
	res := ask(t, v, jobControllerUser, gpuPod(1, ownedBy("train-1")))
	if res.Allowed {
		t.Fatal("admitted a device request without establishing whether it was queued")
	}
	if !strings.Contains(res.Result.Message, "unreachable") {
		t.Fatalf("the refusal does not carry the cause, so an outage reads as a policy decision: %s",
			res.Result.Message)
	}
}
