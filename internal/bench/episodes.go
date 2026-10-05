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
	"math/rand/v2"
	"slices"
	"sort"
	"strings"
)

// The instrument-validation study replays EPISODES rather than a Poisson stream.
// Its clock in section 3 of docs/superpowers/specs/2026-10-05-can-the-stock-engine-time-an-iteration-instrument-validation.md
// attributes engine log lines to requests by order, which is only possible when the composition of every step is known by construction.
// So each episode is a fixed set of requests sent into a drained engine, and nothing else is in flight.

// EpisodeType is one of the three episode shapes the registration buys.
type EpisodeType string

const (
	// EpisodeSerial is one request at a time.
	EpisodeSerial EpisodeType = "serial"
	// EpisodeBurst is a homogeneous group of requests sent at one instant.
	EpisodeBurst EpisodeType = "burst"
	// EpisodeStagger is a group of decoders followed by one prefill introduced while they decode.
	EpisodeStagger EpisodeType = "stagger"
)

// EpisodeTypes lists the shapes in the order the study's arms are named.
var EpisodeTypes = []EpisodeType{EpisodeSerial, EpisodeBurst, EpisodeStagger}

// EpisodeCycles is how many complete cycles one trace holds.
// Fixed rather than filled to a duration, so every trace contains every registered setting the same number of times and a short cell cannot silently omit one.
const EpisodeCycles = 3

// The registered factor levels, in input tokens.
// They are tokens, not characters, and are resolved through the measured table at generation time so that no character count is ever computed here.
var (
	serialLengths     = []int{256, 512, 1024, 2048, 4096, 8192}
	serialCaps        = []int{1, 16, 64}
	burstSizes        = []int{1, 4, 16}
	burstLengths      = []int{256, 2048, 8192}
	staggerDecoders   = []int{1, 4, 16}
	staggerContexts   = []int{256, 8192}
	staggerPrefills   = []int{256, 8192}
	staggerLagMs      = int64(200)
	burstCap          = 64
	staggerDecodeCap  = 128
	staggerPrefillCap = 16
	// The one heterogeneous burst: 64 concurrent at 256 tokens fills max-num-seqs, which no other setting reaches.
	burstWideSize   = 64
	burstWideLength = 256
)

// The spacing bound's constants, taken from the archives on the A10G.
// About 260 ms per 2,048-token prefill chunk and 15 to 25 ms per decode step were measured; both are rounded up so the bound errs towards a longer gap.
const (
	spacingChunkTokens     = 2048
	spacingMsPerChunk      = 270
	spacingMsPerDecodeStep = 30
	spacingMinGapMs        = 2000
)

// EpisodeSpacingMs is the gap from an episode's first send to the next episode's first send.
//
// It is a SPACING BOUND, not a prediction of how long the episode takes.
// It is deliberately conservative, twice a pessimistic estimate and never under two seconds, because its only job is to make overlap between episodes unlikely.
// Whether each episode actually ran drained is verified afterwards from the engine log, where the attribution refuses any overlap.
// So a bound that turns out too short costs a refused episode, never a wrongly attributed one.
func EpisodeSpacingMs(totalPrefillTokens, maxOutputCap int) int64 {
	chunks := (totalPrefillTokens + spacingChunkTokens - 1) / spacingChunkTokens
	est := int64(chunks*spacingMsPerChunk + maxOutputCap*spacingMsPerDecodeStep)
	return max(int64(spacingMinGapMs), 2*est)
}

// episodeRequest is one request of an episode, in tokens, at an offset from the episode's first send.
type episodeRequest struct {
	tokens int
	cap    int
	atMs   int64
}

// episodeSpec is one registered setting: the requests it sends, all known before the run.
type episodeSpec []episodeRequest

// gapMs applies the spacing bound to the whole episode, every request's prefill and the largest cap.
func (e episodeSpec) gapMs() int64 {
	total, maxCap := 0, 0
	for _, r := range e {
		total += r.tokens
		maxCap = max(maxCap, r.cap)
	}
	return EpisodeSpacingMs(total, maxCap)
}

// lastAtMs is the latest send inside the episode, which is zero for every shape but the stagger.
func (e episodeSpec) lastAtMs() int64 {
	var last int64
	for _, r := range e {
		last = max(last, r.atMs)
	}
	return last
}

// signature names an episode by its contents, so a reader of a finished trace can count settings without knowing the order.
func (e episodeSpec) signature() string {
	parts := make([]string, len(e))
	for i, r := range e {
		parts[i] = fmt.Sprintf("%d/%d@%d", r.tokens, r.cap, r.atMs)
	}
	return strings.Join(parts, " ")
}

