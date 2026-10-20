package controller

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

const measuredRevision = "aa8e72537993ba99e69dfaafa59ed015b17504d1"

func engineInfD(mode string) *platformv1.InferenceDeployment {
	infd := &platformv1.InferenceDeployment{}
	infd.Name, infd.Namespace = "qwen", "default"
	infd.Spec = platformv1.InferenceDeploymentSpec{
		Model:    platformv1.InferenceModel{Name: "qwen", StorageURI: "hf://Qwen/Qwen2.5-3B-Instruct"},
		Image:    platformv1.VLLMV0271Image,
		GPUCount: 1, Replicas: 1, Port: 8000,
		Engine: &platformv1.InferenceEngine{VLLM: &platformv1.VLLMEngine{
			Profile: platformv1.VLLMProfileV0271A10G, ModelRevision: measuredRevision}},
	}
	if mode != "" {
		infd.Spec.Admission = &platformv1.InferenceAdmission{Mode: mode}
	}
	return infd
}

// pilotExpected runs the pilot's own registration for the hold-cap arm and returns its key=value lines.
// The shell function is the reference, not a Go copy of it, so the two cannot drift apart unnoticed.
func pilotExpected(t *testing.T, cap int) map[string]string {
	t.Helper()
	lib := filepath.Join("..", "..", "hack", "lib", "prospective-pilot.sh")
	out, err := exec.Command("bash", "-c", `source "$1" && pp_expected_args "$2"`, "_", lib, strconv.Itoa(cap)).Output()
	if err != nil {
		t.Fatalf("pp_expected_args: %v", err)
	}
	want := map[string]string{}
	for line := range strings.SplitSeq(strings.TrimSpace(string(out)), "\n") {
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			t.Fatalf("pp_expected_args printed %q, not key=value", line)
		}
		want[k] = strings.Trim(v, "'")
	}
	return want
}

// asEngineKeys turns rendered flags into the names vLLM prints in its non-default args line.
func asEngineKeys(t *testing.T, args []string) map[string]string {
	t.Helper()
	got := map[string]string{"model_tag": args[0], "model": args[0]}
	for _, a := range args[1:] {
		name, val, hasVal := strings.Cut(strings.TrimPrefix(a, "--"), "=")
		if !hasVal {
			n, ok := strings.CutPrefix(name, "no-")
			if !ok {
				t.Fatalf("flag %q has no value and is not a --no- flag", a)
			}
			name, val = n, "False"
		}
		key := strings.ReplaceAll(name, "-", "_")
		if _, dup := got[key]; dup {
			t.Fatalf("flag %s rendered twice", key)
		}
		got[key] = val
	}
	return got
}

// The engine is the one the measurement ran, less the two entries that only instrumented it.
// port and served_model_name are infrastructure: the pilot's validator exempts the port, and the served name is what the gateway routes on.
// The cap is passed as the literal 384, not the constant under test, so changing the constant turns this red.
func TestRenderedArgsAreTheMeasuredHoldCapEngine(t *testing.T) {
	want := pilotExpected(t, 384)
	delete(want, "enable_logging_iteration_details")
	delete(want, "scheduler_cls")
	got := asEngineKeys(t, vllmArgs(engineInfD(platformv1.AdmissionModeHoldCap), vllmProfiles[platformv1.VLLMProfileV0271A10G]))
	if got["port"] != "8000" || got["served_model_name"] != "qwen" {
		t.Fatalf("port %q and served name %q, want 8000 and qwen", got["port"], got["served_model_name"])
	}
	delete(got, "port")
	delete(got, "served_model_name")
	for k, w := range want {
		g, ok := got[k]
		if !ok {
			t.Errorf("%s=%s was measured and is not rendered", k, w)
			continue
		}
		if gf, err1 := strconv.ParseFloat(g, 64); err1 == nil {
			if wf, err2 := strconv.ParseFloat(w, 64); err2 == nil && gf == wf {
				continue
			}
		}
		if g != w {
			t.Errorf("%s rendered %q, measured %q", k, g, w)
		}
	}
	for k, g := range got {
		if _, ok := want[k]; !ok {
			t.Errorf("%s=%s is rendered and was not measured", k, g)
		}
	}
}

// Off renders the same engine without the cap, which is the measurement's own "off" arm.
func TestOffRendersNoCap(t *testing.T) {
	for _, mode := range []string{"", platformv1.AdmissionModeOff} {
		for _, a := range vllmArgs(engineInfD(mode), vllmProfiles[platformv1.VLLMProfileV0271A10G]) {
			if strings.HasPrefix(a, "--long-prefill-token-threshold") {
				t.Fatalf("mode %q rendered %s", mode, a)
			}
		}
	}
}

// A profile added to the enum without a rendering would panic in the reconciler, so the two are compared here first.
func TestEveryProfileInTheCRDHasARendering(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "config", "crd", "bases", "platform.lkhun9311.github.io_inferencedeployments.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`(?s)\n(\s*)profile:\n.*?enum:\n((?:\s*- \S+\n)+)`).FindStringSubmatch(string(raw))
	if m == nil {
		t.Fatal("no enum under profile in the generated CRD")
	}
	n := 0
	for line := range strings.SplitSeq(strings.TrimSpace(m[2]), "\n") {
		p := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "-"))
		n++
		if _, ok := vllmProfiles[p]; !ok {
			t.Errorf("profile %s is accepted by the CRD and has no rendering", p)
		}
	}
	if n == 0 {
		t.Fatal("the profile enum parsed as empty")
	}
}

// The gateway binds a tier on every backend whose engine this controller renders, in Off as well as HoldCap
// (internal/gateway BackendRef.PriorityScheduled), on the strength of this one fact. A profile without priority
// scheduling would be sent priorities it may refuse.
// Mutation that turns this red: drop --scheduling-policy=priority from a profile.
func TestEveryRenderedProfileSchedulesByPriority(t *testing.T) {
	for name, p := range vllmProfiles {
		if !slices.Contains(p.args, "--scheduling-policy=priority") {
			t.Errorf("profile %s does not schedule by priority, and the gateway binds a tier on every rendered engine", name)
		}
	}
}
