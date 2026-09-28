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
// Two subcommands, and neither needs a cluster:
//
//	render-scheduler-config  emits the KubeSchedulerConfiguration an arm asks for, refusing a profile that the
//	                         scheduler would accept and this study must not -- above all one that selects a
//	                         packing strategy without naming nvidia.com/gpu, which scores cpu and memory and
//	                         leaves the treatment inert.
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
