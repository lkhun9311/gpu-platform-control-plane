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

	storagev1 "k8s.io/api/storage/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/queuelab"
)

// stateRequest is what one run needs from persistent storage, resolved from the arm before the cluster is
// touched.
//
// A struct rather than a second string parameter for the reason FixtureIdentity is one: run already takes
// three adjacent strings a caller can transpose in silence, a fourth would make that worse, and the
// invariant between these two fields would live nowhere.
type stateRequest struct {
	// Needed is whether this arm's victim checkpoints, and so whether a claim must exist at all.
	Needed bool
	// Class is the StorageClass to create the claim with. Empty exactly when Needed is false:
	// stateRequestFor refuses both of the combinations that would break that.
	Class string
}

// stateRequestFor resolves what an arm needs from storage, refusing an invocation whose -arm and
// -state-class disagree.
//
// Both directions are refused rather than only the missing class. A class named for an arm that checkpoints
// nothing creates no claim and does nothing, which is the failure decideOperatorMode already refuses for
// its own run-only flags: the invocation looks configured to its author while doing none of it.
//
// It takes the arm rather than the flag string so the closed list of checkpointing arms stays in the
// protocol. A switch here would be a second enumeration to keep in step, which is item 5 of
// docs/superpowers/specs/2026-09-21-the-resume-arms-and-what-they-contrast.md written again.
func stateRequestFor(a queuelab.Arm, class string) (stateRequest, error) {
	plan, err := a.StateFor(queuelab.VictimRow)
	if err != nil {
		return stateRequest{}, err
	}
	switch {
	case plan.Checkpoint && class == "":
		return stateRequest{}, fmt.Errorf("-arm %s checkpoints, so it needs a PersistentVolumeClaim, and "+
			"-state-class names the StorageClass to create it with. There is no default on purpose: a claim "+
			"created without a class takes the cluster's by omission, and that class is what decides whether "+
			"the replacement Pod reads its predecessor's file or waits on a volume that never binds", a)
	case !plan.Checkpoint && class != "":
		return stateRequest{}, fmt.Errorf("-state-class %q is set but -arm %s checkpoints nothing, so no "+
			"claim would be created and the flag would do nothing; name a checkpointing arm or drop the "+
			"flag rather than leaving an invocation that looks configured to its author", class, a)
	}
	return stateRequest{Needed: plan.Checkpoint, Class: class}, nil
}

// checkStorageClass refuses, before any claim is created, a cluster that cannot provide the class the arm
// asked for.
//
// This is a separate read rather than a question left to the claim's own binding, because an unprovisionable
// claim does not fail: the apiserver accepts it, it stays Pending, and it surfaces much later as a victim
// that never started — on a run that has by then taken a worker, applied fixtures and begun spending its
// horizon. Reading the class first turns that into a refusal naming the class.
//
// A class that exists is not a promise that provisioning succeeds; a broken CSI driver still binds nothing.
// This check removes the one failure mode that is knowable up front, and says nothing about the rest.
func checkStorageClass(ctx context.Context, c client.Client, class string) error {
	var sc storagev1.StorageClass
	err := c.Get(ctx, client.ObjectKey{Name: class}, &sc)
	switch {
	case err == nil:
		return nil
	case apierrors.IsNotFound(err):
		return fmt.Errorf("storage class %q does not exist on this cluster; a claim asking for a class "+
			"nothing provides is accepted and then never binds, so the victim would wait out the horizon "+
			"Pending and the arm would report a contrast it never ran", class)
	default:
		return fmt.Errorf("reading storage class %q: %w", class, err)
	}
}

// createStateClaim creates the progress claim in the run's own namespace, stamped with this run's
// transaction, refusing a leftover it did not create or one created for a different storage class.
//
// It goes through createOwned for the ownership half and relies on sameStateClaim for the mechanism half:
// a claim left by an earlier attempt under the same transaction carries that attempt's class, and adopting
// it would record one class's binding behaviour under another's name.
func createStateClaim(ctx context.Context, c client.Client, id queuelab.FixtureIdentity, class string) error {
	pvc, err := queuelab.StateClaim(id, class)
	if err != nil {
		return err
	}
	return createOwned(ctx, c, pvc, id.TxID)
}
