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
	"strings"
	"testing"
)

// referenceArgs is the scheduler's argument list as measured on the live cluster, with --config removed.
//
// Taken from the running pod rather than invented: kubeadm supplies --authentication-kubeconfig,
// --authorization-kubeconfig, --bind-address, --kubeconfig and --leader-elect whether or not this study
// supplies anything, so those five are the environment both arms share.
var referenceArgs = []string{
	"kube-scheduler",
	"--authentication-kubeconfig=/etc/kubernetes/scheduler.conf",
	"--authorization-kubeconfig=/etc/kubernetes/scheduler.conf",
	"--bind-address=127.0.0.1",
	"--kubeconfig=/etc/kubernetes/scheduler.conf",
	"--leader-elect=true",
}

func loadedProtocol(t *testing.T) Protocol {
	t.Helper()
	p, err := LoadProtocol(protocolPath)
	if err != nil {
		t.Fatalf("the campaign's protocol does not load: %v", err)
	}
	return p
}

// honestReference is evidence from a cluster that really is running the reference arm.
func honestReference(p Protocol) ArmEvidence {
	return ArmEvidence{
		SchedulerArgs:      referenceArgs,
		SchedulerImage:     p.Images.Scheduler,
		Restarts:           0,
		ProfileFilePresent: ObservationNo,
		DemandScheduled:    ObservationYes,
	}
}

// honestTreatment is evidence from a cluster that really is running the treatment arm.
func honestTreatment(p Protocol) ArmEvidence {
	args := append([]string{}, referenceArgs...)
	args = append(args, "--config=/etc/kubernetes/stranded-scheduler.yaml")
	return ArmEvidence{
		SchedulerArgs:      args,
		SchedulerImage:     p.Images.Scheduler,
		Restarts:           0,
		ProfileFilePresent: ObservationYes,
		TreatmentApplied:   ObservationYes,
	}
}

// Both registered arms are qualified by honest evidence, so every refusal below is about the evidence.
func TestBothRegisteredArmsAreQualifiedByHonestEvidence(t *testing.T) {
	p := loadedProtocol(t)
	if err := p.QualifyArm(ArmUntouched, honestReference(p)); err != nil {
		t.Errorf("the reference arm was refused on honest evidence: %v", err)
	}
	if err := p.QualifyArm(ArmConfigured, honestTreatment(p)); err != nil {
		t.Errorf("the treatment arm was refused on honest evidence: %v", err)
	}
	if err := p.QualifyArm(ArmUnset, honestReference(p)); err == nil {
		t.Error("an unnamed arm was qualified; neither arm may be reached by defaulting")
	}
	if err := p.QualifyArm(Arm("S-tas"), honestReference(p)); err == nil {
		t.Error("S-tas was qualified; the first campaign registers two arms and TAS has its own page")
	}
}

// An omitted reading must be refused, never taken for "no".
//
// This is the case the three-state Observation exists for, and it is the one a bool could not express. The
// reference arm PASSES when the profile file is absent, so with `flag.Bool` an operator who simply did not look
// would supply false, the check would read that as "absent", and the arm would qualify on a reading nobody
// took. It is the unobserved-disposition failure the demand ledger guards against, arriving in a new place.
//
// Mutation that turns this red: make Observation.Validate accept ObservationUnobserved, or have the caller
// treat the zero value as ObservationNo.
func TestAnOmittedReadingIsNotEvidenceOfAbsence(t *testing.T) {
	p := loadedProtocol(t)
	for _, tc := range []struct {
		name   string
		mutate func(*ArmEvidence)
		wantIn string
	}{
		{
			name:   "nobody looked at whether a profile is mounted",
			mutate: func(e *ArmEvidence) { e.ProfileFilePresent = ObservationUnobserved },
			wantIn: "whether a profile file is mounted was not observed",
		},
		{
			name:   "nobody looked at whether demand scheduled",
			mutate: func(e *ArmEvidence) { e.DemandScheduled = ObservationUnobserved },
			wantIn: "whether submitted demand scheduled was not observed",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := honestReference(p)
			tc.mutate(&e)
			err := p.QualifyArm(ArmUntouched, e)
			if err == nil {
				t.Fatalf("the reference arm qualified while %s", tc.name)
			}
			if !strings.Contains(err.Error(), tc.wantIn) {
				t.Errorf("the refusal does not name the missing reading.\n  want: %s\n  got: %v", tc.wantIn, err)
			}
			if !strings.Contains(err.Error(), "never \"no\"") {
				t.Errorf("the refusal does not say why absence is not a reading: %v", err)
			}
		})
	}
	// The treatment's own required reading, for the same reason.
	e := honestTreatment(p)
	e.TreatmentApplied = ObservationUnobserved
	if err := p.QualifyArm(ArmConfigured, e); err == nil {
		t.Error("the treatment qualified with no check-treatment verdict observed")
	} else if !strings.Contains(err.Error(), "check-treatment's verdict was not observed") {
		t.Errorf("the refusal is not the unobserved one: %v", err)
	}
	// And a value that is neither reading is refused rather than silently falsy.
	e2 := honestReference(p)
	e2.ProfileFilePresent = Observation("maybe")
	if err := p.QualifyArm(ArmUntouched, e2); err == nil {
		t.Error("an Observation of \"maybe\" was accepted")
	}
}

