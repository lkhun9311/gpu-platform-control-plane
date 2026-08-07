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

// releaseCleanupTimeout bounds every release-path context that deliberately runs on context.Background()
// instead of the run's own signal-cancellable context.
//
// That choice (see acquireWorker's self-release comment below) protects a half-applied restoration from
// being cut off by Ctrl-C, but an unbounded context would let a stuck API server hang the process forever at
// exactly the moment it is trying to clean up — the very stranded-marker outcome the background context
// exists to prevent, just moved from "Ctrl-C" to "hung apiserver" as the cause.
//
// The worst case this bounds is 13 sequential API calls: releaseAcquired's loop retries up to acquireAttempts
// (5) times on conflict, and a retry that reaches the patch spends 1 Get + 1 Patch, so 5 attempts is at most
// 10 round trips; a successful patch then runs verifyReleased, which reads up to verifyAttempts (3) more
// times, spaced verifyInterval (500ms) apart. 10 + 3 = 13 calls. client-go issues no timeout of its own per
// call, so a degraded-but-still-responding API server is bounded only by this context, not by anything
// smaller — budgeting a generous 10s for each of those 13 calls (plus the ~1s of deterministic verifyInterval
// sleep already inside the 13) is 131s of worst-case sequential work, so 3 minutes leaves real margin above
// that instead of the 30s bound this replaces, which left only about 2.2s per call.
//
// The ambiguous-release read-back added since does not change that 13: it runs in the non-conflict branch,
// which returns instead of looping, and it costs the same up-to-3 reads verifyReleased already cost on the
// success branch. The two branches are mutually exclusive, so the worst case is still 10 + 3.
const releaseCleanupTimeout = 3 * time.Minute

// cleanupContext returns a context bounded by releaseCleanupTimeout for release-path work that must run to
// completion even after the run's own context was cancelled.
func cleanupContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), releaseCleanupTimeout)
}

// operatorModeTimeout bounds the four recovery modes, which run on their own uncancellable context for the
// same reason the release path does: a signal arriving between a mode's Get and its Patch is exactly what
// could leave a break half applied.
//
// It is far shorter than releaseCleanupTimeout because far less work runs on it. Each mode spends at most a
// Get and a Patch on this context — releaseStale's actual restoration hands off to cleanupContext, and
// inspectWorker only reads — so at the same generous 10s-per-call budget releaseCleanupTimeout is derived
// from, 2 calls need 20s and one minute leaves triple that margin. Bounding it at all is the point: an
// operator running these modes is already recovering from a stuck node, and a tool that hangs indefinitely
// against a degraded API server gives them nothing to act on and no way to tell a hang from slow progress.
const operatorModeTimeout = time.Minute

// operatorModeContext returns the bounded, signal-independent context the recovery modes run on.
func operatorModeContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), operatorModeTimeout)
}

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
				//
				// It is releaseAcquired rather than releaseOwned because this transaction has not been handed
				// to a run yet: finding the node clean here genuinely means there is nothing of ours to undo,
				// where for a run that has been holding the worker it would mean its markers were taken.

				relCtx, relCancel := cleanupContext()
				_, rerr := releaseAcquired(relCtx, c, j)
				relCancel()
				if rerr != nil {
					return journal{}, fmt.Errorf(
						"acquire node %s: verify failed: %v; release also failed, node may still carry tx %s: run: queuelabrun -inspect-worker -worker %s: %w",
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
	if verr := verifyObserved(observe(&n), j); verr != nil {
		return fmt.Errorf("verify node %s: %w", nodeName, verr)
	}
	return nil
}

// verifyObserved is the whole "did our write land, completely" invariant, in one place.
//
// resolveAmbiguousAcquire used to carry its own inlined copy of this check; two copies of the invariant is
// two places it can drift, and the one thing the design forbids is treating a journal carrying our TxID as
// acquired without also proving the markers are the ones we installed.
func verifyObserved(obs ownership, j journal) error {
	if obs.JournalErr != nil {
		return obs.JournalErr
	}
	if obs.Journal != j {
		return fmt.Errorf("journal is not the one this run wrote")
	}
	return verifyInstalled(obs, j)
}

// verifyReleased requires proof our markers are gone before release is trusted, in the same bounded-retry
// shape as verifyAcquired.
func verifyReleased(ctx context.Context, c client.Client, nodeName string, j journal) error {
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
			return fmt.Errorf("verify release of node %s cancelled: tx %s: %w", nodeName, j.TxID, ctx.Err())
		case <-time.After(verifyInterval):
		}
	}
	if err != nil {
		return fmt.Errorf("verify release of node %s: %w", nodeName, err)
	}
	return verifyClean(observe(&n), j)
}

