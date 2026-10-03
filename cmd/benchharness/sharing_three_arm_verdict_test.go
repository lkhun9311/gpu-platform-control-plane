package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// TestAThreeArmMatrixProducesAVerdict pins the one thing a paid three-arm run is bought for.
//
// # WHY THIS EXISTS
//
// The 2026-10-01 ten-cell run completed, cost $1.44, carried clean evidence, and fired NO pre-registered
// reading: a `GpuSharingBenchmark` declares one `sharingMode`, `sharedInstance` compiles to `{R1, shared}`,
// and both are ROLE fields rather than candidates -- so `a.Sharing` was empty and readings 1, 2, 3 and 5
// came back NotEvaluable. Reading 4d now refuses that shape instead of printing a gap, which is the right
// behaviour and not a verdict.
//
// What follows from that is a question worth a card: will a three-arm matrix under the frozen contract
// actually produce an answer? `internal/bench` pins it at the SharingArms level with synthetic fixtures
// (TestAnArmThatWrecksTheStreamDoesNotFireTheDeliverable asserts reading 5 fires; the 4c test asserts
// reading 1 does). Nothing pinned the path a paid run actually takes: raw rows -> Summarize -> repetition
// split -> arm assembly in this package -> readings. That path is where the empty `Sharing` slice came
// from, and it is the one the ninth pilot's real evidence goes through.
//
// So this drives the REAL report entry point over rows shaped like the ninth pilot's -- three arms, two
// repetitions, two tenants -- and requires an answer. Run by hand against the ninth pilot's committed rows
// the same path prints `ANSWER: 5 (timeSlicing)` and exits 0; those rows are evidence in a private sibling
// repository and a release asset, so they cannot be a test input here. The rows are therefore synthesized,
// and what is asserted is the SHAPE of the conclusion rather than the ninth pilot's figures.
//
// Mutation that turns this red: restrict scoreSharingArms to an empty candidate set, or drop timeSlicing
// from the arms the report assembles.
func TestAThreeArmMatrixProducesAVerdict(t *testing.T) {
	dir := t.TempDir()

	// One row per request. The fields that matter to the readings, and why each is set:
	//
	//   OutputTokens > 1          -- inter-token time needs a gap, so TPOT is empty below two tokens and
	//                                readings 1 and 5 both gate on the premium tenant's TPOT p99.
	//   ErrorKind empty           -- a broken stream contributes tokens but no TPOT, by design.
	//   HTTPStatus 200            -- tallyDelivered counts tokens only on a real response.
	//   IsNoisy on the contender  -- the readings split victim from neighbour by this flag.
	//   Study = StudySharingMatrix -- an empty study reads as the M5-b gateway experiment, whose checks are
	//                                a different set entirely.
	//   TraceChecksum identical   -- the report refuses contended arms that replayed different traffic.
	//   EngineInputTokens per tenant -- reading 4e holds the engine's own count against the tuple the
	//                                registration froze, over EVERY row rather than the eligible population.
	//                                This fixture means to represent a run that carried the declared load, so
	//                                its rows have to say so: premium 256 and contender 8192. Left at zero
	//                                they describe a run whose engine reported nothing, and the gate rightly
	//                                refuses to call that verified -- which is how this test first went red.
	row := func(arm, tenant string, noisy bool, i, rep int, ttftMs, tpotMs float64, outTokens int) bench.RawRow {
		base := int64(1_000_000_000+i*2_000_000) + int64(rep)*1_000_000_000_000
		first := base + int64(ttftMs*1e6)
		end := first + int64(tpotMs*1e6)*int64(outTokens-1)
		// Keyed on the tenant the row is for, not on the noisy flag, because the gate's expectation is keyed
		// on the tenant name and a fixture that agreed with the gate for a different reason would pass while
		// pinning nothing.
		engineIn, exactIn, estIn := 256, 256, 294
		if tenant == bench.NoisyTenant {
			engineIn, exactIn, estIn = 8192, 8192, 8500
		}
		return bench.RawRow{
			Index: i, Arm: arm, Tenant: tenant, IsNoisy: noisy,
			SendUnixNanos: base, FirstTokenUnixNanos: first, EndUnixNanos: end,
			EstInputTokens: estIn, ExactInputTokens: exactIn, EngineInputTokens: engineIn,
			OutputTokens: outTokens, HTTPStatus: 200,
			Study: bench.StudySharingMatrix, TraceChecksum: "t", LongThreshold: 4096, MatchTolerance: 0.05,
		}
	}

	// The three arms the readings need, and the shape that makes an answer possible.
	//
	// R1 is the isolated baseline: premium only, the denominator of both bars. `shared` is the control every
	// improvement is measured from. `timeSlicing` is the candidate, and it is given a tail well inside the
	// 2.00x bar while its premium stream sits outside the 1.25x one -- the outcome reading 5 exists to name,
	// "it protects but not to the bar". Reading 1 must therefore NOT fire, and 5 must.
	arms := []struct {
		name                       string
		premiumTTFT, premiumTPOT   float64
		contenderOut, contenderCnt int
	}{
		{bench.ArmR1, 70, 18, 0, 0},
		{bench.ArmShared, 1900, 40, 40, 140},
		{bench.ArmTimeSlicing, 100, 30, 38, 140},
	}

	var paths []string
	for _, a := range arms {
		for rep := 1; rep <= 2; rep++ {
			var b strings.Builder
			enc := func(r bench.RawRow) {
				line, err := json.Marshal(r)
				if err != nil {
					t.Fatalf("marshal: %v", err)
				}
				b.Write(line)
				b.WriteByte('\n')
			}
			// MinTailSamples premium completions per repetition, so neither the pooled floor nor the
			// per-repetition one refuses the arm. A floor that refuses here would make the test pass or
			// fail for a reason that is not what it is about.
			for i := 1; i <= bench.MinTailSamples+40; i++ {
				enc(row(a.name, bench.PremiumTenant, false, i, rep, a.premiumTTFT, a.premiumTPOT, 16))
			}
			for i := 1; i <= a.contenderCnt; i++ {
				enc(row(a.name, bench.NoisyTenant, true, 10_000+i, rep, 900, 60, a.contenderOut))
			}
			p := filepath.Join(dir, fmt.Sprintf("raw-%s-%d.jsonl", a.name, rep))
			if err := os.WriteFile(p, []byte(b.String()), 0o600); err != nil {
				t.Fatalf("write %s: %v", p, err)
			}
			paths = append(paths, p)
		}
	}

	args := []string{}
	for _, p := range paths {
		args = append(args, "-raw", p)
	}

	// The report's error is not the assertion. `report` returning nil means "nothing was refused", and a run
	// where every reading came back NotEvaluable returns nil too -- that is exactly the shape the ten-cell run
	// had, and checking only the error would pass on it. So the OUTPUT is what is asserted.
	out, err := captureStdout(t, func() error { return report(args) })
	if err != nil {
		t.Fatalf("a three-arm matrix was refused by the report: %v\n%s", err, out)
	}
	if !strings.Contains(out, "ANSWER: 5") {
		t.Errorf("a three-arm matrix produced no reading-5 answer, so buying one would buy no verdict:\n%s", out)
	}
	if !strings.Contains(out, "[FIRED] 5") {
		t.Errorf("reading 5 did not fire; the answer line alone could come from elsewhere:\n%s", out)
	}
	// And 4d must be ABSENT. Its presence would mean the candidate set was empty after all, which is the
	// condition this test exists to distinguish from a real verdict.
	if strings.Contains(out, " 4d ") {
		t.Errorf("reading 4d fired on a three-arm matrix, so the candidate set was empty:\n%s", out)
	}
	// Reading 1 must not fire: the candidate's premium stream sits outside the 1.25x bar on purpose, and an
	// arm that fired 1 here would mean the bars are not being applied.
	if strings.Contains(out, "[FIRED] 1 ") {
		t.Errorf("reading 1 fired POSITIVE for an arm whose stream misses its bar:\n%s", out)
	}
}
