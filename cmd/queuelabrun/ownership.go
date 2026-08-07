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
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	corev1 "k8s.io/api/core/v1"
)

// The ownership keys are the ones the ResourceFlavor selects on, so they are functional state and not
// bookkeeping: internal/queuelab's flavor pins NodeLabels{workerLabelKey: runID} and a matching taint.
const (
	workerLabelKey = "queuelab.gpu-platform/worker"
	workerTaintKey = "queuelab.gpu-platform/dedicated"
	// The journal lives on the Node rather than in the run's namespace because piece 3's namespace teardown
	// would delete the only record of who owns the worker.
	journalKey = "queuelab.gpu-platform/ownership-journal"
	// A forced break leaves this record instead of a free Node, because nothing can prove the previous
	// process is dead and a free Node would let a second run acquire underneath a live one.
	quarantineKey    = "queuelab.gpu-platform/quarantine"
	journalSchema    = 1
	quarantineSchema = 1
)

// installedTuple is exactly what this transaction wrote, so release can prove nothing moved before it
// removes anything.
type installedTuple struct {
	LabelValue  string             `json:"labelValue"`
	TaintValue  string             `json:"taintValue"`
	TaintEffect corev1.TaintEffect `json:"taintEffect"`
}

// journal identifies the transaction by a generated TxID rather than the human run id, because a reused
// run id is already a known confound and must not be able to authorise a release.
type journal struct {
	Schema    int            `json:"schema"`
	TxID      string         `json:"txID"`
	RunID     string         `json:"runID"`
	Arm       string         `json:"arm"`
	Node      string         `json:"node"`
	NodeUID   string         `json:"nodeUID"`
	TakenAt   string         `json:"takenAt"`
	Installed installedTuple `json:"installed"`
}

func encodeJournal(j journal) (string, error) {
	b, err := json.Marshal(j)
	if err != nil {
		return "", fmt.Errorf("encode journal: %w", err)
	}
	return string(b), nil
}

// decodeJournal refuses anything it does not fully understand.
//
// A state machine that decides who owns a GPU worker must not proceed from a document with fields it
// silently ignored, so unknown fields, trailing data and unknown schemas are all errors.
func decodeJournal(s string) (journal, error) {
	dec := json.NewDecoder(strings.NewReader(s))
	dec.DisallowUnknownFields()
	var j journal
	if err := dec.Decode(&j); err != nil {
		return journal{}, fmt.Errorf("decode journal: %w", err)
	}
	if dec.More() {
		return journal{}, fmt.Errorf("decode journal: trailing data after the document")
	}
	if j.Schema != journalSchema {
		return journal{}, fmt.Errorf("decode journal: schema %d is not %d", j.Schema, journalSchema)
	}
	for name, v := range map[string]string{
		"txID": j.TxID, "runID": j.RunID, "arm": j.Arm, "node": j.Node, "nodeUID": j.NodeUID,
		"installed.labelValue": j.Installed.LabelValue, "installed.taintValue": j.Installed.TaintValue,
		"installed.taintEffect": string(j.Installed.TaintEffect),
	} {
		if v == "" {
			return journal{}, fmt.Errorf("decode journal: %s is empty", name)
		}
	}
	return j, nil
}

// The refusal reasons are named constants because the tests assert on them: an ownership state machine
// whose refusals are only free-text drifts silently when someone rewords an error.
const (
	reasonForeignOwner         = "foreign-owner"
	reasonOwnTxID              = "own-transaction-id"
	reasonMarkerWithoutJournal = "marker-without-journal"
	reasonJournalWithoutMarker = "journal-without-marker"
	reasonDuplicateTaintKey    = "duplicate-taint-key"
	reasonBadJournal           = "unreadable-journal"
	// reasonBadQuarantine is its own reason rather than reasonBadJournal because the two states send an
	// operator to different places: an unreadable journal can still be broken with -force-release, while an
	// unreadable QUARANTINE record is the one state this tool has no remaining move for, and a refusal that
	// is only free text cannot be classified by anything reading it.
	reasonBadQuarantine     = "unreadable-quarantine-record"
	reasonQuarantined       = "quarantined"
	reasonWrongNode         = "journal-names-another-node"
	reasonInstalledDiverged = "installed-values-diverged"
	reasonNotOurs           = "not-our-transaction"
	// reasonOwnershipLost is the run's own release finding nothing of its to undo, which is never the clean
	// already-released case: markers this run provably installed can only be absent because something else
	// removed them while the run was still holding the worker.
	reasonOwnershipLost = "ownership-lost-mid-run"
)

