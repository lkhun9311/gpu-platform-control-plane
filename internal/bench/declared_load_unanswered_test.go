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

// A request the engine never answered is not a request that carried the wrong length.
//
// WHY THIS FILE EXISTS, measured 2026-10-03. The first version of reading 4e had TWO buckets: counted, and
// everything else. Re-scoring the ten-cell archive then came back uncomputable on the strength of ONE row of
// 47,245 -- an HTTP 502 with errorKind "http", no response body and no engineInputTokens key at all. Nothing
// was wrong with that run's load; a single request failed in transport, and a failed request cannot carry a
// prompt-token count.
//
// Folding that in with a genuine accounting hole made a transport failure speak as an instrument failure. So
// there are three buckets now, and this file pins the one the real archives cannot demonstrate: "answered
// but uncounted" is zero rows across all three of them, which is exactly why it needs a written fixture
// rather than an archive.
//
// The separate file, and the separate helper, are deliberate: widening declaredLoadArm to a third map would
// have touched seven call sites that have nothing to say about this distinction.
func declaredLoadArmWithFailures(arm string, reported map[string]map[int]int, answeredUncounted, unanswered map[string]int) ArmSummary {
	if reported == nil {
		reported = map[string]map[int]int{}
	}
	if answeredUncounted == nil {
		answeredUncounted = map[string]int{}
	}
	if unanswered == nil {
		unanswered = map[string]int{}
	}
	return ArmSummary{
		Arm:                                 arm,
		EngineInputTokensByTenant:           reported,
		EngineInputTokensUnreportedByTenant: answeredUncounted,
		EngineInputTokensUnansweredByTenant: unanswered,
	}
}

func TestTheDeclaredLoadGateSeparatesAFailedRequestFromAnAccountingHole(t *testing.T) {
	frozen := &FrozenTuple{PremiumInputTokens: 256, ContenderInputTokens: 8192}
	agreeing := map[string]map[int]int{PremiumTenant: {256: 23275}, NoisyTenant: {8192: 695}}

	for _, tc := range []struct {
		name              string
		answeredUncounted map[string]int
		unanswered        map[string]int
		notEvaluable      bool
		wantDetail        string
	}{
		{
			// The ten-cell archive's actual shape, scaled down: everything agreed and one request failed.
			name:         "one request got no successful response",
			unanswered:   map[string]int{PremiumTenant: 1},
			notEvaluable: false,
			wantDetail:   "No count was obtained for 1 request(s)",
		},
		{
			// Many failures are still not a load disagreement. Whether a run that lost this much traffic is
			// worth reading at all is reading 4's and 4b's question, and they ask it over the same rows.
			//
			// But the BOUND has to move with them: 412 unverified rows beside 23,970 scored ones is a
			// different claim from one unverified row, and a pass that reads identically either way is the
			// overstatement this gate exists to avoid.
			name:         "many requests got no successful response",
			unanswered:   map[string]int{PremiumTenant: 400, NoisyTenant: 12},
			notEvaluable: false,
			wantDetail:   "At most 412 of 24382 scored requests could therefore disagree",
		},
		{
			// THIS one blocks. A 200 went through usage accounting and came back with no count, which is a
			// hole in the instrument rather than a failed request.
			name:              "one request was answered and still not counted",
			answeredUncounted: map[string]int{PremiumTenant: 1},
			notEvaluable:      true,
			wantDetail:        "rows the engine ANSWERED carried no count",
		},
		{
			// Both at once: the accounting hole decides, and the failures are still reported beside it so a
			// reader is not left to infer them.
			name:              "both kinds at once",
			answeredUncounted: map[string]int{PremiumTenant: 2},
			unanswered:        map[string]int{PremiumTenant: 5},
			notEvaluable:      true,
			wantDetail:        "No count was obtained for 5 request(s)",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := EvaluateDeclaredLoad([]ArmSummary{
				declaredLoadArmWithFailures(ArmShared, agreeing, tc.answeredUncounted, tc.unanswered),
			}, frozen, PremiumTenant, NoisyTenant)

			if got.Fired {
				t.Fatalf("a silence fired the gate, which is reserved for a reported length that disagrees: %s",
					got.Detail)
			}
			if got.NotEvaluable != tc.notEvaluable {
				t.Errorf("NotEvaluable = %v, want %v -- detail was %q",
					got.NotEvaluable, tc.notEvaluable, got.Detail)
			}
			if !strings.Contains(got.Detail, tc.wantDetail) {
				t.Errorf("the detail does not say %q, so a reader cannot tell which silence this was:\n%s",
					tc.wantDetail, got.Detail)
			}
		})
	}
}

