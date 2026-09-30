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

package bench

import (
	"fmt"
	"sort"
	"strconv"
	"strings"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// CompilePlan turns a GpuSharingBenchmark spec into the harness invocation that would measure it, or refuses.
//
// WHY THIS EXISTS, and why it runs before a card is rented. `spec` is immutable once created, so registering a
// CR whose protocol this harness cannot execute freezes an unexecutable registration forever. And a paid run
// that discovers a mismatch does so after both engines have loaded -- the most expensive place to learn it.
// An external review of the intended design put it plainly: a receipt cannot repair running the wrong
// experiment, so unsupported values must fail before registration or rental.
//
// WHAT IT IS NOT. This does not check that the numbers are right, that a GPU was present, or that the run
// happened. It answers one question: can this harness, as it stands, execute this declared protocol. A clean
// compile is a necessary condition for the evidence to mean what the CR says, never a sufficient one.
//
// The refusals below are measured against the tree, not assumed. Each carries the reason in its text, because
// an operator reading "unsupported" without the reason has to go and find what this function already knew.
func CompilePlan(spec platformv1.GpuSharingBenchmarkSpec) (Plan, error) {
	var p Plan
	var refusals []string
	refuse := func(format string, args ...any) { refusals = append(refusals, fmt.Sprintf(format, args...)) }

	// Tenants. The generator writes two fixed identities into every trace row.
	//
	// The gateway resolves a tenant to a tier through its own policy chain, so a CR naming other identities is
	// not merely cosmetic: the rows would carry identities the run never sent, and the premium-only tail would
	// be computed over the wrong side.
	if spec.Baseline.Tenant != PremiumTenant {
		refuse("baseline.tenant is %q; the trace generator writes the fixed identity %q and nothing passes another",
			spec.Baseline.Tenant, PremiumTenant)
	}
	if spec.Contender.Tenant != NoisyTenant {
		refuse("contender.tenant is %q; the trace generator writes the fixed identity %q and nothing passes another",
			spec.Contender.Tenant, NoisyTenant)
	}

	// Model. The gateway resolves the requested name against the InferenceDeployment index and answers
	// ErrNoRoute when nothing serves it -- after both engines have loaded, which is why this is checked here.
	for _, w := range []struct {
		side  string
		model string
	}{{"baseline", spec.Baseline.Model}, {"contender", spec.Contender.Model}} {
		if w.model != ServedModel {
			refuse("%s.model is %q; the sharing topologies serve %q, and the gateway answers ErrNoRoute for any other name once the engines are up",
				w.side, w.model, ServedModel)
		}
	}

	// Output length. The generator hard-codes a MAXIMUM per tenant and sends it as max_tokens, which is a cap
	// rather than a generation length: a CR asking for 128 output tokens would receive at most 64, and a
	// response that stops early is shorter still.
	if int(spec.Baseline.OutputTokens) != FixedPremiumMaxOutputTokens {
		refuse("baseline.outputTokens is %d; the generator fixes the premium cap at %d and sends it as an upper bound, not a generation length",
			spec.Baseline.OutputTokens, FixedPremiumMaxOutputTokens)
	}
	if int(spec.Contender.OutputTokens) != FixedNoisyMaxOutputTokens {
		refuse("contender.outputTokens is %d; the generator fixes the contender cap at %d and sends it as an upper bound, not a generation length",
			spec.Contender.OutputTokens, FixedNoisyMaxOutputTokens)
	}

	// Warmup. There is no warmup phase and no exclusion boundary anywhere in the harness.
	//
	// Dropping the first N rows afterwards is not equivalent: the protocol says warmup precedes measurement,
	// and with open-loop arrivals the requests that overlap the boundary are still in flight when measurement
	// begins. Zero is representable; any positive value is not.
	if spec.WarmupRequests != 0 {
		refuse("warmupRequests is %d; the harness has no warmup phase and no exclusion boundary, so a positive value cannot be honoured (dropping rows afterwards is not the same protocol)",
			spec.WarmupRequests)
	}

	// Sample floor. The harness has its own floor, derived rather than chosen, and it is ten times smaller.
	if int(spec.MinRequestsPerRun) < MinTailSamples {
		refuse("minRequestsPerRun is %d, below the harness floor of %d", spec.MinRequestsPerRun, MinTailSamples)
	}

	// Load protocol.
	if spec.Load.Mode != "openLoop" {
		refuse("load.mode is %q; Replay dispatches each request at its scheduled offset without waiting for earlier responses, which is openLoop and nothing else",
			spec.Load.Mode)
	}
	if spec.Load.Retries != 0 {
		refuse("load.retries is %d; the sender makes one call per logical request and never resubmits, so a positive value cannot be honoured",
			spec.Load.Retries)
	}
	if !spec.Load.Streaming {
		refuse("load.streaming is false; the sender reads server-sent events to time the first token, and a non-streaming response has no first-token time to measure")
	}
	if spec.Load.Generator != HarnessGenerator {
		refuse("load.generator is %q; the run would be driven by %q, and a manifest naming a generator that did not produce the traffic is provenance for the wrong tool",
			spec.Load.Generator, HarnessGenerator)
	}

	// Input length. The CR declares tokens; the generator takes characters; the table says which is which.
	//
	// This refused every positive count until 2026-09-30, on the grounds that there was nothing to resolve
	// against -- no tokenizer identity was recorded anywhere. There is now: the revision is measured, the
	// tokenizer files and chat template are hashed, and hack/resolve-input-lengths.sh sweeps candidate
	// lengths against the served tokenizer inside the serving image itself. So the refusal narrowed from
	// "any positive count" to "a count nobody has swept".
	//
	// Zero is the one value that asserts nothing, so it is the one value that needs no resolution: it means
	// the plan carries no token length, not a prompt of no tokens.
	//
	// Any positive count is looked up in the measured table. It is a LOOKUP and never a computation, because
	// the relationship is not a function of anything this code knows: it depends on the served tokenizer and
	// its chat template, the token count is not monotone in the character count, and several character
	// lengths give the same count. A value the table does not carry is refused, and the refusal says which
	// values it does carry so the answer is "run the resolver for 4096" rather than "something is wrong".
	var baseChars, contChars int
	for _, w := range []struct {
		side   string
		tokens int32
		out    *int
	}{
		{"baseline", spec.Baseline.InputTokens, &baseChars},
		{"contender", spec.Contender.InputTokens, &contChars},
	} {
		if w.tokens == 0 {
			continue
		}
		r, ok := ResolveInputTokens(int(w.tokens))
		if !ok {
			refuse("%s.inputTokens is %d, which the measured resolution table does not carry; it holds %v. The generator is configured in CHARACTERS and no formula inverts the token count -- run hack/resolve-input-lengths.sh %d to sweep it against the served tokenizer and add the entry",
				w.side, w.tokens, ResolvedInputTokenCounts(), w.tokens)
			continue
		}
		*w.out = r.Chars
	}

	// Repetitions. Expressible, and the two runners disagree with the CRD about what a confirmatory run is, so
	// the resolved value is carried in the plan rather than left to a default.
	if spec.Repetitions < 5 {
		refuse("repetitions is %d; the CRD floor is 5", spec.Repetitions)
	}

	// Sharing mode to arms. The topologies are deployed by the shell, and two of them change the victim's own
	// allocation, so the mode decides which contrast the ratio is of.
	arms, ok := ArmsForSharingMode(spec.SharingMode)
	if !ok {
		refuse("sharingMode is %q; the matrix deploys %s and nothing else", spec.SharingMode, strings.Join(KnownSharingModes(), ", "))
	}

	if len(refusals) > 0 {
		sort.Strings(refusals)
		return Plan{}, fmt.Errorf("this GpuSharingBenchmark cannot be executed by this harness:\n  - %s",
			strings.Join(refusals, "\n  - "))
	}

	p = Plan{
		Arms:                 arms,
		Repetitions:          int(spec.Repetitions),
		SharingMode:          spec.SharingMode,
		Model:                ServedModel,
		PremiumRate:          spec.Baseline.QPS,
		ContenderRate:        spec.Contender.QPS,
		TimeoutMs:            int(spec.Load.TimeoutMs),
		BaselinePromptChars:  baseChars,
		ContenderPromptChars: contChars,
		TokenizerRevision:    InputLengthTokenizerRevision,
	}
	return p, nil
}

// Plan is the resolved harness invocation a compiled spec describes.
//
// It deliberately holds the rates as the decimal STRINGS the CR carries. The CRD stores them as strings so
// that "2.0" round-trips exactly, and parsing them here only to print them again would introduce a float
// whose rendering could differ from the registered value.
type Plan struct {
	Arms        []string
	Repetitions int
	// SharingMode is the declared mode, and Model is the name the run will actually request.
	//
	// They are separate fields because they were briefly one: the first version of this struct had a single
	// Model and CompilePlan assigned the sharing mode to it. Nothing would have caught that -- both are
	// strings, and the plan is printed rather than compared -- so a plan would have named "sharedInstance" as
	// the model it asked the gateway for.
	SharingMode   string
	Model         string
	PremiumRate   string
	ContenderRate string
	TimeoutMs     int
	// BaselinePromptChars and ContenderPromptChars are the RESOLVED prompt lengths, in characters.
	//
	// This is the whole point of the plan carrying more than the spec does. The CR declares tokens; the
	// generator takes characters; the plan holds the character length that was MEASURED to produce the
	// declared token count against the served tokenizer. Zero means the side declared no token length.
	//
	// An external review put the boundary well: a character length belongs in the plan, not in the CR --
	// the spec says what the experiment is, and how many characters produce a token count under one
	// particular tokenizer is an implementation of that declaration.
	BaselinePromptChars  int
	ContenderPromptChars int
	// TokenizerRevision is the revision the resolution was measured against.
	//
	// Carried so a run can be compared with it. A plan resolved against one tokenizer describes nothing
	// about an engine serving another, and the comparison is the only thing that can notice.
	TokenizerRevision string
}

// ServedModel is the model the sharing topologies actually serve.
//
// config/vllm-shared/engine-a.yaml passes Qwen/Qwen2.5-3B-Instruct and hack/m5c-matrix.sh passes the same
// name to gen-trace. The generator's own default is llama-3-8b, which matches neither, and a mismatch is not
// discovered until the gateway answers ErrNoRoute for every request of every arm with both engines loaded.
const ServedModel = "Qwen/Qwen2.5-3B-Instruct"

// FixedPremiumMaxOutputTokens and FixedNoisyMaxOutputTokens are the caps the generator hard-codes per tenant.
const (
	FixedPremiumMaxOutputTokens = 64
	FixedNoisyMaxOutputTokens   = 16
)

// HarnessGenerator names the load generator that actually sends the traffic.
//
// The CR's samples say genai-perf, which is not installed here and is not what any run has used. A manifest
// recording a generator that did not produce the traffic identifies the wrong tool, which is worse than
// recording none.
const HarnessGenerator = "benchharness-replay"

// ArmsForSharingMode maps a declared sharing mode to the arms a run must buy for it, isolated baseline first.
//
// sharedInstance is the only mode whose ratio is contender-presence with everything else held: R1 and shared
// are the same single whole-card engine and differ only in the trace, which gen-trace builds by filtering the
// contender out of the SAME trace so the victim arrives on an identical schedule. timeSlicing and mps put two
// engines on half a card each, so their ratio against R1 also carries the topology and allocation change.
// That is a different registered question, not the same one on different hardware.
func ArmsForSharingMode(mode string) ([]string, bool) {
	switch mode {
	case "sharedInstance":
		return []string{"R1", "shared"}, true
	case "timeSlicing":
		return []string{"R1", "timeSlicing"}, true
	case "mps":
		return []string{"R1", "mps"}, true
	default:
		return nil, false
	}
}

// KnownSharingModes lists the modes ArmsForSharingMode accepts, for a refusal that names the alternatives.
func KnownSharingModes() []string {
	return []string{"sharedInstance", "timeSlicing", "mps"}
}

// FormatPlan renders a compiled plan as the environment a paid run would be launched with.
//
// The defaults are deliberately absent. hack/m5c-gpu-session.sh supplies RATE=9.85, NOISY_WEIGHT=0.054 and
// DURATION_MS=420000 when they are omitted, and the sharing study's own pre-registration records that tuple
// as the seventh pilot's load, the one its reading rejected -- "about as wrong as a run can be while still
// completing". So a plan that leaves them out is a plan that buys the wrong load, and this prints them as
// values the caller must supply rather than pretending to know them.
func FormatPlan(p Plan) string {
	var b strings.Builder
	b.WriteString("ARMS=" + strconv.Quote(strings.Join(p.Arms, " ")) + " \\\n")
	b.WriteString("REPS=" + strconv.Itoa(p.Repetitions) + " \\\n")
	b.WriteString("  # RATE, PREMIUM_WEIGHT, NOISY_WEIGHT, PROBE_WEIGHT and DURATION_MS are NOT defaulted here:\n")
	b.WriteString("  # the wrapper's own defaults are the load its pre-registration rejected. Derive them on the card.\n")
	b.WriteString("  # declared victim qps " + p.PremiumRate + ", contender qps " + p.ContenderRate + "\n")
	return b.String()
}
