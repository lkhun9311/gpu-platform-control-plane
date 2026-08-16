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
	"testing"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	kueuev1beta2 "sigs.k8s.io/kueue/apis/kueue/v1beta2"
)

// condTrue builds a status-True condition; every provenance case here turns on a True condition, and a
// missing/False condition is modelled by simply omitting it.
func condTrue(t, reason string) metav1.Condition {
	return metav1.Condition{Type: t, Status: metav1.ConditionTrue, Reason: reason}
}

func TestClassifyWorkloadAdmitted(t *testing.T) {
	wl := &kueuev1beta2.Workload{Status: kueuev1beta2.WorkloadStatus{
		Conditions: []metav1.Condition{condTrue(kueuev1beta2.WorkloadAdmitted, "Admitted")},
		Admission:  &kueuev1beta2.Admission{},
	}}
	if got := ClassifyWorkload(wl); got.Event != EventAdmitted {
		t.Fatalf("admitted workload = %+v, want EventAdmitted", got)
	}
}

func TestClassifyWorkloadAdmittedRequiresAdmissionField(t *testing.T) {
	// Admitted=True without status.admission is a half-written status; it must not count as an admission.
	wl := &kueuev1beta2.Workload{Status: kueuev1beta2.WorkloadStatus{
		Conditions: []metav1.Condition{condTrue(kueuev1beta2.WorkloadAdmitted, "Admitted")},
	}}
	if got := ClassifyWorkload(wl); got.Event != "" {
		t.Fatalf("admitted without admission field = %+v, want no event", got)
	}
}

func TestClassifyWorkloadExpectedReclaimPreemption(t *testing.T) {
	wl := &kueuev1beta2.Workload{Status: kueuev1beta2.WorkloadStatus{Conditions: []metav1.Condition{
		condTrue(kueuev1beta2.WorkloadEvicted, kueuev1beta2.WorkloadEvictedByPreemption),
		condTrue(kueuev1beta2.WorkloadPreempted, kueuev1beta2.InCohortReclamationReason),
	}}}
	got := ClassifyWorkload(wl)
	if got.Event != EventPreempted || got.Invalid {
		t.Fatalf("in-cohort reclamation = %+v, want EventPreempted and not invalid", got)
	}
}

func TestClassifyWorkloadUnexpectedEvictionInvalidates(t *testing.T) {
	// A PodsReadyTimeout eviction is a different mechanism than the study's reclaim; folding it as the
	// study's preemption would contaminate the arm, so it invalidates the run.
	wl := &kueuev1beta2.Workload{Status: kueuev1beta2.WorkloadStatus{Conditions: []metav1.Condition{
		condTrue(kueuev1beta2.WorkloadEvicted, kueuev1beta2.WorkloadEvictedByPodsReadyTimeout),
	}}}
	if got := ClassifyWorkload(wl); !got.Invalid {
		t.Fatalf("PodsReadyTimeout eviction = %+v, want invalid", got)
	}
}

func TestClassifyWorkloadPreemptionWrongReasonInvalidates(t *testing.T) {
	// Evicted by preemption but NOT for in-cohort reclamation (e.g. a priority preemption within the queue)
	// is not the mechanism under test.
	wl := &kueuev1beta2.Workload{Status: kueuev1beta2.WorkloadStatus{Conditions: []metav1.Condition{
		condTrue(kueuev1beta2.WorkloadEvicted, kueuev1beta2.WorkloadEvictedByPreemption),
		condTrue(kueuev1beta2.WorkloadPreempted, "PriorityPreemption"),
	}}}
	if got := ClassifyWorkload(wl); !got.Invalid {
		t.Fatalf("non-reclaim preemption = %+v, want invalid", got)
	}
}

func TestClassifyJobCompleteAndFailed(t *testing.T) {
	complete := &batchv1.Job{Status: batchv1.JobStatus{Conditions: []batchv1.JobCondition{
		{Type: batchv1.JobComplete, Status: corev1.ConditionTrue},
	}}}
	if got := ClassifyJob(complete); got.Event != EventCompleted {
		t.Fatalf("complete job = %+v, want EventCompleted", got)
	}
	failed := &batchv1.Job{Status: batchv1.JobStatus{Conditions: []batchv1.JobCondition{
		{Type: batchv1.JobFailed, Status: corev1.ConditionTrue, Reason: "BackoffLimitExceeded"},
	}}}
	if got := ClassifyJob(failed); !got.Invalid {
		t.Fatalf("failed job = %+v, want invalid", got)
	}
}

