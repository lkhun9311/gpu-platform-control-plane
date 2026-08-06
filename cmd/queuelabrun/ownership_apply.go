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
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/util/uuid"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// acquireAttempts bounds the optimistic-concurrency retry.
//
// A 409 proves only that something wrote the Node — the kubelet, the device plugin and this repository's
// own nodehealth controller all do routinely — so a conflict is retried after re-deciding from the fresh
// Node, and only exhausting the bound refuses.
const acquireAttempts = 5

// resolveAttempts bounds the re-reads that decide whether a patch whose response was lost actually landed.
const resolveAttempts = 6

const resolveInterval = 2 * time.Second

// verifyAttempts bounds the retry on the read that confirms a patch which the API server already reported
// as committed, so one transient Get error immediately afterward is not mistaken for a verification failure
// and does not, on its own, cause the node to be abandoned still carrying our markers.
const verifyAttempts = 3

const verifyInterval = 500 * time.Millisecond

// newTxID generates the ownership identity.
//
// It is generated rather than derived from the run id because a reused run id is already a known confound
// and must never be able to authorise the release of somebody else's transaction.
func newTxID() string { return string(uuid.NewUUID()) }

// acquireWorker takes exclusive ownership of the worker or refuses.
//
// The label, the whole taint array and the journal go in one resource-version-preconditioned patch, so the
// API server never commits a marker without the journal that says who owns it and what to undo.
func acquireWorker(ctx context.Context, c client.Client, nodeName, txID, runID, arm string) (journal, error) {
	var lastErr error
	for attempt := 0; attempt < acquireAttempts; attempt++ {
		var n corev1.Node
		if err := c.Get(ctx, client.ObjectKey{Name: nodeName}, &n); err != nil {
			return journal{}, fmt.Errorf("get node %s: %w", nodeName, err)
		}
		obs := observe(&n)
		j, err := decideAcquire(obs, &n, txID, runID, arm, time.Now().UTC().Format(time.RFC3339))
		if err != nil {
			// A refusal is a decision about the observed state, so it is returned as-is rather than retried.
			return journal{}, err
		}
		raw, err := encodeJournal(j)
		if err != nil {
			return journal{}, err
		}
		base := n.DeepCopy()
		if n.Labels == nil {
			n.Labels = map[string]string{}
		}
		if n.Annotations == nil {
			n.Annotations = map[string]string{}
		}
		n.Labels[workerLabelKey] = j.Installed.LabelValue
		n.Annotations[journalKey] = raw
		n.Spec.Taints = withOwnershipTaint(obs.AllTaints, j.Installed.TaintValue)
		err = c.Patch(ctx, &n, client.MergeFromWithOptions(base, client.MergeFromWithOptimisticLock{}))
		switch {
		case err == nil:
			if verr := verifyAcquired(ctx, c, nodeName, j); verr != nil {
				// The patch reported success but what we can now observe does not match what it wrote, so
				// this transaction attempts to undo its own markers rather than returning them installed
				// with no error, or returning an error while leaving the node held for the next run to
				// refuse foreign-owner and a human to clear by hand.
				//
				// This self-release must run on a fresh background context, not ctx: a signal cancelling ctx
				// is exactly what can cause verifyAcquired to fail in the first place, and releasing on the
				// same cancelled context would make the Get here fail immediately, skip the release Patch
				// entirely, and leave the label, taint and journal stranded on the node with nothing left to
				// undo them — the failure this task exists to prevent.
				if rerr := releaseAcquired(context.Background(), c, j); rerr != nil {
					return journal{}, fmt.Errorf(
						"acquire node %s: verify failed: %v; release also failed, node may still carry tx %s: run: queuelabrun -inspect-worker %s: %w",
						nodeName, verr, j.TxID, nodeName, rerr)
				}
				return journal{}, fmt.Errorf("acquire node %s: verify failed and was undone: %w", nodeName, verr)
			}
			return j, nil
		case apierrors.IsConflict(err):
			// Somebody wrote the Node between the read and the patch; re-read and re-decide from scratch.
			lastErr = err
			continue
		default:
			// The patch may still have landed with its response lost, so the outcome is resolved rather
			// than assumed.
			return resolveAmbiguousAcquire(ctx, c, nodeName, j, err)
		}
	}
	return journal{}, fmt.Errorf("acquire node %s: %d conflicts, giving up: %w", nodeName, acquireAttempts, lastErr)
}

