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
)

// Observation is a yes/no reading that must have been TAKEN, with no third meaning for "nobody looked".
//
// A bool will not do here, and the reason is specific rather than stylistic. The reference arm passes when the
// profile file is **absent**, so an unsupplied `flag.Bool` -- false -- would read as evidence that it is absent.
// The zero value would satisfy the very check it was meant to make, which is the unobserved-disposition failure
// the demand ledger already guards against, arriving in a new place.
type Observation string

const (
	// ObservationUnobserved is the zero value and is refused wherever the protocol requires the reading.
	ObservationUnobserved Observation = ""
	ObservationYes        Observation = "yes"
	ObservationNo         Observation = "no"
)

// Validate refuses a value that is neither reading, naming what was supposed to have been looked at.
func (o Observation) Validate(what string) error {
	switch o {
	case ObservationYes, ObservationNo:
		return nil
	case ObservationUnobserved:
		return fmt.Errorf("%s was not observed; the protocol requires this reading and an absent value means "+
			"\"nobody looked\", never \"no\"", what)
	default:
		return fmt.Errorf("%s is %q, which is neither %s nor %s", what, o, ObservationYes, ObservationNo)
	}
}

// Yes reports whether the reading was taken and was positive. Call only after Validate.
func (o Observation) Yes() bool { return o == ObservationYes }

// ArmEvidence is what a run operator read off a live cluster before a cell runs.
//
// Every field is an observation rather than an intention. The evidence is deliberately collected by the
// operator and judged here, the way check-treatment already works: the tool that decides whether an arm is what
// it claims does not also hold cluster credentials, so the judgement is reproducible from a recorded reading.
//
// All of it is available from the API without a credential beyond read access and without entering the node:
// the scheduler pod's spec.containers[0].command carries the arguments, spec.volumes carries any mounted
// profile, and status.containerStatuses[0] carries the image and the restart count. /configz would say what the
// scheduler *loaded*, but it binds 127.0.0.1 and answers system:anonymous with 403 -- and what this check needs
// is what was SUPPLIED, which the API states in plain text.
type ArmEvidence struct {
	// SchedulerArgs is the scheduler's argument list as the pod spec reports it, one element per argument.
	SchedulerArgs []string
	// SchedulerImage is the image the container is actually running, from its status rather than its spec.
	SchedulerImage string
	// Restarts is the scheduler container's restart count. The protocol invalidates a cell for any restart.
	Restarts int
	// ProfileFilePresent says whether a supplied KubeSchedulerConfiguration is mounted into the node.
	ProfileFilePresent Observation
	// DemandScheduled says whether submitted demand actually scheduled. Required for the reference arm: without
	// it, a reference whose scheduler was broken would strand everything and the figure would read as a result.
	DemandScheduled Observation
	// TreatmentApplied is check-treatment's verdict. Required for the treatment arm, meaningless for the
	// reference, and refused there rather than ignored.
	TreatmentApplied Observation
}

// ArmVerdict is qualify-arm's published answer, and the form a cell record carries it in.
//
// A named type rather than the anonymous struct the subcommand used to marshal inline: a cell record has to
// embed this verdict, and re-declaring its shape there would make the record format and the subcommand's output
// two statements of one fact with nothing comparing them.
type ArmVerdict struct {
	Arm       Arm    `json:"arm"`
	Qualified bool   `json:"qualified"`
	Image     string `json:"scheduler_image"`
	Restarts  int    `json:"restarts"`
	Reason    string `json:"reason,omitempty"`
}

// ArmByName returns the protocol's registration of one arm.
func (p Protocol) ArmByName(name Arm) (ProtocolArm, error) {
	if err := name.Validate(); err != nil {
		return ProtocolArm{}, err
	}
	for _, a := range p.Arms {
		if Arm(a.Name) == name {
			return a, nil
		}
	}
	return ProtocolArm{}, fmt.Errorf("the protocol does not register arm %s", name)
}

