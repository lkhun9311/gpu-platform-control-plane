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
	"sort"
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
	case "take-census":
		err = takeCensus(os.Args[2:])
	case "qualify-arm":
		err = qualifyArm(os.Args[2:])
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

  render-cluster -arm=S-default|S-gpu-most [-strategy=...] -layout=2,1,1 -dir=DIR
                 -node-image=kindest/node:vX.Y.Z
      Write one arm's kind configuration and device plugins, plus the scheduler profile when
      the arm installs one. S-default installs none: no profile file, no mount, no --config.
      Removes the artifacts the arm does not write, because a stale scheduler-config.yaml in a
      reused directory would install the previous arm while every file said S-default.

  verify-layout -layout=2,1,1 -observed=NAME:LABEL:ALLOCATABLE,...
      Compare what the cluster advertises against what the run asked for. A node's own
      allocatable decides where the scheduler can place; the manifest is not evidence.

  take-census -step=NAME -nodes=NAME:ALLOCATABLE:RESERVED,... -submissions=NAME:REQ:DISPOSITION[:NODE],...
              [-foreign=NODE:N,...] [-settled] [-json]
              [-protocol=hack/stranded-protocol.yaml -step-number=K]
      Read one census step: the registered stranding figure, its diagnostics, and the ledger
      that has to account for every submission. Refuses a reading whose demand is not fully
      observed, whose reservations no submission claims, or that was taken mid-binding.
      With -protocol, the ledger must be exactly the protocol's first K submissions, by
      identity, order and request -- which is the check -settled cannot make, since a ledger
      missing a row balances the reservation check perfectly well.

  qualify-arm -arm=S-default|S-gpu-most -protocol=hack/stranded-protocol.yaml
              -scheduler-args=ARG,ARG,... -scheduler-image=IMAGE -restarts=N
              [-profile-file=yes|no] [-demand-scheduled=yes|no] [-treatment-applied=yes|no] [-json]
      Judge whether a cluster is running the arm a cell claims. The readings come from the
      scheduler pod -- command, volumes, image and restart count -- and each one the protocol
      requires must be supplied as yes or no: an omitted reading is refused rather than taken
      for "no", because the reference arm PASSES on absence and a default would satisfy the
      check it was meant to make.
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
	arm := fs.String("arm", "", "S-default (the reference: no scheduler configuration) or S-gpu-most (the treatment)")
	strategy := fs.String("strategy", "", "LeastAllocated or MostAllocated; only for S-gpu-most")
	layout := fs.String("layout", "", "devices per worker, comma separated, e.g. 2,1,1")
	dir := fs.String("dir", "", "directory to write the cluster's artifacts into")
	namespace := fs.String("namespace", "gpu-platform-control-plane-system", "namespace for the device plugins")
	image := fs.String("image", "gpu-simulator:latest", "device plugin image")
	// No default, unlike the two above. The scheduler version is part of what the run registers: left to kind,
	// it is whatever that binary happens to default to, and two runs months apart would compare arms across two
	// different schedulers without either recording which.
	nodeImage := fs.String("node-image", "", "kind node image, e.g. kindest/node:v1.31.0 (required)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *arm == "" || *layout == "" || *dir == "" || *nodeImage == "" {
		return fmt.Errorf("-arm, -layout, -dir and -node-image are all required; this command renders one "+
			"arm's cluster and none of the four has a meaningful default (arms: %s, %s)",
			ArmUntouched, ArmConfigured)
	}
	// The strategy belongs to the treatment and to nothing else. Accepting one for the reference would let a
	// run record itself as the reference while naming a strategy nothing installs.
	ap := ArmProfile{Arm: Arm(*arm)}
	switch {
	case ap.Arm == ArmConfigured:
		if *strategy == "" {
			return fmt.Errorf("-strategy is required for %s; it is the scoring type the treatment installs",
				ArmConfigured)
		}
		ap.Profile = GPUAware(ScoringStrategy(*strategy))
	case ap.Arm == ArmUntouched && *strategy != "":
		return fmt.Errorf("-strategy=%s was given for %s, which installs no scheduler configuration at all; "+
			"a strategy there would name something nothing applies", *strategy, ArmUntouched)
	}
	if err := ap.Validate(); err != nil {
		return err
	}
	l, err := parseLayout(*layout)
	if err != nil {
		return err
	}
	kindYAML, err := KindConfigYAML(ap, l, *nodeImage)
	if err != nil {
		return err
	}
	files := map[string]string{"kind-config.yaml": kindYAML}
	pluginYAML, err := DevicePluginYAML(l, *namespace, *image)
	if err != nil {
		return err
	}
	files["device-plugins.yaml"] = pluginYAML
	if ap.Arm.InstallsSchedulerConfig() {
		schedYAML, sErr := ap.Profile.KubeSchedulerConfigurationYAML()
		if sErr != nil {
			return sErr
		}
		files["scheduler-config.yaml"] = schedYAML
	}
	if err := os.MkdirAll(*dir, 0o755); err != nil {
		return err
	}
	// Remove the artifacts this arm does not write, because the directory is reused between arms.
	//
	// Without this, rendering the reference into a directory that previously held the treatment would leave
	// scheduler-config.yaml behind -- and kind mounts by relative path, so a later `kind create` from that
	// directory would install the PREVIOUS arm's profile while every artifact said S-default. A stale file is
	// the quietest way for an arm to become the other one.
	for _, name := range []string{"kind-config.yaml", "scheduler-config.yaml", "device-plugins.yaml"} {
		if _, want := files[name]; want {
			continue
		}
		if err := os.Remove(filepath.Join(*dir, name)); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("could not remove the stale %s that arm %s does not write: %w", name, ap.Arm, err)
		}
	}
	for name, content := range files {
		if err := os.WriteFile(filepath.Join(*dir, name), []byte(content), 0o644); err != nil {
			return err
		}
	}
	written := make([]string, 0, len(files))
	for name := range files {
		written = append(written, name)
	}
	sort.Strings(written)
	fmt.Printf("wrote %s to %s\n", strings.Join(written, ", "), *dir)
	if ap.Arm.InstallsSchedulerConfig() {
		fmt.Printf("  cluster %q on %s, arm %s, %d workers advertising %s, scheduler scoring %s over %s\n",
			ClusterName, *nodeImage, ap.Arm, len(l), *layout, *strategy, GPUResourceName)
	} else {
		fmt.Printf("  cluster %q on %s, arm %s, %d workers advertising %s, and NO scheduler configuration "+
			"installed\n", ClusterName, *nodeImage, ap.Arm, len(l), *layout)
	}
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

