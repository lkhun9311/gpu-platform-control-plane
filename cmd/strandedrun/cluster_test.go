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

package main

import (
	"strings"
	"testing"
)

// A layout that cannot host the phenomenon is refused before a cluster is built for it.
//
// The amendment corrected the original registration here, so the boundary matters: heterogeneous nodes and more
// than two workers are NOT prerequisites -- two identical two-GPU nodes each holding one device already block a
// two-device request with two devices free. What genuinely cannot strand is a single node, or a cluster whose
// largest node holds everything, because then anything that fits at all fits there.
//
// Mutation that turns this red: drop the maxNode >= total check, or lower the two-worker floor.
func TestALayoutThatCannotStrandIsRefused(t *testing.T) {
	for _, tc := range []struct {
		name  string
		l     NodeLayout
		wants string
	}{
		{"a single worker", NodeLayout{4}, "at least two nodes"},
		{"no workers at all", NodeLayout{}, "at least two nodes"},
		{"a worker with no capacity", NodeLayout{2, 0}, "no GPU capacity"},
		{"a negative count", NodeLayout{2, -1}, "no GPU capacity"},
		{"one worker holding everything", NodeLayout{4, 4}, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.l.Validate()
			if tc.name == "one worker holding everything" {
				// 4 and 4: the largest node is 4, the total 8, so a witness q=5 exists and this IS valid.
				if err != nil {
					t.Fatalf("a layout of two equal workers was refused: %v", err)
				}
				return
			}
			if err == nil {
				t.Fatalf("%s was accepted", tc.name)
			}
			if !strings.Contains(err.Error(), tc.wants) {
				t.Errorf("the refusal does not say why: got %q, want it to mention %q", err, tc.wants)
			}
		})
	}
	// The case the check is really for: everything on one node, with a second node that has nothing to give.
	// It passes the two-worker floor and still cannot strand.
	if err := (NodeLayout{5, 1}).Validate(); err != nil {
		t.Errorf("a 5+1 layout was refused, but a request for 2 fits nowhere while 6 devices are free: %v", err)
	}
	// And the minimal honest layout from the amendment: two nodes of two.
	if err := (NodeLayout{2, 2}).Validate(); err != nil {
		t.Errorf("the amendment's own minimal example was refused: %v", err)
	}
}

// The rendered kind configuration must carry the label the device plugin selects on, per worker.
//
// The selector and the count are the same fact read twice, and this is the half the cluster carries. A renderer
// that emitted workers without labels would produce a cluster where the plugin lands nowhere and every node
// advertises nothing -- which reads as a cluster with no GPUs rather than as a broken render.
//
// Mutation that turns this red: stop emitting node-labels.
func TestTheRenderedClusterLabelsEachWorkerWithItsDeviceCount(t *testing.T) {
	const nodeImage = "kindest/node:v1.31.0"
	out, err := KindConfigYAML(ConfiguredArm(MostAllocated), NodeLayout{2, 1, 1}, nodeImage)
	if err != nil {
		t.Fatal(err)
	}
	// Every node pins the image, and the file says which Kubernetes it is for a reader who never runs it.
	//
	// Left to kind, the version is whatever that binary defaults to. This host carries clusters running 1.31.0
	// and 1.35.8, so the same rendered file months apart would run different schedulers with different plugin
	// defaults -- and a difference between RUNS would be indistinguishable from a difference between ARMS.
	if got := strings.Count(out, "image: "+nodeImage); got != 4 {
		t.Errorf("expected all four nodes to pin %s, found %d:\n%s", nodeImage, got, out)
	}
	if !strings.Contains(out, "# Kubernetes: "+nodeImage) {
		t.Errorf("the rendered file does not record which Kubernetes it is for:\n%s", out)
	}
	if strings.Count(out, "- role: worker") != 3 {
		t.Errorf("the layout has three workers and the configuration renders %d:\n%s",
			strings.Count(out, "- role: worker"), out)
	}
	if !strings.Contains(out, NodeLabelKey+"=2") {
		t.Errorf("no worker is labelled for two devices:\n%s", out)
	}
	if strings.Count(out, NodeLabelKey+"=1") != 2 {
		t.Errorf("expected two workers labelled for one device, got %d:\n%s",
			strings.Count(out, NodeLabelKey+"=1"), out)
	}
	if !strings.Contains(out, "name: "+ClusterName) {
		t.Errorf("the cluster is not named %q; reusing another study's cluster is what this name prevents:\n%s",
			ClusterName, out)
	}
	// The scheduler profile must reach the control plane, or the arm is a label on a cluster that ignores it.
	for _, want := range []string{"kind: ClusterConfiguration", "config: /etc/kubernetes/stranded-scheduler.yaml",
		"extraMounts"} {
		if !strings.Contains(out, want) {
			t.Errorf("the control plane does not receive the scheduler profile (%q missing):\n%s", want, out)
		}
	}
}