// homogeneous returns n identical requests sent at one instant.
func homogeneous(n, tokens, outCap int) episodeSpec {
	e := make(episodeSpec, n)
	for i := range e {
		e[i] = episodeRequest{tokens: tokens, cap: outCap}
	}
	return e
}

// cycleOf lists one cycle's settings in a fixed enumeration order, before the seeded permutation.
func cycleOf(t EpisodeType) ([]episodeSpec, error) {
	var out []episodeSpec
	switch t {
	case EpisodeSerial:
		for _, l := range serialLengths {
			for _, c := range serialCaps {
				out = append(out, homogeneous(1, l, c))
			}
		}
	case EpisodeBurst:
		for _, n := range burstSizes {
			for _, l := range burstLengths {
				out = append(out, homogeneous(n, l, burstCap))
			}
		}
		out = append(out, homogeneous(burstWideSize, burstWideLength, burstCap))
	case EpisodeStagger:
		for _, n := range staggerDecoders {
			for _, c := range staggerContexts {
				for _, p := range staggerPrefills {
					e := homogeneous(n, c, staggerDecodeCap)
					// The prefill waits for the decoders' own prefill to finish, by the same pessimistic chunk estimate, so it meets them decoding rather than queued.
					lag := int64((n*c+spacingChunkTokens-1)/spacingChunkTokens*spacingMsPerChunk) + staggerLagMs
					out = append(out, append(e, episodeRequest{tokens: p, cap: staggerPrefillCap, atMs: lag}))
				}
			}
		}
	default:
		return nil, fmt.Errorf("episode type %q is not registered; the registered types are %v", t, EpisodeTypes)
	}
	return out, nil
}

// plannedRequest is one request of a planned trace, in tokens, at its absolute offset.
type plannedRequest struct {
	offsetMs int64
	tokens   int
	cap      int
}

// planEpisodes lays out EpisodeCycles cycles, each in its own seeded order, and returns the span a replay needs.
//
// The span is the last row's offset plus its episode's gap, which for a stagger is longer than the episode-start sum by the prefill's lag.
// It is the longer of the two on purpose, because a duration that only covers the shorter one would end the cell while the last prefill is still running.
//
// The seed is the only input besides the type.
// The arm's logging or async suffix never reaches this function, which is what makes the on, off and async arms of one repetition replay byte-identical traces.
func planEpisodes(seed int64, t EpisodeType) ([]plannedRequest, int64, error) {
	cycle, err := cycleOf(t)
	if err != nil {
		return nil, 0, err
	}
	rng := rand.New(rand.NewPCG(uint64(seed), uint64(seed)^0x9e3779b97f4a7c15))
	var out []plannedRequest
	var start, span int64
	for range EpisodeCycles {
		for _, i := range rng.Perm(len(cycle)) {
			e := cycle[i]
			for _, r := range e {
				out = append(out, plannedRequest{offsetMs: start + r.atMs, tokens: r.tokens, cap: r.cap})
			}
			span = start + e.lastAtMs() + e.gapMs()
			start += e.gapMs()
		}
	}
	return out, span, nil
}

// registeredLengths lists every input length a type's cycle uses, ascending.
func registeredLengths(t EpisodeType) []int {
	cycle, _ := cycleOf(t)
	var out []int
	for _, e := range cycle {
		for _, r := range e {
			if !slices.Contains(out, r.tokens) {
				out = append(out, r.tokens)
			}
		}
	}
	slices.Sort(out)
	return out
}

// EpisodeTraceParams are the inputs GenerateEpisodeTrace turns into a trace.
type EpisodeTraceParams struct {
	// Seed orders each cycle; one repetition's arms share it.
	Seed int64
	// DurationMs is the cell's replay budget, which must hold the whole trace.
	DurationMs int64
	// Type is the episode shape, taken from the arm by InstrumentValidationEpisode.
	Type EpisodeType
}

// GenerateEpisodeTrace builds EpisodeCycles complete cycles of one episode type for the premium tenant alone.
//
// It refuses rather than truncates when DurationMs cannot hold the trace, because a trace missing its last settings would be a cell that silently did not measure them.
// It refuses when any registered length has no measured character count, before laying anything out, so a short trace cannot pass by happening not to draw the missing one.
func GenerateEpisodeTrace(p EpisodeTraceParams) ([]TraceRow, error) {
	if _, err := cycleOf(p.Type); err != nil {
		return nil, err
	}
	var missing []int
	chars := map[int]int{}
	for _, l := range registeredLengths(p.Type) {
		r, ok := ResolveInputTokens(l)
		if !ok {
			missing = append(missing, l)
			continue
		}
		chars[l] = r.Chars
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("the %s episodes register input lengths %v and the measured resolution table carries no character count for %v (it carries %v); run hack/resolve-input-lengths.sh for them rather than estimating one",
			p.Type, registeredLengths(p.Type), missing, ResolvedInputTokenCounts())
	}
	plan, span, err := planEpisodes(p.Seed, p.Type)
	if err != nil {
		return nil, err
	}
	if p.DurationMs < span {
		return nil, fmt.Errorf("the %s trace is %d complete cycles spanning %d ms and the duration is %d ms; the cell has to hold every cycle, so pass at least %d",
			p.Type, EpisodeCycles, span, p.DurationMs, span)
	}
	rows := make([]TraceRow, len(plan))
	for i, r := range plan {
		rows[i] = TraceRow{
			Index:           i,
			OffsetMs:        r.offsetMs,
			Tenant:          PremiumTenant,
			PromptLenChars:  chars[r.tokens],
			MaxOutputTokens: r.cap,
		}
	}
	return rows, nil
}

