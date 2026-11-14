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
	"os"
	"path/filepath"
	"slices"
	"testing"

	rbacv1 "k8s.io/api/rbac/v1"
	"sigs.k8s.io/yaml"
)

// A controller reference sets blockOwnerDeletion, and an API server running OwnerReferencesPermissionEnforcement
// refuses it unless the writer may update the owner's finalizers; the plugin is off by default, so neither
// envtest nor kind would show a missing grant, and the first cluster that enables it would refuse the child
// (codex review r8: the manager could not create an InferenceDeployment's Deployment there).
// Every kind this manager names as a controller owner is listed; a new owner kind belongs here too.
//
// Mutation that turns this red: drop the inferencedeployments/finalizers marker and regenerate the role.
func TestTheManagerMayUpdateTheFinalizersOfEveryOwnerItSets(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "config", "rbac", "role.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	role := &rbacv1.ClusterRole{}
	if err := yaml.Unmarshal(raw, role); err != nil {
		t.Fatal(err)
	}
	for _, owner := range []string{"mltrainingjobs", "inferencedeployments", "gpuquotapolicies"} {
		granted := false
		for _, r := range role.Rules {
			if slices.Contains(r.APIGroups, "platform.lkhun9311.github.io") &&
				slices.Contains(r.Resources, owner+"/finalizers") && slices.Contains(r.Verbs, "update") {
				granted = true
			}
		}
		if !granted {
			t.Errorf("the manager's role cannot update %s/finalizers, so a child it owns is refused where the API server enforces owner references", owner)
		}
	}
}
