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

package bench

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

const sizingOverheadMiB = 1400

// The finding that chose the card, kept as a test so it cannot quietly stop being true.
//
// Two Qwen2.5-3B engines do not fit on a T4, and the failure is the dangerous kind: the second engine
// starts, profiles, and finds a cache too small to hold one prompt. Nothing errors. The run produces
// latencies that describe eviction and look like a sharing-mode result.
func TestTwoEnginesOfTheFlagshipModelDoNotFitOnTheCardM5bUses(t *testing.T) {
	p := SharingPlan{Card: CardT4, Model: ModelQwen3B, Engines: 2, UtilizationPerEngine: 0.475, NonKVOverheadMiB: sizingOverheadMiB}

	err := p.Validate()
	if err == nil {
		t.Fatalf("a T4 hosting two %s engines validated; it leaves %d KV tokens each, which is less than one contender prompt",
			ModelQwen3B.Name, p.KVTokensPerEngine())
	}
	if !strings.Contains(err.Error(), "KV") {
		t.Errorf("the refusal does not name the KV cache as the thing that ran out: %v", err)
	}
	if got := p.KVTokensPerEngine(); got >= minUsefulKVTokens {
		t.Errorf("the T4 plan yields %d KV tokens per engine, which would make this test vacuous", got)
	}
}

// The card M5-c does use has to actually work, or the conclusion is only half checked.
func TestTwoEnginesOfTheFlagshipModelFitOnTheCardM5cUses(t *testing.T) {
	p := SharingPlan{Card: CardA10G, Model: ModelQwen3B, Engines: 2, UtilizationPerEngine: 0.475, NonKVOverheadMiB: sizingOverheadMiB}

	if err := p.Validate(); err != nil {
		t.Fatalf("an A10G hosting two %s engines was refused: %v", ModelQwen3B.Name, err)
	}
	// Enough to batch several contender prompts at once, which is what makes a sharing comparison mean
	// anything: two engines that can each only hold one sequence are not sharing, they are taking turns.
	if got := p.KVTokensPerEngine(); got < 8*7695 {
		t.Errorf("A10G plan leaves %d KV tokens per engine, too few to batch", got)
	}
}

// The exclusive arm is the same card with one engine, and it must remain the roomiest.
func TestTheExclusiveArmHasStrictlyMoreCacheThanTheSharedOne(t *testing.T) {
	one := SharingPlan{Card: CardA10G, Model: ModelQwen3B, Engines: 1, UtilizationPerEngine: 0.95, NonKVOverheadMiB: sizingOverheadMiB}
	two := SharingPlan{Card: CardA10G, Model: ModelQwen3B, Engines: 2, UtilizationPerEngine: 0.475, NonKVOverheadMiB: sizingOverheadMiB}

	if err := one.Validate(); err != nil {
		t.Fatalf("the exclusive arm was refused: %v", err)
	}
	if one.KVTokensPerEngine() <= two.KVTokensPerEngine() {
		t.Errorf("exclusive gives %d KV tokens and shared gives %d; if sharing did not cost cache there would be nothing to measure",
			one.KVTokensPerEngine(), two.KVTokensPerEngine())
	}
}

// Utilization that adds past the card is the mistake time-slicing invites, because the plugin advertises
// more devices and says nothing about memory.
func TestAPlanThatClaimsMoreThanOneCardIsRefused(t *testing.T) {
	p := SharingPlan{Card: CardA10G, Model: ModelQwen3B, Engines: 2, UtilizationPerEngine: 0.90, NonKVOverheadMiB: sizingOverheadMiB}

	err := p.Validate()
	if err == nil {
		t.Fatal("two engines at 0.90 utilization validated; that claims 1.8 cards from a machine that has one")
	}
	if !strings.Contains(err.Error(), "they do not create a second") {
		t.Errorf("the refusal does not explain that a shared pool is not a second pool: %v", err)
	}
}

