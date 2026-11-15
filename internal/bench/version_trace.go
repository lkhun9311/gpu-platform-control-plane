package bench

import (
	"fmt"
	"math"
	"math/rand/v2"
)

// VersionTrace is one block's workload at one load: the opening rows of a single seeded stream, cut at warm-up plus windowSeconds.
//
// Every row draws its gap, input length and output length from the stream in a fixed order, and the cut depends only on the arrival time.
// So a shorter window's trace is a prefix of a longer one's, which ChooseWindow and the bundle check both rely on.
// A warm-up that does not send every input x output class is refused rather than redrawn, because redrawing would be choosing a workload.
func (d VersionStudyDesign) VersionTrace(seed int64, offeredRate float64, windowSeconds int) ([]TraceRow, error) {
	if math.IsNaN(offeredRate) || math.IsInf(offeredRate, 0) || offeredRate <= 0 {
		return nil, fmt.Errorf("offered rate %v is not a positive finite number", offeredRate)
	}
	if windowSeconds < d.MinMeasureSeconds || windowSeconds > d.MaxMeasureSeconds || (windowSeconds-d.MinMeasureSeconds)%60 != 0 {
		return nil, fmt.Errorf("window %d s is not one ChooseWindow can pick (%d to %d s in 60 s steps)", windowSeconds, d.MinMeasureSeconds, d.MaxMeasureSeconds)
	}
	chars := map[int]int{}
	for c, tokens := range versionStudyExactTokens() {
		chars[tokens] = c
	}
	for _, lw := range d.InputTokens {
		if _, ok := chars[lw.Tokens]; !ok {
			return nil, fmt.Errorf("input length %d tokens has no resolved prompt size", lw.Tokens)
		}
	}
	// The stream's second word is fixed, so the seed alone names the trace.
	rng := rand.New(rand.NewPCG(uint64(seed), 0x5eed_7a11_0f1e_2026))
	end := float64(d.WarmupSeconds+windowSeconds) * 1000
	var rows []TraceRow
	t := 0.0
	for {
		t += rng.ExpFloat64() / offeredRate * 1000
		in := drawLength(rng, d.InputTokens)
		out := drawLength(rng, d.OutputTokens)
		if t >= end {
			break
		}
		rows = append(rows, TraceRow{
			Index: len(rows), OffsetMs: int64(t), Tenant: PremiumTenant,
			PromptLenChars: chars[in], MaxOutputTokens: out, MinOutputTokens: out,
		})
	}
	if missing := d.warmupGaps(rows, windowSeconds); len(missing) > 0 {
		return nil, fmt.Errorf("the seeded warm-up never sends %v (input, output) tokens at %.3f req/s; the registration qualifies warm-up by content and has no rule to redraw it", missing, offeredRate)
	}
	return rows, nil
}

// MeasuredRows counts the rows whose intended arrival falls in the window, the population every endpoint is computed over.
func (d VersionStudyDesign) MeasuredRows(rows []TraceRow, windowSeconds int) int {
	n := 0
	for _, r := range rows {
		if d.PhaseOf(r.OffsetMs, windowSeconds) == PhaseMeasure {
			n++
		}
	}
	return n
}

// drawLength picks one registered length by its weight, consuming exactly one draw so the stream's order never depends on the outcome.
func drawLength(rng *rand.Rand, mix []LengthWeight) int {
	total := 0.0
	for _, lw := range mix {
		total += lw.Weight
	}
	u := rng.Float64() * total
	for _, lw := range mix {
		if u < lw.Weight {
			return lw.Tokens
		}
		u -= lw.Weight
	}
	return mix[len(mix)-1].Tokens
}

// warmupGaps lists the (input, output) token classes the warm-up of rows never sends.
func (d VersionStudyDesign) warmupGaps(rows []TraceRow, windowSeconds int) [][2]int {
	tokens := versionStudyExactTokens()
	seen := map[[2]int]bool{}
	for _, r := range rows {
		if d.PhaseOf(r.OffsetMs, windowSeconds) == PhaseWarmup {
			seen[[2]int{tokens[r.PromptLenChars], r.MaxOutputTokens}] = true
		}
	}
	var missing [][2]int
	for _, in := range d.InputTokens {
		for _, out := range d.OutputTokens {
			if c := [2]int{in.Tokens, out.Tokens}; !seen[c] {
				missing = append(missing, c)
			}
		}
	}
	return missing
}
