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

// Command queuelabrun executes one queuelab arm against a live Kueue cluster: it applies the study's
// dedicated fixtures, labels and taints a dedicated worker, submits the trace on observed-state barriers,
// watches the Workload/Pod/Job/MLTrainingJob lifecycle into a fail-closed ledger, and reconstructs the
// censoring-aware result.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"
	"time"

	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/clientcmd"
	"sigs.k8s.io/controller-runtime/pkg/client"
	kueuev1beta2 "sigs.k8s.io/kueue/apis/kueue/v1beta2"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/queuelab"
)

func main() {
	var (
		armFlag     = flag.String("arm", "", "arm: A-honor | A-ignore | N-ref")
		runID       = flag.String("runid", "", "unique run id (required, no default: a reused id can confound a run)")
		worker      = flag.String("worker", "platform-worker", "node to dedicate to this run")
		horizonFlag = flag.Duration("horizon", time.Duration(horizonSec)*time.Second,
			"observation horizon (must not be below the protocol's fixed window)")
		// -out is deliberately not required, even for a non-preview run: -runid has no safe default because
		// ANY default (a reused id, e.g. "r1") collides with a prior run's cluster-scoped fixtures, a defect no
		// amount of printing can undo. An unnamed -out has no equivalent hazard once recordPathFor's default is
		// collision-free and this file prints wherever it wrote — see recordPathFor and reportRun. Requiring it
		// anyway would be a flag every invocation must remember to pass for a safety property the default
		// already has, which is friction without a matching gain.
		// The help text warns about replacement because naming a fixed path is how an operator reintroduces the
		// very defect recordPathFor's default was reshaped to remove: writeRecord replaces by rename, so a
		// wrapper script passing `-out record.json` destroys the previous invocation's record on the next run.
		out = flag.String("out", "", "path to write this invocation's run record; an existing file there is "+
			"replaced, so a fixed path loses the previous run's record (default: a per-invocation name in the "+
			"working directory, which never collides)")
		preview = flag.Bool("preview", false, "run without the validity gates; output is a smoke check, not evidence")

		// The operator modes recover from a crash: they inspect, release, or break the Node marker this
		// package's transaction leaves behind. They are flags rather than subcommands only because this CLI
		// was already flag-shaped; see dispatchOperatorMode for why they run before the gate.
		// -inspect-worker names no node of its own: it reads -worker like the other three modes, so that every
		// command this tool prints as a hint is runnable exactly as printed, whichever mode it points at.
		inspectWorkerFlag    = flag.Bool("inspect-worker", false, "read-only: report -worker's ownership state and exit")
		releaseStaleFlag     = flag.Bool("release-stale", false, "release -worker's journal for -txid, after confirming the prior process is gone")
		txidFlag             = flag.String("txid", "", "transaction id to release with -release-stale")
		forceReleaseFlag     = flag.Bool("force-release", false, "break -worker's stuck marker into a quarantine record; never frees the node in one step")
		nodeUIDFlag          = flag.String("node-uid", "", "the Node UID to confirm as the -force-release target")
		acceptDivergenceFlag = flag.Bool("accept-divergence", false, "attest that you accept forcing -worker despite not having tool-verified its installed values")
		clearQuarantineFlag  = flag.Bool("clear-quarantine", false, "clear -worker's quarantine record named -quarantine-id")
		quarantineIDFlag     = flag.String("quarantine-id", "", "the quarantine record to clear")
		confirmOwnerDeadFlag = flag.Bool("confirm-owner-dead", false, "attest that the process which held -worker is confirmed dead (required by -release-stale and -clear-quarantine)")
	)
	flag.Parse()

	// The window a record reports has to open before the first refusal can fire, because the refusals below
	// are records too: a run that is refused is precisely the run that used to leave nothing behind, and the
	// more this tool refuses — which is its entire purpose — the more invocations vanished undiagnosably.
	started := time.Now()
	recordPath := recordPathFor(*out, started, os.Getpid())
	// refuseInvocation records a refusal and NEVER RETURNS.
	//
	// Every caller below depends on that: they refuse on values they have not finished validating, so a
	// version of this that returned would let a refused invocation fall through into a run holding a
	// zero-valued arm, namespace or horizon.
	//
	// The caller prints its own message rather than having this do it, because gateRefusal's is a multi-line
	// explanation that must not be squeezed behind the "ERROR:" prefix the one-line refusals carry.
	refuseInvocation := func(err error) {
		rec := buildRecord(outcome{Disposition: dispRefusedBeforeCluster, Reason: err.Error()},
			nil, nil, recordRunID(*runID), *armFlag, *preview, started, time.Now())
		if werr := writeRecord(recordPath, rec); werr != nil {
			// The record that failed to persist cannot report its own failure, so this is the one outcome that
			// exists only on stderr. It says the record is unproven rather than that nothing changed: a
			// post-rename failure has already put the new content at the path.
			fmt.Fprintln(os.Stderr, "ERROR: run record not persisted:", werr)
		} else {
			// The default path carries a timestamp and a pid, so the operator is told where the record went
			// rather than left to guess at a name this process generated.
			fmt.Fprintln(os.Stderr, "  run record:", recordPath)
		}
		os.Exit(1)
	}

	// Checked before anything dispatches, because the invocation this catches is one that would otherwise
	// run happily against the wrong node.
	if err := refuseExtraArgs(flag.Args()); err != nil {
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		// A stray positional argument is refused before this tool knows whether the invocation was a run or a
		// recovery, so it is recorded: a record naming a refused invocation is worth more than the ambiguity
		// costs, where staying silent would lose the one class of mistake this check exists to catch.
		refuseInvocation(err)
	}

	// Operator modes are recovery tools, not runs, so they dispatch before the gate and work even while the
	// gate refuses every run; each exits directly with its own status rather than falling through to run().
	// Fields are named, not positional, so the flag that fills each one is visible at the call site.
	if fired, err := dispatchOperatorMode(newClusterClient, operatorModeArgs{
		Arm:    *armFlag,
		Worker: *worker,

		// Which run-only flags were actually TYPED, not which hold a non-zero value: -horizon has a default,
		// so its value alone cannot distinguish "left alone" from "configured", and an operator who set it on
		// a recovery invocation must be told it does nothing rather than left believing it took effect.
		RunOnlyFlags: suppliedRunOnlyFlags(flag.CommandLine),

		Inspect: *inspectWorkerFlag,

		ReleaseStale: *releaseStaleFlag,
		TxID:         *txidFlag,

		ForceRelease:     *forceReleaseFlag,
		NodeUID:          *nodeUIDFlag,
		AcceptDivergence: *acceptDivergenceFlag,

		ClearQuarantine: *clearQuarantineFlag,
		QuarantineID:    *quarantineIDFlag,

		ConfirmOwnerDead: *confirmOwnerDeadFlag,
	}); fired {
		// A recovery mode is not a run, so it leaves no run record: writing one would put a document in the
		// record's place describing something the record's schema does not describe.
		if err != nil {
			fmt.Fprintln(os.Stderr, "ERROR:", err)
			os.Exit(1)
		}
		os.Exit(0)
	}

	// The gate runs before the arm and namespace are even parsed, so a refused run cannot mutate the
	// cluster or create fixtures through some later code path that forgets to check it.
	if err := gateRefusal(*preview); err != nil {
		fmt.Fprintln(os.Stderr, err)
		refuseInvocation(err)
	}
	if err := requireRunID(*runID); err != nil {
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		refuseInvocation(err)
	}

	// The arm and the namespace are resolved before anything touches the cluster, so a bad flag is refused
	// up front instead of after fixtures are already applied to some namespace.
	arm, err := parseArm(*armFlag)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		refuseInvocation(err)
	}
	namespace, err := namespaceFor(*runID)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		refuseInvocation(err)
	}
	horizon, err := horizonFor(*horizonFlag)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		refuseInvocation(err)
	}

	if *preview {
		fmt.Println(previewBanner)
	}
	// NotifyContext alone would suppress the default terminate-on-signal behaviour, so every wait below is
	// cancellable too; without that pairing a Ctrl-C would look ignored while the worker stayed dedicated.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	// run publishes nothing and persists nothing: its deferred teardown and emergency release both amend the
	// outcome AFTER the return value has been chosen, so anything written from inside it could be
	// contradicted a moment later. By the time these four values exist here, every defer has finished
	// amending them.
	o, events, res, left := run(ctx, newClusterClient, arm, *runID, namespace, *worker, horizon,
		time.Now, time.Sleep)

	os.Exit(reportRun(os.Stdout, os.Stderr, writeRecord, runReport{
		Outcome: o,
		Events:  events,
		Result:  res,
		Record:  buildRecord(o, events, left, *runID, string(arm), *preview, started, time.Now()),
		Path:    recordPath,
		Preview: *preview,
	}))
}