// Not starting and thrashing are different outcomes, and the refusal has to say which one it is.
//
// This branch was reachable and untested: every other case here runs out of USEFUL cache before it runs
// out of cache, so disabling the negative-cache gate entirely left the suite green and only changed which
// sentence the operator read. The two sentences describe different mornings -- one where the Pod never
// became ready, and one where it did and the numbers are about eviction.
func TestAPlanWithNoCacheAtAllSaysTheEngineWillNotStart(t *testing.T) {
	p := SharingPlan{Card: CardT4, Model: ModelQwen3B, Engines: 2, UtilizationPerEngine: 0.40, NonKVOverheadMiB: sizingOverheadMiB}
	if p.KVMiBPerEngine() > 0 {
		t.Fatalf("this plan leaves %.0f MiB, so it no longer covers the negative-cache case", p.KVMiBPerEngine())
	}

	err := p.Validate()
	if err == nil {
		t.Fatal("a plan with negative KV cache validated")
	}
	if !strings.Contains(err.Error(), "will not start") {
		t.Errorf("the refusal reports thrashing rather than a failure to start, which sends the operator "+
			"looking at latencies for a Pod that never became ready: %v", err)
	}
}

// A plan whose cache is positive but tiny is still refused, because "it started" is not the bar.
func TestAPlanIsRefusedWhileItsCacheIsTooSmallToBatch(t *testing.T) {
	// Chosen to land between "engine starts" and "engine can batch": positive KV, far below four prompts.
	p := SharingPlan{Card: CardT4, Model: ModelQwen3B, Engines: 2, UtilizationPerEngine: 0.49, NonKVOverheadMiB: sizingOverheadMiB}
	if p.KVMiBPerEngine() <= 0 {
		t.Skip("this plan fails the earlier gate; the case it means to cover has moved")
	}
	err := p.Validate()
	if err == nil {
		t.Fatalf("a plan with %d KV tokens per engine validated", p.KVTokensPerEngine())
	}
	if !strings.Contains(err.Error(), "eviction") {
		t.Errorf("the refusal does not say what such an arm would actually measure: %v", err)
	}
}

// The committed manifests must form a plan Validate accepts, or the arithmetic is decoration.
//
// SharingPlan can refuse a bad plan and cannot refuse a bad manifest. What ties them is this test: it reads
// the engines' --gpu-memory-utilization and their count out of config/vllm-shared, and the replicas out of
// the time-slicing plugin's ConfigMap, and builds the plan those files actually describe.
func TestTheCommittedSharedEnginesFormAPlanThatValidates(t *testing.T) {
	// Globbed rather than named: the engines live one per file so each can be applied into its own
	// namespace, and a test that named one file would stop counting the moment a third engine was added --
	// silently, by validating a two-engine plan for a three-engine deployment.
	files, err := filepath.Glob("../../config/vllm-shared/engine-*.yaml")
	if err != nil || len(files) == 0 {
		t.Fatalf("no shared engine manifests found: %v", err)
	}
	var engines []byte
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatalf("read %s: %v", f, err)
		}
		engines = append(engines, b...)
	}
	utils := regexp.MustCompile(`--gpu-memory-utilization=([0-9.]+)`).FindAllStringSubmatch(string(engines), -1)
	if len(utils) == 0 {
		t.Fatal("the shared engines set no --gpu-memory-utilization; under time-slicing that defaults each " +
			"engine to most of the card and the second one has nowhere to live")
	}

	// Every engine must claim the same slice: the matrix compares one mode against another, and engines
	// that differed in memory would differ in cache size too, which is the thing the mode is supposed to
	// change.
	first := utils[0][1]
	for _, u := range utils[1:] {
		if u[1] != first {
			t.Fatalf("engines claim different slices (%s and %s); the arms would differ in cache size as "+
				"well as in sharing mode", first, u[1])
		}
	}
	util, err := strconv.ParseFloat(first, 64)
	if err != nil {
		t.Fatalf("--gpu-memory-utilization %q is not a number: %v", first, err)
	}

	plan := SharingPlan{
		Card: CardA10G, Model: ModelQwen3B,
		Engines:              len(utils),
		UtilizationPerEngine: util,
		NonKVOverheadMiB:     sizingOverheadMiB,
	}
	if err := plan.Validate(); err != nil {
		t.Fatalf("the committed manifests describe a plan that cannot produce a result: %v", err)
	}

	// The plugin must advertise at least as many devices as there are engines, or the extra engines stay
	// Pending -- which looks like a scheduling problem and is a configuration one.
	cm, err := os.ReadFile("../../config/nvidia-device-plugin-timeslicing/configmap.yaml")
	if err != nil {
		t.Fatalf("read the sharing config: %v", err)
	}
	m := regexp.MustCompile(`replicas:\s*(\d+)`).FindStringSubmatch(string(cm))
	if m == nil {
		t.Fatal("the time-slicing ConfigMap declares no replicas; the plugin would advertise one device per card")
	}
	replicas, err := strconv.Atoi(m[1])
	if err != nil {
		t.Fatalf("replicas %q is not a number: %v", m[1], err)
	}
	if replicas < len(utils) {
		t.Errorf("the plugin advertises %d device(s) and the manifests ask for %d engines; the surplus engines "+
			"stay Pending", replicas, len(utils))
	}
}

