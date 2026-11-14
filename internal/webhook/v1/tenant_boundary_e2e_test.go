package v1

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/yaml"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// What a tenant's own identity may do with the bundle in config/tenants/ and the policy in
// config/policy/tenant-reserved-metadata.yaml, asserted against a real apiserver with RBAC on.
//
// Both are read from disk, so the Role and the CEL that ship are the ones under test.
// The design is docs/superpowers/specs/2026-11-07-tenant-boundary-design.md.

const (
	boundaryTenant = "train-a"
	fencedNodesKey = "platform.lkhun9311.github.io/fenced-nodes"
)

// applyManifestFile creates every document in a repository manifest as the administrator.
//
// It goes through unstructured objects so a kind this file does not import is still created, and a field the
// apiserver refuses fails the test rather than being dropped by a typed decode.
func applyManifestFile(t *testing.T, ctx context.Context, c client.Client, rel ...string) {
	t.Helper()
	path := filepath.Join(append([]string{"..", "..", ".."}, rel...)...)
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	for doc := range strings.SplitSeq(string(b), "\n---\n") {
		var obj unstructured.Unstructured
		if err := yaml.Unmarshal([]byte(doc), &obj.Object); err != nil {
			t.Fatalf("decode a document of %s: %v", path, err)
		}
		if len(obj.Object) == 0 {
			continue
		}
		// The namespace's default ServiceAccount is created by a controller envtest does not run, so the bundle's
		// copy is the first; on a real cluster Argo CD applies over the existing one.
		if err := c.Create(ctx, &obj); err != nil {
			t.Fatalf("create %s %s from %s: %v", obj.GetKind(), obj.GetName(), path, err)
		}
	}
}

// tenantClient impersonates a user of the tenant's group, which is what the cluster's authenticator would map
// the tenant's people to.
func tenantClient(t *testing.T, cfg *rest.Config, groups ...string) client.Client {
	t.Helper()
	tc := rest.CopyConfig(cfg)
	tc.Impersonate = rest.ImpersonationConfig{UserName: "someone", Groups: groups}
	c, err := client.New(tc, client.Options{Scheme: scheme.Scheme})
	if err != nil {
		t.Fatalf("build the impersonating client: %v", err)
	}
	return c
}

// startTenantBoundaryEnv installs one rendered tenant and both tenant policies, and waits until each is enforcing.
func startTenantBoundaryEnv(t *testing.T) (context.Context, client.Client, client.Client) {
	t.Helper()
	ctx, admin, cfg := startAdmissionEnvWithConfig(t)
	applyManifestFile(t, ctx, admin, "config", "tenants", boundaryTenant, "bundle.yaml")
	applyManifestFile(t, ctx, admin, "config", "policy", "tenant-reserved-metadata.yaml")
	applyManifestFile(t, ctx, admin, "config", "policy", "tenant-claim-binding.yaml")
	tenant := tenantClient(t, cfg, "tenant:"+boundaryTenant)

	waitUntilRefused(t, fencedNodesKey, func() (client.Object, error) {
		j := boundaryJob("policy-liveness-probe", map[string]string{fencedNodesKey: "n1"})
		return j, tenant.Create(ctx, j)
	}, func(o client.Object) { _ = admin.Delete(ctx, o) })
	waitUntilRefused(t, "spec.volumeName", func() (client.Object, error) {
		c := boundaryClaim("policy-liveness-probe", func(c *corev1.PersistentVolumeClaim) { c.Spec.VolumeName = "staged" })
		return c, tenant.Create(ctx, c)
	}, func(o client.Object) { _ = admin.Delete(ctx, o) })
	return ctx, admin, tenant
}