// runReport is everything the publish-or-not decision needs, in named fields.
//
// The fields are named for the same reason operatorModeArgs' are: two adjacent bools and three slices in
// positional order is an argument list a caller can silently transpose, and this one decides whether a
// result gets published.
type runReport struct {
	Outcome outcome
	Events  []queuelab.LifecycleEvent
	Result  *queuelab.LabResult
	Record  any
	Path    string
	Preview bool
}

// recordWriter is how reportRun persists, so a test can drive the real ordering against a failing write.
type recordWriter func(path string, v any) error

// reportRun persists the record and then, only if that succeeded, publishes the run; it returns the exit
// code rather than calling os.Exit so the ordering it enforces is testable.
//
// That ordering is the point of the whole task: a non-zero exit cannot retract a number that has already
// been printed, so nothing countable may exist before the record of it is durable. It lived inline in main
// until a reviewer observed that no test can call main, which left the one rule this plan exists to
// establish covered by a manual run of the binary alone.
func reportRun(stdout, stderr io.Writer, write recordWriter, r runReport) int {
	// The same substitution buildRecord applies, so the terminal and the record cannot give two accounts of one
	// run: without it a zero disposition prints as "ERROR: :" — the blank field dispUnclassified exists to
	// replace with a failure that names itself — while the file on disk correctly says it was a bug in run().
	// classified is idempotent, so applying it here does not change what buildRecord already decided.
	o := classified(r.Outcome)
	writeErr := write(r.Path, r.Record)
	if writeErr == nil {
		fmt.Fprintln(stderr, "  run record:", r.Path)
		if r.Result != nil && o.Disposition == dispChecksPassed {
			fmt.Fprint(stdout, "\n"+queuelab.RenderResult(*r.Result))
		}
		fmt.Fprintf(stdout, "\nledger: %d events\n", len(r.Events))
		// A preview record deliberately carries a count and no events, so that a run without the validity
		// gates behind it cannot emit anything reconstructable. Printing the ledger would hand back exactly
		// that through a shell redirect, which makes the record's structural guarantee decorative, so the
		// events are withheld from a preview's output for the same reason they are withheld from its record.
		if r.Preview {
			fmt.Fprintln(stdout, "  (withheld: a preview runs without the validity gates, and a printed "+
				"ledger reconstructs just as well as a written one)")
		} else {
			printEvents(stdout, r.Events)
		}
	}
	// The closing banner has to print even when the run failed or its record could not be persisted, or
	// output already on the terminal is left under an opening banner alone and could be mistaken for output
	// nobody flagged.
	if r.Preview {
		fmt.Fprintln(stdout, previewBanner)
	}
	if writeErr != nil {
		// The record that failed to persist cannot report its own failure, so this is the one outcome that
		// exists only on stderr, and nothing above rendered: an unrecorded result must not be published.
		// It says the record is unproven rather than that the previous one survived, because a post-rename
		// failure has already replaced it.
		fmt.Fprintln(stderr, "ERROR: run record not persisted:", writeErr)
		fmt.Fprintf(stderr, "  the outcome was %s: %s\n", o.Disposition, o.Reason)
		return 1
	}
	if o.Disposition != dispChecksPassed {
		fmt.Fprintf(stderr, "ERROR: %s: %s\n", o.Disposition, o.Reason)
		return 1
	}
	return 0
}

