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

// Command benchharness drives the M5-b GPU-free benchmark harness: generate an immutable trace and its
// frozen manifest, replay a trace against the gateway recording raw per-request evidence, and turn raw
// evidence into a report with the design's pre-registered checks.
//
// A stub-serve subcommand runs a trivial streaming backend so the whole gen -> replay -> report path can
// be exercised end to end with no GPU and no cluster.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "gen-trace":
		err = genTrace(os.Args[2:])
	case "replay":
		err = replay(os.Args[2:])
	case "report":
		err = report(os.Args[2:])
	case "stub-serve":
		err = stubServe(os.Args[2:])
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: benchharness <gen-trace|replay|report|stub-serve> [flags]")
}

// genTrace generates an immutable trace file and a frozen manifest that pins its checksum.
func genTrace(args []string) error {
	fs := flag.NewFlagSet("gen-trace", flag.ExitOnError)
	seed := fs.Int64("seed", 1, "trace generator seed")
	durationMs := fs.Int64("duration-ms", 60_000, "trace duration in ms")
	// 20/s is calibrated for hack/m5b-harness-dryrun.sh, whose stub backend costs nothing to serve. It is
	// NOT a value a GPU can take: see hack/m5b-vllm-sizing.md, where sustaining half of it in contender
	// traffic works out to 7.3x a T4's theoretical peak. Set it from the ceiling derived there.
	rate := fs.Float64("rate", 20, "mean total arrival rate per second (stub-calibrated; see hack/m5b-vllm-sizing.md before a GPU run)")
	premiumChars := fs.Int("premium-prompt-chars", 200, "premium tenant prompt length in chars")
	// The old help here said ">= 4x the guard threshold" and that was wrong: ceil(40000/4) is 10,000 against
	// a 4,096 threshold, which is 2.44x. Corrected rather than restated, since the margin is the reason the
	// contender population is unambiguously eligible and a wrong multiple invites someone to shrink it.
	noisyChars := fs.Int("noisy-prompt-chars", 40_000, "noisy tenant prompt length in chars (estimates at 10,000 tokens, 2.44x the 4,096 guard threshold)")
	premiumWeight := fs.Float64("premium-weight", 1, "premium tenant arrival share")
	noisyWeight := fs.Float64("noisy-weight", 1, "noisy tenant arrival share")
	arm := fs.String("arm", "off", "arm this manifest measures (R1|off|static-cap|kv-aware)")
	gatewayURL := fs.String("gateway-url", "http://localhost:8080", "gateway URL the replay targets")
	model := fs.String("model", "llama-3-8b", "model name")
	timeoutMs := fs.Int("timeout-ms", 30_000, "per-request timeout in ms")
	matchTol := fs.String("match-tolerance", "0.05", "admission-work match tolerance")
	longThreshold := fs.Int("admission-long-threshold", 4096, "eligible-population token threshold the guard gates on")
	traceOut := fs.String("trace-out", "trace.jsonl", "trace file to write")
	manifestOut := fs.String("manifest-out", "manifest.yaml", "manifest file to write")
	if err := fs.Parse(args); err != nil {
		return err
	}

	tenants := []bench.TenantSpec{
		{Tenant: "premium-1", Weight: *premiumWeight, PromptLenChars: *premiumChars, MaxOutputTokens: 64, IsNoisy: false},
		{Tenant: "standard-noisy", Weight: *noisyWeight, PromptLenChars: *noisyChars, MaxOutputTokens: 16, IsNoisy: true},
	}

	rows, err := bench.GenerateTrace(bench.TraceParams{
		Seed: *seed, DurationMs: *durationMs, RatePerSec: *rate, Tenants: tenants,
	})
	if err != nil {
		return fmt.Errorf("generate trace: %w", err)
	}

	// R1 is the uncontended premium baseline.
	//
	// It is the SAME two-tenant trace with the contender filtered out, not a premium-only trace at the full rate.
	//
	// That way premium arrives on the identical schedule it has in the contended arms.
	//
	// So the 1.25x baseline is not inflated by running premium at double its share.
	if *arm == "R1" {
		premiumOnly := rows[:0]
		for _, r := range rows {
			if !r.IsNoisy {
				premiumOnly = append(premiumOnly, r)
			}
		}
		rows = premiumOnly
	}

	var traceBuf strings.Builder
	if err := bench.WriteTrace(&traceBuf, rows); err != nil {
		return fmt.Errorf("serialize trace: %w", err)
	}
	traceBytes := []byte(traceBuf.String())
	if err := os.WriteFile(*traceOut, traceBytes, 0o600); err != nil {
		return fmt.Errorf("write trace %s: %w", *traceOut, err)
	}

	m := bench.RunManifest{
		SchemaVersion:   "v2",
		PromptCorpusSHA: bench.PromptCorpusSHA256,
		Arm:             *arm,
		GatewayURL:      *gatewayURL,
		TracePath:       *traceOut,
		TraceChecksum:   bench.Checksum(traceBytes),
		Model:           *model,
		TimeoutMs:       *timeoutMs,
		Seed:            *seed,
		PrimaryEndpoint: "ttft_p99",
		MatchTolerance:  *matchTol,
		LongThreshold:   *longThreshold,
	}
	if err := writeManifest(*manifestOut, m); err != nil {
		return err
	}
	fmt.Printf("wrote %d trace rows to %s and manifest %s (arm=%s)\n", len(rows), *traceOut, *manifestOut, *arm)
	return nil
}

