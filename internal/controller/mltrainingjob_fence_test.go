package controller

import (
	"testing"

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