// The two sharing overlays must be mutually exclusive on one node, and equal in everything but the mechanism.
//
// They select the same node label on purpose -- MPS and time-slicing are two arms of one matrix on one
// machine, run at different times -- which makes applying both a live hazard rather than a hypothetical:
// two plugins registering nvidia.com/gpu against one kubelet socket, on a rented card. The script deletes
// one before applying the other; this checks the properties that make that both necessary and sufficient.
func TestTheSharingOverlaysAreExclusiveAndDifferOnlyInTheMechanism(t *testing.T) {
	ts, err := os.ReadFile("../../config/nvidia-device-plugin-timeslicing/daemonset.yaml")
	if err != nil {
		t.Fatalf("read the time-slicing overlay: %v", err)
	}
	mps, err := os.ReadFile("../../config/nvidia-device-plugin-mps/daemonset.yaml")
	if err != nil {
		t.Fatalf("read the MPS overlay: %v", err)
	}

	sel := regexp.MustCompile(`platform\.lkhun9311\.github\.io/gpu-sharing:\s*"true"`)
	if !sel.MatchString(string(ts)) || !sel.MatchString(string(mps)) {
		t.Fatal("the two overlays no longer select the same node, so the script's delete-then-apply is " +
			"guarding an exclusion that no longer exists and both could run at once elsewhere")
	}

	// Distinct DaemonSet names, or applying one adopts the other's pods and the delete never happens.
	nameOf := regexp.MustCompile(`(?m)^  name:\s*(\S+)`)
	names := map[string]string{}
	for label, b := range map[string][]byte{"timeslicing": ts, "mps": mps} {
		for _, m := range nameOf.FindAllStringSubmatch(string(b), -1) {
			if prev, dup := names[m[1]]; dup && prev != label {
				t.Errorf("both overlays declare %q; applying one would adopt the other's DaemonSet instead "+
					"of replacing it", m[1])
			}
			names[m[1]] = label
		}
	}

	// Same plugin digest. Sharing is a configuration of one binary, and arms that differed in the plugin
	// would differ in more than the mechanism under test.
	// Exactly 64 hex, because prose in these files abbreviates digests and a truncated one is not a pin.
	// The first version of this matched `sha256:ed39e22c...` inside a comment and reported the two arms as
	// running different builds -- a false alarm that would have been read as a real one.
	dig := regexp.MustCompile(`k8s-device-plugin:[^@\s]+@(sha256:[a-f0-9]{64})`)
	tsDig := dig.FindStringSubmatch(string(ts))
	mpsDig := dig.FindStringSubmatch(string(mps))
	if tsDig == nil || mpsDig == nil {
		t.Fatal("one of the overlays does not pin the plugin by digest")
	}
	if tsDig[1] != mpsDig[1] {
		t.Errorf("the arms run different plugin builds (%s and %s); the comparison would carry that "+
			"difference as well as the sharing mechanism", tsDig[1], mpsDig[1])
	}

	// Both must set CONFIG_FILE. Without it the plugin ignores the mounted config and advertises one device
	// per card -- the EXCLUSIVE behaviour under a manifest that says otherwise, which is an arm in name only.
	// Anchored on the whole env-var name. A substring check passed a manifest whose variable had been
	// renamed to CONFIG_FILE_DISABLED, which the plugin ignores exactly as it ignores an absent one.
	cfgVar := regexp.MustCompile(`(?m)^\s*-\s*name:\s*CONFIG_FILE\s*$`)
	for label, b := range map[string][]byte{"timeslicing": ts, "mps": mps} {
		if !cfgVar.MatchString(string(b)) {
			t.Errorf("the %s overlay does not set CONFIG_FILE; the plugin would ignore its sharing config "+
				"and the arm would be the exclusive one wearing another name", label)
		}
	}

	// Equal replica counts. The matrix varies the mechanism and holds the tenant count fixed; arms that
	// differed here would be measuring the count.
	rep := regexp.MustCompile(`replicas:\s*(\d+)`)
	tsCM, err := os.ReadFile("../../config/nvidia-device-plugin-timeslicing/configmap.yaml")
	if err != nil {
		t.Fatalf("read the time-slicing config: %v", err)
	}
	mpsCM, err := os.ReadFile("../../config/nvidia-device-plugin-mps/configmap.yaml")
	if err != nil {
		t.Fatalf("read the MPS config: %v", err)
	}
	a, b := rep.FindStringSubmatch(string(tsCM)), rep.FindStringSubmatch(string(mpsCM))
	if a == nil || b == nil {
		t.Fatal("a sharing config declares no replicas; the plugin would advertise one device per card")
	}
	if a[1] != b[1] {
		t.Errorf("time-slicing advertises %s replicas and MPS %s; the arms would differ in how many tenants "+
			"share the card as well as in how", a[1], b[1])
	}
}