// replay loads a manifest, verifies its trace checksum, and replays the trace against the gateway.
func replay(args []string) error {
	fs := flag.NewFlagSet("replay", flag.ExitOnError)
	manifestPath := fs.String("manifest", "manifest.yaml", "manifest to replay")
	rawOut := fs.String("raw-out", "raw.jsonl", "raw evidence file to write")
	target := fs.String("target", "", "override the manifest gateway URL (e.g. a stub)")
	apiKeys := fs.String("api-keys", "", "comma-separated tenant=key pairs")
	// The pool mode is a flag rather than a constant so the cost of pooling at all stays measurable.
	//
	// "legacy" reproduces the client this sender replaced, which used http.DefaultTransport and its two idle
	// connections per host. It exists for a before/after comparison and for nothing else; a run that reports
	// latency should always use the derived pool. The name written here used to be "go-default", which the
	// flag has never accepted, so an operator copying it out of this rationale got "unknown sender mode".
	connMode := fs.String("conn-mode", bench.SenderModePooled,
		"client connection handling: \"pooled\" (pool sized from the run, plus the drain that lets it be "+
			"used), \"drain-only\", or \"legacy\" (the pre-fix client: http.DefaultTransport, no drain)")
	if err := fs.Parse(args); err != nil {
		return err
	}

	m, err := bench.LoadManifest(*manifestPath)
	if err != nil {
		return err
	}
	rows, err := readTraceFile(m.TracePath)
	if err != nil {
		return err
	}
	url := m.GatewayURL
	if *target != "" {
		url = *target
	}
	timeout := time.Duration(m.TimeoutMs) * time.Millisecond
	conn, err := bench.SenderConnForMode(*connMode, rows, timeout)
	if err != nil {
		return err
	}
	// Printed, not just applied: which client a run used is part of what its raw evidence means, and this
	// line is what puts it in the evidence log beside the numbers it produced.
	fmt.Printf("client connection mode: %s (MaxIdleConnsPerHost=%d, drain=%t) for %d rows at timeout %s\n",
		*connMode, conn.MaxIdleConnsPerHost, conn.DrainForReuse, len(rows), timeout)
	sender := bench.NewHTTPSender(url, m.Model, parseAPIKeys(*apiKeys), timeout, conn)

	// The frozen manifest's provenance is stamped into every raw row.
	//
	// That lets the report enforce trace identity and read the pre-registered knobs from the evidence.
	tol, err := strconv.ParseFloat(m.MatchTolerance, 64)
	if err != nil {
		return fmt.Errorf("manifest matchTolerance %q is not a number: %w", m.MatchTolerance, err)
	}
	raw := bench.Replay(context.Background(), sender, rows, bench.ReplayOptions{
		Arm:            m.Arm,
		TraceChecksum:  m.TraceChecksum,
		LongThreshold:  m.LongThreshold,
		MatchTolerance: tol,
	})

	f, err := os.Create(*rawOut)
	if err != nil {
		return fmt.Errorf("create raw file %s: %w", *rawOut, err)
	}
	defer func() { _ = f.Close() }()
	if err := bench.WriteRawRows(f, raw); err != nil {
		return err
	}
	fmt.Printf("replayed %d rows against %s (arm=%s) to %s\n", len(raw), url, m.Arm, *rawOut)
	return nil
}

