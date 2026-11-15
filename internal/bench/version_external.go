package bench

import (
	"fmt"
	"strings"
	"time"
)

// Invalidation rule 6, external cause, is an automatic predicate over AWS's own records for the instance (owner amendment, 2026-11-15).
// It reads nothing the run produced, so it cannot be chosen after seeing results; any crash or unavailability it does not
// cover is an engine outcome.

// InstanceRecordKind is one of the three AWS records the registration counts as external.
type InstanceRecordKind string

const (
	// InstanceScheduledEvent is an EC2 scheduled event for the instance, such as retirement or a system reboot.
	InstanceScheduledEvent InstanceRecordKind = "scheduled-event"
	// InstanceSystemStatusFailed is a failed system status check, AWS's own report that its host is impaired.
	InstanceSystemStatusFailed InstanceRecordKind = "system-status-failed"
	// InstanceSpotInterruption is a spot interruption notice for the instance.
	InstanceSpotInterruption InstanceRecordKind = "spot-interruption"
)

// InstanceRecord is one AWS record, over the interval AWS gives it.
//
// A scheduled event spans its NotBefore to NotAfter; a failed status check spans its ImpairedSince to the first poll that
// saw it pass, or has no end while it is still failing; a spot notice is the instant it names, so To equals From.
// A scheduled event announced during a block but due after it did not act on the block, so it is not counted.
type InstanceRecord struct {
	Kind InstanceRecordKind
	// Code is AWS's own name for it, such as "system-reboot" or "terminate", kept for the reason.
	Code string
	From time.Time
	// To is the interval's end; zero means the record was still open when collection ended.
	To time.Time
}

// InstanceRecords is what the runner collected for one instance, and the span the collection is complete for.
type InstanceRecords struct {
	InstanceID string
	// CoveredFrom and CoveredThrough bound the time the collection polled without a gap.
	CoveredFrom, CoveredThrough time.Time
	Records                     []InstanceRecord
}

// ExternalCause applies rule 6 to one block attempt: a non-empty reason means the block is invalid for an external cause.
//
// It refuses records that do not cover the whole attempt, because a gap is exactly where an interruption could hide and
// "nothing was reported" would then be a claim the evidence does not make; the runner treats that refusal as a recorder
// failure (rule 5), which is also invalid but for the reason that is true.
func ExternalCause(recs InstanceRecords, a BlockAttempt) (string, error) {
	switch {
	case recs.InstanceID == "":
		return "", fmt.Errorf("the instance records name no instance")
	case a.StartedAt.IsZero() || !a.EndedAt.After(a.StartedAt):
		return "", fmt.Errorf("block %d has no interval to test: %s to %s", a.Block, a.StartedAt.Format(time.RFC3339), a.EndedAt.Format(time.RFC3339))
	case recs.CoveredFrom.IsZero() || recs.CoveredFrom.After(a.StartedAt) || recs.CoveredThrough.Before(a.EndedAt):
		return "", fmt.Errorf("instance %s records cover %s to %s, not block %d's %s to %s",
			recs.InstanceID, recs.CoveredFrom.Format(time.RFC3339), recs.CoveredThrough.Format(time.RFC3339),
			a.Block, a.StartedAt.Format(time.RFC3339), a.EndedAt.Format(time.RFC3339))
	}
	var hits []string
	for i, r := range recs.Records {
		switch r.Kind {
		case InstanceScheduledEvent, InstanceSystemStatusFailed, InstanceSpotInterruption:
		default:
			return "", fmt.Errorf("instance record %d has kind %q, which rule 6 does not name", i, r.Kind)
		}
		if r.From.IsZero() || (!r.To.IsZero() && r.To.Before(r.From)) {
			return "", fmt.Errorf("instance record %d (%s) has no valid interval: %s to %s", i, r.Kind, r.From.Format(time.RFC3339), r.To.Format(time.RFC3339))
		}
		// Closed intervals on both sides: a record touching the block's first or last instant still overlaps it.
		if r.From.After(a.EndedAt) || (!r.To.IsZero() && r.To.Before(a.StartedAt)) {
			continue
		}
		hits = append(hits, fmt.Sprintf("%s %s at %s", r.Kind, r.Code, r.From.UTC().Format(time.RFC3339)))
	}
	if len(hits) == 0 {
		return "", nil
	}
	return fmt.Sprintf("external cause: AWS reported %s for instance %s during block %d", strings.Join(hits, ", "), recs.InstanceID, a.Block), nil
}
