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
	"time"

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

func TestUnimplementedGatesDoesNotNameADoneItem(t *testing.T) {
	// A refusal that names an already-implemented item (non-zero exit on failure, which main already does)
	// erodes the property the function exists for: a reader fixes the named thing and is still refused.
	for _, g := range unimplementedGates() {
		if strings.Contains(g, "non-zero exit") {
			t.Fatalf("gate %q names the already-implemented non-zero exit behaviour", g)
		}
	}
}

func TestRequireRunIDRejectsOnlyEmpty(t *testing.T) {
	// The flag used to default to "r1", which made colliding with a previous run's cluster-scoped fixtures
	// the default behaviour; there is no safe default, so only a genuinely supplied id may pass.
	if err := requireRunID(""); err == nil {
		t.Fatal("an empty run id must be refused")
	}
	if err := requireRunID("r1"); err != nil {
		t.Fatalf("a non-empty run id must be accepted: %v", err)
	}
}

func TestRefusePreviewOutRejectsOnlyTheCombination(t *testing.T) {
	if err := refusePreviewOut(true, "ledger.jsonl"); err == nil {
		t.Fatal("-preview with -out must be refused")
	}
	if err := refusePreviewOut(true, ""); err != nil {
		t.Fatalf("-preview without -out must be allowed: %v", err)
	}
	if err := refusePreviewOut(false, "ledger.jsonl"); err != nil {
		t.Fatalf("-out without -preview must be allowed: %v", err)
	}
	if err := refusePreviewOut(false, ""); err != nil {
		t.Fatalf("neither flag set must be allowed: %v", err)
	}
}

func TestCheckFlavorVariantCatchesAReusedRunID(t *testing.T) {
	// A reused run id leaves the old arm's ResourceFlavor in place; its variant label must match the new
	// arm's PolicyVariant() or the run would silently execute under the old mechanism.
	if err := checkFlavorVariant(map[string]string{variantLabelKey: "Never"}, "Any"); err == nil {
		t.Fatal("a mismatched variant must be refused")
	}
	if err := checkFlavorVariant(map[string]string{variantLabelKey: "Any"}, "Any"); err != nil {
		t.Fatalf("a matching variant must be allowed: %v", err)
	}
	if err := checkFlavorVariant(map[string]string{}, "Any"); err == nil {
		t.Fatal("a flavor missing the variant label entirely must be refused, not treated as a match")
	}
}

func TestHorizonSecCoversTheProtocolsFixedWindow(t *testing.T) {
	// 40 s dose + 60 s victim service + 30 s termination grace + 20 s startup margin = 150 s, the same
	// duration a1 now runs for; a shorter horizon would end the observation before the owner is ever Ready.
	if horizonSec != 150 {
		t.Fatalf("horizonSec = %d, want 150", horizonSec)
	}
}

func TestHorizonForRefusesBelowTheFixedWindow(t *testing.T) {
	min := time.Duration(horizonSec) * time.Second
	if _, err := horizonFor(min - time.Second); err == nil {
		t.Fatal("a horizon below the protocol's fixed window must be refused")
	}
	if got, err := horizonFor(min); err != nil || got != min {
		t.Fatalf("horizonFor(min) = %v, %v; want %v, nil", got, err, min)
	}
	if got, err := horizonFor(min + time.Minute); err != nil || got != min+time.Minute {
		t.Fatalf("a wider horizon must be allowed unchanged: got %v, %v", got, err)
	}
}
