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

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
)

func testJournal() journal {
	return journal{
		Schema:  journalSchema,
		TxID:    "tx-1111",
		RunID:   "r7",
		Arm:     "A-honor",
		Node:    "platform-worker",
		NodeUID: "uid-node",
		TakenAt: "2026-08-06T10:00:00Z",
		Installed: installedTuple{
			LabelValue:  "r7",
			TaintValue:  "r7",
			TaintEffect: corev1.TaintEffectNoSchedule,
		},
	}
}

func TestJournalRoundTrips(t *testing.T) {
	s, err := encodeJournal(testJournal())
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	got, err := decodeJournal(s)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got != testJournal() {
		t.Fatalf("round trip changed the journal:\n got %+v\nwant %+v", got, testJournal())
	}
}

// A state machine that trusts this annotation must not accept a document it does not fully understand,
// so an unknown field and an unknown schema are both rejected rather than ignored.
func TestDecodeJournalRejectsUnknownFieldAndSchema(t *testing.T) {
	for name, raw := range map[string]string{
		"unknown field": `{"schema":1,"txID":"tx-1111","runID":"r7","arm":"A-honor","node":"platform-worker",` +
			`"nodeUID":"uid-node","takenAt":"t","installed":{"labelValue":"r7","taintValue":"r7",` +
			`"taintEffect":"NoSchedule"},"extra":true}`,
		"unknown schema": `{"schema":99,"txID":"tx-1111","runID":"r7","arm":"A-honor","node":"platform-worker",` +
			`"nodeUID":"uid-node","takenAt":"t","installed":{"labelValue":"r7","taintValue":"r7",` +
			`"taintEffect":"NoSchedule"}}`,
		"trailing data": `{"schema":1,"txID":"tx-1111","runID":"r7","arm":"A-honor","node":"platform-worker",` +
			`"nodeUID":"uid-node","takenAt":"t","installed":{"labelValue":"r7","taintValue":"r7",` +
			`"taintEffect":"NoSchedule"}} {"schema":1}`,
		"missing txid": `{"schema":1,"txID":"","runID":"r7","arm":"A-honor","node":"platform-worker",` +
			`"nodeUID":"uid-node","takenAt":"t","installed":{"labelValue":"r7","taintValue":"r7",` +
			`"taintEffect":"NoSchedule"}}`,
	} {
		if _, err := decodeJournal(raw); err == nil {
			t.Fatalf("%s: expected rejection", name)
		}
	}
}

func node(labels map[string]string, ann map[string]string, taints ...corev1.Taint) *corev1.Node {
	return &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{
			Name:        "platform-worker",
			UID:         types.UID("uid-node"),
			Labels:      labels,
			Annotations: ann,
		},
		Spec: corev1.NodeSpec{Taints: taints},
	}
}

func ourTaint() corev1.Taint {
	return corev1.Taint{Key: workerTaintKey, Value: "r7", Effect: corev1.TaintEffectNoSchedule}
}

// The free state is the ONLY state acquisition may proceed from, so each row here is a named refusal and
// the matrix is the specification: anything not on this list must still refuse by falling through.
func TestDecideAcquireRefusesEveryNonFreeState(t *testing.T) {
	good, err := encodeJournal(testJournal())
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	foreign := testJournal()
	foreign.TxID = "tx-other"
	foreign.RunID = "r9"
	foreignRaw, err := encodeJournal(foreign)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}

	cases := map[string]struct {
		n    *corev1.Node
		want string
	}{
		"foreign owner": {
			node(map[string]string{workerLabelKey: "r9"}, map[string]string{journalKey: foreignRaw},
				corev1.Taint{Key: workerTaintKey, Value: "r9", Effect: corev1.TaintEffectNoSchedule}),
			reasonForeignOwner,
		},
		"our own txid again": {
			node(map[string]string{workerLabelKey: "r7"}, map[string]string{journalKey: good}, ourTaint()),
			reasonOwnTxID,
		},
		"marker without journal": {
			node(map[string]string{workerLabelKey: "r7"}, nil, ourTaint()),
			reasonMarkerWithoutJournal,
		},
		"journal without marker": {
			node(nil, map[string]string{journalKey: good}),
			reasonJournalWithoutMarker,
		},
		"label without taint": {
			node(map[string]string{workerLabelKey: "r7"}, nil),
			reasonMarkerWithoutJournal,
		},
		"taint without label": {
			node(nil, nil, ourTaint()),
			reasonMarkerWithoutJournal,
		},
		"duplicate taint key with different effects": {
			node(map[string]string{workerLabelKey: "r7"}, map[string]string{journalKey: good}, ourTaint(),
				corev1.Taint{Key: workerTaintKey, Value: "r7", Effect: corev1.TaintEffectNoExecute}),
			reasonDuplicateTaintKey,
		},
		"unparseable journal": {
			node(map[string]string{workerLabelKey: "r7"}, map[string]string{journalKey: "{"}, ourTaint()),
			reasonBadJournal,
		},
		"quarantined": {
			node(nil, map[string]string{quarantineKey: `{"schema":1,"quarantineID":"q1","forcedAt":"t",` +
				`"node":"platform-worker","nodeUID":"uid-node","priorJournal":"","observedLabel":""}`}),
			reasonQuarantined,
		},
	}

	for name, tc := range cases {
		obs := observe(tc.n)
		if _, err := decideAcquire(obs, tc.n, "tx-1111", "r7", "A-honor", "t"); err == nil {
			t.Fatalf("%s: acquisition must refuse", name)
		} else {
			var r *refusal
			if !asRefusal(err, &r) {
				t.Fatalf("%s: want a named refusal, got %T: %v", name, err, err)
			}
			if r.Reason != tc.want {
				t.Fatalf("%s: refusal %q, want %q", name, r.Reason, tc.want)
			}
		}
	}
}

