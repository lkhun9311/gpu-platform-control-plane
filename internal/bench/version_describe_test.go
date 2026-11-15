package bench

import (
	"math"
	"strings"
	"testing"
	"time"
)

// TestOutcomesCarryTPOTAndTheTrailer: TPOT is per token after the first, and the trailer is measured from the last content byte.
func TestOutcomesCarryTPOTAndTheTrailer(t *testing.T) {
	d := versionAsyncDesign()
	p := *versionStudySampling()
	tr := evalTraceRow(0, 0)
	r := timedRow(tr, 0, 100, 100+63*20)
	ms := int64(time.Millisecond)
	usage, done := *r.Clock.LastContentNanos+3*ms, *r.Clock.LastContentNanos+5*ms
	r.Clock.UsageNanos, r.Clock.DoneNanos = &usage, &done
	out, err := d.CellOutcomes(p, 180, []TraceRow{tr}, []RawRow{r})
	if err != nil {
		t.Fatal(err)
	}
	o := out[0]
	if math.Abs(o.TPOTNanos-20*float64(ms)) > 1 || o.UsageAfterLastNanos != 3*float64(ms) || o.DoneAfterLastNanos != 5*float64(ms) {
		t.Fatalf("tpot %v usage %v done %v, want 20, 3 and 5 ms", o.TPOTNanos, o.UsageAfterLastNanos, o.DoneAfterLastNanos)
	}
	// A failure has no TPOT, whatever content it streamed.
	r.Disposition, r.ErrorKind = "timeout", "timeout"
	out, _ = d.CellOutcomes(p, 180, []TraceRow{tr}, []RawRow{r})
	if !math.IsNaN(out[0].TPOTNanos) || !math.IsNaN(out[0].UsageAfterLastNanos) {
		t.Fatalf("a timeout has tpot %v and trailer %v", out[0].TPOTNanos, out[0].UsageAfterLastNanos)
	}
}

// describeCells builds every arm at every load, with fail timeouts in each cell of the given treatment.
func describeCells(blocks []int, failTreatment string, fail int) CampaignCells {
	cells := CampaignCells{}
	for _, tr := range versionStudyTreatments {
		cells[tr] = map[string]map[int][]RequestOutcome{}
		for _, l := range versionStudyLoads {
			cells[tr][l.Name] = map[int][]RequestOutcome{}
			for _, b := range blocks {
				var cell []RequestOutcome
				for i := range 100 {
					o := RequestOutcome{Index: i, Disposition: DispositionSuccess, TTFTNanos: 1e8, E2ENanos: 1e9, Good: true,
						TPOTNanos: float64(i+1) * 1e6, UsageAfterLastNanos: 2e6, DoneAfterLastNanos: math.NaN()}
					if tr == failTreatment && i >= 100-fail {
						// The slowest requests are the ones that fail, so a success-only TPOT looks better than the arm is.
						o = RequestOutcome{Index: i, Disposition: DispositionTimeout, TTFTNanos: math.Inf(1), E2ENanos: math.Inf(1),
							TPOTNanos: math.NaN(), UsageAfterLastNanos: math.NaN(), DoneAfterLastNanos: math.NaN()}
					}
					cell = append(cell, o)
				}
				cells[tr][l.Name][b] = cell
			}
		}
	}
	return cells
}

// TestDescribeReportsReliabilityPerCellAndPooled: failures by kind for every cell and the pool, and the success-only TPOT.
func TestDescribeReportsReliabilityPerCellAndPooled(t *testing.T) {
	d := versionAsyncDesign()
	blocks := []int{1, 2, 3, 4, 5, 6}
	desc, err := d.Describe(180, blocks, describeCells(blocks, TreatmentB, 10), 1.2)
	if err != nil {
		t.Fatal(err)
	}
	if len(desc) != 6 {
		t.Fatalf("%d descriptions, want three treatments at two loads", len(desc))
	}
	var b ArmDescription
	for _, a := range desc {
		if a.Treatment == TreatmentB && a.Load == LoadL060 {
			b = a
		}
	}
	if b.Offered != 600 || b.Successes != 540 || b.Failures[DispositionTimeout] != 60 || math.Abs(b.SuccessFraction-0.9) > 1e-12 {
		t.Fatalf("pooled B: offered %d successes %d failures %v fraction %v", b.Offered, b.Successes, b.Failures, b.SuccessFraction)
	}
	if len(b.Cells) != 6 || b.Cells[2].Block != 3 || b.Cells[2].Failures[DispositionTimeout] != 10 {
		t.Fatalf("per-cell B: %+v", b.Cells)
	}
	for _, a := range desc {
		if a.Treatment == TreatmentA && (a.TTFTP99Ms != 100 || a.E2EP99Ms != 1000) {
			t.Fatalf("A at %s: ttft p99 %v e2e p99 %v, want 100 and 1000 ms", a.Load, a.TTFTP99Ms, a.E2EP99Ms)
		}
	}
	if !math.IsInf(b.E2EP99Ms, 1) {
		t.Fatalf("e2e p99 %v with a tenth of requests failed, want +Inf", b.E2EP99Ms)
	}
	// Success-only TPOT: the 90 survivors per block run 1..90 ms, so its p99 is 90 ms, better than the arm's real tail.
	if !b.TPOTP99Ms.Defined || b.TPOTP99Ms.Value != 90 || b.TPOTRows != 540 {
		t.Fatalf("tpot p99 %+v over %d rows", b.TPOTP99Ms, b.TPOTRows)
	}
	if !b.UsageTrailerP99Ms.Defined || b.UsageTrailerP99Ms.Value != 2 || b.DoneTrailerP99Ms.Defined {
		t.Fatalf("trailers usage %+v done %+v", b.UsageTrailerP99Ms, b.DoneTrailerP99Ms)
	}
	// 1.2 USD/h over 6 × 180 s is 0.36 USD, for 540 good requests.
	if !b.CostPerSLORequestUSD.Defined || math.Abs(b.CostPerSLORequestUSD.Value-0.36/540) > 1e-15 {
		t.Fatalf("cost %+v", b.CostPerSLORequestUSD)
	}
	if math.Abs(b.GoodputPerSecond-540.0/1080) > 1e-12 {
		t.Fatalf("goodput %v", b.GoodputPerSecond)
	}
}

// TestDescribeNamesWhatItCannotReport: no good request has no price, and a missing rate or block is refused.
func TestDescribeNamesWhatItCannotReport(t *testing.T) {
	d := versionAsyncDesign()
	blocks := []int{1, 2}
	desc, err := d.Describe(180, blocks, describeCells(blocks, TreatmentC, 100), 1.2)
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range desc {
		if a.Treatment == TreatmentC && (a.CostPerSLORequestUSD.Defined || a.TPOTP99Ms.Defined || !strings.Contains(a.CostPerSLORequestUSD.Reason, "no good request")) {
			t.Fatalf("C with every request failed: cost %+v tpot %+v", a.CostPerSLORequestUSD, a.TPOTP99Ms)
		}
	}
	if _, err := d.Describe(180, blocks, describeCells(blocks, "", 0), 0); err == nil {
		t.Fatal("described at a rate of zero")
	}
	if _, err := d.Describe(180, []int{1, 2, 3}, describeCells(blocks, "", 0), 1.2); err == nil {
		t.Fatal("described a block no arm has")
	}
}
