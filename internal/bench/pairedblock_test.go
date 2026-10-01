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
	"math"
	"testing"
)

// These pin the M5-b interval the 2026-10-01 amendment specifies, and nothing pinned it before.
//
// The gate's point estimate was the ratio of each arm's POOLED p99 while its interval bootstrapped the
// MEAN of per-repetition ratios, so one gate decided on two estimands. Replacing the interval broke no
// test: the three that touch IncrementalValuePass assert only its boolean, and no test read the interval's
// value at all. A silent swap of estimators is exactly the shape this repository keeps meeting -- "did not
// run" indistinguishable from "passed" -- so the value itself is asserted here.

// block builds one repetition of `n` premium rows whose TTFTs are ttftMs, plus `timedOut` that never
// completed, which is what makes a block censored.
func block(n int, ttftMs float64, timedOut int) []RawRow {
	rows := make([]RawRow, 0, n+timedOut)
	for i := range n {
		send := int64(1_000_000_000 + i*2_000_000)
		first := send + int64(ttftMs*1e6)
		rows = append(rows, RawRow{
			Index: i, Arm: "static-cap", Tenant: PremiumTenant, HTTPStatus: 200,
			SendUnixNanos: send, FirstTokenUnixNanos: first, EndUnixNanos: first + 20_000_000,
			EstInputTokens: 294, ExactInputTokens: 256, OutputTokens: 16, MatchTolerance: 0.05,
		})
	}
	for i := range timedOut {
		send := int64(1_000_000_000 + (n+i)*2_000_000)
		rows = append(rows, RawRow{
			Index: n + i, Arm: "static-cap", Tenant: PremiumTenant, HTTPStatus: 0, ErrorKind: "timeout",
			SendUnixNanos: send, EstInputTokens: 294, ExactInputTokens: 256, MatchTolerance: 0.05,
		})
	}
	return rows
}

// TestThePairedBlockIntervalIsTheRatioOfPooledP99s asserts the VALUE, not just that one came back.
//
// Every block of an arm carries the same tail here, so every replicate pools to the same pooled p99 and
// the interval collapses onto the point estimate. That is the one case whose number can be written down
// without re-deriving the bootstrap, and it is enough to catch an estimator computing something else: the
// mean-of-ratios bootstrap on the same input returns the same collapsed value only because the inputs are
// degenerate, which the next test is for.
func TestThePairedBlockIntervalIsTheRatioOfPooledP99s(t *testing.T) {
	base := [][]RawRow{block(200, 200, 0), block(200, 200, 0), block(200, 200, 0), block(200, 200, 0)}
	cont := [][]RawRow{block(200, 110, 0), block(200, 110, 0), block(200, 110, 0), block(200, 110, 0)}

	ci := PairedBlockRatioCI("static-cap", base, cont, M5BIncrementalResamples, M5BIncrementalSeed, 0.05)
	if !ci.Valid {
		t.Fatalf("a four-block pair with no censoring produced no interval: %s", ci.InvalidReason)
	}
	// The pooled p99 of 200 identical-tail rows is that tail, so the ratio is 110/200 exactly.
	want := 110.0 / 200.0
	if math.Abs(ci.Lo-want) > 1e-9 || math.Abs(ci.Hi-want) > 1e-9 {
		t.Errorf("interval is [%.6f, %.6f], want both bounds at %.6f -- the replicate statistic is not the"+
			" ratio of pooled p99s", ci.Lo, ci.Hi, want)
	}
}