func TestDecideAcquireProceedsOnlyFromTheFreeState(t *testing.T) {
	// An unrelated taint is not a reason to refuse: this repository's own nodehealth controller taints the
	// worker with its distinct unhealthy key and that must not block the lab.
	n := node(map[string]string{"kubernetes.io/hostname": "platform-worker"}, map[string]string{"other": "x"},
		corev1.Taint{Key: "gpu-platform/unhealthy", Value: "true", Effect: corev1.TaintEffectNoSchedule})
	j, err := decideAcquire(observe(n), n, "tx-1111", "r7", "A-honor", "2026-08-06T10:00:00Z")
	if err != nil {
		t.Fatalf("free node must be acquirable: %v", err)
	}
	if j.TxID != "tx-1111" || j.RunID != "r7" || j.Arm != "A-honor" || j.NodeUID != "uid-node" {
		t.Fatalf("journal does not identify the transaction: %+v", j)
	}
	if j.Installed.LabelValue != "r7" || j.Installed.TaintValue != "r7" ||
		j.Installed.TaintEffect != corev1.TaintEffectNoSchedule {
		t.Fatalf("journal must record exactly what will be installed: %+v", j.Installed)
	}
}

func TestDecideRelease(t *testing.T) {
	good, err := encodeJournal(testJournal())
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	foreign := testJournal()
	foreign.TxID = "tx-other"
	foreignRaw, err := encodeJournal(foreign)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}

	t.Run("restores when the installed tuple is intact", func(t *testing.T) {
		n := node(map[string]string{workerLabelKey: "r7"}, map[string]string{journalKey: good}, ourTaint())
		act, err := decideRelease(observe(n), "tx-1111")
		if err != nil || act != releaseRestore {
			t.Fatalf("got %v, %v; want releaseRestore, nil", act, err)
		}
	})

	// An unrelated taint added while the run was in flight is benign drift, not divergence: only the values
	// this transaction installed are compared.
	t.Run("tolerates an unrelated taint added mid-run", func(t *testing.T) {
		n := node(map[string]string{workerLabelKey: "r7"}, map[string]string{journalKey: good}, ourTaint(),
			corev1.Taint{Key: "gpu-platform/unhealthy", Value: "true", Effect: corev1.TaintEffectNoSchedule})
		act, err := decideRelease(observe(n), "tx-1111")
		if err != nil || act != releaseRestore {
			t.Fatalf("got %v, %v; want releaseRestore, nil", act, err)
		}
	})

	t.Run("already released is success, not failure", func(t *testing.T) {
		n := node(nil, nil)
		act, err := decideRelease(observe(n), "tx-1111")
		if err != nil || act != releaseAlreadyDone {
			t.Fatalf("got %v, %v; want releaseAlreadyDone, nil", act, err)
		}
	})

	// A forced break removed our state and left a quarantine record; that is a restoration FAILURE, not the
	// clean already-released case, or a run whose worker was taken from it could still publish a number.
	t.Run("quarantine is a restoration failure", func(t *testing.T) {
		n := node(nil, map[string]string{quarantineKey: `{"schema":1,"quarantineID":"q1","forcedAt":"t",` +
			`"node":"platform-worker","nodeUID":"uid-node","priorJournal":"","observedLabel":""}`})
		if _, err := decideRelease(observe(n), "tx-1111"); err == nil {
			t.Fatal("a quarantined node must fail release")
		}
	})

	t.Run("a diverged installed value refuses to restore", func(t *testing.T) {
		n := node(map[string]string{workerLabelKey: "someone-else"}, map[string]string{journalKey: good},
			ourTaint())
		_, err := decideRelease(observe(n), "tx-1111")
		var r *refusal
		if err == nil || !asRefusal(err, &r) || r.Reason != reasonInstalledDiverged {
			t.Fatalf("want %s, got %v", reasonInstalledDiverged, err)
		}
	})

	t.Run("a foreign journal is never restored from", func(t *testing.T) {
		n := node(map[string]string{workerLabelKey: "r7"}, map[string]string{journalKey: foreignRaw}, ourTaint())
		_, err := decideRelease(observe(n), "tx-1111")
		var r *refusal
		if err == nil || !asRefusal(err, &r) || r.Reason != reasonNotOurs {
			t.Fatalf("want %s, got %v", reasonNotOurs, err)
		}
	})
}