// The reference arm is refused whenever anything was in fact supplied.
//
// Mutation that turns this red: drop any one of the four refusals in qualifyReference.
func TestTheReferenceArmIsRefusedWhenAnythingWasSupplied(t *testing.T) {
	p := loadedProtocol(t)
	for _, tc := range []struct {
		name   string
		mutate func(*ArmEvidence)
		wantIn string
	}{
		{
			name: "the scheduler was given a --config after all",
			mutate: func(e *ArmEvidence) {
				e.SchedulerArgs = append(append([]string{}, e.SchedulerArgs...),
					"--config=/etc/kubernetes/stranded-scheduler.yaml")
			},
			wantIn: "would misdescribe its own treatment",
		},
		{
			name:   "a profile file is mounted, as a stale artifact would leave it",
			mutate: func(e *ArmEvidence) { e.ProfileFilePresent = ObservationYes },
			wantIn: "installs the previous arm while every rendered artifact says",
		},
		{
			name:   "no submitted demand scheduled, so the scheduler is not working",
			mutate: func(e *ArmEvidence) { e.DemandScheduled = ObservationNo },
			wantIn: "is not a result about scheduling policy",
		},
		{
			name:   "a treatment-applied reading, which the reference cannot have",
			mutate: func(e *ArmEvidence) { e.TreatmentApplied = ObservationYes },
			wantIn: "there is no treatment of its to have applied",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := honestReference(p)
			tc.mutate(&e)
			err := p.QualifyArm(ArmUntouched, e)
			if err == nil {
				t.Fatalf("the reference arm qualified with %s", tc.name)
			}
			if !strings.Contains(err.Error(), tc.wantIn) {
				t.Errorf("the refusal does not explain itself.\n  want: %s\n  got: %v", tc.wantIn, err)
			}
		})
	}
}

// The treatment arm is refused when its profile was never supplied or never took.
//
// These are the two halves of the silent-treatment failure: a profile that was not passed at all, and one that
// was loaded and did not move a placement. Reading the configuration back would catch only the first.
//
// Mutation that turns this red: drop either refusal in qualifyTreatment.
func TestTheTreatmentArmIsRefusedWhenItsProfileNeverTook(t *testing.T) {
	p := loadedProtocol(t)
	noConfig := honestTreatment(p)
	noConfig.SchedulerArgs = referenceArgs
	err := p.QualifyArm(ArmConfigured, noConfig)
	if err == nil {
		t.Fatal("the treatment qualified with no --config supplied at all")
	}
	if !strings.Contains(err.Error(), "reports identical arms as a null result") {
		t.Errorf("the refusal does not name the null-result failure: %v", err)
	}

	notApplied := honestTreatment(p)
	notApplied.TreatmentApplied = ObservationNo
	err = p.QualifyArm(ArmConfigured, notApplied)
	if err == nil {
		t.Fatal("the treatment qualified with check-treatment reporting it did not apply")
	}
	if !strings.Contains(err.Error(), "only a moved placement says it acted") {
		t.Errorf("the refusal does not distinguish loaded from acted: %v", err)
	}
}

