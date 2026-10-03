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

// declaredLoadArm builds one arm whose engine-reported counts are stated outright.
//
// reported maps tenant -> count -> rows, and unreported maps tenant -> rows the engine answered without a
// usage block. Written as a helper rather than inline because every case below differs in exactly those two
// maps, and a reader has to be able to see which.
func declaredLoadArm(arm string, reported map[string]map[int]int, unreported map[string]int) ArmSummary {
	if reported == nil {
		reported = map[string]map[int]int{}
	}
	if unreported == nil {
		unreported = map[string]int{}
	}
	return ArmSummary{
		Arm:                                 arm,
		EngineInputTokensByTenant:           reported,
		EngineInputTokensUnreportedByTenant: unreported,
	}
}

// The frozen tuple the sharing matrix's registration holds, repeated here so a change to the registry is
// visible as a change to this test rather than silently retuning it.
func declaredLoadFrozen() *FrozenTuple {
	return &FrozenTuple{
		PremiumPromptChars:    1174,
		ContenderPromptChars:  42579,
		PremiumInputTokens:    256,
		ContenderInputTokens:  8192,
		TimeoutMs:             60000,
		PremiumOutputTokens:   64,
		ContenderOutputTokens: 16,
	}
}

// Reading 4e tells agreement, disagreement, silence and emptiness apart.
//
// The four outcomes are the point. A check that returns one verdict for "every row carried the declared
// length" and for "no row said anything" is worse than no check: it makes a reader believe the load was
// verified when nothing was compared.
func TestTheDeclaredLoadGateSeparatesAgreementFromSilence(t *testing.T) {
	for _, tc := range []struct {
		name         string
		summaries    []ArmSummary
		frozen       *FrozenTuple
		fired        bool
		notEvaluable bool
		wantDetail   string
	}{
		{
			// The ninth pilot's actual shape: premium 256 on every row, contender 8192 on every row, and R1
			// carrying no contender at all.
			name: "every row carried the declared length",
			summaries: []ArmSummary{
				declaredLoadArm(ArmR1, map[string]map[int]int{PremiumTenant: {256: 23275}}, nil),
				declaredLoadArm(ArmShared, map[string]map[int]int{
					PremiumTenant: {256: 23275}, NoisyTenant: {8192: 695},
				}, nil),
				declaredLoadArm(ArmTimeSlicing, map[string]map[int]int{
					PremiumTenant: {256: 23275}, NoisyTenant: {8192: 695},
				}, nil),
			},
			frozen:     declaredLoadFrozen(),
			wantDetail: "0 unreported",
		},
		{
			name: "one arm sent a different premium length",
			summaries: []ArmSummary{
				declaredLoadArm(ArmR1, map[string]map[int]int{PremiumTenant: {256: 23275}}, nil),
				declaredLoadArm(ArmShared, map[string]map[int]int{
					PremiumTenant: {512: 23275}, NoisyTenant: {8192: 695},
				}, nil),
			},
			frozen:     declaredLoadFrozen(),
			fired:      true,
			wantDetail: "reported 512",
		},
		{
			// A single row is enough. The frozen tuple is a claim about the whole trace, and one request that
			// carried something else contradicts it.
			name: "a single row disagrees among tens of thousands that agree",
			summaries: []ArmSummary{
				declaredLoadArm(ArmShared, map[string]map[int]int{
					PremiumTenant: {256: 23274, 257: 1}, NoisyTenant: {8192: 695},
				}, nil),
			},
			frozen:     declaredLoadFrozen(),
			fired:      true,
			wantDetail: "reported 257 on 1 rows",
		},
		{
			// NOT a pass. Nothing says the load was wrong, and nothing says it was right.
			name: "the engine reported nothing for some rows",
			summaries: []ArmSummary{
				declaredLoadArm(ArmShared, map[string]map[int]int{
					PremiumTenant: {256: 23000}, NoisyTenant: {8192: 695},
				}, map[string]int{PremiumTenant: 275}),
			},
			frozen:       declaredLoadFrozen(),
			notEvaluable: true,
			wantDetail:   "cannot be called verified",
		},
		{
			// An empty population is not agreement with anything. This is the case the old code would have
			// read as "nothing disagreed".
			name: "no row reported a count at all",
			summaries: []ArmSummary{
				declaredLoadArm(ArmShared, nil, nil),
			},
			frozen:       declaredLoadFrozen(),
			notEvaluable: true,
			wantDetail:   "nothing to compare",
		},
		{
			name:         "no evidence at all",
			summaries:    nil,
			frozen:       declaredLoadFrozen(),
			notEvaluable: true,
			wantDetail:   "nothing to compare",
		},
		{
			// A study that froze no tuple gets an uncomputable gate, not a silent pass.
			name: "the study froze no load tuple",
			summaries: []ArmSummary{
				declaredLoadArm(ArmShared, map[string]map[int]int{PremiumTenant: {256: 10}}, nil),
			},
			frozen:       nil,
			notEvaluable: true,
			wantDetail:   "froze no load tuple",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := EvaluateDeclaredLoad(tc.summaries, tc.frozen, PremiumTenant, NoisyTenant)
			if got.ID != "4e" {
				t.Fatalf("the gate came back as reading %q; sharingRunInvalid keys the exit status on 4e", got.ID)
			}
			if got.Fired != tc.fired {
				t.Errorf("Fired = %v, want %v -- detail was %q", got.Fired, tc.fired, got.Detail)
			}
			if got.NotEvaluable != tc.notEvaluable {
				t.Errorf("NotEvaluable = %v, want %v -- detail was %q", got.NotEvaluable, tc.notEvaluable, got.Detail)
			}
			if !strings.Contains(got.Detail, tc.wantDetail) {
				t.Errorf("the detail does not say %q, so a reader cannot see the basis:\n%s", tc.wantDetail, got.Detail)
			}
		})
	}
}

