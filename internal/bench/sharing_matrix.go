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
	"fmt"
	"sort"
	"strings"
)

// The M5-c sharing matrix's readings, from
// docs/superpowers/specs/2026-09-10-does-splitting-the-card-buy-protection.md.
//
// WHY THIS FILE EXISTS AT ALL
//
// The pre-registration lists seven readings and says "the first that fires is the answer". Until this file
// there was no code for any of them, so the answer would have been computed by hand from raw JSONL -- which
// is what the price-of-protection plan called out about itself and fixed: "a confirmatory run whose readings
// are evaluated by hand is not the pre-registered instrument". The pre-registration now gates renting a card
// on this file existing.
//
// It shares PoPReading with price_of_protection.go on purpose. The two studies print through one formatter
// and mean the same thing by Fired, NotEvaluable and Detail; a second copy of that struct would drift, and
// the drift would be between two things a reader compares side by side.
//
// WHAT IT REFUSES TO DO
//
// Every reading below can come back NotEvaluable, and that is a third outcome rather than a polite false.
// A reading that reports "did not fire" when it could not be computed is indistinguishable from one that
// looked and found nothing, and this repository has already paid for that confusion once: an R1 carrying no
// premium TPOT made every cell unscorable while three readings printed "no cell met..." as though they had
// looked.

// The bars, named rather than inlined so the pre-registration and the code can be diffed by eye.
const (
	m5cTTFTBar = 2.00 // premium TTFT p99, as a multiple of R1's
	m5cTPOTBar = 1.25 // premium TPOT p99, as a multiple of R1's
	// m5cContentionBar is reading 4: below this multiple of R1, `shared` produced no interference to study.
	m5cContentionBar = 5.00
	// m5cContenderShareBar is reading 2: the contender's completed output as a fraction of its output under
	// `shared`. Falling below it is necessary for starvation and NOT sufficient -- see readingTwoSharing.
	m5cContenderShareBar = 0.75
)

// SharingArms is everything the matrix produced, sorted into the roles the readings speak about.
type SharingArms struct {
	// R1 is the isolated premium baseline, and it is the DENOMINATOR of both bars rather than an arm.
	//
	// It carries no contender by design, which is why reading 4b's contender floor does not apply to it.
	R1 ArmSummary
	// Shared is the control: both tenants on one engine with the whole card.
	Shared ArmSummary
	// Sharing holds the split arms in the study's order.
	Sharing []ArmSummary
	// Refused records, per arm name, why the runner declined to replay it -- the MPS control daemon being
	// unreachable being the case reading 4c is about.
	//
	// It is a map rather than an inference from a missing arm, because "this arm is absent" and "this arm
	// refused for a stated reason" are different facts and only the second is reading 4c. An arm that is
	// simply not there could equally be an interruption, and calling that a sharing-mode failure would be
	// describing a quantity by a cause the ledger does not establish.
	Refused map[string]string
}

// SharingResult is the ordered readings plus the one that answered.
type SharingResult struct {
	Readings []PoPReading
	// Answer is the first reading that fired, or "" when none did.
	Answer string
}

// sharingScored is one split arm measured against every bar, so no two readings recompute a ratio and
// disagree about the same arm.
type sharingScored struct {
	ArmSummary
	ttft, tpot   float64
	contenderRel float64
	ttftOK       bool
	tpotOK       bool
	// starved is reading 2's condition: the contender lost work AND the ledger shows it was refused or
	// discarded rather than merely late.
	starved bool
	// starvationUnknown marks an arm whose ledger cannot tell deletion from delay.
	starvationUnknown bool
	computable        bool
	why               string
}

// EvaluateSharingMatrix scores the matrix against the pre-registered readings, in the registered order.
//
// premiumTenant and contenderTenant are passed rather than assumed, for the reason the price-of-protection
// evaluator gives: a reading that hard-codes a tenant name goes quietly wrong the first time a trace
// renames one.
func EvaluateSharingMatrix(a SharingArms, premiumTenant, contenderTenant string) SharingResult {
	var res SharingResult

	// Readings 4 and 4b short-circuit, because each one says the TRACE rather than the topology is what has
	// to change. Scoring arms underneath either would be scoring comparisons that do not mean anything.
	for _, r := range []PoPReading{
		sharingReadingFour(a.R1, a.Shared),
		sharingReadingFourB(a, premiumTenant, contenderTenant),
	} {
		res.Readings = append(res.Readings, r)
		if r.Fired || r.NotEvaluable {
			res.Answer = answerOf(r)
			return res
		}
	}

	// 4c does NOT short-circuit, and the difference is in its own name: "INVALID for that arm". A refused
	// MPS arm says nothing about the time-slicing arm beside it, and stopping here would throw away a
	// measurement that was made and paid for. The refused arm is absent from a.Sharing already -- the runner
	// declines it before replay -- so excluding it from the scoring needs no further step.
	res.Readings = append(res.Readings, sharingReadingFourC(a))

	all := scoreSharingArms(a, premiumTenant, contenderTenant)
	res.Readings = append(res.Readings,
		sharingReadingOne(a.R1, all),
		sharingReadingTwo(all, contenderTenant),
		sharingReadingThree(a.Shared, all),
		sharingReadingFive(a.Shared, all),
	)

	for _, r := range res.Readings {
		if r.Fired {
			res.Answer = answerOf(r)
			break
		}
	}
	return res
}