// RFC 7386 merge patch replaces spec.taints wholesale, so the new list must be built from the list we just
// observed or an unrelated taint would be deleted as a side effect of dedicating the worker.
func TestTaintListPreservesUnrelatedTaints(t *testing.T) {
	unrelated := corev1.Taint{Key: "gpu-platform/unhealthy", Value: "true", Effect: corev1.TaintEffectNoSchedule}
	got := withOwnershipTaint([]corev1.Taint{unrelated}, "r7")
	if len(got) != 2 {
		t.Fatalf("want the unrelated taint kept plus ours, got %+v", got)
	}
	if got[0] != unrelated {
		t.Fatalf("unrelated taint was not preserved: %+v", got)
	}
	if got[1].Key != workerTaintKey || got[1].Value != "r7" || got[1].Effect != corev1.TaintEffectNoSchedule {
		t.Fatalf("ownership taint not appended correctly: %+v", got[1])
	}

	back := withoutOwnershipTaint(got)
	if len(back) != 1 || back[0] != unrelated {
		t.Fatalf("release must remove only our taint, got %+v", back)
	}
}

// decodeQuarantine's strictness is what the whole two-step design leans on to trust the record it reads
// back, and the happy-path round trip embedded in the other quarantine tests would still pass if any one of
// these four checks (unknown fields, unknown schema, empty quarantineID, trailing data) were silently
// dropped.
//
// The trailing-data row is the one decodeJournal always had and this decoder did not: two documents in one
// annotation means the second one was written by something other than encodeQuarantine, and decideClear
// matches the operator's -quarantine-id against whichever of them happened to decode first.
func TestDecodeQuarantineRejectsUnknownFieldSchemaEmptyIDAndTrailingData(t *testing.T) {
	for name, raw := range map[string]string{
		"unknown field": `{"schema":1,"quarantineID":"q1","forcedAt":"t","node":"platform-worker",` +
			`"nodeUID":"uid-node","priorJournal":"","observedLabel":"","extra":true}`,
		"unknown schema": `{"schema":99,"quarantineID":"q1","forcedAt":"t","node":"platform-worker",` +
			`"nodeUID":"uid-node","priorJournal":"","observedLabel":""}`,
		"empty quarantineID": `{"schema":1,"quarantineID":"","forcedAt":"t","node":"platform-worker",` +
			`"nodeUID":"uid-node","priorJournal":"","observedLabel":""}`,
		"trailing data": `{"schema":1,"quarantineID":"q1","forcedAt":"t","node":"platform-worker",` +
			`"nodeUID":"uid-node","priorJournal":"","observedLabel":""} {"schema":1,"quarantineID":"q2"}`,
		"trailing garbage": `{"schema":1,"quarantineID":"q1","forcedAt":"t","node":"platform-worker",` +
			`"nodeUID":"uid-node","priorJournal":"","observedLabel":""} not json at all`,
	} {
		if _, err := decodeQuarantine(raw); err == nil {
			t.Fatalf("%s: expected rejection", name)
		}
	}
}

// Forcing twice would overwrite the original record with one describing an already-emptied node, which
// would destroy the only surviving evidence of who held the worker.
func TestDecideForceRefusesWhenAlreadyQuarantined(t *testing.T) {
	q := quarantine{Schema: quarantineSchema, QuarantineID: "q1", ForcedAt: "t", Node: "platform-worker",
		NodeUID: "uid-node"}
	raw, err := encodeQuarantine(q)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	n := node(nil, map[string]string{quarantineKey: raw})
	if _, err := decideForce(observe(n), "uid-node", "q2", "t2"); err == nil {
		t.Fatal("forcing an already quarantined node must refuse")
	}
}

