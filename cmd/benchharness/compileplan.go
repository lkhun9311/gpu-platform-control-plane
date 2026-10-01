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
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"math"
	"os"
	"strconv"
	"strings"

	"sigs.k8s.io/yaml"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// compilePlan reads a GpuSharingBenchmark CR and prints the run configuration it compiles to, or refuses.
//
// WHY THIS EXISTS. CompilePlan has been callable only from tests since it was written, which means the CRD
// declares a protocol nothing outside a test executes. This is the smallest command that makes "the CR
// supplied the configuration of this run" true rather than decorative: one file in, one shell-sourceable
// block out, and the paid runner consumes that block instead of a hand-typed environment.
//
// WHAT IT DOES NOT CLAIM. It is not a controller. Nothing reconciles, nothing writes status, and the CR is
// read from a file rather than from a cluster. The honest sentence it supports is "this CR supplied the
// load and protocol this run executed", and the block it prints carries the CR's own path and digest so a
// reader can check that sentence against the evidence.
func compilePlan(args []string) error {
	fs := flag.NewFlagSet("compile-plan", flag.ExitOnError)
	cr := fs.String("cr", "", "path to a GpuSharingBenchmark manifest")
	// Two things the CR cannot say, required rather than defaulted.
	//
	// The spec has no field for the trace's duration and no field for the study. Defaulting either would
	// make this command supply a value the CR does not contain while printing it beside values the CR does,
	// and a reader of the output could not tell which came from where. Requiring them keeps the boundary
	// where it is: everything this prints as CR-DERIVED came from the file, and everything else was passed.
	durationMs := fs.Int64("duration-ms", 0, "trace duration in ms; the CR has no field for it and nothing derives it")
	study := fs.String("study", "", "the study id the evidence is filed under; the CR has no field for it")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *cr == "" || *durationMs == 0 || *study == "" {
		return fmt.Errorf("--cr, --duration-ms and --study are all required; the last two are the values the CR cannot carry")
	}

	raw, err := os.ReadFile(*cr)
	if err != nil {
		return fmt.Errorf("read %s: %w", *cr, err)
	}
	var obj platformv1.GpuSharingBenchmark
	// Strict, so a field this binary does not know about is a refusal rather than a silent drop. A CR whose
	// unknown key changed the experiment would compile to a plan that describes a different run.
	if err := yaml.UnmarshalStrict(raw, &obj); err != nil {
		return fmt.Errorf("parse %s as a GpuSharingBenchmark: %w", *cr, err)
	}
	if obj.Kind != "" && obj.Kind != "GpuSharingBenchmark" {
		return fmt.Errorf("%s declares kind %q, not GpuSharingBenchmark", *cr, obj.Kind)
	}

	plan, err := bench.CompilePlan(obj.Spec)
	if err != nil {
		return err
	}

	// The weighted arrival model, in the units the runner takes.
	//
	// This study draws one stream of gaps at a total rate and assigns each arrival a tenant by weight, so
	// two per-tenant rates ARE a total rate and a weight: rate = qps_b + qps_c, and noisyWeight = qps_c/qps_b
	// with the premium weight at 1. The translation is exact for the registered tuple, which is the check
	// that matters: 9.166179 + 0.238321 = 9.404500 and 0.238321/9.166179 = 0.026000.
	//
	// Passing the two rates to gen-trace AS RATES would not be the same load. That selects the independent
	// arrival model, where each tenant has its own Poisson process, and the same seed then draws a different
	// schedule -- measured at this load, 4,751/133 offers against the weighted model's 4,655/139.
	base, err := strconv.ParseFloat(plan.PremiumRate, 64)
	if err != nil {
		return fmt.Errorf("baseline.qps %q is not a number: %w", plan.PremiumRate, err)
	}
	cont, err := strconv.ParseFloat(plan.ContenderRate, 64)
	if err != nil {
		return fmt.Errorf("contender.qps %q is not a number: %w", plan.ContenderRate, err)
	}
	if base <= 0 {
		return fmt.Errorf("baseline.qps is %g; a weighted arrival model divides by it", base)
	}
	total := base + cont
	noisyWeight := cont / base

	if bench.CanonicalStudyID(*study) != bench.StudySharingMatrix {
		return fmt.Errorf("study %q: this command compiles the sharing matrix, whose arrival model is weighted; another study may draw its trace differently", *study)
	}

	sum := sha256Hex(raw)
	fmt.Printf("# compiled from %s\n", *cr)
	fmt.Printf("# sha256 %s\n", sum)
	fmt.Printf("# CR-DERIVED: every value below came from that file\n")
	fmt.Printf("export ARMS=%q\n", joinArms(plan.Arms))
	fmt.Printf("export REPS=%d\n", plan.Repetitions)
	fmt.Printf("export RATE=%s\n", trimFloat(total))
	fmt.Printf("export PREMIUM_WEIGHT=1\n")
	fmt.Printf("export NOISY_WEIGHT=%s\n", trimFloat(noisyWeight))
	fmt.Printf("export PROBE_WEIGHT=0\n")
	fmt.Printf("export PREMIUM_PROMPT_CHARS=%d\n", plan.BaselinePromptChars)
	fmt.Printf("export NOISY_PROMPT_CHARS=%d\n", plan.ContenderPromptChars)
	fmt.Printf("export REQUEST_TIMEOUT_MS=%d\n", plan.TimeoutMs)
	fmt.Printf("export PREMIUM_OUTPUT_TOKENS=%d\n", plan.BaselineOutputTokens)
	fmt.Printf("export NOISY_OUTPUT_TOKENS=%d\n", plan.ContenderOutputTokens)
	fmt.Printf("export MODEL_REVISION=%s\n", plan.TokenizerRevision)
	fmt.Printf("# NOT CR-DERIVED: passed to this command, because the spec has no field for either\n")
	fmt.Printf("export DURATION_MS=%d\n", *durationMs)
	fmt.Printf("export STUDY=%s\n", *study)
	// The same value under a second name, because the two consumers reach it differently.
	//
	// The paid session reads $STUDY from this block and bakes it into the instance as STUDY_FROM_CR. The
	// matrix, running locally under a rehearsal, sets STUDY itself for the frozen matrix -- so a block that
	// exported only STUDY would leave STUDY_FROM_CR unset there, and the runner's check that the compiled
	// study matches the one the evidence is filed under would never execute on the path that can test it.
	fmt.Printf("export STUDY_FROM_CR=%s\n", *study)
	fmt.Printf("# The runner refuses to take these from the environment once BENCHMARK_CR_SHA256 is set.\n")
	fmt.Printf("export BENCHMARK_CR_SHA256=%s\n", sum)
	// The tokenizer revision, a second time and under its own name.
	//
	// MODEL_REVISION above is what the runner consumes, and the runner DEFAULTS it -- so an operator who
	// dropped that line from the block would not be missing a value, they would silently get the default,
	// and a guard looking for an empty variable would see nothing wrong. Measured: removing MODEL_REVISION
	// from the block left the run reporting only "load compiled from a GpuSharingBenchmark" and continuing.
	//
	// A defaulted variable cannot be checked for absence, so the runner checks it for AGREEMENT instead:
	// this line carries what the plan resolved, and the run is refused when the two differ. That also
	// catches what absence never would -- a revision overridden by hand to something the plan did not
	// resolve against, which is a run whose manifest would name the wrong tokenizer.
	fmt.Printf("export BENCHMARK_CR_TOKENIZER_REV=%s\n", plan.TokenizerRevision)
	return nil
}