// recordPathFor names the record, and the default names it per invocation.
//
// A single fixed default is what made a refusal destructive: every record this build can produce landed on
// one path, writeRecord replaces by rename, and so a mistyped invocation in the working directory silently
// took the previous run's record with it — a refusal erasing evidence, in the task written to stop refusals
// erasing evidence. The timestamp orders the files and the pid separates two invocations within the same
// second, so two records cannot collide by construction rather than by convention.
//
// It is not derived from the run id, because a refusal can fire before -runid has been read at all and a
// record that only existed for invocations identified enough to name a file would miss exactly the refusals
// this record was added to make visible.
func recordPathFor(out string, started time.Time, pid int) string {
	if out != "" {
		return out
	}
	return fmt.Sprintf("queuelabrun-record-%s-%d.json", started.UTC().Format("20060102T150405Z"), pid)
}

// unidentifiedRunID stands in for the run id of an invocation refused before it supplied one.
//
// decodeRunRecord requires a non-empty run id, and the refusal that fires when -runid is missing still has
// to leave a readable record; runIDPattern forbids parentheses, so this can never be mistaken for, or
// collide with, a run id somebody actually passed.
const unidentifiedRunID = "(unidentified)"

func recordRunID(runID string) string {
	if runID == "" {
		return unidentifiedRunID
	}
	return runID
}

// clusterClientFunc is how dispatchOperatorMode obtains its client.
//
// It is a parameter rather than a direct call to newClusterClient so a test can drive the REAL dispatch path
// — including the context it builds and hands to each mode — against a fake cluster. Without that seam the
// only thing a test could reach is the context helper in isolation, and a regression restoring an unbounded
// context at the dispatch site would pass the whole suite.
type clusterClientFunc func() (client.WithWatch, error)

// dispatchOperatorMode runs at most one of the four recovery modes and reports whether one was requested.
//
// These are recovery tools, not runs, so the caller must invoke this before gateRefusal: an operator needs
// -inspect-worker and the release/quarantine modes to work precisely while the gate refuses every run,
// otherwise a crashed process could orphan a Node with no in-tool way to see or clear it. All argument
// validation happens in decideOperatorMode, entirely before connect below: a malformed invocation must be
// refused before it needs a kubeconfig, not after failing to reach one.
func dispatchOperatorMode(connect clusterClientFunc, args operatorModeArgs) (fired bool, err error) {
	mode, err := decideOperatorMode(args)
	if mode == modeNone && err == nil {
		return false, nil
	}
	if err != nil {
		// decideOperatorMode only returns an error once a mode was actually requested, so this is always a
		// fired, refused attempt, never the "nothing requested" case above.
		return true, err
	}

	c, err := connect()
	if err != nil {
		return true, err
	}
	// A signal firing mid-patch is exactly what could leave a mutation half applied, and there is no wait
	// in any of these modes worth making cancellable, so they all run on a context no signal can cancel out
	// from under them — but bounded, not indefinite, for the reason spelled out at operatorModeTimeout.
	ctx, cancel := operatorModeContext()
	defer cancel()

	switch mode {
	case modeInspect:
		return true, inspectWorker(ctx, c, args.Worker)
	case modeReleaseStale:
		return true, releaseStale(ctx, c, args.Worker, args.TxID)
	case modeForceRelease:
		return true, forceQuarantine(ctx, c, args.Worker, args.NodeUID)
	case modeClearQuarantine:
		return true, clearQuarantine(ctx, c, args.Worker, args.QuarantineID)
	default:
		// decideOperatorMode's own switch is exhaustive over the same four modes, so reaching this means the
		// two switches drifted apart, not that the operator did anything wrong.
		return true, fmt.Errorf("internal error: unhandled operator mode %d", mode)
	}
}