// The write-up must not claim to be finished while it still has placeholders in it.
//
// M5-d is written before the run so its reasoning cannot be fitted to whatever the card produces, which
// means it ships full of markers. That is fine while it says so; it stops being fine the moment the page
// presents itself as a result. This is the check that keeps those two states apart, and it is the same
// discipline the report applies to an arm whose tail is too thin to be a tail.
func TestTheWriteUpDoesNotClaimNumbersItStillMarksAsMissing(t *testing.T) {
	b, err := os.ReadFile("../../hack/m5d-writeup.md")
	if err != nil {
		t.Fatalf("read the write-up: %v", err)
	}
	text := string(b)

	markers := regexp.MustCompile(`\[\[[A-Z0-9_]+\]\]`).FindAllString(text, -1)
	// The page's own title is the declaration that the numbers are absent. If it is edited to drop that,
	// every marker below becomes a claim.
	declares := strings.Contains(text, "with the numbers left out")

	switch {
	case len(markers) > 0 && !declares:
		t.Errorf("the write-up carries %d unfilled marker(s) and no longer says the numbers are missing; a "+
			"reader would take %q for a result", len(markers), markers[0])
	case len(markers) == 0 && declares:
		t.Error("every marker is filled but the write-up still announces that its numbers are missing, which " +
			"understates a finished result as badly as the other direction overstates an unfinished one")
	}
}

// devicePluginOverlays are the four configurations of one plugin the matrix switches between.
//
// Three of them belong to an arm: whole-card is `shared`, and the other two are the sharing modes. The
// fourth is the production overlay that runs on the ordinary GPU node group and is here because the checks
// below are about all of them agreeing on the things that are not the experiment.
var devicePluginOverlays = []string{
	"nvidia-device-plugin",
	"nvidia-device-plugin-whole-card",
	"nvidia-device-plugin-timeslicing",
	"nvidia-device-plugin-mps",
}