// takeCensus reads one census step and reports the registered figure with its diagnostics.
//
// Every refusal it can produce is an absent observation that the original registration's validity rule would
// have accepted: a submission nobody looked at, a reservation no submission claims, a reading taken while
// bindings were still in flight. The amendment requires each to invalidate rather than to pass.
// qualifyArm judges observed evidence against the arm a cell claims to be running.
//
// The readings are supplied rather than collected here, the way check-treatment already works: the tool that
// decides whether an arm is what it claims does not hold cluster credentials, so its verdict is reproducible
// from a recorded reading rather than from a cluster that has since changed.
//
// The three evidence flags are strings, not booleans. `flag.Bool` defaults to false, and the reference arm
// PASSES when the profile file is absent -- so an omitted flag would read as evidence of absence and satisfy
// the check it was meant to make.
func qualifyArm(args []string) error {
	fs := flag.NewFlagSet("qualify-arm", flag.ContinueOnError)
	arm := fs.String("arm", "", "S-default or S-gpu-most; the arm this cell claims to be running")
	protocolFile := fs.String("protocol", "", "the frozen protocol registering what evidence each arm needs")
	schedArgs := fs.String("scheduler-args", "", "the scheduler's arguments, comma separated, from the pod spec")
	schedImage := fs.String("scheduler-image", "", "the image the scheduler container is running, from its status")
	restarts := fs.Int("restarts", 0, "the scheduler container's restart count")
	profileFile := fs.String("profile-file", "", "yes|no: is a supplied profile mounted into the node")
	demandSched := fs.String("demand-scheduled", "", "yes|no: did submitted demand actually schedule")
	treatApplied := fs.String("treatment-applied", "", "yes|no: check-treatment's verdict")
	asJSON := fs.Bool("json", false, "emit the verdict as JSON")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *arm == "" || *protocolFile == "" {
		return fmt.Errorf("-arm and -protocol are both required; an arm with no protocol has no registered " +
			"evidence to be judged against, and a protocol with no arm has nothing to judge")
	}
	p, err := LoadProtocol(*protocolFile)
	if err != nil {
		return err
	}
	var parsedArgs []string
	for part := range strings.SplitSeq(*schedArgs, ",") {
		if part = strings.TrimSpace(part); part != "" {
			parsedArgs = append(parsedArgs, part)
		}
	}
	e := ArmEvidence{
		SchedulerArgs:      parsedArgs,
		SchedulerImage:     strings.TrimSpace(*schedImage),
		Restarts:           *restarts,
		ProfileFilePresent: Observation(*profileFile),
		DemandScheduled:    Observation(*demandSched),
		TreatmentApplied:   Observation(*treatApplied),
	}
	verdictErr := p.QualifyArm(Arm(*arm), e)

	if *asJSON {
		v := struct {
			Arm       string `json:"arm"`
			Qualified bool   `json:"qualified"`
			Image     string `json:"scheduler_image"`
			Restarts  int    `json:"restarts"`
			Reason    string `json:"reason,omitempty"`
		}{Arm: *arm, Qualified: verdictErr == nil, Image: e.SchedulerImage, Restarts: e.Restarts}
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
	fmt.Printf("arm %s qualified\n", *arm)
	fmt.Printf("  scheduler %s, %d restarts\n", e.SchedulerImage, e.Restarts)
	if Arm(*arm).InstallsSchedulerConfig() {
		fmt.Printf("  a profile was supplied and check-treatment reports it applied\n")
	} else {
		fmt.Printf("  no configuration was supplied, and submitted demand scheduled\n")
	}
	return nil
}

func takeCensus(args []string) error {
	fs := flag.NewFlagSet("take-census", flag.ContinueOnError)
	step := fs.String("step", "", "the census point's name (required: a figure with no step is not in a series)")
	nodesFlag := fs.String("nodes", "", "NAME:ALLOCATABLE:RESERVED, comma separated")
	subsFlag := fs.String("submissions", "", "NAME:REQUEST:DISPOSITION[:NODE], comma separated; may be empty")
	foreignFlag := fs.String("foreign", "", "NODE:N, comma separated: GPU reservations held by consumers this study did not submit")
	settled := fs.Bool("settled", false, "assert that terminating pods and in-flight bindings were resolved before this reading")
	protocolFile := fs.String("protocol", "", "the frozen protocol to check this census's ledger membership against")
	stepNumber := fs.Int("step-number", 0, "which registered submission this census follows, 1-based; required with -protocol")
	asJSON := fs.Bool("json", false, "emit the report as JSON")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *step == "" {
		return fmt.Errorf("-step is required; a census point with no name cannot be placed in the series the " +
			"amendment requires in place of a peak")
	}
	// The step NUMBER is supplied rather than parsed out of the step's name.
	//
	// Deriving it from "c2" would make the protocol depend on a naming convention nothing enforces, and a
	// census misnamed by one would then be checked against the wrong step's membership and pass.
	if (*protocolFile == "") != (*stepNumber == 0) {
		return fmt.Errorf("-protocol and -step-number go together: a protocol with no step cannot say which " +
			"submissions should be in the ledger, and a step number with no protocol has nothing to check against")
	}
	nodes, err := parseNodes(*nodesFlag)
	if err != nil {
		return err
	}
	subs, err := parseSubmissions(*subsFlag)
	if err != nil {
		return err
	}
	foreign, err := parseForeign(*foreignFlag)
	if err != nil {
		return err
	}
	c := Census{Step: *step, Nodes: nodes, Submissions: subs, ForeignReserved: foreign, Settled: *settled}
	// Checked BEFORE Report(), because a report computed from a ledger that is missing a row is a figure, and a
	// figure is the thing this study must not produce when the evidence does not support it.
	//
	// This is what -settled cannot do. Settled is the run operator's assertion that bindings had resolved; it
	// says nothing about whether every registered submission reached the ledger, and the reservation balance
	// cannot tell either, because a ledger missing a row balances perfectly well. Membership is judged against
	// the protocol, which was frozen before the run.
	if *protocolFile != "" {
		p, pErr := LoadProtocol(*protocolFile)
		if pErr != nil {
			return pErr
		}
		if mErr := p.CheckMembership(*stepNumber, c); mErr != nil {
			return fmt.Errorf("census %s does not match the frozen protocol: %w", *step, mErr)
		}
	}
	r, err := c.Report()
	if err != nil {
		return err
	}
	if *asJSON {
		b, mErr := json.Marshal(r)
		if mErr != nil {
			return mErr
		}
		fmt.Println(string(b))
		return nil
	}
	fmt.Printf("census %s\n", r.Step)
	if r.NoDemand {
		fmt.Printf("  no demand-relative stranding: the ledger accounts for every submission and none is pending\n")
	} else {
		fmt.Printf("  stranded devices (max(f_i) < q_min): %d\n", r.StrandedDevices)
		fmt.Printf("  blocked: %s\n", joinOrNone(r.Blocked))
		fmt.Printf("  unsatisfiable (short of capacity, not fragmented): %s\n", joinOrNone(r.Unsatisfiable))
		fmt.Printf("  outstanding demand: %d devices\n", r.OutstandingDemand)
	}
	fmt.Printf("  reserved: %d   placed: %s\n", r.ReservedTotal, joinOrNone(r.PlacedWorkloads))
	if r.WitnessExists {
		fmt.Printf("  witness request: %d\n", r.WitnessRequest)
	} else {
		fmt.Printf("  witness request: none exists, so this cluster cannot strand however much is free\n")
	}
	fmt.Printf("  diagnostic only -- per-node gap sum: %d (NOT the registered figure)\n", r.UnusableGapSum)
	return nil
}

func joinOrNone(v []string) string {
	if len(v) == 0 {
		return "none"
	}
	return strings.Join(v, " ")
}

// parseSubmissions reads the demand ledger.
//
// A missing disposition field is left as DispositionUnobserved rather than defaulted, because that is the whole
// distinction the ledger exists to carry: "nobody looked" must not arrive as any outcome.
func parseSubmissions(s string) ([]Submission, error) {
	if strings.TrimSpace(s) == "" {
		// An empty ledger is legitimate -- an idle cluster with nothing submitted -- and Report distinguishes
		// it from a ledger with unobserved entries.
		return nil, nil
	}
	var out []Submission
	seen := map[string]bool{}
	for part := range strings.SplitSeq(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		fields := strings.Split(part, ":")
		if len(fields) < 3 || len(fields) > 4 {
			return nil, fmt.Errorf("submission %q is not NAME:REQUEST:DISPOSITION[:NODE]", part)
		}
		var req int
		if _, err := fmt.Sscanf(fields[1], "%d", &req); err != nil {
			return nil, fmt.Errorf("submission %q: request %q is not a number", fields[0], fields[1])
		}
		if seen[fields[0]] {
			return nil, fmt.Errorf("submission %q appears twice; a ledger naming one workload twice cannot "+
				"account for either", fields[0])
		}
		seen[fields[0]] = true
		sub := Submission{Name: fields[0], Request: req, Disposition: Disposition(fields[2])}
		if len(fields) == 4 {
			sub.Node = fields[3]
		}
		out = append(out, sub)
	}
	return out, nil
}

// parseForeign reads the GPU reservations held by consumers this study did not submit.
func parseForeign(s string) (map[string]int, error) {
	if strings.TrimSpace(s) == "" {
		return nil, nil
	}
	out := map[string]int{}
	for part := range strings.SplitSeq(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		fields := strings.Split(part, ":")
		if len(fields) != 2 {
			return nil, fmt.Errorf("foreign entry %q is not NODE:N", part)
		}
		var n int
		if _, err := fmt.Sscanf(fields[1], "%d", &n); err != nil {
			return nil, fmt.Errorf("foreign entry %q: %q is not a number", fields[0], fields[1])
		}
		out[fields[0]] = n
	}
	return out, nil
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