// An invalid profile or layout must not reach a cluster through the renderer.
//
// Validate() is called inside rather than left to the caller for exactly this: the renderer is the second path
// to a cluster, and a guard on only the first is a guard with a way around it.
//
// Mutation that turns this red: drop either Validate call from KindConfigYAML.
func TestTheClusterRendererRefusesWhatTheValidatorsRefuse(t *testing.T) {
	const nodeImage = "kindest/node:v1.31.0"
	bad := SchedulerProfile{Strategy: MostAllocated, SchedulerName: "default-scheduler",
		Resources: []ResourceWeight{{Name: "cpu", Weight: 1}}}
	if _, err := KindConfigYAML(ArmProfile{Arm: ArmConfigured, Profile: bad}, NodeLayout{2, 1}, nodeImage); err == nil {
		t.Error("a profile that never scores the GPU rendered a cluster configuration")
	}
	if _, err := KindConfigYAML(ConfiguredArm(MostAllocated), NodeLayout{4}, nodeImage); err == nil {
		t.Error("a single-worker layout rendered a cluster configuration")
	}
	if _, err := DevicePluginYAML(NodeLayout{4}, "ns", "img"); err == nil {
		t.Error("a single-worker layout rendered device plugins")
	}
}

// A node image that leaves the Kubernetes version unrecorded is refused.
//
// The amendment requires the scheduler version to be registered. An untagged image is the case that looks fine
// and is not: `kindest/node` resolves to whatever `latest` is on the host, and this host already carries three
// untagged node images pulled in different months.
//
// Mutation that turns this red: accept an empty tag, or drop the validateNodeImage call from KindConfigYAML.
func TestANodeImageThatLeavesTheVersionUnrecordedIsRefused(t *testing.T) {
	for _, tc := range []struct{ name, image, wants string }{
		{"no image at all", "", "registered rather than left"},
		{"no tag", "kindest/node", "resolves to whatever latest"},
		{"an empty tag", "kindest/node:", "resolves to whatever latest"},
		{"no repository", ":v1.31.0", "names no repository"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := KindConfigYAML(ConfiguredArm(MostAllocated), NodeLayout{2, 1}, tc.image)
			if err == nil {
				t.Fatalf("%s was accepted", tc.name)
			}
			if !strings.Contains(err.Error(), tc.wants) {
				t.Errorf("the refusal does not say why: got %q, want it to mention %q", err, tc.wants)
			}
		})
	}
	if _, err := KindConfigYAML(ConfiguredArm(MostAllocated), NodeLayout{2, 1}, "kindest/node:v1.31.0"); err != nil {
		t.Errorf("a tagged node image was refused: %v", err)
	}
}