// Every plugin overlay must render into the namespace the operator actually creates.
//
// `system` in these manifests is kubebuilder's placeholder: config/default rewrites it, and no namespace by
// that name is ever created. An overlay that does not carry the rewrite renders `namespace: system` and is
// refused at apply time with `namespaces "system" not found`.
//
// Both sharing overlays were in exactly that state, so neither sharing arm of the matrix could ever have
// deployed. It survived because TestTheSharingOverlaysAreExclusiveAndDifferOnlyInTheMechanism compares the
// two of them against EACH OTHER: they were identically wrong, and agreement is not correctness. This test
// compares them against the cluster instead.
func TestEveryDevicePluginOverlayRendersIntoTheOperatorsNamespace(t *testing.T) {
	def, err := os.ReadFile("../../config/default/kustomization.yaml")
	if err != nil {
		t.Fatalf("read config/default/kustomization.yaml: %v", err)
	}
	nsLine := regexp.MustCompile(`(?m)^namespace:\s*(\S+)\s*$`)
	m := nsLine.FindStringSubmatch(string(def))
	if m == nil {
		t.Fatal("config/default declares no namespace, so there is nothing to hold the overlays to")
	}
	want := m[1]
	if want == "system" {
		t.Fatal("config/default declares the literal namespace `system`; this test's whole premise is that it does not")
	}

	for _, o := range devicePluginOverlays {
		path := "../../config/" + o + "/kustomization.yaml"
		b, rerr := os.ReadFile(path)
		if rerr != nil {
			t.Errorf("read %s: %v", path, rerr)
			continue
		}
		got := nsLine.FindStringSubmatch(string(b))
		if got == nil {
			t.Errorf("config/%s/kustomization.yaml sets no namespace, so it renders the placeholder "+
				"`system` and every apply of it is refused with `namespaces \"system\" not found`; the arm "+
				"using it could never deploy", o)
			continue
		}
		if got[1] != want {
			t.Errorf("config/%s/kustomization.yaml renders into %q but the operator creates %q", o, got[1], want)
		}
	}
}

// The `shared` arm needs a plugin advertising ONE device on the sharing node, and for a long time none
// existed.
//
// config/nvidia-device-plugin selects platform.lkhun9311.github.io/gpu, a label the sharing node group
// deliberately does not carry (infra/aws/cluster/eks.tf says why: two plugins on one kubelet socket). The
// two sharing overlays select gpu-sharing and advertise two. So the control arm's engine -- the one the
// pre-registration says every other number is measured against -- had a plugin for neither its node nor its
// topology. On a fresh node it would have sat Pending to the 900-second rollout timeout; run after a sharing
// arm it would have scheduled onto a leftover replica and reported a control that was quietly running on
// half a card.
//
// These are the properties that make the whole-card overlay the `shared` arm's plugin rather than a copy of
// one of the others.
func TestTheWholeCardOverlayIsTheExclusivePluginOnTheSharingNode(t *testing.T) {
	whole, err := os.ReadFile("../../config/nvidia-device-plugin-whole-card/daemonset.yaml")
	if err != nil {
		t.Fatalf("read the whole-card overlay: %v", err)
	}

	if !regexp.MustCompile(`platform\.lkhun9311\.github\.io/gpu-sharing:\s*"true"`).Match(whole) {
		t.Error("the whole-card overlay does not select the sharing node, so the `shared` arm's engine would " +
			"find nothing advertising a device and sit Pending to its rollout timeout")
	}
	if regexp.MustCompile(`(?m)^\s*platform\.lkhun9311\.github\.io/gpu:\s*"true"`).Match(whole) {
		t.Error("the whole-card overlay selects the ordinary GPU label as well; it would land on the node " +
			"the production plugin already serves and two plugins would register against one kubelet socket")
	}

	// No CONFIG_FILE, and that omission is the overlay.
	//
	// The plugin's default is one device per physical card, which is exactly what this arm needs. The check
	// runs in the opposite direction from the one on the sharing overlays: there a missing CONFIG_FILE makes
	// a sharing arm exclusive, here a present one would split the control's card.
	if regexp.MustCompile(`(?m)^\s*-\s*name:\s*CONFIG_FILE\s*$`).Match(whole) {
		t.Error("the whole-card overlay sets CONFIG_FILE; it would advertise a split card and the `shared` " +
			"arm would be a sharing arm wearing the control's name")
	}

	// One digest across all four, so an arm cannot differ in the plugin build as well as in the mechanism.
	dig := regexp.MustCompile(`k8s-device-plugin:[^@\s]+@(sha256:[a-f0-9]{64})`)
	digests := map[string]string{}
	for _, o := range devicePluginOverlays {
		b, rerr := os.ReadFile("../../config/" + o + "/daemonset.yaml")
		if rerr != nil {
			t.Fatalf("read config/%s/daemonset.yaml: %v", o, rerr)
		}
		d := dig.FindStringSubmatch(string(b))
		if d == nil {
			t.Fatalf("config/%s does not pin the plugin by digest", o)
		}
		digests[o] = d[1]
	}
	for o, d := range digests {
		if d != digests["nvidia-device-plugin"] {
			t.Errorf("config/%s runs plugin %s but the production overlay runs %s; an arm would carry that "+
				"difference as well as its topology", o, d, digests["nvidia-device-plugin"])
		}
	}

	// Distinct DaemonSet names across all four, or applying one adopts another's Pods rather than replacing
	// it -- and the production overlay is in that set on purpose, because a name collision there would
	// retarget the plugin serving the ordinary GPU node group.
	nameOf := regexp.MustCompile(`(?m)^  name:\s*(\S+)`)
	owner := map[string]string{}
	for _, o := range devicePluginOverlays {
		b, _ := os.ReadFile("../../config/" + o + "/daemonset.yaml")
		for _, n := range nameOf.FindAllStringSubmatch(string(b), -1) {
			if prev, dup := owner[n[1]]; dup && prev != o {
				t.Errorf("config/%s and config/%s both declare %q; applying one would adopt the other's "+
					"DaemonSet instead of replacing it", prev, o, n[1])
			}
			owner[n[1]] = o
		}
	}
}

