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
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"testing"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

var updateGolden = flag.Bool("update-golden", false, "rewrite testdata goldens from the current renderer")

// ordinaryJobs are the shapes the termination canary and the existing specs render, none of them distributed.
//
// The canary's 3/5 is among them because it is the one caller outside this package that hashes the template.
func ordinaryJobs() map[string]*platformv1.MLTrainingJob {
	return map[string]*platformv1.MLTrainingJob{
		"canary-shape": {
			Name: "probe", Namespace: "ns",
			Spec: platformv1.MLTrainingJobSpec{
				Queue: "q", Image: "img:1", Command: []string{"sh", "-c", "true"},
				GPUCount: 1, Parallelism: 3, Completions: 5,
				StateVolume: &platformv1.StateVolume{ClaimName: "c", MountPath: "/s"},
			},
		},
		"no-gpu-defaults": {
			Name: "plain", Namespace: "ns",
			Spec: platformv1.MLTrainingJobSpec{Queue: "q", Image: "img:1"},
		},
	}
}

// A job that does not ask for distribution renders exactly what it rendered before the field existed.
//
// The golden was written by the renderer as it stood before any distributed code was added, so it is a record of
// that version rather than of whatever this one happens to produce.
// Pinning the bytes, not a few fields, is the point: the canary hashes the whole template, and a stray label or
// env var added for distributed jobs would invalidate every reading taken before it without any field-level test
// noticing.
func TestAJobWithoutDistributedRendersWhatItAlwaysRendered(t *testing.T) {
	for name, mltj := range ordinaryJobs() {
		t.Run(name, func(t *testing.T) {
			got, err := json.MarshalIndent(BuildJob(mltj), "", "  ")
			if err != nil {
				t.Fatal(err)
			}
			path := filepath.Join("testdata", "buildjob-"+name+".golden.json")
			if *updateGolden {
				if err := os.WriteFile(path, append(got, '\n'), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			want, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read golden: %v", err)
			}
			if string(want) != string(got)+"\n" {
				t.Errorf("rendering changed for a non-distributed job\n--- golden %s\n%s\n--- now\n%s", path, want, got)
			}
		})
	}
}

func distributedJob(world int32) *platformv1.MLTrainingJob {
	return &platformv1.MLTrainingJob{
		Name: "ddp", Namespace: "ns", UID: "uid-1",
		Spec: platformv1.MLTrainingJobSpec{
			Queue: "q", Image: "img:1", GPUCount: 1, Parallelism: 1, Completions: 1,
			Distributed: &platformv1.Distributed{WorldSize: world},
		},
	}
}

// The webhook spells the suffix itself rather than importing this package, so this is what keeps the two in step.
func TestTheRendezvousServiceNameIsTheOneTheWebhookChecks(t *testing.T) {
	if got := RendezvousServiceName(distributedJob(2)); got != "ddp-ddp" {
		t.Fatalf("service name %q; internal/webhook/v1 distributedName validates <name>-ddp", got)
	}
}

func TestADistributedJobRendersOneIndexedJobOfWorldSizeRanks(t *testing.T) {
	job := BuildJob(distributedJob(3))

	if job.Spec.CompletionMode == nil || *job.Spec.CompletionMode != batchv1.IndexedCompletion {
		t.Errorf("completionMode %v, want Indexed", job.Spec.CompletionMode)
	}
	if *job.Spec.Parallelism != 3 || *job.Spec.Completions != 3 {
		t.Errorf("parallelism %d completions %d, want both 3 from worldSize", *job.Spec.Parallelism, *job.Spec.Completions)
	}
	// Mutation that turns this red: leave BackoffLimit unset, which the API server defaults to 6.
	if job.Spec.BackoffLimit == nil || *job.Spec.BackoffLimit != 0 {
		t.Errorf("backoffLimit %v, want 0 so one failed rank fails the attempt", job.Spec.BackoffLimit)
	}
	tmpl := job.Spec.Template
	if tmpl.Spec.Subdomain != "ddp-ddp" {
		t.Errorf("subdomain %q", tmpl.Spec.Subdomain)
	}
	if tmpl.Labels[mltjNameLabel] != "ddp" || tmpl.Labels[mltjUIDLabel] != "uid-1" {
		t.Errorf("pod labels %v, want name and uid", tmpl.Labels)
	}
	env := map[string]corev1.EnvVar{}
	for _, e := range tmpl.Spec.Containers[0].Env {
		env[e.Name] = e
	}
	for name, want := range map[string]string{
		"WORLD_SIZE": "3", "MASTER_ADDR": "ddp-0.ddp-ddp.ns.svc", "MASTER_PORT": "29500",
	} {
		if env[name].Value != want {
			t.Errorf("%s=%q, want %q", name, env[name].Value, want)
		}
	}
	rank := env["RANK"].ValueFrom
	if rank == nil || rank.FieldRef == nil ||
		rank.FieldRef.FieldPath != "metadata.annotations['batch.kubernetes.io/job-completion-index']" {
		t.Errorf("RANK not read from the completion-index annotation: %+v", env["RANK"])
	}
	// The GPU env this function always set is still there, so the distributed branch adds rather than replaces.
	if env["NVIDIA_DRIVER_CAPABILITIES"].Value == "" {
		t.Errorf("driver capabilities lost: %v", tmpl.Spec.Containers[0].Env)
	}
}

func TestTheRendezvousServiceSelectsOnlyThisIncarnationsPods(t *testing.T) {
	svc := BuildRendezvousService(distributedJob(2))
	if svc.Spec.ClusterIP != corev1.ClusterIPNone || !svc.Spec.PublishNotReadyAddresses {
		t.Errorf("want headless with not-ready addresses published, got clusterIP %q publish %v",
			svc.Spec.ClusterIP, svc.Spec.PublishNotReadyAddresses)
	}
	// Mutation that turns this red: drop the uid from the selector.
	if svc.Spec.Selector[mltjUIDLabel] != "uid-1" || svc.Spec.Selector[mltjNameLabel] != "ddp" {
		t.Errorf("selector %v, want name and uid", svc.Spec.Selector)
	}
}