// verifyAcquired requires the complete invariant before anything else touches the cluster.
//
// Finding our transaction id is not enough: a mutating webhook can keep the annotation and alter a marker,
// which would leave the run holding a node that no longer routes work the way the flavor expects.
func verifyAcquired(ctx context.Context, c client.Client, nodeName string, j journal) error {
	var n corev1.Node
	var err error
	for attempt := 0; attempt < verifyAttempts; attempt++ {
		if err = c.Get(ctx, client.ObjectKey{Name: nodeName}, &n); err == nil {
			break
		}
		if attempt == verifyAttempts-1 {
			break
		}
		select {
		case <-ctx.Done():
			// Bare ctx.Err() here would drop the node name and the txID that identify what is still on the
			// node for the caller's self-release (see acquireWorker) to act on, the same detail every other
			// cancellation branch in this file now carries.
			return fmt.Errorf("verify node %s cancelled: tx %s: %w", nodeName, j.TxID, ctx.Err())
		case <-time.After(verifyInterval):
		}
	}
	if err != nil {
		return fmt.Errorf("verify node %s: %w", nodeName, err)
	}
	obs := observe(&n)
	if obs.JournalErr != nil {
		return fmt.Errorf("verify node %s: %w", nodeName, obs.JournalErr)
	}
	if obs.Journal != j {
		return fmt.Errorf("verify node %s: journal is not the one this run wrote", nodeName)
	}
	return verifyInstalled(obs, j)
}

// resolveAmbiguousAcquire decides whether a patch whose response was lost actually committed.
//
// Three outcomes only: our complete tuple is observed and the run continues; the node is free or foreign
// and the run refuses with nothing of ours to undo; or it is unresolved within the bound, which refuses and
// leaves the operator modes to sort it out.
func resolveAmbiguousAcquire(ctx context.Context, c client.Client, nodeName string, j journal,
	cause error) (journal, error) {
	for attempt := 0; attempt < resolveAttempts; attempt++ {
		var n corev1.Node
		if err := c.Get(ctx, client.ObjectKey{Name: nodeName}, &n); err == nil {
			obs := observe(&n)
			switch {
			case obs.JournalRaw == "" && !obs.HasLabel && len(obs.Taints) == 0:
				return journal{}, fmt.Errorf("acquire node %s failed and did not land: %w", nodeName, cause)
			case obs.JournalErr == nil && obs.Journal == j && verifyInstalled(obs, j) == nil:
				return j, nil
			case obs.JournalErr == nil && obs.JournalRaw != "" && obs.Journal.TxID != j.TxID:
				return journal{}, fmt.Errorf("acquire node %s failed; it is now held by tx %s: %w",
					nodeName, obs.Journal.TxID, cause)
			}
		}
		select {
		case <-ctx.Done():
			// acquireWorker now runs on the signal-cancellable context, so a Ctrl-C during this retry loop
			// must not drop the txID and the inspect-worker hint the bound-exhaustion path below carries.
			return journal{}, fmt.Errorf(
				"acquire node %s is UNRESOLVED after cancellation: it may hold tx %s. Run: queuelabrun -inspect-worker %s. Cause: %w",
				nodeName, j.TxID, nodeName, ctx.Err())
		case <-time.After(resolveInterval):
		}
	}
	return journal{}, fmt.Errorf(
		"acquire node %s is UNRESOLVED after %v: it may hold tx %s. Run: queuelabrun -inspect-worker %s. Cause: %w",
		nodeName, time.Duration(resolveAttempts)*resolveInterval, j.TxID, nodeName, cause)
}

