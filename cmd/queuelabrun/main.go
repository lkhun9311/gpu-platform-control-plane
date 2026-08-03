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
		studyFlag = flag.String("study", "reclaim", "study: reclaim | fifo")
		variant   = flag.String("variant", "Any", "variant within the study")
		runID     = flag.String("runid", "r1", "unique run id")
		namespace = flag.String("ns", "queuelab", "namespace for LocalQueues and jobs")
		worker    = flag.String("worker", "platform-worker", "node to dedicate to this run")
		durSec    = flag.Int("dur", 60, "trace job duration seconds")
		horizon   = flag.Duration("horizon", 150*time.Second, "observation horizon")
		out       = flag.String("out", "", "optional path to write the ledger JSONL")
	)
	flag.Parse()

	if err := run(*studyFlag, *variant, *runID, *namespace, *worker, *durSec, *horizon, *out); err != nil {
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		os.Exit(1)
	}
}

func run(studyName, variant, runID, namespace, worker string, durSec int, horizon time.Duration, out string) error {
	study := queuelab.Study(studyName)
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

	trace, err := buildTrace(study, durSec)
	if err != nil {
		return err
	}
	if err := queuelab.ValidateTrace(study, trace); err != nil {
		return fmt.Errorf("trace invalid: %w", err)
	}
	schedule, err := queuelab.StudySchedule(study, trace)
	if err != nil {
		return err
	}

	if err := ensureNamespace(ctx, c, namespace); err != nil {
		return err
	}
	fs, err := queuelab.BuildFixtures(study, variant, runID, namespace)
	if err != nil {
		return err
	}
	if err := applyFixtures(ctx, c, fs); err != nil {
		return err
	}
	if err := dedicateWorker(ctx, c, worker, runID); err != nil {
		return err
	}
	defer func() { _ = releaseWorker(context.Background(), c, worker) }()

	fmt.Printf("run %s: study=%s variant=%s ns=%s worker=%s horizon=%s\n",
		runID, study, variant, namespace, worker, horizon)

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
		if err := submit(ctx, c, col, step.Row, namespace); err != nil {
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
		return nil
	}
	res, err := queuelab.Reconstruct(variant, trace, events, col.elapsed().Nanoseconds())
	if err != nil {
		fmt.Printf("\nRECONSTRUCT ERROR: %v\n", err)
		printEvents(events)
		return nil
	}
	fmt.Print("\n" + queuelab.RenderResult(res))
	fmt.Printf("\nledger: %d events\n", len(events))
	printEvents(events)
	return nil
}

func buildTrace(study queuelab.Study, durSec int) ([]queuelab.TrainingTraceRow, error) {
	switch study {
	case queuelab.StudyReclaim:
		return queuelab.ReclaimScenario(true, durSec), nil
	case queuelab.StudyFIFO:
		return queuelab.FIFOHeadOfLineScenario(durSec, durSec/4+1), nil
	default:
		return nil, fmt.Errorf("unknown study %q", study)
	}
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
