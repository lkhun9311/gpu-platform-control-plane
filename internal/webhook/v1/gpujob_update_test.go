package v1

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	admissionv1 "k8s.io/api/admission/v1"
	batchv1 "k8s.io/api/batch/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"
)

// askJobUpdate puts an update from old to updated through the handler against a reader built by reader.
func askJobUpdate(t *testing.T, old, updated *batchv1.Job, reader client.Reader) admission.Response {
	t.Helper()
	rawOld, err := json.Marshal(old)
	if err != nil {
		t.Fatalf("marshal old job: %v", err)
	}
	rawNew, err := json.Marshal(updated)
	if err != nil {
		t.Fatalf("marshal new job: %v", err)
	}
	v := &GPUJobValidator{Reader: reader, decoder: admission.NewDecoder(scheme.Scheme)}
	return v.Handle(context.Background(), admission.Request{
		Operation: admissionv1.Update, Namespace: updated.Namespace,
		Object: runtime.RawExtension{Raw: rawNew}, OldObject: runtime.RawExtension{Raw: rawOld}})
}

// emptyCluster is the Kueue-authority case: no policy meters the namespace, so the queue requirement stands.
func emptyCluster(t *testing.T) client.Reader {
	return fake.NewClientBuilder().WithScheme(testScheme(t)).Build()
}

// unreadable fails every read, so an update that is allowed against it was allowed without asking the cluster.
func unreadable(t *testing.T) client.Reader {
	broken := errors.New("the apiserver is not answering")
	return fake.NewClientBuilder().WithScheme(testScheme(t)).WithInterceptorFuncs(interceptor.Funcs{
		Get: func(context.Context, client.WithWatch, client.ObjectKey, client.Object, ...client.GetOption) error {
			return broken
		},
		List: func(context.Context, client.WithWatch, client.ObjectList, ...client.ListOption) error { return broken },
	}).Build()
}

// The apiserver lets a suspended Job gain a GPU after create; the result is the GPU Job with no queue the create path refuses.
// Mutation that turns it red: leave the guard on CREATE only, or return Allowed for every update.
func TestAGPUAddedToAJobWithNoQueueIsRefusedOnUpdate(t *testing.T) {
	old := gpuJob(0, func(j *batchv1.Job) { delete(j.Labels, kueueQueueLabel) })
	updated := gpuJob(1, func(j *batchv1.Job) { delete(j.Labels, kueueQueueLabel) })
	if resp := askJobUpdate(t, old, updated, emptyCluster(t)); resp.Allowed {
		t.Fatal("a GPU added to a Job with no queue label was admitted on update")
	}
}

// Removing the queue label from a GPU Job is the same state reached the other way.
// Mutation that turns it red: compare only the device count.
func TestDroppingTheQueueLabelOfAGPUJobIsRefusedOnUpdate(t *testing.T) {
	old := gpuJob(1, nil)
	updated := gpuJob(1, func(j *batchv1.Job) { delete(j.Labels, kueueQueueLabel) })
	resp := askJobUpdate(t, old, updated, emptyCluster(t))
	if resp.Allowed {
		t.Fatal("dropping the queue label of a GPU Job was admitted on update")
	}
	if create := askJob(t, updated); create.Result.Message != resp.Result.Message {
		t.Fatalf("the update is refused in other words than the create:\n update: %s\n create: %s", resp.Result.Message, create.Result.Message)
	}
}

// An update that changes neither the devices nor the queue is not judged again and reads nothing, so Kueue unsuspending
// a Job is never refused because the apiserver did not answer a read the decision did not need.
// Mutation that turns it red: re-check every update.
func TestAnUpdateThatChangesNeitherDevicesNorQueuePassesWithoutReading(t *testing.T) {
	// A GPU Job with no queue label, as one admitted under a ResourceQuota policy that is gone since: re-judged, it would fail.
	old := gpuJob(1, func(j *batchv1.Job) { delete(j.Labels, kueueQueueLabel) })
	updated := gpuJob(1, func(j *batchv1.Job) {
		delete(j.Labels, kueueQueueLabel)
		j.Annotations = map[string]string{"note": "unsuspended"}
	})
	if resp := askJobUpdate(t, old, updated, unreadable(t)); !resp.Allowed {
		t.Fatalf("an update that changed neither devices nor queue was refused: %s", resp.Result.Message)
	}
}
