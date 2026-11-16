package bench

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// TestReviewedProfileArgsAreTheReviewRecords: the arguments runtime identity is compared with come from the reviewed records, whose hashes the registration pins.
func TestReviewedProfileArgsAreTheReviewRecords(t *testing.T) {
	d := versionAsyncDesign()
	for tr, file := range map[string]string{TreatmentB: "vllm-v0.32.0-async-off.json", TreatmentC: "vllm-v0.32.0-async-on.json"} {
		raw, err := os.ReadFile(filepath.Join("..", "..", "hack", "engine-flag-reviews", file))
		if err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256(raw)
		if hex.EncodeToString(sum[:]) != d.EngineFlagReviews[tr] {
			t.Fatalf("%s no longer hashes to treatment %s's registered review", file, tr)
		}
		var rec struct {
			RenderedProfileArgs []string `json:"renderedProfileArgs"`
		}
		if err := json.Unmarshal(raw, &rec); err != nil {
			t.Fatal(err)
		}
		if !slices.Equal(d.ReviewedProfileArgs[tr], rec.RenderedProfileArgs) {
			t.Fatalf("treatment %s compares with %v, its review record lists %v", tr, d.ReviewedProfileArgs[tr], rec.RenderedProfileArgs)
		}
	}
	// A is the validated v0.27.1 profile, which differs from B only in the release; the controller tests hold both renderings equal.
	if !slices.Equal(d.ReviewedProfileArgs[TreatmentA], d.ReviewedProfileArgs[TreatmentB]) {
		t.Fatalf("A's arguments %v differ from B's %v, but the profile is the same", d.ReviewedProfileArgs[TreatmentA], d.ReviewedProfileArgs[TreatmentB])
	}
}

// TestParseProfileArgsStripsWhatEveryDeploymentSets: what is compared is the profile, not the model, port or names a deployment adds.
func TestParseProfileArgsStripsWhatEveryDeploymentSets(t *testing.T) {
	argv := []string{
		"vllm", "serve", "Qwen/Qwen2.5-3B-Instruct",
		"--dtype=half", "--max-model-len", "16384", "--max-num-seqs=64", "--gpu-memory-utilization=0.90",
		"--no-enable-prefix-caching", "--max-num-batched-tokens=512", "--scheduling-policy", "priority", "--async-scheduling",
		"--port=8000", "--served-model-name=qwen", "--revision=abc", "--tokenizer-revision", "abc",
	}
	got, err := ParseProfileArgs(argv)
	if err != nil {
		t.Fatal(err)
	}
	if want := versionAsyncDesign().ReviewedProfileArgs[TreatmentC]; !slices.Equal(got, want) {
		t.Fatalf("parsed %v, want %v", got, want)
	}
	// A profile flag that lost its value parses as a bare flag and then fails the comparison, which is where it is caught.
	if got, _ := ParseProfileArgs([]string{"vllm", "serve", "m", "--max-model-len"}); slices.Equal(got, []string{"--max-model-len=16384"}) {
		t.Fatal("a flag without its value parsed as the reviewed one")
	}
	for _, bad := range [][]string{
		{"vllm", "serve", "m", "--port"},                          // a deployment flag missing its value
		{"vllm", "serve", "m", "--dtype=half", "--dtype=float16"}, // a flag given twice
		{"python", "-m", "something"},                             // not a vllm serve command line
	} {
		if _, err := ParseProfileArgs(bad); err == nil {
			t.Errorf("%v was parsed", bad)
		}
	}
}

// TestCheckRuntimeNeedsNoBundle: a wrong engine is refused at preflight, before calibration spends hours on it.
func TestCheckRuntimeNeedsNoBundle(t *testing.T) {
	d := versionAsyncDesign()
	rt := RuntimeIdentity{
		Model: d.Model, Tokenizer: d.Model,
		VLLMVersion: "v0.27.1", Image: d.Engines[TreatmentA].Image, ModelRevision: d.ModelRevision,
		TokenizerRevision: d.TokenizerRevision, ChatTemplateSHA256: d.ChatTemplateSHA256,
		ProfileArgs: d.ReviewedProfileArgs[TreatmentA], Settings: d.Engines[TreatmentA],
	}
	if err := d.CheckRuntime(TreatmentA, rt); err != nil {
		t.Fatalf("A's registered runtime was refused: %v", err)
	}
	rt.ProfileArgs = d.ReviewedProfileArgs[TreatmentC]
	if err := d.CheckRuntime(TreatmentA, rt); err == nil || !strings.Contains(err.Error(), "arguments") {
		t.Fatalf("A running C's arguments: %v", err)
	}
}
