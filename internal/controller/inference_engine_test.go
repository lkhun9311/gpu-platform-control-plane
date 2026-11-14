package controller

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"

	appsv1 "k8s.io/api/apps/v1"

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

// crdEnum returns the enum the generated CRD puts under the first property named field.
func crdEnum(t *testing.T, field string) []string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "config", "crd", "bases", "platform.lkhun9311.github.io_inferencedeployments.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`(?s)\n(\s*)` + field + `:\n.*?enum:\n((?:\s*- \S+\n)+)`).FindStringSubmatch(string(raw))
	if m == nil {
		t.Fatalf("no enum under %s in the generated CRD", field)
	}
	var vals []string
	for line := range strings.SplitSeq(strings.TrimSpace(m[2]), "\n") {
		vals = append(vals, strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "-")))
	}
	if len(vals) == 0 {
		t.Fatalf("the %s enum parsed as empty", field)
	}
	return vals
}

// A profile added to the enum without a rendering would panic in the reconciler, so the two are compared here first.
// The experimental profile renders from the release table, which TestEveryReleaseInTheCRDHasAReviewedRow covers.
func TestEveryProfileInTheCRDHasARendering(t *testing.T) {
	for _, p := range crdEnum(t, "profile") {
		if p == platformv1.VLLMProfileExperimentalA10G {
			continue
		}
		if _, ok := vllmProfiles[p]; !ok {
			t.Errorf("profile %s is accepted by the CRD and has no rendering", p)
		}
	}
}

// A release the CRD accepts without a reviewed row would panic in the reconciler, and a row the CRD refuses is review nobody can use.
// Mutation that turns this red: add a release to the enum on VLLMExperimental.Release without a row, or a row without the enum.
func TestEveryReleaseInTheCRDHasAReviewedRow(t *testing.T) {
	enum := crdEnum(t, "release")
	for _, r := range enum {
		if _, ok := experimentalReleases[r]; !ok {
			t.Errorf("release %s is accepted by the CRD and has no reviewed argument set", r)
		}
	}
	for r := range experimentalReleases {
		if !slices.Contains(enum, r) {
			t.Errorf("release %s has a reviewed argument set and the CRD refuses it", r)
		}
	}
}

// The CEL rule pins spec.image to each release's digest, and the controller renders that release's flags, so the two must name the same digest.
// The marker is read rather than the generated CRD, because the YAML folds the rule across lines; the CRD is regenerated from it.
// Mutation that turns this red: change a row's digest, or the digest in the experimental CEL rule.
func TestEveryReleaseDigestIsTheOneTheCRDPins(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "api", "v1", "inferencedeployment_types.go"))
	if err != nil {
		t.Fatal(err)
	}
	for r, rel := range experimentalReleases {
		pair := "self.engine.vllm.experimental.release == '" + r + "' && self.image.endsWith('@" + rel.digest + "')"
		if !strings.Contains(string(raw), pair) {
			t.Errorf("the CEL rule does not pin release %s to %s", r, rel.digest)
		}
	}
}

func experimentalInfD(async string) *platformv1.InferenceDeployment {
	infd := engineInfD("")
	infd.Spec.Engine.VLLM.Profile = platformv1.VLLMProfileExperimentalA10G
	infd.Spec.Engine.VLLM.Experimental = &platformv1.VLLMExperimental{
		Release: platformv1.VLLMReleaseV0271, AsyncScheduling: async}
	return infd
}

// A study arm on the experimental profile is comparable with the validated engine only if, on the same release with async off, it is that engine.
// Mutation that turns this red: change any argument of the v0.27.1 release row.
func TestExperimentalV0271WithAsyncOffRendersTheValidatedEngine(t *testing.T) {
	got, ok := engineProfile(experimentalInfD(platformv1.AsyncSchedulingDisabled))
	if !ok {
		t.Fatal("the reviewed release with async off has no rendering")
	}
	want := vllmProfiles[platformv1.VLLMProfileV0271A10G]
	if !slices.Equal(got.args, want.args) {
		t.Fatalf("rendered %v, the validated profile renders %v", got.args, want.args)
	}
	if !slices.Equal(got.instanceTypes, want.instanceTypes) {
		t.Fatalf("instance types %v, the validated profile has %v", got.instanceTypes, want.instanceTypes)
	}
}

