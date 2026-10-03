package bench

import "testing"

// The three destinations a row's generated prompt length can reach, each driven through Summarize.
//
// # WHY THE PATH MATTERS
//
// A hand-built ArmSummary fills these maps directly and never runs tallyPromptLen, so it would test nothing
// about the branch ordering or the three-way split. This package's 188 ArmSummary literals are exactly that
// shape, and three defects this session were found because a mutation of the real aggregation left every
// literal-based test green. So each case here starts from RawRow.
//
// # WHY THREE AND NOT ONE
//
// The first version of tallyPromptLen returned early on `PromptLenChars <= 0`, which threw absences and
// negatives away together. An external review derived the counter-example from that branch before any run:
// `[200, 200]` and `[200, absent]` both collapsed to "one length, 200", so a reading built on the
// distribution would have certified uniformity over rows half of which said nothing. That is the case
// TestAnAbsentLengthIsNotTheLengthBesideIt pins, and it is the reason the split exists.
func TestPromptLengthsAreTalliedThroughSummarize(t *testing.T) {
	rows := []RawRow{
		// Two rows at one level: a distribution with one key.
		{Index: 0, Tenant: PremiumTenant, PromptLenChars: 1174, HTTPStatus: 200},
		{Index: 1, Tenant: PremiumTenant, PromptLenChars: 1174, HTTPStatus: 200},
		// A SECOND level in the same arm and tenant: two conditions pooled, which is the fact the
		// distribution exists to make visible.
		{Index: 2, Tenant: PremiumTenant, PromptLenChars: 200, HTTPStatus: 200},
		// No length at all: a row written before RawRow.PromptLenChars existed.
		{Index: 3, Tenant: PremiumTenant, HTTPStatus: 200},
		// A length that cannot be one: a defect in the recorder, not evidence about the load.
		{Index: 4, Tenant: PremiumTenant, PromptLenChars: -7, HTTPStatus: 200},
		// A FAILED row still carries the length it was generated at. Counted, because a mixture whose
		// second level is the one that timed out would otherwise be invisible.
		{Index: 5, Tenant: PremiumTenant, PromptLenChars: 200, HTTPStatus: 0, ErrorKind: "timeout"},
		{Index: 6, Tenant: NoisyTenant, PromptLenChars: 42579, HTTPStatus: 200},
	}
	s := Summarize("shared", rows)

	if got := s.PromptLenCharsByTenant[PremiumTenant][1174]; got != 2 {
		t.Errorf("premium rows at 1,174 chars = %d, want 2", got)
	}
	// Two at 200: the 200 that completed and the 200 that timed out.
	if got := s.PromptLenCharsByTenant[PremiumTenant][200]; got != 2 {
		t.Errorf("premium rows at 200 chars = %d, want 2; a failed row still carries its generated length", got)
	}
	// MORE THAN ONE KEY is the disagreement, derived rather than stored. A single length plus a -1 sentinel
	// would be the same claim in two representations, and this repository has been bitten by a claim carried
	// in two places where only one was guarded.
	if n := len(s.PromptLenCharsByTenant[PremiumTenant]); n != 2 {
		t.Errorf("distinct premium prompt lengths = %d, want 2; pooling them hides that two conditions were merged", n)
	}
	if got := s.PromptLenUnreportedByTenant[PremiumTenant]; got != 1 {
		t.Errorf("premium rows carrying no length = %d, want 1", got)
	}
	if got := s.PromptLenInvalidByTenant[PremiumTenant]; got != 1 {
		t.Errorf("premium rows carrying a negative length = %d, want 1", got)
	}
	// A negative is NOT a length: it must not appear in the distribution under its own value.
	if _, ok := s.PromptLenCharsByTenant[PremiumTenant][-7]; ok {
		t.Error("a negative length reached the distribution; a value that cannot be a character count is a recorder defect, not a level")
	}
	if n := len(s.PromptLenCharsByTenant[NoisyTenant]); n != 1 {
		t.Errorf("distinct contender prompt lengths = %d, want 1", n)
	}
}

