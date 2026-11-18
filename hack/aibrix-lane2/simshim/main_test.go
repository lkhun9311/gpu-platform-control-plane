package main

import (
	"slices"
	"testing"
)

// The rendered container's arguments reach the simulator without the one flag it does not know, in either spelling.
func TestSimArgsDropsModelPathAndAppendsTheExtraArguments(t *testing.T) {
	extra := `--port 8080 --fake-metrics {"kv-cache-usage":0.25}`
	want := []string{simulator, "--model", "chat", "--port", "8080", "--fake-metrics", `{"kv-cache-usage":0.25}`}
	for _, in := range [][]string{
		{"--model", "chat", "--model-path", "s3://models/chat"},
		{"--model", "chat", "--model-path=s3://models/chat"},
	} {
		if got := simArgs(in, extra); !slices.Equal(got, want) {
			t.Errorf("simArgs(%q) = %q, want %q", in, got, want)
		}
	}
}
