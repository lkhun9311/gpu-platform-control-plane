package queuelab

import (
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
)

// repoFile reads a file relative to the repository root.
func repoFile(t *testing.T, rel string) string {
	t.Helper()
	b, err := os.ReadFile("../../" + rel)
	if err != nil {
		t.Fatalf("read %s: %v", rel, err)
	}
	return string(b)
}

// Every taint the GPU node group declares must be tolerated by the flavour a run is admitted under.
//
// This is the defect that would have killed the session most quietly. eks.tf taints the node
// nvidia.com/gpu=present:NoSchedule; nothing else in this repository tolerated it. Kueue checks a podset's
// tolerations against the FLAVOUR's declared taints rather than the node's real ones, so the Workload is
// admitted, the Job unsuspends, the ledger records Admitted -- and the scheduler then refuses the Pod. Every
// arm dies at a barrier with a desync.
//
// Neither existing gate could see it: the canary and the preflight both build their Pods through
// probePodFrom, which sets spec.nodeName and bypasses the scheduler, and NoSchedule is a scheduler
// predicate. Both would call the node healthy.
//
// The taints are read from the terraform rather than restated here, so the two cannot drift apart.
func TestTheFlavourToleratesEveryTaintTheGPUNodeGroupDeclares(t *testing.T) {
	tf := repoFile(t, "infra/aws/cluster/eks.tf")
	keys := regexp.MustCompile(`(?m)^\s*key\s*=\s*"([^"]+)"`).FindAllStringSubmatch(tf, -1)
	if len(keys) == 0 {
		t.Fatal("no taint keys found in eks.tf; this test is reading a shape that has moved and must be " +
			"rewritten rather than deleted")
	}
	flavor := labResourceFlavor(FixtureIdentity{RunID: "r1"}, StudyReclaim, "v")
	tolerates := func(key string) bool {
		for _, tol := range flavor.Spec.Tolerations {
			if tol.Key != key {
				continue
			}
			if tol.Operator == corev1.TolerationOpExists {
				return true
			}
			return true
		}
		return false
	}
	for _, m := range keys {
		key := m[1]
		// The lab's own ownership taint is keyed per run and is applied by the harness, not by terraform.
		if strings.HasPrefix(key, "queuelab.") {
			continue
		}
		if !tolerates(key) {
			t.Fatalf("the GPU node group taints %q and the run's ResourceFlavor does not tolerate it, so "+
				"every trace Pod stays Pending while Kueue reports the Workload admitted", key)
		}
	}
}

// The exporter must be configured to emit the labels the parser reads, and to collect often enough for the
// gate that judges it.
//
// Both defaults are against us and both are silent. dcgm-exporter's kubernetes mapping is OFF by default:
// mounting the kubelet's pod-resources socket is necessary and not sufficient, and without the mapping every
// sample arrives with no pod label -- which ParseDCGMUtilisation skips, so a healthy exporter reporting full
// utilisation yields zero attributable samples and the harness reports that the observer could not
// attribute. And the collection interval defaults to thirty seconds, while the exporter serves a CACHED
// snapshot in between, so the pod-to-device mapping in a served scrape can be far staler than the
// stale-label margin the exclusivity clause allows.
func TestTheExporterManifestEmitsWhatTheParserReads(t *testing.T) {
	ds := repoFile(t, "config/dcgm-exporter/daemonset.yaml")
	if !strings.Contains(ds, "DCGM_EXPORTER_KUBERNETES") {
		t.Fatal("the exporter does not enable the kubernetes mapping, so no sample will carry a pod label " +
			"and every device claim will fail attribution for a reason that is not about the card")
	}
	m := regexp.MustCompile(`-\s*"-c"\s*\n\s*-\s*"(\d+)"`).FindStringSubmatch(ds)
	if m == nil {
		t.Fatal("the exporter names no collection interval, so it takes the 30 s default while serving a " +
			"cached snapshot in between")
	}
	ms, err := strconv.Atoi(m[1])
	if err != nil {
		t.Fatalf("collection interval %q is not a number", m[1])
	}
	if got := time.Duration(ms) * time.Millisecond; got >= maxObserverGap {
		t.Fatalf("the exporter collects every %s, which is not shorter than the %s gap a run may blink "+
			"through: a collection slower than the gap cannot cover the interval it is asked about",
			got, maxObserverGap)
	}
}

// The session script must address the exporter's container by a name the manifest actually uses.
//
// It hardcoded the DAEMONSET's name where the CONTAINER's belonged, matched nothing, and exited on the first
// command of the session. What makes that worth a test rather than a fix is how it was "verified": a
// stand-in DaemonSet was written with the container name the script expected, so the check confirmed the
// script agreed with a fixture built from the script. The manifest is the only thing worth checking against.
func TestTheSessionScriptAddressesTheExportersRealContainer(t *testing.T) {
	sh := repoFile(t, "hack/gpu-session.sh")
	ds := repoFile(t, "config/dcgm-exporter/daemonset.yaml")
	names := regexp.MustCompile(`(?m)^\s{8}-\s+name:\s+(\S+)`).FindAllStringSubmatch(ds, -1)
	if len(names) == 0 {
		t.Fatal("no container name found in the exporter manifest")
	}
	container := names[0][1]
	for _, hardcoded := range regexp.MustCompile(`@\.name==\\?"([^"\\]+)\\?"`).FindAllStringSubmatch(sh, -1) {
		if strings.HasPrefix(hardcoded[1], "$") {
			continue // derived from the manifest at run time, which is the point
		}
		if hardcoded[1] != container {
			t.Fatalf("the script selects container %q and the manifest declares %q, so it resolves nothing "+
				"and exits before the preflight", hardcoded[1], container)
		}
	}
	// exec replaces the shell and destroys the EXIT trap that tears the port-forward down, so the two must
	// not appear together.
	if regexp.MustCompile(`(?m)^exec\s`).MatchString(sh) && strings.Contains(sh, "trap ") {
		t.Fatal("the script installs an EXIT trap and then execs, which destroys it: the port-forward the " +
			"trap promises to clean up is either orphaned or dies with the runner")
	}
}
