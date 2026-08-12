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
	"context"
	"errors"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/queuelab"
)

// observationFor finds the observation for a named target, failing the test rather than returning a zero
// value: a missing observation is exactly the defect TestRecoverEmitsOneObservationPerEnumeratedTarget
// exists to catch, and a caller that silently got a zero-value observation back would test the wrong thing.
func observationFor(t *testing.T, obs []observation, name string) observation {
	t.Helper()
	for _, o := range obs {
		if o.Target.Name == name {
			return o
		}
	}
	t.Fatalf("no observation for target %q", name)
	return observation{}
}

// recoverTargets ranges over enumerate's output and emits exactly one observation per target, error paths
// included. The loop is the coverage guarantee: a target that produced no observation would silently not
// appear in the residue, and "no residue" would read as clear.
func TestRecoverEmitsOneObservationPerEnumeratedTarget(t *testing.T) {
	s := testSeed()
	want, err := enumerate(s)
	if err != nil {
		t.Fatalf("enumerate: %v", err)
	}
	c := fake.NewClientBuilder().WithScheme(fullScheme(t)).Build()
	got, err := recoverTargets(context.Background(), c, s, "tx-1")
	if err != nil {
		t.Fatalf("recover: %v", err)
	}
	if len(got) != len(want) {
		t.Fatalf("recover emitted %d observations for %d targets; an unobserved target vanishes from the residue", len(got), len(want))
	}
	seen := map[string]bool{}
	for _, o := range got {
		seen[o.Target.Name] = true
	}
	for _, tg := range want {
		if !seen[tg.Name] {
			t.Errorf("no observation for target %s %q", tg.Kind, tg.Name)
		}
	}
}

// A read that fails must still produce an observation carrying the error, because classifyAbsence turns that
// into absenceUnknown — residue. Skipping it would drop the target out of the audit entirely.
//
// The count check below is load-bearing, not decorative: every Get in this test fails, so a recoverTargets
// that silently dropped a target on read error (a `continue` instead of an append) would leave got empty,
// and the loop that follows would range over nothing and report no failure at all — the exact way a batch
// that "liked the look of nothing" would still read green.
func TestRecoverEmitsAnObservationEvenWhenTheReadFails(t *testing.T) {
	s := testSeed()
	want, err := enumerate(s)
	if err != nil {
		t.Fatalf("enumerate: %v", err)
	}
	c := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithInterceptorFuncs(interceptor.Funcs{
		Get: func(ctx context.Context, cl client.WithWatch, key client.ObjectKey, obj client.Object, opts ...client.GetOption) error {
			return errors.New("etcdserver: request timed out")
		},
	}).Build()
	got, err := recoverTargets(context.Background(), c, s, "tx-1")
	if err != nil {
		t.Fatalf("recover: %v", err)
	}
	if len(got) != len(want) {
		t.Fatalf("recover emitted %d observations for %d targets after every read failed; a dropped observation would misreport the batch as clean", len(got), len(want))
	}
	for _, o := range got {
		if o.Err == nil {
			t.Fatalf("%s carries no error after a failed read; it would classify as absent", o.Target.Name)
		}
		if classifyAbsence(o, o.WantUID) != absenceUnknown {
			t.Fatalf("%s classified as %v after a failed read, want unknown", o.Target.Name, classifyAbsence(o, o.WantUID))
		}
	}
}

// The UID is learned here, not supplied. An object found without our stamp is another run's, and must reach
// the caller as foreign rather than as a deletion candidate.
func TestRecoverLearnsOurUIDAndMarksAForeignObjectForeign(t *testing.T) {
	s := testSeed()
	c := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithObjects(
		&corev1.Namespace{ObjectMeta: metav1.ObjectMeta{
			Name: s.Namespace, UID: "ns-uid", Labels: map[string]string{queuelab.TxLabel: "tx-1"}}},
	).Build()
	got, err := recoverTargets(context.Background(), c, s, "tx-1")
	if err != nil {
		t.Fatalf("recover: %v", err)
	}
	ns := observationFor(t, got, s.Namespace)
	if ns.UID != "ns-uid" || ns.WantUID != "ns-uid" {
		t.Fatalf("namespace observation carries UID %q / WantUID %q, want both ns-uid: the UID is an output of this pass", ns.UID, ns.WantUID)
	}
	if classifyAbsence(ns, ns.WantUID) != absencePresent {
		t.Fatalf("our own stamped namespace classified as %v, want present", classifyAbsence(ns, ns.WantUID))
	}

}

// Ownership is established here, by stamp, and a foreign stamp is a refusal rather than an observation.
//
// classifyAbsence decides foreignness by UID comparison, which needs a UID we recorded for an object we
// created. For an object we never created there is no such UID, so recovery cannot express "foreign" as an
// observation without inventing one. It refuses instead — the same answer ensureNamespace gives at create.
// absenceForeign remains the executor's: during polling it re-reads with a WantUID this pass established,
// and an object replaced under that name mid-teardown is exactly what it detects.
func TestRecoverRefusesAnObjectStampedByAnotherTransaction(t *testing.T) {
	s := testSeed()
	c := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithObjects(
		&corev1.Namespace{ObjectMeta: metav1.ObjectMeta{
			Name: s.Namespace, UID: "theirs", Labels: map[string]string{queuelab.TxLabel: "tx-2"}}},
	).Build()
	if _, err := recoverTargets(context.Background(), c, s, "tx-1"); err == nil {
		t.Fatal("recovery adopted a namespace stamped by another transaction; deleting it would destroy another run's live state")
	}

	unstamped := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithObjects(
		&corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: s.Namespace, UID: "nobody"}},
	).Build()
	if _, err := recoverTargets(context.Background(), unstamped, s, "tx-1"); err == nil {
		t.Fatal("recovery adopted an unstamped namespace; it predates stamping or was created by something else, and either way is not ours to delete")
	}
}
