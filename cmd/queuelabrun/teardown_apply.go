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
	"sort"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	kueuev1beta2 "sigs.k8s.io/kueue/apis/kueue/v1beta2"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/queuelab"
)

// emptyObjectFor returns the zero-value object Get should decode a target's Kind into. It errors on a kind
// enumerate never returns rather than falling back to some default: a new target kind added to enumerate
// without a matching case here must fail loudly, not silently read into the wrong type.
func emptyObjectFor(tg target) (client.Object, error) {
	switch tg.Kind {
	case "Namespace":
		return &corev1.Namespace{}, nil
	case "ClusterQueue":
		return &kueuev1beta2.ClusterQueue{}, nil
	case "ResourceFlavor":
		return &kueuev1beta2.ResourceFlavor{}, nil
	default:
		return nil, fmt.Errorf("recover: no reader registered for target kind %q", tg.Kind)
	}
}

// recoverTargets re-reads every target enumerate names and learns each one's UID from what is actually on
// the cluster, rather than accepting a UID as input. A caller that could hand in UIDs could hand in stale or
// invented ones, which is exactly the residue-printer failure mode this pass exists to rule out: after a
// partial create, the only trustworthy source for "what did THIS run actually make" is a read of the name it
// used, checked against the stamp it wrote at Create.
//
// Ownership is decided here, once, by that stamp — the same test ensureNamespace applies at create time. An
// object found under this run's name but stamped by a different transaction (or not stamped at all) is
// refused outright: recovery cannot express "foreign" as an observation, because classifyAbsence's
// absenceForeign is a UID comparison against a UID this run recorded for an object it created, and there is
// no such UID for an object it never created. Inventing one to force a foreign classification would be
// exactly the lie this whole design refuses to tell. absenceForeign stays the executor's, for the narrower
// case a create-time stamp cannot see: our object deleted and a different one recreated under our name
// between this pass and a later poll, where the WantUID this pass established is what makes that detectable.
func recoverTargets(ctx context.Context, c client.Client, s seed, txID string) ([]observation, error) {
	// txID is a caller-supplied parameter, s.TxID is the durable record this run wrote at Create; nothing
	// stops a caller from passing the two out of sync. Left unguarded, txID == "" would match an unstamped
	// object's absent label (both compare equal to ""), collapsing the unstamped-leftover refusal below, and
	// any other txID would let the caller adopt whatever transaction it names instead of this seed's own. The
	// same reasoning that makes enumerate refuse an empty s.TxID at teardown.go:77 applies here — an
	// unguarded value does not mean "recover less," it means "recover under a different, wrong transaction."
	if txID != s.TxID {
		return nil, fmt.Errorf("recover: txID %q does not match the seed's own TxID %q", txID, s.TxID)
	}
	targets, err := enumerate(s)
	if err != nil {
		return nil, err
	}
	out := make([]observation, 0, len(targets))
	for _, tg := range targets {
		obj, err := emptyObjectFor(tg)
		if err != nil {
			return nil, err
		}
		// Every branch below appends exactly once. A continue here — on a read error especially — would drop
		// the target out of the audit entirely, and "no residue" would then read as clean while the object is
		// still there. That is the batch-level form of unclassified-reads-as-absence, and no coverage check
		// placed afterwards can see it, because the missing observation was never made.
		gerr := c.Get(ctx, client.ObjectKey{Name: tg.Name}, obj)
		switch {
		case apierrors.IsNotFound(gerr):
			out = append(out, observation{Target: tg})
		case gerr != nil:
			out = append(out, observation{Target: tg, Err: gerr})
		default:
			if got := obj.GetLabels()[queuelab.TxLabel]; got != txID {
				return nil, fmt.Errorf("%s %s exists under transaction %q, not this run's %q; "+
					"it is not this run's object to delete", tg.Kind, tg.Name, got, txID)
			}
			uid := string(obj.GetUID())
			out = append(out, observation{
				Target: tg, Found: true, UID: uid, WantUID: uid,
				Terminating: obj.GetDeletionTimestamp() != nil,
			})
		}
	}
	return out, nil
}

// teardownPollInterval is how long the executor waits between rounds of re-reads.
//
// It is a constant rather than a knob because the caller already controls the only input that changes the
// outcome — the budget. A namespace deletion on a real cluster settles in seconds, gated by kube-controller
// -manager's own cleanup, so a tighter interval would add API calls without finishing any sooner.
const teardownPollInterval = 2 * time.Second

// teardownResult is what one teardown attempt proved.
//
// Residue is a result, not a failure to compute one: a run whose budget expired with objects still present
// has established a fact the next run must refuse to start on, and returning it as an error would collapse
// that fact back into "teardown failed" with nothing left to persist.
type teardownResult struct {
	Residue []residue // empty means proven clean
	Elapsed time.Duration
}

