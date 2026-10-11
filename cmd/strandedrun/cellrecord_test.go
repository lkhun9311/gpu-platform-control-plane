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
	"strings"
	"testing"
)

// censusSeries builds the six readings a cell of this protocol must produce, accounting for s1..sk at step k.
//
// Built from the protocol's own submission list rather than from six literals, so that changing the registered
// sequence changes this fixture too instead of leaving it testing a sequence that no longer exists.
func censusSeries(p Protocol) []StrandingReport {
	out := make([]StrandingReport, 0, len(p.Submissions))
	for k := range p.Submissions {
		var placed, blocked []string
		for _, s := range p.Submissions[:k+1] {
			// The disposition does not matter to the membership check; what matters is that every registered
			// submission is accounted for somewhere. One-device requests are placed, larger ones blocked.
			if s.Request == 1 {
				placed = append(placed, s.ID)
			} else {
				blocked = append(blocked, s.ID)
			}
		}
		// Sprintf rather than string(rune('1'+k)), which is correct only while the sequence has fewer than
		// nine steps and would produce ':' for the tenth without anything noticing.
		out = append(out, StrandingReport{
			Step: fmt.Sprintf("c%d", k+1), PlacedWorkloads: placed, Blocked: blocked,
		})
	}
	return out
}

func validReferenceCell(p Protocol) CellRecord {
	return CellRecord{
		Arm: ArmUntouched, Repetition: 1, Attempt: 1,
		ArmQualification: ArmVerdict{Arm: ArmUntouched, Qualified: true, Image: p.Images.Scheduler},
		Censuses:         censusSeries(p),
	}
}

func validTreatmentCell(p Protocol, rep int) CellRecord {
	return CellRecord{
		Arm: ArmConfigured, Repetition: rep, Attempt: 1,
		ArmQualification: ArmVerdict{Arm: ArmConfigured, Qualified: true, Image: p.Images.Scheduler},
		Treatment:        &TreatmentVerdict{Strategy: MostAllocated, Observed: "stranded-worker", Applied: true},
		Censuses:         censusSeries(p),
	}
}

// Both arms' honest cells are accepted, so every refusal below is about the record rather than the fixture.
func TestAnHonestCellOfEitherArmIsAccepted(t *testing.T) {
	p := loadedProtocol(t)
	if err := p.CheckCell(validReferenceCell(p)); err != nil {
		t.Errorf("an honest reference cell was refused: %v", err)
	}
	if err := p.CheckCell(validTreatmentCell(p, 1)); err != nil {
		t.Errorf("an honest treatment cell was refused: %v", err)
	}
}

// A cell may not be discarded for a reason nobody registered, nor for one registered as NOT invalidating.
//
// This is the check the whole type exists for. A campaign fails quietly here rather than loudly: discarding an
// attempt looks like diligence, and an operator who discards the cells that came out level has selected on the
// outcome without ever writing down a threshold. So the reason is a registered enumeration and the list of
// reasons that do NOT invalidate is refused explicitly, in that order.
//
// Mutation that turns this red: accept any non-empty reason, or drop the DoesNotInvalidateACell check.
func TestACellMayNotBeDiscardedForAnUnregisteredReason(t *testing.T) {
	p := loadedProtocol(t)
	for _, tc := range []struct {
		name, reason, wantIn string
	}{
		{
			name:   "a reason invented after the attempt was seen",
			reason: "the numbers looked wrong",
			wantIn: "not a registered invalidation reason",
		},
		{
			name:   "a tie, which the protocol says leaves a cell valid",
			reason: "a_tie_between_nodes",
			wantIn: "selecting on the outcome",
		},
		{
			name:   "an identical outcome across arms, which is a result",
			reason: "an_identical_outcome_across_arms_or_repetitions",
			wantIn: "registers as NOT invalidating",
		},
		{
			name:   "a stranding figure of zero, which the instrument has already reported honestly",
			reason: "a_stranding_figure_of_zero",
			wantIn: "registers as NOT invalidating",
		},
		{
			// Close enough to a registered reason to pass a careless check, and not one of them.
			name:   "a near-miss of a registered reason",
			reason: "scheduler_restart",
			wantIn: "not a registered invalidation reason",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := validReferenceCell(p)
			r.InvalidatedBecause = tc.reason
			err := p.CheckCell(r)
			if err == nil {
				t.Fatalf("the cell was discarded for %q and the record was accepted", tc.reason)
			}
			if !strings.Contains(err.Error(), tc.wantIn) {
				t.Errorf("the refusal does not explain itself.\n  want: %s\n  got: %v", tc.wantIn, err)
			}
		})
	}

	// A registered reason IS accepted, and such an attempt is not required to be complete -- which is the
	// other half: demanding a full series from a failed attempt invites the missing readings to be supplied.
	r := validReferenceCell(p)
	r.InvalidatedBecause = "scheduler_restart_during_the_cell"
	r.ArmQualification.Qualified = false
	r.ArmQualification.Restarts = 8
	r.Censuses = nil
	if err := p.CheckCell(r); err != nil {
		t.Errorf("an attempt invalidated for a registered reason was refused: %v", err)
	}
}