// waitUntilRefused retries a request the policies must refuse until they do.
//
// The apiserver starts enforcing a policy asynchronously, so only a refusal says that it has, and the refusal must
// carry the policy's own words so an RBAC denial is not mistaken for it.
func waitUntilRefused(t *testing.T, words string, try func() (client.Object, error), undo func(client.Object)) {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for {
		obj, err := try()
		if err != nil && strings.Contains(err.Error(), words) {
			return
		}
		if err == nil {
			undo(obj)
		}
		if time.Now().After(deadline) {
			t.Fatalf("no refusal naming %q for 30s; last result: %v", words, err)
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func boundaryClaim(name string, mutate func(*corev1.PersistentVolumeClaim)) *corev1.PersistentVolumeClaim {
	c := &corev1.PersistentVolumeClaim{
		Name: name, Namespace: boundaryTenant,
		Spec: corev1.PersistentVolumeClaimSpec{
			AccessModes: []corev1.PersistentVolumeAccessMode{corev1.ReadWriteMany},
			Resources: corev1.VolumeResourceRequirements{
				Requests: corev1.ResourceList{corev1.ResourceStorage: resource.MustParse("1Gi")},
			},
		},
	}
	if mutate != nil {
		mutate(c)
	}
	return c
}

func TestTheTenantProvisionsAClaimButCannotBindAStagedVolume(t *testing.T) {
	ctx, _, tenant := startTenantBoundaryEnv(t)
	if err := tenant.Create(ctx, boundaryClaim("state", nil)); err != nil {
		t.Fatalf("the tenant could not create a dynamically provisioned claim: %v", err)
	}
	err := tenant.Create(ctx, boundaryClaim("by-selector", func(c *corev1.PersistentVolumeClaim) {
		c.Spec.Selector = &metav1.LabelSelector{MatchLabels: map[string]string{"staged-for": "serve-a"}}
	}))
	if err == nil || !strings.Contains(err.Error(), "spec.selector") {
		t.Fatalf("a tenant's claim selecting staged volumes by label: want a refusal naming the field, got %v", err)
	}
}

// Deleting is the tenant's; finishing the deletion is the controller's, after the rank Pods are retired.
func TestTheTenantCannotRemoveTheControllersFinalizer(t *testing.T) {
	ctx, admin, tenant := startTenantBoundaryEnv(t)
	const finalizer = "mltrainingjob.platform.lkhun9311.github.io/finalizer"

	// The controller adds the finalizer on its first reconcile; envtest runs no controller, so the administrator
	// stands in for it.
	job := boundaryJob("finalized", nil)
	job.Finalizers = []string{finalizer}
	if err := admin.Create(ctx, job); err != nil {
		t.Fatalf("create the job with the controller's finalizer: %v", err)
	}
	strip := client.RawPatch("application/merge-patch+json", []byte(`{"metadata":{"finalizers":null}}`))
	if err := tenant.Patch(ctx, job, strip); err == nil || !strings.Contains(err.Error(), finalizer) {
		t.Fatalf("a tenant removing the controller's finalizer: want a refusal naming it, got %v", err)
	}
	if err := tenant.Delete(ctx, job); err != nil {
		t.Fatalf("the tenant could not delete its own job: %v", err)
	}
	if err := tenant.Patch(ctx, job, strip); err == nil || !strings.Contains(err.Error(), finalizer) {
		t.Fatalf("a tenant removing the finalizer of its job being deleted: want a refusal naming it, got %v", err)
	}
	if err := admin.Patch(ctx, job, strip); err != nil {
		t.Fatalf("the administrator could not release the finalizer: %v", err)
	}
}

func boundaryJob(name string, annotations map[string]string) *platformv1.MLTrainingJob {
	return mltj(name, func(j *platformv1.MLTrainingJob) {
		j.Namespace = boundaryTenant
		j.Annotations = annotations
	})
}

func TestTheTenantSubmitsATrainingJobInItsNamespace(t *testing.T) {
	ctx, _, tenant := startTenantBoundaryEnv(t)
	if err := tenant.Create(ctx, boundaryJob("own", nil)); err != nil {
		t.Fatalf("the tenant could not create an MLTrainingJob in its own namespace: %v", err)
	}
}

func TestTheTenantCannotSubmitInAnotherNamespace(t *testing.T) {
	ctx, _, tenant := startTenantBoundaryEnv(t)
	err := tenant.Create(ctx, mltj("elsewhere", nil))
	if !apierrors.IsForbidden(err) {
		t.Fatalf("a tenant creating an MLTrainingJob in namespace default: want Forbidden, got %v", err)
	}
}

// A Pod or a Job written directly would skip the platform's resource and its queue, and a LocalQueue,
// ResourceQuota or NetworkPolicy would let the tenant remap its quota or open its network.
func TestTheTenantCannotWriteWhatThePlatformGenerates(t *testing.T) {
	ctx, _, tenant := startTenantBoundaryEnv(t)
	objs := map[string]client.Object{
		"Pod": &corev1.Pod{
			Name: "direct", Namespace: boundaryTenant,
			Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "c", Image: "busybox:1.36"}}},
		},
		"ResourceQuota": &corev1.ResourceQuota{Name: "mine", Namespace: boundaryTenant},
		"ServiceAccount": &corev1.ServiceAccount{
			Name: "mine", Namespace: boundaryTenant,
		},
	}
	for kind, obj := range objs {
		if err := tenant.Create(ctx, obj); !apierrors.IsForbidden(err) {
			t.Errorf("a tenant creating a %s in its namespace: want Forbidden, got %v", kind, err)
		}
	}
	for _, gvk := range []struct{ group, version, kind string }{
		{"batch", "v1", "Job"},
		{"kueue.x-k8s.io", "v1beta1", "LocalQueue"},
		{"networking.k8s.io", "v1", "NetworkPolicy"},
	} {
		var obj unstructured.Unstructured
		obj.SetAPIVersion(strings.TrimPrefix(gvk.group+"/"+gvk.version, "/"))
		obj.SetKind(gvk.kind)
		obj.SetName("mine")
		obj.SetNamespace(boundaryTenant)
		if err := tenant.Create(ctx, &obj); !apierrors.IsForbidden(err) {
			t.Errorf("a tenant creating a %s in its namespace: want Forbidden, got %v", gvk.kind, err)
		}
	}
}

