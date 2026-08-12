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
