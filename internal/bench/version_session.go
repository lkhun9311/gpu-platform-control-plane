package bench

import (
	"context"
	"errors"
	"fmt"
	"time"
)

// VisitOutcome is what one treatment's visit in a block says about the block's validity.
//
// Engine crashes and missed readiness are outcomes of the arm, recorded in the rows; they leave Invalid empty.
type VisitOutcome struct {
	// Invalid is the invalidation rule the visit broke, or empty when every cell of it is valid.
	Invalid string
	// LagInvalid is true when dispatch lag (rule 2) is among the reasons, because two such blocks for one treatment stop the campaign.
	LagInvalid bool
}

// VisitRunner runs one treatment's visit in a block: a fresh engine, its readiness bound, both loads in the given
// order with drained starts and any drain restart, then the engine's stop.
//
// An error is a recorder failure (rule 5): the visit's evidence is not whole, and the campaign stops, as it does on a
// failed journal write, because a recorder that lost a write once is not trusted with the replacements either.
type VisitRunner func(ctx context.Context, block int, treatment string, loads []string) (VisitOutcome, error)

// BlockLedger records each attempt's start before its first cell and its end when it ends; AttemptJournal is one.
type BlockLedger interface {
	Start(block, replaces int, at time.Time) error
	End(block int, status AttemptStatus, reason string, at time.Time) error
}

// SessionBlocks are the inputs the block phase needs once the bundle is frozen.
type SessionBlocks struct {
	Design        VersionStudyDesign
	WindowSeconds int
	// RatePerHour is the instance price plus the other session charges per hour, as frozen in the bundle.
	RatePerHour float64
	// Spent is what the session has cost so far; it is read before every block.
	Spent  func() float64
	Now    func() time.Time
	Ledger BlockLedger
	Visit  VisitRunner
}

// BlocksResult is how the block phase ended.
type BlocksResult struct {
	Valid int
	// Stop is why the phase ended before PlannedBlocks valid blocks, or empty when it reached them.
	Stop string
}

// RunBlocks runs the planned blocks in order, then replacements for invalid ones, until enough are valid or a stop rule
// ends the campaign (#607).
//
// Every block is checked against the budget for all the valid blocks still needed before it starts, since a session
// that can afford only the next block would spend money on a pilot it cannot complete.
// A replacement takes the next block number, so its seed and orders are the ones its number fixes, and it starts only
// after every planned block has ended, as AnalysisSet requires.
// When dispatch lag invalidates two blocks of one treatment the campaign stops: replacing blocks a treatment keeps
// invalidating would keep drawing until the client happens to keep up.
// A cancelled context (the teardown deadline or an interruption) or a recorder failure records the open block as stopped
// and runs nothing after.
func RunBlocks(ctx context.Context, s SessionBlocks) (BlocksResult, error) {
	d := s.Design
	var res BlocksResult
	var invalid []int
	lagBlocks := map[string]int{}
	replacements := 0
	for block := 1; ; block++ {
		replaces := 0
		if block > d.PlannedBlocks {
			if res.Valid >= d.PlannedBlocks {
				return res, nil
			}
			if len(invalid) == 0 || replacements >= d.MaxReplacementBlocks {
				res.Stop = fmt.Sprintf("%d of %d planned blocks are valid and no replacement remains", res.Valid, d.PlannedBlocks)
				return res, nil
			}
			replaces, invalid = invalid[0], invalid[1:]
			replacements++
		}
		if err := ctx.Err(); err != nil {
			res.Stop = fmt.Sprintf("stopped before block %d: %v", block, err)
			return res, nil
		}
		needed := d.PlannedBlocks - res.Valid
		if !d.MayStartBlock(s.Spent(), s.RatePerHour, needed, s.WindowSeconds) {
			res.Stop = fmt.Sprintf("the budget cannot cover the %d valid blocks still needed before block %d", needed, block)
			return res, nil
		}
		if err := s.Ledger.Start(block, replaces, s.Now()); err != nil {
			return res, fmt.Errorf("block %d start: %w", block, err)
		}
		status, reason, lagged := s.runBlock(ctx, block)
		if err := s.Ledger.End(block, status, reason, s.Now()); err != nil {
			return res, fmt.Errorf("block %d end: %w", block, err)
		}
		switch status {
		case AttemptStopped:
			res.Stop = fmt.Sprintf("block %d stopped: %s", block, reason)
			return res, nil
		case AttemptValid:
			res.Valid++
		case AttemptInvalid:
			invalid = append(invalid, block)
		}
		for _, t := range lagged {
			if lagBlocks[t]++; lagBlocks[t] == 2 {
				res.Stop = fmt.Sprintf("dispatch lag invalidated treatment %s in two blocks", t)
				return res, nil
			}
		}
	}
}

// runBlock runs every visit of one block in its seeded order, and says how the attempt ends and which treatments lagged.
//
// A visit's invalidity does not skip the later visits: the block's cells stay attempted cells, and an early exit would
// change how long the next treatment's engine had the instance to itself.
func (s SessionBlocks) runBlock(ctx context.Context, block int) (AttemptStatus, string, []string) {
	var reasons []error
	var lagged []string
	loads := LoadOrder(block)
	for _, t := range ArmOrder(s.Design.CampaignSeed, block) {
		out, err := s.Visit(ctx, block, t, loads)
		if ctxErr := ctx.Err(); ctxErr != nil {
			return AttemptStopped, fmt.Sprintf("cut short in treatment %s: %v", t, ctxErr), nil
		}
		if err != nil {
			return AttemptStopped, fmt.Sprintf("recorder failure in treatment %s: %v", t, err), nil
		}
		if out.Invalid != "" {
			reasons = append(reasons, fmt.Errorf("treatment %s: %s", t, out.Invalid))
		}
		if out.LagInvalid {
			lagged = append(lagged, t)
		}
	}
	if len(reasons) > 0 {
		return AttemptInvalid, errors.Join(reasons...).Error(), lagged
	}
	return AttemptValid, "", nil
}