// QualifyArm refuses evidence that would not establish the cluster is running the arm it claims.
//
// The failure this exists for is a cell recorded as one arm while running the other. It is the silent-treatment
// failure read from both ends at once: a reference that quietly installed a profile, or a treatment whose
// profile never took, would both produce figures the campaign would compare as though the arms differed by what
// the registration says they differ by.
func (p Protocol) QualifyArm(name Arm, e ArmEvidence) error {
	arm, err := p.ArmByName(name)
	if err != nil {
		return err
	}

	// Shared evidence first, because it invalidates a cell whichever arm it is.
	if e.SchedulerImage == "" {
		return fmt.Errorf("no scheduler image was observed; the protocol requires the same image in every cell "+
			"and this host has more than one Kubernetes version installed, so an unrecorded image could move "+
			"between cells and read as the treatment (the protocol registers %s)", p.Images.Scheduler)
	}
	if e.SchedulerImage != p.Images.Scheduler {
		return fmt.Errorf("the scheduler is running %s and the protocol registers %s; a version difference "+
			"between cells would masquerade as the arms' difference", e.SchedulerImage, p.Images.Scheduler)
	}
	if e.Restarts != 0 {
		return fmt.Errorf("the scheduler has restarted %d time(s); the protocol invalidates a cell for a restart, "+
			"because a scheduler that crash-looped placed some of the demand under a configuration and the rest "+
			"under whatever it came back as", e.Restarts)
	}
	if len(e.SchedulerArgs) == 0 {
		return fmt.Errorf("no scheduler arguments were observed; whether a configuration was supplied is the " +
			"observable that separates the two arms, and an empty list is not a reading of it")
	}

	if !name.InstallsSchedulerConfig() {
		return qualifyReference(arm, e)
	}
	return qualifyTreatment(arm, e)
}

// qualifyReference checks the arm that installs nothing, behaviourally.
//
// The reference is qualified more weakly than the treatment and that asymmetry is registered: its effective
// configuration cannot be read here, so it is qualified by the absence of anything supplied plus demand that
// schedules -- never by predicting where the default scheduler would place a pod.
func qualifyReference(arm ProtocolArm, e ArmEvidence) error {
	for _, forbidden := range arm.Qualification.SchedulerArgsMustNotContain {
		if found, whole := hasSchedulerArg(e.SchedulerArgs, forbidden); found {
			return fmt.Errorf("arm %s is the reference and the scheduler was given %q; the reference installs no "+
				"configuration, so a cell recorded as %s while running a supplied profile would misdescribe its "+
				"own treatment", arm.Name, whole, arm.Name)
		}
	}
	if arm.Qualification.ProfileFileMustBeAbsent {
		if err := e.ProfileFilePresent.Validate("whether a profile file is mounted"); err != nil {
			return err
		}
		if e.ProfileFilePresent.Yes() {
			return fmt.Errorf("arm %s is the reference and a profile file is mounted; kind resolves extraMounts "+
				"by relative path, so a stale file in a reused directory installs the previous arm while every "+
				"rendered artifact says %s", arm.Name, arm.Name)
		}
	}
	if arm.Qualification.DemandMustSchedule {
		if err := e.DemandScheduled.Validate("whether submitted demand scheduled"); err != nil {
			return err
		}
		if !e.DemandScheduled.Yes() {
			return fmt.Errorf("arm %s is the reference and no submitted demand scheduled; a reference whose "+
				"scheduler is not working stranding everything is not a result about scheduling policy",
				arm.Name)
		}
	}
	// An observation that cannot belong to this arm is refused rather than ignored, the same way ArmProfile
	// refuses profile content on the reference: accepting it would let a run record evidence about the other arm.
	if e.TreatmentApplied != ObservationUnobserved {
		return fmt.Errorf("arm %s carries a treatment-applied reading (%s); the reference installs no profile, "+
			"so there is no treatment of its to have applied and this evidence is about something else",
			arm.Name, e.TreatmentApplied)
	}
	return nil
}

// qualifyTreatment checks the arm that supplies a profile.
func qualifyTreatment(arm ProtocolArm, e ArmEvidence) error {
	if found, _ := hasSchedulerArg(e.SchedulerArgs, "--config"); !found {
		return fmt.Errorf("arm %s is the treatment and the scheduler was given no --config; the profile was not "+
			"supplied at all, which is the failure that reports identical arms as a null result", arm.Name)
	}
	if arm.Qualification.CheckTreatmentMustReportApplied {
		if err := e.TreatmentApplied.Validate("check-treatment's verdict"); err != nil {
			return err
		}
		if !e.TreatmentApplied.Yes() {
			return fmt.Errorf("arm %s supplied a profile and check-treatment did not report it applied; reading "+
				"the configuration back says what the scheduler loaded, and only a moved placement says it acted",
				arm.Name)
		}
	}
	return nil
}

// hasSchedulerArg reports whether the argument list carries the named flag, and returns the whole element.
//
// Compared by flag NAME rather than by substring, because the arguments arrive as `--config=/etc/kubernetes/...`
// and `--authentication-kubeconfig=...` -- so a substring search for `--kubeconfig` would match the
// authentication flag, and one for `--config` would be satisfied by any flag whose value happened to contain
// that text. The name is everything before the first `=`.
func hasSchedulerArg(args []string, name string) (bool, string) {
	for _, a := range args {
		if strings.SplitN(a, "=", 2)[0] == name {
			return true, a
		}
	}
	return false, ""
}