// A pass whose run lost requests says so, and narrows what it claims.
//
// "Every request carried the declared length" would be false: some requests got no answer, and nothing here
// knows what they carried. The wording has to be "every request the engine ANSWERED", or the gate overstates
// itself in exactly the way its own closing sentence warns against.
func TestAPassingDeclaredLoadGateDoesNotClaimTheRequestsThatFailed(t *testing.T) {
	got := EvaluateDeclaredLoad([]ArmSummary{
		declaredLoadArmWithFailures(ArmShared,
			map[string]map[int]int{PremiumTenant: {256: 100}, NoisyTenant: {8192: 10}},
			nil, map[string]int{PremiumTenant: 3}),
	}, &FrozenTuple{PremiumInputTokens: 256, ContenderInputTokens: 8192}, PremiumTenant, NoisyTenant)

	if got.Fired || got.NotEvaluable {
		t.Fatalf("the gate refused a run whose answered requests all carried the declared load: %s", got.Detail)
	}
	if !strings.Contains(got.Detail, "every request the engine ANSWERED") {
		t.Errorf("the pass claims more than it checked -- it must scope itself to answered requests:\n%s",
			got.Detail)
	}
	if !strings.Contains(got.Detail, "not verified by this evidence") {
		t.Errorf("the pass does not say that the failed requests are outside its claim:\n%s", got.Detail)
	}
	// The bound, not just the count. Three unverified rows out of 113 scored means the evidence permits a
	// mismatch rate up to 3/113, and a reader who is given only "3 requests failed" has to work that out.
	if !strings.Contains(got.Detail, "At most 3 of 113 scored requests could therefore disagree") {
		t.Errorf("the pass does not state the bound the evidence permits:\n%s", got.Detail)
	}
	// And it must NOT describe what the engine did. A 502 is what the client obtained; the request may have
	// reached the engine, been prefilled and measured, and lost its response on the way back.
	for _, overclaim := range []string{"had no opportunity", "the engine never received", "was not prefilled"} {
		if strings.Contains(got.Detail, overclaim) {
			t.Errorf("the detail says %q, which a failed response does not establish:\n%s",
				overclaim, got.Detail)
		}
	}
}

// The mismatch bound belongs ONLY to the outcome where it is true.
//
// Found by an independent review of the diff, not by this test suite: the first version appended the bound
// to every outcome, so 100 agreeing rows, 10 reported mismatches and one unanswered request printed "At most
// 1 of 101 scored requests could therefore disagree" directly beside a FIRED verdict that had already found
// ten of them. U/(agreed+U) is the evidence's maximum only when the unanswered rows are the ONLY unverified
// category, and a number printed next to a refusal is read as a measurement of it.
func TestTheMismatchBoundIsPrintedOnlyWhereItHolds(t *testing.T) {
	frozen := &FrozenTuple{PremiumInputTokens: 256, ContenderInputTokens: 8192}
	const bound = "could therefore disagree"

	for _, tc := range []struct {
		name      string
		arm       ArmSummary
		wantBound bool
	}{
		{
			// The review's own example. A bound of 1/101 beside ten confirmed mismatches is worse than no
			// bound at all: it reads as "almost everything checked out".
			name: "a reported mismatch beside an unanswered request",
			arm: declaredLoadArmWithFailures(ArmShared,
				map[string]map[int]int{PremiumTenant: {256: 100, 512: 10}},
				nil, map[string]int{PremiumTenant: 1}),
			wantBound: false,
		},
		{
			name: "an answered-but-uncounted row beside an unanswered request",
			arm: declaredLoadArmWithFailures(ArmShared,
				map[string]map[int]int{PremiumTenant: {256: 100}},
				map[string]int{PremiumTenant: 4}, map[string]int{PremiumTenant: 1}),
			wantBound: false,
		},
		{
			name: "a negative count beside an unanswered request",
			arm: ArmSummary{
				Arm:                                 ArmShared,
				EngineInputTokensByTenant:           map[string]map[int]int{PremiumTenant: {256: 100}},
				EngineInputTokensUnansweredByTenant: map[string]int{PremiumTenant: 1},
				EngineInputTokensInvalidByTenant:    map[string]int{PremiumTenant: 2},
			},
			wantBound: false,
		},
		{
			// The one case where it is exactly right: nothing disagreed, nothing was answered-and-uncounted,
			// no value was broken, and the unanswered rows are the whole of what was not verified.
			name: "unanswered requests are the only unverified category",
			arm: declaredLoadArmWithFailures(ArmShared,
				map[string]map[int]int{PremiumTenant: {256: 100}},
				nil, map[string]int{PremiumTenant: 1}),
			wantBound: true,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := EvaluateDeclaredLoad([]ArmSummary{tc.arm}, frozen, PremiumTenant, NoisyTenant)
			has := strings.Contains(got.Detail, bound)
			if has != tc.wantBound {
				verb := "printed"
				if !has {
					verb = "omitted"
				}
				t.Errorf("the bound was %s and should not have been (fired=%v, n/e=%v):\n%s",
					verb, got.Fired, got.NotEvaluable, got.Detail)
			}
			// Whatever the outcome, the COUNT of unanswered requests is still owed to the reader.
			if !strings.Contains(got.Detail, "No count was obtained for 1 request(s)") {
				t.Errorf("the unanswered requests are not reported at all:\n%s", got.Detail)
			}
		})
	}
}

