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
	"testing"

	appsv1 "k8s.io/api/apps/v1"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// An observed scale-down to zero is not ScaledToZero until the Deployment counts no replicas.
//
// Mutation that turns this red: drop the drain check before ScaledToZero.
func TestScaledToZeroWaitsForTheDrain(t *testing.T) {
	infd := &platformv1.InferenceDeployment{Spec: platformv1.InferenceDeploymentSpec{Replicas: 0}}
	dep := &appsv1.Deployment{}
	dep.Generation, dep.Status.ObservedGeneration = 3, 3
	dep.Status.Replicas, dep.Status.ReadyReplicas = 2, 2
	if phase, cond := computeInfDPhase(infd, dep); phase == infdPhaseReady {
		t.Fatalf("a scale-down still running two replicas reported %s/%s", phase, cond.Reason)
	}
	dep.Status.Replicas, dep.Status.ReadyReplicas = 0, 0
	if phase, cond := computeInfDPhase(infd, dep); phase != infdPhaseReady || cond.Reason != infdReasonScaledZero {
		t.Fatalf("a drained scale-down reported %s/%s", phase, cond.Reason)
	}
}