func TestClassifyPodReadyAndStopped(t *testing.T) {
	ready := &corev1.Pod{Status: corev1.PodStatus{
		Phase:      corev1.PodRunning,
		Conditions: []corev1.PodCondition{{Type: corev1.PodReady, Status: corev1.ConditionTrue}},
	}}
	if got := ClassifyPod(ready); got.Event != EventPodReady {
		t.Fatalf("ready pod = %+v, want EventPodReady", got)
	}
	stopped := &corev1.Pod{Status: corev1.PodStatus{Phase: corev1.PodFailed}}
	if got := ClassifyPod(stopped); got.Event != EventAttemptStopped {
		t.Fatalf("terminal pod = %+v, want EventAttemptStopped", got)
	}
	// A pod merely marked for deletion (grace period started) but not yet terminal must NOT be stopped, or
	// the grace-window work would be dropped from waste.
	deleting := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{DeletionTimestamp: &metav1.Time{}},
		Status:     corev1.PodStatus{Phase: corev1.PodRunning},
	}
	if got := ClassifyPod(deleting); got.Event == EventAttemptStopped {
		t.Fatalf("a deleting-but-running pod must not be AttemptStopped yet")
	}
}

// The Pod phase cannot tell the two arms apart at the moment the experiment is about.
//
// "Failed" is the phase both for a workload that honoured SIGTERM and exited promptly and for one that
// ignored it until the grace period ran out and was killed — 143 against 137, the exact contrast the
// termination canary qualifies and the run itself could not observe. Recording the phase alone left the
// ledger unable to say which kind of stop it had watched, so a claim that a run exercised the SIGKILL path
// rested on the clock rather than on evidence.
//
// Mutation that turns this red: drop ExitCode from the ObservedState that ClassifyPod returns.
func TestClassifyPodRecordsWhichKindOfStopItObserved(t *testing.T) {
	stopped := func(phase corev1.PodPhase, codes ...int32) *corev1.Pod {
		p := &corev1.Pod{Status: corev1.PodStatus{Phase: phase}}
		for _, c := range codes {
			p.Status.ContainerStatuses = append(p.Status.ContainerStatuses, corev1.ContainerStatus{
				State: corev1.ContainerState{Terminated: &corev1.ContainerStateTerminated{ExitCode: c}},
			})
		}
		return p
	}
	for _, tc := range []struct {
		name string
		pod  *corev1.Pod
		want *int32
	}{
		{"a victim that honoured the signal", stopped(corev1.PodFailed, 143), new(int32(143))},
		{"a victim that was killed at the grace period", stopped(corev1.PodFailed, 137), new(int32(137))},
		{"a victim that ran out its own service", stopped(corev1.PodSucceeded, 0), new(int32(0))},
		// Absent rather than guessed: nothing here knows which container carried the workload.
		{"two terminated containers", stopped(corev1.PodFailed, 143, 0), nil},
		{"a terminal phase with no container status", stopped(corev1.PodFailed), nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := ClassifyPod(tc.pod)
			if got.Event != EventAttemptStopped {
				t.Fatalf("a terminal phase must be an AttemptStopped, got %q", got.Event)
			}
			switch {
			case tc.want == nil && got.ExitCode != nil:
				t.Fatalf("the exit code is ambiguous here, yet %d was reported as if measured", *got.ExitCode)
			case tc.want != nil && got.ExitCode == nil:
				t.Fatalf("exit %d was readable and was not recorded; the ledger then cannot tell this stop "+
					"from the other arm's", *tc.want)
			case tc.want != nil && *got.ExitCode != *tc.want:
				t.Fatalf("recorded exit %d, want %d", *got.ExitCode, *tc.want)
			}
		})
	}
}

//go:fix inline