// inspectWorker is read-only and is how an operator learns a transaction id a crashed process never
// printed anywhere.
func inspectWorker(ctx context.Context, c client.Client, nodeName string) error {
	var n corev1.Node
	if err := c.Get(ctx, client.ObjectKey{Name: nodeName}, &n); err != nil {
		return fmt.Errorf("get node %s: %w", nodeName, err)
	}
	obs := observe(&n)
	fmt.Printf("node %s (uid %s)\n", obs.NodeName, obs.NodeUID)
	fmt.Printf("  label %s = %q (present=%v)\n", workerLabelKey, obs.LabelValue, obs.HasLabel)
	fmt.Printf("  taints on %s: %+v\n", workerTaintKey, obs.Taints)
	fmt.Printf("  journal: %s\n", orNone(obs.JournalRaw))
	fmt.Printf("  quarantine: %s\n", orNone(obs.QuarantineRaw))
	switch {
	case obs.QuarantineRaw != "":
		q, err := decodeQuarantine(obs.QuarantineRaw)
		if err != nil {
			fmt.Printf("\nUNREADABLE QUARANTINE RECORD: %v — manual intervention required.\n", err)
			return nil
		}
		fmt.Printf("\nQUARANTINED. To free it after establishing the previous process is dead:\n"+
			"  queuelabrun -clear-quarantine -worker %s -quarantine-id %s -confirm-owner-dead\n",
			nodeName, q.QuarantineID)
	case obs.JournalRaw != "" && obs.JournalErr == nil:
		fmt.Printf("\nHELD by run %s (arm %s) under tx %s since %s.\n"+
			"  If that process is gone: queuelabrun -release-stale -worker %s -txid %s\n",
			obs.Journal.RunID, obs.Journal.Arm, obs.Journal.TxID, obs.Journal.TakenAt,
			nodeName, obs.Journal.TxID)
		if err := verifyInstalled(obs, obs.Journal); err != nil {
			fmt.Printf("  WARNING, the installed values have diverged: %v\n"+
				"  A stale release will refuse. The break is:\n"+
				"    queuelabrun -force-release -worker %s -node-uid %s -accept-divergence\n",
				err, nodeName, obs.NodeUID)
		}
	case obs.HasLabel || len(obs.Taints) > 0:
		fmt.Printf("\nSTALE MARKER WITH NO JOURNAL. This tool cannot release it safely.\n"+
			"  Inspect and decide by hand, or break it with:\n"+
			"    queuelabrun -force-release -worker %s -node-uid %s -accept-divergence\n",
			nodeName, obs.NodeUID)
	default:
		fmt.Printf("\nFREE.\n")
	}
	return nil
}

func orNone(s string) string {
	if s == "" {
		return "(none)"
	}
	return s
}

// releaseStale is the ordinary recovery: the transaction is identified, its values are intact, and the
// operator has established the process holding it is gone.
func releaseStale(ctx context.Context, c client.Client, nodeName, txID string) error {
	var n corev1.Node
	if err := c.Get(ctx, client.ObjectKey{Name: nodeName}, &n); err != nil {
		return fmt.Errorf("get node %s: %w", nodeName, err)
	}
	obs := observe(&n)
	if _, err := decideRelease(obs, txID); err != nil {
		return err
	}
	fmt.Printf("restoring node %s: removing label %s=%q and taint %s=%q/%s, and the journal for tx %s\n",
		nodeName, workerLabelKey, obs.LabelValue, workerTaintKey,
		obs.Journal.Installed.TaintValue, obs.Journal.Installed.TaintEffect, txID)
	// releaseAcquired always runs on an uncancelled context, the same as every other release call site in
	// this package: a half-applied restoration must be allowed to finish even if the operator's own signal
	// handling (if any wraps ctx) fires mid-patch.
	return releaseAcquired(context.Background(), c, obs.Journal)
}

