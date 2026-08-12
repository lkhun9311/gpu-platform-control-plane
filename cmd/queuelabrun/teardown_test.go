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

package main

import (
	"errors"
	"testing"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/queuelab"
)

func testSeed() seed {
	return seed{
		Schema: teardownSeedSchema, TxID: "tx-1", RunID: "r1", Arm: "A-honor",
		Study: queuelab.StudyReclaim, Variant: "Any", Namespace: "queuelab-r1",
	}
}

// The whole point of a seed written before the first Create is that the deletion set regenerates from it
// after a crash, so enumerate must name every object the fixture builder would have created — not a subset
// it happened to remember.
func TestEnumerateNamesEveryFixtureTheBuilderCreates(t *testing.T) {
	s := testSeed()
	fs, err := queuelab.BuildFixtures(s.Study, s.Variant, s.RunID, s.Namespace)
	if err != nil {
		t.Fatalf("build fixtures: %v", err)
	}

	// LocalQueues are deliberately absent from the want set: they live in the namespace and are removed with
	// it, so enumerating them would make the deletion set claim an authority the namespace already has.
	want := map[string]string{s.Namespace: "Namespace", fs.Flavor.GetName(): "ResourceFlavor"}
	for _, cq := range fs.ClusterQueue {
		want[cq.GetName()] = "ClusterQueue"
	}

	got, err := enumerate(s)
	if err != nil {
		t.Fatalf("enumerate: %v", err)
	}
	gotByName := map[string]string{}
	for _, tg := range got {
		if prev, dup := gotByName[tg.Name]; dup {
			t.Fatalf("enumerate returned %q twice (%s then %s)", tg.Name, prev, tg.Kind)
		}
		gotByName[tg.Name] = tg.Kind
	}

	for name, kind := range want {
		if gotByName[name] != kind {
			t.Errorf("enumerate missed %s %q (got kind %q)", kind, name, gotByName[name])
		}
	}
	for name, kind := range gotByName {
		if want[name] == "" {
			t.Errorf("enumerate invented %s %q, which the builder never creates", kind, name)
		}
	}
}

// The order is forced by Kueue's finalizers and must be a declared property of the returned slice, because
// an executor that has to sort the targets itself is an executor that can sort them wrongly.
func TestEnumerateReturnsTargetsInDeletionOrder(t *testing.T) {
	got, err := enumerate(testSeed())
	if err != nil {
		t.Fatalf("enumerate: %v", err)
	}
	last := teardownPhase(-1)
	for _, tg := range got {
		if tg.Phase < last {
			t.Fatalf("target %s %q in phase %d came after phase %d", tg.Kind, tg.Name, tg.Phase, last)
		}
		last = tg.Phase
	}
	// enumerate returning an empty slice with a nil error would otherwise reach the next two index
	// expressions and panic the whole test binary, which crashes the process rather than failing this
	// test cleanly and silently prevents every test declared after this one from running at all.
	if len(got) == 0 {
		t.Fatalf("enumerate returned no targets")
	}
	if got[0].Kind != "Namespace" {
		t.Fatalf("first target is %s, want Namespace: a ClusterQueue deleted while a Workload still reserves it blocks on resource-in-use forever", got[0].Kind)
	}
	if got[len(got)-1].Kind != "ResourceFlavor" {
		t.Fatalf("last target is %s, want ResourceFlavor: it carries the same finalizer and every referencing ClusterQueue must be absent first", got[len(got)-1].Kind)
	}
}

// A seed missing a field yields names like "queuelab-" that match objects this run never created, which is
// the blast radius the guard exists to bound.
func TestEnumerateRefusesAnIncompleteSeed(t *testing.T) {
	for _, tc := range []struct {
		field string
		mut   func(*seed)
	}{
		{"txID", func(s *seed) { s.TxID = "" }},
		{"runID", func(s *seed) { s.RunID = "" }},
		{"arm", func(s *seed) { s.Arm = "" }},
		{"study", func(s *seed) { s.Study = "" }},
		{"variant", func(s *seed) { s.Variant = "" }},
		{"namespace", func(s *seed) { s.Namespace = "" }},
	} {
		s := testSeed()
		tc.mut(&s)
		if _, err := enumerate(s); err == nil {
			t.Errorf("enumerate accepted a seed with an empty %s", tc.field)
		}
	}
	s := testSeed()
	s.Schema = teardownSeedSchema + 1
	if _, err := enumerate(s); err == nil {
		t.Error("enumerate accepted a seed from an unknown schema, whose names a different enumerate produced")
	}
}

