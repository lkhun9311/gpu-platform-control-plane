package bench

import (
	"fmt"
	"strings"
)

// The readings pre-registered in docs/superpowers/specs/2026-09-05-the-price-of-protection.md.
//
// They live in their own file because they are a different experiment's criteria from EvaluateChecks', and
// the 2026-09-07 pilot showed what happens when a study has none of its own: the report handed the caller an
// empty Checks, which rendered as three failures and a verdict for criteria nobody had evaluated. Every
// number in that pilot's write-up was computed by hand.
//
// The order matters and is the pre-registration's: "the first reading that fires is the answer". Reading 4
// is evaluated first even though it is numbered last, because a load that produced no contention makes the
// other four comparisons meaningless rather than negative.

// Disposition is what became of one tenant's offered requests in one arm.
//
// Its whole purpose is to let reading 2 distinguish work that was DELETED from work that was merely late.
// Those produce the same small output share and mean opposite things about a configuration.
type Disposition struct {
	// Offered is every request the trace sent for this tenant, whatever became of it.
	Offered int
	// Completed produced a first token and finished.
	Completed int
	// Rejected was refused at admission (429 or 413) -- work the system chose not to do.
	Rejected int
	// TimedOut ran past the client deadline -- work that may have been delayed rather than discarded.
	TimedOut int
	// Failed broke in transport or mid-stream.
	Failed int
}

// PoPReading is one pre-registered outcome and whether the evidence fired it.
type PoPReading struct {
	// ID is the pre-registration's own numbering: "1", "1b", "2", "3", "4".
	ID string
	// Name is the reading's headline, as written.
	Name string
	// Fired says the evidence meets this reading.
	Fired bool
	// Cell is the winning cell, for the readings that name one.
	Cell string
	// Detail is the measured basis, so a reader never has to take Fired on faith.
	Detail string
	// NotEvaluable marks a reading the evidence cannot decide either way, which is neither fired nor not.
	// A reading that silently reports false when it could not be computed is the defect this whole file
	// exists to avoid.
	NotEvaluable bool
}

// PoPResult is the ordered readings plus the one that answered.
type PoPResult struct {
	Readings []PoPReading
	// Answer is the first reading that fired, or "" when none did.
	Answer string
}

// The bars, named rather than inlined so the pre-registration and the code can be diffed by eye.
const (
	popTTFTBar       = 2.00 // premium TTFT p99, as a multiple of R1's
	popTPOTBar       = 1.25 // premium TPOT p99, as a multiple of R1's
	popNoisyShareBar = 0.75 // noisy tenant's output share, as a fraction of its share under the control
	popThroughputBar = 0.95 // aggregate output tok/s, as a fraction of the control's
	popContentionBar = 5.00 // control's premium TTFT p99 over R1's, below which the load made no contention
)

