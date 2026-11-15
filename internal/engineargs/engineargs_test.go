package engineargs

import (
	"slices"
	"testing"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// TestProfileArgsAppendTheAsyncChoiceLast: the validated profiles end in --no-async-scheduling, so async off renders their order exactly.
func TestProfileArgsAppendTheAsyncChoiceLast(t *testing.T) {
	off, err := ProfileArgs(platformv1.VLLMReleaseV0320, false)
	if err != nil {
		t.Fatal(err)
	}
	on, err := ProfileArgs(platformv1.VLLMReleaseV0320, true)
	if err != nil {
		t.Fatal(err)
	}
	if off[len(off)-1] != "--no-async-scheduling" || on[len(on)-1] != "--async-scheduling" || !slices.Equal(off[:len(off)-1], on[:len(on)-1]) {
		t.Fatalf("async off %v and on %v differ in more than the last flag", off, on)
	}
	if _, err := ProfileArgs("v0.28.0", false); err == nil {
		t.Fatal("an unreviewed release rendered arguments")
	}
}

// TestProfileArgsReturnACopy: a caller appending to the result must not change the reviewed row.
func TestProfileArgsReturnACopy(t *testing.T) {
	a, _ := ProfileArgs(platformv1.VLLMReleaseV0271, false)
	a[0] = "--dtype=float32"
	b, _ := ProfileArgs(platformv1.VLLMReleaseV0271, false)
	if b[0] == "--dtype=float32" {
		t.Fatal("the reviewed row was changed through a returned slice")
	}
}

// TestCommandPutsTheModelFirstAndTheDeploymentAfterTheProfile is the order vllm serve receives, the same in a Pod and in docker.
func TestCommandPutsTheModelFirstAndTheDeploymentAfterTheProfile(t *testing.T) {
	profile := []string{"--dtype=half", "--no-async-scheduling"}
	got := Command(profile, Deployment{Model: "Qwen/Qwen2.5-3B-Instruct", Port: 8000, ServedName: "qwen", Revision: "abc"})
	want := []string{"Qwen/Qwen2.5-3B-Instruct", "--dtype=half", "--no-async-scheduling",
		"--port=8000", "--served-model-name=qwen", "--revision=abc", "--tokenizer-revision=abc"}
	if !slices.Equal(got, want) {
		t.Fatalf("got %v\nwant %v", got, want)
	}
	capped := Command(profile, Deployment{Model: "m", Port: 1, ServedName: "n", Revision: "r", HoldCap: true})
	if capped[len(capped)-1] != "--long-prefill-token-threshold=384" {
		t.Fatalf("HoldCap did not end in the measured threshold: %v", capped)
	}
}

// TestReleasesAreReviewedRows: every row names a pinned digest and both async spellings.
func TestReleasesAreReviewedRows(t *testing.T) {
	rows := Releases()
	if len(rows) == 0 {
		t.Fatal("no reviewed release")
	}
	for name, r := range rows {
		if r.Digest == "" || len(r.Args) == 0 || r.AsyncOn == "" || r.AsyncOff == "" {
			t.Fatalf("release %s is incomplete: %+v", name, r)
		}
	}
	if rows[platformv1.VLLMReleaseV0320].Digest != platformv1.VLLMV0320Digest || rows[platformv1.VLLMReleaseV0271].Digest != platformv1.VLLMV0271Digest {
		t.Fatal("a release row names a digest other than the API's")
	}
}
