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

// EpisodeCycles is how many complete cycles one session-1 trace holds.
// Fixed rather than filled to a duration, so every trace contains every registered setting the same number of times and a short cell cannot silently omit one.
// Session 2 fixes its own counts per type in designS2, for the same reason.
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

// Session 2's changed levels, from sections 3 to 5 of docs/superpowers/specs/2026-10-05-instrument-validation-session-2.md.
var (
	// The held-out lengths 768, 3,072 and 6,144 sit between the calibration lengths so the frozen clock is tested where it was never fitted.
	serialLengthsS2 = []int{256, 512, 768, 1024, 2048, 3072, 4096, 6144, 8192}
	// 512 output tokens keep the decoders decoding for seconds after their first token, so the later trigger still meets them decoding.
	staggerDecodeCapS2 = 512
)

const (
	// staggerShortPrefillTokens marks the short-prefill stagger settings, whose TTFT spread in session 1 is why session 2 buys them more often.
	staggerShortPrefillTokens = 256
	// The warm-up's first and verification requests: W in section 2 compares their TTFT with session 1's warm median for exactly this request.
	warmupTokens = 2048
	warmupCap    = 16
)

// The spacing bound's constants, taken from the archives on the A10G.
// About 260 ms per 2,048-token prefill chunk and 15 to 25 ms per decode step were measured; both are rounded up so the bound errs towards a longer gap.
const (
	spacingChunkTokens     = 2048
	spacingMsPerChunk      = 270
	spacingMsPerDecodeStep = 30
	spacingMinGapMs        = 2000
)