// verifyClean is release's counterpart to verifyObserved: it proves THIS transaction's markers are gone,
// never that the node is free.
//
// Between our patch and this read, another run may legitimately have acquired the node, and demanding a free
// node would turn that ordinary race into a spurious restoration failure. So each check only fails when what
// is observed still names our own installed values, not merely when something is present.
func verifyClean(obs ownership, j journal) error {
	if obs.NodeUID != j.NodeUID {
		// A recreated node is a different node: there is nothing of ours left to find on it, but that is not
		// the invariant this function proves, so treat it as unable to verify rather than silently passing.
		return fmt.Errorf("node UID is %s, the journal named %s: this is a different node", obs.NodeUID, j.NodeUID)
	}
	if obs.JournalRaw != "" {
		switch {
		case obs.JournalErr != nil:
			// The invariant is "absent, or present but naming a different txID" — an unreadable journal
			// satisfies neither, so it cannot be waved through as clean. This cannot false-fail the legitimate
			// race either: a foreign journal is written by encodeJournal inside one atomic patch, so there is
			// no torn read of someone else's write to tolerate here, only ours failing to have been removed.
			return fmt.Errorf("journal on node %s is unreadable after release: %v", obs.NodeName, obs.JournalErr)
		case obs.Journal.TxID == j.TxID:
			return fmt.Errorf("journal for tx %s is still on the node after release", j.TxID)
		}
	}
	if obs.HasLabel && obs.LabelValue == j.Installed.LabelValue {
		return fmt.Errorf("label %s still carries this transaction's value %q", workerLabelKey, obs.LabelValue)
	}
	for _, t := range obs.Taints {
		if t.Value == j.Installed.TaintValue && t.Effect == j.Installed.TaintEffect {
			return fmt.Errorf("taint %s still carries this transaction's value %q/%s",
				workerTaintKey, t.Value, t.Effect)
		}
	}
	return nil
}

// resolveAmbiguousAcquire decides whether a patch whose response was lost actually committed.
//
// Three outcomes only: our complete tuple is observed and the run continues; the node is free or foreign
// and the run refuses with nothing of ours to undo; or it is unresolved within the bound, which refuses and
// leaves the operator modes to sort it out.
func resolveAmbiguousAcquire(ctx context.Context, c client.Client, nodeName string, j journal,
	cause error) (journal, error) {
	// The failed re-read is kept rather than discarded, because "we could not read the node" and "we read it
	// and it never resolved" send the operator to different places. A sustained authorization failure, a
	// deleted node or an API outage would otherwise be reported as a generic unresolved write, and the very
	// -inspect-worker command this refusal prints would fail for the same reason nobody was told about.
	//
	// It tracks the MOST RECENT read, not the worst one ever seen, which is why the success branch clears it:
	// one transient failure early in the loop followed by five clean reads is a node the operator can reach,
	// and reporting the stale error would send them after a connectivity problem that has already passed.
	var lastReadErr error
	for attempt := 0; attempt < resolveAttempts; attempt++ {
		var n corev1.Node
		if err := c.Get(ctx, client.ObjectKey{Name: nodeName}, &n); err != nil {
			lastReadErr = err
		} else {
			lastReadErr = nil
			obs := observe(&n)
			switch {
			case obs.JournalRaw == "" && !obs.HasLabel && len(obs.Taints) == 0:
				// A free node is proof the patch did not commit, not merely a read that has not caught up:
				// controller-runtime's client reads straight from the API server rather than a cache, so this
				// Get is linearizable and cannot observe a state older than a write that already landed. The
				// same read against an informer cache could legitimately lag a committed patch, and this
				// conclusion would then be wrong.
				return journal{}, fmt.Errorf(
					"acquire node %s failed and did not land; it does not hold tx %s. Run: queuelabrun -inspect-worker -worker %s. Cause: %w",
					nodeName, j.TxID, nodeName, cause)
			case verifyObserved(obs, j) == nil:
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
				"acquire node %s is UNRESOLVED after cancellation: it may hold tx %s. Run: queuelabrun -inspect-worker -worker %s. %s. Cause: %w",
				nodeName, j.TxID, nodeName, resolveReadNote(lastReadErr), ctx.Err())
		case <-time.After(resolveInterval):
		}
	}
	return journal{}, fmt.Errorf(
		"acquire node %s is UNRESOLVED after %v: it may hold tx %s. Run: queuelabrun -inspect-worker -worker %s. %s. Cause: %w",
		nodeName, time.Duration(resolveAttempts)*resolveInterval, j.TxID, nodeName,
		resolveReadNote(lastReadErr), cause)
}