// newClusterClient builds the same scheme and kubeconfig-derived client for run() and the operator modes,
// so a recovery action and an ordinary run see the cluster identically.
func newClusterClient() (client.WithWatch, error) {
	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		return nil, err
	}
	for _, add := range []func(*runtime.Scheme) error{platformv1.AddToScheme, kueuev1beta2.AddToScheme} {
		if err := add(scheme); err != nil {
			return nil, err
		}
	}
	cfg, err := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(
		clientcmd.NewDefaultClientConfigLoadingRules(), &clientcmd.ConfigOverrides{}).ClientConfig()
	if err != nil {
		return nil, fmt.Errorf("kubeconfig: %w", err)
	}
	c, err := client.NewWithWatch(cfg, client.Options{Scheme: scheme})
	if err != nil {
		return nil, fmt.Errorf("client: %w", err)
	}
	return c, nil
}

// previewBanner marks preview output so it cannot be mistaken for a countable result.
//
// The validity gates are what make a run's output trustworthy, and preview mode runs without them, so the
// banner has to bracket the result rather than appear only once where scrolled-past output could miss it.
const previewBanner = "==================== PREVIEW: SMOKE CHECK ONLY, NOT EVIDENCE ===================="

// teardownBudget bounds one run's teardown, and it is a constant for the same reason the horizon is: the
// deadline decides whether a run reports a clean teardown or residue, and a knob that could shorten it is a
// knob that can buy a clean-looking record by not waiting for the answer.
//
// The namespace phase is what sizes it. Deleting the namespace waits on kube-controller-manager to remove
// its contents, and the Pods inside carry terminationGraceSec (30s) on top of however long kubelet takes to
// get to them; the two Kueue phases behind it clear in seconds once nothing references them. Three minutes
// is several times over that shape, and it is also the ceiling on how long a stuck teardown holds this
// process before it records the residue and hands the operator a still-dedicated worker.
const teardownBudget = 3 * time.Minute

// teardownContextTimeout is deliberately LARGER than teardownBudget, and the gap is the whole point.
//
// The expiry that has to be reported as residue is the poll loop's own, measured on the injected clock. Were
// the context to expire first, every read and delete would start failing with a cancellation, the executor
// would classify those as absenceUnknown, and a teardown that simply ran out of time would be
// indistinguishable from an orderly shutdown. This context exists only as a backstop against an apiserver
// that never answers at all, so it is bounded but never the binding constraint.
const teardownContextTimeout = teardownBudget + time.Minute

// teardownContext is derived from Background rather than from the run's context, for the same reason
// cleanupContext is: a Ctrl-C landing mid-teardown must not abandon a half-deleted namespace and then
// release the worker on top of it. Containment work runs to completion.
func teardownContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), teardownContextTimeout)
}

// tearDownBeforeRelease deletes everything this run created and reports whether the worker must be kept.
//
// It is a function rather than inline code because run() has to do this twice — once on the path that
// returns normally and once in the deferred path covering every early return — and two copies of a decision
// this consequential is two places for them to drift apart.
//
// hold is true for residue this run is answerable for and for a teardown that could not run at all, and true
// is what HOLDS THE WORKER. Releasing it strips the dedication label and the NoSchedule taint from a node
// whose namespace may still be running this run's GPU Pods, and there is no marker that keeps a scheduler off
// a node while letting the run be over — forceQuarantine's annotation means nothing to the scheduler. So a
// teardown that did not finish sacrifices worker availability to preserve isolation. That is a stated choice,
// and the operator is handed the recovery command rather than left to find it.
//
// The disposition and the hold are decided separately, and only the hold turns on whose objects these are.
// Anything left standing at one of this run's names is amended into the outcome, because the record's residue
// and its disposition must not disagree: a record saying "checks passed" while carrying a residue array is
// two accounts of one run, and this program's whole shape is a refusal to emit those.
func tearDownBeforeRelease(c client.Client, s seed, worker string, now func() time.Time,
	sleep func(time.Duration), o outcome) (outcome, []residue, bool) {
	tctx, cancel := teardownContext()
	defer cancel()
	result, err := deleteTargets(tctx, c, s, s.TxID, now, sleep, teardownBudget)
	if err != nil {
		// A teardown that could not even compute its target set deleted nothing and proved nothing, so for
		// every decision below it is the worst case: hold the worker, and name the cause in the record rather
		// than letting the run look like it cleaned up after itself.
		//
		// This is the one residue-left with nothing in its residue, and after recoverTargets stopped refusing
		// per batch it is no longer reachable from cluster state at all — a txID that disagrees with the seed,
		// a seed enumerate refuses, a target kind with no reader. Each is a bug in this program, which is why
		// the reason carries the error text: there is no object to name.
		o = o.amend(dispResidueLeft, fmt.Sprintf("teardown could not run: %v", err))
		reportResidue(worker, nil, true)
		return o, nil, true
	}
	if len(result.Residue) == 0 {
		return o, nil, false
	}
	// amend rather than assignment, exactly as the deferred emergency release does: a run that failed
	// reconstruction AND then failed to clean up is not the same event as one that only failed to clean up,
	// and the record is the only account of either that survives the process.
	o = o.amend(dispResidueLeft, fmt.Sprintf("teardown left %d object(s) after %s",
		len(result.Residue), result.Elapsed.Round(time.Second)))
	hold := residueHoldsWorker(result.Residue)
	reportResidue(worker, result.Residue, hold)
	return o, result.Residue, hold
}