// The RNG streams beside the cycle order, each its own so that adding one cannot move the draws of another.
// Session 1's traces are pinned byte for byte, and they draw only the order stream.
const (
	jitterStream = 0x6a09e667f3bcc908
	warmupStream = 0xbb67ae8584caa73b
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
	// minOut is the output the engine must produce before it may stop at end-of-sequence, and zero for every request before session 3.
	minOut int
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

// episodeDesign is one registration's episode parameters.
//
// Both sessions are values of one type so that the generator, the warm-up and the plan check cannot drift apart between them.
// A session-2 change that reached session 1 would change traces a finished archive was scored against, which TestSessionOneTracesAreByteIdentical pins.
type episodeDesign struct {
	study            string
	serialLengths    []int
	staggerDecodeCap int
	// The stagger lag is round(tenths/10 x estimated decoder prefill) + staggerLagMs + U(0..staggerJitterMs).
	staggerLagTenths int64
	staggerJitterMs  int64
	serialCycles     int
	burstCycles      int
	staggerCycles    int
	// staggerShortCycles are further cycles of the short-prefill settings only, placed after the full cycles.
	staggerShortCycles int
	// warmup says whether the registration defines a warm-up trace, which session 1's does not.
	warmup bool
	// staggerDecodeMin is the minimum output every stagger decoder asks for, in the measured trace and the warm-up alike.
	// Zero leaves the field off the rows, which is what keeps sessions 1 and 2 byte-identical.
	staggerDecodeMin int
	// warmupConditioning is how many unscored drained 2,048/16 requests the warm-up places between its cycle and its two verification requests.
	// Zero adds no episode and so no draw, which is what keeps the warm-ups of sessions 2 and 3 byte-identical.
	warmupConditioning int
	// burstSettings and staggerSettings list a design's settings explicitly, in enumeration order.
	// Nil keeps the package's factorial levels (burstSizes x burstLengths plus the wide burst, and
	// staggerDecoders x staggerContexts x staggerPrefills), which is what keeps every earlier study's traces byte-identical.
	burstSettings   []burstSetting
	staggerSettings []staggerSetting
}

// burstSetting is n concurrent requests of one prompt length.
type burstSetting struct{ n, tokens int }

// staggerSetting is n decoders of one prompt length and the late prefill that joins them.
type staggerSetting struct{ n, context, prefill int }

var designS1 = episodeDesign{
	study:            StudyInstrumentValidation,
	serialLengths:    serialLengths,
	staggerDecodeCap: staggerDecodeCap,
	staggerLagTenths: 10,
	serialCycles:     EpisodeCycles,
	burstCycles:      EpisodeCycles,
	staggerCycles:    EpisodeCycles,
}

var designS2 = episodeDesign{
	study:            StudyInstrumentValidationS2,
	serialLengths:    serialLengthsS2,
	staggerDecodeCap: staggerDecodeCapS2,
	// 1.3 x the estimate puts the trigger after the (16, 8,192) decoders' last first token, which session 1's 1.0 x did not.
	staggerLagTenths: 13,
	// The jitter keeps the trigger from landing on one fixed phase of the decoders' steps in every replicate.
	staggerJitterMs:    100,
	serialCycles:       6,
	burstCycles:        3,
	staggerCycles:      3,
	staggerShortCycles: 4,
	warmup:             true,
}

// designS3 is session 2's design with one change, from section 1 of docs/superpowers/specs/2026-10-06-instrument-validation-session-3.md.
// It is derived from designS2 rather than written out, so a reader sees the one difference and a later edit to session 2 cannot leave session 3 behind unnoticed.
var designS3 = func() episodeDesign {
	d := designS2
	d.study = StudyInstrumentValidationS3
	// In session 2, 188 of 420 staggered decoders capped at 512 stopped at end-of-sequence, some before the prefill's first token, and gate S refused the cell.
	// A minimum equal to the cap makes every decoder run to exactly 512 tokens, because vLLM does not stop at end-of-sequence before min_tokens.
	d.staggerDecodeMin = d.staggerDecodeCap
	return d
}()

// designS4 is session 3's design with one change, from section 1 of docs/superpowers/specs/2026-10-06-instrument-validation-session-4.md.
// It is derived from designS3 for the same reason designS3 is derived from designS2: the one difference stays visible and an earlier edit cannot leave it behind.
var designS4 = func() episodeDesign {
	d := designS3
	d.study = StudyInstrumentValidationS4
	// Every staggered warm-up's first verification request was slow, and in session 3 gate W refused one at 267.2 ms after 22.4 s idle.
	// One conditioning request absorbs that transient before the two requests W reads, so W itself stays unloosened.
	d.warmupConditioning = 1
	return d
}()

// designStepBoundary is session 4's design under the step-boundary session's study id: its registration buys
// study s4's episodes with fresh seeds, and changes the engine, not the trace.
var designStepBoundary = func() episodeDesign {
	d := designS4
	d.study = StudyStepBoundary
	return d
}()

// designFor returns the episode design a study registers, and false for a study that replays no episodes.
func designFor(study string) (episodeDesign, bool) {
	switch study {
	case StudyInstrumentValidation:
		return designS1, true
	case StudyInstrumentValidationS2:
		return designS2, true
	case StudyInstrumentValidationS3:
		return designS3, true
	case StudyInstrumentValidationS4:
		return designS4, true
	case StudyStepBoundary:
		return designStepBoundary, true
	}
	return episodeDesign{}, false
}

// staggerBaseLagMs is the prefill's lag before jitter.
// The +5 rounds half up, and the estimate is a whole number of 270 ms chunks, so at 1.3 x it is exact and at 1.0 x it is the estimate itself.
func (d episodeDesign) staggerBaseLagMs(n, c int) int64 {
	est := int64((n*c + spacingChunkTokens - 1) / spacingChunkTokens * spacingMsPerChunk)
	return (d.staggerLagTenths*est+5)/10 + staggerLagMs
}

// bursts is the design's burst settings: its explicit list, or the factorial levels and the wide burst, in that order.
func (d episodeDesign) bursts() []burstSetting {
	if d.burstSettings != nil {
		return d.burstSettings
	}
	var out []burstSetting
	for _, n := range burstSizes {
		for _, l := range burstLengths {
			out = append(out, burstSetting{n, l})
		}
	}
	return append(out, burstSetting{burstWideSize, burstWideLength})
}

// staggers is the design's stagger settings: its explicit list, or the factorial levels in their nested order.
func (d episodeDesign) staggers() []staggerSetting {
	if d.staggerSettings != nil {
		return d.staggerSettings
	}
	var out []staggerSetting
	for _, n := range staggerDecoders {
		for _, c := range staggerContexts {
			for _, p := range staggerPrefills {
				out = append(out, staggerSetting{n, c, p})
			}
		}
	}
	return out
}

// fullCycle lists one cycle's settings in a fixed enumeration order, before the seeded permutation.
func (d episodeDesign) fullCycle(t EpisodeType) ([]episodeSpec, error) {
	var out []episodeSpec
	switch t {
	case EpisodeSerial:
		for _, l := range d.serialLengths {
			for _, c := range serialCaps {
				out = append(out, homogeneous(1, l, c))
			}
		}
	case EpisodeBurst:
		for _, b := range d.bursts() {
			out = append(out, homogeneous(b.n, b.tokens, burstCap))
		}
	case EpisodeStagger:
		for _, st := range d.staggers() {
			e := homogeneous(st.n, st.context, d.staggerDecodeCap)
			for i := range e {
				e[i].minOut = d.staggerDecodeMin
			}
			// The prefill waits for the decoders' own prefill to finish, by the same pessimistic chunk estimate, so it meets them decoding rather than queued.
			out = append(out, append(e, episodeRequest{tokens: st.prefill, cap: staggerPrefillCap, atMs: d.staggerBaseLagMs(st.n, st.context)}))
		}
	default:
		return nil, fmt.Errorf("episode type %q is not registered; the registered types are %v", t, EpisodeTypes)
	}
	return out, nil
}

// cycles lists every cycle a measured trace holds, in the order they are laid out.
func (d episodeDesign) cycles(t EpisodeType) ([][]episodeSpec, error) {
	full, err := d.fullCycle(t)
	if err != nil {
		return nil, err
	}
	n := map[EpisodeType]int{EpisodeSerial: d.serialCycles, EpisodeBurst: d.burstCycles, EpisodeStagger: d.staggerCycles}[t]
	var out [][]episodeSpec
	for range n {
		out = append(out, full)
	}
	if t == EpisodeStagger && d.staggerShortCycles > 0 {
		short := slices.DeleteFunc(slices.Clone(full), func(e episodeSpec) bool {
			return e[len(e)-1].tokens != staggerShortPrefillTokens
		})
		for range d.staggerShortCycles {
			out = append(out, short)
		}
	}
	return out, nil
}

// expectedCounts says how many times each setting appears across a measured trace, keyed by signature.
func (d episodeDesign) expectedCounts(t EpisodeType) (map[string]int, []episodeSpec, error) {
	cs, err := d.cycles(t)
	if err != nil {
		return nil, nil, err
	}
	counts := map[string]int{}
	full, _ := d.fullCycle(t)
	for _, c := range cs {
		for _, e := range c {
			counts[e.signature()]++
		}
	}
	return counts, full, nil
}

// cycleOf is session 1's cycle, kept under its old name because the session-1 tests pin it.
func cycleOf(t EpisodeType) ([]episodeSpec, error) {
	return designS1.fullCycle(t)
}

// plannedRequest is one request of a planned trace, in tokens, at its absolute offset.
type plannedRequest struct {
	offsetMs int64
	tokens   int
	cap      int
	minOut   int
}

// jittered returns a stagger setting with its prefill moved later by a seeded draw, and every other setting unchanged.
// Only a design with jitter draws at all, which is what keeps session 1's draws, and so its bytes, where they were.
func (d episodeDesign) jittered(e episodeSpec, jitter *rand.Rand) episodeSpec {
	if d.staggerJitterMs == 0 || e.lastAtMs() == 0 {
		return e
	}
	out := slices.Clone(e)
	out[len(out)-1].atMs += jitter.Int64N(d.staggerJitterMs + 1)
	return out
}

// layOut places each cycle in its own seeded order, back to back from offset zero, and returns the span a replay needs.
//
// The span is the last row's offset plus its episode's gap, which for a stagger is longer than the episode-start sum by the prefill's lag.
// It is the longer of the two on purpose, because a duration that only covers the shorter one would end the cell while the last prefill is still running.
func (d episodeDesign) layOut(order, jitter *rand.Rand, cycles [][]episodeSpec) ([]plannedRequest, int64) {
	var out []plannedRequest
	var start, span int64
	for _, cycle := range cycles {
		for _, i := range order.Perm(len(cycle)) {
			e := d.jittered(cycle[i], jitter)
			for _, r := range e {
				out = append(out, plannedRequest{offsetMs: start + r.atMs, tokens: r.tokens, cap: r.cap, minOut: r.minOut})
			}
			span = start + e.lastAtMs() + e.gapMs()
			start += e.gapMs()
		}
	}
	return out, span
}

// plan lays out a measured trace.
//
// The seed is the only input besides the type.
// The arm's logging or async suffix never reaches this function, which is what makes the on, off and async arms of one repetition replay byte-identical traces.
func (d episodeDesign) plan(seed int64, t EpisodeType) ([]plannedRequest, int64, error) {
	cycles, err := d.cycles(t)
	if err != nil {
		return nil, 0, err
	}
	order := rand.New(rand.NewPCG(uint64(seed), uint64(seed)^0x9e3779b97f4a7c15))
	jitter := rand.New(rand.NewPCG(uint64(seed)^jitterStream, uint64(seed)))
	out, span := d.layOut(order, jitter, cycles)
	return out, span, nil
}

// warmupPlan lays out section 2's warm-up: one drained warm request, one regular cycle of the type, the design's conditioning requests, then two drained verification requests.
// Its order and jitter come from their own streams, so the unscored cycle is not a rehearsal of the measured trace's first cycle in the same order.
// A single-request episode draws from neither stream, so the conditioning requests leave the cycle's order and jitter where session 3 had them.
func (d episodeDesign) warmupPlan(seed int64, t EpisodeType) ([]plannedRequest, int64, error) {
	if !d.warmup {
		return nil, 0, fmt.Errorf("study %s registers no warm-up trace; its cells replay the measured trace alone", d.study)
	}
	full, err := d.fullCycle(t)
	if err != nil {
		return nil, 0, err
	}
	warm := []episodeSpec{homogeneous(1, warmupTokens, warmupCap)}
	order := rand.New(rand.NewPCG(uint64(seed)^warmupStream, uint64(seed)))
	jitter := rand.New(rand.NewPCG(uint64(seed)^warmupStream^jitterStream, uint64(seed)))
	cycles := [][]episodeSpec{warm, full}
	for range d.warmupConditioning {
		cycles = append(cycles, warm)
	}
	out, span := d.layOut(order, jitter, append(cycles, warm, warm))
	return out, span, nil
}

// planEpisodes is session 1's measured plan, kept under its old name because the session-1 tests pin it.
func planEpisodes(seed int64, t EpisodeType) ([]plannedRequest, int64, error) {
	return designS1.plan(seed, t)
}

// EpisodeTraceParams are the inputs GenerateEpisodeTrace turns into a trace.
type EpisodeTraceParams struct {
	// Study selects the registration's episode parameters, and has no default because the two sessions' traces differ.
	Study string
	// Seed orders each cycle; one repetition's arms share it.
	Seed int64
	// DurationMs is the cell's replay budget, which must hold the whole trace.
	DurationMs int64
	// Type is the episode shape, taken from the arm by InstrumentValidationEpisode.
	Type EpisodeType
}

// GenerateEpisodeTrace builds the registered cycles of one episode type for the premium tenant alone.
//
// It refuses rather than truncates when DurationMs cannot hold the trace, because a trace missing its last settings would be a cell that silently did not measure them.
// It refuses when any registered length has no measured character count, before laying anything out, so a short trace cannot pass by happening not to draw the missing one.
func GenerateEpisodeTrace(p EpisodeTraceParams) ([]TraceRow, error) {
	d, ok := designFor(p.Study)
	if !ok {
		return nil, fmt.Errorf("study %q registers no episodes", p.Study)
	}
	if _, err := d.fullCycle(p.Type); err != nil {
		return nil, err
	}
	plan, span, err := d.plan(p.Seed, p.Type)
	if err != nil {
		return nil, err
	}
	return episodeRows(p, plan, span, "complete cycles")
}

// GenerateEpisodeWarmupTrace builds the warm-up trace a session-2 cell replays before its measured trace.
//
// Its rows are premium-tenant rows like the measured ones, because the warm-up has to warm the path the measured requests take.
// It is refused for a study that registers no warm-up, rather than generated, because a session-1 cell given one would no longer be the cell that was scored.
func GenerateEpisodeWarmupTrace(p EpisodeTraceParams) ([]TraceRow, error) {
	d, ok := designFor(p.Study)
	if !ok {
		return nil, fmt.Errorf("study %q registers no episodes", p.Study)
	}
	plan, span, err := d.warmupPlan(p.Seed, p.Type)
	if err != nil {
		return nil, err
	}
	return episodeRows(p, plan, span, "warm-up requests and complete cycle")
}

// episodeRows resolves a plan's token counts to measured characters and checks that the duration holds it.
// The missing lengths are collected from the whole plan before anything is refused, so the message names every one to measure rather than the first.
func episodeRows(p EpisodeTraceParams, plan []plannedRequest, span int64, what string) ([]TraceRow, error) {
	var lengths, missing []int
	chars := map[int]int{}
	for _, r := range plan {
		if !slices.Contains(lengths, r.tokens) {
			lengths = append(lengths, r.tokens)
		}
	}
	slices.Sort(lengths)
	for _, l := range lengths {
		r, ok := ResolveInputTokens(l)
		if !ok {
			missing = append(missing, l)
			continue
		}
		chars[l] = r.Chars
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("the %s episodes register input lengths %v and the measured resolution table carries no character count for %v (it carries %v); run hack/resolve-input-lengths.sh for them rather than estimating one",
			p.Type, lengths, missing, ResolvedInputTokenCounts())
	}
	if p.DurationMs < span {
		return nil, fmt.Errorf("the %s trace is its registered %s spanning %d ms and the duration is %d ms; the cell has to hold all of it, so pass at least %d",
			p.Type, what, span, p.DurationMs, span)
	}
	rows := make([]TraceRow, len(plan))
	for i, r := range plan {
		rows[i] = TraceRow{
			Index:           i,
			OffsetMs:        r.offsetMs,
			Tenant:          PremiumTenant,
			PromptLenChars:  chars[r.tokens],
			MaxOutputTokens: r.cap,
			MinOutputTokens: r.minOut,
		}
	}
	return rows, nil
}

// checkEpisodeRows refuses a row no episode type of the design could have produced, and maps prompt characters to tokens.
//
// Lengths and caps are checked against the UNION of the three types first.
// A value no type registers is a malformed trace, and a value another type registers is a trace built for a different arm; the two are named differently because they are fixed differently.
func (d episodeDesign) checkEpisodeRows(rows []TraceRow) (map[int]int, error) {
	if len(rows) == 0 {
		return nil, fmt.Errorf("the trace has no rows, so there is nothing to replay and nothing to attribute")
	}
	for _, r := range rows {
		if r.Tenant != PremiumTenant || r.IsNoisy {
			return nil, fmt.Errorf("row %d is tenant %q (isNoisy=%v) and the study is single-tenant %s with no contender; any other request would share the engine's steps and break attribution by order",
				r.Index, r.Tenant, r.IsNoisy, PremiumTenant)
		}
	}
	tokensOf := map[int]int{}
	anyCap := map[int]bool{}
	for _, et := range EpisodeTypes {
		c, _ := d.fullCycle(et)
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
			return nil, fmt.Errorf("row %d carries %d prompt characters, which is no registered input length's measured resolution", r.Index, r.PromptLenChars)
		}
		if !anyCap[r.MaxOutputTokens] {
			return nil, fmt.Errorf("row %d carries output cap %d, which no episode type registers", r.Index, r.MaxOutputTokens)
		}
	}
	return tokensOf, nil
}

