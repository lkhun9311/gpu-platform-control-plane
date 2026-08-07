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
	"flag"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/queuelab"
)

// The protocol's fixed parameters, stated here rather than accepted from flags.
//
// They are constants because the design of record fixes them and because the previous CLI let the duration
// be chosen freely, which is how the dose silently became 49 seconds instead of the specified 40.
const (
	victimServiceSec = 60
	doseSec          = 40

	// terminationGraceSec mirrors internal/queuelab's private terminationGraceSec (the Pod termination grace
	// period the fixture runs with). It is duplicated rather than imported because that package must not
	// change for this fix and does not export the constant.
	terminationGraceSec = 30
	// startupMarginSec covers Pod scheduling and container-start latency on each of the schedule's three
	// sequential Ready waits (a1, victim, owner), none of which the protocol's timing accounts for on its own.
	startupMarginSec = 20
)

// horizonSec is the fixed observation window, derived from the protocol's own timing rather than typed in.
//
// A free -horizon flag is how a previous run silently truncated itself and still exited 0: 60 s cuts the run
// off before the owner is ever Ready. The window has to cover the dose (the wait before the owner returns),
// the victim's full service (so an unpreempted victim in N-ref still has time to run out its service), the
// termination grace period (the victim's worst-case shutdown once preempted), and the startup margin above,
// so it sums all four rather than approximating one of them away.
const horizonSec = doseSec + victimServiceSec + terminationGraceSec + startupMarginSec

// horizonFor returns the observation horizon for local iteration, refusing anything short of the protocol's
// fixed window.
//
// A flag that could go below horizonSec would reintroduce the exact truncation this constant exists to rule
// out, so requested only widens the window and never narrows it.
func horizonFor(requested time.Duration) (time.Duration, error) {
	minHorizon := time.Duration(horizonSec) * time.Second
	if requested < minHorizon {
		return 0, fmt.Errorf("-horizon %s is below the protocol's fixed window %s; "+
			"the horizon cannot be shortened without truncating the run", requested, minHorizon)
	}
	return requested, nil
}

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

// requireRunID refuses an empty run id.
//
// The flag used to default to "r1", which made colliding with a previous run's cluster-scoped fixtures
// (ResourceFlavor, ClusterQueue) the default behaviour rather than a rare mistake; there is no safe default,
// so the id must be supplied explicitly.
func requireRunID(runID string) error {
	if runID == "" {
		return fmt.Errorf("-runid is required and has no default: a reused or shared id lets a stale " +
			"cluster-scoped fixture from a different arm silently answer for this run")
	}
	return nil
}

// refusePreviewOut refuses to combine -preview with -out.
//
// The trace and dose are now compile-time constants, so a bare ledger JSONL is enough on its own for someone
// to reconstruct a number offline; a preview run has no validity gates behind it, so that file must never
// become an artifact that looks like evidence.
func refusePreviewOut(preview bool, out string) error {
	if preview && out != "" {
		return fmt.Errorf("-preview and -out cannot be combined: a preview ledger must not become an " +
			"artifact someone reconstructs offline")
	}
	return nil
}

// variantLabelKey mirrors internal/queuelab's private variantLabel, duplicated for the same reason as
// terminationGraceSec above: that package must not change and does not export it.
const variantLabelKey = "queuelab.gpu-platform/variant"

