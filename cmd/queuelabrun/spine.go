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
	"fmt"
	"regexp"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/queuelab"
)

// The protocol's fixed parameters, stated here rather than accepted from flags.
//
// They are constants because the design of record fixes them and because the previous CLI let the duration
// be chosen freely, which is how the dose silently became 49 seconds instead of the specified 40.
const (
	victimServiceSec = 60
	doseSec          = 40
)

// runIDPattern is the shape a run id must take, since it becomes a namespace name.
var runIDPattern = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`)

// parseArm resolves the CLI's arm argument to the closed set the experiment defines.
//
// The old CLI took a free-form study and variant, so a combination the experiment never defined could be
// requested and would run; refusing anything outside the three arms is what makes the executable unable to
// produce a result the protocol does not describe.
func parseArm(s string) (queuelab.Arm, error) {
	switch queuelab.Arm(s) {
	case queuelab.ArmAHonor:
		return queuelab.ArmAHonor, nil
	case queuelab.ArmAIgnore:
		return queuelab.ArmAIgnore, nil
	case queuelab.ArmNRef:
		return queuelab.ArmNRef, nil
	default:
		return "", fmt.Errorf("arm must be one of %s, %s, %s; got %q",
			queuelab.ArmAHonor, queuelab.ArmAIgnore, queuelab.ArmNRef, s)
	}
}

// namespaceFor derives this run's namespace from its run id.
//
// It is derived rather than taken from a flag because two runs sharing a namespace is what allowed a
// previous run's leftover objects to satisfy this run's barriers, and fixed trace job names made the
// collision certain.
func namespaceFor(runID string) (string, error) {
	if !runIDPattern.MatchString(runID) {
		return "", fmt.Errorf("run id %q must be a lowercase DNS label", runID)
	}
	ns := "queuelab-" + runID
	if len(ns) > 63 {
		return "", fmt.Errorf("run id %q makes the namespace name too long", runID)
	}
	return ns, nil
}

// unimplementedGates names the validity work this executable does not yet have.
//
// It exists so the refusal below can be specific: an unexplained failure gets rerun until it passes, while
// a refusal that names what is missing gets fixed.
func unimplementedGates() []string {
	return []string{
		"synchronized list+watch with resourceVersion continuity",
		"environment qualification (capacity, foreign GPU pods, termination canary)",
		"node ownership transaction with crash recovery",
		"run artifact with a validity status and non-zero exit",
	}
}

// gateRefusal stops a run that would produce something a reader could mistake for a result.
//
// The measurement layer is correct and the protocol is now wired, but the gates that make a run's evidence
// admissible are later pieces. A previous published result was wrong precisely because a run that looked
// fine was allowed to count, so the executable refuses by default and requires an explicit preview flag
// whose output is labelled as not a result.
func gateRefusal(preview bool) error {
	if preview {
		return nil
	}
	msg := "refusing to run: the validity gates are not implemented yet, so this run cannot count as a result.\nmissing:"
	for _, g := range unimplementedGates() {
		msg += "\n  - " + g
	}
	msg += "\npass -preview to run anyway; its output is a smoke check, not evidence."
	return fmt.Errorf("%s", msg)
}