// The matrix must apply a device plugin for every arm it deploys, including the control.
//
// This is the check that would have caught the missing whole-card plugin. The script applied one for the two
// sharing arms and nothing for `shared`, which reads as an omission only if you already know the sharing
// node has no plugin of its own -- so the guard is mechanical: every arm in the case statement reaches
// apply_device_plugin.
func TestTheMatrixAppliesADevicePluginForEveryArm(t *testing.T) {
	body, err := os.ReadFile("../../hack/m5c-matrix.sh")
	if err != nil {
		t.Fatalf("read the matrix: %v", err)
	}
	src := string(body)

	for _, arm := range []string{"shared", "timeSlicing", "mps"} {
		if !regexp.MustCompile(`(?m)^\s+`+arm+`\)\s`).MatchString(src) &&
			!strings.Contains(src, arm+"|") && !strings.Contains(src, "|"+arm) {
			t.Errorf("hack/m5c-matrix.sh has no case branch for the %s arm", arm)
		}
	}
	if !strings.Contains(src, "apply_device_plugin shared") {
		t.Error("hack/m5c-matrix.sh does not apply a device plugin for the `shared` arm; nothing advertises " +
			"nvidia.com/gpu on the sharing node, so the control's engine would sit Pending or inherit the " +
			"previous arm's split card")
	}
	if !strings.Contains(src, `apply_device_plugin "$arm"`) {
		t.Error("hack/m5c-matrix.sh does not apply a device plugin for the sharing arms")
	}
	// Exactly, not at least: `-ge` reads the previous arm's larger advertisement as success, which is how a
	// one-device arm starts on a card the last arm already split.
	if !strings.Contains(src, `-eq "$want"`) {
		t.Error("hack/m5c-matrix.sh does not require the node to advertise EXACTLY the arm's device count; " +
			"a `-ge` comparison passes on the outgoing arm's stale advertisement")
	}
}

