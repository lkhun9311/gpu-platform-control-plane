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

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/queuelab"
)

func TestParseArmAcceptsOnlyTheThreeArms(t *testing.T) {
	for _, want := range []queuelab.Arm{queuelab.ArmAHonor, queuelab.ArmAIgnore, queuelab.ArmNRef} {
		got, err := parseArm(string(want))
		if err != nil {
			t.Fatalf("%s: %v", want, err)
		}
		if got != want {
			t.Fatalf("parseArm(%q) = %q", want, got)
		}
	}
	// The old CLI accepted any study/variant pair, which is how an arm the experiment never defined could
	// still be run; anything outside the closed set must be refused rather than defaulted.
	for _, bad := range []string{"", "Any", "reclaim", "fifo", "a-honor", "A-Honor"} {
		if _, err := parseArm(bad); err == nil {
			t.Fatalf("parseArm(%q) must be refused", bad)
		}
	}
}

func TestNamespaceForIsDerivedAndValidated(t *testing.T) {
	ns, err := namespaceFor("p1a")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(ns, "p1a") {
		t.Fatalf("namespace %q must carry the run id", ns)
	}
	// Two runs must never share a namespace, which is what let a previous run's objects satisfy this run's
	// barriers, so the namespace is derived rather than accepted from a flag.
	other, err := namespaceFor("p1b")
	if err != nil {
		t.Fatal(err)
	}
	if ns == other {
		t.Fatal("different run ids must yield different namespaces")
	}
	for _, bad := range []string{"", "P1A", "p1_a", "a/b", strings.Repeat("x", 200)} {
		if _, err := namespaceFor(bad); err == nil {
			t.Fatalf("namespaceFor(%q) must be refused", bad)
		}
	}
}

func TestProtocolConstantsMatchTheDesignOfRecord(t *testing.T) {
	if victimServiceSec != 60 {
		t.Fatalf("victim service = %d, want 60", victimServiceSec)
	}
	// 40 s, not the 49 s the old offset subtraction produced.
	if doseSec != 40 {
		t.Fatalf("dose = %d, want 40", doseSec)
	}
}

func TestGateRefusalBlocksCountableResults(t *testing.T) {
	if len(unimplementedGates()) == 0 {
		t.Fatal("while gates are unimplemented the list must not be empty")
	}
	err := gateRefusal(false)
	if err == nil {
		t.Fatal("without the preview flag the runner must refuse to run")
	}
	// The refusal has to name what is missing, or the next person reads it as a transient failure and
	// reruns until it passes.
	for _, want := range unimplementedGates() {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("refusal must name the missing gate %q, got: %v", want, err)
		}
	}
	if err := gateRefusal(true); err != nil {
		t.Fatalf("the preview flag must allow a run: %v", err)
	}
}