// Evidence that invalidates a cell whichever arm it is.
//
// Mutation that turns this red: drop any of the four shared checks in QualifyArm.
func TestSharedEvidenceInvalidatesEitherArm(t *testing.T) {
	p := loadedProtocol(t)
	for _, tc := range []struct {
		name   string
		mutate func(*ArmEvidence)
		wantIn string
	}{
		{
			name:   "an image the protocol does not register",
			mutate: func(e *ArmEvidence) { e.SchedulerImage = "registry.k8s.io/kube-scheduler-amd64:v1.35.8" },
			wantIn: "would masquerade as the arms' difference",
		},
		{
			name:   "no image observed at all",
			mutate: func(e *ArmEvidence) { e.SchedulerImage = "" },
			wantIn: "no scheduler image was observed",
		},
		{
			name:   "a scheduler that restarted during the cell",
			mutate: func(e *ArmEvidence) { e.Restarts = 8 },
			wantIn: "the rest under whatever it came back as",
		},
		{
			name:   "no arguments observed, which is not a reading of them",
			mutate: func(e *ArmEvidence) { e.SchedulerArgs = nil },
			wantIn: "an empty list is not a reading of it",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			for _, arm := range []Arm{ArmUntouched, ArmConfigured} {
				e := honestReference(p)
				if arm == ArmConfigured {
					e = honestTreatment(p)
				}
				tc.mutate(&e)
				err := p.QualifyArm(arm, e)
				if err == nil {
					t.Errorf("arm %s qualified with %s", arm, tc.name)
					continue
				}
				if !strings.Contains(err.Error(), tc.wantIn) {
					t.Errorf("arm %s: the refusal does not explain itself.\n  want: %s\n  got: %v",
						arm, tc.wantIn, err)
				}
			}
		})
	}
}

// A forbidden argument is matched by flag NAME, not by substring.
//
// The scheduler's real arguments are `--authentication-kubeconfig=...`, `--authorization-kubeconfig=...` and
// `--kubeconfig=...`. A substring search for a flag would match the wrong one of those three, and a search for
// `--config` would be satisfied by any flag whose VALUE happened to contain that text -- refusing a reference
// arm that had supplied nothing.
//
// Mutation that turns this red: compare with strings.Contains instead of splitting on the first "=".
func TestAForbiddenArgumentIsMatchedByFlagNameNotSubstring(t *testing.T) {
	p := loadedProtocol(t)
	// The honest reference already carries three flags ending in "kubeconfig" and none of them is --config.
	if err := p.QualifyArm(ArmUntouched, honestReference(p)); err != nil {
		t.Fatalf("the reference was refused over a flag that merely resembles one: %v", err)
	}
	// A flag whose value contains the forbidden text must not trigger the refusal either.
	e := honestReference(p)
	e.SchedulerArgs = append(append([]string{}, referenceArgs...), "--feature-gates=SomeGate=--config")
	if err := p.QualifyArm(ArmUntouched, e); err != nil {
		t.Errorf("a flag whose VALUE contains --config was read as supplying one: %v", err)
	}

	// Directly, so the helper's contract is pinned rather than inferred.
	if found, _ := hasSchedulerArg(referenceArgs, "--config"); found {
		t.Error("hasSchedulerArg found --config among arguments that carry none")
	}
	found, whole := hasSchedulerArg(honestTreatment(p).SchedulerArgs, "--config")
	if !found {
		t.Error("hasSchedulerArg missed a --config that is present")
	}
	if whole != "--config=/etc/kubernetes/stranded-scheduler.yaml" {
		t.Errorf("hasSchedulerArg returned %q rather than the whole argument, so a refusal could not quote it",
			whole)
	}
}

// An arm the protocol does not register cannot be qualified against it.
func TestAnArmAbsentFromTheProtocolCannotBeQualified(t *testing.T) {
	p := loadedProtocol(t)
	// Drop the reference from the loaded value rather than from the file, so this is about the lookup.
	trimmed := p
	trimmed.Arms = []ProtocolArm{}
	for _, a := range p.Arms {
		if Arm(a.Name) == ArmConfigured {
			trimmed.Arms = append(trimmed.Arms, a)
		}
	}
	if _, err := trimmed.ArmByName(ArmUntouched); err == nil {
		t.Error("an arm absent from the protocol was looked up successfully")
	}
	if err := trimmed.QualifyArm(ArmUntouched, honestReference(p)); err == nil {
		t.Error("an arm absent from the protocol was qualified")
	} else if !strings.Contains(err.Error(), "does not register arm") {
		t.Errorf("the refusal is not the missing-registration one: %v", err)
	}
}