// residueHoldsWorker decides whether what teardown could not remove is a reason to keep the worker dedicated.
//
// The worker is held to contain GPU Pods, and only this run's own objects can be holding any. absenceForeign
// says the name is held under a stamp or a UID this run never recorded, which means nothing of ours is there:
// either we never created anything at that name (a leftover from a previous attempt under the same run id —
// the ordinary rerun, since only the namespace is ever cleaned up by hand), or ours was deleted and something
// else took the name, which frees a namespace's contents on the way. Holding for that contains nothing, and
// releasing restores the node to exactly the state this run acquired it in — the leftovers were already there
// and were not keeping it busy then either.
//
// The condition is deliberately "nothing left is ours" rather than "something foreign is here": one foreign
// flavor alongside a namespace of ours that will not go away says nothing about that namespace's Pods, so any
// entry that is not foreign holds the worker. absenceUnknown holds it too, by the same rule that makes it the
// zero value — a target nobody could classify must fail toward "still here".
//
// It is the record, not the worker, that carries the fact onward: the residue is persisted either way, so a
// next-run gate keying on it still refuses to start on a name another transaction holds.
func residueHoldsWorker(left []residue) bool {
	for _, r := range left {
		if r.Absence != absenceForeign {
			return true
		}
	}
	return false
}

// reportResidue tells the operator what is still standing at this run's names, and what happened to their
// worker as a result.
//
// The residue also reaches the record, so this is not the only account of it — that is the difference
// between this and the WORKER NOT RESTORED line, which for a long time was printed and then lost. What only
// exists here is the advice, and it differs by case because the two cases need opposite things: a stuck
// object of our own must not have its finalizer stripped, and a name another transaction holds is not ours to
// clear at all.
func reportResidue(worker string, left []residue, held bool) {
	if held {
		fmt.Fprintf(os.Stderr, "TEARDOWN INCOMPLETE: worker %s stays dedicated; its GPUs may still be in use\n",
			worker)
	} else {
		// Saying the worker stays dedicated when it does not would send the operator to -force-release for a
		// node that is already free, and the objects named below are not theirs to delete on this run's say-so.
		fmt.Fprintf(os.Stderr, "TEARDOWN INCOMPLETE: worker %s was released; nothing this run created is still "+
			"on the cluster, but these names are held by another transaction\n", worker)
	}
	for _, r := range left {
		fmt.Fprintf(os.Stderr, "  %s %s: %s\n", r.Observation.Target.Kind, r.Observation.Target.Name,
			absenceName(r.Absence))
	}
	if held {
		fmt.Fprintf(os.Stderr, "  do NOT strip a stuck namespace's finalizer: that orphans its contents, and "+
			"every absence check afterwards reports clean over objects that are still running\n")
		fmt.Fprintf(os.Stderr, "  run: queuelabrun -inspect-worker -worker %s\n", worker)
		return
	}
	fmt.Fprintf(os.Stderr, "  rerun under a run id of its own, or clear those objects first once you have "+
		"established the transaction that created them is gone\n")
}

// phaseFailure is classifyPhaseFailure with the cause folded into the reason.
//
// The record has no field for an error and main prints only the reason, so a reason naming the phase alone
// would leave every refusal saying what the run was doing and never what went wrong — the diagnosability
// the record was added to provide, lost at the point it is written. classifyReleaseFailure already folds its
// cause in the same way.
func phaseFailure(phase disposition, what string, err error) outcome {
	return classifyPhaseFailure(phase, fmt.Sprintf("%s: %v", what, err), err)
}