type refusal struct {
	Reason string
	Detail string
}

func (r *refusal) Error() string { return r.Reason + ": " + r.Detail }

func refuse(reason, format string, args ...any) error {
	return &refusal{Reason: reason, Detail: fmt.Sprintf(format, args...)}
}

// asRefusal is errors.As specialised to *refusal, kept here so the tests and the operator modes agree on
// how a refusal is recognised.
//
// It has to unwrap rather than type-assert: every call site that reports a refusal to a human wraps it with
// fmt.Errorf to say which node and which operation it came from, and a bare type assertion would stop
// recognising a refusal the moment it travelled through any of that wrapping.
func asRefusal(err error, target **refusal) bool {
	return errors.As(err, target)
}

// ownership is the Node reduced to the state the decisions actually depend on.
type ownership struct {
	NodeName   string
	NodeUID    string
	HasLabel   bool
	LabelValue string
	// Taints holds only the ownership-key taints, which are the ones the decisions compare.
	Taints []corev1.Taint
	// AllTaints holds the whole observed list, because the merge patch replaces spec.taints wholesale and
	// anything not carried over would be deleted from the Node as a side effect.
	AllTaints     []corev1.Taint
	JournalRaw    string
	Journal       journal
	JournalErr    error
	QuarantineRaw string
}

func observe(n *corev1.Node) ownership {
	obs := ownership{NodeName: n.Name, NodeUID: string(n.UID)}
	obs.LabelValue, obs.HasLabel = n.Labels[workerLabelKey]
	obs.AllTaints = append([]corev1.Taint(nil), n.Spec.Taints...)
	for _, t := range n.Spec.Taints {
		if t.Key == workerTaintKey {
			obs.Taints = append(obs.Taints, t)
		}
	}
	obs.JournalRaw = n.Annotations[journalKey]
	obs.QuarantineRaw = n.Annotations[quarantineKey]
	if obs.JournalRaw != "" {
		obs.Journal, obs.JournalErr = decodeJournal(obs.JournalRaw)
	}
	return obs
}

// decideAcquire proceeds from exactly one state and refuses every other by name.
//
// Free means neither ownership key, nor a journal, nor a quarantine record: because that is the only entry
// state, the prior value of the two keys is provably absent, which is why the journal records what was
// installed rather than what to restore.
func decideAcquire(obs ownership, n *corev1.Node, txID, runID, arm, takenAt string) (journal, error) {
	if obs.QuarantineRaw != "" {
		return journal{}, refuse(reasonQuarantined,
			"node %s carries a quarantine record; clear it deliberately before any run", obs.NodeName)
	}
	if len(obs.Taints) > 1 {
		return journal{}, refuse(reasonDuplicateTaintKey,
			"node %s carries %d taints on %s", obs.NodeName, len(obs.Taints), workerTaintKey)
	}
	hasMarker := obs.HasLabel || len(obs.Taints) == 1
	switch {
	case obs.JournalRaw != "" && obs.JournalErr != nil:
		return journal{}, refuse(reasonBadJournal, "node %s: %v", obs.NodeName, obs.JournalErr)
	case obs.JournalRaw != "" && !hasMarker:
		return journal{}, refuse(reasonJournalWithoutMarker,
			"node %s carries a journal for tx %s but no marker", obs.NodeName, obs.Journal.TxID)
	case obs.JournalRaw != "" && obs.Journal.TxID == txID:
		return journal{}, refuse(reasonOwnTxID,
			"node %s is already held by this transaction %s", obs.NodeName, txID)
	case obs.JournalRaw != "":
		return journal{}, refuse(reasonForeignOwner,
			"node %s is held by run %s under tx %s since %s",
			obs.NodeName, obs.Journal.RunID, obs.Journal.TxID, obs.Journal.TakenAt)
	case hasMarker:
		return journal{}, refuse(reasonMarkerWithoutJournal,
			"node %s carries a queuelab marker with no journal; it cannot be released safely by this tool",
			obs.NodeName)
	}
	return journal{
		Schema:  journalSchema,
		TxID:    txID,
		RunID:   runID,
		Arm:     arm,
		Node:    n.Name,
		NodeUID: string(n.UID),
		TakenAt: takenAt,
		Installed: installedTuple{
			LabelValue:  runID,
			TaintValue:  runID,
			TaintEffect: corev1.TaintEffectNoSchedule,
		},
	}, nil
}

