package v1

import (
	"strings"
	"testing"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	"sigs.k8s.io/controller-runtime/pkg/client"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// Through a real apiserver with config/webhook/manifests.yaml installed, because the handler is only reached if the
// manifest names UPDATE: issue #568 was measured exactly this way, with both edits accepted while the guard ran on create only.
// Mutation that turns it red: drop UPDATE from the hand-written manifest's vgpujob rule.
func TestApiserverRefusesTheEditsThatStepAroundTheJobGuard(t *testing.T) {
	ctx, c := startAdmissionEnv(t)
	ns := &corev1.Namespace{}
	ns.Name = "team-update"
	ns.Labels = map[string]string{platformv1.QuotaEnforcedLabel: platformv1.QuotaEnforcedValue}
	if err := c.Create(ctx, ns); err != nil {
		t.Fatalf("create namespace: %v", err)
	}
	suspended := func(name string, devices int64, queue string) *batchv1.Job {
		j := &batchv1.Job{}
		j.Name, j.Namespace = name, ns.Name
		if queue != "" {
			j.Labels = map[string]string{kueueQueueLabel: queue}
		}
		j.Spec.Suspend = new(true)
		j.Spec.Template = minimalPodTemplate()
		j.Spec.Template.Spec.RestartPolicy = corev1.RestartPolicyNever
		setDevices(j, devices)
		return j
	}
	refused := func(what string, err error) {
		t.Helper()
		if err == nil || !strings.Contains(err.Error(), "vgpujob.kb.io") {
			t.Errorf("%s: want the Job guard's refusal, got %v", what, err)
		}
	}

	plain := suspended("plain", 0, "")
	if err := c.Create(ctx, plain); err != nil {
		t.Fatalf("create a Job with no device: %v", err)
	}
	setDevices(plain, 1)
	// Apiservers before 1.36 keep a suspended Job's template resources immutable and refuse this edit themselves, so
	// there it cannot step around the guard; from 1.36 they allow it and only the guard stands in the way (issue #576).
	// Either refusal is the property that matters; which one this apiserver gave is logged.
	if err := c.Update(ctx, plain); err == nil || !strings.Contains(err.Error(), "field is immutable") {
		refused("a GPU added to a suspended Job with no queue", err)
	} else {
		t.Logf("this apiserver refuses a template resource edit on a suspended Job itself: %v", err)
	}

	queued := suspended("queued", 1, "team-update-queue")
	if err := c.Create(ctx, queued); err != nil {
		t.Fatalf("create a queued GPU Job: %v", err)
	}
	// Labels are mutable on every apiserver version, so this edit always reaches the admission chain: it is what pins
	// the manifest's UPDATE rule whichever envtest runs.
	delete(queued.Labels, kueueQueueLabel)
	refused("the queue label dropped from a suspended GPU Job", c.Update(ctx, queued))

	// The guard on UPDATE must not get in the way of an update that changes neither, such as Kueue's own.
	fresh := &batchv1.Job{}
	if err := c.Get(ctx, client.ObjectKeyFromObject(queued), fresh); err != nil {
		t.Fatalf("read the queued Job back: %v", err)
	}
	fresh.Annotations = map[string]string{"note": "touched"}
	if err := c.Update(ctx, fresh); err != nil {
		t.Errorf("an update that changes neither devices nor queue was refused: %v", err)
	}
}

// setDevices sets the Job template's GPU limit, the field the guard counts, or clears it for zero.
func setDevices(j *batchv1.Job, devices int64) {
	r := &j.Spec.Template.Spec.Containers[0].Resources
	if devices == 0 {
		r.Limits, r.Requests = nil, nil
		return
	}
	q := *resource.NewQuantity(devices, resource.DecimalSI)
	r.Limits = corev1.ResourceList{gpuResource: q}
	r.Requests = corev1.ResourceList{gpuResource: q}
}
