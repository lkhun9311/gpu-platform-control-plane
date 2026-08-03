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

import (
	"slices"
	"strings"
	"testing"
)

func TestRenderMLTrainingJobMatchesTraceAndQueue(t *testing.T) {
	rows := ReclaimScenario(true, 600)
	borrow := rows[1] // a2-borrow, tenant-a
	job := RenderMLTrainingJob(borrow, "run-ns")

	if job.Name != "a2-borrow" || job.Namespace != "run-ns" {
		t.Fatalf("job identity = %s/%s", job.Namespace, job.Name)
	}
	// The job must target the same LocalQueue name the fixtures created for its tenant, or it would never
	// be admitted through the policy variant under test.
	if job.Spec.Queue != "ql-tenant-a" {
		t.Fatalf("queue = %q, want ql-tenant-a", job.Spec.Queue)
	}
	if job.Spec.GPUCount != 1 {
		t.Fatalf("gpuCount = %d, want 1", job.Spec.GPUCount)
	}
	if job.Spec.Parallelism != 1 || job.Spec.Completions != 1 {
		t.Fatalf("parallelism/completions must be pinned to 1 so gpuCount is the demand")
	}
	if len(job.Spec.Command) != 3 || !strings.Contains(job.Spec.Command[2], "sleep 600") {
		t.Fatalf("sleeper command = %v, want sleep 600", job.Spec.Command)
	}
	if job.Labels["queuelab.gpu-platform/trace-index"] != "1" {
		t.Fatalf("trace-index label = %q, want 1", job.Labels["queuelab.gpu-platform/trace-index"])
	}
}

func TestRenderMLTrainingJobQueuePerTenant(t *testing.T) {
	owner := ReclaimScenario(true, 600)[2] // b1-owner, tenant-b
	job := RenderMLTrainingJob(owner, "run-ns")
	if job.Spec.Queue != "ql-tenant-b" {
		t.Fatalf("tenant-b job should target ql-tenant-b, got %q", job.Spec.Queue)
	}
	// The fixtures must create exactly this LocalQueue name for tenant-b, so submit and fixtures agree.
	fs, err := BuildFixtures(StudyReclaim, "Any", "r", "run-ns")
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, lq := range fs.LocalQueue {
		if lq.Name == job.Spec.Queue {
			found = true
		}
	}
	if !found {
		t.Fatalf("submit targets queue %q but no fixture LocalQueue has that name", job.Spec.Queue)
	}
}

func TestRenderMLTrainingJobTerminationContract(t *testing.T) {
	row := TrainingTraceRow{Index: 0, Name: "a1", Tenant: "tenant-a", GPUCount: 1, DurationSec: 40}

	ignoring := RenderMLTrainingJobWithContract(row, "queuelab", IgnoresSIGTERM)
	wantIgnoring := []string{"sh", "-c", "sleep 40"}
	if !slices.Equal(ignoring.Spec.Command, wantIgnoring) {
		t.Fatalf("ignoring command = %q, want %q", ignoring.Spec.Command, wantIgnoring)
	}

	honoring := RenderMLTrainingJobWithContract(row, "queuelab", HonorsSIGTERM)
	// The honoring form must keep the shell as PID 1 and install a TERM trap, because a bare "sleep" exec'd
	// as PID 1 receives no default signal disposition and would ignore the signal.
	got := strings.Join(honoring.Spec.Command, " ")
	for _, want := range []string{"trap", "TERM", "sleep 40", "wait"} {
		if !strings.Contains(got, want) {
			t.Fatalf("honoring command %q is missing %q", got, want)
		}
	}
	// A trapped stop must be distinguishable from natural completion by exit status, or the ledger cannot
	// tell "the preemption stopped it" from "it finished on its own".
	if !strings.Contains(got, "exit 143") {
		t.Fatalf("honoring command %q must exit 143 on TERM so the stop is distinguishable", got)
	}

	// The default wrapper stays on the ignoring contract so existing callers do not silently change arms.
	if !slices.Equal(RenderMLTrainingJob(row, "queuelab").Spec.Command, wantIgnoring) {
		t.Fatal("RenderMLTrainingJob must keep the IgnoresSIGTERM contract")
	}
}
