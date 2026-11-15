package bench

import (
	"errors"
	"fmt"
	"math"
	"sort"
	"time"
)

// The offline evaluator: the registered endpoints rebuilt from raw rows, then the exact block bootstrap and the verdict.
//
// Nothing here reads the existing TTFTNanos or E2ENanos fields: those are measured from the send and E2E ends at the
// stream's end, while the registration measures from each request's intended arrival and ends E2E at the last content
// byte (docs/superpowers/specs/2026-11-15-vllm-version-async-study-design.md, Endpoints).

// RequestOutcome is one measured request's contribution to the endpoints.
type RequestOutcome struct {
	Index       int
	Disposition RowDisposition
	// TTFTNanos is first content byte minus intended arrival, +Inf when no content byte arrived.
	TTFTNanos float64
	// E2ENanos is last content byte minus intended arrival, +Inf for any failure.
	E2ENanos float64
	// Good is a success within the SLO, which goodput counts.
	Good bool
}

// CellOutcomes are the outcomes of one cell's population P: its rows whose intended arrival is inside the window.
//
// It refuses a cell rather than guess: a recording that does not reconcile with its trace, a row the study cannot
// classify, or a measured row without an intended arrival on its clock. Each of those is an invalidation rule the
// session should already have applied, so reaching here means the evidence is not what a valid cell holds.
func (d VersionStudyDesign) CellOutcomes(p SamplingPolicy, windowSeconds int, trace []TraceRow, rows []RawRow) ([]RequestOutcome, error) {
	if err := ReconcileRecording(trace, rows); err != nil {
		return nil, err
	}
	byIndex := make(map[int]TraceRow, len(trace))
	for _, tr := range trace {
		byIndex[tr.Index] = tr
	}
	var out []RequestOutcome
	for _, r := range rows {
		tr := byIndex[r.Index]
		if d.PhaseOf(tr.OffsetMs, windowSeconds) != PhaseMeasure {
			continue
		}
		o, err := d.requestOutcome(p, r, tr)
		if err != nil {
			return nil, fmt.Errorf("row %d: %w", r.Index, err)
		}
		out = append(out, o)
	}
	if len(out) == 0 {
		return nil, errors.New("the cell has no row in its measurement window")
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Index < out[j].Index })
	return out, nil
}

func (d VersionStudyDesign) requestOutcome(p SamplingPolicy, r RawRow, tr TraceRow) (RequestOutcome, error) {
	disp, err := StudyDisposition(p, r, tr)
	if err != nil {
		return RequestOutcome{}, err
	}
	c := r.Clock
	if c == nil || c.IntendedNanos == nil {
		return RequestOutcome{}, errors.New("no intended arrival on the row's clock, so no latency can be measured from it")
	}
	o := RequestOutcome{Index: r.Index, Disposition: disp, TTFTNanos: math.Inf(1), E2ENanos: math.Inf(1)}
	if c.FirstContentNanos != nil {
		ttft, ok := c.FromIntended(c.FirstContentNanos)
		if !ok {
			return RequestOutcome{}, errors.New("first content precedes the intended arrival")
		}
		o.TTFTNanos = float64(ttft)
	}
	if disp != DispositionSuccess {
		return o, nil
	}
	// A success is a completed, conforming stream, so a missing last content byte is a recorder fault and not a slow request.
	if c.FirstContentNanos == nil || c.LastContentNanos == nil {
		return RequestOutcome{}, errors.New("a successful row has no first or last content time")
	}
	e2e, ok := c.FromIntended(c.LastContentNanos)
	if !ok {
		return RequestOutcome{}, errors.New("last content precedes the intended arrival")
	}
	o.E2ENanos = float64(e2e)
	// TPOT needs a second token: with one, the request has no client-observed TPOT and is not counted good (attack item 12).
	if r.EngineOutputTokens >= 2 {
		span, ok := clockSpan(c.FirstContentNanos, c.LastContentNanos)
		if !ok {
			return RequestOutcome{}, errors.New("last content precedes first content")
		}
		ms := float64(time.Millisecond)
		tpotMs := float64(span) / float64(r.EngineOutputTokens-1) / ms
		o.Good = GoodRequest(d.SLO, disp, o.TTFTNanos/ms, tpotMs, r.OutputTokens)
	}
	return o, nil
}

// pooledArm is one arm's outcomes over the analysed blocks, held so a resample's pooled quantile needs no re-sort.
type pooledArm struct {
	blocks int
	// offered and good count each block's population and its good requests.
	offered, good []int
	failed        []int
	// ttft and e2e are every request's value with its block, sorted by value once.
	ttft, e2e []blockValue
}

type blockValue struct {
	v     float64
	block int
}

func poolArm(cells [][]RequestOutcome) pooledArm {
	a := pooledArm{blocks: len(cells), offered: make([]int, len(cells)), good: make([]int, len(cells)), failed: make([]int, len(cells))}
	for b, rows := range cells {
		a.offered[b] = len(rows)
		for _, o := range rows {
			if o.Good {
				a.good[b]++
			}
			if o.Disposition.IsFailure() {
				a.failed[b]++
			}
			a.ttft = append(a.ttft, blockValue{o.TTFTNanos, b})
			a.e2e = append(a.e2e, blockValue{o.E2ENanos, b})
		}
	}
	for _, s := range [][]blockValue{a.ttft, a.e2e} {
		sort.SliceStable(s, func(i, j int) bool { return s[i].v < s[j].v })
	}
	return a
}

