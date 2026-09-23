package v1

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	admissionregistrationv1 "k8s.io/api/admissionregistration/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/yaml"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// What config/policy/gpu-workload-static.yaml refuses, asserted against a real apiserver.
//
// The policy is the one admission layer with no Go code behind it, so nothing else in this package can tell
// whether it works. A CEL expression that fails to compile does not fail quietly either: the policy's
// failurePolicy is Fail, so a typo turns into "every MLTrainingJob is refused" -- and `kustomize build`
// renders it happily, because YAML that parses is all kustomize checks.
//
// The manifest is READ FROM DISK rather than restated here. A copy in this file would drift, and a test
// asserting its own copy of an expression proves nothing about what the cluster installs.

// installStaticPolicy applies config/policy/gpu-workload-static.yaml into the running apiserver.
//
// startAdmissionEnv installs the CRDs and the webhook manifest, but envtest has no option for a
// ValidatingAdmissionPolicy, so it is created through the client like any other object.
func installStaticPolicy(t *testing.T, ctx context.Context, c client.Client) {
	t.Helper()

	path := filepath.Join("..", "..", "..", "config", "policy", "gpu-workload-static.yaml")
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read the policy manifest: %v", err)
	}

	// Two documents, and both are needed: the policy alone is inert until a binding says what to do with its
	// decisions. Splitting on the separator rather than decoding a list, because that is the shape on disk.
	docs := strings.Split(string(b), "\n---\n")
	if len(docs) != 2 {
		t.Fatalf("expected a policy and a binding in %s, got %d documents", path, len(docs))
	}

	var policy admissionregistrationv1.ValidatingAdmissionPolicy
	if err := yaml.Unmarshal([]byte(docs[0]), &policy); err != nil {
		t.Fatalf("decode the policy: %v", err)
	}
	if err := c.Create(ctx, &policy); err != nil {
		t.Fatalf("create the policy: %v", err)
	}

	var binding admissionregistrationv1.ValidatingAdmissionPolicyBinding
	if err := yaml.Unmarshal([]byte(docs[1]), &binding); err != nil {
		t.Fatalf("decode the binding: %v", err)
	}
	if err := c.Create(ctx, &binding); err != nil {
		t.Fatalf("create the binding: %v", err)
	}

	// The apiserver compiles and starts enforcing a policy asynchronously, so a Create issued immediately
	// after the binding can be admitted by a policy that is not live yet. Waiting on an object the policy
	// must refuse is the only signal that says enforcement has started -- a fixed sleep would either be
	// flaky or slow, and polling the policy's status would assert the apiserver's bookkeeping rather than
	// its behaviour.
	deadline := time.Now().Add(30 * time.Second)
	for {
		err := c.Create(ctx, mltj("policy-liveness-probe", func(j *platformv1.MLTrainingJob) {
			j.Spec.Image = "busybox:latest"
		}))
		if err != nil {
			return
		}
		// It was admitted, which means the policy is not enforcing yet. Remove it and try again.
		_ = c.Delete(ctx, mltj("policy-liveness-probe", nil))
		if time.Now().After(deadline) {
			t.Fatal("the policy admitted a :latest image for 30s; it never started enforcing")
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func TestThePolicyRefusesAMutableImageTag(t *testing.T) {
	ctx, c := startAdmissionEnv(t)
	installStaticPolicy(t, ctx, c)

	err := c.Create(ctx, mltj("mutable-tag", func(j *platformv1.MLTrainingJob) {
		j.Spec.Image = "pytorch/pytorch:latest"
	}))
	if err == nil {
		t.Fatal("the apiserver accepted a :latest image; the policy was not enforcing")
	}
	if !strings.Contains(err.Error(), "latest") {
		t.Fatalf("refused for something other than the tag: %v", err)
	}
}

func TestThePolicyRefusesGPUsWithNoClass(t *testing.T) {
	ctx, c := startAdmissionEnv(t)
	installStaticPolicy(t, ctx, c)

	err := c.Create(ctx, mltj("no-class", func(j *platformv1.MLTrainingJob) {
		j.Spec.GPUCount = 2
		j.Spec.GPUClass = ""
	}))
	if err == nil {
		t.Fatal("the apiserver accepted a GPU request with no class; the policy was not enforcing")
	}
	if !strings.Contains(err.Error(), "gpuClass") {
		t.Fatalf("refused for something other than the class: %v", err)
	}
}

// A whitespace-only class is the reason the expression calls trim() rather than testing for "".
//
// Without it, `gpuClass: " "` satisfies a non-empty check and names no class at all -- which is exactly the
// "chosen by omission" outcome the rule exists to refuse, arrived at through a different door.
func TestThePolicyRefusesAWhitespaceClass(t *testing.T) {
	ctx, c := startAdmissionEnv(t)
	installStaticPolicy(t, ctx, c)

	err := c.Create(ctx, mltj("blank-class", func(j *platformv1.MLTrainingJob) {
		j.Spec.GPUCount = 1
		j.Spec.GPUClass = "   "
	}))
	if err == nil {
		t.Fatal("the apiserver accepted a whitespace-only gpuClass")
	}
	if !strings.Contains(err.Error(), "gpuClass") {
		t.Fatalf("refused for something other than the class: %v", err)
	}
}

// A CPU workload naming no class is the case the guard on gpuCount exists for.
//
// Requiring a class unconditionally would refuse every zero-GPU job, which is the opposite mistake and the
// one a rule written without this test would have made.
func TestThePolicyAllowsNoClassWhenNoGPUIsAsked(t *testing.T) {
	ctx, c := startAdmissionEnv(t)
	installStaticPolicy(t, ctx, c)

	if err := c.Create(ctx, mltj("cpu-only", func(j *platformv1.MLTrainingJob) {
		j.Spec.GPUCount = 0
		j.Spec.GPUClass = ""
	})); err != nil {
		t.Fatalf("the policy refused a CPU-only job with no class: %v", err)
	}
}

// The control, for the reason TestApiserverAcceptsARunnableSpec gives: a policy whose expressions error on
// every object would pass all three refusal tests above, and a manifest matching the wrong resource would
// refuse nothing while still looking installed.
func TestThePolicyAcceptsAPinnedImageWithAClass(t *testing.T) {
	ctx, c := startAdmissionEnv(t)
	installStaticPolicy(t, ctx, c)

	if err := c.Create(ctx, mltj("pinned", func(j *platformv1.MLTrainingJob) {
		j.Spec.Image = "pytorch/pytorch:2.3.0-cuda12.1-cudnn8-runtime"
		j.Spec.GPUCount = 2
		j.Spec.GPUClass = "l40s"
	})); err != nil {
		t.Fatalf("the policy refused a pinned image with a named class: %v", err)
	}
}