// resolveReadNote renders what the LAST re-read reported, so the refusal distinguishes a node the operator
// cannot reach from a readable one that simply never showed a resolving state.
//
// It is the last read rather than any read, because that is the state the operator is about to walk into.
// A nil error here therefore means the most recent read succeeded, which is the fact worth stating: without
// it a reader assumes the reads must have failed because the outcome is unknown.
func resolveReadNote(err error) string {
	if err == nil {
		return "The last re-read succeeded and did not resolve the state"
	}
	return "Last re-read failed: " + err.Error()
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
	fmt.Printf("  journal: %s\n", quotedOrNone(obs.JournalRaw))
	fmt.Printf("  quarantine: %s\n", quotedOrNone(obs.QuarantineRaw))
	switch {
	case obs.QuarantineRaw != "":
		q, err := decodeQuarantine(obs.QuarantineRaw)
		if err != nil {
			// A script wrapping -inspect-worker must see a non-zero exit here: an unreadable quarantine
			// record needs a human, and printing the warning while still exiting 0 would read as healthy.
			fmt.Printf("\nUNREADABLE QUARANTINE RECORD: %v — manual intervention required.\n", err)
			return fmt.Errorf("node %s: unreadable quarantine record: %w", nodeName, err)
		}
		fmt.Printf("\nQUARANTINED. To free it after establishing the previous process is dead:\n"+
			"  queuelabrun -clear-quarantine -worker %s -quarantine-id %s -confirm-owner-dead\n",
			nodeName, q.QuarantineID)
	case obs.JournalRaw != "" && obs.JournalErr != nil:
		// Without this branch a node carrying an undecodable journal and no marker fell through to FREE and
		// exited 0, while decideAcquire refuses that same node as unreadable-journal: the recovery tool
		// contradicted the runner about the node's state, and said the safe-sounding thing. A script reading
		// the exit code would then keep pointing runs at a node no run can ever take.
		//
		// It is not recoverable by the ordinary path either: -release-stale needs a txID, and the txID lives
		// in the very document that cannot be read, so the break is the only way through.
		fmt.Printf("\nUNREADABLE OWNERSHIP JOURNAL: %v\n"+
			"  found: %s\n"+
			"  No run can acquire this node (acquisition refuses it as %s) and -release-stale cannot free it,\n"+
			"  because the transaction id it would need is inside this document. Break it with:\n"+
			"    queuelabrun -force-release -worker %s -node-uid %s -accept-divergence\n",
			obs.JournalErr, quotedOrNone(obs.JournalRaw), reasonBadJournal, nodeName, obs.NodeUID)
		return fmt.Errorf("node %s: unreadable ownership journal: %w", nodeName, obs.JournalErr)
	case obs.JournalRaw != "" && obs.JournalErr == nil:
		fmt.Printf("\nHELD by run %s (arm %s) under tx %s since %s.\n"+
			"  If that process is gone: queuelabrun -release-stale -worker %s -txid %s -confirm-owner-dead\n",
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

// quotedOrNone renders an annotation this tool did not write.
//
// The journal and the quarantine record are Node annotations, so anyone who can write the Node can put
// arbitrary bytes in them, and every caller here prints them into an operator's terminal while that operator
// is deciding whether to break a node. %q escapes the terminal control sequences that could otherwise
// rewrite the recovery instructions printed around them, and it also makes trailing whitespace or an empty
// document visible instead of silently absent.
func quotedOrNone(s string) string {
	if s == "" {
		return "(none)"
	}
	return fmt.Sprintf("%q", s)
}

// releaseStale is the ordinary recovery: the transaction is identified, its values are intact, and the
// operator has established the process holding it is gone.
func releaseStale(ctx context.Context, c client.Client, nodeName, txID string) error {
	var n corev1.Node
	if err := c.Get(ctx, client.ObjectKey{Name: nodeName}, &n); err != nil {
		return fmt.Errorf("get node %s: %w", nodeName, err)
	}
	obs := observe(&n)
	act, err := decideRelease(obs, txID)
	if err != nil {
		return err
	}
	if act == releaseAlreadyDone {
		// obs.Journal is the zero journal here (its Node field is ""), because decideRelease only reaches
		// releaseAlreadyDone when there was never a journal to decode in the first place. Passing that zero
		// journal to releaseAcquired would Get an empty node name and fail with a confusing API error, for an
		// operator who reached for this exact mode right after a crash and deserves a plain "already released"
		// instead.
		fmt.Printf("node %s already carries nothing for tx %s; nothing to release\n", nodeName, txID)
		return nil
	}
	fmt.Printf("restoring node %s: removing label %s=%q and taint %s=%q/%s, and the journal for tx %s\n",
		nodeName, workerLabelKey, obs.LabelValue, workerTaintKey,
		obs.Journal.Installed.TaintValue, obs.Journal.Installed.TaintEffect, txID)
	// releaseAcquired always runs on a bounded, uncancelled context, the same as every other release call
	// site in this package: a half-applied restoration must be allowed to finish even if the operator's own
	// signal handling (if any wraps ctx) fires mid-patch, but the wait still cannot be indefinite.
	//
	// It is releaseAcquired rather than releaseOwned because this recovery holds nothing: the read above and
	// the read inside can race a genuine release, and finding the node already clean by then is the outcome
	// the operator wanted, not a lost transaction.
	relCtx, relCancel := cleanupContext()
	defer relCancel()
	_, err = releaseAcquired(relCtx, c, obs.Journal)
	return err
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
		quotedOrNone(obs.JournalRaw), q.QuarantineID)
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
	// Every other hint this tool prints is a complete runnable command, and the operator who has just broken
	// a node is exactly the one who should not have to reconstruct the second step from the flag list.
	fmt.Printf("node %s is QUARANTINED as %s; no run can acquire it until it is cleared.\n"+
		"  Once you have established the previous process is dead:\n"+
		"    queuelabrun -clear-quarantine -worker %s -quarantine-id %s -confirm-owner-dead\n",
		nodeName, q.QuarantineID, nodeName, q.QuarantineID)
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
//
// It reports which of the two release actions it carried out, because "there was nothing of mine to undo"
// means something different to each caller: to the operator modes and to acquire's self-release it is a
// legitimate success, while to the run that holds the worker it is proof its markers were taken from it.
// releaseOwned below is the caller that draws that distinction.
func releaseAcquired(ctx context.Context, c client.Client, j journal) (releaseAction, error) {
	var lastErr error
	for attempt := 0; attempt < acquireAttempts; attempt++ {
		var n corev1.Node
		if err := c.Get(ctx, client.ObjectKey{Name: j.Node}, &n); err != nil {
			return releaseRestore, fmt.Errorf("get node %s: %w", j.Node, err)
		}
		obs := observe(&n)
		act, err := decideRelease(obs, j.TxID)
		if err != nil {
			return act, err
		}
		if act == releaseAlreadyDone {
			return act, nil
		}
		base := n.DeepCopy()
		delete(n.Labels, workerLabelKey)
		delete(n.Annotations, journalKey)
		n.Spec.Taints = withoutOwnershipTaint(obs.AllTaints)
		err = c.Patch(ctx, &n, client.MergeFromWithOptions(base, client.MergeFromWithOptimisticLock{}))
		switch {
		case err == nil:
			// acquireWorker has verifyAcquired for exactly this reason: a status code proves the API server
			// accepted the request, not that what it committed is what a subsequent reader will see. Release
			// now follows the same discipline and reads back before letting the caller trust restoration.
			if verr := verifyReleased(ctx, c, j.Node, j); verr != nil {
				return releaseRestore, fmt.Errorf("release node %s: patch succeeded but restoration did not verify: %w",
					j.Node, verr)
			}
			return releaseRestore, nil
		case apierrors.IsConflict(err):
			// Retrying is legal here because release re-verifies identity on every attempt and is not
			// racing anyone for exclusivity.
			lastErr = err
			continue
		default:
			// Acquisition has resolveAmbiguousAcquire for exactly this class of error and release had no
			// counterpart, so a non-conflict Patch failure whose write actually landed — a proxy timeout, a
			// connection reset after commit — made the run print "worker not restored" and exit non-zero for a
			// node that was already clean. That is a false invalidation, and the lab pays for those in runs.
			//
			// The direction of failure stays safe because only a positive proof passes: verifyReleased must
			// observe our label gone, our taint value gone, our journal gone and the same node UID, and it
			// fails closed on an unreadable journal or a Get it cannot complete. It deliberately tolerates
			// another transaction having acquired in the meantime, which is verifyClean's whole contract and
			// is an ordinary race rather than a restoration failure.
			//
			// A 409 cannot reach here, which is what keeps this narrow: had a concurrent -release-stale or
			// -force-release removed our markers before this patch, it would have moved the resourceVersion and
			// the optimistic lock would have failed with a conflict, sending us round the loop to a fresh
			// decideRelease that sees the loss. So a clean read-back here is our own write far more plausibly
			// than somebody else's.
			if verr := verifyReleased(ctx, c, j.Node, j); verr != nil {
				return releaseRestore, fmt.Errorf(
					"release node %s: %w (the read-back could not prove restoration either: %v)", j.Node, err, verr)
			}
			return releaseRestore, nil
		}
	}
	return releaseRestore, fmt.Errorf("release node %s: %d conflicts, giving up: %w",
		j.Node, acquireAttempts, lastErr)
}

// releaseOwned is the release of a worker this process is still holding, and it is the only release for
// which a free node is a failure.
//
// decideRelease cannot make this call on its own: reading a node with no journal and no markers, it cannot
// tell "already released" from "released out from under a live run", and both operator recovery and
// acquire's own self-release legitimately meet the first. The run does know — it installed those markers
// and never removed them — so the distinction is drawn here, at the one call site that has that knowledge.
//
// A free worker at this point means someone ran -release-stale or the force/clear break-glass pair against
// a live transaction, or the node was deleted and recreated. In every one of those the run lost exclusive
// use of the GPU somewhere it cannot bound, which is exactly the "looked fine, was allowed to count"
// failure the whole transaction exists to stop, so it invalidates rather than reporting a clean release.
func releaseOwned(ctx context.Context, c client.Client, j journal) error {
	act, err := releaseAcquired(ctx, c, j)
	if err != nil {
		return err
	}
	if act == releaseAlreadyDone {
		return refuse(reasonOwnershipLost,
			"worker %s no longer carries this run's markers; ownership was lost mid-run under tx %s",
			j.Node, j.TxID)
	}
	return nil
}
