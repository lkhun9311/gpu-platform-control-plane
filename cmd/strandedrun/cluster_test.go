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
	out, err := KindConfigYAML(GPUAware(MostAllocated), NodeLayout{2, 1, 1}, nodeImage)
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
	if _, err := KindConfigYAML(bad, NodeLayout{2, 1}, nodeImage); err == nil {
		t.Error("a profile that never scores the GPU rendered a cluster configuration")
	}
	if _, err := KindConfigYAML(GPUAware(MostAllocated), NodeLayout{4}, nodeImage); err == nil {
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
			_, err := KindConfigYAML(GPUAware(MostAllocated), NodeLayout{2, 1}, tc.image)
			if err == nil {
				t.Fatalf("%s was accepted", tc.name)
			}
			if !strings.Contains(err.Error(), tc.wants) {
				t.Errorf("the refusal does not say why: got %q, want it to mention %q", err, tc.wants)
			}
		})
	}
	if _, err := KindConfigYAML(GPUAware(MostAllocated), NodeLayout{2, 1}, "kindest/node:v1.31.0"); err != nil {
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
func TestEachDevicePluginAdvertisesWhatItsSelectorAsksFor(t *testing.T) {
	out, err := DevicePluginYAML(NodeLayout{2, 1, 1}, "gpu-platform-control-plane-system", "gpu-simulator:latest")
	if err != nil {
		t.Fatal(err)
	}
	// Two distinct counts, so two DaemonSets separated by one document marker.
	if got := strings.Count(out, "kind: DaemonSet"); got != 2 {
		t.Errorf("the layout has two distinct counts and %d DaemonSet(s) were rendered:\n%s", got, out)
	}
	if got := strings.Count(out, "\n---\n"); got != 1 {
		t.Errorf("two documents need exactly one separator, got %d", got)
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
