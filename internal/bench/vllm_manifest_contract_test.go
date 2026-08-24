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
	"encoding/json"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/yaml"
)

// The manifest's numbers are only as good as the measurements they came from, and prose in a header cannot
// keep the two in step. These tests read config/vllm/deployment.yaml and the recorded calibration and fail
// when an edit to either breaks the relationship the other depends on.
//
// Each case below corresponds to something that has actually gone wrong -- an engine that refused to start,
// an engine that started and served the wrong thing, or a Pod that never scheduled at all.

// calibration is the measured tokenizer record; see testdata/tokenizer_calibration.json.
type calibration struct {
	PromptCorpusSHA256 string `json:"promptCorpusSHA256"`
	Tokenizer          string `json:"tokenizer"`
	Samples            []struct {
		PromptLenChars int `json:"promptLenChars"`
		ActualTokens   int `json:"actualTokens"`
	} `json:"samples"`
}

func loadCalibration(t *testing.T) calibration {
	t.Helper()
	b, err := os.ReadFile("testdata/tokenizer_calibration.json")
	if err != nil {
		t.Fatalf("read calibration: %v", err)
	}
	var c calibration
	if err := json.Unmarshal(b, &c); err != nil {
		t.Fatalf("parse calibration: %v", err)
	}
	return c
}

func loadVLLMDeployment(t *testing.T) appsv1.Deployment {
	t.Helper()
	b, err := os.ReadFile("../../config/vllm/deployment.yaml")
	if err != nil {
		t.Fatalf("read deployment: %v", err)
	}
	var d appsv1.Deployment
	if err := yaml.Unmarshal(b, &d); err != nil {
		t.Fatalf("parse deployment: %v", err)
	}
	return d
}

func vllmContainer(t *testing.T, d appsv1.Deployment) corev1.Container {
	t.Helper()
	for _, c := range d.Spec.Template.Spec.Containers {
		if c.Name == "vllm" {
			return c
		}
	}
	t.Fatal("deployment has no container named vllm")
	return corev1.Container{}
}

// argValue returns the value of a --flag=value argument, and whether it was present.
func argValue(args []string, flag string) (string, bool) {
	for _, a := range args {
		if v, ok := strings.CutPrefix(a, flag+"="); ok {
			return v, true
		}
	}
	return "", false
}

// The calibration was measured against one tokenizer; the Deployment must serve that model.
//
// Every token count this experiment reports -- the contender's 7,695, the false-positive band around the
// guard's threshold -- is a property of a specific vocabulary and chat template. Serving a different model
// leaves those numbers in the report describing traffic that was never sent.
func TestServedModelIsTheOneTheCalibrationWasMeasuredAgainst(t *testing.T) {
	cal := loadCalibration(t)
	c := vllmContainer(t, loadVLLMDeployment(t))

	served := ""
	for _, a := range c.Args {
		if !strings.HasPrefix(a, "-") {
			served = a
			break
		}
	}
	if served != cal.Tokenizer {
		t.Fatalf("deployment serves %q but the calibration was measured against %q", served, cal.Tokenizer)
	}
	if cal.PromptCorpusSHA256 != PromptCorpusSHA256 {
		t.Fatalf("calibration was measured against corpus %s but this binary sends %s",
			cal.PromptCorpusSHA256, PromptCorpusSHA256)
	}
}

// The context window must hold the largest prompt the trace actually sends, plus its output.
//
// vLLM rejects an over-long request with a 400, and the harness records a 400 as an http error rather than
// as a rejection -- so a context window one token too small would empty the contender population from every
// arm at once and leave four arms that agree because none of them ran the experiment.
func TestContextWindowHoldsTheLargestMeasuredPrompt(t *testing.T) {
	cal := loadCalibration(t)
	c := vllmContainer(t, loadVLLMDeployment(t))

	raw, ok := argValue(c.Args, "--max-model-len")
	if !ok {
		t.Fatal("deployment does not set --max-model-len")
	}
	maxLen, err := strconv.Atoi(raw)
	if err != nil {
		t.Fatalf("--max-model-len %q is not a number: %v", raw, err)
	}

	largest := 0
	for _, s := range cal.Samples {
		if s.ActualTokens > largest {
			largest = s.ActualTokens
		}
	}
	if largest == 0 {
		t.Fatal("calibration records no samples")
	}
	// 64 is the largest MaxOutputTokens any tenant in cmd/benchharness asks for.
	const largestOutput = 64
	if maxLen < largest+largestOutput {
		t.Fatalf("--max-model-len=%d cannot hold the largest measured prompt (%d tokens) plus its output (%d)",
			maxLen, largest, largestOutput)
	}
}