// checkMinOutput refuses a row whose minimum output is not the one its role registers.
//
// It is checked row by row rather than through the episode signatures, because a decoder that lost its minimum still forms a registered setting and would be counted as one.
// That is session 2's composition under session 3's name, which is exactly what session 3 exists to exclude.
// A stagger decoder is recognised by its cap, which no prefill and no other episode type shares.
func (d episodeDesign) checkMinOutput(t EpisodeType, rows []TraceRow) error {
	for _, r := range rows {
		decoder := t == EpisodeStagger && r.MaxOutputTokens == d.staggerDecodeCap
		want := 0
		if decoder {
			want = d.staggerDecodeMin
		}
		if r.MinOutputTokens == want {
			continue
		}
		if decoder {
			return fmt.Errorf("row %d is a stagger decoder with minOutputTokens %d and study %s registers %d for every stagger decoder",
				r.Index, r.MinOutputTokens, d.study, want)
		}
		return fmt.Errorf("row %d is not a stagger decoder and carries minOutputTokens %d; study %s registers a minimum output only for stagger decoders, if at all",
			r.Index, r.MinOutputTokens, d.study)
	}
	return nil
}

// EpisodeTraceRefusal says whether a measured trace is one this study's episode type registration can score.
//
// The tail studies' sample floors do not apply: the estimands here are per-episode timings, not a p99, and a trace is complete when it holds its cycles.
// The checks are ordered from the most basic to the most specific, so a refusal names the first thing wrong rather than a consequence of it.
func EpisodeTraceRefusal(study string, t EpisodeType, rows []TraceRow) error {
	d, ok := designFor(study)
	if !ok {
		return fmt.Errorf("study %q registers no episodes", study)
	}
	want, cycle, err := d.expectedCounts(t)
	if err != nil {
		return err
	}
	tokensOf, err := d.checkEpisodeRows(rows)
	if err != nil {
		return err
	}

	// Reassemble episodes from the rows and count each registered setting.
	// A stagger's prefill is a later single row with the prefill cap, so it is joined to the group before it.
	counts := map[string]int{}
	byOffset := map[int64][]TraceRow{}
	var offsets []int64
	for _, r := range rows {
		if _, ok := byOffset[r.OffsetMs]; !ok {
			offsets = append(offsets, r.OffsetMs)
		}
		byOffset[r.OffsetMs] = append(byOffset[r.OffsetMs], r)
	}
	slices.Sort(offsets)
	// The spacing is checked here, not only in the generator, because this is what a trace is bought against.
	// A review found a serial trace with its offsets rewritten to 0-53 ms reported as three complete cycles: the
	// contents were all there, and the episodes would have overlapped on the card and failed the evaluator's
	// drained check after the money was spent.
	var prevStart, prevGap int64
	havePrev := false
	for i := 0; i < len(offsets); i++ {
		start := offsets[i]
		var e episodeSpec
		for _, r := range byOffset[start] {
			e = append(e, episodeRequest{tokens: tokensOf[r.PromptLenChars], cap: r.MaxOutputTokens})
		}
		var lag int64
		if t == EpisodeStagger && i+1 < len(offsets) {
			next := byOffset[offsets[i+1]]
			if len(next) == 1 && next[0].MaxOutputTokens == staggerPrefillCap {
				lag = offsets[i+1] - start
				e = append(e, episodeRequest{tokens: tokensOf[next[0].PromptLenChars], cap: staggerPrefillCap, atMs: lag})
				i++
			}
		}
		// A jittered lag is compared with the formula's range rather than one value, so the setting is named by its base lag.
		// The setting is identified first and the lag judged second, so a malformed group is not reported as a mistimed one.
		var base int64
		jitteredStagger := d.staggerJitterMs > 0 && lag > 0
		if jitteredStagger {
			base = d.staggerBaseLagMs(len(e)-1, e[0].tokens)
			e[len(e)-1].atMs = base
		}
		sig := e.signature()
		if want[sig] == 0 {
			return fmt.Errorf("the rows at offset %d ms form the episode [%s], which is not a %s setting; the trace was not built for this arm's episode type",
				start, sig, t)
		}
		if jitteredStagger && (lag < base || lag > base+d.staggerJitterMs) {
			return fmt.Errorf("the prefill of the stagger episode at offset %d ms is sent %d ms after its decoders, and the registered lag for %d decoders at %d tokens is %d to %d ms (round(%d/10 x the estimated decoder prefill) + %d + 0..%d)",
				start, lag, len(e)-1, e[0].tokens, base, base+d.staggerJitterMs, d.staggerLagTenths, staggerLagMs, d.staggerJitterMs)
		}
		if havePrev && start < prevStart+prevGap {
			return fmt.Errorf("the episode at offset %d ms starts %d ms after the one before it, inside that episode's spacing bound of %d ms, so the engine would not be drained between them",
				start, start-prevStart, prevGap)
		}
		prevStart, prevGap, havePrev = start, e.gapMs(), true
		counts[sig]++
	}
	for _, e := range cycle {
		if n, w := counts[e.signature()], want[e.signature()]; n != w {
			return fmt.Errorf("the %s setting [%s] appears %d times and study %s places it exactly %d times", t, e.signature(), n, d.study, w)
		}
	}
	// Last, because only once the rows are known to be this type's settings is a cap of the decoders' value a decoder.
	return d.checkMinOutput(t, rows)
}
