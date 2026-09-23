package main

import (
	"context"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

// These specs cover verifyStateProbe, which had NO test when it shipped.
//
// What it checked, precisely: that the two Pod UIDs differ, that a claim of that name is Bound, and that the
// claim names a volume. What it did NOT check, and what its own registration page names: that the claim is
// the same OBJECT the probe created (name equality is not object equality), and that either Pod ran on the
// worker the probe took out of service.
//
// The UID comparison also had a defect of its own, and it is simpler than a first draft of this comment
// claimed. The function re-read both Pods into locals `w` and `r` — and then compared `writer.UID` and
// `reader.UID`, the PARAMETERS. The re-read was discarded entirely. So what it compared were the UIDs the
// caller's objects happened to carry, which against a fake apiserver that assigns none are empty on both
// sides; the `!= ""` guard then skipped the comparison silently. Against a real apiserver the values are
// present, because Create decodes the server's response back into the object it was given — so the defect
// is not "this could never fail in production", it is "this could never fail in any test, and the re-read
// it appeared to rely on was dead code".

const probeNode = "platform-worker"

// probeClaim is the probe's claim as the cluster holds it after binding.
func probeClaim(uid types.UID, phase corev1.PersistentVolumeClaimPhase, volume string) *corev1.PersistentVolumeClaim {
	return &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{Name: "queuelab-state", Namespace: canaryNamespace, UID: uid},
		Spec:       corev1.PersistentVolumeClaimSpec{VolumeName: volume},
		Status:     corev1.PersistentVolumeClaimStatus{Phase: phase},
	}
}

// probeHalf is one of the probe's Pods as the cluster holds it after scheduling.
func probeHalf(name string, uid types.UID, node string) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: canaryNamespace, UID: uid},
		Spec: corev1.PodSpec{
			NodeName:   node,
			Containers: []corev1.Container{{Name: probeTrainerContainer, Image: "i"}},
		},
		Status: corev1.PodStatus{Phase: corev1.PodSucceeded},
	}
}

// The control: everything the page registered, holding.
//
// Without it a verifier that refused every probe would satisfy every row below and make the mode unusable.
func TestTheProbeVerifierAcceptsWhatThePageRegistered(t *testing.T) {
	reader := probeHalf("sp-reader", "reader-uid", probeNode)
	c := fake.NewClientBuilder().WithScheme(testScheme(t)).
		WithObjects(probeClaim("claim-uid", corev1.ClaimBound, "pv-1"), reader).Build()

	err := verifyStateProbe(context.Background(), c,
		probeClaim("claim-uid", corev1.ClaimBound, "pv-1"),
		probeIdentities{claimUID: "claim-uid", writerUID: "writer-uid", writerNode: probeNode},
		reader, probeNode)
	if err != nil {
		t.Fatalf("a probe that met every registered condition was refused: %v", err)
	}
}

// An identity nobody assigned must be a refusal, not a comparison that passes vacuously.
//
// This is the row that would have caught the original defect. A fake apiserver assigns no UIDs, so the
// shipped verifier's `a != "" && b != "" && a == b` never compared anything — and the only test that could
// have noticed was one asserting that the ABSENCE is itself refused.
//
// Mutation that turns this red: guard the identity comparisons with `!= ""` instead of demanding them.
func TestTheProbeVerifierRefusesIdentitiesNobodyAssigned(t *testing.T) {
	for _, tc := range []struct {
		name   string
		ids    probeIdentities
		reader *corev1.Pod
		wants  string
	}{
		{
			name:   "no claim UID was captured at creation",
			ids:    probeIdentities{writerUID: "writer-uid", writerNode: probeNode},
			reader: probeHalf("sp-reader", "reader-uid", probeNode),
			wants:  "claim's UID",
		},
		{
			name:   "the writer's identity was never observed",
			ids:    probeIdentities{claimUID: "claim-uid", writerNode: probeNode},
			reader: probeHalf("sp-reader", "reader-uid", probeNode),
			wants:  "writer's UID",
		},
		{
			name:   "the writer's placement was never observed",
			ids:    probeIdentities{claimUID: "claim-uid", writerUID: "writer-uid"},
			reader: probeHalf("sp-reader", "reader-uid", probeNode),
			wants:  "writer's node",
		},
		{
			name:   "the reader was never scheduled anywhere",
			ids:    probeIdentities{claimUID: "claim-uid", writerUID: "writer-uid", writerNode: probeNode},
			reader: probeHalf("sp-reader", "reader-uid", ""),
			wants:  "reader's node",
		},
		{
			// The row a review found missing. Five identities are demanded and only four were driven, so the
			// reader's own UID was the one requirement in this block that no case exercised — which is the
			// same shape of gap as the vacuous comparison this whole file exists to replace.
			name:   "the reader carries no identity",
			ids:    probeIdentities{claimUID: "claim-uid", writerUID: "writer-uid", writerNode: probeNode},
			reader: probeHalf("sp-reader", "", probeNode),
			wants:  "reader's UID",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := fake.NewClientBuilder().WithScheme(testScheme(t)).
				WithObjects(probeClaim("claim-uid", corev1.ClaimBound, "pv-1"), tc.reader).Build()
			err := verifyStateProbe(context.Background(), c,
				probeClaim("claim-uid", corev1.ClaimBound, "pv-1"), tc.ids, tc.reader, probeNode)
			if err == nil {
				t.Fatal("the probe passed on an identity nothing established; a pass built on absent " +
					"identities is not a pass")
			}
			if !strings.Contains(err.Error(), tc.wants) {
				t.Fatalf("the refusal does not name %q: %v", tc.wants, err)
			}
		})
	}
}