// EpisodeTraceRefusal says whether a trace is one this episode type's registration can score.
//
// The tail studies' sample floors do not apply: the estimands here are per-episode timings, not a p99, and a trace is complete when it holds its cycles.
// The checks are ordered from the most basic to the most specific, so a refusal names the first thing wrong rather than a consequence of it.
func EpisodeTraceRefusal(t EpisodeType, rows []TraceRow) error {
	cycle, err := cycleOf(t)
	if err != nil {
		return err
	}
	if len(rows) == 0 {
		return fmt.Errorf("the trace has no rows, so there is nothing to replay and nothing to attribute")
	}
	for _, r := range rows {
		if r.Tenant != PremiumTenant || r.IsNoisy {
			return fmt.Errorf("row %d is tenant %q (isNoisy=%v) and the study is single-tenant %s with no contender; any other request would share the engine's steps and break attribution by order",
				r.Index, r.Tenant, r.IsNoisy, PremiumTenant)
		}
	}

	// Lengths and caps are checked against the UNION of the three types first.
	// A value no type registers is a malformed trace, and a value another type registers is a trace built for a different arm; the two are named differently because they are fixed differently.
	tokensOf := map[int]int{}
	anyCap := map[int]bool{}
	for _, et := range EpisodeTypes {
		c, _ := cycleOf(et)
		for _, e := range c {
			for _, r := range e {
				anyCap[r.cap] = true
				if res, ok := ResolveInputTokens(r.tokens); ok {
					tokensOf[res.Chars] = r.tokens
				}
			}
		}
	}
	for _, r := range rows {
		if _, ok := tokensOf[r.PromptLenChars]; !ok {
			return fmt.Errorf("row %d carries %d prompt characters, which is no registered input length's measured resolution", r.Index, r.PromptLenChars)
		}
		if !anyCap[r.MaxOutputTokens] {
			return fmt.Errorf("row %d carries output cap %d, which no episode type registers", r.Index, r.MaxOutputTokens)
		}
	}

	// Reassemble episodes from the rows and count each registered setting.
	// A stagger's prefill is a later single row with the prefill cap, so it is joined to the group before it.
	known := map[string]bool{}
	for _, e := range cycle {
		known[e.signature()] = true
	}
	counts := map[string]int{}
	byOffset := map[int64][]TraceRow{}
	var offsets []int64
	for _, r := range rows {
		if _, ok := byOffset[r.OffsetMs]; !ok {
			offsets = append(offsets, r.OffsetMs)
		}
		byOffset[r.OffsetMs] = append(byOffset[r.OffsetMs], r)
	}
	sort.Slice(offsets, func(i, j int) bool { return offsets[i] < offsets[j] })
	for i := 0; i < len(offsets); i++ {
		start := offsets[i]
		var e episodeSpec
		for _, r := range byOffset[start] {
			e = append(e, episodeRequest{tokens: tokensOf[r.PromptLenChars], cap: r.MaxOutputTokens})
		}
		if t == EpisodeStagger && i+1 < len(offsets) {
			next := byOffset[offsets[i+1]]
			if len(next) == 1 && next[0].MaxOutputTokens == staggerPrefillCap {
				e = append(e, episodeRequest{tokens: tokensOf[next[0].PromptLenChars], cap: staggerPrefillCap, atMs: offsets[i+1] - start})
				i++
			}
		}
		sig := e.signature()
		if !known[sig] {
			return fmt.Errorf("the rows at offset %d ms form the episode [%s], which is not a %s setting; the trace was not built for this arm's episode type",
				start, sig, t)
		}
		counts[sig]++
	}
	for _, e := range cycle {
		if n := counts[e.signature()]; n != EpisodeCycles {
			return fmt.Errorf("the %s setting [%s] appears %d times and a trace holds exactly %d complete cycles", t, e.signature(), n, EpisodeCycles)
		}
	}
	return nil
}
