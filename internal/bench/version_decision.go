package bench

import (
	"fmt"
	"math"
	"slices"
	"sort"
)

// The version study's pilot decision heuristic, registered in docs/superpowers/specs/2026-11-15-vllm-version-async-study-design.md.
//
// The bounds below come from a percentile bootstrap over six blocks.
// They are a registered decision device for a fixed-work pilot on one host, not calibrated tests: nothing here claims a
// coverage, a type I error rate or a TOST.

// DecisionRule is the owner's 2026-11-15 rule: a worthwhile benefit on a designated endpoint, tolerated losses
// elsewhere, and an absolute reliability guardrail that no ratio can buy back.
type DecisionRule struct {
	// Voting are the endpoints whose intervals decide; success-only TPOT is not one of them (attack item 4).
	Voting []Endpoint
	// BenefitEndpoints are the endpoints on which an adoption's benefit must be established.
	BenefitEndpoints []Endpoint
	// MinWorthwhileBenefit is the relative improvement the interval's lower bound must exceed: 0.10 is a tenth less latency or a tenth more goodput.
	MinWorthwhileBenefit float64
	// ToleratedLoss is the relative worsening each voting endpoint may show without counting as harm.
	ToleratedLoss map[Endpoint]float64
	// MaxFailureFraction bounds the candidate's failures as a fraction of its offered requests, pooled over the analysed blocks.
	MaxFailureFraction float64
	// IntervalLevel is the central mass the bootstrap interval spans.
	IntervalLevel float64
}

// isLatency says whether an endpoint improves downward.
func isLatency(e Endpoint) bool {
	return e == EndpointTTFTP99 || e == EndpointE2EP99
}

// OrientedEffect is the log effect of candidate over reference, positive when the candidate is better, or false when undefined.
//
// Every zero and infinity case is registered here rather than left to arithmetic (attack item 12):
//   - latency: a reference that is not finite and positive leaves the effect undefined; a candidate tail of +Inf is -Inf, a valid "worse";
//     a zero latency is a measurement fault and undefined;
//   - goodput: a reference of zero or less is undefined; a candidate of zero is -Inf;
//   - TPOT and cost do not vote and are always undefined here.
func OrientedEffect(e Endpoint, ref, cand float64) (float64, bool) {
	if math.IsNaN(ref) || math.IsNaN(cand) {
		return 0, false
	}
	switch {
	case isLatency(e):
		if math.IsInf(ref, 0) || ref <= 0 || cand <= 0 {
			return 0, false
		}
		if math.IsInf(cand, 1) {
			return math.Inf(-1), true
		}
		return math.Log(ref / cand), true
	case e == EndpointGoodput:
		if math.IsInf(ref, 0) || ref <= 0 || cand < 0 || math.IsInf(cand, 0) {
			return 0, false
		}
		if cand == 0 {
			return math.Inf(-1), true
		}
		return math.Log(cand / ref), true
	default:
		return 0, false
	}
}

// benefitThreshold is the oriented effect a worthwhile benefit must exceed on e.
func (r DecisionRule) benefitThreshold(e Endpoint) float64 {
	if isLatency(e) {
		return -math.Log(1 - r.MinWorthwhileBenefit)
	}
	return math.Log(1 + r.MinWorthwhileBenefit)
}

// lossThreshold is the oriented effect below which a loss on e exceeds what is tolerated.
func (r DecisionRule) lossThreshold(e Endpoint) float64 {
	m := r.ToleratedLoss[e]
	if isLatency(e) {
		return -math.Log(1 + m)
	}
	return math.Log(1 - m)
}

// Interval is a bootstrap interval of an oriented effect.
type Interval struct {
	Lo, Hi    float64
	Evaluable bool
	// Resamples is how many distinct multisets were enumerated and Undefined how many gave no effect.
	Resamples int
	Undefined int
	Reason    string
}

// maxEnumeratedBlocks bounds the exact enumeration; eight blocks are 6,435 multisets.
const maxEnumeratedBlocks = 8