// A negative count is classified as a broken value, and classified BEFORE the response status is read.
//
// WHY THIS TEST EXISTS, measured 2026-10-03. Two mutations of the negative handling left the whole suite
// GREEN: deleting the classification entirely, and moving it behind the status check. Both passed because
// every other test in this file hands EvaluateDeclaredLoad a pre-built ArmSummary and so never runs
// tallyEngineInputTokens at all.
//
// That is the same defect I had just written a note to myself about, repeated within the hour: a fixture
// that starts after the aggregation cannot test the aggregation. The only cure is to feed RawRow through
// Summarize and assert on which bucket the row landed in.
//
// The ORDER matters on its own. A negative on a failed row is still a broken value, and the failed-row
// bucket is the one that does not block -- so classifying by status first would file the nonsense under the
// verdict that lets a run through.
func TestANegativeCountIsABrokenValueWhateverTheResponseWas(t *testing.T) {
	for _, tc := range []struct {
		name string
		row  RawRow
	}{
		{
			// The accounting hole's twin: a 200 came back, and the count it carried is impossible.
			name: "a negative on a successful response",
			row:  RawRow{HTTPStatus: httpStatusOK, EngineInputTokens: -1, OutputTokens: 16},
		},
		{
			// The case the two green mutations both got wrong. Reordering sends this to the unanswered
			// bucket, where it stops blocking and the run proceeds on a trace whose recorder is broken.
			name: "a negative on a failed response",
			row:  RawRow{HTTPStatus: 502, ErrorKind: "http", EngineInputTokens: -4096},
		},
		{
			name: "a negative on a timeout",
			row:  RawRow{HTTPStatus: 0, ErrorKind: errKindTimeout, EngineInputTokens: -256},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := tc.row
			r.Arm, r.Tenant = ArmShared, PremiumTenant
			s := Summarize(ArmShared, []RawRow{r})

			if got := s.EngineInputTokensInvalidByTenant[PremiumTenant]; got != 1 {
				t.Errorf("recorded %d rows as a broken value, want 1; a negative is not a prompt length and "+
					"must not be scored, silenced or excused by the response status", got)
			}
			if got := s.EngineInputTokensUnansweredByTenant[PremiumTenant]; got != 0 {
				t.Errorf("recorded %d rows as unanswered, want 0; that bucket does not block, so a broken "+
					"value filed there lets the run proceed", got)
			}
			if got := s.EngineInputTokensUnreportedByTenant[PremiumTenant]; got != 0 {
				t.Errorf("recorded %d rows as answered-but-uncounted, want 0; the row reported something, "+
					"and what it reported was impossible rather than missing", got)
			}
			if len(s.EngineInputTokensByTenant[PremiumTenant]) != 0 {
				t.Errorf("a negative was counted as a reported length: %v", s.EngineInputTokensByTenant)
			}

			// And it must reach the verdict as a refusal, over the Summarize path rather than a literal.
			got := EvaluateDeclaredLoad([]ArmSummary{s},
				&FrozenTuple{PremiumInputTokens: 256, ContenderInputTokens: 8192}, PremiumTenant, NoisyTenant)
			if !got.NotEvaluable || got.Fired {
				t.Errorf("a broken value did not refuse the reading (fired=%v, n/e=%v): %s",
					got.Fired, got.NotEvaluable, got.Detail)
			}
			if !strings.Contains(got.Detail, "negative") {
				t.Errorf("the refusal does not say what was wrong with the value:\n%s", got.Detail)
			}
		})
	}
}

