package bench

import (
	"math"
	"math/rand"
	"slices"
	"strings"
	"testing"
	"time"
)

// evalTraceRow is a window row of the version study at offset ms past the start of the measurement window.
func evalTraceRow(i int, windowOffsetMs int64) TraceRow {
	d := versionAsyncDesign()
	return TraceRow{
		Index: i, OffsetMs: int64(d.WarmupSeconds)*1000 + windowOffsetMs,
		PromptLenChars: 1174, MaxOutputTokens: 64, MinOutputTokens: 64, ExactInputTokens: 256,
	}
}

// timedRow is a conforming success whose first and last content arrive firstMs and lastMs after the intended arrival, sent sendLagMs late.
func timedRow(tr TraceRow, sendLagMs, firstMs, lastMs float64) RawRow {
	r := conformingRow(tr)
	r.ScheduledOffsetMs = tr.OffsetMs
	ms := float64(time.Millisecond)
	at := func(v float64) *int64 { n := tr.OffsetMs*int64(time.Millisecond) + int64(v*ms); return &n }
	r.Clock = &RequestClock{
		IntendedNanos: at(0), SendNanos: at(sendLagMs), TransportWriteNanos: at(sendLagMs),
		FirstContentNanos: at(firstMs), LastContentNanos: at(lastMs), TerminalNanos: at(lastMs + 1),
	}
	return r
}

// TestOutcomesAreMeasuredFromIntendedArrival: a request the client sent late is that much slower, and the window alone is P.
func TestOutcomesAreMeasuredFromIntendedArrival(t *testing.T) {
	d := versionAsyncDesign()
	p := *versionStudySampling()
	warm := TraceRow{Index: 0, OffsetMs: 1000, PromptLenChars: 1174, MaxOutputTokens: 64, MinOutputTokens: 64, ExactInputTokens: 256}
	tr := evalTraceRow(1, 0)
	rows := []RawRow{timedRow(warm, 0, 10, 20), timedRow(tr, 300, 400, 2000)}
	out, err := d.CellOutcomes(p, 180, []TraceRow{warm, tr}, rows)
	if err != nil {
		t.Fatal(err)
	}
	if len(out) != 1 || out[0].Index != 1 {
		t.Fatalf("population %+v, want only the window row", out)
	}
	ms := float64(time.Millisecond)
	if out[0].TTFTNanos != 400*ms || out[0].E2ENanos != 2000*ms {
		t.Fatalf("ttft %v e2e %v, want 400 ms and 2000 ms from intended arrival", out[0].TTFTNanos/ms, out[0].E2ENanos/ms)
	}
	// TPOT (2000-400)/63 is about 25 ms and TTFT 400 ms: within the SLO.
	if !out[0].Good {
		t.Fatal("a request within the SLO was not counted good")
	}
}

// TestFailuresAreInfiniteAndNeverGood: E2E counts every failure as +Inf, TTFT only a request that never saw content.
func TestFailuresAreInfiniteAndNeverGood(t *testing.T) {
	d := versionAsyncDesign()
	p := *versionStudySampling()
	timeoutTr, unavailTr := evalTraceRow(0, 0), evalTraceRow(1, 10)
	timeout := timedRow(timeoutTr, 0, 300, 900)
	timeout.Disposition, timeout.ErrorKind, timeout.HTTPStatus = "timeout", "timeout", 200
	unavail := UnavailableRows([]TraceRow{unavailTr}, ReplayOptions{}, time.Unix(0, 0))[0]
	out, err := d.CellOutcomes(p, 180, []TraceRow{timeoutTr, unavailTr}, []RawRow{timeout, unavail})
	if err != nil {
		t.Fatal(err)
	}
	ms := float64(time.Millisecond)
	if out[0].TTFTNanos != 300*ms || !math.IsInf(out[0].E2ENanos, 1) || out[0].Good {
		t.Fatalf("timeout after first content: %+v", out[0])
	}
	if !math.IsInf(out[1].TTFTNanos, 1) || !math.IsInf(out[1].E2ENanos, 1) || out[1].Good || out[1].Disposition != DispositionEngineUnavailable {
		t.Fatalf("engine unavailable: %+v", out[1])
	}
}

