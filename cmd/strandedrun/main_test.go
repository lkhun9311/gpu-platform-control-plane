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
	if err := renderCluster([]string{"-strategy=MostAllocated", "-layout=2,1,1", "-dir=" + dir,
		"-node-image=kindest/node:v1.31.0"}); err != nil {
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
	err := renderCluster([]string{"-strategy=MostAllocated", "-layout=4", "-dir=" + dir,
		"-node-image=kindest/node:v1.31.0"})
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
	for _, args := range [][]string{
		{"-layout=2,1", "-dir=" + dir, img},
		{"-strategy=MostAllocated", "-dir=" + dir, img},
		{"-strategy=MostAllocated", "-layout=2,1", img},
		// The fourth, and the one most easily left to a default: without it the scheduler version is whatever
		// the kind binary happens to be, and no artifact records which.
		{"-strategy=MostAllocated", "-layout=2,1", "-dir=" + dir},
	} {
		if err := renderCluster(args); err == nil {
			t.Errorf("render-cluster ran with %v, leaving part of the arm unstated", args)
		}
	}
}