// sha256Hex digests the CR's bytes as they were read.
//
// The digest is over the FILE and not over the parsed spec, so it changes when a comment changes. That is
// deliberate: the comments in this repository's manifests carry the reasons, and a run whose CR was edited
// is a run whose operator should be able to see that it was.
func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func joinArms(arms []string) string {
	return strings.Join(arms, " ")
}

// trimFloat prints a rate as the shortest decimal that is still the same load.
//
// WHY NOT JUST FormatFloat(v, 'g', -1, 64). That is the shortest string that round-trips to the same
// float64, which is not the same question. The contender weight comes out of a division, so the exact
// float is 0.026000000025965014 and the shortest round-tripping spelling is all eighteen digits of it --
// while the pre-registration, the design page and every existing run record spell it 0.026. A reader
// checking this block against those documents would find no match, and the load is identical: generating
// the trace at both values gives byte-identical output, 4,655 premium and 139 contender offers either way.
//
// So this walks up from one significant digit and takes the first spelling within a relative 1e-9 of the
// value. The tolerance is not a rounding convenience: 1e-9 of an arrival rate is nanoseconds of scheduling
// over a 505-second trace, far below the millisecond the generator quantises to. Anything a shorter
// spelling would actually change stays long.
func trimFloat(v float64) string {
	exact := strconv.FormatFloat(v, 'g', -1, 64)
	if v == 0 {
		return exact
	}
	for prec := 1; prec <= 17; prec++ {
		s := strconv.FormatFloat(v, 'g', prec, 64)
		got, err := strconv.ParseFloat(s, 64)
		if err != nil {
			continue
		}
		if math.Abs(got-v)/math.Abs(v) <= 1e-9 {
			return s
		}
	}
	return exact
}