// TestGoodRequiresTheSLO: TTFT over 1,000 ms or TPOT over 60 ms is a success that is not good.
func TestGoodRequiresTheSLO(t *testing.T) {
	d := versionAsyncDesign()
	p := *versionStudySampling()
	for name, c := range map[string]struct {
		first, last float64
		good        bool
	}{
		"inside":        {900, 900 + 63*50, true},
		"ttft over":     {1001, 1001 + 63*10, false},
		"tpot over":     {100, 100 + 63*61, false},
		"tpot at bound": {100, 100 + 63*60, true},
		"ttft at bound": {1000, 1000 + 63*10, true},
	} {
		t.Run(name, func(t *testing.T) {
			tr := evalTraceRow(0, 0)
			out, err := d.CellOutcomes(p, 180, []TraceRow{tr}, []RawRow{timedRow(tr, 0, c.first, c.last)})
			if err != nil {
				t.Fatal(err)
			}
			if out[0].Good != c.good {
				t.Fatalf("good %v, want %v", out[0].Good, c.good)
			}
		})
	}
}

// TestCellOutcomesRefuseEvidenceAValidCellCannotHold: each of these is a recorder or protocol fault, not a slow request.
func TestCellOutcomesRefuseEvidenceAValidCellCannotHold(t *testing.T) {
	d := versionAsyncDesign()
	p := *versionStudySampling()
	tr := evalTraceRow(0, 0)
	for name, mutate := range map[string]func(*RawRow){
		"no intended arrival":       func(r *RawRow) { r.Clock.IntendedNanos = nil },
		"success without last byte": func(r *RawRow) { r.Clock.LastContentNanos = nil },
		"content before intended":   func(r *RawRow) { n := int64(-1); r.Clock.FirstContentNanos = &n },
		"nonconforming prompt":      func(r *RawRow) { r.EngineInputTokens = 255 },
		"cancelled by the session":  func(r *RawRow) { r.ErrorKind = errKindCancelled },
	} {
		t.Run(name, func(t *testing.T) {
			r := timedRow(tr, 0, 100, 1000)
			mutate(&r)
			if _, err := d.CellOutcomes(p, 180, []TraceRow{tr}, []RawRow{timedRow(tr, 0, 100, 1000)}); err != nil {
				t.Fatalf("the unmutated row is refused, so this case proves nothing: %v", err)
			}
			if out, err := d.CellOutcomes(p, 180, []TraceRow{tr}, []RawRow{r}); err == nil {
				t.Fatalf("outcomes %+v from a row a valid cell cannot hold", out)
			}
		})
	}
	if _, err := d.CellOutcomes(p, 180, []TraceRow{tr}, nil); err == nil {
		t.Fatal("a recording missing its row was evaluated")
	}
}

// TestCellOutcomesClassifyTheWarmupToo: a warm-up row the study cannot classify invalidates the cell, as CellValidity says.
//
// Only P is measured, but the evidence is the whole cell, so filtering to the window first let a warm-up protocol fault through.
func TestCellOutcomesClassifyTheWarmupToo(t *testing.T) {
	d := versionAsyncDesign()
	p := *versionStudySampling()
	warm := TraceRow{Index: 0, OffsetMs: 1000, PromptLenChars: 1174, MaxOutputTokens: 64, MinOutputTokens: 64, ExactInputTokens: 256}
	trace := []TraceRow{warm, evalTraceRow(1, 0)}
	for name, mutate := range map[string]func(*RawRow){
		"a sent warm-up row labelled unavailable": func(r *RawRow) { r.Disposition, r.ErrorKind = errKindEngineUnavailable, errKindEngineUnavailable },
		"a nonconforming warm-up row":             func(r *RawRow) { r.EngineInputTokens = 255 },
	} {
		t.Run(name, func(t *testing.T) {
			bad := timedRow(warm, 0, 10, 20)
			mutate(&bad)
			rows := []RawRow{bad, timedRow(trace[1], 0, 100, 1000)}
			if reason, _ := d.CellValidity(p, 180, trace, rows); !strings.Contains(reason, "protocol fault") {
				t.Fatalf("cell validity %q, want a protocol fault, so the evaluator is the only thing under test", reason)
			}
			if out, err := d.CellOutcomes(p, 180, trace, rows); err == nil {
				t.Fatalf("outcomes %+v from a cell whose warm-up has a protocol fault", out)
			}
		})
	}
}

