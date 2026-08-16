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
	"fmt"
	"strconv"
	"strings"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	kueuev1beta2 "sigs.k8s.io/kueue/apis/kueue/v1beta2"
)

// ObservedState is the authoritative reading of one observed object version: the lifecycle event its
// conditions now justify (empty when none), and whether that state forces the whole run invalid.
//
// The collector (a later slice) tracks the last emitted event per object and only journals a transition,
// so a repeated observation of the same admitted Workload does not produce duplicate Admitted events. This
// classifier is stateless: it answers "what does THIS version mean", not "did it just change".
type ObservedState struct {
	// Event is the lifecycle transition this object version justifies, or "" for none.
	Event EventType
	// Reason carries the condition reason behind Event (e.g. the preemption mechanism), for provenance.
	Reason string
	// Invalid is set when this state proves the run cannot be a clean comparison (an unexpected eviction,
	// a failed Job), so the runner must discard the run rather than report a contaminated number.
	Invalid bool
	// InvalidReason explains the invalidation.
	InvalidReason string
	// ExitCode is the terminated container's status, and it is what tells one kind of stop from another.
	//
	// Reason carries the Pod PHASE, which is "Failed" both for a workload that honoured SIGTERM and exited
	// promptly and for one that ignored it and was SIGKILLed at the end of the grace period. Those are the two
	// arms of this experiment, so a ledger that records only the phase cannot say which of them it observed —
	// the termination canary distinguishes them by exit status (143 against 137) and the run itself could not.
	//
	// It is a pointer because "no terminated container status to read" is a different fact from "exited 0",
	// and nil is the only honest spelling of the first.
	ExitCode *int32
	// Iterations is how much work the container had completed when it stopped, read out of the same terminated
	// status the exit code comes from.
	//
	// It is what turns a discarded GPU-second into a discarded UNIT OF WORK. Without it the waste figure says
	// how long a device was held and nothing about what was lost, and a workload that computed nothing looks
	// exactly like one that saturated the card.
	//
	// nil for the same reason ExitCode is: a status that could not be read, or a message that does not carry a
	// count, is a different fact from zero iterations.
	Iterations *int
}

// ClassifyWorkload reads a Workload's conditions into the authoritative admission/preemption state.
//
// The ONLY preemption the reclaim study expects is in-cohort reclamation: Preempted=True with reason
// InCohortReclamation AND Evicted=True with reason Preempted. Any other eviction (PodsReadyTimeout,
// NodeFailures, AdmissionCheck, a stopped queue, a non-reclaim preemption) is a different mechanism than
// the one under test and would silently change the arm, so it invalidates the run instead of being folded
// as if it were the study's preemption.
func ClassifyWorkload(wl *kueuev1beta2.Workload) ObservedState {
	evicted, evictReason := conditionTrue(wl.Status.Conditions, kueuev1beta2.WorkloadEvicted)
	if evicted {
		preempted, preemptReason := conditionTrue(wl.Status.Conditions, kueuev1beta2.WorkloadPreempted)
		if evictReason == kueuev1beta2.WorkloadEvictedByPreemption &&
			preempted && preemptReason == kueuev1beta2.InCohortReclamationReason {
			return ObservedState{Event: EventPreempted, Reason: kueuev1beta2.InCohortReclamationReason}
		}
		return ObservedState{
			Invalid:       true,
			InvalidReason: fmt.Sprintf("unexpected Workload eviction (reason %q), not the study's in-cohort reclamation", evictReason),
		}
	}
	if admitted, _ := conditionTrue(wl.Status.Conditions, kueuev1beta2.WorkloadAdmitted); admitted && wl.Status.Admission != nil {
		return ObservedState{Event: EventAdmitted, Reason: kueuev1beta2.WorkloadAdmitted}
	}
	return ObservedState{}
}