// deleteObjectFor builds the object a Delete is issued against: this target's kind and name, and nothing
// else, so no stale spec read earlier in the run can travel into the delete.
//
// It carries no TypeMeta. The typed client resolves the kind from the scheme, not from the object body, so
// stamping a GroupVersionKind here would change nothing on the wire — anything that needs to name what was
// deleted resolves the kind the same way the client does.
func deleteObjectFor(tg target) (client.Object, error) {
	obj, err := emptyObjectFor(tg)
	if err != nil {
		return nil, err
	}
	obj.SetName(tg.Name)
	return obj, nil
}

// deleteTarget issues the one Delete this run is entitled to issue for a target.
//
// The UID precondition is not a nicety. Between the read that learned the UID and this call, another actor
// can delete the name and recreate it, and an unconditioned delete-by-name would then destroy the
// replacement — an object this run never created and has no authority over. The precondition makes the
// apiserver refuse instead of leaving that outcome to timing. o.WantUID is non-empty by construction here:
// classifyAbsence returns absenceUnknown when it is empty, so a target with no recovered UID never reaches a
// delete at all.
//
// WantUID and UID are equal at every call site today, because the only classification that reaches a delete
// is absencePresent and that classification requires them to match. WantUID is still the right field to read:
// it is what this run recorded, so it stays correct if the gate below it ever widens, whereas o.UID is
// whatever the last read happened to see.
func deleteTarget(ctx context.Context, c client.Client, o observation) error {
	obj, err := deleteObjectFor(o.Target)
	if err != nil {
		return err
	}
	uid := types.UID(o.WantUID)
	return c.Delete(ctx, obj, client.Preconditions{UID: &uid})
}

// observeTarget re-reads one target and reports what that read found, against the UID recovery established.
//
// It deliberately does not re-check the transaction stamp: ownership was decided once, by recoverTargets, and
// the question during polling is the narrower one — is the object we established still the object at this
// name. classifyAbsence answers that from the UID alone, which is exactly what catches our object being
// deleted and a different one recreated under our name mid-teardown, stamped or not.
func observeTarget(ctx context.Context, c client.Client, tg target, wantUID string) observation {
	obj, err := emptyObjectFor(tg)
	if err != nil {
		return observation{Target: tg, WantUID: wantUID, Err: err}
	}
	switch gerr := c.Get(ctx, client.ObjectKey{Name: tg.Name}, obj); {
	case apierrors.IsNotFound(gerr):
		return observation{Target: tg, WantUID: wantUID}
	case gerr != nil:
		return observation{Target: tg, WantUID: wantUID, Err: gerr}
	default:
		return observation{
			Target: tg, Found: true, UID: string(obj.GetUID()), WantUID: wantUID,
			Terminating: obj.GetDeletionTimestamp() != nil,
		}
	}
}

