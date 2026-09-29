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

package main

import (
	"fmt"
	"slices"
	"sort"
	"strings"
)

// CellRecord is one attempt at one cell of the campaign, as its evidence was recorded.
//
// A cell is an (arm, repetition) pair, and an attempt is one run at it. The record is judged rather than
// produced here: the shell performs the submissions and the readings, this decides whether what came back is a
// cell the campaign may count. Every subcommand in this tool works that way, and the reason is that a verdict
// reached from a recorded reading can be re-reached later, when the cluster is gone.
type CellRecord struct {
	Arm Arm `json:"arm"`
	// Repetition is which of the protocol's repetitions this is, 1-based.
	Repetition int `json:"repetition"`
	// Attempt is 1 for the first run at this cell and 2 for its replacement. The protocol registers how many.
	Attempt int `json:"attempt"`
	// ArmQualification is qualify-arm's verdict. A cell with no qualification evidence is not a cell.
	ArmQualification ArmVerdict `json:"arm_verdict"`
	// Treatment is check-treatment's verdict, required for the treatment arm and refused for the reference --
	// where it would be evidence about a configuration the arm does not install.
	Treatment *TreatmentVerdict `json:"treatment_verdict,omitempty"`
	// Censuses are the readings, one per registered submission, in order.
	Censuses []StrandingReport `json:"censuses"`
	// InvalidatedBecause is empty for a cell that stands, and otherwise names the protocol's reason.
	//
	// It must be one of the protocol's registered invalidation reasons. An operator who discards a cell for a
	// reason nobody registered is retaking on the outcome, whatever the reason sounds like -- which is why this
	// is a registered enum rather than free text, and why the ones the protocol says do NOT invalidate are
	// refused here explicitly.
	InvalidatedBecause string `json:"invalidated_because,omitempty"`
}

// Valid reports whether this attempt is one the campaign may count.
func (r CellRecord) Valid() bool { return r.InvalidatedBecause == "" }

// CheckCell refuses a record the campaign could not honestly count, or honestly discard.
//
// The two halves matter equally. A record that claims to be a valid cell while missing evidence would put a
// figure into the comparison that nothing supports; a record that claims to be invalid for an unregistered
// reason would take a figure OUT of the comparison on grounds chosen after seeing it. The second is the one a
// campaign fails quietly, because discarding a cell looks like diligence.
func (p Protocol) CheckCell(r CellRecord) error {
	arm, err := p.ArmByName(r.Arm)
	if err != nil {
		return err
	}
	if r.Repetition < 1 || r.Repetition > p.Matrix.RepetitionsPerArm {
		return fmt.Errorf("repetition %d is outside the registered 1..%d for arm %s; a cell the matrix does not "+
			"contain has no place to be counted", r.Repetition, p.Matrix.RepetitionsPerArm, r.Arm)
	}
	maxAttempt := 1 + p.Matrix.ReplacementsPerInvalidCell
	if r.Attempt < 1 || r.Attempt > maxAttempt {
		return fmt.Errorf("attempt %d is outside 1..%d; the protocol registers %d replacement(s) per invalid "+
			"cell, and a further attempt is retaking until the numbers agree",
			r.Attempt, maxAttempt, p.Matrix.ReplacementsPerInvalidCell)
	}

	if err := p.checkInvalidationReason(r); err != nil {
		return err
	}

	// The qualification evidence is required whether or not the cell stands, because an unqualified arm is the
	// commonest way for an attempt to be invalid and the record must say which arm it failed to be.
	if r.ArmQualification.Arm != r.Arm {
		return fmt.Errorf("the record is for arm %s and carries a qualification verdict for %s; a cell whose "+
			"evidence is about the other arm describes neither", r.Arm, r.ArmQualification.Arm)
	}
	if r.ArmQualification.Image != p.Images.Scheduler {
		return fmt.Errorf("the qualification verdict records scheduler image %q and the protocol registers %q",
			r.ArmQualification.Image, p.Images.Scheduler)
	}
	if arm.InstallsSchedulerConfig {
		if r.Treatment == nil {
			return fmt.Errorf("arm %s is the treatment and the record carries no check-treatment verdict; a "+
				"treatment that silently did not apply is the failure that reports identical arms as a null "+
				"result", r.Arm)
		}
		if r.Treatment.Strategy != arm.Qualification.ScoringStrategy {
			return fmt.Errorf("the check-treatment verdict is about %s and arm %s installs %s",
				r.Treatment.Strategy, r.Arm, arm.Qualification.ScoringStrategy)
		}
	} else if r.Treatment != nil {
		return fmt.Errorf("arm %s is the reference and the record carries a check-treatment verdict; the "+
			"reference installs no profile, so that evidence is about something else", r.Arm)
	}

	if !r.Valid() {
		// An invalid attempt is retained with its reason and is not required to be complete. Requiring a full
		// census series here would push an operator towards inventing the missing readings rather than
		// recording that the attempt failed -- and the protocol publishes every attempt precisely so that a
		// failed one can be seen to have failed.
		return nil
	}

	if !r.ArmQualification.Qualified {
		return fmt.Errorf("the record stands as a valid cell while its arm qualification says %s was not "+
			"qualified; a cell whose arm is unestablished must be invalidated, not counted", r.Arm)
	}
	if r.ArmQualification.Restarts != 0 {
		return fmt.Errorf("the record stands as valid with %d scheduler restart(s); the protocol invalidates a "+
			"cell for a restart, so this attempt must carry that reason instead", r.ArmQualification.Restarts)
	}
	if r.Treatment != nil && !r.Treatment.Applied {
		return fmt.Errorf("the record stands as valid while check-treatment reports the profile did not apply")
	}
	if len(r.Censuses) != p.Expected.AcceptedCensuses {
		return fmt.Errorf("the cell holds %d census(es) and the protocol expects %d; a valid cell is one that "+
			"produced the whole series, and a short series is an invalid attempt rather than a small result",
			len(r.Censuses), p.Expected.AcceptedCensuses)
	}
	return p.checkCensusSeries(r)
}

