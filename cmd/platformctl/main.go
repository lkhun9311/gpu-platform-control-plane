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

// Command platformctl reads and writes the operations ledger from a shell.
//
// It exists because the ledger's whole claim is evidence that outlives the cluster that produced it, and a
// record that needs Go written against it to be read is not evidence anyone can check. The seven other
// binaries here are all things you point AT a live cluster; none of them reads a durable record, and
// workloadrunctl -- the superficially closest -- "runs the WorkloadRun reconciler and nothing else".
//
// Design of record: docs/superpowers/specs/2026-09-27-operations-ledger-slice-one-design.md.
//
// Two conventions worth stating because they are deliberate refusals:
//
// -ledger has NO DEFAULT. A default path would let `project` create a database the operator never named, in a
// directory they were not thinking about, and let `list` read one they did not mean.
//
// `project` prints what it recorded rather than "ok". A projector that reported success would make "wrote
// nothing because the cluster had nothing" and "wrote nothing because the ledger was already ahead" the same
// output, and those are different facts.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"text/tabwriter"
	"time"

	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/ledger"
)

func main() {
	if len(os.Args) < 3 || os.Args[1] != "workload-runs" {
		usage()
		os.Exit(2)
	}
	var err error
	switch os.Args[2] {
	case "project":
		err = project(os.Args[3:])
	case "list":
		err = list(os.Args[3:])
	case "get":
		err = get(os.Args[3:])
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "platformctl: %v\n", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `platformctl reads and writes the operations ledger.

  platformctl workload-runs project -ledger PATH [-namespace NS]
        read WorkloadRuns from the cluster in the current kubecontext and record them

  platformctl workload-runs list -ledger PATH
        list the runs the ledger holds

  platformctl workload-runs get -ledger PATH -namespace NS -name NAME
        print one run and its observation trail

-ledger has no default on purpose: a default would create or read a database nobody named.
`)
}

// project reads the cluster and records what it finds.
func project(args []string) error {
	fs := flag.NewFlagSet("project", flag.ExitOnError)
	path := fs.String("ledger", "", "path to the SQLite ledger; created if absent (required)")
	namespace := fs.String("namespace", "", "only this namespace; empty means every namespace")
	timeout := fs.Duration("timeout", time.Minute, "give up reading the cluster after this long")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *path == "" {
		return errors.New("-ledger is required")
	}

	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		return fmt.Errorf("register client-go scheme: %w", err)
	}
	if err := platformv1.AddToScheme(scheme); err != nil {
		return fmt.Errorf("register platform scheme: %w", err)
	}
	cfg, err := ctrl.GetConfig()
	if err != nil {
		return fmt.Errorf("find a cluster to read: %w", err)
	}
	c, err := client.New(cfg, client.Options{Scheme: scheme})
	if err != nil {
		return fmt.Errorf("build client: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	var runs platformv1.WorkloadRunList
	var opts []client.ListOption
	if *namespace != "" {
		opts = append(opts, client.InNamespace(*namespace))
	}
	if err := c.List(ctx, &runs, opts...); err != nil {
		return fmt.Errorf("read WorkloadRuns: %w", err)
	}

	store, err := ledger.Open(*path)
	if err != nil {
		return err
	}
	defer func() { _ = store.Close() }()

	// The projection time is taken once, here, and passed in. Reading the clock inside the projector would
	// stamp rows from one projection with different times.
	p, err := store.ProjectWorkloadRuns(runs.Items, time.Now())
	if err != nil {
		return err
	}
	fmt.Printf("seen=%d written=%d stale=%d without-start=%d events-new=%d events-already=%d\n",
		p.RunsSeen, p.RunsWritten, p.RunsStale, p.RunsWithoutStart, p.EventsWritten, p.EventsAlreadyPresent)
	if p.RunsSeen == 0 {
		// Distinguished from a projection that matched everything already: this one found nothing to read.
		fmt.Println("the cluster reported no WorkloadRuns; nothing was recorded")
	}
	return nil
}

func list(args []string) error {
	fs := flag.NewFlagSet("list", flag.ExitOnError)
	path := fs.String("ledger", "", "path to an existing SQLite ledger (required)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *path == "" {
		return errors.New("-ledger is required")
	}
	store, err := ledger.OpenForRead(*path)
	if err != nil {
		return err
	}
	defer func() { _ = store.Close() }()

	runs, err := store.ListWorkloadRuns()
	if err != nil {
		return err
	}
	if len(runs) == 0 {
		// Said out loud rather than left as empty output. Printing nothing would look the same as a command
		// that failed to run, and the point of OpenForRead's refusal is that those two are not the same.
		fmt.Printf("no runs recorded in %s\n", *path)
		return nil
	}

	// The per-row errors are dropped deliberately, and that is not the same as discarding them: tabwriter
	// keeps the first write error and hands it back from Flush, which is returned. So the failure has exactly
	// one reporting path rather than none.
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	_, _ = fmt.Fprintln(w, "NAMESPACE\tNAME\tSCENARIO\tPHASE\tVERDICT\tTARGET\tPROJECTED")
	for _, r := range runs {
		_, _ = fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\t%s/%s\t%s\n",
			r.Namespace, r.Name, r.Scenario, r.Phase, orNone(r.Verdict),
			r.TargetKind, r.TargetName, r.ProjectedAt.Format(time.RFC3339))
	}
	return w.Flush()
}