// A record may not stand as valid while its own evidence says the cell failed.
//
// The mirror of the case above. Discarding a good cell takes a figure out of the comparison; counting a bad one
// puts in a figure nothing supports, and the record contradicts itself in both directions.
//
// Mutation that turns this red: drop any of the three consistency checks after the Valid() early return.
func TestARecordMayNotStandWhileItsEvidenceSaysOtherwise(t *testing.T) {
	p := loadedProtocol(t)
	for _, tc := range []struct {
		name   string
		mutate func(*CellRecord)
		wantIn string
	}{
		{
			name:   "an arm that was not qualified",
			mutate: func(r *CellRecord) { r.ArmQualification.Qualified = false },
			wantIn: "must be invalidated, not counted",
		},
		{
			name:   "a scheduler that restarted",
			mutate: func(r *CellRecord) { r.ArmQualification.Restarts = 1 },
			wantIn: "must carry that reason instead",
		},
		{
			name:   "a series shorter than the protocol expects",
			mutate: func(r *CellRecord) { r.Censuses = r.Censuses[:3] },
			wantIn: "a short series is an invalid attempt rather than a small result",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := validReferenceCell(p)
			tc.mutate(&r)
			err := p.CheckCell(r)
			if err == nil {
				t.Fatalf("a record standing as valid was accepted with %s", tc.name)
			}
			if !strings.Contains(err.Error(), tc.wantIn) {
				t.Errorf("the refusal does not explain itself.\n  want: %s\n  got: %v", tc.wantIn, err)
			}
		})
	}
	// The treatment's own contradiction.
	r := validTreatmentCell(p, 1)
	r.Treatment.Applied = false
	if err := p.CheckCell(r); err == nil {
		t.Error("a treatment cell stood as valid while check-treatment said the profile did not apply")
	}
}

// Each reading must account for exactly the protocol's first k submissions.
//
// A census that simply omits a submission is internally consistent and balances, so it is compared against the
// frozen sequence rather than checked for self-consistency. The union of placed, blocked and unsatisfiable is
// where the omission shows.
//
// Mutation that turns this red: check only the count, or only one of the three name lists.
func TestEachReadingMustAccountForTheRegisteredSubmissions(t *testing.T) {
	p := loadedProtocol(t)
	for _, tc := range []struct {
		name   string
		mutate func([]StrandingReport)
		wantIn string
	}{
		{
			name: "a submission left out of the last reading",
			mutate: func(cs []StrandingReport) {
				// Drop one blocked name. By the last step the protocol has registered every submission, so
				// removing one leaves a reading that still balances and is still internally consistent.
				last := &cs[len(cs)-1]
				last.Blocked = last.Blocked[:len(last.Blocked)-1]
			},
			wantIn: "accounts for no disposition of",
		},
		{
			name: "demand the sequence never registered",
			mutate: func(cs []StrandingReport) {
				cs[0].Blocked = append(cs[0].Blocked, "s9")
			},
			wantIn: "demand the sequence did not register",
		},
		{
			name: "one submission in two dispositions at once",
			mutate: func(cs []StrandingReport) {
				cs[0].Blocked = append(cs[0].Blocked, cs[0].PlacedWorkloads[0])
			},
			wantIn: "cannot be in two dispositions at one reading",
		},
		{
			name:   "a reading with no step name",
			mutate: func(cs []StrandingReport) { cs[2].Step = "" },
			wantIn: "not in a series",
		},
		{
			name:   "two readings under one name",
			mutate: func(cs []StrandingReport) { cs[3].Step = cs[2].Step },
			wantIn: "cannot be ordered",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := validReferenceCell(p)
			tc.mutate(r.Censuses)
			err := p.CheckCell(r)
			if err == nil {
				t.Fatalf("the series was accepted with %s", tc.name)
			}
			if !strings.Contains(err.Error(), tc.wantIn) {
				t.Errorf("the refusal does not explain itself.\n  want: %s\n  got: %v", tc.wantIn, err)
			}
		})
	}
}