// The flagship and the sharing matrix must serve the same model at the same dtype, or they measure two things.
//
// This assertion used to be that dtype is startable on a T4: vLLM's platforms/cuda.py refuses bfloat16
// below sm_80, so on sm_75 fp16 was a startup condition. The card is an A10G now (sm_86), which accepts
// bfloat16 -- so that reason is gone, and asserting it would be asserting something false.
//
// The reason that replaced it is stronger, because it binds two files instead of restating a vendor limit.
// M5-c's exclusive arm IS this configuration, one engine with the card to itself, so the flagship's result
// is that arm. Engines that differed in dtype would make the matrix compare sharing mode AND numerics, and
// the difference would be attributed to the mode.
func TestTheFlagshipAndTheSharingMatrixAgreeOnModelAndDtype(t *testing.T) {
	flagship := vllmContainer(t, loadVLLMDeployment(t))
	flagshipDtype, ok := argValue(flagship.Args, "--dtype")
	if !ok {
		t.Fatal("the flagship engine sets no --dtype; it would be inferred from the model config and could differ from the matrix's")
	}

	shared, err := os.ReadFile("../../config/vllm-shared/engines.yaml")
	if err != nil {
		t.Fatalf("read the sharing engines: %v", err)
	}
	dtypes := regexp.MustCompile(`--dtype=([A-Za-z0-9]+)`).FindAllStringSubmatch(string(shared), -1)
	if len(dtypes) == 0 {
		t.Fatal("the sharing engines set no --dtype")
	}
	for _, d := range dtypes {
		if d[1] != flagshipDtype {
			t.Errorf("the flagship serves at --dtype=%s and a sharing engine at --dtype=%s; the matrix would "+
				"compare sharing mode and numerics together", flagshipDtype, d[1])
		}
	}

	flagshipModel := ""
	for _, a := range flagship.Args {
		if !strings.HasPrefix(a, "-") {
			flagshipModel = a
			break
		}
	}
	if !strings.Contains(string(shared), flagshipModel) {
		t.Errorf("the flagship serves %q and the sharing engines do not; the exclusive arm of the matrix is "+
			"supposed to be the flagship's own measurement", flagshipModel)
	}
}

// The sequence cap must sit ABOVE the concurrency that fills the cache, or it becomes the binding limit.
//
// This is the defect that moving from a T4 to an A10G introduced, and it introduces nothing visible. With
// --max-num-seqs below the block limit the engine simply never runs out of blocks: KV usage plateaus under
// the engage threshold, the guard's cache arm never fires, and the arm under test degenerates into the
// waiting arm. Every number still looks reasonable.
//
// 32 was right on a T4, where 24 concurrent contenders filled the cache. The A10G's cache takes 50.
func TestTheSequenceCapDoesNotBindBeforeTheKVCacheDoes(t *testing.T) {
	c := vllmContainer(t, loadVLLMDeployment(t))
	raw, ok := argValue(c.Args, "--max-num-seqs")
	if !ok {
		t.Fatal("the engine sets no --max-num-seqs; vLLM's default would decide whether the cap or the cache binds")
	}
	seqs, err := strconv.Atoi(raw)
	if err != nil {
		t.Fatalf("--max-num-seqs %q is not a number: %v", raw, err)
	}

	util, ok := argValue(c.Args, "--gpu-memory-utilization")
	if !ok {
		t.Fatal("the engine sets no --gpu-memory-utilization, so its cache size is not derivable from the manifest")
	}
	u, err := strconv.ParseFloat(util, 64)
	if err != nil {
		t.Fatalf("--gpu-memory-utilization %q is not a number: %v", util, err)
	}

	plan := SharingPlan{Card: CardA10G, Model: ModelQwen3B, Engines: 1, UtilizationPerEngine: u, NonKVOverheadMiB: 1400}
	if err := plan.Validate(); err != nil {
		t.Fatalf("the flagship's own plan does not validate: %v", err)
	}
	// The largest measured prompt in the trace; the cache fills when this many of them are resident.
	const contenderTokens = 7695
	fills := plan.KVTokensPerEngine() / contenderTokens
	if seqs <= fills {
		t.Errorf("--max-num-seqs=%d is at or below the %d concurrent contenders that fill the cache, so the "+
			"sequence cap binds first and the guard's KV-usage arm can never fire", seqs, fills)
	}
}

