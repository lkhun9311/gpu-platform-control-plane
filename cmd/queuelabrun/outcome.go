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
	"fmt"
)

// disposition is what happened to one invocation.
//
// The set is derived from the return graph of main and run rather than invented, because two earlier
// attempts at an asserted list did not survive a walk of the real returns.
type disposition string

const (
	dispRefusedBeforeCluster = disposition("refused-before-cluster")
	dispClientFailed         = disposition("client-failed")
	dispProtocolBuildFailed  = disposition("protocol-build-failed")
	dispAcquisitionRefused   = disposition("acquisition-refused")
	dispSetupFailed          = disposition("setup-failed")
	dispCancelled            = disposition("cancelled")
	dispObservationFailed    = disposition("observation-failed")
	dispCollectorDesync      = disposition("collector-desync")
	dispReconstructRefused   = disposition("reconstruct-refused")
	dispCardinalityRefused   = disposition("cardinality-refused")
	dispWorkerNotRestored    = disposition("worker-not-restored")
	// dispChecksPassed is deliberately not called "valid": four validity gates are unimplemented, so the
	// strongest statement available is that the checks this build implements passed.
	dispChecksPassed = disposition("completed-implemented-checks-passed")
)

// outcome is what run returns instead of a bare error, so its deferred cleanup can amend it.
type outcome struct {
	Disposition disposition
	Reason      string
	Err         error
}

// amend replaces the disposition while preserving what was originally decided as the cause.
//
// The deferred emergency release runs after run has chosen its return value, so without this the record
// could be written and then contradicted by a WORKER NOT RESTORED line moments later.
func (o outcome) amend(d disposition, reason string) outcome {
	if o.Reason != "" {
		reason = reason + " (after " + o.Reason + ")"
	}
	return outcome{Disposition: d, Reason: reason, Err: o.Err}
}

// classifyPhaseFailure applies the causal precedence rule.
//
// Cancellation outranks a phase only when that phase terminated because it observed cancellation; a phase
// that failed on its own terms keeps its own disposition even if a signal is pending elsewhere.
func classifyPhaseFailure(phase disposition, reason string, err error) outcome {
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return outcome{Disposition: dispCancelled, Reason: reason, Err: err}
	}
	return outcome{Disposition: phase, Reason: reason, Err: err}
}

// classifyReleaseFailure is separate because restoration wins once it has begun.
//
// The release runs on cleanupContext rather than the signal-cancelled run context, so a cancellation
// surfacing beneath it does not mean the run was cancelled — it means restoration could not be proven.
func classifyReleaseFailure(err error) outcome {
	return outcome{Disposition: dispWorkerNotRestored, Reason: fmt.Sprintf("release: %v", err), Err: err}
}
