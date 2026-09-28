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

// The refusal this whole file exists for: a profile the SCHEDULER would accept and this study must not.
//
// NodeResourcesFit scores cpu and memory by default. A profile that selects MostAllocated without naming
// nvidia.com/gpu starts a scheduler that reports exactly the requested strategy and packs nothing the study
// varies -- so the three arms report the same number and it reads as a null result rather than as a treatment
// that never applied. Every case below is one the scheduler starts happily.
//
// Mutation that turns this red: drop the GPUResourceName search from Validate.
func TestAProfileTheSchedulerWouldAcceptAndThisStudyMustNot(t *testing.T) {
	for _, tc := range []struct {
		name    string
		profile SchedulerProfile
		wants   string
	}{
		{
			name: "no resources at all, so the default cpu and memory apply",
			profile: SchedulerProfile{Strategy: MostAllocated, SchedulerName: "default-scheduler",
				Resources: nil},
			wants: "cpu and memory",
		},
		{
			name: "a resource list that does not name the GPU",
			profile: SchedulerProfile{Strategy: MostAllocated, SchedulerName: "default-scheduler",
				Resources: []ResourceWeight{{Name: "cpu", Weight: 1}, {Name: "memory", Weight: 1}}},
			wants: "does not name " + GPUResourceName,
		},
		{
			name: "the GPU named at weight zero, which contributes nothing",
			profile: SchedulerProfile{Strategy: MostAllocated, SchedulerName: "default-scheduler",
				Resources: []ResourceWeight{{Name: GPUResourceName, Weight: 0}}},
			wants: "configured and inert",
		},
		{
			name: "no schedulerName, so no pod is governed by the profile",
			profile: SchedulerProfile{Strategy: MostAllocated, SchedulerName: "",
				Resources: []ResourceWeight{{Name: GPUResourceName, Weight: 1}}},
			wants: "schedulerName",
		},
		{
			name: "a third strategy nothing registered",
			profile: SchedulerProfile{Strategy: "RequestedToCapacityRatio", SchedulerName: "default-scheduler",
				Resources: []ResourceWeight{{Name: GPUResourceName, Weight: 1}}},
			wants: "neither",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.profile.Validate()
			if err == nil {
				t.Fatalf("the profile was accepted; %s", tc.name)
			}
			if !strings.Contains(err.Error(), tc.wants) {
				t.Errorf("the refusal does not say why: got %q, want it to mention %q", err, tc.wants)
			}
			if _, rerr := tc.profile.KubeSchedulerConfigurationYAML(); rerr == nil {
				t.Error("an invalid profile still rendered a configuration; the render must not be a second " +
					"path to a cluster that the validation does not guard")
			}
		})
	}
}

// The rendered configuration must carry the GPU resource, or the study's treatment is inert on the cluster.
//
// Asserted on the rendered TEXT rather than on the struct, because the text is what the scheduler reads. A
// renderer that dropped the resource list would leave Validate green and the cluster ungoverned.
//
// Mutation that turns this red: stop emitting the resources block.
func TestTheRenderedConfigurationNamesTheResourceTheStudyVaries(t *testing.T) {
	for _, s := range []ScoringStrategy{LeastAllocated, MostAllocated} {
		out, err := GPUAware(s).KubeSchedulerConfigurationYAML()
		if err != nil {
			t.Fatalf("%s: %v", s, err)
		}
		for _, want := range []string{
			"kind: KubeSchedulerConfiguration",
			"name: NodeResourcesFit",
			"type: " + string(s),
			"name: " + GPUResourceName,
			"schedulerName: default-scheduler",
			// Without this the scheduler cannot reach the API server and crash-loops: kubeadm passes both
			// --config and --kubeconfig, and the flag is ignored once the file is given. The first cluster
			// this renderer built failed exactly that way, and everything downstream -- kindnet Pending,
			// every node NotReady, the device plugins unschedulable -- looked like a different problem.
			"clientConnection:",
			"kubeconfig: " + SchedulerKubeconfigPath,
		} {
			if !strings.Contains(out, want) {
				t.Errorf("%s: the rendered configuration does not contain %q:\n%s", s, want, out)
			}
		}
		// cpu and memory must be ABSENT, not present at weight zero: a zero-weight entry behaves identically
		// and would tell a reader the study scores over three resources when it scores over one.
		if strings.Contains(out, "name: cpu") || strings.Contains(out, "name: memory") {
			t.Errorf("%s: the configuration names cpu or memory; what the arms differ by must be readable "+
				"from the resource list:\n%s", s, out)
		}
	}
}

// The two strategies must render DIFFERENTLY, which is the whole of what an arm is.
//
// Mutation that turns this red: hardcode either strategy name in the renderer.
func TestTheTwoArmsRenderDifferentConfigurations(t *testing.T) {
	least, err := GPUAware(LeastAllocated).KubeSchedulerConfigurationYAML()
	if err != nil {
		t.Fatal(err)
	}
	most, err := GPUAware(MostAllocated).KubeSchedulerConfigurationYAML()
	if err != nil {
		t.Fatal(err)
	}
	if least == most {
		t.Fatal("both arms render byte-identical scheduler configurations, so the comparison has one arm")
	}
	if !strings.Contains(least, "type: LeastAllocated") || !strings.Contains(most, "type: MostAllocated") {
		t.Errorf("the strategies did not reach their own configurations:\nleast:\n%s\nmost:\n%s", least, most)
	}
}
