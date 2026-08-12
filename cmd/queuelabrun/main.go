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
			nil, recordRunID(*runID), *armFlag, *preview, started, time.Now())
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
	// run publishes nothing and persists nothing: its deferred emergency release amends the outcome AFTER
	// the return value has been chosen, so anything written from inside it could be contradicted a moment
	// later. By the time these three values exist here, every defer has finished amending them.
	o, events, res := run(ctx, newClusterClient, arm, *runID, namespace, *worker, horizon)

	os.Exit(reportRun(os.Stdout, os.Stderr, writeRecord, runReport{
		Outcome: o,
		Events:  events,
		Result:  res,
		Record:  buildRecord(o, events, *runID, string(arm), *preview, started, time.Now()),
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
// The outcome is a NAMED return because the deferred emergency release below runs after the return value has
// been chosen: a record written from inside this function could be contradicted by a WORKER NOT RESTORED
// line moments later, so the caller persists only what the defers have finished amending. Every return path
// sets o; a zero disposition reaching the record would be a silent lie about what happened.
//
// connect is a parameter rather than a direct newClusterClient call for the same reason dispatchOperatorMode
// takes one: without that seam the amendment this function is shaped around is reachable only by reading it,
// and a regression that stopped the defer amending would leave the suite green.
func run(ctx context.Context, connect clusterClientFunc, arm queuelab.Arm, runID, namespace, worker string,
	horizon time.Duration) (o outcome, events []queuelab.LifecycleEvent, res *queuelab.LabResult) {
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
	// The emergency release covers the paths that return early; the run's own release below sets
	// releaseAttempted before it runs, whatever it returns, so this defer stays a no-op for every path that
	// reached it. It must key on ATTEMPTED rather than succeeded: if the explicit release below fails with
	// ownership-lost (a node observed FREE, not one this defer could do anything more for), re-running it
	// here would print a second, misleading "WORKER NOT RESTORED" for a release that already ran and already
	// invalidated the run.
	defer func() {
		if releaseAttempted {
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

	if err := ensureNamespace(ctx, c, namespace, txID); err != nil {
		o = phaseFailure(dispSetupFailed, fmt.Sprintf("ensuring namespace %s", namespace), err)
		return
	}
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
		// coming: releaseAttempted is already true, so the deferred emergency release above is a no-op, and a
		// real failure here (conflict-bound exhaustion, a non-conflict Patch error, or a verification failure
		// where our markers truly are still installed) means the worker is still marked. The operator needs
		// the same runnable next step the deferred path always printed, not just the reason it failed.
		fmt.Printf("\nRUN INVALIDATED: worker %s not restored: %v\n  run: queuelabrun -inspect-worker -worker %s\n",
			worker, err, worker)
		// classifyReleaseFailure, never classifyPhaseFailure: this release ran on cleanupContext rather than
		// the signal-cancelled run context, so a cancellation surfacing beneath it does not mean the run was
		// cancelled — it means restoration could not be proven, which is the more serious of the two.
		o = classifyReleaseFailure(err)
		return
	}

	// The result is handed back only once restoration is proven, so the caller has nothing renderable for any
	// run that lost its worker, whatever else that run computed.
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