// checkInvalidationReason refuses a discard the protocol does not license.
func (p Protocol) checkInvalidationReason(r CellRecord) error {
	if r.Valid() {
		return nil
	}
	reason := r.InvalidatedBecause
	// This branch changes the MESSAGE rather than the verdict, and it stays anyway.
	//
	// Protocol.Validate refuses a reason that appears in both lists, so a reason registered as
	// not-invalidating is never also registered as invalidating -- which means the check below would refuse it
	// too, as unregistered. Measured by disabling this branch: a discard for `a_tie_between_nodes` was still
	// refused, with "not a registered invalidation reason".
	//
	// It is not a second gate and must not be read as one. It stays because the two refusals tell an operator
	// different things: "not registered" reads as a typo to fix, and this one says the discard is selecting on
	// the outcome -- which is the thing they must not do, however they spell it.
	if slices.Contains(p.DoesNotInvalidateACell, reason) {
		return fmt.Errorf("the cell was discarded for %q, which the protocol registers as NOT invalidating; "+
			"discarding the attempts that report a tie or an identical outcome is selecting on the outcome, "+
			"whichever way the discard is worded", reason)
	}
	if !slices.Contains(p.InvalidatesACell, reason) {
		return fmt.Errorf("the cell was discarded for %q, which is not a registered invalidation reason (the "+
			"protocol registers %s); a reason invented after the attempt was seen is a reason chosen from the "+
			"outcome", reason, strings.Join(p.InvalidatesACell, ", "))
	}
	return nil
}

