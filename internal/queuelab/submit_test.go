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