// Point 4 of the registered criteria: the two halves must have shared an OBJECT, not a name.
//
// A claim deleted and recreated between the halves carries the same name in the same namespace and a
// different volume. The reader would read whatever that new volume held, and the shipped verifier — which
// asked only whether something named `queuelab-state` was Bound — would have called it a pass.
//
// Mutation that turns this red: compare the claim by name rather than by UID.
func TestTheProbeVerifierRefusesAClaimThatWasReplaced(t *testing.T) {
	reader := probeHalf("sp-reader", "reader-uid", probeNode)
	// Same name, same namespace, different object.
	c := fake.NewClientBuilder().WithScheme(testScheme(t)).
		WithObjects(probeClaim("claim-uid-AFTER", corev1.ClaimBound, "pv-2"), reader).Build()

	err := verifyStateProbe(context.Background(), c,
		probeClaim("claim-uid-BEFORE", corev1.ClaimBound, "pv-1"),
		probeIdentities{claimUID: "claim-uid-BEFORE", writerUID: "writer-uid", writerNode: probeNode},
		reader, probeNode)
	if err == nil {
		t.Fatal("a claim replaced between the two halves was accepted; the reader read some other volume")
	}
	if !strings.Contains(err.Error(), "did not share an object") {
		t.Fatalf("the refusal does not say what was actually wrong: %v", err)
	}
}

// Point 2: both halves must have run on the worker the probe took out of service.
//
// Placement is the SCHEDULER's decision — the probe deliberately does not pin spec.nodeName, because pinning
// it is what defeats WaitForFirstConsumer binding — so a probe that landed elsewhere exercised another
// node's storage path while this worker sat acquired and idle.
//
// Mutation that turns this red: drop the node comparison, or compare only one of the two halves.
func TestTheProbeVerifierRefusesAHalfThatRanElsewhere(t *testing.T) {
	for _, tc := range []struct {
		name       string
		writerNode string
		readerNode string
		wants      string
	}{
		{"the writer landed on another node", "some-other-node", probeNode, "writer ran on"},
		{"the reader landed on another node", probeNode, "some-other-node", "reader ran on"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reader := probeHalf("sp-reader", "reader-uid", tc.readerNode)
			c := fake.NewClientBuilder().WithScheme(testScheme(t)).
				WithObjects(probeClaim("claim-uid", corev1.ClaimBound, "pv-1"), reader).Build()

			err := verifyStateProbe(context.Background(), c,
				probeClaim("claim-uid", corev1.ClaimBound, "pv-1"),
				probeIdentities{claimUID: "claim-uid", writerUID: "writer-uid", writerNode: tc.writerNode},
				reader, probeNode)
			if err == nil {
				t.Fatal("a half that ran on another node was accepted, so the probe's conclusion is about " +
					"storage it did not take a worker for")
			}
			if !strings.Contains(err.Error(), tc.wants) {
				t.Fatalf("the refusal does not name which half moved: %v", err)
			}
		})
	}
}