// forceQuarantine breaks a stuck node without ever producing a free one.
//
// It cannot prove the previous process is dead, so it records everything it removes and leaves a record
// that acquisition refuses until an operator clears it in a separate, deliberate step.
func forceQuarantine(ctx context.Context, c client.Client, nodeName, nodeUID string) error {
	var n corev1.Node
	if err := c.Get(ctx, client.ObjectKey{Name: nodeName}, &n); err != nil {
		return fmt.Errorf("get node %s: %w", nodeName, err)
	}
	obs := observe(&n)
	q, err := decideForce(obs, nodeUID, string(uuid.NewUUID()), time.Now().UTC().Format(time.RFC3339))
	if err != nil {
		return err
	}
	raw, err := encodeQuarantine(q)
	if err != nil {
		return err
	}
	fmt.Printf("forcing node %s: removing label %s=%q, %d taint(s) on %s, and the journal %s\n"+
		"  all of it is preserved in quarantine record %s\n",
		nodeName, workerLabelKey, obs.LabelValue, len(obs.Taints), workerTaintKey,
		orNone(obs.JournalRaw), q.QuarantineID)
	base := n.DeepCopy()
	delete(n.Labels, workerLabelKey)
	delete(n.Annotations, journalKey)
	if n.Annotations == nil {
		n.Annotations = map[string]string{}
	}
	n.Annotations[quarantineKey] = raw
	n.Spec.Taints = withoutOwnershipTaint(obs.AllTaints)
	if err := c.Patch(ctx, &n, client.MergeFromWithOptions(base, client.MergeFromWithOptimisticLock{})); err != nil {
		return fmt.Errorf("force node %s (state changed under you, re-inspect): %w", nodeName, err)
	}
	fmt.Printf("node %s is QUARANTINED as %s; no run can acquire it until it is cleared\n", nodeName, q.QuarantineID)
	return nil
}

// clearQuarantine removes only the record the operator names, after they have attested the previous owner
// is dead — a judgement no flag can make for them.
func clearQuarantine(ctx context.Context, c client.Client, nodeName, quarantineID string) error {
	var n corev1.Node
	if err := c.Get(ctx, client.ObjectKey{Name: nodeName}, &n); err != nil {
		return fmt.Errorf("get node %s: %w", nodeName, err)
	}
	obs := observe(&n)
	if err := decideClear(obs, quarantineID); err != nil {
		return err
	}
	base := n.DeepCopy()
	delete(n.Annotations, quarantineKey)
	if err := c.Patch(ctx, &n, client.MergeFromWithOptions(base, client.MergeFromWithOptimisticLock{})); err != nil {
		return fmt.Errorf("clear quarantine on %s (state changed under you, re-inspect): %w", nodeName, err)
	}
	fmt.Printf("node %s quarantine %s cleared\n", nodeName, quarantineID)
	return nil
}

// releaseAcquired undoes exactly what this transaction installed, or refuses and invalidates the run.
func releaseAcquired(ctx context.Context, c client.Client, j journal) error {
	var lastErr error
	for attempt := 0; attempt < acquireAttempts; attempt++ {
		var n corev1.Node
		if err := c.Get(ctx, client.ObjectKey{Name: j.Node}, &n); err != nil {
			return fmt.Errorf("get node %s: %w", j.Node, err)
		}
		obs := observe(&n)
		act, err := decideRelease(obs, j.TxID)
		if err != nil {
			return err
		}
		if act == releaseAlreadyDone {
			return nil
		}
		base := n.DeepCopy()
		delete(n.Labels, workerLabelKey)
		delete(n.Annotations, journalKey)
		n.Spec.Taints = withoutOwnershipTaint(obs.AllTaints)
		err = c.Patch(ctx, &n, client.MergeFromWithOptions(base, client.MergeFromWithOptimisticLock{}))
		switch {
		case err == nil:
			return nil
		case apierrors.IsConflict(err):
			// Retrying is legal here because release re-verifies identity on every attempt and is not
			// racing anyone for exclusivity.
			lastErr = err
			continue
		default:
			return fmt.Errorf("release node %s: %w", j.Node, err)
		}
	}
	return fmt.Errorf("release node %s: %d conflicts, giving up: %w", j.Node, acquireAttempts, lastErr)
}
