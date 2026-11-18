package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// srpfSweepPort is the port every arm's engine publishes on loopback; one engine runs at a time.
const srpfSweepPort = 8000

// srpfSweep runs the vLLM #58420 sweep on the instance: the pull, the image's identity, the model download, and seven
// arms on fresh engines, every record written as it ends.
//
// It is the paid session's only workload, so the image, the arms, their order and the bounds are constants and no flag moves them.
// -print-arms only prints them, so the session can record, and its offline test check, what the built binary will run.
func srpfSweep(args []string, out io.Writer) error {
	fs := flag.NewFlagSet("srpf-sweep", flag.ContinueOnError)
	dir := fs.String("dir", "", "an existing, empty directory every record is written to")
	hfCache := fs.String("hf-cache", "", "host directory for the model cache; must be absent or empty")
	compileCache := fs.String("compile-cache", "", "host directory for the arms' compile caches; must be absent or empty")
	overlay := fs.String("overlay", "", "the PR head's vllm/v1/core/sched/scheduler.py")
	trace := fs.String("trace", "", "the diagnostic's trace-off-3.jsonl")
	manifest := fs.String("archived-manifest", "", "the diagnostic's manifest-off-3.yaml")
	printArms := fs.Bool("print-arms", false, "print the arms in run order with the SRPF variables each engine is started with, and exit")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *printArms {
		return printSRPFArms(out)
	}
	if *dir == "" || *hfCache == "" || *compileCache == "" || *overlay == "" || *trace == "" || *manifest == "" {
		return errors.New("-dir, -hf-cache, -compile-cache, -overlay, -trace and -archived-manifest are required")
	}
	self, err := os.Executable()
	if err != nil {
		return fmt.Errorf("find the harness binary: %w", err)
	}
	abs := func(p string) string {
		if a, err := filepath.Abs(p); err == nil {
			return a
		}
		return p
	}
	st, ok := bench.LookupStudy(bench.StudySRPF58420Threshold)
	if !ok || st.Frozen == nil {
		return fmt.Errorf("study %q is not registered with a frozen load", bench.StudySRPF58420Threshold)
	}
	timeout := time.Duration(st.Frozen.TimeoutMs) * time.Millisecond
	sweep := &bench.SRPFSweep{
		Docker: execRunner, Exec: execRunner, Self: self,
		// The cache paths are checked as given, since a relative one would be mounted as a named volume.
		HFCache: *hfCache, CompileRoot: *compileCache, Overlay: abs(*overlay),
		Trace: abs(*trace), ArchivedManifest: abs(*manifest), Out: abs(*dir),
		Port: srpfSweepPort, EngineURL: fmt.Sprintf("http://127.0.0.1:%d", srpfSweepPort),
		// No keep-alive: a pooled connection to a removed container would fail a poll for a reason that is not the engine.
		Health:     &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{DisableKeepAlives: true}},
		Logs:       dockerLogs,
		PollEvery:  500 * time.Millisecond,
		StateEvery: 10 * time.Second,
		NewSender: func(url string) (*bench.HTTPSender, error) {
			return bench.NewHTTPSender(url, bench.SRPFSweepModel, nil, timeout,
				bench.SenderConn{MaxIdleConnsPerHost: 8, DrainForReuse: true}), nil
		},
	}
	// The sweep's own bounds sum to SRPFSweepBound, so nothing it starts outlives them, including a step with no bound of its own.
	ctx, cancel := context.WithTimeout(context.Background(), bench.SRPFSweepBound)
	defer cancel()
	sum, err := sweep.Run(ctx)
	for _, a := range sum.Arms {
		line := fmt.Sprintf("%d %s: %s", a.Position, a.Name, a.Outcome)
		if a.Reason != "" {
			line += " (" + a.Reason + ")"
		}
		if f := a.Figures; f != nil {
			line += fmt.Sprintf("; premium TTFT p50 %s p99 %s ms, %d of %d completed; contender e2e p50 %s p95 %s ms, %d of %d completed",
				f.PremiumTTFTP50, f.PremiumTTFTP99, f.Premium.Completed, f.Premium.Rows,
				f.ContenderE2EP50, f.ContenderE2EP95, f.Contender.Completed, f.Contender.Rows)
			line += fmt.Sprintf("; max dispatch lag %.1f ms; %d rows with another prompt length than frozen", f.MaxDispatchLagMs, f.InputTokenMismatches)
		}
		if a.Preemptions != nil {
			line += fmt.Sprintf("; preemptions %g", *a.Preemptions)
		}
		if _, wErr := fmt.Fprintln(out, line); wErr != nil {
			return errors.Join(err, wErr)
		}
	}
	return err
}

// printSRPFArms prints one line per arm in run order: its position, name, policy and the SRPF variables its engine gets.
//
// The variables are read back from the arm's own docker run arguments, so the line shows what the engine is given rather
// than what the arm table says it should be.
func printSRPFArms(out io.Writer) error {
	s := &bench.SRPFSweep{HFCache: "/hf", CompileRoot: "/compile", Overlay: "/overlay", Port: srpfSweepPort}
	for i, a := range bench.SRPFSweepOrder(bench.SRPFSweepOrderSeed) {
		args, err := s.RunArgs(a, "/scheduler.py")
		if err != nil {
			return err
		}
		line := fmt.Sprintf("%d %s", i+1, a.Name)
		env := []string{}
		for _, arg := range args {
			if p, ok := strings.CutPrefix(arg, "--scheduling-policy="); ok {
				line += " policy=" + p
			}
			if v, ok := strings.CutPrefix(arg, "--env="); ok && strings.HasPrefix(v, "VLLM_") && strings.Contains(v, "SRPF") {
				env = append(env, v)
			}
		}
		if len(env) == 0 {
			env = []string{"no-srpf-env"}
		}
		if _, err := fmt.Fprintln(out, line+" "+strings.Join(env, " ")); err != nil {
			return err
		}
	}
	return nil
}
