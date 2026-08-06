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
	)
	flag.Parse()

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
	runErr := run(arm, *runID, namespace, *worker, horizon, *out)
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

// previewBanner marks preview output so it cannot be mistaken for a countable result.
//
// The validity gates are what make a run's output trustworthy, and preview mode runs without them, so the
// banner has to bracket the result rather than appear only once where scrolled-past output could miss it.
const previewBanner = "==================== PREVIEW: SMOKE CHECK ONLY, NOT EVIDENCE ===================="

func run(arm queuelab.Arm, runID, namespace, worker string, horizon time.Duration, out string) error {
	study := queuelab.StudyReclaim
	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		return err
	}
	for _, add := range []func(*runtime.Scheme) error{platformv1.AddToScheme, kueuev1beta2.AddToScheme} {
		if err := add(scheme); err != nil {
			return err
		}
	}

	cfg, err := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(
		clientcmd.NewDefaultClientConfigLoadingRules(), &clientcmd.ConfigOverrides{}).ClientConfig()
	if err != nil {
		return fmt.Errorf("kubeconfig: %w", err)
	}
	c, err := client.NewWithWatch(cfg, client.Options{Scheme: scheme})
	if err != nil {
		return fmt.Errorf("client: %w", err)
	}
	ctx := context.Background()

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
	released := false
	// The emergency release covers the paths that return early; the run's own release in the happy path
	// runs before anything is published, and sets released so this defer stays a no-op.
	defer func() {
		if released {
			return
		}
		if rerr := releaseAcquired(context.Background(), c, j); rerr != nil {
			fmt.Fprintf(os.Stderr, "WORKER NOT RESTORED: %v\n  run: queuelabrun -inspect-worker %s\n", rerr, worker)
		}
	}()
	fmt.Printf("  worker %s acquired: tx=%s (if this process dies, run: queuelabrun -inspect-worker %s)\n",
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
			col.builder.Desync(fmt.Sprintf("barrier before step %d (%s): %v", i, step.Row.Name, err))
			break
		}
		if err := submit(ctx, c, col, arm, step.Row, namespace); err != nil {
			return fmt.Errorf("submit %s: %w", step.Row.Name, err)
		}
		fmt.Printf("  submitted %s (t=%s)\n", step.Row.Name, col.elapsed().Round(time.Second))
	}

	// Observe until the horizon.
	remaining := time.Until(deadline)
	if remaining > 0 {
		time.Sleep(remaining)
	}
	cancel()
	col.wait()

	events := col.builder.Events()
	if out != "" {
		if err := writeLedger(out, events); err != nil {
			return err
		}
		fmt.Printf("  wrote %d ledger events to %s\n", len(events), out)
	}
	if err := col.builder.Err(); err != nil {
		fmt.Printf("\nRUN INVALIDATED: %v\n", err)
		printEvents(events)
		// The ledger is printed for diagnosis, but an invalidated run must exit non-zero so nothing
		// downstream mistakes this for a countable result.
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
	fmt.Print("\n" + queuelab.RenderResult(res))
	fmt.Printf("\nledger: %d events\n", len(events))
	printEvents(events)
	return nil
}

func printEvents(events []queuelab.LifecycleEvent) {
	for _, e := range events {
		fmt.Printf("  t=%-8s %-14s %-14s job=%-10s reason=%s\n",
			time.Duration(e.ElapsedNs).Round(time.Second), e.Kind, e.Type, e.Job, e.Reason)
	}
}

func writeLedger(path string, events []queuelab.LifecycleEvent) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()
	enc := json.NewEncoder(f)
	for i := range events {
		if err := enc.Encode(events[i]); err != nil {
			return err
		}
	}
	return nil
}