// R1 carrying no contender is not a missing population.
//
// R1 is the isolated premium baseline BY DESIGN -- reading 4b's contender floor already exempts it. A gate
// that counted its absent contender as unreported rows would come back uncomputable on every correct
// matrix, which is a refusal nobody could ever clear.
func TestTheDeclaredLoadGateDoesNotPunishR1ForHavingNoContender(t *testing.T) {
	got := EvaluateDeclaredLoad([]ArmSummary{
		declaredLoadArm(ArmR1, map[string]map[int]int{PremiumTenant: {256: 100}}, nil),
	}, declaredLoadFrozen(), PremiumTenant, NoisyTenant)

	if got.Fired || got.NotEvaluable {
		t.Fatalf("R1 alone disqualified the run: Fired=%v NotEvaluable=%v -- %s",
			got.Fired, got.NotEvaluable, got.Detail)
	}
}

// A pass says what it does not establish, in the same sentence that says it passed.
//
// The engine's count agreeing with the declared count does not show the prompt STRINGS were the frozen ones,
// that the tokenizer revision matched, that the tokens were prefilled rather than served from cache, or that
// the other three frozen values applied. A reader who takes this gate for "the load was the declared load"
// has been misled by its name, so the detail carries the limits.
func TestTheDeclaredLoadGateStatesWhatItDoesNotEstablish(t *testing.T) {
	got := EvaluateDeclaredLoad([]ArmSummary{
		declaredLoadArm(ArmShared, map[string]map[int]int{
			PremiumTenant: {256: 10}, NoisyTenant: {8192: 10},
		}, nil),
	}, declaredLoadFrozen(), PremiumTenant, NoisyTenant)

	if got.Fired || got.NotEvaluable {
		t.Fatalf("the agreeing case did not pass: %s", got.Detail)
	}
	for _, want := range []string{
		"not a pre-registered check",
		"prompt text",
		"tokenizer revision",
		"prefill",
	} {
		if !strings.Contains(got.Detail, want) {
			t.Errorf("a passing detail does not mention %q, so the pass reads stronger than it is:\n%s",
				want, got.Detail)
		}
	}
}
