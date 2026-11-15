package bench

import (
	"strings"
	"testing"
	"time"
)

// TestExternalCauseCountsOnlyAWSRecordsThatOverlapTheBlock: the predicate is the interval overlap of a named AWS record, nothing else.
func TestExternalCauseCountsOnlyAWSRecordsThatOverlapTheBlock(t *testing.T) {
	start := journalT0
	end := start.Add(time.Hour)
	block := BlockAttempt{Block: 3, StartedAt: start, EndedAt: end}
	covered := func(rs ...InstanceRecord) InstanceRecords {
		return InstanceRecords{InstanceID: "i-1", CoveredFrom: start.Add(-time.Minute), CoveredThrough: end.Add(time.Minute), Records: rs}
	}
	for name, c := range map[string]struct {
		recs InstanceRecords
		hit  bool
	}{
		"nothing reported":                                 {covered(), false},
		"spot notice inside":                               {covered(InstanceRecord{Kind: InstanceSpotInterruption, Code: "terminate", From: start.Add(10 * time.Minute), To: start.Add(10 * time.Minute)}), true},
		"spot notice at the last instant":                  {covered(InstanceRecord{Kind: InstanceSpotInterruption, From: end, To: end}), true},
		"status check failing since before and still open": {covered(InstanceRecord{Kind: InstanceSystemStatusFailed, From: start.Add(-time.Hour)}), true},
		"status check that recovered before the block":     {covered(InstanceRecord{Kind: InstanceSystemStatusFailed, From: start.Add(-time.Hour), To: start.Add(-time.Second)}), false},
		"scheduled event due after the block":              {covered(InstanceRecord{Kind: InstanceScheduledEvent, Code: "instance-retirement", From: end.Add(24 * time.Hour), To: end.Add(48 * time.Hour)}), false},
		"scheduled reboot window over the block":           {covered(InstanceRecord{Kind: InstanceScheduledEvent, Code: "system-reboot", From: start.Add(-time.Minute), To: start.Add(5 * time.Minute)}), true},
	} {
		t.Run(name, func(t *testing.T) {
			reason, err := ExternalCause(c.recs, block)
			if err != nil {
				t.Fatal(err)
			}
			if (reason != "") != c.hit {
				t.Fatalf("reason %q, want hit %v", reason, c.hit)
			}
			if c.hit && !strings.Contains(reason, "i-1") {
				t.Fatalf("reason %q does not name the instance", reason)
			}
		})
	}
}

// TestExternalCauseRefusesRecordsThatDoNotCoverTheBlock: a collection gap is not evidence that nothing happened.
func TestExternalCauseRefusesRecordsThatDoNotCoverTheBlock(t *testing.T) {
	block := BlockAttempt{Block: 1, StartedAt: journalT0, EndedAt: journalT0.Add(time.Hour)}
	for name, recs := range map[string]InstanceRecords{
		"ends early":      {InstanceID: "i-1", CoveredFrom: journalT0, CoveredThrough: journalT0.Add(59 * time.Minute)},
		"starts late":     {InstanceID: "i-1", CoveredFrom: journalT0.Add(time.Second), CoveredThrough: journalT0.Add(2 * time.Hour)},
		"never covered":   {InstanceID: "i-1"},
		"no instance":     {CoveredFrom: journalT0, CoveredThrough: journalT0.Add(2 * time.Hour)},
		"unnamed kind":    {InstanceID: "i-1", CoveredFrom: journalT0, CoveredThrough: journalT0.Add(2 * time.Hour), Records: []InstanceRecord{{Kind: "engine-crash", From: journalT0}}},
		"reversed record": {InstanceID: "i-1", CoveredFrom: journalT0, CoveredThrough: journalT0.Add(2 * time.Hour), Records: []InstanceRecord{{Kind: InstanceSpotInterruption, From: journalT0.Add(time.Minute), To: journalT0}}},
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := ExternalCause(recs, block); err == nil {
				t.Fatal("decided rule 6 from records that cannot establish it")
			}
		})
	}
}
