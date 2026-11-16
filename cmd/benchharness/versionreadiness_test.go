package main

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestVersionReadinessRefusesBeforeDocker: a missing flag or a used directory is refused before any command runs,
// because on the instance the next command is a paid image pull.
func TestVersionReadinessRefusesBeforeDocker(t *testing.T) {
	root := t.TempDir()
	used := filepath.Join(root, "used")
	if err := os.MkdirAll(used, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(used, "summary.json"), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	for name, c := range map[string]struct {
		args []string
		want string
	}{
		"no flags":       {nil, "are required"},
		"a used out dir": {[]string{"-dir", used, "-hf-cache", filepath.Join(root, "hf"), "-compile-cache", filepath.Join(root, "cc")}, "out directory"},
		// The out dir is fresh, so only the relative path can be refused, and that happens before any docker call.
		"a relative model cache":   {[]string{"-dir", filepath.Join(root, "fresh1"), "-hf-cache", "hf", "-compile-cache", filepath.Join(root, "cc")}, "not absolute"},
		"a relative compile cache": {[]string{"-dir", filepath.Join(root, "fresh2"), "-hf-cache", filepath.Join(root, "hf"), "-compile-cache", "cache/cc"}, "not absolute"},
	} {
		t.Run(name, func(t *testing.T) {
			err := versionReadiness(c.args, io.Discard)
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("err %v, want %q", err, c.want)
			}
		})
	}
}