// armNotScorable says, in words, why an arm cannot be held against the bars -- or "" when it can.
func armNotScorable(c ArmSummary, premiumTenant string) string {
	switch {
	case c.TTFTMsP99 <= 0:
		return fmt.Sprintf("%s completed no premium requests, so it has no tail to hold against a bar", c.Arm)
	case c.TPOTMsP99ByTenant[premiumTenant] <= 0:
		return fmt.Sprintf("%s has no premium TPOT, so the stream bar cannot be applied to it", c.Arm)
	case c.TailSampleSize < MinTailSamples:
		return fmt.Sprintf("%s has %d premium completions, below the %d a nearest-rank p99 needs to be anything but the maximum",
			c.Arm, c.TailSampleSize, MinTailSamples)
	case c.Censored:
		return fmt.Sprintf("%s has a censored tail, which is a lower bound rather than a p99", c.Arm)
	}
	return ""
}

func scoreSharingArms(a SharingArms, premiumTenant, contenderTenant string) []sharingScored {
	sharedContender := shareOf(a.Shared, contenderTenant)
	out := make([]sharingScored, 0, len(a.Sharing))
	for _, c := range a.Sharing {
		s := sharingScored{ArmSummary: c}
		s.ttft = ratioOr(c.TTFTMsP99, a.R1.TTFTMsP99)
		s.tpot = ratioOr(c.TPOTMsP99ByTenant[premiumTenant], a.R1.TPOTMsP99ByTenant[premiumTenant])
		s.contenderRel = ratioOr(shareOf(c, contenderTenant), sharedContender)

		// The arm's OWN numerators are checked, not only the denominators.
		//
		// price_of_protection.go records what happens otherwise, and it is the worst wrong number either
		// file could print: percentile() returns 0 for an empty slice, so an arm whose premium requests all
		// timed out arrives with TTFTMsP99 = 0, and 0/100 clears a 2x bar while 0 clears a 1.25x one. The
		// arm that starved the protected tenant completely would be reported as the one that protected it.
		s.computable = a.R1.TTFTMsP99 > 0 && a.R1.TPOTMsP99ByTenant[premiumTenant] > 0 &&
			sharedContender > 0 &&
			c.TTFTMsP99 > 0 && c.TPOTMsP99ByTenant[premiumTenant] > 0 &&
			c.TailSampleSize >= MinTailSamples && !c.Censored
		s.why = armNotScorable(c, premiumTenant)
		s.ttftOK = s.ttft <= m5cTTFTBar
		s.tpotOK = s.tpot <= m5cTPOTBar

		// Starvation is TWO conditions, and the pre-registration is explicit that the second is required:
		// "Starvation must be shown, not inferred from a smaller number." A share that fell because work was
		// delayed is a different finding from one that fell because work was refused.
		if s.contenderRel < m5cContenderShareBar {
			d, ok := c.DispositionByTenant[contenderTenant]
			switch {
			case !ok:
				s.starvationUnknown = true
			case d.Rejected+d.Failed > 0:
				s.starved = true
			}
		}
		out = append(out, s)
	}
	return out
}

// sharingReadingFour: the load made no contention, so nothing below it measures protection.
func sharingReadingFour(r1, shared ArmSummary) PoPReading {
	r := PoPReading{ID: "4", Name: "the load did not create contention -- INVALID"}
	if r1.TTFTMsP99 <= 0 {
		r.NotEvaluable = true
		r.Detail = "R1 has no premium tail, so there is no baseline to hold the control against"
		return r
	}
	if shared.TTFTMsP99 <= 0 {
		r.NotEvaluable = true
		r.Detail = "the `shared` control completed no premium requests, so whether it produced contention cannot be read from its tail"
		return r
	}
	ratio := shared.TTFTMsP99 / r1.TTFTMsP99
	r.Fired = ratio < m5cContentionBar
	r.Detail = fmt.Sprintf("the control's premium TTFT p99 is %.1fx R1's (%.1f ms against %.1f ms), against an INVALID threshold of %.1fx",
		ratio, shared.TTFTMsP99, r1.TTFTMsP99, m5cContentionBar)
	return r
}

