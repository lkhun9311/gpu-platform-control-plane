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
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"hash/fnv"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// traceRefFor returns the trace path as a manifest should record it: relative to the manifest's own
// directory when both live under it, and unchanged otherwise.
//
// LoadManifest resolves relative paths against the manifest's directory, so a working-directory-relative
// path recorded verbatim is joined twice and cannot be found.
func traceRefFor(manifestOut, traceOut string) string {
	if manifestOut == "" || filepath.IsAbs(traceOut) {
		return traceOut
	}
	rel, err := filepath.Rel(filepath.Dir(manifestOut), traceOut)
	if err != nil || strings.HasPrefix(rel, "..") {
		// Outside the manifest's directory: an absolute path is the only unambiguous answer.
		abs, absErr := filepath.Abs(traceOut)
		if absErr != nil {
			return traceOut
		}
		return abs
	}
	return rel
}

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
	case "print-prompt":
		printPrompt(os.Args[2:])
	case "power":
		err = power(os.Args[2:])
	case "stamp-exact-tokens":
		err = stampExactTokens(os.Args[2:])
	case "verify-exact-tokens":
		err = verifyExactTokens(os.Args[2:])
	case "prepare-traces":
		err = prepareTraces(os.Args[2:])
	case "check-replay":
		err = checkReplay(os.Args[2:])
	case "ladder-verdict":
		err = ladderVerdict(os.Args[2:])
	case "ladder-plan-check":
		err = ladderPlanCheck(os.Args[2:])
	case "matrix-plan-check":
		err = matrixPlanCheck(os.Args[2:])
	case "study-arrivals":
		err = studyArrivals(os.Args[2:])
	case "study-frozen-tuple":
		err = studyFrozenTuple(os.Args[2:])
	case "study-traces":
		err = studyTraces(os.Args[2:])
	case "compile-plan":
		err = compilePlan(os.Args[2:])
	case "sim-cap":
		err = simCap(os.Args[2:])
	case "fit-pilot-rate":
		err = fitPilotRate(os.Args[2:], os.Stdout)
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
	fmt.Fprintln(os.Stderr, "usage: benchharness <gen-trace|prepare-traces|replay|report|ladder-verdict|ladder-plan-check|matrix-plan-check|study-arrivals|study-frozen-tuple|print-prompt|check-replay|stamp-exact-tokens|verify-exact-tokens|compile-plan|sim-cap|power|stub-serve> [flags]")
}

// arrivalFlags are gen-trace's load flags, gathered so the choice between the two arrival models lives in one place.
type arrivalFlags struct {
	rate, premiumWeight, noisyWeight, probeWeight             float64
	premiumRate, noisyRate, probeRate                         float64
	premiumChars, noisyChars, probeUnderChars, probeOverChars int
	premiumOutputTokens, noisyOutputTokens                    int
	// passed names the flags the caller set, since an explicit value can equal its default.
	passed map[string]bool
}

// traceTenants builds the tenants and the total rate GenerateTrace is given, under whichever arrival model the flags select.
//
// Passing any per-tenant rate selects the independent-arrivals model. --rate and every weight are then refused
// rather than ignored, because a caller who passed both has two loads on the page and obeying one silently is
// how a trace ends up with an arrival process nobody stated.
//
// All three rates are required once one is passed. Defaulting --probe-rate to zero would silently drop the
// probes that make the guard threshold load-bearing, and defaulting it to anything else would offer a load
// nobody derived.
func traceTenants(f arrivalFlags) ([]bench.TenantSpec, float64, error) {
	rated := f.passed["premium-rate"] || f.passed["noisy-rate"] || f.passed["probe-rate"]
	if rated {
		for _, name := range []string{"rate", "premium-weight", "noisy-weight", "probe-weight"} {
			if f.passed[name] {
				return nil, 0, fmt.Errorf("--%s was passed alongside per-tenant rates; a trace uses one arrival model, so pass the rates or the total rate and weights", name)
			}
		}
		for _, name := range []string{"premium-rate", "noisy-rate", "probe-rate"} {
			if !f.passed[name] {
				return nil, 0, fmt.Errorf("--%s is required once any per-tenant rate is passed (--probe-rate 0 disables the probes)", name)
			}
		}
		if f.probeRate < 0 {
			return nil, 0, fmt.Errorf("--probe-rate must be zero or positive, got %g", f.probeRate)
		}
	}

	premium := bench.TenantSpec{Tenant: bench.PremiumTenant, PromptLenChars: f.premiumChars, MaxOutputTokens: f.premiumOutputTokens, IsNoisy: false}
	noisy := bench.TenantSpec{Tenant: bench.NoisyTenant, PromptLenChars: f.noisyChars, MaxOutputTokens: f.noisyOutputTokens, IsNoisy: true}
	under := bench.TenantSpec{Tenant: bench.ProbeUnderTenant, PromptLenChars: f.probeUnderChars, MaxOutputTokens: 8, IsNoisy: true}
	over := bench.TenantSpec{Tenant: bench.ProbeOverTenant, PromptLenChars: f.probeOverChars, MaxOutputTokens: 8, IsNoisy: true}

	if rated {
		premium.RatePerSec, noisy.RatePerSec = f.premiumRate, f.noisyRate
		under.RatePerSec, over.RatePerSec = f.probeRate, f.probeRate
		tenants := []bench.TenantSpec{premium, noisy}
		if f.probeRate > 0 {
			tenants = append(tenants, under, over)
		}
		return tenants, 0, nil
	}

	premium.Weight, noisy.Weight = f.premiumWeight, f.noisyWeight
	under.Weight, over.Weight = f.probeWeight, f.probeWeight
	tenants := []bench.TenantSpec{premium, noisy}
	if f.probeWeight > 0 {
		tenants = append(tenants, under, over)
	}
	return tenants, f.rate, nil
}

// arrivalsOf returns the arrival model a study registered, refusing a study that registered none.
func arrivalsOf(study string) (bench.ArrivalModel, error) {
	st, ok := bench.LookupStudy(study)
	if !ok {
		return "", fmt.Errorf("study %q is not registered; known: %s", study, strings.Join(bench.KnownStudyIDs(), ", "))
	}
	if st.Arrivals == "" {
		return "", fmt.Errorf("study %s registered no arrival model", st.ID)
	}
	return st.Arrivals, nil
}

// studyArrivals prints a study's arrival model, so a script chooses gen-trace's flags from the registry rather than from a copy of it.
func studyArrivals(args []string) error {
	fs := flag.NewFlagSet("study-arrivals", flag.ExitOnError)
	study := fs.String("study", "", "registered study id")
	if err := fs.Parse(args); err != nil {
		return err
	}
	model, err := arrivalsOf(*study)
	if err != nil {
		return err
	}
	fmt.Println(model)
	return nil
}

// studyTraces prints whether a study replays one trace in every repetition or one per repetition.
//
// The runner chooses each repetition's seed from it, so a run of a per-repetition study cannot reach a card
// with the one seed every archive before 2026-10-04 used -- the report would refuse that run's evidence, but
// only after the cells were paid for.
func studyTraces(args []string) error {
	fs := flag.NewFlagSet("study-traces", flag.ExitOnError)
	study := fs.String("study", "", "registered study id")
	if err := fs.Parse(args); err != nil {
		return err
	}
	st, ok := bench.LookupStudy(*study)
	if !ok {
		return fmt.Errorf("study %q is not registered; known: %s", *study, strings.Join(bench.KnownStudyIDs(), ", "))
	}
	if st.TracesVaryByRepetition {
		fmt.Println("per-repetition")
	} else {
		fmt.Println("one")
	}
	return nil
}