// report turns one raw file per arm into the design's pre-registered report.
//
// Each --raw file is one arm's evidence; multiple files for the same arm are treated as repetitions for the bootstrap.
func report(args []string) error {
	fs := flag.NewFlagSet("report", flag.ExitOnError)
	var rawFiles multiFlag
	fs.Var(&rawFiles, "raw", "a raw evidence file (repeatable, one arm per file)")
	matchTolFlag := fs.Float64("match-tolerance", 0.05,
		"fallback admission-work match tolerance when the evidence carries none")
	out := fs.String("out", "", "report file to write (default stdout)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if len(rawFiles) == 0 {
		return fmt.Errorf("at least one --raw file is required")
	}

	// Group rows and per-file p99 repetitions by arm, and capture each arm's frozen provenance.
	byArm := map[string][]bench.RawRow{}
	repP99 := map[string][]float64{}
	armChecksum := map[string]string{}
	armTolerance := map[string]float64{}
	for _, path := range rawFiles {
		f, err := os.Open(path)
		if err != nil {
			return fmt.Errorf("open %s: %w", path, err)
		}
		rows, err := bench.ReadRawRows(f)
		_ = f.Close()
		if err != nil {
			return err
		}
		if len(rows) == 0 {
			continue
		}
		arm := rows[0].Arm
		byArm[arm] = append(byArm[arm], rows...)
		repP99[arm] = append(repP99[arm], bench.Summarize(arm, rows).TTFTMsP99)
		armChecksum[arm] = rows[0].TraceChecksum
		armTolerance[arm] = rows[0].MatchTolerance
	}

	// The contended arms must have replayed identical traffic, so their trace checksums must match.
	//
	// R1 legitimately differs (it is the same trace with the contender filtered out).
	//
	// So it is excluded from the identity check.
	var wantSum string
	for _, arm := range []string{"off", "static-cap", "kv-aware"} {
		sum, ok := armChecksum[arm]
		if !ok {
			continue
		}
		if sum == "" {
			return fmt.Errorf("arm %s carries no trace checksum; regenerate its manifest with a current gen-trace", arm)
		}
		if wantSum == "" {
			wantSum = sum
		} else if sum != wantSum {
			return fmt.Errorf("arm %s replayed a different trace (%s) than the other contended arms (%s);"+
				" a valid comparison needs one immutable trace", arm, sum, wantSum)
		}
	}

	// The admission-match tolerance is the frozen one from the evidence, not a CLI default.
	//
	// So it cannot be loosened after the fact.
	matchTolerance := *matchTolFlag
	if tol, ok := armTolerance["kv-aware"]; ok && tol > 0 {
		matchTolerance = tol
	} else if tol, ok := armTolerance["static-cap"]; ok && tol > 0 {
		matchTolerance = tol
	}

	order := []string{"R1", "off", "static-cap", "kv-aware"}
	var summaries []bench.ArmSummary
	summ := map[string]bench.ArmSummary{}
	for _, arm := range order {
		if rows, ok := byArm[arm]; ok {
			s := bench.Summarize(arm, rows)
			summaries = append(summaries, s)
			summ[arm] = s
		}
	}

	// The incremental C/B CI resamples per-repetition ratios when both arms have matching repetitions.
	//
	// With a single repetition per arm it degenerates to the point estimate.
	incCI := bench.CI{}
	b, c := repP99["static-cap"], repP99["kv-aware"]
	if len(b) == len(c) && len(b) > 0 {
		ratios := make([]float64, len(b))
		for i := range b {
			if b[i] > 0 {
				ratios[i] = c[i] / b[i]
			}
		}
		incCI = bench.BootstrapCI(ratios, 2000, 1, 0.05)
	} else if len(b) > 0 && len(c) > 0 {
		// Unequal repetition counts leave the incremental CI at the degenerate point estimate.
		//
		// That would make the CI-upper-bound gate trivially true.
		fmt.Fprintf(os.Stderr, "warning: static-cap has %d repetitions but kv-aware has %d;"+
			" the incremental C/B interval is a point estimate, not a real CI\n", len(b), len(c))
	}

	checks := bench.EvaluateChecks(summ["R1"], summ["static-cap"], summ["kv-aware"], incCI, matchTolerance)
	text := bench.FormatReport(summaries, checks, matchTolerance)

	if *out == "" {
		fmt.Print(text)
		return nil
	}
	if err := os.WriteFile(*out, []byte(text), 0o600); err != nil {
		return fmt.Errorf("write report %s: %w", *out, err)
	}
	fmt.Printf("wrote report to %s\n", *out)
	return nil
}