// The handoff's own guarantee, kept: the reader must not be the writer.
//
// Mutation that turns this red: remove the writer/reader UID comparison.
func TestTheProbeVerifierRefusesAReaderThatIsTheWriter(t *testing.T) {
	reader := probeHalf("sp-reader", "same-uid", probeNode)
	c := fake.NewClientBuilder().WithScheme(testScheme(t)).
		WithObjects(probeClaim("claim-uid", corev1.ClaimBound, "pv-1"), reader).Build()

	err := verifyStateProbe(context.Background(), c,
		probeClaim("claim-uid", corev1.ClaimBound, "pv-1"),
		probeIdentities{claimUID: "claim-uid", writerUID: "same-uid", writerNode: probeNode},
		reader, probeNode)
	if err == nil {
		t.Fatal("the same Pod counted as both halves, so nothing was handed over")
	}
	if !strings.Contains(err.Error(), "same Pod") {
		t.Fatalf("the refusal does not say the halves were one Pod: %v", err)
	}
}

// The handoff must refuse to destroy what nobody has read yet.
//
// This is the row a perturbation asked for. Removing the capture upstream — so the writer is deleted and
// only then looked for — left every other test in this file green, because verifyStateProbe receives the
// identities ready-made and cannot tell who filled them in. The ordering IS the handoff's guarantee, and it
// had nothing behind it.
//
// Mutation that turns this red: drop the emptiness refusal from awaitProbeGone, or stop passing the
// captured identities to it.
func TestTheHandoffRefusesToDeleteAWriterItNeverObserved(t *testing.T) {
	for _, tc := range []struct {
		name string
		ids  probeIdentities
	}{
		{"nothing was captured at all", probeIdentities{claimUID: "claim-uid"}},
		{"the identity was captured and the placement was not",
			probeIdentities{claimUID: "claim-uid", writerUID: "writer-uid"}},
		{"the placement was captured and the identity was not",
			probeIdentities{claimUID: "claim-uid", writerNode: probeNode}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			writer := probeHalf("sp-writer", "writer-uid", probeNode)
			c := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(writer).Build()

			err := awaitProbeGone(context.Background(), c, writer, tc.ids,
				func() time.Time { return time.Unix(0, 0) }, func(time.Duration) {})
			if err == nil {
				t.Fatal("the writer was deleted before anything had read it; the verification that follows " +
					"would compare values nobody captured")
			}
			if !strings.Contains(err.Error(), "before its identity and placement were observed") {
				t.Fatalf("the refusal does not say what was skipped: %v", err)
			}
			// And it must not have deleted anything on the way to refusing.
			var still corev1.Pod
			if gerr := c.Get(context.Background(), client.ObjectKeyFromObject(writer), &still); gerr != nil {
				t.Fatalf("the writer was removed by a call that refused: %v", gerr)
			}
		})
	}
}

// A claim that is not Bound, or Bound to nothing, cannot support the reader's success.
//
// Mutation that turns this red: drop either the phase check or the VolumeName check.
func TestTheProbeVerifierRefusesAClaimThatBoundNothing(t *testing.T) {
	for _, tc := range []struct {
		name   string
		phase  corev1.PersistentVolumeClaimPhase
		volume string
		wants  string
	}{
		{"still pending", corev1.ClaimPending, "", "rather than Bound"},
		{"bound to no volume", corev1.ClaimBound, "", "names no volume"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reader := probeHalf("sp-reader", "reader-uid", probeNode)
			c := fake.NewClientBuilder().WithScheme(testScheme(t)).
				WithObjects(probeClaim("claim-uid", tc.phase, tc.volume), reader).Build()

			err := verifyStateProbe(context.Background(), c,
				probeClaim("claim-uid", tc.phase, tc.volume),
				probeIdentities{claimUID: "claim-uid", writerUID: "writer-uid", writerNode: probeNode},
				reader, probeNode)
			if err == nil {
				t.Fatalf("a claim that is %s with volume %q was accepted", tc.phase, tc.volume)
			}
			if !strings.Contains(err.Error(), tc.wants) {
				t.Fatalf("the refusal does not name the problem: %v", err)
			}
		})
	}
}