// The matrix must pass the WHOLE load to gen-trace, and the served model with it.
//
// hack/m5b-price-of-protection.sh carries the lesson in one line beside its own gen-trace call: "gen-trace's
// defaults are stub-calibrated and the first pilot ran them at a GPU at ten times its prefill capacity."
// hack/m5c-matrix.sh asked its operator for RATE and left everything else defaulted, which is the larger
// half of the same mistake and could not be fixed by any choice of RATE:
//
//   - The default mix is premium 1, noisy 1 and two probe tenants at 0.1, so the 40,000-character contender
//     takes about 45% of arrivals. At roughly 1.03 s of engine per contender prompt -- the figure the paid
//     evidence measured -- that is four to five times an A10G's prefill capacity at the rate this study
//     would use, and every arm is censored.
//   - Lowering RATE until the contender fits leaves the premium tenant below the MinTailSamples floor that
//     reading 4b exists to enforce, so the run is INVALID from the other direction.
//
// And --model, which is a different failure with the same silence: gen-trace defaults to "llama-3-8b",
// internal/gateway resolves a backend by matching the requested model against the InferenceDeployment index
// in the tenant's namespace, and the routing records this script writes serve Qwen2.5-3B. Every request of
// every arm would have come back ErrNoRoute, after both engines had finished loading.
func TestTheMatrixPassesTheWholeLoadAndTheModelToGenTrace(t *testing.T) {
	src, err := os.ReadFile("../../hack/m5c-matrix.sh")
	if err != nil {
		t.Fatalf("read the matrix: %v", err)
	}
	body := string(src)

	// COMMENTS STRIPPED FIRST, and this is not tidiness.
	//
	// The first version of this test matched from the word "gen-trace" onwards over the whole file, and the
	// rationale comment directly above the call names every flag it is arguing for -- including --model. So
	// deleting `--model "$MODEL"` from the actual command left this test green, satisfied entirely by the
	// prose explaining why the flag matters. Found by deleting the flag and watching nothing go red, which
	// is the same way this repository found `use_name_prefix` and CONFIG_FILE being satisfied by comments.
	var code strings.Builder
	for line := range strings.SplitSeq(body, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		code.WriteString(line)
		code.WriteString("\n")
	}
	stripped := code.String()

	gen := regexp.MustCompile(`(?s)benchharness" gen-trace.*?manifest-out[^\n]*\n`).FindString(stripped)
	if gen == "" {
		t.Fatal("hack/m5c-matrix.sh has no gen-trace invocation to check")
	}
	for _, flag := range []string{
		"--rate", "--duration-ms", "--model",
		"--premium-weight", "--noisy-weight", "--probe-weight",
	} {
		if !strings.Contains(gen, flag) {
			t.Errorf("the matrix's gen-trace call does not pass %s, so it takes the harness's "+
				"stub-calibrated default for it", flag)
		}
	}

	// Refused, not defaulted. A default the operator never sees is how the stub calibration got onto a card
	// the first time.
	for _, v := range []string{"RATE", "PREMIUM_WEIGHT", "NOISY_WEIGHT", "PROBE_WEIGHT", "DURATION_MS"} {
		if !strings.Contains(stripped, v) {
			t.Errorf("the matrix never mentions %s", v)
			continue
		}
		if regexp.MustCompile(`(?m)^` + v + `="\$\{` + v + `:-`).MatchString(stripped) {
			t.Errorf("the matrix gives %s a default. Every part of the load has to be derived on the card "+
				"this run is using; a default here is a number nobody measured arriving in the evidence", v)
		}
	}

	// The derived trace length is gone, and it must stay gone: 500/(RATE/2) assumes the two tenants split
	// arrivals evenly, which is true of the defaults this study is refusing and false of any mix it derives.
	if regexp.MustCompile(`DURATION_MS=\$\(python3`).MatchString(stripped) {
		t.Error("the matrix still derives DURATION_MS from RATE, overwriting whatever the caller measured; " +
			"the arithmetic assumes an even tenant split, which is the premise a calibrated mix abandons")
	}
}