// EvaluatePriceOfProtection scores the sweep's cells against the pre-registered readings.
//
// r1 is the isolated baseline, control is ArmDefaultFCFS, and cells are every configured cell in the order
// the study prints them. premiumTenant and noisyTenant name the two populations whose shares the readings
// compare; they are passed rather than guessed because a reading that hard-codes a tenant name would go
// quietly wrong the first time a trace renames one.
func EvaluatePriceOfProtection(r1, control ArmSummary, cells []ArmSummary, premiumTenant, noisyTenant string) PoPResult {
	var res PoPResult

	// Reading 4 first: if the load made no contention, nothing below is a measurement of protection.
	four := PoPReading{ID: "4", Name: "the load did not create contention -- INVALID"}
	switch {
	case r1.TTFTMsP99 <= 0:
		four.NotEvaluable = true
		four.Detail = "R1 has no premium tail to compare against"
	default:
		ratio := control.TTFTMsP99 / r1.TTFTMsP99
		four.Fired = ratio < popContentionBar
		four.Detail = fmt.Sprintf("control premium TTFT p99 is %.1fx R1's (%.1f ms against %.1f ms); the load is contended when this is at least %.2fx",
			ratio, control.TTFTMsP99, r1.TTFTMsP99, popContentionBar)
	}
	res.Readings = append(res.Readings, four)
	if four.Fired || four.NotEvaluable {
		res.Answer = answerOf(four)
		return res
	}

	// Reading 4b, added by 2026-09-08-the-load-needs-an-upper-gate.md: reading 4 guards only the low side.
	//
	// A load can also be too high to measure. The pilot's control completed 17 of 555 premium requests and 26
	// of 544 of the contending tenant's, everything else timing out -- and every reading below is a ratio of
	// tails and shares over those handfuls. The floor is MinTailSamples, which is not a number chosen here:
	// it is the point where a nearest-rank p99 stops being the largest observation, derived in report.go and
	// already gating the other study. A control below it cannot supply a tail, and its output shares are
	// computed over whatever few requests happened to survive.
	fourB := PoPReading{ID: "4b", Name: "the load was too high to measure -- INVALID"}
	controlNoisyDone := control.DispositionByTenant[noisyTenant].Completed
	switch {
	case control.TailSampleSize < MinTailSamples:
		fourB.Fired = true
		fourB.Detail = fmt.Sprintf("the control completed %d premium requests, below the %d a nearest-rank p99 needs to be anything other than the maximum",
			control.TailSampleSize, MinTailSamples)
	case len(control.DispositionByTenant) == 0:
		fourB.NotEvaluable = true
		fourB.Detail = "the control carries no per-tenant disposition, so how much of each tenant's work survived cannot be checked"
	case controlNoisyDone < MinTailSamples:
		fourB.Fired = true
		fourB.Detail = fmt.Sprintf("the control completed %d of %s's %d requests, below the %d that the share clauses need to be measuring a population rather than a remnant",
			controlNoisyDone, noisyTenant, control.DispositionByTenant[noisyTenant].Offered, MinTailSamples)
	default:
		fourB.Detail = fmt.Sprintf("the control completed %d premium and %d %s requests, both at or above %d",
			control.TailSampleSize, controlNoisyDone, noisyTenant, MinTailSamples)
	}
	res.Readings = append(res.Readings, fourB)
	if fourB.Fired || fourB.NotEvaluable {
		res.Answer = answerOf(fourB)
		return res
	}

	// The three bars every positive reading shares, measured per cell.
	type scored struct {
		ArmSummary
		ttft, tpot, share, thru float64
		ttftOK, tpotOK          bool
		shareOK, thruOK         bool
		computable              bool
	}
	controlNoisy := shareOf(control, noisyTenant)
	var all []scored
	for _, c := range cells {
		s := scored{ArmSummary: c}
		s.ttft = ratioOr(c.TTFTMsP99, r1.TTFTMsP99)
		s.tpot = ratioOr(c.TPOTMsP99ByTenant[premiumTenant], r1.TPOTMsP99ByTenant[premiumTenant])
		s.thru = ratioOr(c.OutputTokensPerSecond, control.OutputTokensPerSecond)
		s.share = ratioOr(shareOf(c, noisyTenant), controlNoisy)
		s.computable = r1.TTFTMsP99 > 0 && r1.TPOTMsP99ByTenant[premiumTenant] > 0 &&
			control.OutputTokensPerSecond > 0 && controlNoisy > 0
		s.ttftOK = s.ttft <= popTTFTBar
		s.tpotOK = s.tpot <= popTPOTBar
		s.shareOK = s.share >= popNoisyShareBar
		s.thruOK = s.thru >= popThroughputBar
		all = append(all, s)
	}

	// Reading 1: all four bars. Ties on noisy share go to the larger budget, which is the later cell in the
	// study's own ordering -- the pre-registration says so and says why.
	one := PoPReading{ID: "1", Name: "protection without deletion -- POSITIVE"}
	var won *scored
	for i := range all {
		s := &all[i]
		if !s.computable || !s.ttftOK || !s.tpotOK || !s.shareOK || !s.thruOK {
			continue
		}
		// Highest noisy share wins. On an EXACT tie the later cell wins, because cells arrive in the study's
		// order and that order is ascending by budget -- the pre-registration breaks ties toward the larger
		// budget, as the smaller change from the control, and says its first draft got this backwards.
		if won == nil || s.share >= won.share {
			won = s
		}
	}
	if won != nil {
		one.Fired, one.Cell = true, won.Arm
		one.Detail = fmt.Sprintf("%s holds TTFT p99 at %.2fx R1, TPOT p99 at %.2fx, noisy share at %.2f of the control's and throughput at %.2f of it",
			won.Arm, won.ttft, won.tpot, won.share, won.thru)
	} else {
		one.Detail = "no cell met all four bars"
	}
	res.Readings = append(res.Readings, one)

	// Reading 1b: the same, minus the throughput clause, and only for cells that missed on throughput alone.
	oneB := PoPReading{ID: "1b", Name: "protection, bought with throughput -- POSITIVE with a price"}
	var wonB *scored
	for i := range all {
		s := &all[i]
		if !s.computable || !s.ttftOK || !s.tpotOK || !s.shareOK || s.thruOK {
			continue
		}
		if wonB == nil || s.thru > wonB.thru {
			wonB = s
		}
	}
	if wonB != nil {
		oneB.Fired, oneB.Cell = true, wonB.Arm
		oneB.Detail = fmt.Sprintf("%s protects at %.2fx R1 with the noisy tenant's work intact, and costs %.0f%% of the control's throughput",
			wonB.Arm, wonB.ttft, 100*(1-wonB.thru))
	} else {
		oneB.Detail = "no cell held the tail, the share and the stream while missing only on throughput"
	}
	res.Readings = append(res.Readings, oneB)

	// Reading 2: protection only by deletion. Requires cells that met the p99 bar, all of them failing the
	// share bar, AND the per-tenant ledger showing the missing work was refused or discarded rather than late.
	two := PoPReading{ID: "2", Name: "protection only by deletion -- NEGATIVE"}
	var metTail []*scored
	for i := range all {
		if all[i].computable && all[i].ttftOK {
			metTail = append(metTail, &all[i])
		}
	}
	switch {
	case len(metTail) == 0:
		two.Detail = "no cell met the p99 bar, so this reading does not apply; that is reading 3"
	default:
		allDeleted, why := true, ""
		for _, s := range metTail {
			if s.shareOK {
				allDeleted, why = false, fmt.Sprintf("%s met the p99 bar with the noisy tenant's share intact", s.Arm)
				break
			}
			d, ok := s.DispositionByTenant[noisyTenant]
			if !ok {
				two.NotEvaluable = true
				two.Detail = fmt.Sprintf("%s carries no per-tenant disposition for %s, and a smaller share is equally consistent with deletion, delay and starvation",
					s.Arm, noisyTenant)
				break
			}
			// Deletion means refused or discarded. A timeout is work that may merely have been late, and
			// the pre-registration is explicit that those are different findings.
			if d.Rejected+d.Failed == 0 {
				allDeleted, why = false, fmt.Sprintf("%s lost %s's share with %d timeouts and no rejections or discards, which is delay rather than deletion",
					s.Arm, noisyTenant, d.TimedOut)
				break
			}
		}
		if !two.NotEvaluable {
			two.Fired = allDeleted
			if allDeleted {
				two.Detail = fmt.Sprintf("every cell that met the p99 bar (%d of them) did so with %s's work rejected or discarded", len(metTail), noisyTenant)
			} else {
				two.Detail = why
			}
		}
	}
	res.Readings = append(res.Readings, two)

	// Reading 3: no cell beats the control by more than the control's own repetition-to-repetition spread.
	// With one repetition there IS no spread, so this cannot be decided rather than being decided as false.
	three := PoPReading{ID: "3", Name: "no cell beats the control -- INCONCLUSIVE"}
	if spread, ok := repetitionSpread(control.RepetitionTTFTMsP99); !ok {
		three.NotEvaluable = true
		three.Detail = fmt.Sprintf("the control carries %d per-repetition tail(s); its repetition-to-repetition spread is what this reading compares against and needs at least 2",
			len(control.RepetitionTTFTMsP99))
	} else {
		best := 0.0
		for i := range all {
			if imp := control.TTFTMsP99 - all[i].TTFTMsP99; imp > best {
				best = imp
			}
		}
		three.Fired = best <= spread
		three.Detail = fmt.Sprintf("the best cell improves the control's premium TTFT p99 by %.1f ms against a repetition-to-repetition spread of %.1f ms",
			best, spread)
	}
	res.Readings = append(res.Readings, three)

	for _, r := range res.Readings {
		if r.Fired {
			res.Answer = answerOf(r)
			break
		}
	}
	return res
}