// p99 is the nearest-rank p99 of the population that draws block b counts[b] times.
//
// Each request carries its block's count as its weight, so the pooled rank is found without building the multiset.
func (a pooledArm) p99(values []blockValue, counts []int) float64 {
	n := 0
	for b, c := range counts {
		n += c * a.offered[b]
	}
	if n == 0 {
		return math.NaN()
	}
	rank := int(math.Ceil(0.99 * float64(n)))
	cum := 0
	for _, x := range values {
		cum += counts[x.block]
		if cum >= rank {
			return x.v
		}
	}
	return values[len(values)-1].v
}

// goodput is good requests per second of window over the drawn blocks.
func (a pooledArm) goodput(counts []int, windowSeconds int) float64 {
	good, drawn := 0, 0
	for b, c := range counts {
		good += c * a.good[b]
		drawn += c
	}
	if drawn == 0 {
		return math.NaN()
	}
	return float64(good) / (float64(windowSeconds) * float64(drawn))
}

func (a pooledArm) value(e Endpoint, counts []int, windowSeconds int) float64 {
	switch e {
	case EndpointTTFTP99:
		return a.p99(a.ttft, counts)
	case EndpointE2EP99:
		return a.p99(a.e2e, counts)
	case EndpointGoodput:
		return a.goodput(counts, windowSeconds)
	}
	return math.NaN()
}

func (a pooledArm) failureFraction() float64 {
	failed, offered := 0, 0
	for b := range a.offered {
		failed += a.failed[b]
		offered += a.offered[b]
	}
	if offered == 0 {
		return math.NaN()
	}
	return float64(failed) / float64(offered)
}

// LoadEvidenceFor builds one comparison's evidence at one load, from the cells of the analysed blocks in the same order.
//
// The two arms are resampled by the same block counts: a block is the experimental unit both arms ran in, so drawing
// it draws both, and the effect is recomputed from the pooled populations under every multiset.
func (d VersionStudyDesign) LoadEvidenceFor(load string, windowSeconds int, reference, candidate [][]RequestOutcome) (LoadEvidence, error) {
	if len(reference) == 0 || len(reference) != len(candidate) {
		return LoadEvidence{}, fmt.Errorf("%d reference and %d candidate blocks; both arms need every analysed block", len(reference), len(candidate))
	}
	for b := range reference {
		if len(reference[b]) == 0 || len(candidate[b]) == 0 {
			return LoadEvidence{}, fmt.Errorf("analysed block %d has an empty cell", b)
		}
	}
	ref, cand := poolArm(reference), poolArm(candidate)
	ev := LoadEvidence{
		Load:                     load,
		Endpoints:                map[Endpoint]Interval{},
		CandidateFailureFraction: cand.failureFraction(),
		ReferenceFailureFraction: ref.failureFraction(),
	}
	for _, e := range d.Decision.Voting {
		ev.Endpoints[e] = ExactBlockBootstrap(len(reference), d.Decision.IntervalLevel, func(counts []int) (float64, bool) {
			return OrientedEffect(e, ref.value(e, counts, windowSeconds), cand.value(e, counts, windowSeconds))
		})
	}
	return ev, nil
}

// ComparisonResult is one comparison's assessment at both loads and its verdict.
type ComparisonResult struct {
	Comparison  Comparison
	Assessments map[string]LoadAssessment
	Verdict     Verdict
}

// CampaignCells are the analysed blocks' cell outcomes, by treatment and load, each in the analysed blocks' order.
type CampaignCells map[string]map[string][][]RequestOutcome

// Evaluate applies the registered decision to every comparison and selects the engine.
func (d VersionStudyDesign) Evaluate(windowSeconds int, cells CampaignCells) (map[string]ComparisonResult, string, error) {
	results := map[string]ComparisonResult{}
	for name, cmp := range map[string]Comparison{"primary": d.Primary, "fallback": d.Fallback, "explanatory": d.Explanatory} {
		res := ComparisonResult{Comparison: cmp, Assessments: map[string]LoadAssessment{}}
		var outcomes []LoadOutcome
		for _, l := range versionStudyLoads {
			ev, err := d.LoadEvidenceFor(l.Name, windowSeconds, cells[cmp.Reference][l.Name], cells[cmp.Candidate][l.Name])
			if err != nil {
				return nil, "", fmt.Errorf("%s comparison %s vs %s at %s: %w", name, cmp.Candidate, cmp.Reference, l.Name, err)
			}
			a := d.Decision.AssessLoad(ev)
			res.Assessments[l.Name] = a
			outcomes = append(outcomes, a.Outcome)
		}
		res.Verdict = CombineLoads(outcomes[0], outcomes[1])
		results[name] = res
	}
	return results, SelectTreatment(results["primary"].Verdict, results["fallback"].Verdict), nil
}
