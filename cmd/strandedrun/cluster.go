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
	"fmt"
	"sort"
	"strings"
)

// ClusterName is the study's own kind cluster.
//
// Its own name rather than `platform`, and that is a requirement rather than tidiness: the `platform` cluster
// is weeks old and carries Argo CD, cert-manager, KServe and Kueue that other work depends on. A study that
// recreated it would destroy evidence it has no claim to, and one that reused it would measure a scheduler
// governed by configuration this study did not set.
const ClusterName = "stranded"

// NodeLabelKey marks a worker with the GPU count it should advertise.
//
// The count reaches the node as a LABEL rather than as a per-node manifest, because the device plugin is a
// DaemonSet: one object, every node. Selecting on a label is what lets one cluster hold workers that advertise
// different capacities, which is the whole shape a fragmentation study needs.
const NodeLabelKey = "stranded.gpu-platform/devices"

// NodeLayout is how many fake devices each worker advertises.
//
// A slice rather than a map, because the order is the node order in the rendered kind configuration and a map
// would make the rendering non-deterministic -- two runs of the same study would produce configurations that
// differ by nothing but worker order, and a reader comparing them could not tell that from a real change.
type NodeLayout []int

// Validate refuses a layout that cannot host the phenomenon the study measures.
//
// The amendment corrected the original registration on one point here: heterogeneous nodes and more than two
// workers are NOT prerequisites. Two identical two-GPU nodes each holding one device already block a two-device
// request with two devices free. So this refuses only what genuinely cannot strand.
func (l NodeLayout) Validate() error {
	if len(l) < 2 {
		return fmt.Errorf("a layout of %d worker(s) cannot strand anything: stranding is capacity free on one "+
			"node that a pending workload cannot use because it needs more on a single node, which needs at "+
			"least two nodes to be free on", len(l))
	}
	total := 0
	for i, n := range l {
		if n < 1 {
			return fmt.Errorf("worker %d advertises %d devices; a worker with no GPU capacity is not part of "+
				"this study's cluster and would silently absorb pods that request none", i, n)
		}
		total += n
	}
	// The witness request the amendment requires -- max(f_i) < q <= sum(f_i) -- can only exist if the largest
	// single node is smaller than the total. A cluster of one-device nodes satisfies that; a cluster whose
	// largest node holds everything cannot strand, because anything that fits at all fits there.
	maxNode := 0
	for _, n := range l {
		if n > maxNode {
			maxNode = n
		}
	}
	if maxNode >= total {
		return fmt.Errorf("one worker advertises %d of the cluster's %d devices, so every request that fits "+
			"anywhere fits there and no witness request max(f_i) < q <= sum(f_i) exists", maxNode, total)
	}
	return nil
}

// KindConfigYAML renders the study's cluster: one control plane, workers carrying their device-count label, and
// the scheduler configuration for the given arm mounted into the control plane.
//
// The scheduler configuration is written to the control-plane node as a file and named from
// KubeSchedulerConfiguration's own `--config` flag through kubeadm's ClusterConfiguration. kind has no
// higher-level way to say "run the scheduler with this profile", and this repository has no precedent for
// either mechanism -- which is why the FIRST thing built was the check that the requested strategy actually
// governs a placement, rather than this renderer.
func KindConfigYAML(p SchedulerProfile, l NodeLayout) (string, error) {
	if err := p.Validate(); err != nil {
		return "", err
	}
	if err := l.Validate(); err != nil {
		return "", err
	}
	sched, err := p.KubeSchedulerConfigurationYAML()
	if err != nil {
		return "", err
	}

	var b strings.Builder
	b.WriteString("# Rendered by cmd/strandedrun. Do not edit: the arm's scheduler profile and the node layout\n")
	b.WriteString("# are encoded here, and a hand edit would make the cluster disagree with what the run records.\n")
	b.WriteString("kind: Cluster\n")
	b.WriteString("apiVersion: kind.x-k8s.io/v1alpha4\n")
	fmt.Fprintf(&b, "name: %s\n", ClusterName)
	b.WriteString("nodes:\n")
	b.WriteString("  - role: control-plane\n")
	// The scheduler reads its profile from a file, so the file has to exist on the control-plane node before
	// the static pod starts. extraMounts puts it there; the kubeadm patch points the scheduler at it.
	b.WriteString("    extraMounts:\n")
	b.WriteString("      - hostPath: ./scheduler-config.yaml\n")
	b.WriteString("        containerPath: /etc/kubernetes/stranded-scheduler.yaml\n")
	b.WriteString("        readOnly: true\n")
	b.WriteString("    kubeadmConfigPatches:\n")
	b.WriteString("      - |\n")
	b.WriteString("        kind: ClusterConfiguration\n")
	b.WriteString("        scheduler:\n")
	b.WriteString("          extraArgs:\n")
	b.WriteString("            config: /etc/kubernetes/stranded-scheduler.yaml\n")
	b.WriteString("          extraVolumes:\n")
	b.WriteString("            - name: stranded-scheduler\n")
	b.WriteString("              hostPath: /etc/kubernetes/stranded-scheduler.yaml\n")
	b.WriteString("              mountPath: /etc/kubernetes/stranded-scheduler.yaml\n")
	b.WriteString("              readOnly: true\n")
	b.WriteString("              pathType: File\n")
	for i, n := range l {
		b.WriteString("  - role: worker\n")
		b.WriteString("    kubeadmConfigPatches:\n")
		b.WriteString("      - |\n")
		b.WriteString("        kind: JoinConfiguration\n")
		b.WriteString("        nodeRegistration:\n")
		b.WriteString("          kubeletExtraArgs:\n")
		fmt.Fprintf(&b, "            node-labels: \"%s=%d\"\n", NodeLabelKey, n)
		_ = i
	}
	b.WriteString("\n# The scheduler profile this cluster runs, for the reader. The same bytes are written to\n")
	b.WriteString("# scheduler-config.yaml beside this file, which is what the control plane actually mounts.\n")
	for line := range strings.SplitSeq(strings.TrimRight(sched, "\n"), "\n") {
		fmt.Fprintf(&b, "# %s\n", line)
	}
	return b.String(), nil
}