// One DaemonSet per distinct count, with the selector and the environment variable agreeing.
//
// They are the same fact twice -- a node labelled for two devices must run the plugin that advertises two -- so
// a render where they disagree produces a cluster whose capacity silently differs from its labels, and the
// allocatable readback would be the only thing that noticed.
//
// Mutation that turns this red: emit a fixed FAKE_GPU_COUNT, or select on a different value than the one set.
// The rendered manifest creates the namespace it puts everything into.
//
// A rendered artifact that cannot be applied to an empty cluster is not a rendered artifact. Measured on the
// first reference-arm cluster: every object failed with `namespaces "..." not found`, the nodes advertised
// nothing, and the live capacity loop honestly reported none six times over. The treatment cluster had hidden
// this for a day, because something else had created that namespace there — so a manifest that assumed it
// worked by accident, and only a genuinely empty cluster could show the difference.
//
// Putting the creation in the shell instead would mean the run applies something the renderer never emitted.
//
// Mutation that turns this red: drop the Namespace document, or render it after the DaemonSets.
func TestTheRenderedPluginsCreateTheirOwnNamespace(t *testing.T) {
	const ns = "gpu-platform-control-plane-system"
	out, err := DevicePluginYAML(NodeLayout{2, 1, 1}, ns, "gpu-simulator:latest")
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Count(out, "kind: Namespace"); got != 1 {
		t.Fatalf("the manifest renders %d Namespace document(s), want exactly 1:\n%s", got, out)
	}
	// First, not merely present: kubectl applies in order, and a namespace created after the objects that
	// live in it is a namespace created too late.
	nsAt := strings.Index(out, "kind: Namespace")
	dsAt := strings.Index(out, "kind: DaemonSet")
	if nsAt < 0 || dsAt < 0 || nsAt > dsAt {
		t.Errorf("the Namespace is rendered at %d and the first DaemonSet at %d; it has to come first, "+
			"because kubectl applies in document order:\n%s", nsAt, dsAt, out)
	}
	// It must be the namespace the objects actually name, not just any namespace.
	if !strings.Contains(out, "kind: Namespace\nmetadata:\n  name: "+ns+"\n") {
		t.Errorf("the Namespace document does not name %q:\n%s", ns, out)
	}
	if got := strings.Count(out, "  namespace: "+ns+"\n"); got != 2 {
		t.Errorf("%d object(s) name namespace %q; both DaemonSets must:\n%s", got, ns, out)
	}
	// And the name follows the argument, so a caller cannot get a namespace it did not ask for.
	other, err := DevicePluginYAML(NodeLayout{2, 1}, "some-other-ns", "gpu-simulator:latest")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(other, "kind: Namespace\nmetadata:\n  name: some-other-ns\n") {
		t.Errorf("the Namespace document ignores the namespace argument:\n%s", other)
	}
	if strings.Contains(other, ns) {
		t.Errorf("a namespace nobody asked for leaked into the manifest:\n%s", other)
	}
}

func TestEachDevicePluginAdvertisesWhatItsSelectorAsksFor(t *testing.T) {
	out, err := DevicePluginYAML(NodeLayout{2, 1, 1}, "gpu-platform-control-plane-system", "gpu-simulator:latest")
	if err != nil {
		t.Fatal(err)
	}
	// Two distinct counts, so two DaemonSets separated by one document marker.
	if got := strings.Count(out, "kind: DaemonSet"); got != 2 {
		t.Errorf("the layout has two distinct counts and %d DaemonSet(s) were rendered:\n%s", got, out)
	}
	// Separators are counted against the document count rather than against a literal, so adding a document
	// cannot be absorbed by editing the number here. Adding the Namespace made this assertion fail with a
	// hardcoded 1, which is the reminder it exists to give.
	docs := strings.Count(out, "kind: DaemonSet") + strings.Count(out, "kind: Namespace")
	if got := strings.Count(out, "\n---\n"); got != docs-1 {
		t.Errorf("%d documents need exactly %d separator(s), got %d:\n%s", docs, docs-1, got, out)
	}
	for _, n := range []string{"1", "2"} {
		selector := NodeLabelKey + `: "` + n + `"`
		if !strings.Contains(out, selector) {
			t.Errorf("no DaemonSet selects %s:\n%s", selector, out)
		}
		if !strings.Contains(out, `value: "`+n+`"`) {
			t.Errorf("no DaemonSet sets FAKE_GPU_COUNT to %s:\n%s", n, out)
		}
	}
	// The shared config/device-plugin must be left alone: other studies expect its fixed count of one, so these
	// objects must not collide with its name.
	//
	// Anchored on the two-space indent of a `metadata.name`, not on the token. The first version of this
	// assertion searched for "name: gpu-simulator\n" anywhere in the document and matched the CONTAINER name
	// eight lines lower, which every correct render also carries -- so it failed against output that was right.
	// A substring search over YAML reads tokens, not key paths.
	if strings.Contains(out, "\n  name: gpu-simulator\n") {
		t.Errorf("a rendered DaemonSet is named gpu-simulator, colliding with the shared object:\n%s", out)
	}
	for _, n := range []string{"gpu-simulator-1", "gpu-simulator-2"} {
		if !strings.Contains(out, "\n  name: "+n+"\n") {
			t.Errorf("no DaemonSet is named %s; the name carries the count so two documents cannot collide:\n%s",
				n, out)
		}
	}
	// Every DaemonSet must carry imagePullPolicy, and its absence is the failure that looks like a missing
	// image.
	//
	// A :latest tag defaults to Always, so the kubelet re-pulls even after `kind load docker-image` has placed
	// the layers on the node, and a locally built tag exists in no registry. The first live cluster showed
	// exactly that: three pods scheduled onto the right workers, every label correct, `crictl images` listing
	// the image on all three, and every node advertising zero devices.
	//
	// Mutation that turns this red: drop the imagePullPolicy line from the template.
	if got := strings.Count(out, "imagePullPolicy: IfNotPresent"); got != 2 {
		t.Errorf("expected both DaemonSets to set imagePullPolicy, found %d:\n%s", got, out)
	}

	// A namespace and an image are not defaulted, because a plugin in the wrong namespace advertises from
	// wherever it landed.
	if _, err := DevicePluginYAML(NodeLayout{2, 1}, "", "img"); err == nil {
		t.Error("a DaemonSet rendered with no namespace")
	}
	if _, err := DevicePluginYAML(NodeLayout{2, 1}, "ns", ""); err == nil {
		t.Error("a DaemonSet rendered with no image")
	}
}