func answerOf(r PoPReading) string {
	if r.NotEvaluable {
		return ""
	}
	if r.Cell != "" {
		return r.ID + " (" + r.Cell + ")"
	}
	return r.ID
}

// ratioOr is a/b, and zero when b cannot be divided by. A zero ratio never passes a "<= bar" test by
// accident because the callers gate on computable first.
func ratioOr(a, b float64) float64 {
	if b == 0 {
		return 0
	}
	return a / b
}

// repetitionSpread is the control's own run-to-run variation in premium TTFT p99, as max minus min.
//
// Range rather than a standard deviation because the pre-registration says "repetition-to-repetition
// spread" and the confirmatory run has three repetitions: a standard deviation over three values is a
// number with the shape of a statistic and none of the content, and this study has already been bitten once
// by a bootstrap over four blocks being read as a 95% interval. The range is what it claims to be.
//
// ok is false when there are fewer than two repetitions, because one value has no spread. Returning zero
// there would silently make every cell "fail to beat the noise", which is a verdict rather than a refusal.
func repetitionSpread(perRep []float64) (float64, bool) {
	if len(perRep) < 2 {
		return 0, false
	}
	lo, hi := perRep[0], perRep[0]
	for _, v := range perRep[1:] {
		if v < lo {
			lo = v
		}
		if v > hi {
			hi = v
		}
	}
	return hi - lo, true
}