// The reference may not carry treatment evidence, and the treatment may not lack it.
func TestTheArmsEvidenceMustBelongToTheArm(t *testing.T) {
	p := loadedProtocol(t)
	ref := validReferenceCell(p)
	ref.Treatment = &TreatmentVerdict{Strategy: MostAllocated, Observed: "w1", Applied: true}
	if err := p.CheckCell(ref); err == nil {
		t.Error("a reference cell carrying a check-treatment verdict was accepted")
	} else if !strings.Contains(err.Error(), "that evidence is about something else") {
		t.Errorf("the refusal is not the alien-evidence one: %v", err)
	}

	treat := validTreatmentCell(p, 1)
	treat.Treatment = nil
	if err := p.CheckCell(treat); err == nil {
		t.Error("a treatment cell with no check-treatment verdict was accepted")
	} else if !strings.Contains(err.Error(), "reports identical arms as a null result") {
		t.Errorf("the refusal does not name the null-result failure: %v", err)
	}

	wrongArm := validReferenceCell(p)
	wrongArm.ArmQualification.Arm = ArmConfigured
	if err := p.CheckCell(wrongArm); err == nil {
		t.Error("a record whose qualification verdict is about the other arm was accepted")
	} else if !strings.Contains(err.Error(), "describes neither") {
		t.Errorf("the refusal does not say the record describes neither arm: %v", err)
	}
}

// The stopping rule is a property of the campaign, not of any cell.
//
// Every attempt below is individually well formed. What is wrong is the set: a cell run again after it produced
// a figure, a cell retaken twice, a missing cell, and more attempts than the cap allows. No per-cell check can
// see any of it.
//
// Mutation that turns this red: drop the followed-by-another check, or the per-cell attempt cap.
func TestTheStoppingRuleIsCheckedAcrossTheCampaign(t *testing.T) {
	p := loadedProtocol(t)
	full := func() []CellRecord {
		var out []CellRecord
		for rep := 1; rep <= p.Matrix.RepetitionsPerArm; rep++ {
			ref := validReferenceCell(p)
			ref.Repetition = rep
			out = append(out, ref, validTreatmentCell(p, rep))
		}
		return out
	}
	if err := p.CheckCampaign(full()); err != nil {
		t.Fatalf("a complete honest campaign was refused: %v", err)
	}

	// A cell that stands, run again.
	again := full()
	extra := validReferenceCell(p)
	again = append(again, extra)
	if err := p.CheckCampaign(again); err == nil {
		t.Error("a cell was run again after it produced a figure and the campaign was accepted")
	} else if !strings.Contains(err.Error(), "choosing between figures") {
		t.Errorf("the refusal does not name the choice: %v", err)
	}

	// A cell retaken more often than the protocol allows.
	retaken := full()
	for range 2 {
		bad := validReferenceCell(p)
		bad.InvalidatedBecause = "scheduler_restart_during_the_cell"
		bad.ArmQualification.Qualified = false
		bad.Attempt = 2
		retaken = append(retaken, bad)
	}
	if err := p.CheckCampaign(retaken); err == nil {
		t.Error("a cell with three attempts was accepted")
	}

	// A missing cell.
	short := full()[:len(full())-1]
	if err := p.CheckCampaign(short); err == nil {
		t.Error("a campaign missing a cell was accepted")
	} else if !strings.Contains(err.Error(), "has no attempt") {
		t.Errorf("the refusal does not name the missing cell: %v", err)
	}

	// A cell whose last attempt is invalid: the campaign ends with the history, not a comparison.
	ended := full()
	ended[len(ended)-1].InvalidatedBecause = "pending_for_a_non_gpu_reason"
	ended[len(ended)-1].ArmQualification.Qualified = false
	if err := p.CheckCampaign(ended); err == nil {
		t.Error("a campaign whose last attempt at a cell is invalid was published as a comparison")
	} else if !strings.Contains(err.Error(), "attempt history published rather than with a comparison") {
		t.Errorf("the refusal does not say what happens instead: %v", err)
	}
}
