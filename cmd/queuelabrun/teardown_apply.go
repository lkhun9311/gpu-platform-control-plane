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

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
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