// studyFrozenTuple prints the five load quantities a study's pre-registration froze, as shell assignments.
//
// It exists so hack/m5c-matrix.sh compares the load it is about to offer against the registration instead of
// holding a second copy of those numbers. Measured on 2026-10-02: every one of the four frozen quantities
// could be overridden on the command line and the pre-purchase plan check passed unchanged, and the 15-cell
// run of 2026-10-02 met the frozen premium length only because it inherited the script's default.
//
// A study that froze nothing is a REFUSAL rather than empty output. Printing nothing would let a caller that
// forgot to check the exit status read "no constraints" out of silence, which is the failure this whole
// command exists to stop one layer up.
//
// Drift is reported and not repaired: if the resolution table no longer resolves the frozen token counts to
// the frozen characters, the registration and the table disagree and a human has to date an amendment.
func studyFrozenTuple(args []string) error {
	fs := flag.NewFlagSet("study-frozen-tuple", flag.ExitOnError)
	study := fs.String("study", "", "registered study id")
	if err := fs.Parse(args); err != nil {
		return err
	}
	st, ok := bench.LookupStudy(*study)
	if !ok {
		return fmt.Errorf("study %q is not registered; known: %s", *study, strings.Join(bench.KnownStudyIDs(), ", "))
	}
	if st.Frozen == nil {
		return fmt.Errorf("study %s froze no load tuple, so there is nothing to compare a run's load against", st.ID)
	}
	if d := st.Frozen.Drift(); d != "" {
		return fmt.Errorf("study %s's frozen tuple no longer agrees with the measured resolution table -- %s. The registration froze characters; the table has moved. Date an amendment rather than letting the frozen value follow the table", st.ID, d)
	}
	f := *st.Frozen
	fmt.Printf("FROZEN_PREMIUM_PROMPT_CHARS=%d\n", f.PremiumPromptChars)
	fmt.Printf("FROZEN_NOISY_PROMPT_CHARS=%d\n", f.ContenderPromptChars)
	fmt.Printf("FROZEN_REQUEST_TIMEOUT_MS=%d\n", f.TimeoutMs)
	fmt.Printf("FROZEN_PREMIUM_OUTPUT_TOKENS=%d\n", f.PremiumOutputTokens)
	fmt.Printf("FROZEN_NOISY_OUTPUT_TOKENS=%d\n", f.ContenderOutputTokens)
	return nil
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
	// The output caps, which were literals in traceTenants until 2026-10-01.
	//
	// They default to what every pre-CR trace in the evidence was generated with, so an un-flagged call
	// produces the same trace it always did. A compiled plan passes the CR's values instead.
	premiumOut := fs.Int("premium-output-tokens", bench.FixedPremiumMaxOutputTokens, "premium tenant max_tokens cap")
	noisyOut := fs.Int("noisy-output-tokens", bench.FixedNoisyMaxOutputTokens, "noisy tenant max_tokens cap")
	premiumWeight := fs.Float64("premium-weight", 1, "premium tenant arrival share")
	noisyWeight := fs.Float64("noisy-weight", 1, "noisy tenant arrival share")
	// Meant to be small, and 0.1 is NOT small the way this comment used to claim.
	//
	// These are a probe population rather than a load driver, and each carries about 3,171 real tokens. The
	// comment here said a large share would move the pressure the arms are supposed to differ under, and
	// then left a default that does exactly that: measured on the 2026-09-07 price-of-protection pilot, the
	// two probe tenants at 0.1 each carried 78% of the engine's prefill capacity between them, against the
	// protected tenant's 5%. A weight is a share of the total arrival rate, so what it costs the engine
	// depends on the prompt behind it, and 0.1 of a 3,171-token prompt is not 0.1 of the load.
	//
	// Left at 0.1 because lowering it silently would change every existing caller's trace. Set it from the
	// engine's measured prefill capacity, as
	// docs/superpowers/specs/2026-09-08-the-load-needs-an-upper-gate.md derives.
	probeWeight := fs.Float64("probe-weight", 0.1, "arrival share of EACH threshold-probe tenant; 0 disables them (see the comment: 0.1 is not a small load)")
	probeUnderChars := fs.Int("probe-under-chars", bench.ProbeUnderChars, "probe prompt scoring just BELOW the guard threshold")
	probeOverChars := fs.Int("probe-over-chars", bench.ProbeOverChars, "probe prompt scoring exactly AT the guard threshold")
	// Per-tenant rates select the independent-arrivals model, where a tenant's schedule depends on its own rate alone.
	//
	// Under the weights above, raising the premium share redraws every gap, so the M5-c ladder held the
	// contender's COUNT fixed and still handed each rung a different contender schedule. See
	// bench.TenantSpec.RatePerSec, and traceTenants for why these refuse to be mixed with the weights.
	premiumRate := fs.Float64("premium-rate", 0, "premium tenant's own arrival rate per second; passing any rate replaces --rate and the weights")
	noisyRate := fs.Float64("noisy-rate", 0, "noisy tenant's own arrival rate per second")
	probeRate := fs.Float64("probe-rate", 0, "arrival rate per second of EACH threshold-probe tenant; required with the other rates, 0 disables them")
	// Defaulted rather than required, because every existing caller is the M5-b gateway experiment and
	// making them all pass a flag to keep working would be a migration with no reader.
	study := fs.String("study", bench.StudyM5BGateway,
		"pre-registered experiment this manifest belongs to; its registry decides which arms are admissible")
	arm := fs.String("arm", "off", "arm this manifest measures, one of the named study's arms")
	gatewayURL := fs.String("gateway-url", "http://localhost:8080", "gateway URL the replay targets")
	model := fs.String("model", "llama-3-8b", "model name")
	timeoutMs := fs.Int("timeout-ms", 30_000, "per-request timeout in ms")
	matchTol := fs.String("match-tolerance", "0.05", "admission-work match tolerance")
	longThreshold := fs.Int("admission-long-threshold", 4096, "eligible-population token threshold the guard gates on")
	// Provenance the record has to carry, because nothing else can reconstruct it later.
	//
	// RunManifest has declared gatewaySHA and imageDigests since it was written and nothing ever filled them:
	// no flag accepted them, no script passed them, and every manifest this repository has produced left them
	// empty. A paid run's numbers belong to a build, and after the cluster is gone the record is the only
	// place that association can live.
	//
	// The image flags take `name@sha256:...` references. replay -require-provenance refuses a tag, because a
	// tag names whatever was pushed under it most recently.
	gatewaySHA := fs.String("gateway-sha", "", "commit SHA of the gateway build under test")
	// The tokenizer revision, which was the third field declared for provenance and never filled.
	//
	// RunManifest.TokenizerRev has said it records the tokenizer and chat-template revision since it was
	// written, and nothing set it: no flag, no script, no manifest. The repair that added --gateway-sha and
	// the image flags did not include it, so it stayed the one provenance field with no way in.
	//
	// It matters more than it looks. The design scores admitted work over the SERVED tokenizer count, and the
	// calibration that relates characters to tokens was measured against one specific tokenizer. Without the
	// revision, a number cannot be tied to the tokenizer that produced it -- and the calibration file claimed
	// to have been measured "at the recorded revision" while no revision was recorded anywhere.
	tokenizerRev := fs.String("tokenizer-rev", "",
		"revision of the served model whose tokenizer the estimate was calibrated against (40 lowercase hex)")
	gatewayImage := fs.String("gateway-image", "", "digest-pinned gateway image reference (name@sha256:...)")
	engineImage := fs.String("engine-image", "", "digest-pinned inference engine image reference (name@sha256:...)")
	// The gateway by content, because its image ID changes with every build of the same binary
	// (docs/superpowers/specs/2026-10-07-gateway-identity-for-reproduction.md).
	gatewayBinary := fs.String("gateway-binary-sha256", "", "sha256 of the gateway binary in the image (64 lowercase hex); with --gateway-base or not at all")
	gatewayBase := fs.String("gateway-base", "", "digest-pinned base image the gateway image was built on (name@sha256:...); with --gateway-binary-sha256 or not at all")
	traceOut := fs.String("trace-out", "trace.jsonl", "trace file to write")
	manifestOut := fs.String("manifest-out", "manifest.yaml", "manifest file to write")
	// The warm-up is a separate trace rather than rows prepended to the measured one, so the measured trace's bytes and its plan check are the same with or without it.
	warmup := fs.Bool("warmup", false, "write the registered warm-up trace for the arm's episode type instead of the measured trace (episode studies that register a warm-up only)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if err := bench.GatewayIdentityRefusal(*gatewayBinary, *gatewayBase); err != nil {
		return err
	}
	out := traceOutputs{
		seed: *seed, study: *study, arm: *arm, gatewayURL: *gatewayURL, model: *model, timeoutMs: *timeoutMs,
		matchTol: *matchTol, longThreshold: *longThreshold, gatewaySHA: *gatewaySHA, tokenizerRev: *tokenizerRev,
		gatewayImage: *gatewayImage, engineImage: *engineImage, traceOut: *traceOut, manifestOut: *manifestOut,
		gatewayBinary: *gatewayBinary, gatewayBase: *gatewayBase,
	}

	// An episode study's rows come from its registered settings, so none of the Poisson flags below has anything to configure.
	if st, ok := bench.LookupStudy(*study); ok && st.Arrivals == bench.ArrivalsEpisodes {
		explicit := map[string]bool{}
		fs.Visit(func(f *flag.Flag) { explicit[f.Name] = true })
		rows, err := episodeRows(st, *arm, *seed, *durationMs, *warmup, explicit)
		if err != nil {
			return err
		}
		// The caps and lengths vary by episode, so the manifest leaves both per-tenant maps out rather than recording one value of several.
		return writeTraceAndManifest(rows, out, nil)
	}
	// A Poisson study has no warm-up registered, and ignoring the flag would hand back a measured trace to a caller who asked for something else.
	if *warmup {
		return fmt.Errorf("--warmup is defined only for an episode study that registers a warm-up, and study %s does not", *study)
	}

	// Two probe tenants that straddle the guard's eligibility threshold, four characters apart.
	//
	// Without them the trace does not test the threshold at all: the contender estimates at 10,000 tokens and
	// premium at 50, so ANY threshold between 51 and 10,000 produces identical behaviour in every arm, and the
	// number the guard is configured with is decorative. These two make it load-bearing. The gateway scores
	// (chars+3)/4, so 16,380 characters score 4,095 and pass while 16,384 score 4,096 and are rejected -- one
	// real token apart, opposite decisions.
	//
	// They also walk into the false-positive band the calibration measured: both prompts carry about 3,171
	// real tokens against a threshold of 4,096, so the rejected one is rejected on an over-estimate of 29
	// percent. That band was measurable before and unreachable; now the run reports how often it fires.
	//
	// IsNoisy is true for both, and it is not a claim that they are contenders. The field's operational
	// meaning is "not the victim whose tail is the primary endpoint" -- it gates exactly two things, the
	// tail's population and R1's filter, and a probe tenant belongs in neither. Marking them false would put
	// borderline traffic inside the p99 the whole experiment is judged on.
	passed := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { passed[f.Name] = true })
	tenants, totalRate, err := traceTenants(arrivalFlags{
		rate: *rate, premiumWeight: *premiumWeight, noisyWeight: *noisyWeight, probeWeight: *probeWeight,
		premiumRate: *premiumRate, noisyRate: *noisyRate, probeRate: *probeRate,
		premiumChars: *premiumChars, noisyChars: *noisyChars, probeUnderChars: *probeUnderChars, probeOverChars: *probeOverChars,
		premiumOutputTokens: *premiumOut, noisyOutputTokens: *noisyOut,
		passed: passed,
	})
	if err != nil {
		return err
	}
	// A study that registered its arrival model is generated under that model only.
	//
	// Nothing in a trace file records which model produced it, so a ladder generated with the other model's
	// flags would carry the right arm names and the right contender count under a different arrival process,
	// and every check downstream would pass it.
	if st, ok := bench.LookupStudy(*study); ok && st.Arrivals != "" {
		used := bench.ArrivalsWeighted
		if passed["premium-rate"] || passed["noisy-rate"] || passed["probe-rate"] {
			used = bench.ArrivalsIndependent
		}
		if used != st.Arrivals {
			return fmt.Errorf("study %s registered %s arrivals and these flags describe %s arrivals; its traces have to be generated the way its pre-registration says", st.ID, st.Arrivals, used)
		}
	}

	rows, err := bench.GenerateTrace(bench.TraceParams{
		Seed: *seed, DurationMs: *durationMs, RatePerSec: totalRate, Tenants: tenants,
	})
	if err != nil {
		return fmt.Errorf("generate trace: %w", err)
	}
	if st, ok := bench.LookupStudy(*study); ok && st.FixesOutputAtCap {
		if err := bench.FixOutputAtCap(rows); err != nil {
			return fmt.Errorf("study %s fixes output at its cap: %w", st.ID, err)
		}
	}
	if st, ok := bench.LookupStudy(*study); ok && st.FrozenExactTokens != nil {
		if err := bench.StampFrozenExactTokens(rows, st.FrozenExactTokens); err != nil {
			return fmt.Errorf("study %s froze its exact token counts: %w", st.ID, err)
		}
	}

	// R1 is the uncontended premium baseline.
	//
	// It is the SAME two-tenant trace with the contender filtered out, not a premium-only trace at the full rate.
	//
	// That way premium arrives on the identical schedule it has in the contended arms.
	//
	// So the 1.25x baseline is not inflated by running premium at double its share.
	if bench.IsIsolatedBaseline(*arm) {
		premiumOnly := rows[:0]
		for _, r := range rows {
			if !r.IsNoisy {
				premiumOnly = append(premiumOnly, r)
			}
		}
		rows = premiumOnly
	}
	return writeTraceAndManifest(rows, out, map[string]int{bench.PremiumTenant: *premiumOut, bench.NoisyTenant: *noisyOut})
}

// poissonOnlyFlags are the gen-trace flags that shape a Poisson trace and mean nothing to an episode trace.
var poissonOnlyFlags = []string{
	"rate", "premium-prompt-chars", "noisy-prompt-chars", "premium-output-tokens", "noisy-output-tokens",
	"premium-weight", "noisy-weight", "probe-weight", "probe-under-chars", "probe-over-chars",
	"premium-rate", "noisy-rate", "probe-rate",
}

// episodeRows builds an episode study's trace from the arm's episode type and the seed alone.
//
// The Poisson flags are refused rather than ignored, because a caller who passed a rate believes it shaped the trace.
// --duration-ms must be passed, because its default is a Poisson window that no three-cycle trace fits and a refusal naming that default would send the reader looking for the wrong mistake.
func episodeRows(st bench.Study, arm string, seed, durationMs int64, warmup bool, passed map[string]bool) ([]bench.TraceRow, error) {
	for _, name := range poissonOnlyFlags {
		if passed[name] {
			return nil, fmt.Errorf("study %s registered %s arrivals and --%s configures a Poisson trace; its lengths, caps and spacing are the registration's", st.ID, st.Arrivals, name)
		}
	}
	if !passed["duration-ms"] {
		return nil, fmt.Errorf("study %s needs --duration-ms: the trace is a fixed number of complete cycles, and the default is a Poisson window", st.ID)
	}
	episode, ok := bench.InstrumentValidationEpisode(arm)
	if !ok || !st.Admits(arm) {
		return nil, fmt.Errorf("arm %q is not one of study %s's arms (%s)", arm, st.ID, strings.Join(st.Arms, ", "))
	}
	params := bench.EpisodeTraceParams{Study: st.ID, Seed: seed, DurationMs: durationMs, Type: episode}
	if warmup {
		rows, err := bench.GenerateEpisodeWarmupTrace(params)
		if err != nil {
			return nil, fmt.Errorf("generate the %s warm-up: %w", episode, err)
		}
		return rows, nil
	}
	rows, err := bench.GenerateEpisodeTrace(params)
	if err != nil {
		return nil, fmt.Errorf("generate %s episodes: %w", episode, err)
	}
	return rows, nil
}

// traceOutputs are the gen-trace flags that only reach the written files, shared by both arrival paths.
type traceOutputs struct {
	seed                                             int64
	study, arm, gatewayURL, model                    string
	timeoutMs, longThreshold                         int
	matchTol, gatewaySHA, tokenizerRev               string
	gatewayImage, engineImage, traceOut, manifestOut string
	gatewayBinary, gatewayBase                       string
}