// shareOf is the tenant's fraction of the arm's output tokens.
func shareOf(s ArmSummary, tenant string) float64 {
	if s.OutputTokens == 0 {
		return 0
	}
	return float64(s.OutputTokensByTenant[tenant]) / float64(s.OutputTokens)
}

// FormatPriceOfProtection renders the readings under the measurements.
//
// Every reading is printed, fired or not, with the numbers it was decided on. A page that showed only the
// winner would be a conclusion without its basis, and this study's whole design is that the first reading to
// fire is the answer -- which a reader can only check if they can see the ones that did not.
func FormatPriceOfProtection(res PoPResult) string {
	var b strings.Builder
	b.WriteString("\nPre-registered readings (docs/superpowers/specs/2026-09-05-the-price-of-protection.md)\n")
	for _, r := range res.Readings {
		state := "did not fire"
		switch {
		case r.NotEvaluable:
			// Distinct from "did not fire" on purpose. One says the evidence answered no; the other says the
			// evidence could not be asked, and treating them alike is how a run reports an absence as a result.
			state = "NOT EVALUABLE"
		case r.Fired:
			state = "FIRED"
		}
		fmt.Fprintf(&b, "  %-3s %-52s %s\n", r.ID, r.Name, state)
		if r.Detail != "" {
			fmt.Fprintf(&b, "      %s\n", r.Detail)
		}
	}
	b.WriteString("\n")
	if res.Answer == "" {
		b.WriteString("ANSWER: none of the readings fired on this evidence.\n")
	} else {
		fmt.Fprintf(&b, "ANSWER: reading %s.\n", res.Answer)
	}
	return b.String()
}