// DevicePluginYAML renders one DaemonSet per distinct device count in the layout.
//
// config/device-plugin is left untouched: it hardcodes FAKE_GPU_COUNT "1" and runs everywhere, which is what
// every other study on this cluster family expects. Editing it to take a per-node count would change the
// capacity every one of those studies sees, to serve this one.
//
// One DaemonSet per COUNT rather than per node, because a DaemonSet already selects a set of nodes -- and the
// label carries the count, so the selector and the environment variable are the same fact read twice. They are
// rendered together here so they cannot drift.
func DevicePluginYAML(l NodeLayout, namespace, image string) (string, error) {
	if err := l.Validate(); err != nil {
		return "", err
	}
	if namespace == "" {
		return "", fmt.Errorf("no namespace given; a DaemonSet rendered into the default namespace would " +
			"advertise capacity from wherever it happened to land")
	}
	if image == "" {
		return "", fmt.Errorf("no image given; the device plugin is the thing that makes nvidia.com/gpu " +
			"schedulable at all and there is no meaningful default for it")
	}
	counts := l.distinctCounts()
	var b strings.Builder
	for i, n := range counts {
		if i > 0 {
			b.WriteString("---\n")
		}
		fmt.Fprintf(&b, `# Advertises %d fake device(s) on every worker labelled %s=%d.
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: gpu-simulator-%d
  namespace: %s
  labels:
    app.kubernetes.io/name: gpu-platform-control-plane
    app.kubernetes.io/component: gpu-simulator
    %s: "%d"
spec:
  selector:
    matchLabels:
      app.kubernetes.io/component: gpu-simulator
      %s: "%d"
  template:
    metadata:
      labels:
        app.kubernetes.io/name: gpu-platform-control-plane
        app.kubernetes.io/component: gpu-simulator
        %s: "%d"
    spec:
      priorityClassName: system-node-critical
      # The selector and FAKE_GPU_COUNT below are the same fact twice, which is why they are rendered from one
      # value: a node labelled for %d devices must run the plugin that advertises %d.
      nodeSelector:
        %s: "%d"
      tolerations:
        - operator: Exists
      containers:
        - name: gpu-simulator
          image: %s
          command:
            - /gpu-simulator
          env:
            - name: FAKE_GPU_COUNT
              value: "%d"
          securityContext:
            privileged: true
            runAsUser: 0
            runAsNonRoot: false
          volumeMounts:
            - name: device-plugins
              mountPath: /var/lib/kubelet/device-plugins
          resources:
            limits:
              cpu: 100m
              memory: 64Mi
            requests:
              cpu: 10m
              memory: 32Mi
      volumes:
        - name: device-plugins
          hostPath:
            path: /var/lib/kubelet/device-plugins
            type: Directory
      terminationGracePeriodSeconds: 5
`, n, NodeLabelKey, n, n, namespace, NodeLabelKey, n, NodeLabelKey, n, NodeLabelKey, n, n, n,
			NodeLabelKey, n, image, n)
	}
	return b.String(), nil
}

func (l NodeLayout) distinctCounts() []int {
	seen := map[int]bool{}
	var out []int
	for _, n := range l {
		if !seen[n] {
			seen[n] = true
			out = append(out, n)
		}
	}
	sort.Ints(out)
	return out
}
