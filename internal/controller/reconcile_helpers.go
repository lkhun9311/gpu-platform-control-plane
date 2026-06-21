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
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// nodeHealthFinalizer guards NodeHealth cleanup.
// Real cleanup (e.g. removing node taints) lands in M3; at M2 the finalizer only establishes the lifecycle.
const nodeHealthFinalizer = "nodehealth.platform.lkhun9311.github.io/finalizer"

// conditionReady is the NodeHealth condition type that mirrors target node readiness.
const conditionReady = "Ready"

// Condition reasons for conditionReady.
const (
	reasonNodeReady    = "NodeReady"
	reasonNodeNotReady = "NodeNotReady"
	reasonNodeNotFound = "NodeNotFound"
)

// NodeHealth phases used at M2 (observation only).
// Intake/Quarantine are M3.
const (
	phasePending  = "Pending"
	phaseReady    = "Ready"
	phaseDegraded = "Degraded"
)

// setPhase updates the phase and bumps lastTransitionTime only when the phase changes.
func setPhase(status *platformv1.NodeHealthStatus, phase string) {
	if status.Phase == phase {
		return
	}
	status.Phase = phase
	now := metav1.Now()
	status.LastTransitionTime = &now
}

// setReadyCondition sets the Ready condition, stamping observedGeneration.
// It is a thin wrapper over meta.SetStatusCondition (which preserves lastTransitionTime when unchanged).
func setReadyCondition(status *platformv1.NodeHealthStatus, ready bool, reason, msg string, generation int64) {
	condStatus := metav1.ConditionFalse
	if ready {
		condStatus = metav1.ConditionTrue
	}
	meta.SetStatusCondition(&status.Conditions, metav1.Condition{
		Type:               conditionReady,
		Status:             condStatus,
		Reason:             reason,
		Message:            msg,
		ObservedGeneration: generation,
	})
}

// isNodeReady reports whether the node's Ready condition is True.
func isNodeReady(node *corev1.Node) bool {
	for i := range node.Status.Conditions {
		c := node.Status.Conditions[i]
		if c.Type == corev1.NodeReady {
			return c.Status == corev1.ConditionTrue
		}
	}
	return false
}