// run executes one arm and reports what happened to it, publishing and persisting nothing.
//
// The outcome is a NAMED return because the deferred teardown and emergency release below both run after the
// return value has been chosen: a record written from inside this function could be contradicted by a
// TEARDOWN INCOMPLETE or WORKER NOT RESTORED line moments later, so the caller persists only what the defers
// have finished amending. left is named for the same reason and carries the residue out to the record —
// residue that only reached stderr would be printed and lost, which is the failure the record exists to end.
// Every return path sets o; a zero disposition reaching the record would be a silent lie about what happened.
//
// connect is a parameter rather than a direct newClusterClient call for the same reason dispatchOperatorMode
// takes one: without that seam the amendment this function is shaped around is reachable only by reading it,
// and a regression that stopped the defer amending would leave the suite green.
//
// now and sleep are the teardown executor's clock, injected for the same reason and nothing else: teardown
// polls to a three-minute budget, and a test that had to spend three real minutes to see a run report residue
// would be a test nobody runs. Everything else in this function reads the real clock directly.
func run(ctx context.Context, connect clusterClientFunc, arm queuelab.Arm, runID, namespace, worker string,
	horizon time.Duration, now func() time.Time, sleep func(time.Duration)) (o outcome,
	events []queuelab.LifecycleEvent, res *queuelab.LabResult, left []residue) {
	study := queuelab.StudyReclaim
	c, err := connect()
	if err != nil {
		o = phaseFailure(dispClientFailed, "connecting to the cluster", err)
		return
	}

	// The corrected trace gives the victim its own duration instead of sharing one with the co-tenant, so the
	// co-tenant's release cannot be mistaken for the reclamation under test.
	trace, err := queuelab.TerminationContractTrace(victimServiceSec, doseSec)
	if err != nil {
		o = phaseFailure(dispProtocolBuildFailed, "building the trace", err)
		return
	}
	// ValidateTrace still runs because the corrected trace must satisfy the reclaim study's semantic rules,
	// not just the termination-contract shape.
	if err := queuelab.ValidateTrace(study, trace); err != nil {
		o = phaseFailure(dispProtocolBuildFailed, "trace invalid", err)
		return
	}
	schedule, err := queuelab.TerminationContractSchedule(trace, doseSec)
	if err != nil {
		o = phaseFailure(dispProtocolBuildFailed, "building the schedule", err)
		return
	}

	// Ownership is taken before any namespace or fixture exists, so a refused run leaves nothing of its own
	// behind for the next one to trip over.
	txID := newTxID()
	j, err := acquireWorker(ctx, c, worker, txID, runID, string(arm))
	if err != nil {
		o = phaseFailure(dispAcquisitionRefused, fmt.Sprintf("acquire worker %s", worker), err)
		return
	}
	releaseAttempted := false
	// workerHeldForResidue is the deliberate refusal to release, not a release that failed. Teardown sets it
	// when it could not prove this run's objects gone, and it suppresses the emergency release below for the
	// same reason the explicit release is skipped on that path: a node whose namespace may still be running
	// GPU Pods must keep its label and its NoSchedule taint, or the next run acquires a worker that only
	// looks free. It is a second flag rather than a reuse of releaseAttempted because "we chose not to" and
	// "we already tried" want different messages, and the operator acts on the difference.
	workerHeldForResidue := false
	// The emergency release covers the paths that return early; the run's own release below sets
	// releaseAttempted before it runs, whatever it returns, so this defer stays a no-op for every path that
	// reached it. It must key on ATTEMPTED rather than succeeded: if the explicit release below fails with
	// ownership-lost (a node observed FREE, not one this defer could do anything more for), re-running it
	// here would print a second, misleading "WORKER NOT RESTORED" for a release that already ran and already
	// invalidated the run.
	defer func() {
		if releaseAttempted || workerHeldForResidue {
			return
		}
		relCtx, relCancel := cleanupContext()
		defer relCancel()
		if rerr := releaseOwned(relCtx, c, j); rerr != nil {
			fmt.Fprintf(os.Stderr, "WORKER NOT RESTORED: %v\n  run: queuelabrun -inspect-worker -worker %s\n",
				rerr, worker)
			// This defer runs after the return value was chosen, so amending it is the only thing that stops
			// the record being written and then contradicted by the line just printed. amend keeps whatever
			// was originally decided as the cause, because a run that failed reconstruction AND lost its
			// worker is not the same event as one that only lost its worker.
			o = o.amend(dispWorkerNotRestored, fmt.Sprintf("emergency release: %v", rerr))
		}
	}()
	fmt.Printf("  worker %s acquired: tx=%s (if this process dies, run: queuelabrun -inspect-worker -worker %s)\n",
		worker, txID, worker)

	// Both of these used to sit BELOW ensureNamespace, and neither does any I/O — which made that ordering a
	// real hole rather than a matter of taste. ensureNamespace is this run's first Create, and the seed that
	// teardown regenerates its deletion set from cannot be built without the policy variant; so on the path
	// where the namespace was created and PolicyVariant then failed, a namespace existed and no seed did, and
	// teardown could not compute a target set for an object the run demonstrably created. teardown.go
	// specifies the seed as written before the run's first Create, and moving these two up is what makes that
	// true. It also means an invalid arm or an unbuildable fixture set now fails before the run touches the
	// cluster at all, rather than after.
	policyVariant, err := arm.PolicyVariant()
	if err != nil {
		o = phaseFailure(dispSetupFailed, "resolving the arm's policy variant", err)
		return
	}
	fs, err := queuelab.BuildFixtures(study, policyVariant, txID, runID, namespace)
	if err != nil {
		o = phaseFailure(dispSetupFailed, "building fixtures", err)
		return
	}
	s := seed{
		Schema:    teardownSeedSchema,
		TxID:      txID,
		RunID:     runID,
		Arm:       string(arm),
		Study:     study,
		Variant:   policyVariant,
		Namespace: namespace,
	}

	teardownAttempted := false
	// Registered AFTER the emergency release above, and that is the requirement, not an accident of where the
	// code happened to land: defers run LIFO, so registering this one second is what makes it run FIRST.
	// Inverted, the worker's dedication label and NoSchedule taint would come off while this run's namespace
	// still held its GPUs, and the next run would acquire a node that only looks free.
	//
	// It covers every early return from here down; the path that returns normally calls the same function
	// inline, because an inline release later in the body would otherwise beat a defer registered here.
	defer func() {
		if teardownAttempted {
			return
		}
		teardownAttempted = true
		var hold bool
		o, left, hold = tearDownBeforeRelease(c, s, worker, now, sleep, o)
		if hold {
			workerHeldForResidue = true
		}
	}()

	if err := ensureNamespace(ctx, c, namespace, txID); err != nil {
		o = phaseFailure(dispSetupFailed, fmt.Sprintf("ensuring namespace %s", namespace), err)
		return
	}
	if err := applyFixtures(ctx, c, fs, policyVariant, txID); err != nil {
		o = phaseFailure(dispSetupFailed, "applying fixtures", err)
		return
	}

	fmt.Printf("run %s: arm=%s ns=%s worker=%s horizon=%s\n",
		runID, arm, namespace, worker, horizon)

	// The horizon is stamped here, once, as an absolute instant on the collector's own clock: the barrier
	// loop, the observation wait and the reconstruction's censoring boundary all read that one instant, so
	// none of them can be a different number than the others or than the horizon this run was configured with.
	col := newCollector(c, namespace, runID, horizon)
	cctx, cancel := context.WithCancel(ctx)
	defer cancel()
	col.start(cctx)

	// Execute the barrier-staged schedule.
	for i, step := range schedule {
		if err := waitBarriers(ctx, c, namespace, step.After, col); err != nil {
			if ctx.Err() != nil {
				// A signal reached the barrier wait; recording this as a Desync would misread an operator's
				// Ctrl-C as the arm failing to reach its protocol barrier, so it is reported as cancellation.
				cancel()
				col.wait()
				// The events are carried out even though the run is cancelled: they are not a result and
				// nothing renders them, but a cancelled run with an empty record is undiagnosable, which is
				// the invisibility this record exists to end.
				events = col.builder.Events()
				o = phaseFailure(dispCancelled,
					fmt.Sprintf("observation cancelled while waiting for a barrier before step %d (%s)",
						i, step.Row.Name), err)
				return
			}
			// col.desync rather than col.builder.Desync: the four watch goroutines are still running and still
			// calling Observe, and the builder has no locking of its own.
			col.desync(fmt.Sprintf("barrier before step %d (%s): %v", i, step.Row.Name, err))
			break
		}
		if err := submit(ctx, c, col, arm, step.Row, namespace); err != nil {
			// Every return past col.start must stop the watches and join them, the same as the two paths
			// around it. Returning straight out would run the deferred release while four goroutines were
			// still writing to the builder and still watching a namespace the run has abandoned, and nothing
			// would ever reach wg.Wait().
			cancel()
			col.wait()
			events = col.builder.Events()
			o = phaseFailure(dispSetupFailed, fmt.Sprintf("submit %s", step.Row.Name), err)
			return
		}
		fmt.Printf("  submitted %s (t=%s)\n", step.Row.Name, col.elapsed().Round(time.Second))
	}

	// Observe until the horizon.
	werr := waitForHorizon(ctx, col.deadline)
	cancel()
	col.wait()

	// Reading the builder directly is safe only from here down: col.wait() above joined every watch
	// goroutine, so nothing else can touch it again for the rest of the run.
	events = col.builder.Events()
	if werr != nil {
		// waitForHorizon has exactly one failure — the window was cancelled — so this is named cancelled here
		// rather than through some observation-failure disposition that no code path could ever produce.
		o = phaseFailure(dispCancelled, "observing until the horizon", werr)
		return
	}

	// Validity is decided before anything is published, because a non-zero exit cannot retract a number
	// that has already been printed or a record that has already been written.
	if err := col.builder.Err(); err != nil {
		fmt.Printf("\nRUN INVALIDATED: %v\n", err)
		o = phaseFailure(dispCollectorDesync, "run invalidated", err)
		return
	}
	result, err := reconstructAtHorizon(col, arm, trace, events)
	if err != nil {
		fmt.Printf("\nRECONSTRUCT ERROR: %v\n", err)
		// Same reasoning as the invalidation path above: a failed reconstruction is not a result either.
		o = phaseFailure(dispReconstructRefused, "reconstruct failed", err)
		return
	}
	// The victim is identified by ordinal position now, not by cross-watch causal inference, so an unexpected
	// preemption count means that pairing was not actually unambiguous and this reconstruction must be refused
	// rather than printed as if it were.
	if err := arm.AssertCardinality(result); err != nil {
		fmt.Printf("\nRUN INVALIDATED: %v\n", err)
		o = phaseFailure(dispCardinalityRefused, "cardinality check failed", err)
		return
	}

	// Teardown runs here, INLINE and above the release, rather than being left to the defer registered
	// earlier. A defer runs after every inline statement in the function body, so it cannot get ahead of the
	// release call below however it is registered: the ordering the early-return paths get for free has to be
	// written out explicitly on the path that returns normally.
	//
	// teardownAttempted is set before the call for the same reason releaseAttempted is below: whatever this
	// returns, the deferred copy must not run the whole thing a second time.
	teardownAttempted = true
	var holdWorker bool
	o, left, holdWorker = tearDownBeforeRelease(c, s, worker, now, sleep, o)
	if holdWorker {
		// The worker is deliberately kept, so the deferred emergency release must not undo that.
		workerHeldForResidue = true
	} else {
		// The worker is restored, and proven restored, before the result exists anywhere a reader could find
		// it: a run that lost its exclusive worker mid-flight has no claim on the number it computed.
		//
		// releaseOwned rather than releaseAcquired, because a node found already free here is that very case:
		// this run installed the markers and never removed them, so their absence is a lost worker, not a
		// release that had already happened.
		//
		// Set before the call, not after checking its error: the deferred emergency release above must skip
		// because this release ran, regardless of whether it succeeded or invalidated the run.
		releaseAttempted = true
		relCtx, relCancel := cleanupContext()
		err = releaseOwned(relCtx, c, j)
		relCancel()
		if err != nil {
			// This is the one path in the program that can leave a node genuinely held with no further attempt
			// coming: releaseAttempted is already true, so the deferred emergency release above is a no-op, and
			// a real failure here (conflict-bound exhaustion, a non-conflict Patch error, or a verification
			// failure where our markers truly are still installed) means the worker is still marked. The
			// operator needs the same runnable next step the deferred path always printed, not just the reason
			// it failed.
			fmt.Printf("\nRUN INVALIDATED: worker %s not restored: %v\n  run: queuelabrun -inspect-worker -worker %s\n",
				worker, err, worker)
			// classifyReleaseFailure, never classifyPhaseFailure: this release ran on cleanupContext rather
			// than the signal-cancelled run context, so a cancellation surfacing beneath it does not mean the
			// run was cancelled — it means restoration could not be proven, which is the more serious of the
			// two.
			o = classifyReleaseFailure(err)
			return
		}
	}

	// The result is handed back only under an outcome nothing has amended: restoration proven, and teardown
	// with nothing to report. Testing o rather than re-testing the two conditions is what keeps this from
	// drifting out of step with them — a residue that held the worker and a residue that let it go have
	// already been folded into o, and either way this run did not leave the cluster as it found it, so the
	// number it computed is not published under a disposition that says the checks passed.
	if o.Disposition != "" {
		return
	}
	res = &result
	o = outcome{Disposition: dispChecksPassed}
	return
}