// TestThePairedBlockIntervalDiffersFromTheMeanOfRatios is the test that distinguishes the two estimands.
//
// With blocks that differ, the ratio of pooled p99s is NOT the mean of the per-repetition ratios: pooling
// weights a repetition by how many requests it completed and takes one nearest-rank percentile over the
// union, while the old statistic averaged four independent quotients. A test asserting only that some
// interval came back cannot tell the two apart, and that is how the swap would have gone unnoticed.
func TestThePairedBlockIntervalDiffersFromTheMeanOfRatios(t *testing.T) {
	// FOUR distinct per-block ratios. The first draft of this fixture used two tails repeated twice, so
	// both estimators mixed the same two quotients and returned the identical interval -- the test could
	// not have told them apart, and it said so rather than passing.
	base := [][]RawRow{block(200, 100, 0), block(200, 300, 0), block(200, 600, 0), block(200, 1000, 0)}
	cont := [][]RawRow{block(200, 90, 0), block(200, 240, 0), block(200, 540, 0), block(200, 300, 0)}

	blockCI := PairedBlockRatioCI("static-cap", base, cont, M5BIncrementalResamples, M5BIncrementalSeed, 0.05)
	if !blockCI.Valid {
		t.Fatalf("the block interval was refused on valid input: %s", blockCI.InvalidReason)
	}

	// The old statistic, computed the way the gate used to: each block's own p99 ratio, then BootstrapCI,
	// whose replicate statistic is their MEAN.
	ratios := make([]float64, len(base))
	for i := range base {
		b := Summarize("static-cap", base[i]).TTFTMsP99
		c := Summarize("static-cap", cont[i]).TTFTMsP99
		ratios[i] = c / b
	}
	meanCI := BootstrapCI(ratios, M5BIncrementalResamples, M5BIncrementalSeed, 0.05)
	if !meanCI.Valid {
		t.Fatalf("the mean-of-ratios interval was refused, so the two cannot be compared")
	}

	if math.Abs(blockCI.Lo-meanCI.Lo) < 1e-6 && math.Abs(blockCI.Hi-meanCI.Hi) < 1e-6 {
		t.Errorf("the block interval [%.6f, %.6f] equals the mean-of-ratios interval [%.6f, %.6f] on uneven"+
			" blocks, so this test cannot tell the amendment's estimator from the one it replaced",
			blockCI.Lo, blockCI.Hi, meanCI.Lo, meanCI.Hi)
	}
}

// TestOneBlockPairIsRefusedRatherThanCollapsed keeps the degenerate case a refusal.
//
// A single block makes every replicate that block, so the interval would be a point wearing an interval's
// name -- and the gate reads `Hi < 1.0`, which such a point satisfies whenever the ratio does. CI.Valid
// exists because that vacuous pass once disarmed the strictest check in the design.
func TestOneBlockPairIsRefusedRatherThanCollapsed(t *testing.T) {
	ci := PairedBlockRatioCI("static-cap",
		[][]RawRow{block(200, 200, 0)}, [][]RawRow{block(200, 110, 0)},
		M5BIncrementalResamples, M5BIncrementalSeed, 0.05)
	if ci.Valid {
		t.Errorf("one block per arm produced a usable interval [%.3f, %.3f]; it cannot bound its own variance",
			ci.Lo, ci.Hi)
	}
}

// TestUnequalBlockCountsAreRefused: the estimator does not zip what the caller failed to pair.
func TestUnequalBlockCountsAreRefused(t *testing.T) {
	ci := PairedBlockRatioCI("static-cap",
		[][]RawRow{block(200, 200, 0), block(200, 200, 0)},
		[][]RawRow{block(200, 110, 0)},
		M5BIncrementalResamples, M5BIncrementalSeed, 0.05)
	if ci.Valid {
		t.Error("two baseline blocks against one contender block produced an interval")
	}
}

// TestABaselineBlockWithNoCompletionRefusesRatherThanDroppingReplicates pins the amendment's rule that a
// replicate which cannot be computed is never silently skipped.
//
// A baseline block whose premium requests all timed out has a pooled p99 of zero, so any replicate drawing
// it has no ratio. Dropping those replicates and reporting the percentiles of the rest would publish an
// interval over the draws that happened to work -- narrower than the evidence supports, and silent.
func TestABaselineBlockWithNoCompletionRefusesRatherThanDroppingReplicates(t *testing.T) {
	base := [][]RawRow{block(200, 200, 0), block(0, 0, 200), block(200, 200, 0), block(200, 200, 0)}
	cont := [][]RawRow{block(200, 110, 0), block(200, 110, 0), block(200, 110, 0), block(200, 110, 0)}

	ci := PairedBlockRatioCI("static-cap", base, cont, M5BIncrementalResamples, M5BIncrementalSeed, 0.05)
	if ci.Valid {
		t.Errorf("a baseline block with no premium completion produced an interval [%.3f, %.3f] instead of a"+
			" refusal; the replicates that drew it have no ratio", ci.Lo, ci.Hi)
	}
	if ci.InvalidReason == "" {
		t.Error("the refusal carries no reason, so an operator cannot tell it from an absent interval")
	}
}