// ClassifyJob reads a batch/v1 Job's conditions. Only the terminal Complete condition is the authoritative
// Completed event; a failure invalidates the run, because a lab Job runs with backoffLimit 0 (set by the
// runner) and a real training row is not supposed to fail, so a failure means the arm did not run as
// designed.
//
// SuccessCriteriaMet is deliberately NOT treated as completion: Kubernetes sets it before the Job's Pods
// have all terminated, so completing on it would let an orchestrator close the horizon while a Pod is still
// holding a GPU, dropping that interval. Complete is the condition that waits for terminal Pods.
func ClassifyJob(job *batchv1.Job) ObservedState {
	for _, c := range job.Status.Conditions {
		if c.Status != corev1.ConditionTrue {
			continue
		}
		switch c.Type {
		case batchv1.JobComplete:
			return ObservedState{Event: EventCompleted, Reason: string(c.Type)}
		case batchv1.JobFailed:
			return ObservedState{Invalid: true, InvalidReason: fmt.Sprintf("Job failed (%s)", c.Reason)}
		}
	}
	return ObservedState{}
}

// ClassifyPod reads a Pod's status into the execution-start and execution-stop events.
//
// AttemptStopped is a genuine TERMINAL phase (Succeeded or Failed), not the first deletionTimestamp: the
// deletion timestamp only starts the grace period, during which the Pod keeps holding the GPU, so waste
// measured to it would undercount exactly the grace window this event exists to capture.
func ClassifyPod(pod *corev1.Pod) ObservedState {
	if pod.Status.Phase == corev1.PodSucceeded || pod.Status.Phase == corev1.PodFailed {
		code, iters := soleTerminated(pod)
		return ObservedState{Event: EventAttemptStopped, Reason: string(pod.Status.Phase),
			ExitCode: code, Iterations: iters}
	}
	if pod.Status.Phase == corev1.PodRunning && podConditionTrue(pod, corev1.PodReady) {
		return ObservedState{Event: EventPodReady, Reason: string(corev1.PodReady)}
	}
	return ObservedState{}
}

// conditionTrue reports whether the named condition is present with status True, returning its reason.
func conditionTrue(conditions []metav1.Condition, condType string) (bool, string) {
	for i := range conditions {
		if conditions[i].Type == condType {
			return conditions[i].Status == metav1.ConditionTrue, conditions[i].Reason
		}
	}
	return false, ""
}

// podConditionTrue reports whether the Pod carries the named condition with status True.
func podConditionTrue(pod *corev1.Pod, condType corev1.PodConditionType) bool {
	for i := range pod.Status.Conditions {
		if pod.Status.Conditions[i].Type == condType {
			return pod.Status.Conditions[i].Status == corev1.ConditionTrue
		}
	}
	return false
}

// soleExitCode returns the exit status when exactly one container terminated, and nil otherwise.
//
// The ambiguity is refused rather than resolved by picking a container, because this package has no way to
// know which one carried the workload: the trace's Pods have a single container today, and a template that
// grew a sidecar would make any choice here a guess presented as a measurement. nil then reports that the
// stop was observed but its kind could not be established, which is a weaker claim than a number and the
// only true one.
func soleTerminated(pod *corev1.Pod) (*int32, *int) {
	var code *int32
	var iters *int
	for i := range pod.Status.ContainerStatuses {
		t := pod.Status.ContainerStatuses[i].State.Terminated
		if t == nil {
			continue
		}
		if code != nil {
			return nil, nil
		}
		c := t.ExitCode
		code = &c
		iters = itersFromMessage(t.Message)
	}
	return code, iters
}

// itersFromMessage reads the workload's own count out of the terminated status message.
//
// The kubelet copies /dev/termination-log there, and the workload rewrites that file from inside its loop, so
// this arrives even for a container SIGKILLed at the grace boundary — the arm whose discarded work the
// experiment is about, and the one that can print no final line because SIGKILL cannot be handled.
//
// Anything that is not exactly the expected shape yields nil rather than a guess. The message is a channel the
// workload controls, and a number parsed loosely out of it would be a measurement invented from whatever
// happened to be in a file.
func itersFromMessage(msg string) *int {
	const prefix = "iters="
	msg = strings.TrimSpace(msg)
	if !strings.HasPrefix(msg, prefix) {
		return nil
	}
	n, err := strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(msg, prefix)))
	if err != nil || n < 0 {
		return nil
	}
	return &n
}