// The async arm's registration claims one changed setting, so the rendering may differ in nothing else.
// Mutation that turns this red: render the same flag for both choices, or let Enabled touch another argument.
func TestExperimentalAsyncChoiceChangesOnlyAsyncScheduling(t *testing.T) {
	off, ok1 := engineProfile(experimentalInfD(platformv1.AsyncSchedulingDisabled))
	on, ok2 := engineProfile(experimentalInfD(platformv1.AsyncSchedulingEnabled))
	if !ok1 || !ok2 {
		t.Fatal("a reviewed async choice has no rendering")
	}
	if len(off.args) != len(on.args) {
		t.Fatalf("the choices render %d and %d arguments", len(off.args), len(on.args))
	}
	var diff []string
	for i := range off.args {
		if off.args[i] != on.args[i] {
			diff = append(diff, off.args[i]+" -> "+on.args[i])
		}
	}
	if len(diff) != 1 || diff[0] != "--no-async-scheduling -> --async-scheduling" {
		t.Fatalf("the choices differ in %v, want only the async-scheduling flag", diff)
	}
}

// The CRD refuses each of these, and the controller refuses them too, so a CRD that drifts from the table renders nothing rather than guessed flags.
// Mutation that turns this red: drop any one check from engineProfile.
func TestEngineProfileRefusesCombinationsNobodyReviewed(t *testing.T) {
	cases := map[string]func(*platformv1.InferenceDeployment){
		"unreviewed release": func(o *platformv1.InferenceDeployment) { o.Spec.Engine.VLLM.Experimental.Release = "v0.28.0" },
		"other digest": func(o *platformv1.InferenceDeployment) {
			o.Spec.Image = "vllm/vllm-openai@sha256:" + "00" + platformv1.VLLMV0271Digest[9:]
		},
		"tag, not digest":              func(o *platformv1.InferenceDeployment) { o.Spec.Image = "vllm/vllm-openai:v0.27.1" },
		"no async choice":              func(o *platformv1.InferenceDeployment) { o.Spec.Engine.VLLM.Experimental.AsyncScheduling = "" },
		"bool-like async":              func(o *platformv1.InferenceDeployment) { o.Spec.Engine.VLLM.Experimental.AsyncScheduling = "true" },
		"profile without experimental": func(o *platformv1.InferenceDeployment) { o.Spec.Engine.VLLM.Experimental = nil },
		"experimental on a validated profile": func(o *platformv1.InferenceDeployment) {
			o.Spec.Engine.VLLM.Profile = platformv1.VLLMProfileV0271A10G
		},
		"HoldCap on experimental": func(o *platformv1.InferenceDeployment) {
			o.Spec.Admission = &platformv1.InferenceAdmission{Mode: platformv1.AdmissionModeHoldCap}
		},
		"HoldCap on prefix cache": func(o *platformv1.InferenceDeployment) {
			o.Spec.Engine.VLLM.Profile = platformv1.VLLMProfileV0271A10GPrefixCache
			o.Spec.Engine.VLLM.Experimental = nil
			o.Spec.Admission = &platformv1.InferenceAdmission{Mode: platformv1.AdmissionModeHoldCap}
		},
	}
	for name, mutate := range cases {
		o := experimentalInfD(platformv1.AsyncSchedulingEnabled)
		mutate(o)
		if p, ok := engineProfile(o); ok {
			t.Errorf("%s rendered %v", name, p.args)
		}
	}
}

