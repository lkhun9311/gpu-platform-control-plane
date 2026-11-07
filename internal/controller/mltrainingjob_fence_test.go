package controller

import (
	"slices"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

func TestABareFenceNameStandsOnlyWhileTheJobHasSeenOneMachineOfThatName(t *testing.T) {
	ran := func(number int32, uid string) platformv1.TrainingAttempt {
		a := platformv1.TrainingAttempt{Number: number, Nodes: []string{"n"}}
		if uid != "" {
			a.NodeUIDs = map[string]string{"n": uid}
		}
		return a
	}
	cases := []struct {
		name              string
		fenced            []string
		attempts          []platformv1.TrainingAttempt
		vouched, needsUID bool
	}{
		{name: "a bare name for the only machine of that name", fenced: []string{"n"},
			attempts: []platformv1.TrainingAttempt{ran(1, "u1")}, vouched: true},
		{name: "the same machine in two attempts", fenced: []string{"n"},
			attempts: []platformv1.TrainingAttempt{ran(1, "u1"), ran(2, "u1")}, vouched: true},
		{name: "a bare name left from another machine of that name", fenced: []string{"n"},
			attempts: []platformv1.TrainingAttempt{ran(1, "u1"), ran(2, "u2")}, needsUID: true},
		{name: "the name bound to this attempt's machine", fenced: []string{"n@u2"},
			attempts: []platformv1.TrainingAttempt{ran(1, "u1"), ran(2, "u2")}, vouched: true},
		{name: "the name bound to the earlier machine", fenced: []string{"n@u1"},
			attempts: []platformv1.TrainingAttempt{ran(1, "u1"), ran(2, "u2")}, needsUID: true},
		{name: "an earlier attempt that found the name absent", fenced: []string{"n"},
			attempts: []platformv1.TrainingAttempt{ran(1, nodeUIDAbsent), ran(2, "u2")}, needsUID: true},
		{name: "two attempts that each found the name absent", fenced: []string{"n"},
			attempts: []platformv1.TrainingAttempt{ran(1, nodeUIDAbsent), ran(2, nodeUIDAbsent)}, needsUID: true},
		{name: "the absent word itself names no machine", fenced: []string{"n@" + nodeUIDAbsent},
			attempts: []platformv1.TrainingAttempt{ran(1, nodeUIDAbsent), ran(2, nodeUIDAbsent)}, needsUID: true},
		{name: "an absent machine acknowledged for an earlier attempt", fenced: []string{"n@absent-a1"},
			attempts: []platformv1.TrainingAttempt{ran(1, nodeUIDAbsent), ran(2, nodeUIDAbsent)}, needsUID: true},
		{name: "an absent machine acknowledged for this attempt", fenced: []string{"n@absent-a2"},
			attempts: []platformv1.TrainingAttempt{ran(1, nodeUIDAbsent), ran(2, nodeUIDAbsent)}, vouched: true},
		{name: "a bare name for an absent machine no other attempt ran on", fenced: []string{"n"},
			attempts: []platformv1.TrainingAttempt{ran(1, nodeUIDAbsent)}, vouched: true},
		{name: "an earlier attempt recorded before UIDs were", fenced: []string{"n"},
			attempts: []platformv1.TrainingAttempt{ran(1, ""), ran(2, "u2")}, needsUID: true},
		{name: "an attempt recorded before UIDs were is judged by the name", fenced: []string{"n"},
			attempts: []platformv1.TrainingAttempt{ran(1, "u1"), ran(2, "")}, vouched: true},
		{name: "another node's entry", fenced: []string{"m", "m@u1"},
			attempts: []platformv1.TrainingAttempt{ran(1, "u1")}},
		{name: "no annotation", fenced: []string{""},
			attempts: []platformv1.TrainingAttempt{ran(1, "u1")}},
	}
	for _, c := range cases {
		cur := c.attempts[len(c.attempts)-1].Number
		vouched, needsUID := fenceVouches(c.fenced, c.attempts, cur, "n")
		if vouched != c.vouched || needsUID != c.needsUID {
			t.Errorf("%s: vouched %v, needs n@id %v; want %v, %v", c.name, vouched, needsUID, c.vouched, c.needsUID)
		}
	}
}

// An entry an attempt stopped on is spent for later attempts, and a scoped entry speaks only for its attempt.
//
// Mutations that turn this red: ignore fencedBy, or keep an entry scoped to another attempt.
func TestAFenceEntryIsSpentByTheAttemptThatStoppedOnIt(t *testing.T) {
	spent := []platformv1.TrainingAttempt{
		{Number: 1, Nodes: []string{"n"}, FencedBy: []string{"n", "m@u1"}},
		{Number: 2, Nodes: []string{"n"}},
	}
	cases := []struct {
		name string
		raw  []string
		cur  int32
		want []string
	}{
		{name: "spent entries do not speak for a later attempt", raw: []string{"n", "m@u1"}, cur: 2, want: nil},
		{name: "they still spoke for the attempt that spent them", raw: []string{"n", "m@u1"}, cur: 1, want: []string{"n", "m@u1"}},
		{name: "an entry scoped to this attempt", raw: []string{"n#2"}, cur: 2, want: []string{"n"}},
		{name: "an entry scoped to another attempt", raw: []string{"n#1", "n@u2#3"}, cur: 2, want: nil},
		{name: "an unspent entry", raw: []string{" k ", ""}, cur: 2, want: []string{"k"}},
	}
	for _, c := range cases {
		if got := fenceEntries(c.raw, spent, c.cur); !slices.Equal(got, c.want) {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

// A node replaced before its rank was seen is pinned to the attempt, as an absent one is.
func TestAReplacedNodeIsPinnedToItsAttempt(t *testing.T) {
	a := platformv1.TrainingAttempt{Number: 3, NodeUIDs: map[string]string{"n": nodeUIDReplaced, "m": "u"}}
	if got := machineID(a, "n"); got != "replaced-a3" {
		t.Fatalf("machineID of a replaced node: %q", got)
	}
	if got := machineID(a, "m"); got != "u" {
		t.Fatalf("machineID of a recorded node: %q", got)
	}
}

// A terminal rank Pod is released only once its node is in its attempt's record, unless the job is being deleted and
// no next attempt needs the node; discover writes the record first, so only this test reaches the rule.
//
// Mutation that turns this red: drop the recorded check in rankStopped.
func TestARankIsReleasedOnlyOnceItsNodeIsRecorded(t *testing.T) {
	mltj := &platformv1.MLTrainingJob{Status: platformv1.MLTrainingJobStatus{Attempts: []platformv1.TrainingAttempt{{Number: 1}}}}
	p := &corev1.Pod{Labels: map[string]string{mltjAttemptLabel: "1"}, Spec: corev1.PodSpec{NodeName: "n"},
		Status: corev1.PodStatus{Phase: corev1.PodFailed, Conditions: []corev1.PodCondition{
			{Type: corev1.PodScheduled, Status: corev1.ConditionTrue, LastTransitionTime: metav1.NewTime(time.Unix(2000, 0))}}}}
	node := readyNode("n", "u", time.Unix(1000, 0), corev1.ConditionTrue)
	if rankStopped(mltj, p, true, node) {
		t.Fatal("released a terminal rank whose node is not recorded")
	}
	if !rankStopped(mltj, p, false, node) {
		t.Fatal("held a terminal rank when no record is needed")
	}
	mltj.Status.Attempts[0].Nodes = []string{"n"}
	if !rankStopped(mltj, p, true, node) {
		t.Fatal("held a terminal rank whose node is recorded")
	}
}

func readyNode(name, uid string, created time.Time, ready corev1.ConditionStatus) *corev1.Node {
	return &corev1.Node{Name: name, UID: types.UID(uid), CreationTimestamp: metav1.NewTime(created),
		Status: corev1.NodeStatus{Conditions: []corev1.NodeCondition{{Type: corev1.NodeReady, Status: ready}}}}
}

// A terminal phase is the kubelet's report only from a Ready Node that is the machine the rank ran on, and never when
// PodGC wrote it.
//
// Mutations that turn this red: drop any one of the four refusals in kubeletReported.
func TestATerminalPhaseCountsOnlyFromTheRanksOwnReadyNode(t *testing.T) {
	bound := time.Unix(2000, 0)
	pod := func(conds ...corev1.PodCondition) *corev1.Pod {
		return &corev1.Pod{Spec: corev1.PodSpec{NodeName: "n"}, Status: corev1.PodStatus{Phase: corev1.PodFailed,
			Conditions: append([]corev1.PodCondition{{Type: corev1.PodScheduled, Status: corev1.ConditionTrue,
				LastTransitionTime: metav1.NewTime(bound)}}, conds...)}}
	}
	podGC := corev1.PodCondition{Type: corev1.DisruptionTarget, Status: corev1.ConditionTrue, Reason: podGCReason}
	rec := &platformv1.TrainingAttempt{Number: 1, Nodes: []string{"n"}, NodeUIDs: map[string]string{"n": "u"}}
	cases := []struct {
		name string
		rec  *platformv1.TrainingAttempt
		p    *corev1.Pod
		node *corev1.Node
		want bool
	}{
		{"the recorded machine, Ready", rec, pod(), readyNode("n", "u", time.Unix(1000, 0), corev1.ConditionTrue), true},
		{"PodGC wrote it", rec, pod(podGC), readyNode("n", "u", time.Unix(1000, 0), corev1.ConditionTrue), false},
		{"the Node is gone", rec, pod(), nil, false},
		{"the Node is NotReady", rec, pod(), readyNode("n", "u", time.Unix(1000, 0), corev1.ConditionFalse), false},
		{"another machine under the name", rec, pod(), readyNode("n", "u2", time.Unix(1000, 0), corev1.ConditionTrue), false},
		{"no record, Node older than the binding", nil, pod(), readyNode("n", "u", time.Unix(1000, 0), corev1.ConditionTrue), true},
		{"no record, Node newer than the binding", nil, pod(), readyNode("n", "u", time.Unix(3000, 0), corev1.ConditionTrue), false},
	}
	for _, c := range cases {
		if got := kubeletReported(c.rec, c.p, c.node); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}
