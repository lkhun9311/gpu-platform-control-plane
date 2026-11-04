package controller

import (
	"testing"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

func TestABareFenceNameStandsOnlyWhileTheJobHasSeenOneMachineOfThatName(t *testing.T) {
	ran := func(number int32, uids map[string]string, nodes ...string) platformv1.TrainingAttempt {
		return platformv1.TrainingAttempt{Number: number, Nodes: nodes, NodeUIDs: uids}
	}
	cases := []struct {
		name              string
		fenced            []string
		attempts          []platformv1.TrainingAttempt
		uid               string
		vouched, needsUID bool
	}{
		{name: "a bare name for the only machine of that name", fenced: []string{"n"},
			attempts: []platformv1.TrainingAttempt{ran(1, map[string]string{"n": "u1"}, "n")}, uid: "u1", vouched: true},
		{name: "the same machine in two attempts", fenced: []string{"n"},
			attempts: []platformv1.TrainingAttempt{ran(1, map[string]string{"n": "u1"}, "n"), ran(2, map[string]string{"n": "u1"}, "n")}, uid: "u1", vouched: true},
		{name: "a bare name left from another machine of that name", fenced: []string{"n"},
			attempts: []platformv1.TrainingAttempt{ran(1, map[string]string{"n": "u1"}, "n"), ran(2, map[string]string{"n": "u2"}, "n")}, uid: "u2", needsUID: true},
		{name: "the name bound to this attempt's machine", fenced: []string{"n@u2"},
			attempts: []platformv1.TrainingAttempt{ran(1, map[string]string{"n": "u1"}, "n"), ran(2, map[string]string{"n": "u2"}, "n")}, uid: "u2", vouched: true},
		{name: "the name bound to the earlier machine", fenced: []string{"n@u1"},
			attempts: []platformv1.TrainingAttempt{ran(1, map[string]string{"n": "u1"}, "n"), ran(2, map[string]string{"n": "u2"}, "n")}, uid: "u2", needsUID: true},
		{name: "an earlier attempt that found the name absent", fenced: []string{"n"},
			attempts: []platformv1.TrainingAttempt{ran(1, map[string]string{"n": nodeUIDAbsent}, "n"), ran(2, map[string]string{"n": "u2"}, "n")}, uid: "u2", needsUID: true},
		{name: "an earlier attempt recorded before UIDs were", fenced: []string{"n"},
			attempts: []platformv1.TrainingAttempt{ran(1, nil, "n"), ran(2, map[string]string{"n": "u2"}, "n")}, uid: "u2", needsUID: true},
		{name: "an attempt recorded before UIDs were is judged by the name", fenced: []string{"n"},
			attempts: []platformv1.TrainingAttempt{ran(1, map[string]string{"n": "u1"}, "n"), ran(2, nil, "n")}, uid: "", vouched: true},
		{name: "another node's entry", fenced: []string{"m", "m@u1"},
			attempts: []platformv1.TrainingAttempt{ran(1, map[string]string{"n": "u1"}, "n")}, uid: "u1"},
		{name: "no annotation", fenced: []string{""},
			attempts: []platformv1.TrainingAttempt{ran(1, map[string]string{"n": "u1"}, "n")}, uid: "u1"},
	}
	for _, c := range cases {
		cur := c.attempts[len(c.attempts)-1].Number
		vouched, needsUID := fenceVouches(c.fenced, c.attempts, cur, "n", c.uid)
		if vouched != c.vouched || needsUID != c.needsUID {
			t.Errorf("%s: vouched %v, needs n@uid %v; want %v, %v", c.name, vouched, needsUID, c.vouched, c.needsUID)
		}
	}
}
