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

// Neither arm may be reached by defaulting, because they differ in what the run installs.
//
// Mutation that turns this red: treat ArmUnset as ArmUntouched, or accept an unknown value.
func TestAnArmMustBeNamedRatherThanDefaulted(t *testing.T) {
	if err := ArmUnset.Validate(); err == nil {
		t.Error("the zero value was accepted as an arm; an absent value has to mean \"nobody said\"")
	} else if !strings.Contains(err.Error(), "no arm was named") {
		t.Errorf("the refusal does not say why: %v", err)
	}
	if err := Arm("S-tas").Validate(); err == nil {
		t.Error("S-tas was accepted; the amendment deferred topology-aware scheduling to its own page and the " +
			"first campaign registers exactly two arms")
	}
	for _, a := range []Arm{ArmUntouched, ArmConfigured} {
		if err := a.Validate(); err != nil {
			t.Errorf("registered arm %s was refused: %v", a, err)
		}
	}
	if ArmUntouched.InstallsSchedulerConfig() {
		t.Error("the reference arm claims to install a scheduler configuration")
	}
	if !ArmConfigured.InstallsSchedulerConfig() {
		t.Error("the treatment arm claims to install nothing")
	}
}

// The reference arm must carry NO profile content, checked field by field.
//
// A run that recorded itself as the reference while installing something would misdescribe its own treatment --
// the silent-treatment failure read from the other end. Each field is its own case because the first version of
// this check used `!= empty`, which does not compile for a struct holding a slice and would have accepted any
// field added later without a word.
//
// Mutation that turns this red: drop any one of the three field tests.
func TestTheReferenceArmRefusesProfileContentFieldByField(t *testing.T) {
	for _, tc := range []struct {
		name string
		ap   ArmProfile
	}{
		{"a strategy", ArmProfile{Arm: ArmUntouched, Profile: SchedulerProfile{Strategy: MostAllocated}}},
		{"a resource list", ArmProfile{Arm: ArmUntouched,
			Profile: SchedulerProfile{Resources: []ResourceWeight{{Name: GPUResourceName, Weight: 1}}}}},
		{"a schedulerName", ArmProfile{Arm: ArmUntouched,
			Profile: SchedulerProfile{SchedulerName: "default-scheduler"}}},
		{"a whole GPU-aware profile", ArmProfile{Arm: ArmUntouched, Profile: GPUAware(MostAllocated)}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.ap.Validate()
			if err == nil {
				t.Fatalf("the reference arm was accepted carrying %s", tc.name)
			}
			if !strings.Contains(err.Error(), "installs no configuration") {
				t.Errorf("the refusal does not say what the reference is: %v", err)
			}
		})
	}
	// And the bare reference is accepted, so the refusals above are about content rather than about the arm.
	if err := UntouchedArm().Validate(); err != nil {
		t.Errorf("the bare reference arm was refused: %v", err)
	}
}

// The treatment arm still goes through SchedulerProfile.Validate(), so the missing-GPU guard is not lost.
//
// That guard is the one the amendment's chosen reference collided with, and the resolution was an explicit arm
// mode rather than letting an empty resource list mean "untouched". This asserts the guard survived the change.
//
// Mutation that turns this red: skip Profile.Validate() for ArmConfigured.
func TestTheTreatmentArmStillRefusesAProfileThatWouldBeInert(t *testing.T) {
	inert := ArmProfile{Arm: ArmConfigured, Profile: SchedulerProfile{
		Strategy:      MostAllocated,
		SchedulerName: "default-scheduler",
		Resources:     []ResourceWeight{{Name: "cpu", Weight: 1}},
	}}
	err := inert.Validate()
	if err == nil {
		t.Fatal("the treatment arm accepted a profile that never scores the GPU")
	}
	if !strings.Contains(err.Error(), "does not name "+GPUResourceName) {
		t.Errorf("the refusal is not the missing-GPU one: %v", err)
	}
	// An empty resource list must still be refused for the treatment, and must NOT be read as the reference.
	empty := ArmProfile{Arm: ArmConfigured, Profile: SchedulerProfile{
		Strategy: MostAllocated, SchedulerName: "default-scheduler",
	}}
	if err := empty.Validate(); err == nil {
		t.Error("the treatment arm accepted an empty resource list; emptiness must never mean \"untouched\"")
	}
	// And the registered treatment is accepted.
	if err := ConfiguredArm(MostAllocated).Validate(); err != nil {
		t.Errorf("the registered treatment arm was refused: %v", err)
	}
	if err := ConfiguredArm(LeastAllocated).Validate(); err != nil {
		t.Errorf("a GPU-aware LeastAllocated profile was refused; it stays available as an instrument control "+
			"even though it is not a campaign arm: %v", err)
	}
}
