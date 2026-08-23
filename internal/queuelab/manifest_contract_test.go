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
	// A toleration must actually TOLERATE the taint, not merely mention its key. The first version of this
	// accepted any entry with a matching key, so operator, value and effect could all be wrong -- a
	// `nvidia.com/gpu=wrong:NoExecute` toleration would have passed while leaving every Pod Pending against
	// the node's `nvidia.com/gpu=present:NoSchedule`. A test that checks the name of the thing rather than
	// the thing is the failure this file exists to catch, committed inside the file.
	//
	// The rule is Kubernetes': Exists matches any value, Equal matches only its own, and an empty effect
	// matches every effect.
	tolerates := func(t corev1.Taint) bool {
		for _, tol := range flavor.Spec.Tolerations {
			if tol.Key != t.Key {
				continue
			}
			if tol.Effect != "" && tol.Effect != t.Effect {
				continue
			}
			switch tol.Operator {
			case corev1.TolerationOpExists:
				return true
			case corev1.TolerationOpEqual, "":
				if tol.Value == t.Value {
					return true
				}
			}
		}
		return false
	}
	// The effect and value are read from the terraform beside the key, so the toleration is checked against
	// the taint as declared rather than against its name alone.
	effects := regexp.MustCompile(`(?m)^\s*effect\s*=\s*"([^"]+)"`).FindAllStringSubmatch(tf, -1)
	values := regexp.MustCompile(`(?m)^\s*value\s*=\s*"([^"]+)"`).FindAllStringSubmatch(tf, -1)
	for i, m := range keys {
		key := m[1]
		// The lab's own ownership taint is keyed per run and is applied by the harness, not by terraform.
		if strings.HasPrefix(key, "queuelab.") {
			continue
		}
		taint := corev1.Taint{Key: key}
		if i < len(values) {
			taint.Value = values[i][1]
		}
		if i < len(effects) {
			// Terraform spells the effect NO_SCHEDULE; the API spells it NoSchedule.
			taint.Effect = corev1.TaintEffect(
				strings.ReplaceAll(strings.Title(strings.ToLower(
					strings.ReplaceAll(effects[i][1], "_", " "))), " ", ""))
		}
		if !tolerates(taint) {
			t.Fatalf("the GPU node group taints %s=%s:%s and the run's ResourceFlavor does not tolerate it, "+
				"so every trace Pod stays Pending while Kueue reports the Workload admitted",
				taint.Key, taint.Value, taint.Effect)
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
	// The VALUE, not the name. Checking only that the variable appears accepts `value: "false"`, which
	// disables the very mapping this test exists to require -- the same name-not-thing mistake the
	// toleration check above was making.
	if !regexp.MustCompile(`name:\s*DCGM_EXPORTER_KUBERNETES\s*\n\s*value:\s*"true"`).MatchString(ds) {
		t.Fatal("the exporter does not enable the kubernetes mapping with value \"true\", so no sample will " +
			"carry a pod label and every device claim will fail attribution for a reason that is not about " +
			"the card")
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

// The infrastructure must be able to run the axes the preregistration promises.
//
// The GPU node group was capped at one node while the preregistration promised a node comparison. The cap
// saved nothing -- desired_size is 0 either way, and nothing bills at zero -- so a number nobody had argued
// for made a preregistered axis unrunnable. The failure would not have been silent (`-compare -mode node`
// refuses a set in which nothing varies) but it would have been discovered on the rented node.
//
// This ties the promise to the capability. If the node axis is ever withdrawn from the preregistration, this
// test should be deleted with it rather than left asserting a requirement nothing has.
//
// Mutation that turns this red: put the cap back to 1.
func TestTheGPUNodeGroupCanRunTheAxesThePreregistrationPromises(t *testing.T) {
	prereg := repoFile(t, "hack/gpu-session-preregistration.md")
	if !strings.Contains(prereg, "-mode node") {
		t.Skip("the preregistration no longer promises a node axis, so nothing here is required")
	}
	tf := repoFile(t, "infra/aws/cluster/eks.tf")
	// The GPU group is the block carrying the NVIDIA AMI; read its cap rather than the first one in the file.
	gpu := tf[strings.Index(tf, "gpu = {"):]
	if i := strings.Index(gpu, "AL2023_x86_64_NVIDIA"); i < 0 {
		t.Fatal("the GPU node group is not the block this test thinks it is; it must be rewritten rather " +
			"than left matching the wrong sizes")
	}
	m := regexp.MustCompile(`max_size\s*=\s*(\d+)`).FindStringSubmatch(gpu)
	if m == nil {
		t.Fatal("the GPU node group declares no max_size")
	}
	max, err := strconv.Atoi(m[1])
	if err != nil {
		t.Fatalf("max_size %q is not a number", m[1])
	}
	// Two, because a node comparison needs the node to vary and one node cannot.
	if max < 2 {
		t.Fatalf("the GPU node group caps at %d node(s) and the preregistration promises a node comparison, "+
			"which needs the node to vary; -compare -mode node refuses a set in which nothing does, so a "+
			"session would discover this on the rented hardware. desired_size is 0 either way, so the cap "+
			"buys no cost discipline -- it only removes the choice", max)
	}
	// And the cost control must still be there: a group that defaults to running is the discipline this
	// repository is built around, lost.
	if !regexp.MustCompile(`desired_size\s*=\s*0`).MatchString(gpu) {
		t.Fatal("the GPU node group does not default to zero nodes, so it bills whether or not anybody is " +
			"running an experiment")
	}
}
