package bench

import (
	"fmt"
	"math"
)

// SamplingPolicy is a study's frozen generation behaviour: what every request asks the engine to do with its logits and its stop condition.
//
// The trace seed fixes which requests arrive when; it says nothing about what the engine generates.
// A request that names no sampling parameter gets the engine's defaults, and since vLLM began reading the model's
// generation_config those defaults are Qwen2.5's temperature 0.7, top_p 0.8 and repetition_penalty 1.05, applied or not
// depending on the version (audit finding 12).
// A version comparison that left them implicit could be measuring a change of sampler rather than of scheduler.
//
// The sender consumes this through RequestFields and the preflight through CheckCompletion; see the version study's spec.
type SamplingPolicy struct {
	// Temperature 0 is greedy decoding, which makes the output independent of any random state.
	Temperature float64 `json:"temperature"`
	// TopP is sent explicitly so the model's generation_config cannot substitute its own.
	TopP float64 `json:"topP"`
	// RepetitionPenalty is sent because it changes logits even under greedy decoding, unlike top_p and top_k.
	RepetitionPenalty float64 `json:"repetitionPenalty"`
	// Seed says what, if anything, goes in the request's seed field.
	Seed SeedPolicy `json:"seedPolicy"`
	// IgnoreEOS asks the engine not to stop at end-of-sequence.
	IgnoreEOS bool `json:"ignoreEos"`
	// Length says how a request's output length is decided.
	Length LengthPolicy `json:"lengthPolicy"`
}

// SeedPolicy names what a request sends as its sampling seed.
type SeedPolicy string

const (
	// SeedOmitGreedy sends no seed, and is valid only with temperature 0.
	//
	// Greedy output does not depend on a seed, and a per-request seed makes some engine versions build a
	// per-request generator, which would be a performance treatment of its own.
	SeedOmitGreedy SeedPolicy = "omit-greedy"
	// SeedRowIndex sends the trace row's index, so every arm draws the same random stream for the same request.
	SeedRowIndex SeedPolicy = "row-index"
)

// LengthPolicy names how a request's output length is decided.
type LengthPolicy string

const (
	// LengthExactCap makes every request produce exactly its trace cap: min_tokens and max_tokens both equal it and EOS is ignored.
	//
	// The output length is then a property of the workload, identical across arms, rather than of what each engine version generated.
	LengthExactCap LengthPolicy = "exact-cap"
	// LengthNaturalStop lets the model stop at end-of-sequence before the cap.
	LengthNaturalStop LengthPolicy = "natural-stop"
)

// versionStudySampling is the version study's registered policy; the spec gives the reasons for each value.
func versionStudySampling() *SamplingPolicy {
	return &SamplingPolicy{
		Temperature:       0,
		TopP:              1,
		RepetitionPenalty: 1,
		Seed:              SeedOmitGreedy,
		IgnoreEOS:         true,
		Length:            LengthExactCap,
	}
}

// Validate refuses a policy whose fields contradict each other or the engine's accepted ranges.
func (p SamplingPolicy) Validate() error {
	finite := func(x float64) bool { return !math.IsNaN(x) && !math.IsInf(x, 0) }
	switch {
	case !finite(p.Temperature) || p.Temperature < 0:
		return fmt.Errorf("temperature %v is not a finite non-negative number", p.Temperature)
	case !finite(p.TopP) || p.TopP <= 0 || p.TopP > 1:
		return fmt.Errorf("top_p %v is outside (0, 1]", p.TopP)
	case !finite(p.RepetitionPenalty) || p.RepetitionPenalty <= 0:
		return fmt.Errorf("repetition_penalty %v is not a finite positive number", p.RepetitionPenalty)
	}
	switch p.Seed {
	case SeedOmitGreedy:
		if p.Temperature != 0 {
			return fmt.Errorf("seed policy %q needs temperature 0; random sampling without a seed is not reproducible across arms", p.Seed)
		}
	case SeedRowIndex:
	default:
		return fmt.Errorf("seed policy %q is not one of %q, %q", p.Seed, SeedOmitGreedy, SeedRowIndex)
	}
	switch p.Length {
	case LengthExactCap:
		if !p.IgnoreEOS {
			return fmt.Errorf("length policy %q needs ignore_eos, or an engine that stops at EOS shortens the workload", p.Length)
		}
	case LengthNaturalStop:
		if p.IgnoreEOS {
			return fmt.Errorf("length policy %q contradicts ignore_eos", p.Length)
		}
	default:
		return fmt.Errorf("length policy %q is not one of %q, %q", p.Length, LengthExactCap, LengthNaturalStop)
	}
	return nil
}

// SamplingRequestFields are the generation fields of one chat-completions body, in the engine's own names.
//
// A sender marshals these into the body in place of its own max_tokens and min_tokens, so the policy is the one source of both.
type SamplingRequestFields struct {
	MaxTokens         int     `json:"max_tokens"`
	MinTokens         int     `json:"min_tokens,omitempty"`
	Temperature       float64 `json:"temperature"`
	TopP              float64 `json:"top_p"`
	RepetitionPenalty float64 `json:"repetition_penalty"`
	Seed              *int64  `json:"seed,omitempty"`
	IgnoreEOS         bool    `json:"ignore_eos"`
}

// RequestFields returns the fields one trace row is sent with, or an error for an invalid policy or a row without a cap.
func (p SamplingPolicy) RequestFields(row TraceRow) (SamplingRequestFields, error) {
	if err := p.Validate(); err != nil {
		return SamplingRequestFields{}, err
	}
	if row.MaxOutputTokens <= 0 {
		return SamplingRequestFields{}, fmt.Errorf("trace row %d has output cap %d; a request needs a positive cap", row.Index, row.MaxOutputTokens)
	}
	f := SamplingRequestFields{
		MaxTokens:         row.MaxOutputTokens,
		Temperature:       p.Temperature,
		TopP:              p.TopP,
		RepetitionPenalty: p.RepetitionPenalty,
		IgnoreEOS:         p.IgnoreEOS,
	}
	if p.Length == LengthExactCap {
		f.MinTokens = row.MaxOutputTokens
	}
	if p.Seed == SeedRowIndex {
		f.Seed = new(int64(row.Index))
	}
	return f, nil
}

// CheckCompletion says whether one completed request shows the policy took effect, from the engine's own usage and finish reason.
//
// A zero token count is the usage chunk missing, which is refused: the policy cannot be shown to have held without it.
func (p SamplingPolicy) CheckCompletion(capTokens, engineOutputTokens int, finishReason string) error {
	if engineOutputTokens <= 0 {
		return fmt.Errorf("no engine usage count, so the output length cannot be checked")
	}
	if finishReason == "" {
		return fmt.Errorf("no finish reason, so the stop condition cannot be checked")
	}
	switch p.Length {
	case LengthExactCap:
		if engineOutputTokens != capTokens || finishReason != "length" {
			return fmt.Errorf("output %d tokens with finish reason %q; the exact-cap policy requires %d and \"length\"",
				engineOutputTokens, finishReason, capTokens)
		}
	case LengthNaturalStop:
		if engineOutputTokens > capTokens {
			return fmt.Errorf("output %d tokens exceeds the cap %d", engineOutputTokens, capTokens)
		}
	default:
		return fmt.Errorf("length policy %q is not registered", p.Length)
	}
	return nil
}