// Every offered row lands in exactly one bucket, and the four of them add up to what was offered.
//
// Suggested by the external review as the conservation check the per-bucket tests cannot do: a mutation that
// drops a row, or files it twice, changes no single bucket's meaning but silently narrows the population the
// gate scores. Disposition.Offered is the independent count to hold them against.
func TestTheFourTokenBucketsAccountForEveryOfferedRow(t *testing.T) {
	rows := []RawRow{
		{HTTPStatus: httpStatusOK, EngineInputTokens: 256, OutputTokens: 16},
		{HTTPStatus: httpStatusOK, EngineInputTokens: 512, OutputTokens: 16},
		{HTTPStatus: httpStatusOK, OutputTokens: 16},
		{HTTPStatus: 502, ErrorKind: "http"},
		{HTTPStatus: 0, ErrorKind: errKindTimeout},
		{HTTPStatus: httpStatusOK, EngineInputTokens: -1, OutputTokens: 16},
	}
	for i := range rows {
		rows[i].Arm, rows[i].Tenant = ArmShared, PremiumTenant
	}
	s := Summarize(ArmShared, rows)

	reported := 0
	for _, n := range s.EngineInputTokensByTenant[PremiumTenant] {
		reported += n
	}
	sum := reported +
		s.EngineInputTokensUnreportedByTenant[PremiumTenant] +
		s.EngineInputTokensUnansweredByTenant[PremiumTenant] +
		s.EngineInputTokensInvalidByTenant[PremiumTenant]

	if offered := s.DispositionByTenant[PremiumTenant].Offered; sum != offered {
		t.Errorf("the four buckets hold %d rows and %d were offered (reported=%d uncounted=%d unanswered=%d "+
			"invalid=%d); a row in none of them or in two of them changes the population the gate scores "+
			"without changing any bucket's meaning",
			sum, offered, reported,
			s.EngineInputTokensUnreportedByTenant[PremiumTenant],
			s.EngineInputTokensUnansweredByTenant[PremiumTenant],
			s.EngineInputTokensInvalidByTenant[PremiumTenant])
	}
	if sum != len(rows) {
		t.Errorf("the buckets hold %d of %d rows written into the fixture", sum, len(rows))
	}
}

// Routing the two silences by the error kind rather than by the response would reclassify the next kind.
//
// errKindTimeout and errKindRejected are named constants; the ten-cell archive's failure carried "http",
// which is in neither. A predicate that listed kinds would have put that row in the accounting-hole bucket
// by omission, which is how the first version of this gate behaved. The response status is the fact that
// decides it, and this pins that a NAMED kind and an unnamed one land in the same place.
func TestAnyUnsuccessfulResponseCountsAsUnanswered(t *testing.T) {
	for _, tc := range []struct {
		name string
		row  RawRow
	}{
		{name: "a 502 with an unnamed error kind", row: RawRow{HTTPStatus: 502, ErrorKind: "http"}},
		{name: "a timeout with no status at all", row: RawRow{HTTPStatus: 0, ErrorKind: errKindTimeout}},
		{name: "a shed request", row: RawRow{HTTPStatus: httpStatusTooManyRequests, ErrorKind: errKindRejected}},
		{name: "a refusal decided on identity", row: RawRow{HTTPStatus: httpStatusForbidden}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := tc.row
			r.Arm, r.Tenant = ArmShared, PremiumTenant
			s := Summarize(ArmShared, []RawRow{r})

			if got := s.EngineInputTokensUnansweredByTenant[PremiumTenant]; got != 1 {
				t.Errorf("recorded %d unanswered rows, want 1", got)
			}
			if got := s.EngineInputTokensUnreportedByTenant[PremiumTenant]; got != 0 {
				t.Errorf("recorded %d rows as answered-but-uncounted, want 0; a request that never got a "+
					"successful response cannot be an accounting hole", got)
			}
		})
	}
}