// phasesIn returns the distinct phases the observations carry, ascending.
//
// The order comes from the phase constants rather than from the order the observations happen to arrive in,
// so a target list that reached here shuffled still deletes the namespace first; and a phase added to
// enumerate later is picked up here without a second ordered list to keep in sync with teardown.go.
func phasesIn(obs []observation) []teardownPhase {
	seen := map[teardownPhase]bool{}
	var out []teardownPhase
	for _, o := range obs {
		if seen[o.Target.Phase] {
			continue
		}
		seen[o.Target.Phase] = true
		out = append(out, o.Target.Phase)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

// phaseTargetSettled reports whether a target has stopped holding its phase open.
//
// Absent is the only thing that proves the object is gone. Foreign settles the phase too, but for the
// opposite reason: the name is held by an object under a different UID, so ours is no longer there, and
// continuing to poll would be waiting on a deletion this run does not control — the outcome teardown.go
// refuses when it declines to report a foreign object as present. It is not evidence of a clean teardown
// either, so residual keeps it in the residue; it simply stops holding the next phase hostage.
func phaseTargetSettled(o observation) bool {
	switch classifyAbsence(o, o.WantUID) {
	case absenceAbsent, absenceForeign:
		return true
	default:
		return false
	}
}

// settlePhase deletes one phase's targets and then polls them to absence, updating their observations in
// place so the caller always holds the freshest read of every target. It reports whether the phase settled;
// false means the budget ran out with something still there.
//
// A Delete that the apiserver refused is recorded in deleteErrs, keyed by target name, rather than written
// onto the observation. The read that follows in the same round is better evidence of whether the object is
// still there, and would overwrite anything written onto the observation before any caller could see it —
// but the read says nothing about WHY the object survived, and "the apiserver refused" is the single most
// useful thing a residue record can carry. deleteTargets folds these back in at the end, for targets that
// never settled.
func settlePhase(ctx context.Context, c client.Client, latest []observation, phase teardownPhase,
	now func() time.Time, sleep func(time.Duration), deadline time.Time, deleteErrs map[string]error) bool {
	for {
		for i := range latest {
			o := &latest[i]
			if o.Target.Phase != phase {
				continue
			}
			// Terminating is what separates "deletion already requested, keep polling" from "issue the
			// Delete". Re-issuing against an object that already carries a deletionTimestamp buys nothing —
			// the request was accepted and a finalizer, not a missing Delete, is what holds it. Re-issuing
			// against one that is present and NOT terminating is the opposite: evidence the previous attempt
			// did not take, which is the case worth another try.
			if classifyAbsence(*o, o.WantUID) != absencePresent || o.Terminating {
				continue
			}
			err := deleteTarget(ctx, c, *o)
			switch {
			case err == nil || apierrors.IsNotFound(err):
				// Already gone is not a failure, and a successful request clears any earlier refusal so a
				// transient one cannot haunt a target that did in the end come away.
				delete(deleteErrs, o.Target.Name)
			default:
				// A Forbidden here is teardown discovering that this run's delete authority was never
				// verified, and that is a fact to report, not a reason to crash and abandon the rest of the
				// set. It is held aside rather than written onto the observation so it neither gets erased by
				// this round's own read nor stops the next round from trying the Delete again.
				deleteErrs[o.Target.Name] = err
			}
		}

		// Read after deleting, so the loop always exits on evidence rather than on the assumption that an
		// accepted Delete completed. An accepted Delete is a request; only a read proves the result.
		for i := range latest {
			o := &latest[i]
			if o.Target.Phase != phase || phaseTargetSettled(*o) {
				continue
			}
			*o = observeTarget(ctx, c, o.Target, o.WantUID)
		}

		done := true
		for _, o := range latest {
			if o.Target.Phase == phase && !phaseTargetSettled(o) {
				done = false
				break
			}
		}
		if done {
			return true
		}
		// The budget is checked here, against the injected clock, and never against ctx. A context deadline
		// would surface expiry as an ordinary cancellation indistinguishable from the caller giving up, and
		// expiry is the one path that must report residue.
		if !now().Before(deadline) {
			return false
		}
		sleep(teardownPollInterval)
	}
}

// deleteTargets deletes everything this run created, in the order Kueue's finalizers allow, and reports what
// would not go away.
//
// The deletion set comes only from enumerate via recoverTargets — no List, no label selector, no DeleteAllOf.
// A selector deletes whatever currently matches it, which is not the same set as "what THIS run created": a
// concurrent run's objects can match, and the seed exists precisely to remove that ambiguity.
func deleteTargets(ctx context.Context, c client.Client, s seed, txID string,
	now func() time.Time, sleep func(time.Duration), budget time.Duration) (teardownResult, error) {
	start := now()
	deadline := start.Add(budget)

	// Ownership is decided once, here, by recoverTargets — which refuses outright on an object stamped by
	// another transaction. Nothing below re-derives it, so there is exactly one place that can be wrong about
	// whose objects these are.
	latest, err := recoverTargets(ctx, c, s, txID)
	if err != nil {
		return teardownResult{}, err
	}

	deleteErrs := map[string]error{}
	for _, phase := range phasesIn(latest) {
		if !settlePhase(ctx, c, latest, phase, now, sleep, deadline, deleteErrs) {
			// A phase that did not settle stops teardown here rather than advancing. Deleting a ClusterQueue
			// while the namespace holding its Workloads is still there does not fail loudly — it blocks on
			// the resource-in-use finalizer — so pressing on buys nothing and buries which object is stuck.
			break
		}
	}

	// Fold the refusals back in, last, and only onto targets that never settled. A residue record saying
	// "still present" and nothing else reads as a slow finalizer, so the next run refuses to start with no
	// clue why; carrying the refusal makes the difference between "waiting" and "not allowed" legible. It is
	// applied here rather than during the loop because a target that did eventually come away has nothing to
	// explain, and because classifyAbsence turns a carried error into absenceUnknown — which, mid-loop, would
	// have stopped the retry that removed it.
	for i := range latest {
		o := &latest[i]
		if o.Err == nil && !phaseTargetSettled(*o) {
			if derr := deleteErrs[o.Target.Name]; derr != nil {
				o.Err = derr
			}
		}
	}
	return teardownResult{Residue: residual(latest), Elapsed: now().Sub(start)}, nil
}
