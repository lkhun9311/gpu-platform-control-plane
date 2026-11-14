package bench

import (
	"math"
	"slices"
	"testing"
)

// TestOrientedEffectRegisteredCases pins every zero and infinity case so none is decided by whichever arithmetic happens.
func TestOrientedEffectRegisteredCases(t *testing.T) {
	inf := math.Inf(1)
	for _, c := range []struct {
		name      string
		e         Endpoint
		ref, cand float64
		want      float64
		ok        bool
	}{
		{"latency halved", EndpointE2EP99, 200, 100, math.Log(2), true},
		{"latency doubled", EndpointTTFTP99, 100, 200, -math.Log(2), true},
		{"candidate tail infinite", EndpointE2EP99, 100, inf, math.Inf(-1), true},
		{"reference tail infinite", EndpointE2EP99, inf, 100, 0, false},
		{"both tails infinite", EndpointE2EP99, inf, inf, 0, false},
		{"reference latency zero", EndpointTTFTP99, 0, 100, 0, false},
		{"candidate latency zero", EndpointTTFTP99, 100, 0, 0, false},
		{"NaN", EndpointTTFTP99, math.NaN(), 100, 0, false},
		{"goodput up 10%", EndpointGoodput, 1, 1.1, math.Log(1.1), true},
		{"candidate goodput zero", EndpointGoodput, 1, 0, math.Inf(-1), true},
		{"reference goodput zero", EndpointGoodput, 0, 1, 0, false},
		{"goodput negative", EndpointGoodput, 1, -1, 0, false},
		{"TPOT does not vote", EndpointTPOTP99, 100, 50, 0, false},
		{"cost does not vote", EndpointCostPerSLORequest, 1, 1, 0, false},
	} {
		got, ok := OrientedEffect(c.e, c.ref, c.cand)
		if ok != c.ok || (ok && got != c.want && math.Abs(got-c.want) > 1e-12) {
			t.Errorf("%s: effect %v ok %v, want %v ok %v", c.name, got, ok, c.want, c.ok)
		}
	}
}

// TestExactBlockBootstrapEnumerates checks the multisets, their weights and the weighted quantiles exactly.
func TestExactBlockBootstrapEnumerates(t *testing.T) {
	n := 0
	total := int64(0)
	err := enumerateBlockResamples(6, func(counts []int, weight int64) {
		n++
		total += weight
	})
	if err != nil {
		t.Fatal(err)
	}
	if n != 462 || total != 46656 {
		t.Fatalf("6 blocks: %d multisets with total weight %d, want 462 and 6^6 = 46656", n, total)
	}

	// Two blocks valued 0 and 1, statistic the resampled mean: {0,0} w1 -> 0, {0,1} w2 -> 0.5, {1,1} w1 -> 1.
	values := []float64{0, 1}
	iv := ExactBlockBootstrap(2, 0.90, func(counts []int) (float64, bool) {
		s := 0.0
		for i, c := range counts {
			s += float64(c) * values[i]
		}
		return s / 2, true
	})
	if !iv.Evaluable || iv.Lo != 0 || iv.Hi != 1 || iv.Resamples != 3 {
		t.Fatalf("interval %+v, want [0, 1] over 3 multisets", iv)
	}
	iv = ExactBlockBootstrap(2, 0.40, func(counts []int) (float64, bool) {
		return float64(counts[1]) / 2, true
	})
	// Cumulative weights 1/4, 3/4, 1: the 30th percentile is 0.5 and the 70th is 0.5.
	if iv.Lo != 0.5 || iv.Hi != 0.5 {
		t.Fatalf("40%% interval %+v, want [0.5, 0.5]", iv)
	}
}

// TestExactBlockBootstrapEvaluabilityIsNotLuck is attack item 12: one infinite reference block poisons every resample that draws only it.
//
// With six blocks that resample has weight 1/46,656, so ten thousand random draws miss it 81% of the time; enumeration never does.
func TestExactBlockBootstrapEvaluabilityIsNotLuck(t *testing.T) {
	iv := ExactBlockBootstrap(6, 0.90, func(counts []int) (float64, bool) {
		return 0, counts[0] < 6
	})
	if iv.Evaluable {
		t.Fatalf("an interval with one undefined resample was evaluable: %+v", iv)
	}
	if iv.Undefined != 1 {
		t.Errorf("undefined resamples = %d, want exactly 1", iv.Undefined)
	}
	if iv := ExactBlockBootstrap(0, 0.90, func([]int) (float64, bool) { return 0, true }); iv.Evaluable {
		t.Errorf("zero blocks produced an evaluable interval")
	}
	if iv := ExactBlockBootstrap(9, 0.90, func([]int) (float64, bool) { return 0, true }); iv.Evaluable {
		t.Errorf("more blocks than the enumeration supports produced an evaluable interval")
	}
}

