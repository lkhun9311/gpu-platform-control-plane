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

package controller

import (
	"strings"
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// isServing decides whether a WorkloadRun's target is carrying work, and one of its branches cannot be reached
// through the API at all: the target-kind enum admits only InferenceDeployment and NodeHealth, so an
// unrecognised kind has no envtest path. Mutating that branch to return "serving" left the whole suite green,
// which is the signature of a guard nothing tests. This calls the function directly instead.

func targetWith(phase string, ready *int64) *unstructured.Unstructured {
	status := map[string]any{}
	if phase != "" {
		status["phase"] = phase
	}
	if ready != nil {
		status["readyReplicas"] = *ready
	}
	return &unstructured.Unstructured{Object: map[string]any{"status": status}}
}

func TestIsServingRequiresAReadyReplicaForInferenceDeployment(t *testing.T) {
	two := int64(2)
	zero := int64(0)

	for _, c := range []struct {
		name  string
		ready *int64
		want  bool
	}{
		// The whole point: phase Ready with nothing running is a deliberate scale-to-zero, which serves nobody.
		{"Ready with two replicas is serving", &two, true},
		{"Ready with zero replicas is not serving", &zero, false},
		// Absent reads as zero rather than as "assume it is fine": an InferenceDeployment that has not reported
		// replicas yet has not told us it is serving.
		{"Ready with no replica count at all is not serving", nil, false},
	} {
		got, err := isServing("InferenceDeployment", "Ready", targetWith("Ready", c.ready))
		if err != nil {
			t.Fatalf("%s: unexpected error: %v", c.name, err)
		}
		if got != c.want {
			t.Errorf("%s: isServing = %t, want %t", c.name, got, c.want)
		}
	}
}

// A phase that is not the healthy one is never serving, whatever the replica count says. A Degraded deployment
// with replicas still counted as ready is the case that matters -- the rollout failed, and the run must see a
// failure rather than health.
func TestIsServingNeedsTheHealthyPhaseFirst(t *testing.T) {
	three := int64(3)
	for _, kind := range []string{"InferenceDeployment", "NodeHealth"} {
		for _, phase := range []string{"Degraded", "Pending", "Quarantine", "NoPhase", ""} {
			got, err := isServing(kind, phase, targetWith(phase, &three))
			if err != nil {
				t.Fatalf("%s/%s: unexpected error: %v", kind, phase, err)
			}
			if got {
				t.Errorf("%s reported serving in phase %q", kind, phase)
			}
		}
	}
}

// NodeHealth has no replica concept: its status carries a phase, a fault signal and conditions, so Ready is the
// whole of the judgment. Requiring a replica count here would make every node run unhealthy forever.
func TestIsServingAcceptsAReadyNodeHealth(t *testing.T) {
	got, err := isServing("NodeHealth", "Ready", targetWith("Ready", nil))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !got {
		t.Fatal("a Ready NodeHealth was not read as serving; every node run would be unhealthy forever")
	}
}

// The branch no API path can reach.
//
// The kind enum admits two values today. A third added later without a rule here must NOT default to healthy:
// a run would award Recovered for a target nobody taught this function to judge. So the default refuses, and
// says which kind it does not know.
func TestIsServingRefusesAKindItHasNoRuleFor(t *testing.T) {
	got, err := isServing("GpuSharingBenchmark", "Ready", targetWith("Ready", nil))
	if err == nil {
		t.Fatal("an unknown target kind was judged without complaint; a new kind would be read as healthy by default")
	}
	if got {
		t.Error("an unknown target kind was reported as serving")
	}
	if !strings.Contains(err.Error(), "GpuSharingBenchmark") {
		t.Errorf("the error does not name the kind it cannot judge: %v", err)
	}
	if !strings.Contains(err.Error(), "no serving rule") {
		t.Errorf("the error does not say what is missing: %v", err)
	}
}
