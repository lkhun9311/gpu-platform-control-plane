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

package queuelab

import "fmt"

// The three rows of the reclaim trace, named so the protocol can address them without positional guessing.
//
// OwnRow holds tenant-a's own nominal unit for the whole run, VictimRow borrows tenant-b's idle unit and is
// the row the preemption targets, and OwnerRow is tenant-b returning to reclaim it.
const (
	OwnRow    = "a1"
	VictimRow = "a2-borrow"
	OwnerRow  = "b1-owner"
)

// Arm is the closed set of experimental conditions.
//
// It is an enum rather than a free-form study/variant pair because the previous design let any combination
// of knobs be requested, which is how an arm that the experiment never defined could still be run.
type Arm string

const (
	// ArmAHonor is reclamation enabled against a workload that stops when asked.
	ArmAHonor Arm = "A-honor"
	// ArmAIgnore is reclamation enabled against a workload that ignores the request; the contrast arm.
	ArmAIgnore Arm = "A-ignore"
	// ArmNRef is the no-reclamation reference, with workloads identical to A-honor.
	ArmNRef Arm = "N-ref"
	// ArmDFull and ArmDQuarter are the idling study, whose only axis is how much of its service the victim
	// spends computing.
	//
	// They exist because the first hardware session could not decide the reading it was built to decide.
	// Reserved GPU-seconds and observed device-seconds agreed to within a tenth of the run's floor, which
	// sounds like reservation being a good proxy for use and is not evidence of it: the trace workload
	// computes continuously by construction, so agreement was the only answer available. These two arms plant
	// a difference and ask whether the instrument recovers it.
	//
	// The termination contract is FIXED across them, at the ignoring arm's, and that is the whole point of
	// keeping this separate from the reclaim study. Two axes at once would give four cells and a session
	// twice as long, and any difference would carry both. Here the contract is a constant and the duty is the
	// only thing that moves. The ignoring contract is chosen rather than the honouring one because its hold
	// is tens of seconds rather than milliseconds, so the observer has samples inside it.
	ArmDFull    Arm = "D-full"
	ArmDQuarter Arm = "D-quarter"
	// ArmEFresh and ArmEResume are the resume study, whose only axis is whether the victim READS the progress
	// it has been writing all along.
	//
	// Both checkpoint. That is what makes this a pair rather than a single arm measured against A-ignore:
	// the checkpoint costs an open, a write, an fsync and a rename on every iteration, so an arm that writes
	// nothing differs from a resuming one in two ways at once, and a difference in discarded work could be
	// either. E-fresh pays the full cost and recovers nothing, which is the only control the question admits.
	//
	// The termination contract is FIXED across them at the ignoring arm's and the duty at full, for the
	// reason the idling pair fixes its contract: one axis moves, or the difference carries both.
	//
	// docs/superpowers/specs/2026-09-21-the-resume-arms-and-what-they-contrast.md registers what they measure
	// and what would make the measurement invalid, including the four things that had to exist before a card
	// could be bought for them.
	ArmEFresh  Arm = "E-fresh"
	ArmEResume Arm = "E-resume"
)

// StatePlan is what an arm decides about one row's progress file.
//
// Two booleans rather than one, because "writes a checkpoint" and "reads the one it finds" are independent
// and the pair exists precisely to hold the first constant while the second moves. A single flag could not
// express E-fresh at all: it writes every iteration and restores nothing.
//
// Restore without Checkpoint is not a state any arm can ask for, and StateFor never returns it -- a run that
// read a file it never wrote would be resuming somebody else's work.
type StatePlan struct {
	// Checkpoint is whether the row's workload is given a path to save its progress to.
	Checkpoint bool
	// Restore is whether it reads that path at startup rather than beginning at zero.
	Restore bool
}

// VariantAny and VariantNever are the two values of Kueue's reclaimWithinCohort that this lab sets.
//
// Constants because the string is a VOCABULARY crossing three places that must agree: PolicyVariant produces
// it, reclaimFixtures switches on it to choose a kueuev1beta2.PreemptionPolicy, and it is stamped into
// fixture names and labels. A literal repeated across those is the drift this repository keeps being caught
// by -- one of them edited and the others not, with nothing failing to compile and a run rendering the wrong
// preemption policy under the right label.
//
// They are also what goconst asked for. The linter counted the copies and was right to; the same finding on
// internal/queuelab/provenance.go was closed the same way in 7c5063a, and the note in .custom-gcl.yml
// records that this gate reports such findings in CI while a local run of the same tree does not. That makes
// CI the only instrument here, so the fix is to remove the duplication rather than to argue with the count.
const (
	VariantAny   = "Any"
	VariantNever = "Never"
)

// PolicyVariant returns the ClusterQueue reclaimWithinCohort setting this arm applies.
func (a Arm) PolicyVariant() (string, error) {
	switch a {
	case ArmAHonor, ArmAIgnore, ArmDFull, ArmDQuarter, ArmEFresh, ArmEResume:
		return VariantAny, nil
	case ArmNRef:
		return VariantNever, nil
	default:
		return "", fmt.Errorf("unknown arm %q", a)
	}
}