func ivl(lo, hi float64) Interval { return Interval{Lo: lo, Hi: hi, Evaluable: true} }

// evidence builds one load's evidence with every voting endpoint at the same interval.
func evidence(lo, hi, candFail, refFail float64) LoadEvidence {
	return LoadEvidence{
		Endpoints: map[Endpoint]Interval{
			EndpointTTFTP99: ivl(lo, hi), EndpointE2EP99: ivl(lo, hi), EndpointGoodput: ivl(lo, hi),
		},
		CandidateFailureFraction: candFail,
		ReferenceFailureFraction: refFail,
	}
}

// TestAssessLoad covers each outcome of one load, with the attack's counterexamples.
func TestAssessLoad(t *testing.T) {
	r := versionAsyncDesign().Decision
	benefit := math.Log(1 / 0.9) // a 10% latency reduction
	loss := -math.Log(1.1)       // a 10% latency increase
	for _, c := range []struct {
		name string
		ev   LoadEvidence
		want LoadOutcome
	}{
		{"established worthwhile benefit, no harm", evidence(benefit+0.01, 0.5, 0, 0), OutcomeBenefit},
		// Attack item 7: a benefit not shown to exceed the threshold is not a benefit.
		// The band's upper edge is the smaller of the two orientations' thresholds, ln 1.1 for goodput.
		{"small certain gain", evidence(0.001, 0.09, 0, 0), OutcomeEquivalent},
		{"gain whose bound reaches past the threshold", evidence(0.001, 0.30, 0, 0), OutcomeSafe},
		// Attack item 7: a loss not shown to exceed the tolerance is not harm.
		{"small certain loss", evidence(-0.10, -0.001, 0, 0), OutcomeUncertain},
		{"established material harm", evidence(-0.5, loss-0.01, 0, 0), OutcomeHarm},
		{"wide interval", evidence(-0.5, 0.5, 0, 0), OutcomeUncertain},
		{"candidate breaks the reliability guardrail", evidence(benefit+0.01, 0.5, 0.006, 0), OutcomeHarm},
		{"candidate at the guardrail", evidence(benefit+0.01, 0.5, 0.005, 0), OutcomeBenefit},
		{"reference breaks the guardrail", evidence(benefit+0.01, 0.5, 0, 0.01), OutcomeUncertain},
		{"failure fraction unknown", evidence(benefit+0.01, 0.5, math.NaN(), 0), OutcomeHarm},
	} {
		if got := r.AssessLoad(c.ev).Outcome; got != c.want {
			t.Errorf("%s: %s, want %s", c.name, got, c.want)
		}
	}

	// Benefit counts only on the designated endpoint: a TTFT gain alone does not adopt.
	ev := evidence(0, 0.05, 0, 0)
	ev.Endpoints[EndpointTTFTP99] = ivl(benefit+0.1, 0.9)
	if got := r.AssessLoad(ev).Outcome; got == OutcomeBenefit {
		t.Errorf("a benefit on a non-designated endpoint adopted")
	}
	// An endpoint that cannot be evaluated leaves the load uncertain, unless harm is established elsewhere.
	ev = evidence(benefit+0.01, 0.5, 0, 0)
	ev.Endpoints[EndpointGoodput] = Interval{}
	if got := r.AssessLoad(ev).Outcome; got != OutcomeUncertain {
		t.Errorf("an unevaluable endpoint gave %s, want uncertain", got)
	}
	ev.Endpoints[EndpointTTFTP99] = ivl(-0.9, loss-0.01)
	if got := r.AssessLoad(ev).Outcome; got != OutcomeHarm {
		t.Errorf("established harm beside an unevaluable endpoint gave %s, want harm", got)
	}
	// A missing voting endpoint is not evaluable.
	ev = evidence(benefit+0.01, 0.5, 0, 0)
	delete(ev.Endpoints, EndpointE2EP99)
	if got := r.AssessLoad(ev).Outcome; got != OutcomeUncertain {
		t.Errorf("a missing endpoint gave %s, want uncertain", got)
	}
}