// TestPooledP99IsTheP99OfTheDrawnMultiset: the weighted rank equals building the resampled population and taking its nearest-rank p99.
func TestPooledP99IsTheP99OfTheDrawnMultiset(t *testing.T) {
	rng := rand.New(rand.NewSource(7))
	for trial := range 200 {
		blocks := 2 + rng.Intn(5)
		cells := make([][]RequestOutcome, blocks)
		for b := range cells {
			for range 1 + rng.Intn(150) {
				v := float64(rng.Intn(5000))
				if rng.Intn(40) == 0 {
					v = math.Inf(1)
				}
				cells[b] = append(cells[b], RequestOutcome{E2ENanos: v, TTFTNanos: v / 2})
			}
		}
		counts := make([]int, blocks)
		for range blocks {
			counts[rng.Intn(blocks)]++
		}
		var naive []float64
		for b, c := range counts {
			for range c {
				for _, o := range cells[b] {
					naive = append(naive, o.E2ENanos)
				}
			}
		}
		slices.Sort(naive)
		got := poolArm(cells).p99(poolArm(cells).e2e, counts)
		if want := percentile(naive, 0.99); got != want && !(math.IsInf(got, 1) && math.IsInf(want, 1)) {
			t.Fatalf("trial %d counts %v: pooled p99 %v, the multiset's %v", trial, counts, got, want)
		}
	}
}

// evalCells is six blocks of n requests each, with every latency scaled by scale and the given number of failures per block.
func evalCells(n int, scale float64, failures int) [][]RequestOutcome {
	cells := make([][]RequestOutcome, 6)
	for b := range cells {
		for i := range n {
			v := float64(1000+i*10+b) * scale
			o := RequestOutcome{Index: i, Disposition: DispositionSuccess, TTFTNanos: v / 4, E2ENanos: v, Good: true}
			if i < failures {
				o = RequestOutcome{Index: i, Disposition: DispositionTimeout, TTFTNanos: math.Inf(1), E2ENanos: math.Inf(1)}
			}
			cells[b] = append(cells[b], o)
		}
	}
	return cells
}

// TestTheEvaluatorReachesTheRegisteredOutcomes: the same data is equivalent, a uniformly faster candidate benefits, a failing one is harm.
func TestTheEvaluatorReachesTheRegisteredOutcomes(t *testing.T) {
	d := versionAsyncDesign()
	ref := evalCells(400, 1, 0)
	for name, c := range map[string]struct {
		cand [][]RequestOutcome
		want LoadOutcome
	}{
		"identical":          {evalCells(400, 1, 0), OutcomeEquivalent},
		"a fifth faster":     {evalCells(400, 0.8, 0), OutcomeBenefit},
		"a fifth slower":     {evalCells(400, 1.2, 0), OutcomeHarm},
		"over the guardrail": {evalCells(400, 1, 3), OutcomeHarm},
	} {
		t.Run(name, func(t *testing.T) {
			ev, err := d.LoadEvidenceFor(LoadL060, 180, ref, c.cand)
			if err != nil {
				t.Fatal(err)
			}
			if a := d.Decision.AssessLoad(ev); a.Outcome != c.want {
				t.Fatalf("outcome %s (%v), want %s; evidence %+v", a.Outcome, a.Reasons, c.want, ev)
			}
		})
	}
}

// TestAnInfiniteReferenceTailIsNotEvaluable: a reference whose p99 is a failure leaves the latency effect undefined, never a win.
func TestAnInfiniteReferenceTailIsNotEvaluable(t *testing.T) {
	d := versionAsyncDesign()
	ev, err := d.LoadEvidenceFor(LoadL060, 180, evalCells(100, 1, 2), evalCells(100, 1, 0))
	if err != nil {
		t.Fatal(err)
	}
	if iv := ev.Endpoints[EndpointE2EP99]; iv.Evaluable {
		t.Fatalf("e2e interval %+v from a reference whose p99 is +Inf", iv)
	}
	if a := d.Decision.AssessLoad(ev); a.Outcome == OutcomeBenefit {
		t.Fatal("a candidate won against a reference that failed its tail")
	}
}

