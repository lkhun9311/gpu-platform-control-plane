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

// Command strandedrun is the instrument for the stranded-GPU placement study.
//
// The study asks whether a scheduler's scoring strategy changes how many GPUs end up unreserved and unusable,
// and it is registered in docs/superpowers/specs/2026-09-23-what-a-stranded-gpu-is-and-what-kind-can-say-about-it.md
// with its corrections in the 2026-09-28 amendment beside it. Both pages were published before this file
// existed.
//
// This is the FIRST piece, and the registration chose it rather than me: the thing built before any arm runs is
// the check that the requested scoring strategy is the one the cluster is actually running. The reason is the
// study's worst outcome -- a treatment that silently did not apply produces three arms reporting the same
// number, which reads as a null result rather than as a broken instrument.
//
// Four subcommands. None of them talks to a cluster: two render what a cluster is made of, and two judge
// readings taken from one, so every refusal here is reachable without renting or creating anything.
//
//	render-scheduler-config  emits the KubeSchedulerConfiguration an arm asks for, refusing a profile that the
//	                         scheduler would accept and this study must not -- above all one that selects a
//	                         packing strategy without naming nvidia.com/gpu, which scores cpu and memory and
//	                         leaves the treatment inert.
//	render-cluster           writes that profile, the kind configuration that mounts it, and one device plugin
//	                         per distinct device count, into one directory. Together, because the kind
//	                         configuration names the profile by relative path: rendered separately, a cluster
//	                         could mount one arm's profile under another arm's configuration.
//	verify-layout            compares what the cluster advertises against what the run asked for. The
//	                         registration requires reading allocatable BACK from each node rather than trusting
//	                         the manifest, because only the node's word decides where the scheduler can place.
//	check-treatment          judges an observed probe placement against the profile the run asked for, over a
//	                         fixture whose two strategies demonstrably disagree. Reading the scheduler's
//	                         configuration back says what it loaded; only a moved placement says it acted.
//
// It deliberately does not live in internal/queuelab. An Arm there must answer PolicyVariant, StateFor,
// ContractFor, DutyFor and AssertCardinality; a placement study has no victim, no termination contract and no
// duty, so four of those five would carry values that mean nothing and would then flow into the record schema
// and its refusals.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "render-scheduler-config":
		err = renderSchedulerConfig(os.Args[2:])
	case "check-treatment":
		err = checkTreatment(os.Args[2:])
	case "render-cluster":
		err = renderCluster(os.Args[2:])
	case "verify-layout":
		err = verifyLayout(os.Args[2:])
	case "-h", "--help", "help":
		usage()
		return
	default:
		usage()
		err = fmt.Errorf("unknown subcommand %q", os.Args[1])
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "strandedrun: %v\n", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `strandedrun -- the stranded-GPU placement study's instrument

  render-scheduler-config -strategy=LeastAllocated|MostAllocated
      Emit the KubeSchedulerConfiguration for one arm, to be supplied to kind through
      kubeadmConfigPatches. Refuses a profile that would leave the treatment inert.

  check-treatment -strategy=... -nodes=NAME:ALLOCATABLE:RESERVED,... -request=N -observed=NODE
      Judge an observed probe placement against the strategy the run asked for. Refuses a
      fixture on which the two strategies agree, because such a placement qualifies nothing.

  render-cluster -strategy=... -layout=2,1,1 -dir=DIR [-namespace=... -image=...]
      Write the study's kind configuration, the scheduler profile it mounts, and one device
      plugin per distinct device count. Refuses a layout that cannot strand anything.

  verify-layout -layout=2,1,1 -observed=NAME:LABEL:ALLOCATABLE,...
      Compare what the cluster advertises against what the run asked for. A node's own
      allocatable decides where the scheduler can place; the manifest is not evidence.
`)
}

func renderSchedulerConfig(args []string) error {
	fs := flag.NewFlagSet("render-scheduler-config", flag.ContinueOnError)
	strategy := fs.String("strategy", "", "LeastAllocated or MostAllocated")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *strategy == "" {
		return fmt.Errorf("-strategy is required; this command renders one arm and there is no default arm")
	}
	out, err := GPUAware(ScoringStrategy(*strategy)).KubeSchedulerConfigurationYAML()
	if err != nil {
		return err
	}
	fmt.Print(out)
	return nil
}