// sessionRunners are the scripts that build an EC2 user-data payload and launch an instance with it.
var sessionRunners = []string{
	"hack/m5b-scheduler-microtest.sh",
	"hack/m5b-price-of-protection.sh",
	"hack/queuelab-gpu-session.sh",
	"hack/m5c-gpu-session.sh",
}

// Every runner that builds user-data must re-emit the shebang, and must refuse a payload that lacks one.
//
// These scripts keep the instance's script in a heredoc and strip it on the way out -- EC2 caps user-data at
// 25600 encoded bytes and the explanations do not fit. The stripping starts with `tail -n +2`, which drops
// line 1, which is `#!/bin/bash`. cloud-init executes user-data as a script ONLY when it begins with `#!`.
//
// hack/m5c-gpu-session.sh was written from the shape of the others and dropped that line. On 2026-09-11 its
// first paid run launched a g5.2xlarge, cloud-init declined to execute the payload, and the instance sat
// idle for 145 minutes -- about $1.64 -- and produced nothing. There was not even a log, because the trap
// that uploads one lives inside the script that never ran.
//
// NOTHING CAUGHT IT, and that is why this test exists rather than a comment. `bash -n` passes on a script
// with no shebang, since it parses fine. The characterization goldens pass because the stubs record the
// launch without executing the payload. Every check was green and none of them could see it.
func TestEverySessionRunnerEmitsAShebangAndRefusesAPayloadWithout(t *testing.T) {
	for _, r := range sessionRunners {
		body := readRepoFile(t, r)

		// It must put the shebang back after stripping it.
		if !strings.Contains(body, `echo "#!/bin/bash"`) {
			t.Errorf("%s never re-emits a shebang. Its user-data stripping drops the heredoc's own with "+
				"`tail -n +2`, so cloud-init would not execute the payload and the instance would boot, do "+
				"nothing, and bill until its backstop", r)
		}

		// And it must refuse rather than launch if one is missing anyway -- a guard that only works when
		// the code above it is right is not a guard.
		if !regexp.MustCompile(`head -1 "\$UD" \| grep -q '\^#!'`).MatchString(body) {
			t.Errorf("%s does not check that its generated user-data begins with a shebang before launching. "+
				"`bash -n` cannot see this: a script without one parses perfectly and does not run", r)
		}
	}
}

// The session script and the matrix must agree on which arms a default run measures.
//
// hack/m5c-gpu-session.sh EXPORTS ARMS into hack/m5c-matrix.sh, so when the two defaults differ the
// session's wins silently and the matrix's is dead text. They did differ: the matrix gained R1 after the
// first paid run showed its readings could not be evaluated without the isolated baseline, and the session
// still carried the three-arm list, which would have bought a second run with no denominator.
//
// This is the same defect shape the repetition-count test above was written for, where two scripts that do
// not read each other disagreed about REPS and a re-run silently bought half the repetitions the design was
// built on. The fix is not the value. It is that a disagreement now fails.
func TestTheSessionAndTheMatrixAgreeOnTheArms(t *testing.T) {
	re := regexp.MustCompile(`(?m)^ARMS="\$\{ARMS:-([^}]*)\}"\s*$`)

	want, wantFrom := "", ""
	for _, script := range []string{"hack/m5c-matrix.sh", "hack/m5c-gpu-session.sh"} {
		m := re.FindStringSubmatch(readRepoFile(t, script))
		if m == nil {
			t.Fatalf("%s has no ARMS default in the expected form", script)
		}
		if want == "" {
			want, wantFrom = m[1], script
			continue
		}
		if m[1] != want {
			t.Errorf("%s defaults ARMS to %q but %s defaults to %q. The session exports this into the matrix, "+
				"so the difference is not a preference: it decides which arms a paid run measures",
				script, m[1], wantFrom, want)
		}
	}

	// And R1 has to be among them, because it is the denominator of both of this study's bars.
	if !strings.Contains(want, ArmR1) {
		t.Errorf("the default arm set is %q and does not include %s, the isolated baseline both bars are "+
			"ratios against. A run without it can produce numerators and nothing to divide them by", want, ArmR1)
	}
}