// TestEvaluateSelectsByTheRegisteredOrder: C is selected when C vs A adopts; every arm needs a cell in every analysed block.
func TestEvaluateSelectsByTheRegisteredOrder(t *testing.T) {
	d := versionAsyncDesign()
	blocks := []int{1, 2, 3, 4, 5, 7}
	byBlock := func(cells [][]RequestOutcome) map[int][]RequestOutcome {
		m := map[int][]RequestOutcome{}
		for i, b := range blocks {
			m[b] = cells[i]
		}
		return m
	}
	cells := CampaignCells{}
	for _, tr := range []string{TreatmentA, TreatmentB, TreatmentC} {
		cells[tr] = map[string]map[int][]RequestOutcome{}
	}
	for _, l := range versionStudyLoads {
		cells[TreatmentA][l.Name] = byBlock(evalCells(400, 1, 0))
		cells[TreatmentB][l.Name] = byBlock(evalCells(400, 1, 0))
		cells[TreatmentC][l.Name] = byBlock(evalCells(400, 0.8, 0))
	}
	res, sel, err := d.Evaluate(180, blocks, cells)
	if err != nil {
		t.Fatal(err)
	}
	if sel != TreatmentC || res["primary"].Verdict != VerdictAdopt || res["fallback"].Verdict != VerdictEquivalent {
		t.Fatalf("selection %s, primary %s, fallback %s", sel, res["primary"].Verdict, res["fallback"].Verdict)
	}
	if _, _, err := d.Evaluate(180, blocks[:5], cells); err == nil {
		t.Fatal("a verdict was computed over fewer blocks than registered")
	}
	delete(cells[TreatmentB][LoadL090], 7)
	if _, _, err := d.Evaluate(180, blocks, cells); err == nil || !strings.Contains(err.Error(), "block 7") {
		t.Fatalf("an arm missing a block was evaluated: %v", err)
	}
}

// TestArmsArePairedByBlockNumber: a block-wide slowdown in one block lines up for both arms whatever order the cells were built in.
func TestArmsArePairedByBlockNumber(t *testing.T) {
	d := versionAsyncDesign()
	blocks := []int{1, 2, 3, 4, 5, 6}
	cells := CampaignCells{}
	for _, tr := range []string{TreatmentA, TreatmentB, TreatmentC} {
		cells[tr] = map[string]map[int][]RequestOutcome{}
		for _, l := range versionStudyLoads {
			cells[tr][l.Name] = map[int][]RequestOutcome{}
			f := 1.0
			if tr == TreatmentC {
				f = 0.8
			}
			for _, b := range blocks {
				cell := evalCells(200, f*float64(b), 0)[0]
				cells[tr][l.Name][b] = cell
			}
		}
	}
	res, _, err := d.Evaluate(180, blocks, cells)
	if err != nil {
		t.Fatal(err)
	}
	if a := res["primary"].Assessments[LoadL060]; a.Outcome != OutcomeBenefit {
		t.Fatalf("paired by block, C is a fifth faster in every block: %s %v", a.Outcome, a.Reasons)
	}
}

// TestBothArmsAreDrawnByTheSameBlocks: a block is the unit both arms ran in, so a block-wide slowdown cancels in every resample.
func TestBothArmsAreDrawnByTheSameBlocks(t *testing.T) {
	d := versionAsyncDesign()
	scaled := func(f float64) [][]RequestOutcome {
		cells := evalCells(200, f, 0)
		for b := range cells {
			for i := range cells[b] {
				// Block b runs 1+b times slower for both arms, as a hot or contended block would.
				cells[b][i].E2ENanos *= float64(1 + b)
				cells[b][i].TTFTNanos *= float64(1 + b)
			}
		}
		return cells
	}
	ev, err := d.LoadEvidenceFor(LoadL060, 180, scaled(1), scaled(0.8))
	if err != nil {
		t.Fatal(err)
	}
	iv := ev.Endpoints[EndpointE2EP99]
	want := math.Log(1 / 0.8)
	if !iv.Evaluable || math.Abs(iv.Lo-want) > 1e-9 || math.Abs(iv.Hi-want) > 1e-9 {
		t.Fatalf("e2e interval %+v, want every resample at ln(1/0.8) = %v", iv, want)
	}
}