// reconstructAtHorizon reconstructs the run's result against the horizon the collector stamped before the
// observation window opened.
//
// It is its own function so the censoring boundary is testable at the CALL SITE rather than only as a value:
// the horizon used to be read off the clock right here, after the watches had been cancelled and joined, and
// a test of the stamped instant alone could not have caught that. Everything this needs is already joined and
// final by the time it runs, so it takes no clock of its own.
func reconstructAtHorizon(col *collector, arm queuelab.Arm, trace []queuelab.TrainingTraceRow,
	events []queuelab.LifecycleEvent) (queuelab.LabResult, error) {
	return queuelab.Reconstruct(string(arm), trace, events, col.horizonNs())
}

// waitForHorizon blocks until the observation deadline or ctx is cancelled, whichever comes first.
//
// A cancelled observation window is an incomplete run, so the signal has to reach this wait and the run
// must then invalidate rather than report whatever it happened to see; the caller classifies this error
// before any result is reconstructed, so a cancellation can never fall through to publication.
//
// These two returns — a cancellation-wrapped error and nil — are the complete set, which is why the caller
// names the failure cancelled outright: there is no non-cancellation way for the observation window to end
// early, and a disposition for one would describe a path no code can take.
func waitForHorizon(ctx context.Context, deadline time.Time) error {
	if remaining := time.Until(deadline); remaining > 0 {
		select {
		case <-ctx.Done():
			return fmt.Errorf("observation cancelled before the horizon: %w", ctx.Err())
		case <-time.After(remaining):
		}
	}
	return nil
}

// printEvents takes its destination rather than writing to stdout directly, so the one caller that must be
// able to withhold the ledger — a preview, whose record carries a count and no events — is a decision a
// test can observe instead of a package-level side effect.
func printEvents(w io.Writer, events []queuelab.LifecycleEvent) {
	for _, e := range events {
		fmt.Fprintf(w, "  t=%-8s %-14s %-14s job=%-10s reason=%s\n",
			time.Duration(e.ElapsedNs).Round(time.Second), e.Kind, e.Type, e.Job, e.Reason)
	}
}