// writeTraceAndManifest writes the trace and a manifest pinning its checksum.
//
// maxOutputTokens is nil for a trace whose caps vary by row, and so is the per-tenant prompt length, since either map would record one of several values as if it were the only one.
func writeTraceAndManifest(rows []bench.TraceRow, o traceOutputs, maxOutputTokens map[string]int) error {
	var traceBuf strings.Builder
	if err := bench.WriteTrace(&traceBuf, rows); err != nil {
		return fmt.Errorf("serialize trace: %w", err)
	}
	traceBytes := []byte(traceBuf.String())
	if err := os.WriteFile(o.traceOut, traceBytes, 0o600); err != nil {
		return fmt.Errorf("write trace %s: %w", o.traceOut, err)
	}
	var promptLenChars map[string]int
	if maxOutputTokens != nil {
		promptLenChars = bench.PromptLenCharsByTenant(rows)
	}

	m := bench.RunManifest{
		SchemaVersion:   "v2",
		PromptCorpusSHA: bench.PromptCorpusSHA256,
		Study:           o.study,
		Arm:             o.arm,
		GatewayURL:      o.gatewayURL,
		// Relative to the MANIFEST, not to the working directory.
		//
		// LoadManifest resolves a relative TracePath against the manifest's own directory, which is what
		// makes a run directory portable. gen-trace wrote the flag through verbatim, so
		// `--trace-out hack/run-x/trace.jsonl --manifest-out hack/run-x/manifest.yaml` recorded a
		// working-directory path that the loader then joined onto hack/run-x again:
		//
		//   read trace file hack/run-x/hack/run-x/trace-R1-1.jsonl: no such file or directory
		//
		// The paid run failed on its first replay because of it. Storing the path the loader expects keeps
		// the manifest movable, which is the point of recording a checksum beside it.
		TracePath:     traceRefFor(o.manifestOut, o.traceOut),
		TraceChecksum: bench.Checksum(traceBytes),
		Model:         o.model,
		TimeoutMs:     o.timeoutMs,
		// What that number bounds, from the constant rather than a literal: the sender's deadline covers
		// the whole request including the stream, so a reader cannot take timeoutMs for a first-token budget.
		TimeoutScope:    bench.TimeoutScopeWholeRequest,
		Seed:            o.seed,
		PrimaryEndpoint: "ttft_p99",
		MatchTolerance:  o.matchTol,
		LongThreshold:   o.longThreshold,
		GatewaySHA:      o.gatewaySHA,
		TokenizerRev:    o.tokenizerRev,

		GatewayBinarySHA256: o.gatewayBinary,
		GatewayBase:         o.gatewayBase,
		PromptLenChars:      promptLenChars,
		MaxOutputTokens:     maxOutputTokens,
	}
	// Only set the map when something was supplied, so a free run's manifest carries no empty scaffolding
	// that could later be mistaken for a recorded value.
	for role, ref := range map[string]string{"gateway": o.gatewayImage, "engine": o.engineImage} {
		if ref == "" {
			continue
		}
		if m.ImageDigests == nil {
			m.ImageDigests = map[string]string{}
		}
		m.ImageDigests[role] = ref
	}
	if err := writeManifest(o.manifestOut, m); err != nil {
		return err
	}
	fmt.Printf("wrote %d trace rows to %s and manifest %s (arm=%s)\n", len(rows), o.traceOut, o.manifestOut, o.arm)
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
	// The paid path's counterpart to -require-device.
	//
	// Opt-in rather than always-on: a kind run against a stub has no build worth pinning, and demanding one
	// from every free run would push an operator toward inventing a value. Where the record has to outlive
	// the cluster, it is required.
	requireExactTokens := fs.Bool("require-exact-tokens", false,
		"refuse a trace whose rows carry no measured input-token count, before sending any request")
	requireProvenance := fs.Bool("require-provenance", false,
		"refuse a manifest that does not name the gateway build and digest-pin every image the number depends on")
	// The axis the paid evidence showed actually works, exposed so an arm can carry it.
	//
	// vLLM's priority scheduler reads a per-request field, and the microtest measured it moving the premium
	// tail where every backend-telemetry signal the gateway could see did not. Without this flag the runner
	// can only test admission, which is the axis that failed.
	priorities := fs.String("priorities", "",
		"comma-separated tenant=priority pairs sent with each request (lower is more urgent); "+
			"requires the engine to run with --scheduling-policy=priority")
	requestIDPrefix := fs.String("request-id-prefix", "",
		"send each request with X-Request-Id <prefix>-<trace index> and record it in the raw rows; the prefix must be "+
			"unique per cell and phase. Empty sends no id, as every earlier run did")
	connMode := fs.String("conn-mode", bench.SenderModePooled,
		"client connection handling: \"pooled\" (pool sized from the run, plus the drain that lets it be "+
			"used), \"drain-only\", or \"legacy\" (the pre-fix client: http.DefaultTransport, no drain)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	// Parsed before anything is loaded or dialled, so a typo in the treatment costs nothing.
	prio, err := parsePriorities(*priorities)
	if err != nil {
		return err
	}

	m, err := bench.LoadManifest(*manifestPath)
	if err != nil {
		return err
	}
	if *requireProvenance {
		if perr := m.RequireProvenance(); perr != nil {
			return fmt.Errorf("manifest %s: %w", *manifestPath, perr)
		}
	}
	rows, err := readTraceFile(m.TracePath)
	if err == nil && *requireExactTokens {
		// Refused BEFORE the first request, not after the run.
		//
		// A trace can be freshly checksummed and still carry no measured input-token counts -- that is exactly
		// what the old workflow produced, because the replay loop regenerated the trace after the stamping
		// step. The manifest is then internally consistent and the evidence it yields cannot be scored against
		// the admission-match criterion, which is defined over the served tokenizer's own count. Discovering
		// that in the report costs a paid run; discovering it here costs nothing.
		unstamped := 0
		for _, r := range rows {
			if r.ExactInputTokens <= 0 {
				unstamped++
			}
		}
		if unstamped > 0 {
			return fmt.Errorf("%d of %d rows in %s carry no measured input-token count and -require-exact-tokens was set, so nothing was sent: prepare the traces with prepare-traces (which stamps before it checksums) rather than replaying a trace whose evidence cannot be scored against the admission-match criterion",
				unstamped, len(rows), m.TracePath)
		}
	}
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
	study, studyKnown := bench.LookupStudy(m.Study)
	if studyKnown && study.SenderPoolSize > 0 {
		if *connMode != bench.SenderModePooled {
			return fmt.Errorf("study %s fixes a pooled sender of %d connections, and --conn-mode is %q", study.ID, study.SenderPoolSize, *connMode)
		}
		conn.MaxIdleConnsPerHost = study.SenderPoolSize
	}
	// Printed, not just applied: which client a run used is part of what its raw evidence means, and this
	// line is what puts it in the evidence log beside the numbers it produced.
	fmt.Printf("client connection mode: %s (MaxIdleConnsPerHost=%d, drain=%t) for %d rows at timeout %s\n",
		*connMode, conn.MaxIdleConnsPerHost, conn.DrainForReuse, len(rows), timeout)
	sender := bench.NewHTTPSender(url, m.Model, parseAPIKeys(*apiKeys), timeout, conn)
	// Printed for the same reason the connection mode is: which arm this replay actually was is part of what
	// its rows mean, and a priority map that silently arrived empty must be visible in the run log.
	if len(prio) > 0 {
		sender.SetPriorities(prio)
		fmt.Printf("request priorities: %v\n", prio)
	} else {
		fmt.Printf("request priorities: none (requests carry no priority field)\n")
	}
	// Printed only when set, so the output of every run that sets nothing stays what it was.
	if *requestIDPrefix != "" {
		sender.SetRequestIDPrefix(*requestIDPrefix)
		fmt.Printf("request ids: %s-<index>\n", *requestIDPrefix)
	}

	// The frozen manifest's provenance is stamped into every raw row.
	//
	// That lets the report enforce trace identity and read the pre-registered knobs from the evidence.
	tol, err := strconv.ParseFloat(m.MatchTolerance, 64)
	if err != nil {
		return fmt.Errorf("manifest matchTolerance %q is not a number: %w", m.MatchTolerance, err)
	}
	if studyKnown && study.FrozenExactTokens != nil {
		// Refused before the first request: a row whose count is not the frozen one was not generated for this study.
		for _, r := range rows {
			if want := study.FrozenExactTokens[r.PromptLenChars]; want <= 0 || r.ExactInputTokens != want {
				return fmt.Errorf("row %d of %s carries %d exact input tokens for a %d-character prompt, and study %s froze %d",
					r.Index, m.TracePath, r.ExactInputTokens, r.PromptLenChars, study.ID, want)
			}
		}
	}
	recordTiming := false
	if studyKnown && study.RecordsReplayTiming {
		// Refused before the first request: rows without IDs cannot be joined to the gateway's record, and the
		// pilot's every timing measurement is that join.
		if *requestIDPrefix == "" {
			return fmt.Errorf("study %s joins its rows to the gateway's record by request ID, and no --request-id-prefix was given", study.ID)
		}
		recordTiming = true
		if err := writeSenderConfig(*rawOut+".sender.json", senderConfig{
			Study: m.Study, Arm: m.Arm, ConnMode: *connMode,
			MaxIdleConnsPerHost: conn.MaxIdleConnsPerHost, DrainForReuse: conn.DrainForReuse,
			TimeoutMs: m.TimeoutMs, Model: m.Model, Target: url, Priorities: prio,
			RequestIDPrefix: *requestIDPrefix,
		}); err != nil {
			return err
		}
	}
	var live *liveRows
	if recordTiming {
		// Each row is appended durably as its request ends, so the evidence sidecar can carry it off the instance
		// while the replay is still running (design page, build item 8).
		// Named live-raw-*, not raw-*.live.jsonl: every reader of raw-*.jsonl would count it as a cell's rows.
		if live, err = openLiveRows(filepath.Join(filepath.Dir(*rawOut), "live-"+filepath.Base(*rawOut))); err != nil {
			return err
		}
	}
	raw := bench.Replay(context.Background(), sender, rows, bench.ReplayOptions{
		Study:           m.Study,
		Arm:             m.Arm,
		Priorities:      prio,
		RequestIDPrefix: *requestIDPrefix,
		TraceChecksum:   m.TraceChecksum,
		LongThreshold:   m.LongThreshold,
		MatchTolerance:  tol,
		RecordTiming:    recordTiming,
		OnRow:           live.write,
	})
	if live != nil {
		// A live file that failed is reported, not fatal: the complete rows are written below either way, and the
		// live file only matters to an instance that dies before they are.
		if n, first := live.close(); n > 0 {
			fmt.Fprintf(os.Stderr, "WARNING: %d row(s) could not be appended to the live file; the first error: %v\n", n, first)
		}
	}

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
// ladderPlanCheck asks, of a trace that has been generated but not replayed, whether the cell it describes
// could ever be scored.
//
// It takes a generated trace file rather than counts on the command line, so the thing being checked is the
// artefact the run will actually replay and not a number somebody typed twice.
func ladderPlanCheck(args []string) error {
	fs := flag.NewFlagSet("ladder-plan-check", flag.ExitOnError)
	trace := fs.String("trace", "", "the generated trace file to check")
	study := fs.String("study", "", "the study the cell belongs to")
	arm := fs.String("arm", "", "the arm name the cell will record")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *trace == "" || *study == "" || *arm == "" {
		return fmt.Errorf("--trace, --study and --arm are all required")
	}
	tf, err := os.Open(*trace)
	if err != nil {
		return fmt.Errorf("open trace %s: %w", *trace, err)
	}
	defer func() { _ = tf.Close() }()
	rows, err := bench.ReadTrace(tf)
	if err != nil {
		return fmt.Errorf("read trace %s: %w", *trace, err)
	}
	premium, contender := 0, 0
	for _, r := range rows {
		switch r.Tenant {
		case bench.PremiumTenant:
			premium++
		case bench.NoisyTenant:
			contender++
		}
	}
	if perr := bench.LadderPlanRefusal(*study, *arm, premium, contender); perr != nil {
		return fmt.Errorf("%s: %w", *arm, perr)
	}
	fmt.Printf("%s: %d premium, %d contender -- scorable\n", *arm, premium, contender)
	return nil
}

// ladderVerdictStop is the exit code that tells the runner to stop climbing.

// ladderVerdictStop is the exit code that tells the runner to stop climbing.
//
// A distinct code rather than a non-zero, because the runner must tell "both topologies breached, which is
// what we were climbing to find" apart from "something went wrong". The first is the successful end of a
// ladder and the second must not be mistaken for it.
const ladderVerdictStop = 10

// ladderVerdict answers the one question the runner asks between rungs: climb again, or stop here?
//
// It exists so that the stopping rule lives in the same package as the criterion it applies. The
// alternative was a shell script reading a p99 out of a table and comparing it to a threshold written down
// twice -- and a threshold written down twice is a threshold that will eventually differ, in the direction
// whoever edits it wants.
//
// It prints one line as well as setting an exit code. The line is what the runner asserts on, so a change
// to either alone is caught rather than silently obeyed.
func ladderVerdict(args []string) error {
	fs := flag.NewFlagSet("ladder-verdict", flag.ExitOnError)
	var rawFiles multiFlag
	fs.Var(&rawFiles, "raw", "a raw evidence file (repeatable); pass every ladder cell measured so far")
	rung := fs.Int("rung", 0, "the rung just measured")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if len(rawFiles) == 0 {
		return fmt.Errorf("at least one --raw file is required")
	}
	if *rung <= 0 {
		return fmt.Errorf("--rung is required and must name the rung just measured")
	}
	e, err := loadArmEvidence(rawFiles)
	if err != nil {
		return err
	}
	// The SAME evidence refusal the report applies, before a purchase decision is made on the evidence.
	//
	// It was absent here, so a rung whose two cells replayed different traces -- which `report` refuses with
	// a non-zero exit -- produced LADDER: CONTINUE and bought the next rung. The cheap decision accepted
	// evidence the expensive one would throw away.
	if terr := e.refuseIfTracesDisagree(); terr != nil {
		fmt.Println("LADDER: INVALID")
		return fmt.Errorf("rung %d cannot be scored: %w", *rung, terr)
	}
	summaries, _ := e.summarize()
	res := bench.EvaluateThroughputLadder(summaries)

	// An unscorable cell stops the ladder for a different reason than a breach does, and says so.
	for _, r := range res.Readings {
		if r.Fired && r.ID == "L0" {
			fmt.Println("LADDER: INVALID")
			return fmt.Errorf("rung %d cannot be scored: %s", *rung, r.Detail)
		}
	}
	// An INCOMPLETE requested rung is not a stopping point, and the caller cannot tell the two apart from a
	// boolean. Asking about a rung whose pair is not in the evidence used to print STOP and exit 10, which
	// the runner acts on by ending the climb -- a missing cell reported as a registered result.
	if !bench.LadderRungComplete(res, *rung) {
		fmt.Println("LADDER: INVALID")
		return fmt.Errorf("rung %d is not complete in this evidence, so there is no verdict to give: both contended topologies must be present and scorable", *rung)
	}
	cont, detail := bench.LadderShouldContinue(res, *rung)
	if cont {
		fmt.Println("LADDER: CONTINUE")
		fmt.Fprintln(os.Stderr, detail)
		return nil
	}
	fmt.Println("LADDER: STOP")
	fmt.Fprintln(os.Stderr, detail)
	os.Exit(ladderVerdictStop)
	return nil
}

func report(args []string) error {
	fs := flag.NewFlagSet("report", flag.ExitOnError)
	var rawFiles multiFlag
	fs.Var(&rawFiles, "raw", "a raw evidence file (repeatable, one arm per file)")
	matchTolFlag := fs.Float64("match-tolerance", 0.05,
		"fallback admission-work match tolerance when the evidence carries none")
	out := fs.String("out", "", "report file to write (default stdout)")
	// A machine-readable copy, because the paid raw evidence is gitignored and 7 MB.
	//
	// A number quoted in a write-up whose source is not in the repository is a number nobody can re-derive,
	// and every overclaim this project has had to withdraw took that shape. This file is what a spec's table
	// is checked against, so the derivation runs from the report code rather than from a hand copy.
	jsonOut := fs.String("json-out", "", "machine-readable per-arm summary to write alongside the report")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if len(rawFiles) == 0 {
		return fmt.Errorf("at least one --raw file is required")
	}

	e, err := loadArmEvidence(rawFiles)
	if err != nil {
		return err
	}
	if err := e.refuseIfTracesDisagree(); err != nil {
		return err
	}
	matchTolerance := e.frozenMatchTolerance(*matchTolFlag)
	summaries, summ := e.summarize()
	incCI := e.incrementalCI()

	// Name the arms that are absent, because the refusal downstream cannot.
	//
	// summ is a map, so a missing arm yields the zero ArmSummary, whose TailSampleSize is 0, and
	// EvaluateChecks disqualifies the comparison on exactly that. The refusal therefore WORKS -- a session cut
	// short by a reclaimed node or an aborted run cannot be reported as a result. Two independent reviews
	// asserted the opposite, and reading this path is what settled it.
	//
	// What the refusal cannot do is say WHICH arm. Its message interpolates s.Arm, which on a zero value is the
	// empty string, so the operator reads "arm  completed no premium requests" and has to work out from the
	// record directory what is missing. That is a bad minute to spend at the end of a paid session, and it is
	// the difference between a gate that stops you and a gate that tells you what to re-run.
	// The three checks below are M5-b's pre-registered comparison, and they name M5-b's arms.
	//
	// Running them for another experiment asked for static-cap and kv-aware, found neither, and reported
	// the run disqualified -- a verdict about arms the experiment never had. Another study's readings are
	// its own, so until they are implemented the report prints that study's tables and says plainly that
	// it evaluated no criteria, rather than failing it against somebody else's.
	// The registered estimand's two arms must carry the SAME repetition identities, not merely as many.
	//
	// FormatReport prints B, C and R from summaries alone (internal/bench/report.go), and the slices it
	// divides are per-arm: equal lengths are all ComputeRegisteredEstimand can check, because a []float64
	// cannot say which repetition each value came from. So {1,2} against {1,3} would be published as a
	// paired ratio of two repetitions that were never the same block. The identities live here, in the
	// evidence, which is why the check is here and not in the formatter.
	if len(e.reps[bench.ArmR1]) > 0 && len(e.reps[bench.ArmShared]) > 0 {
		if _, _, why := e.pairedRepetitions(bench.ArmR1, bench.ArmShared); why != "" {
			return fmt.Errorf("the registered estimand pairs %s with %s by repetition identity, and %s;"+
				" reporting a ratio of their medians would present two unpaired arms as paired blocks",
				bench.ArmR1, bench.ArmShared, why)
		}
	}

	checks, pop, sharing, ladder := evaluateRegisteredReadings(e, summ, summaries, rawFiles, incCI, matchTolerance)
	// The repetition floor goes AHEAD of the tables, because it is a premise about the sample rather than a
	// finding in it.
	//
	// Concatenated rather than branched on, and that is not a style choice: adding `if why != ""` here took
	// `report` from cyclomatic complexity 30 to 31 against a limit of 30 and `make lint` went red, measured.
	// So the function returns the whole prefix including its label, or the empty string, and an empty string
	// prepends nothing. The alternative was widening the gocyclo exemption this file already carries for
	// run(), which buys the same line by raising the ceiling instead of spending less of it.
	//
	// It is prepended to `text` rather than written to stderr so the warning lands in the file too -- a
	// report read out of the archive months later carries its own premise.
	text := e.repetitionFloorPrefix(summaries) + bench.FormatReport(summaries, checks, matchTolerance) + e.tailCrossingReadings(summaries)
	if pop != nil {
		text += bench.FormatPriceOfProtection(*pop)
	}
	if sharing != nil {
		text += bench.FormatSharingMatrix(*sharing)
	}
	if ladder != nil {
		text += bench.FormatThroughputLadder(*ladder)
	}

	if *out != "" {
		if err := os.WriteFile(*out, []byte(text), 0o600); err != nil {
			return fmt.Errorf("write report %s: %w", *out, err)
		}
		fmt.Printf("wrote report to %s\n", *out)
	} else {
		fmt.Print(text)
	}

	if *jsonOut != "" {
		enc, merr := json.MarshalIndent(summaries, "", "  ")
		if merr != nil {
			return fmt.Errorf("encode summaries: %w", merr)
		}
		if werr := os.WriteFile(*jsonOut, append(enc, '\n'), 0o600); werr != nil {
			return fmt.Errorf("write %s: %w", *jsonOut, werr)
		}
		fmt.Printf("wrote per-arm summaries to %s\n", *jsonOut)
	}

	// An INVALID run exits non-zero. A run that merely fails its checks does not.
	//
	// The distinction is the whole point. "Not all checks passed" is a scientific result -- the guard did not
	// protect, and that is a finding worth recording. "Run invalid" means the evidence cannot answer the
	// question at all, and the paid wrapper was treating the two identically: hack/m5b-arms.sh runs
	//
	//     benchharness report ... || fail "report"
	//
	// and this command returned 0 for both, so a session whose evidence had been disqualified printed a
	// success line and moved on to the next arm. Every hole closed today -- the missing arm, the transport
	// censoring, the absent interval, the thin repetition, the short recording -- reaches the operator through
	// this exit code, and until now none of them did.
	//
	// The report file is still written first, so the refusal is preserved as evidence rather than discarded.
	//
	// A study with no implemented readings reaches here with nil checks. It cannot be INVALID, because
	// nothing evaluated it -- and it must not be reported as valid either. The exit code says only what this
	// binary actually decided, and the report itself says the criteria were not evaluated.
	if checks != nil && checks.Invalid {
		return fmt.Errorf("run invalid: %s", checks.InvalidReason)
	}
	// The price-of-protection study reaches here with nil checks, so its INVALID readings used to exit 0 --
	// and the paid runner calls this as `benchharness report ... || fail`, which is the whole reason the
	// comment above says an invalid run exits non-zero. A run whose load made no contention, or whose load
	// was too high to measure, printed its refusal and told the wrapper it had succeeded.
	// The sharing study's INVALID readings exit non-zero too, for the reason the price-of-protection block
	// below gives: automation that writes `benchharness report ... || fail` would otherwise accept a run the
	// readings had just declared unusable.
	if sharing != nil {
		if err := sharingRunInvalid(*sharing); err != nil {
			return err
		}
	}
	if pop != nil {
		for _, r := range pop.Readings {
			if r.Fired && (r.ID == "4" || r.ID == "4b") {
				return fmt.Errorf("run invalid: reading %s fired -- %s", r.ID, r.Detail)
			}
		}
	}
	// The ladder's L0 is its only INVALID reading, and the distinction it draws is the one the runner acts
	// on: a cell that could not be scored must stop the ladder, and a rung where both topologies BREACHED
	// must not -- a breach is what the ladder is climbing to find.
	//
	// L5 is the same kind of result. "No qualified operating point at or above the bottom rung" is a
	// finding about where the answer lies, not evidence that failed, and exiting non-zero for it would tell
	// a wrapper that writes `benchharness report ... || fail` to discard a rung it paid for.
	if ladder != nil {
		for _, r := range ladder.Readings {
			if r.Fired && r.ID == "L0" {
				return fmt.Errorf("run invalid: reading L0 fired -- %s", r.Detail)
			}
		}
		// A FINAL report needs the baseline; a between-rung verdict does not, which is why this is here and
		// not in L0. ladderVerdict deliberately does not consult it.
		if ladder.BaselineMissing {
			return fmt.Errorf("run invalid: %s", ladder.BaselineNote)
		}
	}
	return nil
}

// repSummary is one repetition's whole shape, carried under the identity the runner recorded for it.
//
// It exists because the six per-repetition structures below used to be six independent slices appended in
// --raw ARGUMENT ORDER, and the third 2026-09-30 amendment pairs arms by the repetition identity the
// schedule records rather than by position. Keeping them as separate slices made two failures possible:
// pairing arm A's repetition 3 with arm B's repetition 1 because that is the order the shell happened to
// glob, and -- if only one slice were converted to a map -- silently desynchronising the rest. One struct
// per repetition makes "sort one and forget the others" impossible to express.
//
// repID is the number the runner wrote into the filename (hack/m5c-matrix.sh builds cells as
// arm|arm|rep|... and names each raw file raw-<arm>-<rep>.jsonl). It is NOT derived from position, and the
// arm half comes from the ROWS -- singleArm has already proven every row agrees on it -- so an arm name
// containing hyphens (kv-aware, mbt-1024-priority, rung03-timeSlicing) cannot be mis-split.
type repSummary struct {
	repID   int
	ttftP99 float64
	tail    int
	// rowCount is the number of rows, and rows is the rows themselves.
	//
	// They are separate fields with distinct names because the amendment of 2026-10-01 needs both and
	// confusing them is the shape of the defect it fixes: the first draft of this struct carried only a
	// count called `rows`, and a block bootstrap written against it would have had to recover the rows by
	// slicing the pooled arm by those counts -- which is positional reconstruction, the inference the
	// pairing work exists to remove.
	rowCount int
	rows     []bench.RawRow
	seconds  float64
	done     map[string]int
	served   map[string]float64
	censored bool
	// checksum is this repetition's trace, kept per repetition because a study can give each its own.
	checksum string
}

// armEvidence is every arm's rows plus the per-repetition shape the pooled rows cannot carry.
//
// It exists because report's refusals ask questions of the SPLIT -- did each repetition record the same
// number of rows, is any repetition's tail thin -- and pooling answers none of them.
type armEvidence struct {
	// byArm is every arm's rows pooled, DERIVED from reps in repetition-identity order after loading.
	//
	// It used to be accumulated in --raw argument order beside reps. Deriving it means the pooled rows and
	// the per-repetition blocks cannot disagree about which rows belong to the arm.
	//
	// It is a derived COPY, not a no-copy view: the loop below appends `r.rows...` into a separate backing
	// array, so each RawRow struct is stored twice -- once in its block and once here. The comment here
	// claimed the rows were "stored once" and that this map held slices into reps' own array, and that was
	// wrong. Strings and other references are shared, so the duplication is the struct storage rather than
	// the payload, but it is duplication.
	byArm map[string][]bench.RawRow
	// reps is each arm's repetitions under their recorded identities, sorted by repID once loading ends.
	//
	// The six derived maps below are rebuilt from it rather than appended to directly, so they cannot fall
	// out of step with each other or with the identity.
	reps    map[string][]repSummary
	repP99  map[string][]float64
	repTail map[string][]int
	// repDone is each repetition's completed count per tenant: arm -> one map per repetition.
	//
	// repTail carries only the premium tenant's, so reading 4b's contender floor could be applied to the
	// POOL and nothing else. An independent review reproduced what that allows: repetitions of 140, 140 and
	// 50 contender completions, each offered 140, clear a hundred-completion floor at 330 pooled and fire
	// reading 1 POSITIVE -- on a run containing one block the registration calls invalid.
	repDone map[string][]map[string]int
	// replayFrom maps a replay's IDENTITY to the file that carried it, so the same replay cannot be
	// counted twice as two repetitions.
	//
	// A repetition is supposed to be an independent measurement. Nothing stopped the same file being
	// passed twice, or copied under a second name: both produced RepetitionCount=2, equal counts across
	// arms, and a control whose repetition-to-repetition spread is EXACTLY ZERO -- which is the threshold
	// readings 3 and 5 compare an improvement against. A review reproduced it by passing each of the eighth
	// pilot's files twice, and reading 5 fired on single-repetition evidence.
	//
	// The identity is the arm plus every row's send timestamp. Two real replays of the same trace start at
	// different nanoseconds; a copy is bit-identical. The trace checksum cannot do this job -- repetitions
	// of one arm are SUPPOSED to share it, and the check beside this one refuses them when they do not.
	replayFrom map[string]string
	// repServed is each repetition's completed/offered per tenant, which the counts alone cannot express.
	repServed map[string][]map[string]float64
	// repCensored records whether ANY of an arm's repetitions was censored, which pooling hides.
	repCensored map[string]bool
	repRows     map[string][]int
	// repSeconds is each repetition's own wall clock, kept because the arm's throughput must be its tokens
	// over the time it was actually sending -- not over a pooled span that includes the washout pauses
	// between repetitions.
	repSeconds map[string][]float64
	checksum   map[string]string
	tolerance  map[string]float64
	// treatment is the canonical rendering of the priorities each arm's rows carried, so two replays that
	// differ only in treatment cannot be pooled as repetitions of one condition.
	treatment map[string]string
	// study is the one pre-registered experiment every row in this report came from, and studyFrom is
	// the file that established it, so a refusal can name both sides of the disagreement.
	//
	// studySeen is separate because the empty string is a legitimate value here -- it is what every raw
	// file written before the study field existed carries. Using "" as the not-yet-set sentinel made
	// unlabelled evidence silently adopt whatever study the next file named, which is the one mixing
	// this check exists to prevent.
	study string
	// studyRecorded is what the file literally carried, kept alongside the normalized value so a refusal
	// can say "unlabelled" instead of silently presenting old evidence as if it had named a study.
	studyRecorded string
	studySeen     bool
	studyFrom     string
	// tracesVary is the study's TracesVaryByRepetition, read once with the study.
	tracesVary bool
	// repFrom maps an (arm, repID) to the file that carried it, so a duplicate identity can name both
	// files -- and it spans the WHOLE input set rather than one directory, because a glob over two run
	// directories is exactly how the same repetition number arrives twice.
	repFrom map[string]string
}

// repIDFromPath reads the repetition identity the runner recorded in a raw file's name.
//
// The arm comes from the rows (already validated by singleArm) and is used as an exact prefix, so the
// number is whatever follows it. That is what makes this unambiguous: 22 arm names in this repository
// contain hyphens, and raw-mbt-1024-priority-1.jsonl cannot be split without knowing the arm.
//
// A name that does not match is REFUSED rather than falling back to position. A positional fallback for
// unmarked files would leave the inference the amendment forbids -- pairing two arrays because they are the
// same length -- alive for exactly the inputs whose identity is unknown.
func repIDFromPath(path, arm string) (int, error) {
	base := filepath.Base(path)
	want := "raw-" + arm + "-"
	if !strings.HasPrefix(base, want) || !strings.HasSuffix(base, ".jsonl") {
		return 0, fmt.Errorf("%s carries arm %q in every row, so its name must be raw-%s-<repetition>.jsonl;"+
			" the pairing of two arms is by the repetition identity the runner recorded in the filename, and a"+
			" name it cannot read would be paired by --raw argument order instead",
			path, arm, arm)
	}
	digits := strings.TrimSuffix(strings.TrimPrefix(base, want), ".jsonl")
	id, err := strconv.Atoi(digits)
	if err != nil || id < 1 {
		return 0, fmt.Errorf("%s names repetition %q after arm %q, which is not a positive number;"+
			" the identity has to be comparable between arms, and %q cannot be",
			path, digits, arm, digits)
	}
	return id, nil
}

// singleStudy returns the one study every row in a file belongs to, or refuses.
//
// Normalization is applied before comparing, so an unlabelled legacy file and one that names
// m5b-gateway-v1 explicitly are the same study rather than two.
// singleArm is singleStudy's twin: a raw file is ONE arm, and every row has to say so.
//
// It also checks the trace checksum, because the two travel together -- rows from another cell carry both a
// different arm and a different trace, and a file doctored to fix one would still fail the other.
func singleArm(path string, rows []bench.RawRow) (string, error) {
	arm, sum := rows[0].Arm, rows[0].TraceChecksum
	for i, r := range rows {
		if r.Arm != arm {
			return "", fmt.Errorf("%s mixes arms within one file: row 0 carries %q but row %d carries %q;"+
				" a raw file is one arm of one experiment, and pooling two of them reports a cell nobody ran",
				path, arm, i, r.Arm)
		}
		if r.TraceChecksum != sum {
			return "", fmt.Errorf("%s mixes traces within one file: row 0 carries checksum %s but row %d carries %s;"+
				" one replay of one immutable trace is what a raw file records",
				path, sum, i, r.TraceChecksum)
		}
	}
	return arm, nil
}

func singleStudy(path string, rows []bench.RawRow) (canonical, recorded string, err error) {
	recorded = rows[0].Study
	canonical = bench.CanonicalStudyID(recorded)
	for i, r := range rows {
		if got := bench.CanonicalStudyID(r.Study); got != canonical {
			return "", "", fmt.Errorf("%s mixes studies within one file: row 0 carries %s but row %d carries %s;"+
				" a raw file is one arm of one experiment",
				path, studyLabel(canonical, recorded), i, studyLabel(got, r.Study))
		}
	}
	return canonical, recorded, nil
}

// treatmentOf renders the priorities a file's rows carried, as a stable string.
//
// Derived from the rows rather than from a flag the runner claims to have passed, because the point is to
// describe what the requests actually carried. Sorted so the same treatment always renders identically.
func treatmentOf(rows []bench.RawRow) string {
	seen := map[string]int{}
	for _, r := range rows {
		if r.Priority != nil {
			seen[r.Tenant] = *r.Priority
		}
	}
	if len(seen) == 0 {
		return "none"
	}
	tenants := make([]string, 0, len(seen))
	for t := range seen {
		tenants = append(tenants, t)
	}
	sort.Strings(tenants)
	parts := make([]string, 0, len(tenants))
	for _, t := range tenants {
		parts = append(parts, fmt.Sprintf("%s=%d", t, seen[t]))
	}
	return strings.Join(parts, ",")
}

// studyLabel renders a study for a refusal message, disclosing when the file did not name one.
//
// The comparison normalizes an empty study to the M5-b experiment, because unlabelled evidence IS that
// experiment and refusing to pool it with evidence that says so would reject a legitimate comparison. The
// message must not normalize as well: an operator reading "these are different experiments" needs to know
// that one side was old evidence carrying no label, not a file naming a study they do not recognise.
func studyLabel(canonical, recorded string) string {
	if recorded == "" {
		return canonical + " (unlabelled, predates the study field)"
	}
	return canonical
}

// loadArmEvidence reads one raw file per repetition and groups it by arm.
func loadArmEvidence(rawFiles []string) (*armEvidence, error) {
	// Group rows and per-file p99 repetitions by arm, and capture each arm's frozen provenance.
	e := &armEvidence{
		byArm: map[string][]bench.RawRow{}, repP99: map[string][]float64{},
		reps:    map[string][]repSummary{},
		repTail: map[string][]int{}, repRows: map[string][]int{}, repSeconds: map[string][]float64{},
		repDone:     map[string][]map[string]int{},
		replayFrom:  map[string]string{},
		repFrom:     map[string]string{},
		repCensored: map[string]bool{},
		repServed:   map[string][]map[string]float64{},
		checksum:    map[string]string{}, tolerance: map[string]float64{},
		treatment: map[string]string{},
	}
	for _, path := range rawFiles {
		f, err := os.Open(path)
		if err != nil {
			return nil, fmt.Errorf("open %s: %w", path, err)
		}
		rows, err := bench.ReadRawRows(f)
		_ = f.Close()
		if err != nil {
			return nil, err
		}
		if len(rows) == 0 {
			continue
		}
		// Two studies in one report is not a comparison, it is a category error.
		//
		// Nothing else catches it. Arm names are not unique across studies, and the trace checksum does
		// not stand in for study identity either: refuseIfTracesDisagree only inspects three hard-coded
		// M5-b arm names and skips anything it does not recognise, so rows from a different experiment
		// pass through it untouched. This is the check, and it runs before a single row is pooled.
		// EVERY row, not the first one.
		//
		// Reading rows[0] made the check defeatable by concatenation: a file whose first row is legacy and
		// whose remaining rows belong to another experiment passed, and ReadRawRows sorts by index so which
		// row lands first is not even under the operator's control among ties.
		study, recorded, err := singleStudy(path, rows)
		if err != nil {
			return nil, err
		}
		if !e.studySeen {
			e.study = study
			e.studyRecorded = recorded
			e.studySeen = true
			e.studyFrom = path
		} else if study != e.study {
			return nil, fmt.Errorf("%s carries study %s but %s carries %s; these are different"+
				" pre-registered experiments and their arms do not mean the same thing, so pooling them"+
				" would report a comparison that was never run",
				path, studyLabel(study, recorded), e.studyFrom, studyLabel(e.study, e.studyRecorded))
		}

		// EVERY row's arm and trace, for the reason every row's study is checked: a file is one arm of one
		// experiment, and reading row zero made both defeatable by concatenation. An adversarial review
		// appended one arm's rows to another's and watched the pooled p99 move from 1,694.7 ms to 1,179.3
		// while the report exited 0.
		arm, err := singleArm(path, rows)
		if err != nil {
			return nil, err
		}
		// An UNREGISTERED study is refused rather than warned about.
		//
		// A typo in the study id used to fall through: LookupStudy misses, the arm order falls back to
		// M5-b's, every ladder arm drops out of the table, and the report exits 0 saying only that it
		// evaluated no criteria. Evidence whose experiment this binary does not know is evidence it cannot
		// place, and "no criteria evaluated" is what it says about a study whose readings are not written --
		// a different thing, and one a reader has no way to tell apart.
		//
		// Rows written before studies existed carry an empty id, which CanonicalStudyID maps to M5-b, so
		// this refusal only bites an id that was actually wrong.
		st, known := bench.LookupStudy(study)
		if !known {
			return nil, fmt.Errorf("%s records study %s, which is not registered; known studies are %s."+
				" A report cannot place evidence from an experiment it does not know, and reporting it under"+
				" another study's arm order would be a comparison nobody ran",
				path, studyLabel(study, recorded), strings.Join(bench.KnownStudyIDs(), ", "))
		}
		// And the arm must be one the study admits. An unknown arm is not a row this report can place: it
		// falls out of the study's order, out of contendedArms, and out of every reading that names arms --
		// silently, because nothing downstream asks whether it belonged.
		if !st.Admits(arm) {
			return nil, fmt.Errorf("%s records arm %q, which study %s does not admit (%s);"+
				" a report cannot place a row whose arm its own registry does not name",
				path, arm, st.ID, strings.Join(st.Arms, ", "))
		}

		// Keep the whole per-repetition summary, not just its p99.
		//
		// This line used to discard everything except TTFTMsP99, which is how a truncated repetition became
		// invisible: the pooled arm summary sums every row, so three healthy repetitions carry a fourth whose
		// p99 is a maximum over thirty requests -- and the bootstrap then resamples that fourth value with
		// equal weight.
		// The same replay may not be counted twice.
		h := fnv.New64a()
		var buf [8]byte
		for _, r := range rows {
			binary.LittleEndian.PutUint64(buf[:], uint64(r.SendUnixNanos))
			_, _ = h.Write(buf[:])
		}
		id := fmt.Sprintf("%s/%x", arm, h.Sum64())
		if prev, dup := e.replayFrom[id]; dup {
			return nil, fmt.Errorf("%s and %s carry the SAME replay of arm %s -- every row was sent at the"+
				" same nanosecond, so one is a copy of the other. Counting it twice would report two"+
				" repetitions whose spread is exactly zero, and that spread is what readings 3 and 5"+
				" measure an improvement against", path, prev, arm)
		}
		e.replayFrom[id] = path

		// The repetition's IDENTITY, read from the name the runner wrote, and refused if it is not there.
		//
		// This runs after the arm has been validated against every row, because the arm is the prefix this
		// strips. Doing it earlier would mean splitting a hyphenated arm name by guesswork.
		repID, err := repIDFromPath(path, arm)
		if err != nil {
			return nil, err
		}
		// The same (arm, repetition) twice is refused across the WHOLE input set, not per directory.
		//
		// replayFrom above catches a byte-identical copy by hashing send timestamps. It cannot catch two
		// DIFFERENT replays both calling themselves repetition 3 -- two run directories globbed together --
		// and that pair would pair one of them against the other arm's repetition 3 while discarding which.
		repKey := arm + "/" + strconv.Itoa(repID)
		if prev, dup := e.repFrom[repKey]; dup {
			return nil, fmt.Errorf("%s and %s both record arm %s repetition %d;"+
				" the pairing is by that identity, so two files claiming it leave no way to say which"+
				" repetition the other arm's repetition %d is being compared with",
				path, prev, arm, repID, repID)
		}
		e.repFrom[repKey] = path

		rs := bench.Summarize(arm, rows)
		done := map[string]int{}
		served := map[string]float64{}
		for tenant, d := range rs.DispositionByTenant {
			done[tenant] = d.Completed
			if d.Offered > 0 {
				served[tenant] = float64(d.Completed) / float64(d.Offered)
			}
		}
		e.reps[arm] = append(e.reps[arm], repSummary{
			repID:    repID,
			ttftP99:  rs.TTFTMsP99,
			tail:     rs.TailSampleSize,
			rowCount: len(rows),
			rows:     rows,
			seconds:  rs.ActiveSeconds,
			done:     done,
			served:   served,
			censored: rs.Censored,
			checksum: rows[0].TraceChecksum,
		})
		// Every repetition's checksum, not the last one's.
		//
		// This assigned, so loadArmEvidence kept only whichever file it read last and a repetition replayed
		// from a different trace was invisible to refuseIfTracesDisagree -- the one check whose entire job is
		// to prove the arms saw identical traffic. The trigger is a workflow this runner endorses: re-running
		// one botched arm into the same output directory.
		//
		// A study that registered a trace per repetition inverts the rule: two repetitions of one arm sharing
		// a trace are the defect, because they are one draw of the arrival process counted twice. Every
		// earlier repetition is compared, not the previous one, so a third repeating the first is caught.
		e.tracesVary = st.TracesVaryByRepetition
		if st.TracesVaryByRepetition {
			for _, earlier := range e.reps[arm][:len(e.reps[arm])-1] {
				if earlier.checksum == rows[0].TraceChecksum {
					return nil, fmt.Errorf("arm %s repetitions %d and %d replayed the same trace (%s), and study %s registers a trace per repetition;"+
						" the second is the first draw of the arrival process measured again, so the seed was not varied",
						arm, earlier.repID, repID, rows[0].TraceChecksum, study)
				}
			}
		} else if prev, ok := e.checksum[arm]; ok && prev != rows[0].TraceChecksum {
			return nil, fmt.Errorf("arm %s has repetitions replayed from different traces (%s and %s); its rows are pooled into one summary, so mixing them compares an arm against itself across two workloads", arm, prev, rows[0].TraceChecksum)
		}
		e.checksum[arm] = rows[0].TraceChecksum
		if prev, ok := e.tolerance[arm]; ok && prev != rows[0].MatchTolerance {
			return nil, fmt.Errorf("arm %s has repetitions carrying different admission-match tolerances (%v and %v); the pre-registered tolerance cannot be two values", arm, prev, rows[0].MatchTolerance)
		}
		e.tolerance[arm] = rows[0].MatchTolerance
		// The treatment is part of an arm's identity, exactly like its trace and its tolerance.
		//
		// Without this, replaying one manifest twice -- once with --priorities and once without -- produced
		// two files a report happily pooled as repetitions of the same condition. The bootstrap would then
		// resample across a treated and an untreated run and report the interval as if one thing had been
		// measured four times.
		treat := treatmentOf(rows)
		if prev, ok := e.treatment[arm]; ok && prev != treat {
			return nil, fmt.Errorf("arm %s has repetitions replayed under different priority treatments (%s and %s);"+
				" they are two conditions, and pooling them reports an interval over a comparison rather than a repetition",
				arm, prev, treat)
		}
		e.treatment[arm] = treat
	}

	// The per-repetition structures are DERIVED from the identities, in identity order, once.
	//
	// They used to be appended in --raw argument order inside the loop above. Deriving them here instead is
	// what makes the pairing the recorded one: position i in every one of these slices is repetition
	// e.reps[arm][i].repID, for every arm, whatever order the caller listed the files in.
	//
	// All seven are rebuilt in the same pass deliberately. Converting one of them to a map and leaving the
	// rest positional would pair correctly and then report the wrong repetition's row count beside it.
	for arm := range e.reps {
		sort.Slice(e.reps[arm], func(i, j int) bool { return e.reps[arm][i].repID < e.reps[arm][j].repID })
		for _, r := range e.reps[arm] {
			e.byArm[arm] = append(e.byArm[arm], r.rows...)
			e.repP99[arm] = append(e.repP99[arm], r.ttftP99)
			e.repTail[arm] = append(e.repTail[arm], r.tail)
			e.repRows[arm] = append(e.repRows[arm], r.rowCount)
			e.repSeconds[arm] = append(e.repSeconds[arm], r.seconds)
			e.repDone[arm] = append(e.repDone[arm], r.done)
			e.repServed[arm] = append(e.repServed[arm], r.served)
			if r.censored {
				e.repCensored[arm] = true
			}
		}
	}
	return e, nil
}

// refuseIfTracesDisagree stops a comparison whose arms did not replay the same trace, or did not finish
// replaying it.
func (e *armEvidence) refuseIfTracesDisagree() error {
	// A study with a trace per repetition holds the same two properties per REPETITION instead of per arm,
	// and adds the pairing a shared trace used to guarantee by construction.
	if e.tracesVary {
		return e.refuseIfRepetitionsDisagree()
	}
	// The contended arms must have replayed identical traffic, so their trace checksums must match.
	//
	// R1 legitimately differs (it is the same trace with the contender filtered out).
	//
	// So it is excluded from the identity check.
	// The identity holds WITHIN A COMPARISON GROUP, which is the whole study for every experiment that
	// offers one load and one rung for the capacity ladder, which offers four.
	//
	// It was written as one group across all arms, and that is correct for every study that existed when it
	// was written. The ladder broke it in the direction that matters: its rungs replay DIFFERENT traces on
	// purpose -- that is what a rung is -- so the report refused the ladder's own evidence after the cells
	// were bought. The first ladder rehearsal caught it on a free cluster; on a card it would have refused
	// at the end of the session, with every cell paid for.
	wantSum := map[string]string{}
	wantSumFrom := map[string]string{}
	for _, arm := range e.contendedArms() {
		sum, ok := e.checksum[arm]
		if !ok {
			continue
		}
		if sum == "" {
			return fmt.Errorf("arm %s carries no trace checksum; regenerate its manifest with a current gen-trace", arm)
		}
		g := comparisonGroup(arm)
		if _, seen := wantSum[g]; !seen {
			wantSum[g], wantSumFrom[g] = sum, arm
			continue
		}
		if sum != wantSum[g] {
			return fmt.Errorf("arm %s replayed a different trace (%s) than %s (%s);"+
				" arms compared against each other need one immutable trace", arm, sum, wantSumFrom[g], wantSum[g])
		}
	}

	// The same trace must also have produced the same NUMBER of records.
	//
	// The checksum above proves the arms replayed identical traffic. It says nothing about whether the
	// recording of that traffic finished, and the two are different questions with no shared symptom: a run
	// cut off partway -- a reclaimed node, a killed port-forward, a resumed session, a short duration -- leaves
	// every row it did write COMPLETE. Nothing is censored, no repetition is thin, the tail clears its floor,
	// and the arm is simply shorter than the trace it claims to have replayed.
	//
	// The direction is what makes this the worst of the set. Contention builds over a trace, so the requests
	// that arrive late are the slow ones; dropping the tail of the recording drops exactly the evidence that
	// would fail the arm. An adversarial review demonstrated it on this binary: complete evidence printed
	//
	//     absolute protection  C/R1 = 3.434  FAIL   ...  VERDICT: not all checks passed
	//
	// and the identical evidence truncated to its first 60% of rows printed
	//
	//     absolute protection  C/R1 = 1.066  PASS   ...  VERDICT: all checks passed; the guard protects
	//
	// with kv-aware at 960 recorded rows against 1,600 for the two arms it shares a trace with, unremarked.
	// A genuine FAIL certified as protection is the one outcome this study must never produce.
	//
	// This is a refusal rather than a check result, and it sits beside the checksum test for that reason: two
	// arms of different lengths cannot be compared at all, which is a statement about the evidence rather than
	// about the guard.
	contended := e.contendedArms()
	wantRows := map[string]int{}
	wantFrom := map[string]string{}
	// The repetition this names is the RECORDED one, not the position in the argument list.
	//
	// An operator reads this refusal at the end of a paid session and goes looking for the file. While the
	// number was the slice index, `repetition 1` meant "the second file --raw happened to list for this
	// arm", which is raw-R1-3.jsonl whenever the glob was not in order -- a message that sends them to the
	// wrong file is worse than one that gives no number.
	for _, arm := range contended {
		g := comparisonGroup(arm)
		for _, r := range e.reps[arm] {
			if wantRows[g] == 0 {
				wantRows[g], wantFrom[g] = r.rowCount, fmt.Sprintf("%s repetition %d", arm, r.repID)
				continue
			}
			if r.rowCount != wantRows[g] {
				return fmt.Errorf("arm %s repetition %d recorded %d rows but %s recorded %d;"+
					" these arms share one immutable trace, so a shorter recording means a run that did not finish,"+
					" and the requests it is missing are the late ones contention makes slow",
					arm, r.repID, r.rowCount, wantFrom[g], wantRows[g])
			}
		}
	}

	// A baseline replays the same trace with the contender filtered out, so its count legitimately differs
	// from the contended arms -- but not from itself.
	//
	// Every baseline, not the literal "R1": the ladder's is called rung02-R1, and a loop over one hardcoded
	// name would have checked nothing at all for it while looking exactly as though it had.
	for arm, reps := range e.reps {
		if !bench.IsIsolatedBaseline(arm) || len(reps) == 0 {
			continue
		}
		for _, r := range reps {
			if r.rowCount != reps[0].rowCount {
				return fmt.Errorf("arm %s repetition %d recorded %d rows but repetition %d recorded %d;"+
					" its repetitions replay one trace and must record the same number of rows",
					arm, r.repID, r.rowCount, reps[0].repID, reps[0].rowCount)
			}
		}
	}
	return nil
}

// refuseIfRepetitionsDisagree is refuseIfTracesDisagree for a study whose repetitions replay their own traces.
//
// What one shared trace guaranteed without a check now needs one: that the isolated baseline of repetition
// r is the partner of the contended arm's repetition r. The baseline's trace is the contended trace with
// the contender filtered out, so its checksum cannot be compared; its latency-critical SCHEDULE can, and is
// the thing the pairing is for -- a baseline drawn from another seed would compare two different arrival
// sequences and report their difference as interference.
//
// The same comparison is what catches a recording cut short. The per-arm path compares row counts between
// contended arms that share a trace; in these studies each comparison group holds one contended arm, so
// there is no sibling to compare against, and a check written for one would never run. A cut recording
// drops latency-critical rows, so its schedule no longer matches its baseline's and it is refused here.
func (e *armEvidence) refuseIfRepetitionsDisagree() error {
	for _, arm := range e.contendedArms() {
		for _, r := range e.reps[arm] {
			if r.checksum == "" {
				return fmt.Errorf("arm %s repetition %d carries no trace checksum; regenerate its manifest with a current gen-trace", arm, r.repID)
			}
		}
	}
	baselines := make([]string, 0, len(e.reps))
	for arm := range e.reps {
		if bench.IsIsolatedBaseline(arm) {
			baselines = append(baselines, arm)
		}
	}
	sort.Strings(baselines)
	for _, base := range baselines {
		g := comparisonGroup(base)
		for _, br := range e.reps[base] {
			want := premiumSchedule(br.rows)
			for _, arm := range e.contendedArms() {
				if comparisonGroup(arm) != g {
					continue
				}
				for _, cr := range e.reps[arm] {
					if cr.repID != br.repID {
						continue
					}
					if got := premiumSchedule(cr.rows); !slices.Equal(want, got) {
						return fmt.Errorf("repetition %d of %s and of %s offer %s different schedules (%d and %d requests);"+
							" a baseline is the same draw of the arrival process with the contender removed, so either the two"+
							" were generated from different seeds or one recording stopped early, and their difference is not interference",
							br.repID, base, arm, bench.PremiumTenant, len(want), len(got))
					}
				}
			}
		}
	}
	return nil
}

// premiumSchedule is the latency-critical tenant's scheduled offsets, sorted.
func premiumSchedule(rows []bench.RawRow) []int64 {
	var out []int64
	for _, r := range rows {
		if r.Tenant == bench.PremiumTenant {
			out = append(out, r.ScheduledOffsetMs)
		}
	}
	slices.Sort(out)
	return out
}

// pairedBlocks returns the two arms' repetition BLOCKS under the identities they share, for the M5-b
// interval the 2026-10-01 amendment specifies.
//
// It is pairedRepetitions' twin and shares its identity check: equal lengths are not a licence to zip, so
// the ID sets themselves are compared. The difference is what it hands back -- whole blocks of rows rather
// than each block's p99 -- because the amendment's replicate pools a drawn block's REQUESTS and recomputes
// the pooled p99, which is not a function of the blocks' own p99s.
//
// Censoring is refused here rather than in the estimator. A censored repetition makes that block's p99 a
// lower bound, and a replicate that draws it reports a bound as a measurement. The old gate checked only
// POOLED censoring (internal/bench/report.go reads ArmSummary.Censored), so a run at 0.49% pooled with one
// repetition at 1.96% passed; under the amendment it does not, and that is a narrowing of accepted input
// rather than a neutral change of estimator.
func (e *armEvidence) pairedBlocks(baseArm, contArm string) (base, cont [][]bench.RawRow, why string) {
	b, c := e.reps[baseArm], e.reps[contArm]
	if len(b) == 0 || len(c) == 0 {
		return nil, nil, fmt.Sprintf("arm %s carries %d repetitions and %s carries %d", baseArm, len(b), contArm, len(c))
	}
	ids := func(rs []repSummary) []string {
		out := make([]string, 0, len(rs))
		for _, r := range rs {
			out = append(out, strconv.Itoa(r.repID))
		}
		return out
	}
	bi, ci := ids(b), ids(c)
	if !slices.Equal(bi, ci) {
		return nil, nil, fmt.Sprintf("arm %s recorded repetitions %s and %s recorded %s;"+
			" the pairing is by that identity, so two arms that do not carry the same ones have no paired"+
			" blocks to compare even when they carry equally many",
			baseArm, strings.Join(bi, ","), contArm, strings.Join(ci, ","))
	}
	for _, pair := range [2]struct {
		arm  string
		reps []repSummary
	}{{baseArm, b}, {contArm, c}} {
		for _, r := range pair.reps {
			if r.censored {
				// "at least 1%", not "more than 1%": internal/bench/report.go sets Censored at `>= 0.01`,
				// so exactly 1% is censored too. And the numerator is not every request that failed to
				// complete -- requests shed by admission are excluded there, because a shed request is a
				// decision the guard made rather than a tail this benchmark failed to measure.
				return nil, nil, fmt.Sprintf("arm %s repetition %d is censored (at least 1%% of its premium"+
					" requests ended in a timeout or another transport or stream error; requests shed by"+
					" admission are not counted), so its p99 is a lower bound and any resample drawing it"+
					" reports a bound as a measurement", pair.arm, r.repID)
			}
		}
	}
	for i := range b {
		base = append(base, b[i].rows)
		cont = append(cont, c[i].rows)
	}
	return base, cont, ""
}

// pairedRepetitions returns the two arms' per-repetition victim tails under the identities they share, or
// says why they cannot be paired.
//
// Equal lengths are NOT a licence to zip. {1,2} and {1,3} are both two repetitions and pairing them by
// position compares repetition 2 of one arm with repetition 3 of the other -- the inference the third
// 2026-09-30 amendment exists to forbid, which is why the sets themselves are compared rather than their
// sizes.
func (e *armEvidence) pairedRepetitions(baseArm, contArm string) (base, cont []float64, why string) {
	b, c := e.reps[baseArm], e.reps[contArm]
	if len(b) == 0 || len(c) == 0 {
		return nil, nil, fmt.Sprintf("arm %s carries %d repetitions and %s carries %d", baseArm, len(b), contArm, len(c))
	}
	ids := func(rs []repSummary) []string {
		out := make([]string, 0, len(rs))
		for _, r := range rs {
			out = append(out, strconv.Itoa(r.repID))
		}
		return out
	}
	bi, ci := ids(b), ids(c)
	if !slices.Equal(bi, ci) {
		return nil, nil, fmt.Sprintf("arm %s recorded repetitions %s and %s recorded %s;"+
			" the pairing is by that identity, so two arms that do not carry the same ones have no paired"+
			" blocks to compare even when they carry equally many",
			baseArm, strings.Join(bi, ","), contArm, strings.Join(ci, ","))
	}
	for i := range b {
		base = append(base, b[i].ttftP99)
		cont = append(cont, c[i].ttftP99)
	}
	return base, cont, ""
}

// comparisonGroup names the set of arms an arm is compared against, which is what "one immutable trace"
// has to hold within.
//
// Every study but one offers a single load, so every arm is in one group and the group name is empty. The
// capacity ladder offers a different load per rung by design, so its group is the rung: rung01-shared and
// rung01-timeSlicing must replay the same trace as each other and MUST NOT replay the same trace as
// rung02's cells -- a ladder whose rungs agreed would be four measurements of one load.
func comparisonGroup(arm string) string { return bench.ArmComparisonGroup(arm) }

// frozenMatchTolerance prefers the tolerance recorded in the evidence over the CLI default.
func (e *armEvidence) frozenMatchTolerance(fallback float64) float64 {
	// The admission-match tolerance is the frozen one from the evidence, not a CLI default.
	//
	// So it cannot be loosened after the fact.
	matchTolerance := fallback
	if tol, ok := e.tolerance["kv-aware"]; ok && tol > 0 {
		matchTolerance = tol
	} else if tol, ok := e.tolerance["static-cap"]; ok && tol > 0 {
		matchTolerance = tol
	}
	return matchTolerance
}

// repetitionFloorPrefix is the labelled block repetitionFloorShortfall's sentence is printed in, or "".
//
// The label travels with the sentence so the caller needs no branch: an empty shortfall yields an empty
// prefix, and prepending that to the report changes nothing. `report` sits at the cyclomatic limit, so one
// `if` at the call site is the difference between a green lint and a red one -- measured at 31 against 30.
func (e *armEvidence) repetitionFloorPrefix(summaries []bench.ArmSummary) string {
	why := e.repetitionFloorShortfall(summaries)
	if why == "" {
		return ""
	}
	return "\nREPETITION FLOOR NOT MET: " + why + "\n"
}

// repetitionFloorShortfall names every arm that carries fewer repetitions than its study registered, or "".
//
// WHY THIS IS NOT A REFUSAL. By the time a report runs, the cells are bought. Declining to print the tables
// would leave the operator with paid evidence and no way to read it, which is worse than reading it with the
// shortfall named -- so this returns a sentence the caller prints beside the tables, in the shape
// RegisteredEstimandFor already uses: say why the registered object is not computable and let the
// measurements stand. The estimand's own refusals still apply independently and are not duplicated here.
//
// WHY A SEPARATE FUNCTION. summarize() has the study and the repetition counts in hand, and putting the
// comparison there was the obvious place. It is also where `report` sits at cyclomatic complexity 30 against
// a limit of 30 -- measured, with FormatReport, Summarize and EvaluateChecks at 30, 30 and 28 beside it --
// so one more branch in any of them turns `make lint` red. That constraint is why this is its own function
// rather than three lines inside the loop.
//
// A study that registered no floor reports nothing, and the comparison itself is what says so: zero means
// the registration did not say, so `RepetitionCount < 0` is false for every arm and no sentence is produced.
//
// TWO GUARDS WERE REMOVED FROM HERE, and saying why is the point. The first version opened with
// `if !ok || study.MinRepetitions == 0 { return "" }` and skipped arms whose `RepetitionCount == 0`, with
// comments calling both of them important. Neither could ever act:
//
//   - A zero floor already produces no sentence, because nothing is less than zero. The explicit return was
//     a second spelling of the same answer.
//   - An arm cannot reach this function with zero repetitions. loadArmEvidence fills repTail and byArm in one
//     loop over the same `e.reps[arm]`, and summarize only builds a summary when byArm has the arm -- so a
//     summary existing means repTail was appended to.
//
// Measured 2026-10-04: deleting both left the five floor tests and the whole package green, which is what
// "unreachable" means operationally. A guard no input can reach is a guard no mutation can test, and this
// repository has already shipped one of those; a comment asserting it matters is worse than its absence,
// because the next reader preserves it.
//
// THE UNREGISTERED-STUDY BRANCH IS UNREACHABLE TOO, and it is kept rather than removed because its two
// siblings keep it. loadArmEvidence refuses an unregistered id outright, and LookupStudy maps the empty id
// to the gateway study, so nothing arrives here with ok false -- measured: replacing this branch with
// `study, _ :=` left the whole package green. What decides its fate is consistency: contendedArms and
// summarize both fall back to StudyM5BGateway at exactly this point, because every raw file written before
// studies existed is M5-b's and a report has to keep reading them. Returning "" here instead would make
// this the one function of the three that answers a different question about the same input.
//
// So it falls back the same way, which also gives the branch an observable effect: the gateway study
// registers a floor of five, so evidence that somehow reached here unregistered is measured against that
// rather than silently waived. That is what makes the branch testable at all.
func (e *armEvidence) repetitionFloorShortfall(summaries []bench.ArmSummary) string {
	study, ok := bench.LookupStudy(e.study)
	if !ok {
		study, _ = bench.LookupStudy(bench.StudyM5BGateway)
	}
	var short []string
	for _, s := range summaries {
		if s.RepetitionCount < study.MinRepetitions {
			short = append(short, fmt.Sprintf("%s has %d", s.Arm, s.RepetitionCount))
		}
	}
	if len(short) == 0 {
		return ""
	}
	return fmt.Sprintf("study %s registered a floor of %d repetitions per arm and %s; its registered point estimate is a median over fewer blocks than the registration fixed",
		study.ID, study.MinRepetitions, strings.Join(short, ", "))
}

// contendedArms are the study's arms that replay the full trace, so their traffic must be identical.
//
// R1 is excluded because it replays the same trace with the contending tenant filtered out, which is what
// makes it a ceiling rather than a condition -- its record count legitimately differs.
//
// Derived from the study rather than listed, because the list used to be three M5-b names and every arm of
// any other experiment therefore skipped the identity check entirely: refuseIfTracesDisagree looked at
// nothing at all for the price-of-protection sweep.
func (e *armEvidence) contendedArms() []string {
	study, ok := bench.LookupStudy(e.study)
	if !ok {
		study, _ = bench.LookupStudy(bench.StudyM5BGateway)
	}
	arms := make([]string, 0, len(study.Arms))
	for _, a := range study.Arms {
		if !bench.IsIsolatedBaseline(a) {
			arms = append(arms, a)
		}
	}
	return arms
}

// summarize builds the per-arm summaries in report order and attaches the repetition shape.
func (e *armEvidence) summarize() ([]bench.ArmSummary, map[string]bench.ArmSummary) {
	// The order is the study's, not four literals.
	//
	// Hard-coded, this dropped nine of the price-of-protection sweep's ten arms on the floor: summarize
	// kept only R1, because that is the one name the two studies share, and the report then complained
	// about arms belonging to an experiment it was not reporting on.
	study, ok := bench.LookupStudy(e.study)
	if !ok {
		study, _ = bench.LookupStudy(bench.StudyM5BGateway)
	}
	order := study.Arms
	var summaries []bench.ArmSummary
	summ := map[string]bench.ArmSummary{}
	for _, arm := range order {
		if rows, ok := e.byArm[arm]; ok {
			s := bench.Summarize(arm, rows)
			// Summarize sees pooled rows and cannot know how they were split, so the repetition shape is
			// attached here where the split is known.
			s.AnyRepetitionCensored = e.repCensored[arm]
			// The worst fraction any repetition served, per tenant. A tenant absent from a repetition was
			// offered nothing there, so that repetition says nothing about its fraction and is skipped --
			// unlike the count, where absence means zero served.
			if reps := e.repServed[arm]; len(reps) > 0 {
				s.WorstRepetitionServedFractionByTenant = map[string]float64{}
				for _, served := range reps {
					for tenant, f := range served {
						if prev, seen := s.WorstRepetitionServedFractionByTenant[tenant]; !seen || f < prev {
							s.WorstRepetitionServedFractionByTenant[tenant] = f
						}
					}
				}
			}
			if tails := e.repTail[arm]; len(tails) > 0 {
				s.RepetitionCount = len(tails)
				s.MinRepetitionTail = slices.Min(tails)
			}
			// The thinnest repetition per tenant, so a floor can be applied where the pool hides it.
			//
			// A tenant MISSING from a repetition counts as zero for that repetition, which is the whole
			// point: a block that served the contender nothing carries no disposition entry for it, and
			// taking the minimum over only the repetitions that mention the tenant would skip exactly the
			// block the floor is looking for.
			if reps := e.repDone[arm]; len(reps) > 0 {
				tenants := map[string]bool{}
				for _, done := range reps {
					for tenant := range done {
						tenants[tenant] = true
					}
				}
				s.MinRepetitionCompletedByTenant = map[string]int{}
				for tenant := range tenants {
					minSeen := -1
					for _, done := range reps {
						n := done[tenant] // zero when this repetition served the tenant nothing
						if minSeen < 0 || n < minSeen {
							minSeen = n
						}
					}
					s.MinRepetitionCompletedByTenant[tenant] = minSeen
				}
			}
			// The per-repetition tails travel with the summary too, because the price-of-protection run's
			// reading 3 needs the CONTROL'S spread as its threshold and a pooled p99 cannot supply it.
			s.RepetitionTTFTMsP99 = append([]float64(nil), e.repP99[arm]...)
			for _, r := range e.reps[arm] {
				s.RepetitionIDs = append(s.RepetitionIDs, r.repID)
			}
			// The pooled span Summarize just computed spans the washouts between repetitions, so replace it
			// with the sum of the repetitions' own spans, which is the time the arm was actually sending.
			if spans := e.repSeconds[arm]; len(spans) > 0 {
				total := 0.0
				for _, v := range spans {
					total += v
				}
				s.SetActiveSeconds(total)
			}
			summaries = append(summaries, s)
			summ[arm] = s
		}
	}
	return summaries, summ
}

// incrementalCI resamples per-repetition C/B ratios, and warns when the repetitions do not line up.
func (e *armEvidence) incrementalCI() bench.CI {
	// The incremental C/B CI resamples per-repetition ratios when both arms have matching repetitions.
	//
	// With a single repetition per arm it degenerates to the point estimate.
	incCI := bench.CI{}
	// The two arms are paired by the repetition identity the runner recorded, not by argument position.
	//
	// This read two slices appended in --raw order and zipped them, so shuffling one arm's files changed
	// which repetitions were compared with no sign that anything had moved. Equal lengths were the only
	// precondition, which is exactly the inference the third 2026-09-30 amendment forbids: {1,2} and {1,3}
	// are both two repetitions.
	bb, cb, why := e.pairedBlocks("static-cap", "kv-aware")
	b, c, _ := e.pairedRepetitions("static-cap", "kv-aware")
	if why != "" {
		// The REASON travels with the refusal, not just the absence of an interval.
		//
		// Leaving the zero CI here made the report print "unequal or insufficient repetitions" for every
		// invalid interval -- the fallback in internal/bench/report.go when InvalidReason is empty -- so a
		// run refused for a censored repetition sent its operator to count repetitions that were fine.
		// CI.InvalidReason exists for exactly this, and its own doc comment says so.
		b, c, bb, cb = nil, nil, nil, nil
		incCI.InvalidReason = why
	}
	if len(bb) == len(cb) && len(bb) > 0 {
		// The amendment's interval: resample whole blocks and recompute the POOLED p99 ratio, which is the
		// quantity the gate's point estimate already used. This was BootstrapCI over per-repetition ratios,
		// whose statistic is their MEAN -- so one gate decided on two different estimands.
		incCI = bench.PairedBlockRatioCI("static-cap", bb, cb,
			bench.M5BIncrementalResamples, bench.M5BIncrementalSeed, 0.05)
		ratios := make([]float64, len(b))
		for i := range b {
			if b[i] > 0 {
				ratios[i] = c[i] / b[i]
			}
		}
		// The scatter refusal is RETAINED across the 2026-10-01 amendment, and its justification did not
		// move with the estimator: cmd/benchharness/power.go models the MEAN of per-repetition ratios, and
		// MaxRatioScatter's own justification is stated against "this package's own BootstrapCI at four
		// repetitions" (internal/bench/report.go). Neither describes the block bootstrap above.
		//
		// So the claim this refusal can carry is narrow: with everything else fixed, the set of runs that
		// PASS with this rule is a subset of those that pass without it, which cannot raise the rate of a
		// false PASS on one fixed experiment. That is the whole of it.
		//
		// What it may NOT be called, and an earlier version of this comment did: a validity boundary for
		// the new interval. A coefficient of variation above 0.15 does not make the paired-block interval
		// invalid, and below it does not make its coverage 95%. Nothing has measured either.
		//
		// Removing it would change the acceptance conditions for evidence already collected, so it stays
		// until a separate dated decision retires or replaces it.
		if bench.RatioScatterTooHigh(ratios) {
			incCI.Valid = false
			// The message says what the rule DOES, not what it establishes about this interval.
			//
			// It used to assert that past this bound a percentile bootstrap "fires on no effect at all more
			// often than its nominal 5 percent". That number was measured against the mean of
			// per-repetition ratios -- the statistic the 2026-10-01 amendment replaced -- so presenting it
			// as the reason this interval is refused carries the old evidence into a new claim. The comment
			// above withdrew that wording and this string kept it, which left the withdrawal unfinished.
			incCI.InvalidReason = fmt.Sprintf("the per-repetition C/B ratios scatter beyond a coefficient of variation of %.2f over %d values, which this study refuses provisionally rather than because the paired-block interval has been shown to misbehave there; the %.2f was placed between false-PASS rates measured for a different statistic (the mean of per-repetition ratios, cmd/benchharness/power.go) and no coverage has been measured for this one", bench.MaxRatioScatter, len(ratios), bench.MaxRatioScatter)
		}
	} else if why != "" && len(e.reps["static-cap"]) > 0 && len(e.reps["kv-aware"]) > 0 {
		// Unequal repetition counts leave the incremental CI at the degenerate point estimate.
		//
		// That would make the CI-upper-bound gate trivially true.
		// Left as a warning here on purpose: the refusal now lives in the checks rather than in this branch.
		//
		// It used to be the ONLY response to unequal repetitions, and it refused nothing -- the caller then
		// passed the zero CI into EvaluateChecks, whose incremental gate reads `Hi < 1.0`, and 0.0 satisfies
		// it. Truncation disarmed the strictest check in the design instead of tripping it. CI.Valid closes
		// that; this line stays so the operator learns WHY the run was refused without reading the code.
		fmt.Fprintf(os.Stderr, "warning: %s;"+
			" no incremental CI will be computed and the comparison will be refused\n", why)
	}
	return incCI
}

// printPrompt writes the exact prompt text a trace row of the given length produces, and nothing else.
//
// It exists so a session can MEASURE with the bytes it will later SEND. The paid run derives its arrival
// rate from one contender prefill against an idle engine, and a prefill's cost is in tokens rather than
// characters -- so measuring with a stand-in payload measures the wrong thing. A run of one character is
// the worst possible stand-in: a byte-pair tokenizer collapses 40,000 of them to about 5,000 tokens where
// the corpus gives 7,695, so the card would look half again faster than it is and the derived rate would
// oversubscribe it.
func printPrompt(args []string) {
	fs := flag.NewFlagSet("print-prompt", flag.ExitOnError)
	chars := fs.Int("chars", 0, "prompt length in characters")
	// The corpus hash, printed so a caller can record WHICH corpus its measurements were taken against.
	//
	// hack/resolve-input-lengths.sh needs it: every token count it measures depends on the corpus bytes, and
	// its table said the corpus was recorded while recording only the tokenizer. Changing promptCorpus would
	// then leave both copies of that table agreeing with each other and disagreeing with reality. Go owns the
	// corpus and its hash, so Go prints it rather than a shell recomputing it from a copy.
	corpusSHA := fs.Bool("corpus-sha", false, "print the prompt corpus sha256 and exit, ignoring --chars")
	if err := fs.Parse(args); err != nil {
		os.Exit(2)
	}
	if *corpusSHA {
		fmt.Println(bench.PromptCorpusSHA256)
		return
	}
	if *chars <= 0 {
		fmt.Fprintln(os.Stderr, "print-prompt: --chars must be positive")
		os.Exit(2)
	}
	fmt.Print(bench.PromptText(*chars))
}

// evaluatePoP scores the price-of-protection readings, or returns nil when the arms they need are absent.
//
// R1 and the control are not optional: every reading is a ratio against one or the other, and a report that
// quietly scored the cells against a missing baseline would produce ratios against zero. Saying so on stderr
// and returning nil puts the run in the "criteria not evaluated" state, which the report already renders
// honestly, rather than inventing a verdict.
func evaluatePoP(summ map[string]bench.ArmSummary, summaries []bench.ArmSummary) *bench.PoPResult {
	r1, haveR1 := summ[bench.ArmR1]
	control, haveControl := summ[bench.ArmDefaultFCFS]
	if !haveR1 || !haveControl {
		fmt.Fprintf(os.Stderr,
			"warning: the price-of-protection readings need both %s and %s and this evidence has %s; no criteria were evaluated\n",
			bench.ArmR1, bench.ArmDefaultFCFS, strings.Join(armNames(summaries), ", "))
		return nil
	}
	var cells []bench.ArmSummary
	for _, s := range summaries {
		if s.Arm != bench.ArmR1 && s.Arm != bench.ArmDefaultFCFS {
			cells = append(cells, s)
		}
	}
	res := bench.EvaluatePriceOfProtection(r1, control, cells, bench.PremiumTenant, bench.NoisyTenant)
	return &res
}

// refusalsBeside reads the arm refusals the runner wrote next to its raw evidence.
//
// Reading 4c is "the sharing mode did not engage", and it distinguishes a RECORDED refusal from an arm that
// is merely absent -- because absence is equally consistent with an interruption or an operator running a
// subset. Until this existed nothing populated that map outside the unit tests, so the one registered
// outcome meant to identify an MPS engagement failure could never fire on evidence the runner produced: the
// reason lived in evidence.log and `report` reads only raw files.
//
// Discovered rather than passed, because a flag an operator must remember is a flag that is forgotten on the
// run that needed it. hack/m5c-matrix.sh writes refused-<arm>.txt into the same directory as the raw files.
func refusalsBeside(rawFiles []string) map[string]string {
	if len(rawFiles) == 0 {
		return nil
	}
	out := map[string]string{}
	seen := map[string]bool{}
	for _, f := range rawFiles {
		dir := filepath.Dir(f)
		if seen[dir] {
			continue
		}
		seen[dir] = true
		matches, err := filepath.Glob(filepath.Join(dir, "refused-*.txt"))
		if err != nil {
			continue
		}
		for _, m := range matches {
			arm := strings.TrimSuffix(strings.TrimPrefix(filepath.Base(m), "refused-"), ".txt")
			b, rerr := os.ReadFile(m)
			if rerr != nil {
				continue
			}
			if why := strings.TrimSpace(string(b)); why != "" {
				out[arm] = why
			}
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// evaluateRegisteredReadings runs whichever study's readings the evidence belongs to, and none of anybody
// else's.
//
// It is one function rather than four branches inside report for a reason worth keeping: a fifth study adds
// a case here and nothing else, and report's job stays "load, evaluate, format, decide the exit code". The
// three checks the M5-b branch names are M5-b's pre-registered comparison. Running them for another
// experiment asked for static-cap and kv-aware, found neither, and reported the run disqualified -- a
// verdict about arms the experiment never had. A study whose readings are not implemented gets its tables
// and a line on stderr saying plainly that no criteria were evaluated, rather than a failure against
// somebody else's.
func evaluateRegisteredReadings(e *armEvidence, summ map[string]bench.ArmSummary, summaries []bench.ArmSummary,
	rawFiles []string, incCI bench.CI, matchTolerance float64,
) (*bench.Checks, *bench.PoPResult, *bench.SharingResult, *bench.LadderResult) {
	switch bench.CanonicalStudyID(e.study) {
	case bench.StudyM5BGateway:
		// Name the arms that are absent, because the refusal downstream cannot: summ is a map, so a missing
		// arm yields the zero ArmSummary and EvaluateChecks disqualifies on its zero TailSampleSize. The
		// refusal WORKS; what it cannot do is say which arm, and that is a bad minute to spend at the end of
		// a paid session.
		var missing []string
		for _, arm := range []string{bench.ArmR1, "static-cap", "kv-aware"} {
			if _, ok := summ[arm]; !ok {
				missing = append(missing, arm)
			}
		}
		if len(missing) > 0 {
			fmt.Fprintf(os.Stderr, "warning: no records for arm(s) %s; the comparison will be disqualified\n",
				strings.Join(missing, ", "))
		}
		evaluated := bench.EvaluateChecks(summ[bench.ArmR1], summ["static-cap"], summ["kv-aware"], incCI, matchTolerance)
		return &evaluated, nil, nil, nil
	case bench.StudyPriceOfProtection:
		return nil, evaluatePoP(summ, summaries), nil, nil
	case bench.StudySharingMatrix:
		return nil, nil, evaluateSharingMatrix(summ, summaries, refusalsBeside(rawFiles), frozenOf(e.study)), nil
	case bench.StudyTailCrossingShortLC, bench.StudyTailCrossingMidLC, bench.StudyTailCrossingLongLC:
		// Their readings are text with no verdict and no exit status, appended by tailCrossingReadings, so
		// there is nothing to return here -- and nothing to warn about either, since they do have readings.
		return nil, nil, nil, nil
	case bench.StudyThroughputLadder, bench.StudyThroughputLadderDown, bench.StudyThroughputLadderIndependent:
		// The ladder takes the summaries rather than the arm map, because its cells are identified by rung
		// and topology parsed out of the arm name and it has to see every one of them -- including arms this
		// study does not name, which it ignores.
		evaluated := bench.EvaluateThroughputLadder(summaries)
		evaluated.Study = bench.CanonicalStudyID(e.study)
		return nil, nil, nil, &evaluated
	default:
		fmt.Fprintf(os.Stderr,
			"warning: study %s has no implemented readings, so this report shows its measurements and evaluates no criteria\n",
			e.study)
		return nil, nil, nil, nil
	}
}

// tailCrossingReadings is the tail-crossing sweep's readings block, or "" for any other study.
//
// A method returning a string rather than another result type in evaluateRegisteredReadings, so that report
// concatenates it instead of branching on it: report sits at the cyclomatic limit `make lint` enforces, and
// a reading with no verdict has no exit status for report to decide on.
func (e *armEvidence) tailCrossingReadings(summaries []bench.ArmSummary) string {
	switch id := bench.CanonicalStudyID(e.study); id {
	case bench.StudyTailCrossingShortLC, bench.StudyTailCrossingMidLC, bench.StudyTailCrossingLongLC:
		return bench.FormatTailCrossing(bench.EvaluateTailCrossing(id, summaries))
	}
	return ""
}

// evaluateSharingMatrix sorts the M5-c evidence into the roles its readings speak about.
//
// R1 and `shared` are required, and their absence is a warning with no readings rather than readings
// computed against a zero ArmSummary. R1 is the denominator of both bars and `shared` is the control every
// improvement is measured from; a zero value for either would make every ratio meaningless in a way that
// still prints a number, which is the failure this file's other evaluator was fixed for.
//
// The sharing arms are taken as whatever else is present, rather than looked up by name. An operator running
// ARMS="shared timeSlicing" gets a matrix with one sharing arm and readings that say so, instead of a
// lookup miss reported as a mode that did not engage.
// frozenOf returns the load tuple the named study's registration froze, or nil when it froze none.
//
// nil rather than an error: a study with no frozen tuple is an ordinary case, and reading 4e reports it as
// an uncomputable gate. Swallowing it here would be the silence this whole change is about.
func frozenOf(study string) *bench.FrozenTuple {
	s, ok := bench.LookupStudy(study)
	if !ok {
		return nil
	}
	return s.Frozen
}

// evaluateSharingMatrix scores the matrix and puts the declared-load gate in FRONT of every reading.
//
// The gate goes first because it is a premise, not a finding. Readings 4 and 4b ask whether the load created
// contention; neither means anything if the load was not the one declared, and a reader meeting them first
// would be reading answers about an unknown trace.
//
// It is attached here rather than inside bench.EvaluateSharingMatrix for two reasons. The frozen tuple
// belongs to the study and that evaluator takes no study. And this wrapper has both of its exits -- the
// missing-baseline refusal and the scored result -- so prepending in one place makes the gate present on
// BOTH, which is what stops it being a check that quietly disappears on the path where the evidence is
// already in doubt.
//
// The ANSWER is cleared when the gate speaks. A verdict printed beside a refusal is read as a verdict.
func evaluateSharingMatrix(summ map[string]bench.ArmSummary, summaries []bench.ArmSummary,
	refused map[string]string, frozen *bench.FrozenTuple,
) *bench.SharingResult {
	res := sharingMatrixReadings(summ, summaries, refused)
	declared := bench.EvaluateDeclaredLoad(summaries, frozen, bench.PremiumTenant, bench.NoisyTenant)
	res.Readings = append([]bench.PoPReading{declared}, res.Readings...)
	if declared.Fired || declared.NotEvaluable {
		res.Answer = ""
	}
	return res
}

func sharingMatrixReadings(summ map[string]bench.ArmSummary, summaries []bench.ArmSummary, refused map[string]string) *bench.SharingResult {
	// A missing baseline or control is REPORTED as an uncomputable gate, not returned as nil.
	//
	// Returning nil printed a warning to stderr and left `sharing` unset, so the verdict block never ran and
	// `report` exited zero -- and the paid runner calls it as `benchharness report ... || fail`. The
	// evaluator carries the same refusal for its own callers, and that one is unreachable from here because
	// this function stops first: the fix belonged in both places and was put in only one.
	r1, haveR1 := summ[bench.ArmR1]
	shared, haveShared := summ[bench.ArmShared]
	if !haveR1 || !haveShared {
		want := bench.ArmR1
		why := "the isolated baseline both bars divide by"
		if haveR1 {
			want, why = bench.ArmShared, "the control every improvement is measured from"
		}
		return &bench.SharingResult{Readings: []bench.PoPReading{{
			ID: "4", Name: "the load did not create contention -- INVALID", NotEvaluable: true,
			Detail: fmt.Sprintf("this evidence carries %s and no %s arm, which is %s; nothing below can be scored without it",
				strings.Join(armNames(summaries), ", "), want, why),
		}}}
	}
	arms := bench.SharingArms{R1: r1, Shared: shared, Refused: refused}
	for _, s := range summaries {
		if s.Arm != bench.ArmR1 && s.Arm != bench.ArmShared {
			arms.Sharing = append(arms.Sharing, s)
		}
	}
	res := bench.EvaluateSharingMatrix(arms, bench.PremiumTenant, bench.NoisyTenant)
	return &res
}

func armNames(summaries []bench.ArmSummary) []string {
	names := make([]string, 0, len(summaries))
	for _, s := range summaries {
		names = append(names, s.Arm)
	}
	return names
}

// sharingRunInvalid reports the error that must end the process, or nil when the run stands.
//
// Reading 4c is deliberately NOT in this list, and matching on the word INVALID used to put it there.
//
// 4 and 4b invalidate the RUN: they say the trace, not the topology, is what has to change, and nothing
// measured under them means anything. 4c invalidates ONE ARM -- its name ends "INVALID for that arm" --
// and the arm beside it was still measured and still paid for. Name matching could not tell those apart,
// so a refused MPS arm made `benchharness report ... || fail` reject a run whose time-slicing arm had
// produced a result. That is the expected case for this study rather than a corner: MPS has already been
// measured failing to engage on this AMI. The IDs are listed explicitly so an exit status turns on which
// reading fired rather than on how it was worded.
//
// A named function rather than a condition inside report(), because a rule that was wrong once should be
// reachable from a test, and inline in a command that wants files on disk it is not.
func sharingRunInvalid(res bench.SharingResult) error {
	for _, r := range res.Readings {
		if r.Fired && (r.ID == "4" || r.ID == "4b" || r.ID == "4d" || r.ID == "4e") {
			return fmt.Errorf("run invalid: reading %s fired -- %s", r.ID, r.Detail)
		}
		// A GATE that could not be computed is also not a run that stands.
		//
		// 4 and 4b are prerequisites: they ask whether the evidence can be assessed at all. When one of them
		// comes back NotEvaluable the answer is "we could not tell", and this returned nil -- so a control
		// whose premium tail is censored printed a report with no verdict, no answer and exit status zero,
		// and `benchharness report ... || fail` accepted it as a successful run. Reproduced by an
		// independent review with 2% premium timeouts in the control.
		//
		// Only the GATES. A reading below them coming back NotEvaluable is an ordinary "no finding here".
		//
		// 4d is a gate too, and the newest one. It says the PLAN could not produce a verdict rather than
		// that this evidence failed to: readings 1, 2, 3 and 5 stay in the list as ordinary non-findings,
		// and 4d is what turns the exit status. Without it a run that evaluated nothing exited zero --
		// 2026-10-01, ten cells and $1.44.
		if r.NotEvaluable && (r.ID == "4" || r.ID == "4b" || r.ID == "4d" || r.ID == "4e") {
			return fmt.Errorf("run invalid: reading %s could not be evaluated -- %s", r.ID, r.Detail)
		}
	}
	return nil
}