func checkTreatment(args []string) error {
	fs := flag.NewFlagSet("check-treatment", flag.ContinueOnError)
	strategy := fs.String("strategy", "", "the strategy this run asked the cluster for")
	nodes := fs.String("nodes", "", "NAME:ALLOCATABLE:RESERVED, comma separated, as of the census before the probe")
	request := fs.Int("request", 1, "the probe pod's GPU request")
	observed := fs.String("observed", "", "the node the probe was actually placed on")
	asJSON := fs.Bool("json", false, "emit the verdict as JSON")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *strategy == "" {
		return fmt.Errorf("-strategy is required; without it there is nothing to judge the placement against")
	}
	parsed, err := parseNodes(*nodes)
	if err != nil {
		return err
	}
	fixture := QualificationFixture{Nodes: parsed, Request: *request}
	profile := GPUAware(ScoringStrategy(*strategy))
	verdictErr := fixture.TreatmentApplied(profile, *observed)

	if *asJSON {
		v := struct {
			Strategy string `json:"strategy"`
			Observed string `json:"observed"`
			Applied  bool   `json:"applied"`
			Reason   string `json:"reason,omitempty"`
		}{Strategy: *strategy, Observed: *observed, Applied: verdictErr == nil}
		if verdictErr != nil {
			v.Reason = verdictErr.Error()
		}
		b, mErr := json.Marshal(v)
		if mErr != nil {
			return mErr
		}
		fmt.Println(string(b))
		return verdictErr
	}
	if verdictErr != nil {
		return verdictErr
	}
	fmt.Printf("the treatment applied: %s placed the probe on %s, and the other strategy would not have\n",
		*strategy, *observed)
	return nil
}

// renderCluster writes every artifact the study's cluster is made of, into one directory.
//
// Into a directory rather than to stdout, because there are three files and the kind configuration REFERENCES
// one of the others by relative path (./scheduler-config.yaml). Emitting them separately would let a caller
// create a cluster whose mounted profile came from a different arm than the configuration it rendered -- which
// is the silent-treatment failure this command exists to make impossible, arriving by another door.
func renderCluster(args []string) error {
	fs := flag.NewFlagSet("render-cluster", flag.ContinueOnError)
	strategy := fs.String("strategy", "", "LeastAllocated or MostAllocated")
	layout := fs.String("layout", "", "devices per worker, comma separated, e.g. 2,1,1")
	dir := fs.String("dir", "", "directory to write the cluster's artifacts into")
	namespace := fs.String("namespace", "gpu-platform-control-plane-system", "namespace for the device plugins")
	image := fs.String("image", "gpu-simulator:latest", "device plugin image")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *strategy == "" || *layout == "" || *dir == "" {
		return fmt.Errorf("-strategy, -layout and -dir are all required; this command renders one arm's " +
			"cluster and none of the three has a meaningful default")
	}
	l, err := parseLayout(*layout)
	if err != nil {
		return err
	}
	profile := GPUAware(ScoringStrategy(*strategy))
	kindYAML, err := KindConfigYAML(profile, l)
	if err != nil {
		return err
	}
	schedYAML, err := profile.KubeSchedulerConfigurationYAML()
	if err != nil {
		return err
	}
	pluginYAML, err := DevicePluginYAML(l, *namespace, *image)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(*dir, 0o755); err != nil {
		return err
	}
	for name, content := range map[string]string{
		"kind-config.yaml":      kindYAML,
		"scheduler-config.yaml": schedYAML,
		"device-plugins.yaml":   pluginYAML,
	} {
		if err := os.WriteFile(filepath.Join(*dir, name), []byte(content), 0o644); err != nil {
			return err
		}
	}
	fmt.Printf("wrote kind-config.yaml, scheduler-config.yaml and device-plugins.yaml to %s\n", *dir)
	fmt.Printf("  cluster %q, %d workers advertising %s, scheduler scoring %s over %s\n",
		ClusterName, len(l), *layout, *strategy, GPUResourceName)
	return nil
}

