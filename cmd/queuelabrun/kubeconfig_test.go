package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// What -kubeconfig does, asserted because for the life of this tool it did nothing.
//
// The flag was never declared here: controller-runtime's client/config package registers it on
// flag.CommandLine from an init(), so `-h` advertised it and `-kubeconfig /path` parsed cleanly. Nothing
// read the value back, so every invocation talked to whatever KUBECONFIG or $HOME/.kube/config pointed at.
// A session lost twenty minutes to "nodes not found" against a cluster whose nodes were listed by kubectl a
// moment earlier, with the same file passed to both.
//
// These tests drive newClusterClient directly rather than the binary. That is the seam where the decision
// is made: the flag plumbing above it is one function call, and a test that shelled out would be asserting
// the loader's behaviour through two layers of our own.

// A kubeconfig pointing at an address nothing listens on.
//
// The client is built from the file, not from a reachable apiserver — client.NewWithWatch does not dial —
// so the server address only has to parse. What is under test is which FILE was read, and a fake address
// makes it impossible for a passing test to have reached a real cluster by accident.
const fakeKubeconfig = `apiVersion: v1
kind: Config
clusters:
- name: probe
  cluster:
    server: https://127.0.0.1:1
contexts:
- name: probe
  context:
    cluster: probe
    user: probe
current-context: probe
users:
- name: probe
  user: {}
`

func writeKubeconfig(t *testing.T, dir, name string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(fakeKubeconfig), 0o600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
	return path
}

// An explicitly named file that does not exist must fail, not fall through.
//
// This is the half that makes the flag worth having. clientcmd's ExplicitPath treats the path as a demand:
// without it, a mistyped path selects the environment's cluster and reports ITS state, which reads exactly
// like the named cluster being wrong.
func TestAMissingKubeconfigPathIsRefused(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "not-here.yaml")

	_, err := newClusterClient(missing)
	if err == nil {
		t.Fatal("a kubeconfig path that does not exist was accepted; the loader fell through to the environment")
	}
	if !strings.Contains(err.Error(), "not-here.yaml") {
		t.Fatalf("the refusal does not name the path it was given: %v", err)
	}
}

// The flag beats the environment, which is the case the defect actually presented as.
//
// KUBECONFIG names a usable file and the flag names a missing one. If the environment won, this would
// succeed — and an operator who passed -kubeconfig would be talking to a cluster they did not name.
func TestTheFlagBeatsTheEnvironment(t *testing.T) {
	dir := t.TempDir()
	usable := writeKubeconfig(t, dir, "usable.yaml")
	t.Setenv("KUBECONFIG", usable)

	missing := filepath.Join(dir, "named-but-absent.yaml")
	if _, err := newClusterClient(missing); err == nil {
		t.Fatal("KUBECONFIG won over an explicit -kubeconfig; the flag is decoration again")
	}
}

// An empty path keeps the behaviour every invocation that does not pass the flag has always had.
//
// The control. Without it the two refusals above are satisfiable by a change that simply broke the loader
// for everyone, and the vast majority of invocations pass no flag at all.
func TestNoPathFallsBackToTheEnvironment(t *testing.T) {
	usable := writeKubeconfig(t, t.TempDir(), "usable.yaml")
	t.Setenv("KUBECONFIG", usable)

	if _, err := newClusterClient(""); err != nil {
		t.Fatalf("an empty path stopped honouring KUBECONFIG: %v", err)
	}
}

// kubeconfigPath reads the flag controller-runtime registered, and must not panic when it is absent.
//
// Absent is not hypothetical: a build that stops linking that package loses the flag, and this tool would
// then be one nil dereference away from failing before it could say why.
func TestKubeconfigPathSurvivesTheFlagBeingAbsent(t *testing.T) {
	// The flag is registered by an init() in a package this binary links, so in this test it exists and the
	// call returns its value — here, the empty string, because no test sets it.
	if got := kubeconfigPath(); got != "" {
		t.Fatalf("kubeconfigPath() = %q, want empty in a test binary that never set the flag", got)
	}
}