// enumerateBlockResamples calls visit for every multiset of n blocks drawn n times with replacement, with its multinomial weight n!/∏c_i!.
//
// The weights sum to n^n, the number of ordered draws, so the enumeration is the bootstrap distribution itself and not a sample of it.
func enumerateBlockResamples(n int, visit func(counts []int, weight int64)) error {
	if n < 1 || n > maxEnumeratedBlocks {
		return fmt.Errorf("exact block resampling supports 1 to %d blocks, got %d", maxEnumeratedBlocks, n)
	}
	fact := make([]int64, n+1)
	fact[0] = 1
	for i := 1; i <= n; i++ {
		fact[i] = fact[i-1] * int64(i)
	}
	counts := make([]int, n)
	var rec func(i, left int)
	rec = func(i, left int) {
		if i == n-1 {
			counts[i] = left
			w := fact[n]
			for _, c := range counts {
				w /= fact[c]
			}
			visit(slices.Clone(counts), w)
			return
		}
		for c := left; c >= 0; c-- {
			counts[i] = c
			rec(i+1, left-c)
		}
	}
	rec(0, n)
	return nil
}

// ExactBlockBootstrap is the percentile interval of effect over the exact block-resampling distribution of n blocks.
//
// effect receives how many times each block is drawn and returns the oriented effect, or false where it is undefined.
// If any multiset with positive weight is undefined, the interval is not evaluable: deciding by enumeration removes the chance
// that random draws happen to miss the one resample that would have made the endpoint unevaluable (attack item 12).
// The quantiles are weighted: the lower bound is the smallest value whose cumulative weight reaches (1 - level)/2 of n^n.
func ExactBlockBootstrap(n int, level float64, effect func(counts []int) (float64, bool)) Interval {
	if !(level > 0 && level < 1) {
		return Interval{Reason: fmt.Sprintf("interval level %v is not in (0, 1)", level)}
	}
	type point struct {
		v float64
		w int64
	}
	var pts []point
	var total int64
	iv := Interval{}
	err := enumerateBlockResamples(n, func(counts []int, w int64) {
		iv.Resamples++
		total += w
		v, ok := effect(counts)
		if !ok || math.IsNaN(v) {
			iv.Undefined++
			return
		}
		pts = append(pts, point{v, w})
	})
	if err != nil {
		iv.Reason = err.Error()
		return iv
	}
	if iv.Undefined > 0 {
		iv.Reason = fmt.Sprintf("%d of %d resamples have no defined effect", iv.Undefined, iv.Resamples)
		return iv
	}
	sort.SliceStable(pts, func(i, j int) bool { return pts[i].v < pts[j].v })
	quantile := func(q float64) float64 {
		target := q * float64(total)
		var cum int64
		for _, p := range pts {
			cum += p.w
			// A relative slack, so a target that equals a cumulative weight in exact arithmetic is not missed by rounding.
			if float64(cum) >= target-1e-9*float64(total) {
				return p.v
			}
		}
		return pts[len(pts)-1].v
	}
	tail := (1 - level) / 2
	iv.Lo, iv.Hi = quantile(tail), quantile(1-tail)
	iv.Evaluable = true
	return iv
}

// LoadOutcome is one comparison's result at one load.
type LoadOutcome string

const (
	// OutcomeHarm is established material harm on a voting endpoint, or a candidate over the reliability guardrail.
	OutcomeHarm LoadOutcome = "harm"
	// OutcomeBenefit is a worthwhile benefit established on a designated endpoint with every voting endpoint within its tolerated loss.
	OutcomeBenefit LoadOutcome = "benefit"
	// OutcomeEquivalent is every voting endpoint's interval inside the band between tolerated loss and worthwhile benefit.
	OutcomeEquivalent LoadOutcome = "equivalent"
	// OutcomeSafe is no endpoint beyond its tolerated loss, with neither a benefit nor equivalence established.
	OutcomeSafe LoadOutcome = "safe"
	// OutcomeUncertain is everything else, including an endpoint that could not be evaluated.
	OutcomeUncertain LoadOutcome = "uncertain"
)

// LoadEvidence is what one comparison measured at one load.
type LoadEvidence struct {
	Load string
	// Endpoints holds the oriented-effect interval of each endpoint; a voting endpoint that is absent is not evaluable.
	Endpoints map[Endpoint]Interval
	// CandidateFailureFraction and ReferenceFailureFraction are failures over offered requests, pooled over the analysed blocks.
	CandidateFailureFraction float64
	ReferenceFailureFraction float64
}