// checkFlavorVariant refuses a run whose cluster-scoped ResourceFlavor was left behind by a prior run under
// a different policy variant.
//
// ResourceFlavor and ClusterQueue are cluster-scoped and named from the run id alone, so reusing an id after
// deleting only the namespace leaves them in place; without this check the run would proceed under the old
// arm's mechanism while printing this arm's label.
func checkFlavorVariant(existingLabels map[string]string, wantVariant string) error {
	if got := existingLabels[variantLabelKey]; got != wantVariant {
		return fmt.Errorf("resource flavor already exists with variant %q, this arm requires %q "+
			"(run id likely reused from a different arm)", got, wantVariant)
	}
	return nil
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

// operatorModeArgs bundles the operator-mode flags into named fields.
//
// dispatchOperatorMode used to take these eleven values as positional bool/string parameters; two adjacent
// bools (accept-divergence, clear-quarantine) could be swapped at the call site and the compiler would not
// notice, silently rewiring the attestation gate for the most destructive path onto the wrong mode. A
// struct with named fields turns that mistake from silent into a field name that visibly does not match
// what it is assigned.
type operatorModeArgs struct {
	Arm    string
	Worker string

	// Inspect names no node of its own: like the other three modes it acts on Worker, so a hint this tool
	// prints for one mode cannot be right while the same hint for another is not runnable as printed.
	Inspect bool

	ReleaseStale bool
	TxID         string

	ForceRelease     bool
	NodeUID          string
	AcceptDivergence bool

	ClearQuarantine bool
	QuarantineID    string

	// ConfirmOwnerDead is shared by -release-stale and -clear-quarantine because both turn on the same
	// judgement — that the process which held the worker is gone — and nothing this tool can observe makes
	// that judgement for the operator.
	ConfirmOwnerDead bool

	// RunOnlyFlags names the run-configuration flags the operator actually supplied alongside a mode.
	//
	// It is the flag NAMES rather than their values because that is the only thing that distinguishes a flag
	// left at its default from one typed with the same value as its default, and -horizon has a default.
	RunOnlyFlags []string
}

// runOnlyFlagNames are the flags that configure a run and mean nothing to a recovery mode.
//
// -worker is not among them: every mode acts on it. -arm is not either, because it has its own refusal that
// says the specific thing worth saying — a mode is not a run.
var runOnlyFlagNames = map[string]bool{"runid": true, "out": true, "preview": true, "horizon": true}

// suppliedRunOnlyFlags reports which run-only flags were present on the command line, in a stable order.
//
// flag.Visit walks only the flags actually set, which is what makes this a report of what the operator typed
// rather than of what the defaults happen to be. It takes the FlagSet rather than reading the global one so
// the refusal it feeds can be tested without a process-wide command line.
func suppliedRunOnlyFlags(fs *flag.FlagSet) []string {
	var names []string
	fs.Visit(func(f *flag.Flag) {
		if runOnlyFlagNames[f.Name] {
			names = append(names, "-"+f.Name)
		}
	})
	sort.Strings(names)
	return names
}

// refuseExtraArgs refuses leftover positional arguments, of which this executable accepts none.
//
// -inspect-worker becoming a bool is what makes them dangerous rather than merely untidy: the old
// `-inspect-worker platform-worker2` invocation still parses cleanly, with the node name silently demoted
// to a positional argument, and would report on -worker's default instead of the node the operator named —
// an operator deciding whether to break a stuck node from a report about a different machine.
func refuseExtraArgs(args []string) error {
	if len(args) > 0 {
		return fmt.Errorf("unexpected argument(s) %v: this tool takes flags only, and -inspect-worker now "+
			"names its node with -worker like the other operator modes", args)
	}
	return nil
}

// operatorMode names which recovery mode decideOperatorMode selected, or that none was requested.
type operatorMode int

const (
	modeNone operatorMode = iota
	modeInspect
	modeReleaseStale
	modeForceRelease
	modeClearQuarantine
)

// decideOperatorMode is the pure validation layer for the four operator recovery modes: it decides which
// mode (if any) was requested and whether the invocation is well-formed, entirely without touching the
// cluster.
//
// This has to run, in full, before anything that needs a kubeconfig: an operator on a box with no cluster
// access who mistypes a flag combination must see the flag-combination refusal, not a "kubeconfig: ..."
// error that has nothing to do with what they actually got wrong.
//
// modeNone is returned both when no mode was requested (err is nil; the caller falls through to the
// ordinary run) and when a requested mode is malformed (err is non-nil; the caller must still stop rather
// than fall through). The two are distinguished by err, not by the mode value alone.
func decideOperatorMode(a operatorModeArgs) (operatorMode, error) {
	requested := 0
	for _, on := range []bool{a.Inspect, a.ReleaseStale, a.ForceRelease, a.ClearQuarantine} {
		if on {
			requested++
		}
	}
	if requested == 0 {
		return modeNone, nil
	}
	if requested > 1 {
		return modeNone, fmt.Errorf(
			"only one of -inspect-worker, -release-stale, -force-release, -clear-quarantine may be given at a time")
	}
	// An operator mode is a recovery tool, not a run, so combining one with -arm would let "recover the
	// node" and "run an arm" be read as a single invocation.
	if a.Arm != "" {
		return modeNone, fmt.Errorf("an operator mode cannot be combined with -arm: it is a recovery tool, not a run")
	}
	// The same argument as -arm, for the flags that were merely ignored rather than refused. An invocation
	// that names a run id, an output path, a preview or a horizon and then quietly does none of those things
	// reads to its author as configured, which is the worst kind of no-op: they will believe the recovery
	// they just ran was the one they described.
	if len(a.RunOnlyFlags) > 0 {
		return modeNone, fmt.Errorf(
			"an operator mode cannot be combined with %s: a recovery mode ignores every run-only flag, so "+
				"this invocation would have looked configured while doing nothing of the kind",
			strings.Join(a.RunOnlyFlags, ", "))
	}

	switch {
	case a.Inspect:
		return modeInspect, nil
	case a.ReleaseStale:
		if a.TxID == "" {
			return modeNone, fmt.Errorf("-release-stale requires -txid")
		}
		// A matching -txid proves the operator identified the right transaction; it proves nothing about
		// whether that transaction's process is dead, and that is the judgement that actually matters here.
		// Releasing a live run's journal leaves it holding a worker it no longer owns, so this is the mode
		// most likely to cost a run its exclusivity — and, being the one -inspect-worker recommends first,
		// also the most reached for. It is attested like the other two destructive modes.
		if !a.ConfirmOwnerDead {
			return modeNone, fmt.Errorf(
				"-release-stale requires -confirm-owner-dead: a -txid match identifies the transaction but " +
					"cannot show its process is gone, and releasing a live run's journal costs that run its worker")
		}
		return modeReleaseStale, nil
	case a.ForceRelease:
		if a.NodeUID == "" {
			return modeNone, fmt.Errorf(
				"-force-release requires -node-uid: it is the operator's confirmation of the target")
		}
		// Nothing can prove the previous process is dead, so forcing requires the operator's explicit
		// attestation rather than proceeding on the node-uid confirmation alone.
		if !a.AcceptDivergence {
			return modeNone, fmt.Errorf(
				"-force-release requires -accept-divergence: nothing can prove the previous process is dead, " +
					"so this attests it was the operator's judgement")
		}
		return modeForceRelease, nil
	default: // a.ClearQuarantine
		if a.QuarantineID == "" {
			return modeNone, fmt.Errorf("-clear-quarantine requires -quarantine-id")
		}
		if !a.ConfirmOwnerDead {
			return modeNone, fmt.Errorf(
				"-clear-quarantine requires -confirm-owner-dead: clearing is a separate, deliberate act and " +
					"this attests the operator has established the previous owner is dead")
		}
		return modeClearQuarantine, nil
	}
}

// unimplementedGates names the validity work this executable does not yet have.
//
// The ownership transaction itself now exists — acquire, release, and the operator modes in
// ownership_apply.go that recover a Node after a crash — so that line is narrowed here rather than
// deleted: what remains is proving the exclusivity held for the whole run, not just at acquire and
// release. Continuous evidence via a Node watch (2c) and a restoration audit recorded in the run artifact
// (2d) are still open pieces.
//
// It exists so the refusal below can be specific: an unexplained failure gets rerun until it passes, while
// a refusal that names what is missing gets fixed.
func unimplementedGates() []string {
	return []string{
		"synchronized list+watch with resourceVersion continuity",
		"environment qualification (capacity, foreign GPU pods, termination canary)",
		"continuous ownership evidence (Node watch) and restoration audit in the run artifact",
		"run artifact with a validity status",
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