// The engine needs 160 MiB of /dev/shm for one worker and a container's default is 64 MiB.
//
// Observed directly: without this mount the engine core dies during startup with "Insufficient space in
// /dev/shm: 160 MiB required, 64 MiB free". The Pod would restart forever and no arm would ever run.
func TestSharedMemoryIsMountedLargeEnoughForTheEngine(t *testing.T) {
	d := loadVLLMDeployment(t)
	c := vllmContainer(t, d)

	mounted := false
	for _, m := range c.VolumeMounts {
		if m.MountPath == "/dev/shm" {
			mounted = true
			for _, v := range d.Spec.Template.Spec.Volumes {
				if v.Name != m.Name {
					continue
				}
				if v.EmptyDir == nil || v.EmptyDir.Medium != corev1.StorageMediumMemory {
					t.Fatalf("/dev/shm volume %q is not a memory-backed emptyDir", v.Name)
				}
				if v.EmptyDir.SizeLimit == nil {
					t.Fatalf("/dev/shm volume %q sets no sizeLimit", v.Name)
				}
				const measuredFloorBytes = 160 << 20
				if v.EmptyDir.SizeLimit.Value() < measuredFloorBytes {
					t.Fatalf("/dev/shm sizeLimit %s is below the measured 160Mi the engine requires", v.EmptyDir.SizeLimit)
				}
			}
		}
	}
	if !mounted {
		t.Fatal("no volume is mounted at /dev/shm; the engine dies at startup on the default 64 MiB")
	}
}

// One replica is the assertion the KV-aware arm rests on, and nothing downstream can detect its violation.
func TestExactlyOneEngineBacksTheService(t *testing.T) {
	d := loadVLLMDeployment(t)
	if d.Spec.Replicas == nil || *d.Spec.Replicas != 1 {
		t.Fatalf("replicas must be exactly 1 so the scraped KV pool is the one requests fill, got %v", d.Spec.Replicas)
	}
	if d.Spec.Strategy.Type != appsv1.RecreateDeploymentStrategyType {
		t.Fatalf("strategy %q allows a second Pod during rollout, which is a second KV pool", d.Spec.Strategy.Type)
	}
}

// The Pod must tolerate every taint the GPU node group declares, or it never schedules.
func TestEngineToleratesTheGPUNodeTaint(t *testing.T) {
	d := loadVLLMDeployment(t)
	tf, err := os.ReadFile("../../infra/aws/cluster/eks.tf")
	if err != nil {
		t.Fatalf("read eks.tf: %v", err)
	}
	if !strings.Contains(string(tf), "nvidia.com/gpu") {
		t.Skip("eks.tf declares no nvidia.com/gpu taint to tolerate")
	}
	for _, tol := range d.Spec.Template.Spec.Tolerations {
		if tol.Key == "nvidia.com/gpu" && tol.Value == "present" && tol.Effect == corev1.TaintEffectNoSchedule {
			return
		}
	}
	t.Fatal("no toleration matches the nvidia.com/gpu=present:NoSchedule taint eks.tf puts on the GPU node group")
}

// The image must be pinned by digest, like every other fixture this experiment's numbers are tied to.
func TestEngineImageIsPinnedByDigest(t *testing.T) {
	c := vllmContainer(t, loadVLLMDeployment(t))
	if !strings.Contains(c.Image, "@sha256:") {
		t.Fatalf("image %q is not digest-pinned; the run would not be reproducible from the manifest", c.Image)
	}
}