// The reference arm renders a cluster with NO scheduler configuration, and keeps the worker capacity labels.
//
// "Untouched" is scoped to the scheduler configuration: the deliberate per-worker capacities and the fake
// device plugins are the environment both arms share. Dropping the worker patches too would make the reference
// a different cluster rather than the same cluster with an unconfigured scheduler.
//
// Mutation that turns this red: emit the extraMounts or the ClusterConfiguration patch for ArmUntouched, or
// drop the JoinConfiguration patches along with them.
func TestTheReferenceArmInstallsNoSchedulerConfigurationAndKeepsTheLabels(t *testing.T) {
	const nodeImage = "kindest/node:v1.31.0"
	out, err := KindConfigYAML(UntouchedArm(), NodeLayout{2, 1, 1}, nodeImage)
	if err != nil {
		t.Fatalf("the reference arm was refused: %v", err)
	}
	for _, absent := range []string{
		"extraMounts",
		"scheduler-config.yaml",
		"ClusterConfiguration",
		"/etc/kubernetes/stranded-scheduler.yaml",
		"extraVolumes",
		"config:",
	} {
		if strings.Contains(out, absent) {
			t.Errorf("the reference arm emitted %q; it installs no scheduler configuration at all:\n%s",
				absent, out)
		}
	}
	// The shared environment must survive.
	if strings.Count(out, "- role: worker") != 3 {
		t.Errorf("the reference arm renders %d workers, want 3:\n%s", strings.Count(out, "- role: worker"), out)
	}
	if !strings.Contains(out, NodeLabelKey+"=2") || strings.Count(out, NodeLabelKey+"=1") != 2 {
		t.Errorf("the worker capacity labels did not survive:\n%s", out)
	}
	if strings.Count(out, "image: "+nodeImage) != 4 {
		t.Errorf("the node image is not pinned on all four nodes:\n%s", out)
	}
	// And the file says which arm it is, for a reader who never runs it.
	if !strings.Contains(out, "# Arm: "+string(ArmUntouched)) {
		t.Errorf("the rendered file does not record its arm:\n%s", out)
	}
	// The treatment, by contrast, emits all of it.
	treat, err := KindConfigYAML(ConfiguredArm(MostAllocated), NodeLayout{2, 1, 1}, nodeImage)
	if err != nil {
		t.Fatal(err)
	}
	for _, present := range []string{"extraMounts", "ClusterConfiguration", "extraVolumes",
		"# Arm: " + string(ArmConfigured)} {
		if !strings.Contains(treat, present) {
			t.Errorf("the treatment arm does not emit %q:\n%s", present, treat)
		}
	}
}
