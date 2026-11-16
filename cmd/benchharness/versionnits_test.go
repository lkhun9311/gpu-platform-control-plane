package main

import (
	"bytes"
	"errors"
	"flag"
	"strings"
	"testing"
)

// TestHelpIsNotAnError: -h on a version subcommand prints usage and succeeds.
func TestHelpIsNotAnError(t *testing.T) {
	for _, run := range []func([]string, *bytes.Buffer) error{
		func(a []string, b *bytes.Buffer) error { return versionBundle(a, b) },
		func(a []string, b *bytes.Buffer) error { return versionManifests(a, b) },
		func(a []string, b *bytes.Buffer) error { return versionCalibrate(a, b) },
	} {
		var out, errOut bytes.Buffer
		err := run([]string{"-h"}, &out)
		if !errors.Is(err, flag.ErrHelp) {
			t.Fatalf("-h returned %v, want flag.ErrHelp", err)
		}
		if code := exitCode(err, &errOut); code != 0 || strings.Contains(errOut.String(), "error:") {
			t.Fatalf("exit %d with %q, want 0 and no error line", code, errOut.String())
		}
	}
	var errOut bytes.Buffer
	if code := exitCode(errors.New("boom"), &errOut); code != 1 || !strings.Contains(errOut.String(), "error: boom") {
		t.Fatalf("a real error: exit %d %q", code, errOut.String())
	}
}

// TestVersionManifestsRequiresTheEngineURL: the usage names -engine-url and the miss is refused before the bundle is read.
func TestVersionManifestsRequiresTheEngineURL(t *testing.T) {
	var out bytes.Buffer
	err := versionManifests([]string{"-bundle", "x", "-blocks", "1", "-out", "y"}, &out)
	if err == nil || !strings.Contains(err.Error(), "-engine-url") {
		t.Fatalf("no engine URL: %v, want a refusal naming -engine-url", err)
	}
}