// StateFor returns what this arm decides about one row's progress file.
//
// Per row for the reason ContractFor and DutyFor are: the treatment is the VICTIM's behaviour. Checkpointing
// the owner and the co-tenant would put the write cost into every manifest and leave a difference between
// arms attributable to three rows instead of one.
//
// Every arm but the resume pair checkpoints nothing, which is what every run this lab has taken did, and the
// zero value of StatePlan says so.
func (a Arm) StateFor(rowName string) (StatePlan, error) {
	switch rowName {
	case OwnRow, VictimRow, OwnerRow:
	default:
		return StatePlan{}, fmt.Errorf("unknown trace row %q", rowName)
	}
	if _, err := a.PolicyVariant(); err != nil {
		return StatePlan{}, err
	}
	if rowName != VictimRow {
		return StatePlan{}, nil
	}
	switch a {
	case ArmEFresh:
		return StatePlan{Checkpoint: true}, nil
	case ArmEResume:
		return StatePlan{Checkpoint: true, Restore: true}, nil
	default:
		return StatePlan{}, nil
	}
}

// ContractFor returns the termination contract this arm renders for one trace row.
//
// The contract is per row rather than per arm because the treatment under test is the VICTIM's behaviour.
// An arm-wide switch would change all three manifests at once, so a difference in the owner's or a1's
// manifest could not be distinguished from the difference the experiment intends to measure.
func (a Arm) ContractFor(rowName string) (TerminationContract, error) {
	switch rowName {
	case OwnRow, VictimRow, OwnerRow:
	default:
		return "", fmt.Errorf("unknown trace row %q", rowName)
	}
	if _, err := a.PolicyVariant(); err != nil {
		return "", err
	}
	if rowName == VictimRow {
		switch a {
		// The idling arms hold the contract constant at the ignoring one, so the only thing that differs
		// between them is the duty. A honouring victim would stop in milliseconds and leave the observer
		// nothing to see inside the hold, which is the defect that invalidated a measured run once already.
		//
		// The resume pair holds it at the same value for the same reason, and for one more: a victim that
		// stopped in milliseconds would have written almost no checkpoint and lost almost no work, so the
		// quantity the pair exists to move would be too small to see whichever arm it ran under.
		case ArmAIgnore, ArmDFull, ArmDQuarter, ArmEFresh, ArmEResume:
			return IgnoresSIGTERM, nil
		}
	}
	return HonorsSIGTERM, nil
}

// DutyFor returns the fraction of its service this arm's row spends computing.
//
// Per row for the reason ContractFor is per row: the treatment is the VICTIM's behaviour, and an arm-wide
// duty would idle the owner and the co-tenant too. Their occupancy is not what any reading here is about,
// and changing three manifests when one is meant to differ is how a difference stops being attributable.
func (a Arm) DutyFor(rowName string) (DutyCycle, error) {
	switch rowName {
	case OwnRow, VictimRow, OwnerRow:
	default:
		return 0, fmt.Errorf("unknown trace row %q", rowName)
	}
	if _, err := a.PolicyVariant(); err != nil {
		return 0, err
	}
	if rowName != VictimRow {
		return FullDuty, nil
	}
	switch a {
	case ArmDQuarter:
		return QuarterDuty, nil
	default:
		return FullDuty, nil
	}
}

// AssertCardinality checks that a reconstructed run has the shape the protocol declares.
//
// It matters more than it looks: once causality is no longer inferred from cross-watch timestamps, the
// victim attempt is identified by BEING the only one open to the decision, so an unexpected count is not a
// cosmetic surprise — it means the pairing this arm relies on was not actually unambiguous.
func (a Arm) AssertCardinality(res LabResult) error {
	wantPreemptions := 1
	if a == ArmNRef {
		// Never must not reclaim; a preemption here means the applied policy was not the intended one.
		wantPreemptions = 0
	} else if _, err := a.PolicyVariant(); err != nil {
		return err
	}

	seen := map[string]WorkloadOutcome{}
	for _, o := range res.Outcomes {
		seen[o.Job] = o
	}
	for _, row := range []string{OwnRow, VictimRow, OwnerRow} {
		if _, ok := seen[row]; !ok {
			return fmt.Errorf("row %q is missing from the reconstruction", row)
		}
	}
	for _, row := range []string{OwnRow, OwnerRow} {
		if n := seen[row].Preemptions; n != 0 {
			return fmt.Errorf("row %q was preempted %d times; only the victim may be preempted", row, n)
		}
	}
	if n := seen[VictimRow].Preemptions; n != wantPreemptions {
		return fmt.Errorf("victim was preempted %d times, want %d for arm %s", n, wantPreemptions, a)
	}
	return nil
}