type releaseAction int

const (
	// releaseRestore removes exactly the two values this transaction installed, plus its journal.
	releaseRestore releaseAction = iota
	// releaseAlreadyDone is a success: nothing of ours is on the Node, so there is nothing to undo.
	releaseAlreadyDone
)

// verifyInstalled proves the two values this transaction wrote are still exactly what it wrote.
//
// Only those values are compared: unrelated labels and taints, including the operator's own unhealthy
// taint, are benign drift and must not invalidate an otherwise valid run.
func verifyInstalled(obs ownership, j journal) error {
	if !obs.HasLabel || obs.LabelValue != j.Installed.LabelValue {
		return refuse(reasonInstalledDiverged, "label %s is %q, this transaction installed %q",
			workerLabelKey, obs.LabelValue, j.Installed.LabelValue)
	}
	if len(obs.Taints) != 1 {
		return refuse(reasonInstalledDiverged, "node carries %d taints on %s, this transaction installed 1",
			len(obs.Taints), workerTaintKey)
	}
	if obs.Taints[0].Value != j.Installed.TaintValue || obs.Taints[0].Effect != j.Installed.TaintEffect {
		return refuse(reasonInstalledDiverged, "taint %s is %q/%s, this transaction installed %q/%s",
			workerTaintKey, obs.Taints[0].Value, obs.Taints[0].Effect,
			j.Installed.TaintValue, j.Installed.TaintEffect)
	}
	if obs.NodeUID != j.NodeUID {
		return refuse(reasonWrongNode, "node UID is %s, the journal names %s", obs.NodeUID, j.NodeUID)
	}
	return nil
}

// withOwnershipTaint returns the taint list to patch, built from the observed list.
//
// The merge patch replaces the array wholesale, so anything not carried over here is deleted from the Node.
func withOwnershipTaint(observed []corev1.Taint, runID string) []corev1.Taint {
	out := make([]corev1.Taint, 0, len(observed)+1)
	for _, t := range observed {
		if t.Key != workerTaintKey {
			out = append(out, t)
		}
	}
	return append(out, corev1.Taint{
		Key: workerTaintKey, Value: runID, Effect: corev1.TaintEffectNoSchedule,
	})
}

// withoutOwnershipTaint removes only this experiment's taint key, leaving every other taint untouched.
func withoutOwnershipTaint(observed []corev1.Taint) []corev1.Taint {
	out := make([]corev1.Taint, 0, len(observed))
	for _, t := range observed {
		if t.Key != workerTaintKey {
			out = append(out, t)
		}
	}
	return out
}

// quarantine is what a forced break leaves behind instead of a free node.
//
// No flag can prove the previous process is dead, so the break records what it removed and blocks
// acquisition until an operator deliberately clears it in a second step.
type quarantine struct {
	Schema         int            `json:"schema"`
	QuarantineID   string         `json:"quarantineID"`
	ForcedAt       string         `json:"forcedAt"`
	Node           string         `json:"node"`
	NodeUID        string         `json:"nodeUID"`
	PriorJournal   string         `json:"priorJournal"`
	ObservedLabel  string         `json:"observedLabel"`
	ObservedTaints []corev1.Taint `json:"observedTaints,omitempty"`
}

func encodeQuarantine(q quarantine) (string, error) {
	b, err := json.Marshal(q)
	if err != nil {
		return "", fmt.Errorf("encode quarantine: %w", err)
	}
	return string(b), nil
}