// sharingReadingFourB: the load was too high for any arm to be measured.
//
// Applied to every ARM of the matrix and not only the control, because a split card gives each engine less
// to work with and an arm collapsing is a live outcome for the arm itself.
//
// R1 is exempt from the CONTENDER clause and only that clause. It is the isolated premium baseline: it has
// no contender by construction, so requiring a hundred contender completions of it would fire this reading
// on every run that was working perfectly. Its premium floor still applies, because R1 is the denominator of
// both bars and a baseline built on fewer than a hundred completions is the slowest request wearing a
// percentile's name.
func sharingReadingFourB(a SharingArms, premiumTenant, contenderTenant string) PoPReading {
	r := PoPReading{ID: "4b", Name: "the load was too high to measure -- INVALID"}
	var thin []string

	check := func(s ArmSummary, wantContender bool) {
		if s.Arm == "" {
			return
		}
		if s.TailSampleSize < MinTailSamples {
			thin = append(thin, fmt.Sprintf("%s completed %d %s requests", s.Arm, s.TailSampleSize, premiumTenant))
		}
		if !wantContender {
			return
		}
		d, ok := s.DispositionByTenant[contenderTenant]
		if !ok {
			thin = append(thin, fmt.Sprintf("%s carries no disposition for %s at all", s.Arm, contenderTenant))
			return
		}
		if d.Completed < MinTailSamples {
			thin = append(thin, fmt.Sprintf("%s completed %d %s requests", s.Arm, d.Completed, contenderTenant))
		}
	}

	check(a.R1, false)
	check(a.Shared, true)
	for _, s := range a.Sharing {
		check(s, true)
	}

	if len(thin) == 0 {
		r.Detail = fmt.Sprintf("every arm completed at least %d requests for both tenants", MinTailSamples)
		return r
	}
	r.Fired = true
	r.Detail = fmt.Sprintf("against a floor of %d: %s", MinTailSamples, strings.Join(thin, "; "))
	return r
}

// sharingReadingFourC: a sharing mode did not engage, which makes that arm the other one under its name.
//
// hack/m5c-matrix.sh refuses an MPS arm whose control daemon never became ready rather than replaying it,
// so the evidence for this reading is a recorded refusal and not a number. The reading exists so that
// refusal is a registered outcome rather than a detail buried in a run log.
//
// An arm that is absent with NO recorded refusal is NotEvaluable, not fired. Absence is equally consistent
// with an interruption, a deadline that ran out on a cell boundary, or an operator running a subset with
// ARMS=; calling any of those a sharing-mode failure would be attributing a result to a cause the evidence
// does not establish.
func sharingReadingFourC(a SharingArms) PoPReading {
	r := PoPReading{ID: "4c", Name: "the sharing mode did not engage -- INVALID for that arm"}

	present := map[string]bool{}
	for _, s := range a.Sharing {
		present[s.Arm] = true
	}
	var refused, missing []string
	for _, arm := range []string{ArmTimeSlicing, ArmMPS} {
		if why, ok := a.Refused[arm]; ok && why != "" {
			refused = append(refused, fmt.Sprintf("%s: %s", arm, why))
			continue
		}
		if !present[arm] {
			missing = append(missing, arm)
		}
	}
	if len(refused) > 0 {
		r.Fired, r.Cell = true, strings.SplitN(refused[0], ":", 2)[0]
		r.Detail = strings.Join(refused, "; ")
		return r
	}
	if len(missing) > 0 {
		r.NotEvaluable = true
		r.Detail = fmt.Sprintf("no evidence for %s and no recorded refusal either; absence alone does not say the mode failed to engage, and the run log is what distinguishes a refusal from an interruption",
			strings.Join(missing, " and "))
		return r
	}
	r.Detail = "both sharing arms produced evidence and neither was refused"
	return r
}