func get(args []string) error {
	fs := flag.NewFlagSet("get", flag.ExitOnError)
	path := fs.String("ledger", "", "path to an existing SQLite ledger (required)")
	namespace := fs.String("namespace", "default", "the run's namespace")
	name := fs.String("name", "", "the run's name (required)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *path == "" {
		return errors.New("-ledger is required")
	}
	if *name == "" {
		return errors.New("-name is required")
	}
	store, err := ledger.OpenForRead(*path)
	if err != nil {
		return err
	}
	defer func() { _ = store.Close() }()

	r, trail, err := store.GetWorkloadRun(*namespace, *name)
	if err != nil {
		// Including ledger.ErrNoSuchRun, which exits non-zero on purpose: a run nobody projected is not a run
		// that happened and recorded nothing.
		return err
	}

	fmt.Printf("%s/%s\n", r.Namespace, r.Name)
	fmt.Printf("  uid        %s\n", r.UID)
	fmt.Printf("  scenario   %s\n", r.Scenario)
	fmt.Printf("  target     %s %s/%s\n", r.TargetKind, orEmpty(r.TargetNamespace), r.TargetName)
	fmt.Printf("  phase      %s\n", r.Phase)
	fmt.Printf("  verdict    %s\n", orNone(r.Verdict))
	fmt.Printf("  reason     %s\n", orNone(r.Reason))
	fmt.Printf("  started    %s\n", orNoTime(r.StartedAt))
	fmt.Printf("  last seen  %s\n", orNoTime(r.LastObservedAt))
	fmt.Printf("  generation %d\n", r.ObservedGen)
	fmt.Printf("  projected  %s\n", r.ProjectedAt.Format(time.RFC3339))

	if len(trail) == 0 {
		// A run with no trail is a real state -- it never entered Observing -- and saying so is the whole
		// distinction the ledger exists to keep.
		fmt.Println("  trail      none; this run was never observed")
		return nil
	}
	fmt.Println("  trail")
	// As in list: tabwriter keeps the first write error and Flush returns it, so dropping the per-row values
	// leaves one reporting path rather than none.
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	_, _ = fmt.Fprintln(w, "    #\tELAPSED\tSTATE\tHEALTHY\tWALL CLOCK")
	for _, o := range trail {
		_, _ = fmt.Fprintf(w, "    %d\t%ds\t%s\t%t\t%s\n",
			o.Ordinal, o.ElapsedSeconds, o.State, o.Healthy, orNoTime(o.WallClock))
	}
	return w.Flush()
}

// orNone prints an absent optional as "none" rather than as an empty column, because a blank cell reads as a
// value that was not fetched.
func orNone(s *string) string {
	if s == nil || *s == "" {
		return "none"
	}
	return *s
}

// orNoTime says why there is no time rather than printing the epoch, which would read as a real moment.
func orNoTime(t *time.Time) string {
	if t == nil {
		return "none (this run has no origin to measure from)"
	}
	return t.Format(time.RFC3339)
}

func orEmpty(s string) string {
	if s == "" {
		return "(cluster-scoped)"
	}
	return s
}
