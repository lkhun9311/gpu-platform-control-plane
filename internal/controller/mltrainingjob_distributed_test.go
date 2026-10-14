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
