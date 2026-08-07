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
	"encoding/json"
	"flag"
	"fmt"
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
		out     = flag.String("out", "", "optional path to write the ledger JSONL")
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
	// Checked before anything dispatches, because the invocation this catches is one that would otherwise
	// run happily against the wrong node.
	if err := refuseExtraArgs(flag.Args()); err != nil {
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		os.Exit(1)
	}

	// Operator modes are recovery tools, not runs, so they dispatch before the gate and work even while the
	// gate refuses every run; each exits directly with its own status rather than falling through to run().
	// Fields are named, not positional, so the flag that fills each one is visible at the call site.
	if fired, err := dispatchOperatorMode(operatorModeArgs{
		Arm:    *armFlag,
		Worker: *worker,

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
		os.Exit(1)
	}
	// A preview ledger with no gates behind it must not be able to leave the process as a file, so this is
	// checked alongside the other refuse-before-touching-anything checks.
	if err := refusePreviewOut(*preview, *out); err != nil {
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		os.Exit(1)
	}
	if err := requireRunID(*runID); err != nil {
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		os.Exit(1)
	}

	// The arm and the namespace are resolved before anything touches the cluster, so a bad flag is refused
	// up front instead of after fixtures are already applied to some namespace.
	arm, err := parseArm(*armFlag)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		os.Exit(1)
	}
	namespace, err := namespaceFor(*runID)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		os.Exit(1)
	}
	horizon, err := horizonFor(*horizonFlag)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		os.Exit(1)
	}

	if *preview {
		fmt.Println(previewBanner)
	}
	// NotifyContext alone would suppress the default terminate-on-signal behaviour, so every wait below is
	// cancellable too; without that pairing a Ctrl-C would look ignored while the worker stayed dedicated.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	runErr := run(ctx, arm, *runID, namespace, *worker, horizon, *out)
	// The closing banner has to print even when run fails, or an invalidated preview's ledger is dumped
	// under an opening banner alone and could be mistaken for output nobody flagged.
	if *preview {
		fmt.Println(previewBanner)
	}
	if runErr != nil {
		fmt.Fprintln(os.Stderr, "ERROR:", runErr)
		os.Exit(1)
	}
}