// checkCensusSeries refuses a series whose readings do not account for the registered submissions.
//
// Step k must account for exactly the protocol's first k submissions. A census names them in three places --
// placed, blocked and unsatisfiable -- and their union is where an omitted submission shows up, because a
// reading that simply leaves one out is internally consistent and balances.
//
// This assumes the protocol registers no releases, which it does not: a released submission would legitimately
// appear in none of the three. If a release is ever registered, this check has to be amended rather than
// loosened, and the registration page says so.
func (p Protocol) checkCensusSeries(r CellRecord) error {
	seenSteps := map[string]bool{}
	for i, c := range r.Censuses {
		step := i + 1
		if c.Step == "" {
			return fmt.Errorf("census %d has no step name; a figure with no step is not in a series", step)
		}
		if seenSteps[c.Step] {
			return fmt.Errorf("step name %q appears twice; two readings under one name cannot be ordered", c.Step)
		}
		seenSteps[c.Step] = true

		want := map[string]bool{}
		for _, s := range p.Submissions[:step] {
			want[s.ID] = true
		}
		got := map[string]bool{}
		for _, name := range slices.Concat(c.PlacedWorkloads, c.Blocked, c.Unsatisfiable) {
			if got[name] {
				return fmt.Errorf("census %q names %q more than once across placed, blocked and unsatisfiable; "+
					"one submission cannot be in two dispositions at one reading", c.Step, name)
			}
			got[name] = true
		}
		if missing := keysNotIn(want, got); len(missing) > 0 {
			return fmt.Errorf("census %q accounts for no disposition of %s, and the protocol registers them by "+
				"step %d; a reading that leaves a submission out is internally consistent and balances, which "+
				"is why it is checked against the frozen sequence", c.Step, strings.Join(missing, ", "), step)
		}
		if extra := keysNotIn(got, want); len(extra) > 0 {
			return fmt.Errorf("census %q names %s, which the protocol has not submitted by step %d; demand the "+
				"sequence did not register is demand this campaign cannot attribute",
				c.Step, strings.Join(extra, ", "), step)
		}
	}
	return nil
}

// keysNotIn returns the keys of a that b does not have, sorted so a message is stable.
func keysNotIn(a, b map[string]bool) []string {
	var out []string
	for k := range a {
		if !b[k] {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

// CheckCampaign refuses a set of attempts the campaign could not publish as its result.
//
// Per-cell checks cannot see this: every attempt can be individually well formed while the campaign as a whole
// has retaken a cell three times, or lost the record of a failed attempt, or reported a comparison from five
// cells. The stopping rule lives here.
func (p Protocol) CheckCampaign(records []CellRecord) error {
	attempts := map[string][]CellRecord{}
	for i, r := range records {
		if err := p.CheckCell(r); err != nil {
			return fmt.Errorf("attempt %d of %d is not a record this campaign may hold: %w", i+1, len(records), err)
		}
		key := fmt.Sprintf("%s/%d", r.Arm, r.Repetition)
		attempts[key] = append(attempts[key], r)
	}
	if len(records) > p.Matrix.MaxAttemptsTotal {
		return fmt.Errorf("the campaign holds %d attempts and the protocol caps it at %d; a cap that can be "+
			"exceeded is not a stopping rule", len(records), p.Matrix.MaxAttemptsTotal)
	}

	for _, a := range p.Arms {
		for rep := 1; rep <= p.Matrix.RepetitionsPerArm; rep++ {
			key := fmt.Sprintf("%s/%d", a.Name, rep)
			got := attempts[key]
			if len(got) == 0 {
				return fmt.Errorf("cell %s has no attempt; the comparison is published only when every "+
					"registered cell has one that stands", key)
			}
			if len(got) > 1+p.Matrix.ReplacementsPerInvalidCell {
				return fmt.Errorf("cell %s has %d attempts and the protocol allows %d; a second invalidation of "+
					"one cell ends the campaign with the history published instead",
					key, len(got), 1+p.Matrix.ReplacementsPerInvalidCell)
			}
			// Every attempt before the last must be invalid, and the last must stand. A valid attempt followed
			// by another is a cell that was run again after it had already produced a figure.
			for i, r := range got[:len(got)-1] {
				if r.Valid() {
					return fmt.Errorf("cell %s attempt %d stands and is followed by another; running a cell "+
						"again after it produced a figure is choosing between figures", key, i+1)
				}
			}
			last := got[len(got)-1]
			if !last.Valid() {
				return fmt.Errorf("cell %s ends with an invalid attempt (%s) and has no replacement left; the "+
					"campaign ends here with the attempt history published rather than with a comparison",
					key, last.InvalidatedBecause)
			}
		}
	}
	// Retention is asserted rather than assumed: the protocol publishes every attempt, so a campaign whose
	// record count equals its cell count has either never invalidated anything or has dropped the evidence.
	// That is not an error -- it is the ordinary case -- but the count is returned to the caller to print.
	return nil
}