// sharingReadingOne: separation protects, and this is the deliverable.
//
// THREE clauses, not two. The tail bar, the stream bar, and NOT reading 2's starvation -- because reading 2's
// condition is otherwise a strict subset of this one, and "the first that fires is the answer" would report
// an arm that bought its tail by taking the other tenant's work as POSITIVE with reading 2 never reached.
// The pre-registration was corrected for this on 2026-09-10, before any card, and says so.
func sharingReadingOne(r1 ArmSummary, all []sharingScored) PoPReading {
	r := PoPReading{ID: "1", Name: "separation protects -- POSITIVE"}
	if countSharingScorable(all) == 0 && len(all) > 0 {
		r.NotEvaluable = true
		r.Detail = "no sharing arm could be scored against the bars" + sharingUnscorableSuffix(all)
		return r
	}
	var won *sharingScored
	for i := range all {
		s := &all[i]
		if !s.computable || !s.ttftOK || !s.tpotOK || s.starved || s.starvationUnknown {
			continue
		}
		// Higher contender throughput wins. An EXACT tie goes to timeSlicing, because MPS needs a control
		// daemon that can be absent and the simpler mechanism is the smaller claim.
		switch {
		case won == nil:
			won = s
		case s.contenderRel > won.contenderRel:
			won = s
		case s.contenderRel == won.contenderRel && s.Arm == ArmTimeSlicing:
			won = s
		}
	}
	if won == nil {
		r.Detail = "no sharing arm held both bars with the contender's work intact" + sharingUnscorableSuffix(all)
		return r
	}
	r.Fired, r.Cell = true, won.Arm
	// THE PRICE IS IN THE HEADLINE, because the pre-registration requires it: "Protection that costs half
	// the machine is a real answer and a different product from one that costs a tenth, and a pass/fail line
	// would report them identically."
	price := ratioOr(won.OutputTokensPerSecond, r1.OutputTokensPerSecond)
	r.Detail = fmt.Sprintf("%s holds the premium tail at %.2fx R1 and the stream at %.2fx, with the contender at %.2f of its output under `shared`; it runs at %.2f of R1's throughput",
		won.Arm, won.ttft, won.tpot, won.contenderRel, price)
	return r
}

// sharingReadingTwo: the tail was bought by starving the contender.
func sharingReadingTwo(all []sharingScored, contenderTenant string) PoPReading {
	r := PoPReading{ID: "2", Name: "separation protects only by starving the contender -- NEGATIVE"}
	var metBars []*sharingScored
	for i := range all {
		if all[i].computable && all[i].ttftOK && all[i].tpotOK {
			metBars = append(metBars, &all[i])
		}
	}
	if len(metBars) == 0 {
		r.Detail = "no sharing arm met both bars, so this reading does not apply; that is reading 3 or 5" + sharingUnscorableSuffix(all)
		return r
	}
	for _, s := range metBars {
		if s.starvationUnknown {
			r.NotEvaluable = true
			r.Detail = fmt.Sprintf("%s carries no per-tenant disposition for %s, and a smaller share is equally consistent with deletion, delay and starvation",
				s.Arm, contenderTenant)
			return r
		}
		if s.starved {
			r.Fired, r.Cell = true, s.Arm
			d := s.DispositionByTenant[contenderTenant]
			r.Detail = fmt.Sprintf("%s met both bars with %s at %.2f of its output under `shared`, and the ledger shows %d rejected and %d failed against %d timed out -- refused work, not merely late work",
				s.Arm, contenderTenant, s.contenderRel, d.Rejected, d.Failed, d.TimedOut)
			return r
		}
	}
	r.Detail = fmt.Sprintf("every arm that met both bars kept %s's work", contenderTenant)
	return r
}

// sharingReadingThree: splitting the card changes nothing that matters.
//
// The threshold is `shared`'s own repetition-to-repetition spread. With fewer than two repetitions there IS
// no spread, so this declines rather than reporting every arm as failing to beat noise nobody measured.
func sharingReadingThree(shared ArmSummary, all []sharingScored) PoPReading {
	r := PoPReading{ID: "3", Name: "splitting the card changes nothing that matters -- INCONCLUSIVE"}
	if countSharingScorable(all) == 0 && len(all) > 0 {
		r.NotEvaluable = true
		r.Detail = "no sharing arm could be scored against the bars" + sharingUnscorableSuffix(all)
		return r
	}
	best, spread, ok := bestImprovementOverShared(shared, all)
	if !ok {
		r.NotEvaluable = true
		r.Detail = fmt.Sprintf("`shared` carries %d per-repetition tail(s); its repetition-to-repetition spread is what this reading compares against and needs at least 2",
			len(shared.RepetitionTTFTMsP99))
		return r
	}
	r.Fired = best <= spread
	r.Detail = fmt.Sprintf("the best sharing arm improves the control's premium TTFT p99 by %.1f ms against a repetition-to-repetition spread of %.1f ms",
		best, spread)
	return r
}

