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
				if rerr := releaseAcquired(ctx, c, j); rerr != nil {
					return journal{}, fmt.Errorf(
						"acquire node %s: verify failed: %v; release also failed, node may still carry tx %s: %w",
						nodeName, verr, j.TxID, rerr)
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
			return ctx.Err()
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
			return journal{}, ctx.Err()
		case <-time.After(resolveInterval):
		}
	}
	return journal{}, fmt.Errorf(
		"acquire node %s is UNRESOLVED after %v: it may hold tx %s. Run: queuelabrun -inspect-worker %s. Cause: %w",
		nodeName, time.Duration(resolveAttempts)*resolveInterval, j.TxID, nodeName, cause)
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