// LoadAssessment is an outcome with the reasons that produced it, so a report can print why.
type LoadAssessment struct {
	Outcome LoadOutcome
	Reasons []string
}

// AssessLoad applies the registered rule to one load.
func (r DecisionRule) AssessLoad(ev LoadEvidence) LoadAssessment {
	var reasons []string
	// The guardrail is absolute and read first: a ratio that improves cannot excuse failures the candidate added.
	cf := ev.CandidateFailureFraction
	if math.IsNaN(cf) || cf < 0 || cf > r.MaxFailureFraction {
		return LoadAssessment{OutcomeHarm, []string{fmt.Sprintf("candidate failure fraction %v exceeds the guardrail %v", cf, r.MaxFailureFraction)}}
	}
	harm, unevaluable := false, false
	safe, equivalent, benefit := true, true, false
	for _, e := range r.Voting {
		iv, ok := ev.Endpoints[e]
		if !ok || !iv.Evaluable {
			unevaluable = true
			reasons = append(reasons, fmt.Sprintf("%s is not evaluable: %s", e, iv.Reason))
			continue
		}
		loss, gain := r.lossThreshold(e), r.benefitThreshold(e)
		if iv.Hi < loss {
			harm = true
			reasons = append(reasons, fmt.Sprintf("%s: harm beyond the tolerated loss is established", e))
		}
		if iv.Lo < loss {
			safe = false
		}
		if iv.Lo < loss || iv.Hi > gain {
			equivalent = false
		}
		if slices.Contains(r.BenefitEndpoints, e) && iv.Lo > gain {
			benefit = true
		}
	}
	switch {
	case harm:
		return LoadAssessment{OutcomeHarm, reasons}
	case unevaluable:
		return LoadAssessment{OutcomeUncertain, reasons}
	}
	rf := ev.ReferenceFailureFraction
	if math.IsNaN(rf) || rf < 0 || rf > r.MaxFailureFraction {
		// A reference outside the guardrail is not a service worth comparing with.
		return LoadAssessment{OutcomeUncertain, append(reasons, fmt.Sprintf("reference failure fraction %v exceeds the guardrail", rf))}
	}
	switch {
	case safe && benefit:
		return LoadAssessment{OutcomeBenefit, reasons}
	case equivalent:
		return LoadAssessment{OutcomeEquivalent, reasons}
	case safe:
		return LoadAssessment{OutcomeSafe, reasons}
	}
	return LoadAssessment{OutcomeUncertain, reasons}
}

// Verdict is a comparison's pilot decision across both loads.
type Verdict string

const (
	VerdictAdopt      Verdict = "adopt"
	VerdictEquivalent Verdict = "practically-equivalent"
	VerdictUncertain  Verdict = "uncertain"
	VerdictReject     Verdict = "reject"
)

// CombineLoads is the registered cross-load policy.
//
// Reject when either load shows harm; adopt when a worthwhile benefit is established at either load and the other load is
// safe; practically equivalent only when both loads are; everything else is uncertain.
// A deployment serves both regimes, so a gain at one load is worth taking only if the other is not made worse.
func CombineLoads(a, b LoadOutcome) Verdict {
	pair := []LoadOutcome{a, b}
	switch {
	case slices.Contains(pair, OutcomeHarm):
		return VerdictReject
	case slices.Contains(pair, OutcomeUncertain):
		return VerdictUncertain
	case a == OutcomeEquivalent && b == OutcomeEquivalent:
		return VerdictEquivalent
	case slices.Contains(pair, OutcomeBenefit):
		return VerdictAdopt
	}
	return VerdictUncertain
}

// SelectTreatment is the registered choice of engine: C if C vs A adopts, else B if B vs A adopts, else the incumbent A.
//
// C vs B never selects; it explains which change produced a C vs A result.
func SelectTreatment(cVsA, bVsA Verdict) string {
	switch {
	case cVsA == VerdictAdopt:
		return TreatmentC
	case bVsA == VerdictAdopt:
		return TreatmentB
	}
	return TreatmentA
}