// The forced break must preserve everything it removed — which node, when, and exactly what was on it — or
// the operator loses the evidence of what they broke. Node, NodeUID and ForcedAt are asserted here too
// (not just PriorJournal/ObservedLabel/ObservedTaints): those three are exactly what tells an operator
// which machine was broken and at what time if the record is ever read on its own, and dropping any one of
// the six fields checked below must fail this test, not just the round-trip test elsewhere in this file.
func TestDecideForceRecordsWhatItRemoves(t *testing.T) {
	good, err := encodeJournal(testJournal())
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	// An unrelated taint alongside the ownership one is what makes ObservedTaints meaningful to assert: with
	// only the ownership taint present, a record built from obs.AllTaints (the whole taint list) would look
	// identical to one correctly built from obs.Taints (the ownership-key subset), and this test would not
	// catch the difference.
	unrelated := corev1.Taint{Key: "gpu-platform/unhealthy", Value: "true", Effect: corev1.TaintEffectNoSchedule}
	n := node(map[string]string{workerLabelKey: "r7"}, map[string]string{journalKey: good}, ourTaint(), unrelated)
	q, err := decideForce(observe(n), "uid-node", "q1", "2026-08-06T11:00:00Z")
	if err != nil {
		t.Fatalf("force: %v", err)
	}
	if q.QuarantineID == "" {
		t.Fatal("a quarantine must be identified so clearing it can be targeted")
	}
	if q.ForcedAt != "2026-08-06T11:00:00Z" {
		t.Fatalf("forcedAt = %q, want the caller's timestamp", q.ForcedAt)
	}
	if q.Node != "platform-worker" {
		t.Fatalf("node = %q, want platform-worker", q.Node)
	}
	if q.NodeUID != "uid-node" {
		t.Fatalf("nodeUID = %q, want uid-node", q.NodeUID)
	}
	if q.PriorJournal != good {
		t.Fatalf("the prior journal must be preserved verbatim, got %q", q.PriorJournal)
	}
	if q.ObservedLabel != "r7" {
		t.Fatalf("observedLabel = %q, want r7", q.ObservedLabel)
	}
	if len(q.ObservedTaints) != 1 || q.ObservedTaints[0] != ourTaint() {
		t.Fatalf("observedTaints must be exactly the ownership taint, not the unrelated one, got %+v",
			q.ObservedTaints)
	}
}

func TestDecideForceRefusesAWrongNodeUID(t *testing.T) {
	n := node(map[string]string{workerLabelKey: "r7"}, nil, ourTaint())
	if _, err := decideForce(observe(n), "uid-typed-wrong", "q1", "t"); err == nil {
		t.Fatal("a mistyped node UID must refuse: it is the operator's confirmation of the target")
	}
}

func TestDecideClearRequiresTheExactQuarantineID(t *testing.T) {
	q := quarantine{Schema: quarantineSchema, QuarantineID: "q1", ForcedAt: "t", Node: "platform-worker",
		NodeUID: "uid-node"}
	raw, err := encodeQuarantine(q)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	n := node(nil, map[string]string{quarantineKey: raw})
	if err := decideClear(observe(n), "q-wrong"); err == nil {
		t.Fatal("clearing must be targeted at the exact quarantine record")
	}
	if err := decideClear(observe(n), "q1"); err != nil {
		t.Fatalf("the matching id must clear: %v", err)
	}
	if err := decideClear(observe(node(nil, nil)), "q1"); err == nil {
		t.Fatal("clearing a node with no quarantine record must refuse rather than silently succeed")
	}
}

// withOwnershipTaint replaces the deleted upsertTaint's de-duplication role: a retried acquire attempt must
// not leave two entries under workerTaintKey, or decideAcquire's own duplicate-taint-key check would refuse
// a Node this transaction just wrote.
func TestWithOwnershipTaintReplacesStaleValue(t *testing.T) {
	stale := corev1.Taint{Key: workerTaintKey, Value: "old-run", Effect: corev1.TaintEffectNoSchedule}
	got := withOwnershipTaint([]corev1.Taint{stale}, "new-run")
	if len(got) != 1 {
		t.Fatalf("want exactly one taint under %s, got %+v", workerTaintKey, got)
	}
	if got[0].Value != "new-run" {
		t.Fatalf("stale taint value was not replaced: %+v", got[0])
	}
}
