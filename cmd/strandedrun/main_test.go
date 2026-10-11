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
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// An absent label and a label of zero are different facts, and the parse must keep them apart.
//
// The device plugin selects on the label, so an unlabelled worker advertises nothing. Reading that as a node of
// size zero would let a broken render pass as a cluster with less capacity -- the same inversion the census
// refuses one layer up, arriving through the flag parser instead.
//
// Mutation that turns this red: default an empty label field to Labelled 0, Present true.
func TestAnAbsentLabelIsNotALabelOfZero(t *testing.T) {
	got, err := parseObserved("w1:2:2,w2::0")
	if err != nil {
		t.Fatalf("a census naming an unlabelled node was refused by the parser: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("parsed %d nodes, want 2", len(got))
	}
	if !got[0].Present || got[0].Labelled != 2 {
		t.Errorf("w1 = %+v; a present label must be read as present", got[0])
	}
	if got[1].Present {
		t.Errorf("w2 = %+v; an empty label field means the label is ABSENT, not zero", got[1])
	}
	// And the layout check must then refuse it, so the distinction is load-bearing rather than cosmetic.
	if err := VerifyLayout(NodeLayout{2, 1}, got); err == nil {
		t.Error("a census containing an unlabelled worker was accepted as a verified layout")
	}
}

// Input the parsers cannot read is refused rather than defaulted.
//
// Mutation that turns this red: skip malformed entries instead of failing.
func TestTheFlagParsersRefuseWhatTheyCannotRead(t *testing.T) {
	for _, in := range []string{"", "   ", "2,x,1", "two"} {
		if _, err := parseLayout(in); err == nil {
			t.Errorf("parseLayout(%q) was accepted", in)
		}
	}
	for _, in := range []string{"", "w1:1", "w1:1:2:3", "w1:one:1", "w1:1:one"} {
		if _, err := parseObserved(in); err == nil {
			t.Errorf("parseObserved(%q) was accepted", in)
		}
	}
	l, err := parseLayout("2, 1,1")
	if err != nil {
		t.Fatalf("a well-formed layout was refused: %v", err)
	}
	if len(l) != 3 || l[0] != 2 || l[1] != 1 || l[2] != 1 {
		t.Errorf("parseLayout = %v, want [2 1 1]", l)
	}
}

// render-cluster writes all three artifacts together, and the kind configuration references one of the others.
//
// Together rather than separately because the kind configuration mounts ./scheduler-config.yaml by relative
// path: a caller who rendered them in separate invocations could create a cluster whose mounted profile came
// from a different arm than the configuration that named it. That is the silent-treatment failure this command
// exists to prevent, arriving through a second door.
//
// Mutation that turns this red: write only the kind configuration, or change the mount path without changing
// the file name.
func TestRenderClusterWritesAnArmThatCanBeCreatedFromOneDirectory(t *testing.T) {
	dir := t.TempDir()
	if err := renderCluster([]string{"-arm=" + string(ArmConfigured), "-strategy=MostAllocated", "-layout=2,1,1",
		"-dir=" + dir, "-node-image=kindest/node:v1.31.0"}); err != nil {
		t.Fatalf("render-cluster: %v", err)
	}
	for _, name := range []string{"kind-config.yaml", "scheduler-config.yaml", "device-plugins.yaml"} {
		if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
			t.Errorf("%s was not written: %v", name, err)
		}
	}
	kindCfg, err := os.ReadFile(filepath.Join(dir, "kind-config.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	// The mount source must be the file that was actually written beside it.
	if !strings.Contains(string(kindCfg), "hostPath: ./scheduler-config.yaml") {
		t.Errorf("the kind configuration does not mount the profile written beside it:\n%s", kindCfg)
	}
	sched, err := os.ReadFile(filepath.Join(dir, "scheduler-config.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(sched), "type: MostAllocated") ||
		!strings.Contains(string(sched), "name: "+GPUResourceName) {
		t.Errorf("the mounted profile is not the arm that was asked for:\n%s", sched)
	}
	plugins, err := os.ReadFile(filepath.Join(dir, "device-plugins.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(string(plugins), "kind: DaemonSet") != 2 {
		t.Errorf("a 2,1,1 layout has two distinct counts and should render two DaemonSets:\n%s", plugins)
	}
}

// A layout that cannot strand must not produce a directory of artifacts at all.
//
// Refusing at the renderer rather than at cluster creation is what keeps a caller from building the cluster and
// discovering only afterwards that nothing on it could ever strand.
//
// Mutation that turns this red: write the files before validating.
func TestRenderClusterRefusesALayoutThatCannotStrandBeforeWritingAnything(t *testing.T) {
	dir := t.TempDir()
	err := renderCluster([]string{"-arm=" + string(ArmConfigured), "-strategy=MostAllocated", "-layout=4",
		"-dir=" + dir, "-node-image=kindest/node:v1.31.0"})
	if err == nil {
		t.Fatal("a single-worker layout rendered a cluster")
	}
	entries, rerr := os.ReadDir(dir)
	if rerr != nil {
		t.Fatal(rerr)
	}
	if len(entries) != 0 {
		names := make([]string, 0, len(entries))
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Errorf("the refusal still left %v behind; a half-written arm is worse than none", names)
	}
}

// The three required flags have no defaults, because each silently wrong one produces a different study.
//
// Mutation that turns this red: give any of them a default.
func TestRenderClusterRequiresTheArmToBeStatedInFull(t *testing.T) {
	dir := t.TempDir()
	const img = "-node-image=kindest/node:v1.31.0"
	const cfg = "-arm=S-gpu-most"
	for _, args := range [][]string{
		{cfg, "-layout=2,1", "-dir=" + dir, img},
		{cfg, "-strategy=MostAllocated", "-dir=" + dir, img},
		{cfg, "-strategy=MostAllocated", "-layout=2,1", img},
		// No arm at all: neither may be reached by defaulting.
		{"-strategy=MostAllocated", "-layout=2,1", "-dir=" + dir, img},
		// The treatment without a strategy, which is the flag that only it may carry.
		{cfg, "-layout=2,1", "-dir=" + dir, img},
		// And the reference WITH one, which would name something nothing installs.
		{"-arm=S-default", "-strategy=MostAllocated", "-layout=2,1", "-dir=" + dir, img},
		// The fourth, and the one most easily left to a default: without it the scheduler version is whatever
		// the kind binary happens to be, and no artifact records which.
		{"-strategy=MostAllocated", "-layout=2,1", "-dir=" + dir},
	} {
		if err := renderCluster(args); err == nil {
			t.Errorf("render-cluster ran with %v, leaving part of the arm unstated", args)
		}
	}
}

// A census checked against the protocol refuses a ledger missing a row; -settled alone accepts the same one.
//
// The pair is the point. -settled is the run operator's assertion that terminating pods and in-flight bindings
// had resolved, and it is not an observation of anything about the ledger: the reservation balance cannot see a
// submission omitted entirely, because a ledger missing a row balances perfectly well. Only the frozen protocol
// knows that a third submission should have been there.
//
// Mutation that turns this red: skip the membership check when -protocol is supplied, or accept -protocol
// without -step-number so the check has no step to judge.
func TestTheProtocolCatchesALedgerRowThatSettledCannotSee(t *testing.T) {
	// The honest ledger at step 3 is s1, s2, s3. This one drops s3 -- the discriminating request, which is
	// exactly the row an arm would benefit from losing.
	const nodes = "stranded-worker:2:1,stranded-worker2:1:1,stranded-worker3:1:0"
	const shortLedger = "s1:1:bound:stranded-worker,s2:1:bound:stranded-worker2"

	// Without the protocol, the short ledger is a perfectly valid census: it balances, and every submission in
	// it was observed. Nothing in the reading says a row is missing.
	if err := takeCensus([]string{"-step=c3", "-nodes=" + nodes, "-submissions=" + shortLedger,
		"-settled"}); err != nil {
		t.Fatalf("the short ledger was refused without a protocol, so this test no longer demonstrates the "+
			"gap it was written for: %v", err)
	}

	// With the protocol, the same census is refused, and the refusal names the count.
	err := takeCensus([]string{"-step=c3", "-nodes=" + nodes, "-submissions=" + shortLedger, "-settled",
		"-protocol=" + protocolPath, "-step-number=3"})
	if err == nil {
		t.Fatal("a census whose ledger is missing a registered submission was accepted against the protocol")
	}
	for _, want := range []string{"does not match the frozen protocol", "balances the reservation check"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the refusal does not say %q: %v", want, err)
		}
	}

	// And the full ledger at step 3 is accepted, so the refusal above is about the missing row.
	full := shortLedger + ",s3:2:queued-unadmitted"
	if err := takeCensus([]string{"-step=c3", "-nodes=" + nodes, "-submissions=" + full, "-settled",
		"-protocol=" + protocolPath, "-step-number=3"}); err != nil {
		t.Errorf("the complete ledger at step 3 was refused: %v", err)
	}
}

// Neither of the protocol flags may be supplied alone.
//
// A protocol with no step number cannot say which submissions belong in the ledger, and a step number with no
// protocol has nothing to check against -- so either one alone would read as a checked census while checking
// nothing, which is the failure class this repository keeps producing.
//
// Mutation that turns this red: drop the paired-flag guard.
func TestTheProtocolFlagsMustBeSuppliedTogether(t *testing.T) {
	const nodes = "stranded-worker:2:0"
	const ledger = "s1:1:queued-unadmitted"
	for _, extra := range [][]string{
		{"-protocol=" + protocolPath},
		{"-step-number=1"},
	} {
		args := append([]string{"-step=c1", "-nodes=" + nodes, "-submissions=" + ledger, "-settled"}, extra...)
		err := takeCensus(args)
		if err == nil {
			t.Errorf("take-census accepted %v alone; a census that reports having been checked while checking "+
				"nothing is worse than one that was never checked", extra)
			continue
		}
		if !strings.Contains(err.Error(), "go together") {
			t.Errorf("the refusal for %v does not explain the pairing: %v", extra, err)
		}
	}
}

// Rendering the reference into a directory that held the treatment must remove the stale profile.
//
// kind mounts scheduler-config.yaml by RELATIVE path, so a leftover file plus a kind-config that no longer
// references it is not inert: a later `kind create` from that directory would find the previous arm's profile
// sitting there. Worse, nothing in the artifacts would say so -- every file would read S-default.
//
// Mutation that turns this red: write only the files the arm produces without removing the others.
func TestRenderingTheReferenceRemovesTheTreatmentsStaleProfile(t *testing.T) {
	dir := t.TempDir()
	if err := renderCluster([]string{"-arm=" + string(ArmConfigured), "-strategy=MostAllocated",
		"-layout=2,1,1", "-dir=" + dir, "-node-image=kindest/node:v1.31.0"}); err != nil {
		t.Fatalf("treatment render: %v", err)
	}
	sched := filepath.Join(dir, "scheduler-config.yaml")
	if _, err := os.Stat(sched); err != nil {
		t.Fatalf("the treatment did not write scheduler-config.yaml: %v", err)
	}

	if err := renderCluster([]string{"-arm=" + string(ArmUntouched), "-layout=2,1,1",
		"-dir=" + dir, "-node-image=kindest/node:v1.31.0"}); err != nil {
		t.Fatalf("reference render: %v", err)
	}
	if _, err := os.Stat(sched); !os.IsNotExist(err) {
		t.Errorf("scheduler-config.yaml survived the reference render (stat err %v); a stale profile in a "+
			"reused directory is the quietest way for one arm to become the other", err)
	}
	// The two files the reference does write must be there and must describe the reference.
	kindCfg, err := os.ReadFile(filepath.Join(dir, "kind-config.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(kindCfg), "# Arm: "+string(ArmUntouched)) {
		t.Errorf("the kind configuration does not record the reference arm:\n%s", kindCfg)
	}
	if strings.Contains(string(kindCfg), "extraMounts") {
		t.Errorf("the reference kind configuration still mounts something:\n%s", kindCfg)
	}
	if _, err := os.Stat(filepath.Join(dir, "device-plugins.yaml")); err != nil {
		t.Errorf("the reference did not write device-plugins.yaml: %v", err)
	}
}