// The counter-example the review derived from the single-branch version, as a test.
//
// Two arms that a reading must not describe the same way: one where every row carried 1,174, and one where
// the rows that said anything said 1,174 and the rest said nothing. The distribution is identical in both --
// one key, 1174 -- so the ONLY thing that separates them is the unreported count, and a reading that reads
// the distribution alone certifies uniformity it has not seen.
func TestAnAbsentLengthIsNotTheLengthBesideIt(t *testing.T) {
	complete := Summarize("shared", []RawRow{
		{Index: 0, Tenant: PremiumTenant, PromptLenChars: 1174, HTTPStatus: 200},
		{Index: 1, Tenant: PremiumTenant, PromptLenChars: 1174, HTTPStatus: 200},
	})
	partial := Summarize("shared", []RawRow{
		{Index: 0, Tenant: PremiumTenant, PromptLenChars: 1174, HTTPStatus: 200},
		{Index: 1, Tenant: PremiumTenant, HTTPStatus: 200},
	})

	// The distributions agree, and that is the point: the distribution cannot tell these apart.
	if len(complete.PromptLenCharsByTenant[PremiumTenant]) != 1 ||
		len(partial.PromptLenCharsByTenant[PremiumTenant]) != 1 {
		t.Fatalf("both arms should hold one distinct length: complete=%v partial=%v",
			complete.PromptLenCharsByTenant[PremiumTenant], partial.PromptLenCharsByTenant[PremiumTenant])
	}
	if complete.PromptLenUnreportedByTenant[PremiumTenant] != 0 {
		t.Errorf("the complete arm reports %d rows without a length, want 0",
			complete.PromptLenUnreportedByTenant[PremiumTenant])
	}
	if partial.PromptLenUnreportedByTenant[PremiumTenant] != 1 {
		t.Errorf("the partial arm reports %d rows without a length, want 1 -- without this count the two arms are indistinguishable",
			partial.PromptLenUnreportedByTenant[PremiumTenant])
	}
}

// Every offered row lands in exactly one of the three destinations, so none is silently dropped.
//
// Asserted against DispositionByTenant[t].Offered rather than len(rows), for the reason the finish-reason
// conservation test gives: Offered is the divisor every published per-tenant figure uses, and a destination
// that quietly lost rows would move those figures without changing a count a reader can see.
func TestEveryOfferedRowLandsInExactlyOnePromptLengthDestination(t *testing.T) {
	rows := []RawRow{
		{Index: 0, Tenant: PremiumTenant, PromptLenChars: 1174, HTTPStatus: 200},
		{Index: 1, Tenant: PremiumTenant, PromptLenChars: 200, HTTPStatus: 200},
		{Index: 2, Tenant: PremiumTenant, HTTPStatus: 200},
		{Index: 3, Tenant: PremiumTenant, PromptLenChars: -1, HTTPStatus: 500, ErrorKind: "http"},
		{Index: 4, Tenant: PremiumTenant, PromptLenChars: 1174, HTTPStatus: 0, ErrorKind: "timeout"},
		{Index: 5, Tenant: PremiumTenant, PromptLenChars: 1174, HTTPStatus: 429},
	}
	s := Summarize("shared", rows)

	withLength := 0
	for _, n := range s.PromptLenCharsByTenant[PremiumTenant] {
		withLength += n
	}
	accounted := withLength + s.PromptLenUnreportedByTenant[PremiumTenant] + s.PromptLenInvalidByTenant[PremiumTenant]
	offered := s.DispositionByTenant[PremiumTenant].Offered
	if accounted != offered {
		t.Errorf("the three prompt-length destinations account for %d of %d offered premium rows (lengths=%d unreported=%d invalid=%d)",
			accounted, offered, withLength, s.PromptLenUnreportedByTenant[PremiumTenant],
			s.PromptLenInvalidByTenant[PremiumTenant])
	}
	// A rejected and a timed-out row are both counted: the tally runs before the loop's first `continue`,
	// and the length a request was generated at does not depend on what the engine did with it.
	if withLength != 4 {
		t.Errorf("rows carrying a length = %d, want 4 (two completed, one timed out, one rejected)", withLength)
	}
}