func TestTheTenantCannotRelabelItsNamespace(t *testing.T) {
	ctx, _, tenant := startTenantBoundaryEnv(t)
	var ns corev1.Namespace
	if err := tenant.Get(ctx, client.ObjectKey{Name: boundaryTenant}, &ns); !apierrors.IsForbidden(err) {
		t.Fatalf("a tenant reading its Namespace object: want Forbidden, got %v", err)
	}
	ns = corev1.Namespace{Name: boundaryTenant}
	patch := client.RawPatch("application/merge-patch+json",
		[]byte(`{"metadata":{"labels":{"pod-security.kubernetes.io/enforce":"privileged"}}}`))
	if err := tenant.Patch(ctx, &ns, patch); !apierrors.IsForbidden(err) {
		t.Fatalf("a tenant relaxing its namespace's Pod Security label: want Forbidden, got %v", err)
	}
}

func TestTheTenantCannotRaiseItsTier(t *testing.T) {
	ctx, admin, tenant := startTenantBoundaryEnv(t)
	policy := &platformv1.GPUQuotaPolicy{
		Name: boundaryTenant,
		Spec: platformv1.GPUQuotaPolicySpec{
			Tenant: boundaryTenant, TargetNamespace: boundaryTenant, GPUClass: "a10g",
			Limits: platformv1.GPUQuotaLimits{GPUCount: 1},
		},
	}
	if err := admin.Create(ctx, policy); err != nil {
		t.Fatalf("create the tenant's GPUQuotaPolicy as the administrator: %v", err)
	}
	patch := client.RawPatch("application/merge-patch+json",
		[]byte(`{"metadata":{"annotations":{"platform.lkhun9311.github.io/tier":"premium"}}}`))
	if err := tenant.Patch(ctx, policy, patch); !apierrors.IsForbidden(err) {
		t.Fatalf("a tenant annotating its GPUQuotaPolicy's tier: want Forbidden, got %v", err)
	}
}

func TestTheTenantCannotDeclareANodeFenced(t *testing.T) {
	ctx, _, tenant := startTenantBoundaryEnv(t)

	err := tenant.Create(ctx, boundaryJob("fenced-at-create", map[string]string{fencedNodesKey: "n1"}))
	if err == nil || !strings.Contains(err.Error(), fencedNodesKey) {
		t.Fatalf("a tenant creating a job that declares a node fenced: want a refusal naming the key, got %v", err)
	}

	job := boundaryJob("fenced-at-update", nil)
	if err := tenant.Create(ctx, job); err != nil {
		t.Fatalf("create the tenant's job: %v", err)
	}
	job.Annotations = map[string]string{fencedNodesKey: "n1"}
	err = tenant.Update(ctx, job)
	if err == nil || !strings.Contains(err.Error(), fencedNodesKey) {
		t.Fatalf("a tenant adding fenced-nodes to its job: want a refusal naming the key, got %v", err)
	}
}

// The policy denies tenants rather than allowing operators, so an operator's identity must not need to be
// listed anywhere, and a tenant's edit that leaves the operator's value alone must still go through.
func TestAnOperatorFencesAndTheTenantCannotUndoIt(t *testing.T) {
	ctx, admin, tenant := startTenantBoundaryEnv(t)

	job := boundaryJob("fenced-by-operator", nil)
	if err := tenant.Create(ctx, job); err != nil {
		t.Fatalf("create the tenant's job: %v", err)
	}
	fence := client.RawPatch("application/merge-patch+json",
		[]byte(`{"metadata":{"annotations":{"`+fencedNodesKey+`":"n1"}}}`))
	if err := admin.Patch(ctx, job, fence); err != nil {
		t.Fatalf("the administrator could not declare a node fenced: %v", err)
	}

	unrelated := client.RawPatch("application/merge-patch+json",
		[]byte(`{"metadata":{"annotations":{"example.com/note":"x"}}}`))
	if err := tenant.Patch(ctx, job, unrelated); err != nil {
		t.Fatalf("a tenant's unrelated annotation on a fenced job was refused: %v", err)
	}

	for name, body := range map[string]string{
		"remove": `{"metadata":{"annotations":{"` + fencedNodesKey + `":null}}}`,
		"change": `{"metadata":{"annotations":{"` + fencedNodesKey + `":"n2"}}}`,
	} {
		err := tenant.Patch(ctx, job, client.RawPatch("application/merge-patch+json", []byte(body)))
		if err == nil || !strings.Contains(err.Error(), fencedNodesKey) {
			t.Errorf("a tenant trying to %s the operator's fenced-nodes: want a refusal naming the key, got %v",
				name, err)
		}
	}
}