// A benchmark row is traced to its engine through this annotation, so it must be exactly what the container runs, for every profile.
// Mutation that turns this red: record the profile's args without the per-deployment ones, or omit the image.
func TestRenderedEngineAnnotationIsWhatTheContainerRuns(t *testing.T) {
	prefix := engineInfD("")
	prefix.Spec.Engine.VLLM.Profile = platformv1.VLLMProfileV0271A10GPrefixCache
	for name, infd := range map[string]*platformv1.InferenceDeployment{
		"holdcap":      engineInfD(platformv1.AdmissionModeHoldCap),
		"prefix-cache": prefix,
		"async-on":     experimentalInfD(platformv1.AsyncSchedulingEnabled),
	} {
		dep := &appsv1.Deployment{}
		if !mutateEngineDeployment(infd, dep) {
			t.Fatalf("%s has no rendering", name)
		}
		raw, ok := dep.Spec.Template.Annotations[renderedEngineAnnotation]
		if !ok {
			t.Fatalf("%s: no %s on the Pod template", name, renderedEngineAnnotation)
		}
		var got renderedEngine
		if err := json.Unmarshal([]byte(raw), &got); err != nil {
			t.Fatalf("%s: %s is not JSON: %v", name, raw, err)
		}
		c := dep.Spec.Template.Spec.Containers[0]
		if got.Image != c.Image || !slices.Equal(got.Args, c.Args) {
			t.Errorf("%s: annotation records %s %v, the container runs %s %v", name, got.Image, got.Args, c.Image, c.Args)
		}
	}
}

// The validated profiles resolve exactly as before, HoldCap included, so the experimental path loosened nothing for them.
func TestEngineProfileKeepsTheValidatedProfiles(t *testing.T) {
	for _, mode := range []string{"", platformv1.AdmissionModeOff, platformv1.AdmissionModeHoldCap} {
		p, ok := engineProfile(engineInfD(mode))
		if !ok || !slices.Equal(p.args, vllmProfiles[platformv1.VLLMProfileV0271A10G].args) {
			t.Errorf("v0.27.1-a10g in mode %q resolved to %v, %v", mode, p.args, ok)
		}
	}
	o := engineInfD("")
	o.Spec.Engine.VLLM.Profile = platformv1.VLLMProfileV0271A10GPrefixCache
	p, ok := engineProfile(o)
	if !ok || !slices.Equal(p.args, vllmProfiles[platformv1.VLLMProfileV0271A10GPrefixCache].args) {
		t.Errorf("the prefix-cache profile resolved to %v, %v", p.args, ok)
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
	for name, rel := range experimentalReleases {
		if !slices.Contains(rel.args, "--scheduling-policy=priority") {
			t.Errorf("release %s does not schedule by priority, and the gateway binds a tier on every rendered engine", name)
		}
	}
}

// The prefix-cache profile is the measured engine with caching on and nothing else moved, which is all the routing
// study's registration claims for it.
// Mutation that turns this red: change any other argument of one profile and leave the other as it is.
func TestPrefixCacheProfileDiffersOnlyInCaching(t *testing.T) {
	base := vllmProfiles[platformv1.VLLMProfileV0271A10G]
	pc, ok := vllmProfiles[platformv1.VLLMProfileV0271A10GPrefixCache]
	if !ok {
		t.Fatal("no rendering for the prefix-cache profile")
	}
	if len(base.args) != len(pc.args) {
		t.Fatalf("the profiles render %d and %d arguments", len(base.args), len(pc.args))
	}
	var diff []string
	for i := range base.args {
		if base.args[i] != pc.args[i] {
			diff = append(diff, base.args[i]+" -> "+pc.args[i])
		}
	}
	if len(diff) != 1 || diff[0] != "--no-enable-prefix-caching -> --enable-prefix-caching" {
		t.Fatalf("the profiles differ in %v, want only the caching flag", diff)
	}
	if !slices.Equal(base.instanceTypes, pc.instanceTypes) {
		t.Fatalf("instance types %v and %v differ", base.instanceTypes, pc.instanceTypes)
	}
}