// TestTheAmendmentsSettingsAreTheOnesTheGateUses guards the two constants against a silent edit.
//
// They are M5-b's existing values adopted explicitly, NOT inherited from M5-c: a study whose numbers
// changed because another study's amendment moved a shared constant would be unreproducible from its own
// registration. The assertion is on the values, not on their being different, because "different" would
// still pass if both moved.
func TestTheAmendmentsSettingsAreTheOnesTheGateUses(t *testing.T) {
	if M5BIncrementalResamples != 2000 {
		t.Errorf("M5-b resamples are %d; the 2026-10-01 amendment fixed 2000", M5BIncrementalResamples)
	}
	if M5BIncrementalSeed != 1 {
		t.Errorf("M5-b seed is %d; the 2026-10-01 amendment fixed 1", M5BIncrementalSeed)
	}
	if RegisteredBootstrapResamples == M5BIncrementalResamples && RegisteredBootstrapSeed == M5BIncrementalSeed {
		t.Error("M5-b and M5-c now share both settings; each registration fixes its own, and one inheriting" +
			" the other's makes a study depend on an amendment it never cited")
	}
}

// TestTheOldPairingCouldPlaceThePointEstimateOutsideItsInterval is the numeric evidence for the amendment.
//
// Before 2026-10-01 the gate read a POOLED p99 ratio as its point estimate and a bootstrap of the MEAN of
// per-repetition ratios as its interval. Those are different quantities, so nothing stopped the point from
// falling outside the interval -- and on this input it does. The gate's rule is `ratio <= 0.90 && CI.Hi <
// 1.0`, which a mismatched pair can satisfy or fail for reasons that have nothing to do with the evidence.
//
// Under the amendment both come from the pooled p99 ratio, so the point estimate lies inside its own
// interval by construction. That is asserted here as a property rather than a number, because the bound
// values depend on the resampling settings and the property is what the amendment chose.
func TestTheOldPairingCouldPlaceThePointEstimateOutsideItsInterval(t *testing.T) {
	base := [][]RawRow{block(800, 100, 0), block(110, 1200, 0), block(800, 120, 0), block(110, 1500, 0)}
	cont := [][]RawRow{block(800, 95, 0), block(110, 400, 0), block(800, 115, 0), block(110, 450, 0)}

	var allBase, allCont []RawRow
	ratios := make([]float64, len(base))
	for i := range base {
		allBase = append(allBase, base[i]...)
		allCont = append(allCont, cont[i]...)
		ratios[i] = Summarize("static-cap", cont[i]).TTFTMsP99 / Summarize("static-cap", base[i]).TTFTMsP99
	}
	// The gate's point estimate, unchanged by the amendment: the ratio of the arms' pooled p99s.
	point := Summarize("static-cap", allCont).TTFTMsP99 / Summarize("static-cap", allBase).TTFTMsP99

	oldCI := BootstrapCI(ratios, M5BIncrementalResamples, M5BIncrementalSeed, 0.05)
	newCI := PairedBlockRatioCI("static-cap", base, cont, M5BIncrementalResamples, M5BIncrementalSeed, 0.05)
	if !oldCI.Valid || !newCI.Valid {
		t.Fatalf("one of the intervals was refused, so they cannot be compared: old %q new %q",
			oldCI.InvalidReason, newCI.InvalidReason)
	}

	if point >= oldCI.Lo && point <= oldCI.Hi {
		t.Errorf("the pooled point estimate %.6f lies inside the mean-of-ratios interval [%.6f, %.6f] on"+
			" this input, so this test no longer demonstrates the mismatch the amendment fixes",
			point, oldCI.Lo, oldCI.Hi)
	}
	if point < newCI.Lo || point > newCI.Hi {
		t.Errorf("the pooled point estimate %.6f falls outside the paired-block interval [%.6f, %.6f];"+
			" the amendment's whole claim is that the point and the interval are the same estimand",
			point, newCI.Lo, newCI.Hi)
	}
}