// verifyLayout compares the cluster's advertised capacity against the layout the run registered.
func verifyLayout(args []string) error {
	fs := flag.NewFlagSet("verify-layout", flag.ContinueOnError)
	layout := fs.String("layout", "", "devices per worker the run asked for, e.g. 2,1,1")
	observed := fs.String("observed", "", "NAME:LABEL:ALLOCATABLE, comma separated; LABEL empty when absent")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *layout == "" {
		return fmt.Errorf("-layout is required; without it there is nothing to compare the cluster against")
	}
	l, err := parseLayout(*layout)
	if err != nil {
		return err
	}
	nodes, err := parseObserved(*observed)
	if err != nil {
		return err
	}
	if err := VerifyLayout(l, nodes); err != nil {
		return err
	}
	free := make([]int, 0, len(nodes))
	for _, n := range nodes {
		free = append(free, n.Allocatable)
	}
	q, ok := WitnessRequest(free)
	if !ok {
		return fmt.Errorf("the cluster advertises the registered layout, but no witness request exists for an "+
			"empty cluster (free: %v); nothing placed on it could ever strand", free)
	}
	fmt.Printf("the cluster advertises the registered layout; on an empty cluster the smallest witness "+
		"request is %d devices\n", q)
	return nil
}

// parseLayout reads the per-worker device counts.
func parseLayout(s string) (NodeLayout, error) {
	var out NodeLayout
	for part := range strings.SplitSeq(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		var n int
		if _, err := fmt.Sscanf(part, "%d", &n); err != nil {
			return nil, fmt.Errorf("layout entry %q is not a number", part)
		}
		out = append(out, n)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("the layout %q names no workers", s)
	}
	return out, nil
}

// parseObserved reads the node census taken from the cluster.
//
// An empty LABEL field means the label is ABSENT, which is a different fact from a label of zero: the device
// plugin selects on it, so an unlabelled worker advertises nothing, and reading that as a node of size zero
// would let a broken render pass as a cluster with less capacity.
func parseObserved(s string) ([]ObservedNode, error) {
	if strings.TrimSpace(s) == "" {
		return nil, fmt.Errorf("-observed is empty; an empty reading is not a cluster with no capacity, it is " +
			"a census that did not happen")
	}
	var out []ObservedNode
	for part := range strings.SplitSeq(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		fields := strings.Split(part, ":")
		if len(fields) != 3 {
			return nil, fmt.Errorf("node %q is not NAME:LABEL:ALLOCATABLE", part)
		}
		n := ObservedNode{Name: fields[0]}
		if fields[1] != "" {
			var v int
			if _, err := fmt.Sscanf(fields[1], "%d", &v); err != nil {
				return nil, fmt.Errorf("node %q: label %q is not a number", fields[0], fields[1])
			}
			n.Labelled, n.Present = v, true
		}
		var a int
		if _, err := fmt.Sscanf(fields[2], "%d", &a); err != nil {
			return nil, fmt.Errorf("node %q: allocatable %q is not a number", fields[0], fields[2])
		}
		n.Allocatable = a
		out = append(out, n)
	}
	return out, nil
}

// parseNodes reads the census that the fixture is built from.
//
// Reserved is taken rather than derived from a "free" input on purpose: free is allocatable minus the requests
// of bound pods, and a flag that accepted free directly would let a caller supply a figure this study says must
// be computed. The parse refuses anything it cannot read rather than defaulting, because a census with a
// mis-read node is not a smaller census -- it describes a cluster that does not exist.
func parseNodes(s string) ([]NodeCapacity, error) {
	if strings.TrimSpace(s) == "" {
		return nil, fmt.Errorf("-nodes is empty; a fixture with no nodes cannot qualify a strategy")
	}
	var out []NodeCapacity
	seen := map[string]bool{}
	for part := range strings.SplitSeq(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		fields := strings.Split(part, ":")
		if len(fields) != 3 {
			return nil, fmt.Errorf("node %q is not NAME:ALLOCATABLE:RESERVED", part)
		}
		var alloc, reserved int
		if _, err := fmt.Sscanf(fields[1], "%d", &alloc); err != nil {
			return nil, fmt.Errorf("node %q: allocatable %q is not a number", fields[0], fields[1])
		}
		if _, err := fmt.Sscanf(fields[2], "%d", &reserved); err != nil {
			return nil, fmt.Errorf("node %q: reserved %q is not a number", fields[0], fields[2])
		}
		if seen[fields[0]] {
			return nil, fmt.Errorf("node %q appears twice; a census naming one node twice is not a census",
				fields[0])
		}
		seen[fields[0]] = true
		out = append(out, NodeCapacity{Name: fields[0], Allocatable: alloc, Reserved: reserved})
	}
	return out, nil
}