// sharingReadingFive: it protects, but not to the bar.
//
// This is the reading the previous study had no name for. Its readings required either that some cell met
// the bar or that no cell beat the control; the evidence landed between them and nothing fired. Here that
// gap is closed in advance rather than after seeing which way the numbers went.
func sharingReadingFive(shared ArmSummary, all []sharingScored) PoPReading {
	r := PoPReading{ID: "5", Name: "it protects but not to the bar -- measured partial result"}
	if countSharingScorable(all) == 0 && len(all) > 0 {
		r.NotEvaluable = true
		r.Detail = "no sharing arm could be scored against the bars" + sharingUnscorableSuffix(all)
		return r
	}
	best, spread, ok := bestImprovementOverShared(shared, all)
	if !ok {
		r.NotEvaluable = true
		r.Detail = fmt.Sprintf("`shared` carries %d per-repetition tail(s), so there is no spread to call an improvement real against",
			len(shared.RepetitionTTFTMsP99))
		return r
	}
	for i := range all {
		if all[i].computable && all[i].ttftOK {
			r.Detail = fmt.Sprintf("%s met the 2x tail bar, so this reading does not apply", all[i].Arm)
			return r
		}
	}
	if best <= spread {
		r.Detail = fmt.Sprintf("no arm improved on the control by more than its %.1f ms spread, which is reading 3 rather than this one", spread)
		return r
	}
	r.Fired = true
	var closest *sharingScored
	for i := range all {
		if !all[i].computable {
			continue
		}
		if closest == nil || all[i].ttft < closest.ttft {
			closest = &all[i]
		}
	}
	r.Cell = closest.Arm
	r.Detail = fmt.Sprintf("%s improves the control's premium tail by %.1f ms against a %.1f ms spread, and still sits at %.1fx R1 against a %.1fx bar -- a real improvement that does not reach the bar",
		closest.Arm, best, spread, closest.ttft, m5cTTFTBar)
	return r
}

// bestImprovementOverShared returns the largest premium-tail improvement any scorable arm makes on the
// control, and the control's own repetition spread to judge it against.
//
// Only SCORABLE arms count. An arm whose premium requests all timed out has a TTFTMsP99 of 0, which would
// otherwise register as the largest improvement of all.
func bestImprovementOverShared(shared ArmSummary, all []sharingScored) (best, spread float64, ok bool) {
	spread, ok = repetitionSpread(shared.RepetitionTTFTMsP99)
	if !ok {
		return 0, 0, false
	}
	for i := range all {
		if !all[i].computable {
			continue
		}
		if imp := shared.TTFTMsP99 - all[i].TTFTMsP99; imp > best {
			best = imp
		}
	}
	return best, spread, true
}

func countSharingScorable(all []sharingScored) int {
	n := 0
	for i := range all {
		if all[i].computable {
			n++
		}
	}
	return n
}

// sharingUnscorableSuffix names what could not be scored, so a reading that did not fire says whether it
// looked at everything or at nothing.
func sharingUnscorableSuffix(all []sharingScored) string {
	var why []string
	for i := range all {
		if !all[i].computable && all[i].why != "" {
			why = append(why, all[i].why)
		}
	}
	if len(why) == 0 {
		return ""
	}
	sort.Strings(why)
	return " (" + strings.Join(why, "; ") + ")"
}

// FormatSharingMatrix renders the readings in the order they were evaluated.
func FormatSharingMatrix(res SharingResult) string {
	var b strings.Builder
	b.WriteString("PRE-REGISTERED READINGS (docs/superpowers/specs/2026-09-10-does-splitting-the-card-buy-protection.md)\n")
	for _, r := range res.Readings {
		mark := "     "
		switch {
		case r.Fired:
			mark = "FIRED"
		case r.NotEvaluable:
			mark = " N/E "
		}
		fmt.Fprintf(&b, "  [%s] %-3s %s\n", mark, r.ID, r.Name)
		if r.Detail != "" {
			b.WriteString("          " + r.Detail + "\n")
		}
	}
	if res.Answer == "" {
		b.WriteString("\nANSWER: none of the readings fired. That is not a result; it is a gap in the outcome space,\n")
		b.WriteString("and the pre-registration says what to do about one rather than leaving it to a reader.\n")
	} else {
		b.WriteString("\nANSWER: " + res.Answer + "\n")
	}
	return b.String()
}
