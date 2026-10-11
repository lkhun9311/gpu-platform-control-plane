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

import "testing"

// The declared-load tally covers every offered row, including the ones the admission guard never gated.
//
// WHY THIS FILE EXISTS, measured 2026-10-03. The gate's own tests build ArmSummary directly, so they never
// run Summarize and never exercise the choice of population. Moving the tally inside the eligible-population
// guard -- the single most likely wrong edit anyone could make to it -- left the whole suite GREEN. A
// mutation run found that: three other mutations of the gate each reddened four tests, and that one reddened
// none.
//
// The consequence is not cosmetic. The guard's rule is tier == standard AND estimate >= threshold. The
// premium tier's estimate is 294 against a 4,096 threshold, so premium is excluded BY CONSTRUCTION: in the
// ninth pilot that is 69,825 of 71,215 rows, and premium TTFT is the study's primary endpoint. Narrowed to
// the eligible rows, the gate would compare only the contender, find it agreeing, and PASS -- printing "the
// engine reported the declared count" over a premium population nothing had looked at.
//
// So the property pinned here is the population itself, not the verdict.
func TestTheDeclaredLoadTallyCoversRowsTheAdmissionGuardNeverSaw(t *testing.T) {
	// A premium row exactly as the sharing matrix sends it: estimate 294, far BELOW the 4,096 threshold, and
	// a tier the guard does not gate. Nothing about it is eligible.
	premium := RawRow{
		Arm: ArmShared, Tenant: PremiumTenant, Tier: "premium",
		EstInputTokens: 294, EngineInputTokens: 256, OutputTokens: 16, HTTPStatus: 200,
		LongThreshold: eligibleLongThreshold,
	}
	// And a contender row that IS eligible, so the test can tell "counted everything" from "counted nothing".
	contender := RawRow{
		Arm: ArmShared, Tenant: NoisyTenant, Tier: tierStandard, IsNoisy: true,
		EstInputTokens: 10_645, EngineInputTokens: 8192, OutputTokens: 40, HTTPStatus: 200,
		LongThreshold: eligibleLongThreshold,
	}

	s := Summarize(ArmShared, []RawRow{premium, premium, premium, contender})

	if got := s.eligibleScored; got != 1 {
		t.Fatalf("the eligible population holds %d rows, want 1; if premium had become eligible this test "+
			"would pass for the wrong reason and stop pinning anything", got)
	}
	if got := s.EngineInputTokensByTenant[PremiumTenant][256]; got != 3 {
		t.Errorf("the declared-load tally counted %d premium rows reporting 256, want 3. Premium is outside "+
			"the admission guard's eligible population by construction, and a tally that lives inside that "+
			"guard cannot see the study's primary endpoint at all", got)
	}
	if got := s.EngineInputTokensByTenant[NoisyTenant][8192]; got != 1 {
		t.Errorf("the declared-load tally counted %d contender rows reporting 8192, want 1", got)
	}

	// And the gate built on those counts must PASS here. A population check that pins the counters but not
	// the reading would survive a change that collected the rows and then ignored them.
	r := EvaluateDeclaredLoad([]ArmSummary{s}, &FrozenTuple{PremiumInputTokens: 256, ContenderInputTokens: 8192},
		PremiumTenant, NoisyTenant)
	if r.Fired || r.NotEvaluable {
		t.Errorf("the gate refused a run that carried the declared load on every row (fired=%v, n/e=%v): %s",
			r.Fired, r.NotEvaluable, r.Detail)
	}
}

// A row the engine never accounted for is counted apart, wherever it sits relative to the threshold.
//
// The same narrowing would also hide unreported PREMIUM rows, which is the worse half: the gate would come
// back PASS rather than uncomputable, so "we could not check 69,825 rows" would print as "checked".
func TestUnreportedRowsAreCountedOutsideTheEligiblePopulationToo(t *testing.T) {
	// Premium, below the threshold, and the engine answered without a usage block.
	silent := RawRow{
		Arm: ArmShared, Tenant: PremiumTenant, Tier: "premium",
		EstInputTokens: 294, OutputTokens: 16, HTTPStatus: 200,
		LongThreshold: eligibleLongThreshold,
	}
	s := Summarize(ArmShared, []RawRow{silent, silent})

	if got := s.EngineInputTokensUnreportedByTenant[PremiumTenant]; got != 2 {
		t.Errorf("%d premium rows were recorded as unreported, want 2; rows the guard never gated are still "+
			"rows the trace sent", got)
	}
	r := EvaluateDeclaredLoad([]ArmSummary{s}, &FrozenTuple{PremiumInputTokens: 256, ContenderInputTokens: 8192},
		PremiumTenant, NoisyTenant)
	if !r.NotEvaluable {
		t.Errorf("a run whose premium rows reported no count at all was not reported as uncomputable "+
			"(fired=%v, n/e=%v): %s", r.Fired, r.NotEvaluable, r.Detail)
	}
}