// decodeQuarantine is as strict as decodeJournal, and for the same reason.
//
// The quarantine record is the only surviving evidence of who held a forcibly broken node, and it is what
// decideClear matches the operator's -quarantine-id against, so a document with anything after it is one
// this tool does not fully understand and must not act on.
func decodeQuarantine(s string) (quarantine, error) {
	dec := json.NewDecoder(strings.NewReader(s))
	dec.DisallowUnknownFields()
	var q quarantine
	if err := dec.Decode(&q); err != nil {
		return quarantine{}, fmt.Errorf("decode quarantine: %w", err)
	}
	if dec.More() {
		return quarantine{}, fmt.Errorf("decode quarantine: trailing data after the document")
	}
	if q.Schema != quarantineSchema {
		return quarantine{}, fmt.Errorf("decode quarantine: schema %d is not %d", q.Schema, quarantineSchema)
	}
	if q.QuarantineID == "" {
		return quarantine{}, fmt.Errorf("decode quarantine: quarantineID is empty")
	}
	return q, nil
}

// decideForce refuses to force a node that is already quarantined and requires the operator to confirm the
// target by its UID.
func decideForce(obs ownership, nodeUID, quarantineID, forcedAt string) (quarantine, error) {
	if obs.QuarantineRaw != "" {
		return quarantine{}, refuse(reasonQuarantined,
			"node %s is already quarantined; clear that record instead of forcing again", obs.NodeName)
	}
	if obs.NodeUID != nodeUID {
		return quarantine{}, refuse(reasonWrongNode,
			"node %s has UID %s, you confirmed %s", obs.NodeName, obs.NodeUID, nodeUID)
	}
	return quarantine{
		Schema:         quarantineSchema,
		QuarantineID:   quarantineID,
		ForcedAt:       forcedAt,
		Node:           obs.NodeName,
		NodeUID:        obs.NodeUID,
		PriorJournal:   obs.JournalRaw,
		ObservedLabel:  obs.LabelValue,
		ObservedTaints: obs.Taints,
	}, nil
}

// decideClear removes only the exact record the operator names, on the exact object it was written about.
//
// The quarantine id alone is not enough. decideForce records the node NAME and the node UID precisely
// because a record is a document that can be copied onto another Node, and because a Node deleted and
// recreated under the same name is a different machine wearing the same label. Clearing is the step that
// makes a node acquirable again, so it must confirm it is unblocking the object that was actually broken,
// the same way decideForce required the operator to confirm the target it was breaking.
func decideClear(obs ownership, quarantineID string) error {
	if obs.QuarantineRaw == "" {
		return refuse(reasonNotOurs, "node %s carries no quarantine record", obs.NodeName)
	}
	q, err := decodeQuarantine(obs.QuarantineRaw)
	if err != nil {
		return refuse(reasonBadQuarantine, "node %s: %v", obs.NodeName, err)
	}
	if q.QuarantineID != quarantineID {
		return refuse(reasonNotOurs, "node %s carries quarantine %s, you named %s",
			obs.NodeName, q.QuarantineID, quarantineID)
	}
	if q.Node != obs.NodeName || q.NodeUID != obs.NodeUID {
		return refuse(reasonWrongNode,
			"quarantine %s was recorded for node %s (uid %s), this node is %s (uid %s)",
			quarantineID, q.Node, q.NodeUID, obs.NodeName, obs.NodeUID)
	}
	return nil
}

// decideRelease says what release may do, and refusing is a run-invalidating outcome rather than a warning.
//
// Restoring over a value that moved would be a second act of damage, so divergence refuses and hands the
// node to the operator modes instead.
func decideRelease(obs ownership, txID string) (releaseAction, error) {
	if obs.QuarantineRaw != "" {
		return releaseRestore, refuse(reasonQuarantined,
			"node %s was force-released under a quarantine record while this run held it", obs.NodeName)
	}
	if obs.JournalRaw == "" {
		if obs.HasLabel || len(obs.Taints) > 0 {
			return releaseRestore, refuse(reasonMarkerWithoutJournal,
				"node %s carries a marker with no journal", obs.NodeName)
		}
		return releaseAlreadyDone, nil
	}
	if obs.JournalErr != nil {
		return releaseRestore, refuse(reasonBadJournal, "node %s: %v", obs.NodeName, obs.JournalErr)
	}
	if obs.Journal.TxID != txID {
		return releaseRestore, refuse(reasonNotOurs,
			"node %s is held by tx %s, not %s", obs.NodeName, obs.Journal.TxID, txID)
	}
	if err := verifyInstalled(obs, obs.Journal); err != nil {
		return releaseRestore, err
	}
	return releaseRestore, nil
}
