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

package bench

import (
	"strings"
	"testing"
)

const sizingOverheadMiB = 1400

// The finding that chose the card, kept as a test so it cannot quietly stop being true.
//
// Two Qwen2.5-3B engines do not fit on a T4, and the failure is the dangerous kind: the second engine
// starts, profiles, and finds a cache too small to hold one prompt. Nothing errors. The run produces
// latencies that describe eviction and look like a sharing-mode result.
func TestTwoEnginesOfTheFlagshipModelDoNotFitOnTheCardM5bUses(t *testing.T) {
	p := SharingPlan{Card: CardT4, Model: ModelQwen3B, Engines: 2, UtilizationPerEngine: 0.475, NonKVOverheadMiB: sizingOverheadMiB}

	err := p.Validate()
	if err == nil {
		t.Fatalf("a T4 hosting two %s engines validated; it leaves %d KV tokens each, which is less than one contender prompt",
			ModelQwen3B.Name, p.KVTokensPerEngine())
	}
	if !strings.Contains(err.Error(), "KV") {
		t.Errorf("the refusal does not name the KV cache as the thing that ran out: %v", err)
	}
	if got := p.KVTokensPerEngine(); got >= minUsefulKVTokens {
		t.Errorf("the T4 plan yields %d KV tokens per engine, which would make this test vacuous", got)
	}
}

// The card M5-c does use has to actually work, or the conclusion is only half checked.
func TestTwoEnginesOfTheFlagshipModelFitOnTheCardM5cUses(t *testing.T) {
	p := SharingPlan{Card: CardA10G, Model: ModelQwen3B, Engines: 2, UtilizationPerEngine: 0.475, NonKVOverheadMiB: sizingOverheadMiB}

	if err := p.Validate(); err != nil {
		t.Fatalf("an A10G hosting two %s engines was refused: %v", ModelQwen3B.Name, err)
	}
	// Enough to batch several contender prompts at once, which is what makes a sharing comparison mean
	// anything: two engines that can each only hold one sequence are not sharing, they are taking turns.
	if got := p.KVTokensPerEngine(); got < 8*7695 {
		t.Errorf("A10G plan leaves %d KV tokens per engine, too few to batch", got)
	}
}

// The exclusive arm is the same card with one engine, and it must remain the roomiest.
func TestTheExclusiveArmHasStrictlyMoreCacheThanTheSharedOne(t *testing.T) {
	one := SharingPlan{Card: CardA10G, Model: ModelQwen3B, Engines: 1, UtilizationPerEngine: 0.95, NonKVOverheadMiB: sizingOverheadMiB}
	two := SharingPlan{Card: CardA10G, Model: ModelQwen3B, Engines: 2, UtilizationPerEngine: 0.475, NonKVOverheadMiB: sizingOverheadMiB}

	if err := one.Validate(); err != nil {
		t.Fatalf("the exclusive arm was refused: %v", err)
	}
	if one.KVTokensPerEngine() <= two.KVTokensPerEngine() {
		t.Errorf("exclusive gives %d KV tokens and shared gives %d; if sharing did not cost cache there would be nothing to measure",
			one.KVTokensPerEngine(), two.KVTokensPerEngine())
	}
}

// Utilization that adds past the card is the mistake time-slicing invites, because the plugin advertises
// more devices and says nothing about memory.
func TestAPlanThatClaimsMoreThanOneCardIsRefused(t *testing.T) {
	p := SharingPlan{Card: CardA10G, Model: ModelQwen3B, Engines: 2, UtilizationPerEngine: 0.90, NonKVOverheadMiB: sizingOverheadMiB}

	err := p.Validate()
	if err == nil {
		t.Fatal("two engines at 0.90 utilization validated; that claims 1.8 cards from a machine that has one")
	}
	if !strings.Contains(err.Error(), "they do not create a second") {
		t.Errorf("the refusal does not explain that a shared pool is not a second pool: %v", err)
	}
}

// Not starting and thrashing are different outcomes, and the refusal has to say which one it is.
//
// This branch was reachable and untested: every other case here runs out of USEFUL cache before it runs
// out of cache, so disabling the negative-cache gate entirely left the suite green and only changed which
// sentence the operator read. The two sentences describe different mornings -- one where the Pod never
// became ready, and one where it did and the numbers are about eviction.
func TestAPlanWithNoCacheAtAllSaysTheEngineWillNotStart(t *testing.T) {
	p := SharingPlan{Card: CardT4, Model: ModelQwen3B, Engines: 2, UtilizationPerEngine: 0.40, NonKVOverheadMiB: sizingOverheadMiB}
	if p.KVMiBPerEngine() > 0 {
		t.Fatalf("this plan leaves %.0f MiB, so it no longer covers the negative-cache case", p.KVMiBPerEngine())
	}

	err := p.Validate()
	if err == nil {
		t.Fatal("a plan with negative KV cache validated")
	}
	if !strings.Contains(err.Error(), "will not start") {
		t.Errorf("the refusal reports thrashing rather than a failure to start, which sends the operator "+
			"looking at latencies for a Pod that never became ready: %v", err)
	}
}

// A plan whose cache is positive but tiny is still refused, because "it started" is not the bar.
func TestAPlanIsRefusedWhileItsCacheIsTooSmallToBatch(t *testing.T) {
	// Chosen to land between "engine starts" and "engine can batch": positive KV, far below four prompts.
	p := SharingPlan{Card: CardT4, Model: ModelQwen3B, Engines: 2, UtilizationPerEngine: 0.49, NonKVOverheadMiB: sizingOverheadMiB}
	if p.KVMiBPerEngine() <= 0 {
		t.Skip("this plan fails the earlier gate; the case it means to cover has moved")
	}
	err := p.Validate()
	if err == nil {
		t.Fatalf("a plan with %d KV tokens per engine validated", p.KVTokensPerEngine())
	}
	if !strings.Contains(err.Error(), "eviction") {
		t.Errorf("the refusal does not say what such an arm would actually measure: %v", err)
	}
}