// TestSuccessOnlyTPOTCannotAdopt is attack item 4: failing slow requests must not manufacture an adoption.
//
// The candidate fails 2 of 500 requests that the reference served slowly; success-only TPOT looks much better.
// TPOT is not a voting endpoint, so the decision rests on the failure-inclusive tails and goodput, which did not improve.
func TestSuccessOnlyTPOTCannotAdopt(t *testing.T) {
	r := versionAsyncDesign().Decision
	ev := evidence(-0.01, 0.01, 2.0/500, 0)
	ev.Endpoints[EndpointTPOTP99] = ivl(1.0, 2.0)
	if got := r.AssessLoad(ev).Outcome; got == OutcomeBenefit {
		t.Fatalf("a success-only TPOT gain adopted")
	}
}

// TestCombineLoads is the registered cross-load policy, written out case by case.
func TestCombineLoads(t *testing.T) {
	for _, c := range []struct {
		a, b LoadOutcome
		want Verdict
	}{
		{OutcomeBenefit, OutcomeBenefit, VerdictAdopt},
		{OutcomeBenefit, OutcomeEquivalent, VerdictAdopt},
		{OutcomeBenefit, OutcomeSafe, VerdictAdopt},
		{OutcomeSafe, OutcomeBenefit, VerdictAdopt},
		{OutcomeBenefit, OutcomeUncertain, VerdictUncertain},
		{OutcomeBenefit, OutcomeHarm, VerdictReject},
		{OutcomeHarm, OutcomeEquivalent, VerdictReject},
		{OutcomeEquivalent, OutcomeEquivalent, VerdictEquivalent},
		{OutcomeEquivalent, OutcomeSafe, VerdictUncertain},
		{OutcomeSafe, OutcomeSafe, VerdictUncertain},
		{OutcomeUncertain, OutcomeUncertain, VerdictUncertain},
	} {
		if got := CombineLoads(c.a, c.b); got != c.want {
			t.Errorf("%s + %s = %s, want %s", c.a, c.b, got, c.want)
		}
	}
}

// TestSelectTreatment is the registered choice: C vs A decides, B vs A is the fallback, C vs B never selects.
func TestSelectTreatment(t *testing.T) {
	all := []Verdict{VerdictAdopt, VerdictEquivalent, VerdictUncertain, VerdictReject}
	for _, ca := range all {
		for _, ba := range all {
			got := SelectTreatment(ca, ba)
			want := TreatmentA
			switch {
			case ca == VerdictAdopt:
				want = TreatmentC
			case ba == VerdictAdopt:
				want = TreatmentB
			}
			if got != want {
				t.Errorf("C vs A %s, B vs A %s: selected %s, want %s", ca, ba, got, want)
			}
		}
	}
	d := versionAsyncDesign()
	if d.Primary != (Comparison{TreatmentC, TreatmentA}) || d.Fallback != (Comparison{TreatmentB, TreatmentA}) ||
		d.Explanatory != (Comparison{TreatmentC, TreatmentB}) {
		t.Errorf("comparisons = %+v %+v %+v", d.Primary, d.Fallback, d.Explanatory)
	}
}

// TestDecisionRuleRegistered pins the owner's 2026-11-15 values.
func TestDecisionRuleRegistered(t *testing.T) {
	r := versionAsyncDesign().Decision
	if r.MinWorthwhileBenefit != 0.10 || r.MaxFailureFraction != 0.005 || r.IntervalLevel != 0.90 {
		t.Errorf("rule %+v", r)
	}
	if !slices.Equal(r.BenefitEndpoints, []Endpoint{EndpointE2EP99}) {
		t.Errorf("benefit endpoints %v, want [e2e_p99]", r.BenefitEndpoints)
	}
	for _, e := range []Endpoint{EndpointTTFTP99, EndpointE2EP99, EndpointGoodput} {
		if r.ToleratedLoss[e] != 0.10 {
			t.Errorf("tolerated loss on %s = %v, want 0.10", e, r.ToleratedLoss[e])
		}
	}
	if slices.Contains(r.Voting, EndpointTPOTP99) {
		t.Errorf("success-only TPOT votes")
	}
}