// dispatchOperatorMode runs at most one of the four recovery modes and reports whether one was requested.
//
// These are recovery tools, not runs, so the caller must invoke this before gateRefusal: an operator needs
// -inspect-worker and the release/quarantine modes to work precisely while the gate refuses every run,
// otherwise a crashed process could orphan a Node with no in-tool way to see or clear it. All argument
// validation happens in decideOperatorMode, entirely before newClusterClient below: a malformed invocation
// must be refused before it needs a kubeconfig, not after failing to reach one.
func dispatchOperatorMode(args operatorModeArgs) (fired bool, err error) {
	mode, err := decideOperatorMode(args)
	if mode == modeNone && err == nil {
		return false, nil
	}
	if err != nil {
		// decideOperatorMode only returns an error once a mode was actually requested, so this is always a
		// fired, refused attempt, never the "nothing requested" case above.
		return true, err
	}

	c, err := newClusterClient()
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

func run(ctx context.Context, arm queuelab.Arm, runID, namespace, worker string, horizon time.Duration, out string) error {
	study := queuelab.StudyReclaim
	c, err := newClusterClient()
	if err != nil {
		return err
	}

	// The corrected trace gives the victim its own duration instead of sharing one with the co-tenant, so the
	// co-tenant's release cannot be mistaken for the reclamation under test.
	trace, err := queuelab.TerminationContractTrace(victimServiceSec, doseSec)
	if err != nil {
		return err
	}
	// ValidateTrace still runs because the corrected trace must satisfy the reclaim study's semantic rules,
	// not just the termination-contract shape.
	if err := queuelab.ValidateTrace(study, trace); err != nil {
		return fmt.Errorf("trace invalid: %w", err)
	}
	schedule, err := queuelab.TerminationContractSchedule(trace, doseSec)
	if err != nil {
		return err
	}

	// Ownership is taken before any namespace or fixture exists, so a refused run leaves nothing of its own
	// behind for the next one to trip over.
	txID := newTxID()
	j, err := acquireWorker(ctx, c, worker, txID, runID, string(arm))
	if err != nil {
		return fmt.Errorf("acquire worker %s: %w", worker, err)
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
		}
	}()
	fmt.Printf("  worker %s acquired: tx=%s (if this process dies, run: queuelabrun -inspect-worker -worker %s)\n",
		worker, txID, worker)

	if err := ensureNamespace(ctx, c, namespace); err != nil {
		return err
	}
	policyVariant, err := arm.PolicyVariant()
	if err != nil {
		return err
	}
	fs, err := queuelab.BuildFixtures(study, policyVariant, runID, namespace)
	if err != nil {
		return err
	}
	if err := applyFixtures(ctx, c, fs, policyVariant); err != nil {
		return err
	}

	fmt.Printf("run %s: arm=%s ns=%s worker=%s horizon=%s\n",
		runID, arm, namespace, worker, horizon)

	col := newCollector(c, namespace, runID)
	cctx, cancel := context.WithCancel(ctx)
	defer cancel()
	col.start(cctx)

	// Execute the barrier-staged schedule.
	deadline := time.Now().Add(horizon)
	for i, step := range schedule {
		if err := waitBarriers(ctx, c, namespace, step.After, col, deadline); err != nil {
			if ctx.Err() != nil {
				// A signal reached the barrier wait; recording this as a Desync would misread an operator's
				// Ctrl-C as the arm failing to reach its protocol barrier, so it is reported as cancellation.
				cancel()
				col.wait()
				return fmt.Errorf("observation cancelled while waiting for a barrier: %w", ctx.Err())
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
			return fmt.Errorf("submit %s: %w", step.Row.Name, err)
		}
		fmt.Printf("  submitted %s (t=%s)\n", step.Row.Name, col.elapsed().Round(time.Second))
	}

	// Observe until the horizon.
	werr := waitForHorizon(ctx, deadline)
	cancel()
	col.wait()
	if werr != nil {
		return werr
	}

	// Reading the builder directly is safe only from here down: col.wait() above joined every watch
	// goroutine, so nothing else can touch it again for the rest of the run.
	events := col.builder.Events()

	// Validity is decided before anything is published, because a non-zero exit cannot retract a number
	// that has already been printed or a ledger that has already been written.
	if err := col.builder.Err(); err != nil {
		fmt.Printf("\nRUN INVALIDATED: %v\n", err)
		printEvents(events)
		return fmt.Errorf("run invalidated: %w", err)
	}
	res, err := queuelab.Reconstruct(string(arm), trace, events, col.elapsed().Nanoseconds())
	if err != nil {
		fmt.Printf("\nRECONSTRUCT ERROR: %v\n", err)
		printEvents(events)
		// Same reasoning as the invalidation path above: a failed reconstruction is not a result either.
		return fmt.Errorf("reconstruct failed: %w", err)
	}
	// The victim is identified by ordinal position now, not by cross-watch causal inference, so an unexpected
	// preemption count means that pairing was not actually unambiguous and this reconstruction must be refused
	// rather than printed as if it were.
	if err := arm.AssertCardinality(res); err != nil {
		fmt.Printf("\nRUN INVALIDATED: %v\n", err)
		printEvents(events)
		return fmt.Errorf("cardinality check failed: %w", err)
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
		printEvents(events)
		return fmt.Errorf("worker not restored: %w", err)
	}

	if out != "" {
		if err := writeLedger(out, events); err != nil {
			return err
		}
		fmt.Printf("  wrote %d ledger events to %s\n", len(events), out)
	}
	fmt.Print("\n" + queuelab.RenderResult(res))
	fmt.Printf("\nledger: %d events\n", len(events))
	printEvents(events)
	return nil
}

// waitForHorizon blocks until the observation deadline or ctx is cancelled, whichever comes first.
//
// A cancelled observation window is an incomplete run, so the signal has to reach this wait and the run
// must then invalidate rather than report whatever it happened to see; the caller returns this error before
// any ledger is written or any result is reconstructed, so a cancellation can never fall through to
// publication.
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

func printEvents(events []queuelab.LifecycleEvent) {
	for _, e := range events {
		fmt.Printf("  t=%-8s %-14s %-14s job=%-10s reason=%s\n",
			time.Duration(e.ElapsedNs).Round(time.Second), e.Kind, e.Type, e.Job, e.Reason)
	}
}

// writeLedger reports the Close error rather than discarding it.
//
// The ledger is the run's only evidence, and a buffered write can look successful right up until Close, so
// swallowing that error would let a truncated file be reported to the operator as fully written.
func writeLedger(path string, events []queuelab.LifecycleEvent) (err error) {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer func() {
		if cerr := f.Close(); cerr != nil && err == nil {
			err = fmt.Errorf("close ledger %s: %w", path, cerr)
		}
	}()
	enc := json.NewEncoder(f)
	for i := range events {
		if err = enc.Encode(events[i]); err != nil {
			return err
		}
	}
	return nil
}