// An object carrying a deletionTimestamp has been asked to go away and has not gone away. Treating that as
// absence is the exact error this whole piece exists to prevent: it asserts deletion was requested, not that
// it happened.
func TestTerminatingIsNotAbsent(t *testing.T) {
	obs := observation{Target: target{Kind: "Namespace", Name: "queuelab-r1"}, Found: true, UID: "u1", Terminating: true}
	if got := classifyAbsence(obs, "u1"); got != absencePresent {
		t.Fatalf("a terminating object classified as %v, want present", got)
	}
}

// A read that failed says nothing about the object, and a teardown that reports zero residue from a failed
// read is reporting a guess as a result.
func TestAReadErrorIsUnknownNotAbsent(t *testing.T) {
	obs := observation{Target: target{Kind: "ClusterQueue", Name: "ql-reclaim-tenant-a-r1"}, Err: errors.New("etcdserver: request timed out")}
	if got := classifyAbsence(obs, "u1"); got != absenceUnknown {
		t.Fatalf("a failed read classified as %v, want unknown", got)
	}
}

// NotFound on a name proves the name is free, not that this run's object was deleted: the runner derives its
// namespace from the run id alone and today adopts one it did not create, so a name can be absent because it
// never existed, because someone else's was deleted, or because ours was deleted and recreated. A found
// object under a different UID is a name collision this run must refuse to touch, not a routine "present"
// indistinguishable from our own live object — an executor that cannot tell the two apart from the returned
// classification alone cannot refuse to delete the one it does not own.
func TestAbsenceIsCreditedOnlyAgainstTheRecordedUID(t *testing.T) {
	mine := observation{Target: target{Kind: "Namespace", Name: "queuelab-r1"}, Found: true, UID: "ours"}
	if got := classifyAbsence(mine, "ours"); got != absencePresent {
		t.Fatalf("our own live namespace classified as %v, want present", got)
	}
	theirs := observation{Target: target{Kind: "Namespace", Name: "queuelab-r1"}, Found: true, UID: "somebody-else"}
	if got := classifyAbsence(theirs, "ours"); got != absenceForeign {
		t.Fatalf("a different UID under our name classified as %v; it must never become a deletion target", got)
	}
	if classifyAbsence(mine, "ours") == classifyAbsence(theirs, "ours") {
		t.Fatal("ours and somebody else's classify identically; the executor cannot refuse what it cannot see")
	}
	gone := observation{Target: target{Kind: "Namespace", Name: "queuelab-r1"}, Found: false}
	if got := classifyAbsence(gone, "ours"); got != absenceAbsent {
		t.Fatalf("NotFound with a recorded UID classified as %v, want absent", got)
	}
}

// The zero value is load-bearing: a map miss, an unset field, or a code path that forgets to classify must
// read as unknown, never as absence.
func TestUnclassifiedIsUnknown(t *testing.T) {
	var a absence
	if a != absenceUnknown {
		t.Fatalf("the zero absence is %v, want unknown; an unclassified observation must never read as gone", a)
	}
}

// residual is what the executor persists, so anything not proven absent has to survive into it — including
// the unknowns, which are the ones a hurried reader will otherwise treat as fine, and the foreign ones,
// which residual must carry forward on WantUID rather than a second lookup structure the caller could
// populate inconsistently.
func TestResidualKeepsEverythingNotProvenAbsent(t *testing.T) {
	in := []observation{
		{Target: target{Name: "gone"}, Found: false},
		{Target: target{Name: "stuck"}, Found: true, UID: "u", WantUID: "u", Terminating: true},
		{Target: target{Name: "unreadable"}, Err: errors.New("boom")},
		{Target: target{Name: "squatted"}, Found: true, UID: "other", WantUID: "ours"},
	}
	got := residual(in)
	if len(got) != 3 {
		t.Fatalf("residual kept %d observations, want 3 (the terminating one, the unreadable one, and the squatted one)", len(got))
	}
	byName := map[string]observation{}
	for _, o := range got {
		if o.Target.Name == "gone" {
			t.Fatal("residual kept an object proven absent")
		}
		byName[o.Target.Name] = o
	}
	squatted, ok := byName["squatted"]
	if !ok {
		t.Fatal("residual dropped the squatted observation, whose recorded UID this run does not own")
	}
	if got := classifyAbsence(squatted, squatted.WantUID); got != absenceForeign {
		t.Fatalf("the squatted observation classifies as %v via residual's WantUID wiring, want foreign", got)
	}
}
