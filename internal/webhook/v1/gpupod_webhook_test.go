package v1

import (
	"context"
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
	return &GPUPodValidator{Reader: fake.NewClientBuilder().WithScheme(scheme.Scheme).WithObjects(objs...).Build()}
}

func queuedJob(name, queue string) *batchv1.Job {
	j := &batchv1.Job{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "team-a"}}
	if queue != "" {
		j.Labels = map[string]string{kueueQueueLabel: queue}
	}
	return j
}

// The bypass itself, which was demonstrated on a live cluster before this guard existed: a Pod asking for two
// devices in a governed namespace, owned by nothing, was created and Running with no Kueue Workload anywhere.
//
// Mutation that turns this red: return nil from ValidateCreate.
func TestABareGPUPodIsRefused(t *testing.T) {
	v := gpuValidator(t)
	_, err := v.ValidateCreate(context.Background(), gpuPod(2, nil))
	if err == nil {
		t.Fatal("a Pod took two devices without belonging to any queue")
	}
	// The message has to say what to do, because the person who hits this is a tenant who thinks they are
	// allowed to run a Pod.
	for _, want := range []string{"MLTrainingJob", kueueQueueLabel, QuotaExemptAnnotation} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("the refusal does not mention %q, so it names a rule without a remedy: %v", want, err)
		}
	}
}

// The case that makes the guard usable rather than merely strict, and the one a Pod-level label check would
// have broken: BuildJob puts the queue label on the JOB, and the Job controller creates Pods from
// spec.template, which carries no such label. Reading the Pod alone would refuse every training Pod this
// platform creates.
//
// Mutation that turns this red: look for the label on the Pod instead of on its owner.
func TestAPodFromAQueuedJobIsAdmitted(t *testing.T) {
	v := gpuValidator(t, queuedJob("train-1", "team-a-queue"))
	warnings, err := v.ValidateCreate(context.Background(), gpuPod(1, ownedBy("train-1")))
	if err != nil {
		t.Fatalf("refused a Pod created by a Job that is in a queue: %v", err)
	}
	if len(warnings) != 0 {
		t.Fatalf("an ordinary training Pod produced warnings: %v", warnings)
	}
}

// A Job with no queue label is not on the quota path either, however legitimate it looks.
func TestAPodFromAnUnqueuedJobIsRefused(t *testing.T) {
	v := gpuValidator(t, queuedJob("raw-1", ""))
	if _, err := v.ValidateCreate(context.Background(), gpuPod(1, ownedBy("raw-1"))); err == nil {
		t.Fatal("a Job outside every queue was allowed to take a device through its Pod")
	}
}

// An ownerReference is a field anyone can write. A Pod naming a Job that does not exist must not be trusted
// on the strength of the name alone.
//
// Mutation that turns this red: treat a NotFound owner as queued.
func TestAPodNamingAJobThatDoesNotExistIsRefused(t *testing.T) {
	v := gpuValidator(t)
	if _, err := v.ValidateCreate(context.Background(), gpuPod(1, ownedBy("ghost"))); err == nil {
		t.Fatal("a Pod was admitted on an ownerReference to a Job nobody could find")
	}
}

// Pods with no device request are the overwhelming majority and must not pay for this guard, nor be able to
// fail it.
func TestAPodWithNoDeviceRequestIsUntouched(t *testing.T) {
	v := gpuValidator(t)
	if _, err := v.ValidateCreate(context.Background(), gpuPod(0, func(p *corev1.Pod) {
		p.Spec.Containers[0].Resources.Limits = corev1.ResourceList{}
	})); err != nil {
		t.Fatalf("a Pod asking for no device was refused: %v", err)
	}
}

// The exemption is deliberate and must announce itself. A device that leaves the budget silently is the same
// hole this guard closes, moved behind an annotation.
//
// Mutation that turns this red: return no warning for an exempt Pod.
func TestAnExemptPodIsAdmittedWithAWarning(t *testing.T) {
	v := gpuValidator(t)
	warnings, err := v.ValidateCreate(context.Background(), gpuPod(4, func(p *corev1.Pod) {
		p.Annotations = map[string]string{QuotaExemptAnnotation: "device-plugin"}
	}))
	if err != nil {
		t.Fatalf("refused a Pod that was explicitly exempted: %v", err)
	}
	if len(warnings) == 0 {
		t.Fatal("an exempt Pod took devices outside the budget and said nothing")
	}
	if !strings.Contains(warnings[0], QuotaExemptAnnotation) {
		t.Fatalf("the warning does not name the annotation that allowed it: %v", warnings)
	}
}

// A device request can arrive as a limit, as a request, or on an init container, and BuildJob sets only the
// limit. A guard that read one of the three would be bypassed by writing the other.
//
// Mutation that turns this red: count only Requests, or skip InitContainers.
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
			if _, err := v.ValidateCreate(context.Background(), gpuPod(1, row.mutate)); err == nil {
				t.Fatalf("a device requested as %s was not counted, so the guard is bypassed by writing it that way",
					row.name)
			}
		})
	}
}

// A read that fails must refuse, for the same reason the webhook's failurePolicy is Fail: a guard that stops
// applying whenever the apiserver is briefly unreachable admits exactly what it exists to catch.
//
// Mutation that turns this red: treat a lookup error as "not queued" and fall through to the ordinary refusal
// — which would still refuse here, so the assertion is on the MESSAGE naming the cause.
func TestALookupFailureRefusesAndSaysWhy(t *testing.T) {
	v := &GPUPodValidator{Reader: erroringClient{}}
	_, err := v.ValidateCreate(context.Background(), gpuPod(1, ownedBy("train-1")))
	if err == nil {
		t.Fatal("admitted a device request without establishing whether it was queued")
	}
	if !strings.Contains(err.Error(), "unreachable") {
		t.Fatalf("the refusal does not carry the cause, so an outage reads as a policy decision: %v", err)
	}
}
