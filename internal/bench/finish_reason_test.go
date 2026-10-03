package bench

import "testing"

// The three silences a finish reason can leave, each driven through Summarize rather than asserted on a
// hand-built ArmSummary.
//
// # WHY THE PATH MATTERS
//
// This package has 188 ArmSummary literals in its tests, and a literal bypasses the aggregation entirely:
// the population choice, the ordering of the three branches and the map initialisation are all inside
// Summarize, so a fixture that fills the maps by hand tests the formatter and nothing else. Three defects
// in this session were found exactly that way -- a mutation of the real code left every hand-built test
// green. So each case here starts from RawRow.
func TestFinishReasonsAreTalliedThroughSummarize(t *testing.T) {
	rows := []RawRow{
		// Reported: the output cap cut it. This is a reading.
		{Index: 0, Tenant: "premium-1", HTTPStatus: 200, FinishReason: "length"},
		{Index: 1, Tenant: "premium-1", HTTPStatus: 200, FinishReason: "length"},
		// Reported: the model ended on its own. A DIFFERENT reading, not the same as the cap.
		{Index: 2, Tenant: "premium-1", HTTPStatus: 200, FinishReason: "stop"},
		// Answered and said nothing: an instrument gap, not a normal stop.
		{Index: 3, Tenant: "premium-1", HTTPStatus: 200},
		// No successful response at all: unobservable here, and not the same fact as the gap above.
		{Index: 4, Tenant: "premium-1", HTTPStatus: 0, ErrorKind: "timeout"},
		{Index: 5, Tenant: "noisy-1", HTTPStatus: 503},
	}
	s := Summarize("off", rows)

	if got := s.FinishReasonByTenant["premium-1"]["length"]; got != 2 {
		t.Errorf("premium rows reporting the cap = %d, want 2", got)
	}
	if got := s.FinishReasonByTenant["premium-1"]["stop"]; got != 1 {
		t.Errorf("premium rows reporting a model stop = %d, want 1", got)
	}
	// "length" and "stop" must not be pooled: a run that hit the cap on every request measured the cap.
	if len(s.FinishReasonByTenant["premium-1"]) != 2 {
		t.Errorf("distinct premium finish reasons = %d, want 2; pooling them loses the only distinction the field exists for", len(s.FinishReasonByTenant["premium-1"]))
	}
	if got := s.FinishReasonUnreportedByTenant["premium-1"]; got != 1 {
		t.Errorf("premium 200s that named no reason = %d, want 1", got)
	}
	if got := s.FinishReasonUnansweredByTenant["premium-1"]; got != 1 {
		t.Errorf("premium rows with no successful response = %d, want 1", got)
	}
	// The contender's 503 is unanswered, not unreported: it never completed.
	if got := s.FinishReasonUnansweredByTenant["noisy-1"]; got != 1 {
		t.Errorf("contender rows with no successful response = %d, want 1", got)
	}
	if got := s.FinishReasonUnreportedByTenant["noisy-1"]; got != 0 {
		t.Errorf("contender 200s that named no reason = %d, want 0; a 503 is not an answered request", got)
	}
}

// Every offered row lands in exactly one of the three buckets, so none is silently dropped.
//
// Conservation is asserted against DispositionByTenant[t].Offered rather than len(rows), because that is
// the divisor every published per-tenant figure uses. A bucket that quietly lost rows would shift those
// figures without changing any count a reader can see.
func TestEveryOfferedRowLandsInExactlyOneFinishReasonBucket(t *testing.T) {
	rows := []RawRow{
		{Index: 0, Tenant: "premium-1", HTTPStatus: 200, FinishReason: "length"},
		{Index: 1, Tenant: "premium-1", HTTPStatus: 200, FinishReason: "stop"},
		{Index: 2, Tenant: "premium-1", HTTPStatus: 200},
		{Index: 3, Tenant: "premium-1", HTTPStatus: 0, ErrorKind: "transport"},
		{Index: 4, Tenant: "premium-1", HTTPStatus: 429},
	}
	s := Summarize("off", rows)

	reported := 0
	for _, n := range s.FinishReasonByTenant["premium-1"] {
		reported += n
	}
	total := reported + s.FinishReasonUnreportedByTenant["premium-1"] + s.FinishReasonUnansweredByTenant["premium-1"]
	offered := s.DispositionByTenant["premium-1"].Offered
	if total != offered {
		t.Errorf("the three finish-reason buckets hold %d rows (reported %d, unreported %d, unanswered %d) and the tenant was offered %d; a row in none of them is a row no published figure accounts for",
			total, reported, s.FinishReasonUnreportedByTenant["premium-1"], s.FinishReasonUnansweredByTenant["premium-1"], offered)
	}
}

// A 200 that named no reason must not be read as a model stop.
//
// This is the case the field exists for: without it, "the cap was not reached" was unsupportable in either
// direction, and the cheapest wrong fix is to default the empty string to "stop".
func TestAnAnsweredRowWithNoReasonIsNotCountedAsAStop(t *testing.T) {
	s := Summarize("off", []RawRow{
		{Index: 0, Tenant: "premium-1", HTTPStatus: 200},
	})
	if got := s.FinishReasonByTenant["premium-1"]["stop"]; got != 0 {
		t.Errorf("rows counted as a model stop = %d, want 0; the engine said nothing and that is an instrument gap", got)
	}
	if got := s.FinishReasonUnreportedByTenant["premium-1"]; got != 1 {
		t.Errorf("rows counted as unreported = %d, want 1", got)
	}
	if len(s.FinishReasonByTenant["premium-1"]) != 0 {
		t.Errorf("distinct reasons = %d, want 0; an empty reason is not a reason", len(s.FinishReasonByTenant["premium-1"]))
	}
}
