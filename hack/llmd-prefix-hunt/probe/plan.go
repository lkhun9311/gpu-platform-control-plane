package main

import (
	"fmt"
	"math/rand/v2"
	"strings"
)

// Step is one request of the session's seeded workload.
// The plan is a pure function of its seed, so the offline test and the instance run the same requests.
type Step struct {
	ID    string `json:"id"`
	Hyp   string `json:"hyp"`
	Case  string `json:"case"`
	Rep   int    `json:"rep"`
	Phase string `json:"phase"`
	Pod   string `json:"pod"`
	Kind  string `json:"kind"`
	// Tokens is the token-array prompt of a completion.
	// A token array reaches the router as sent, so both sides hash exactly these IDs and no tokenizer can differ between them.
	Tokens []uint32 `json:"tokens,omitempty"`
	// SharedLen is how many leading prompt tokens this step shares with the case's warm request.
	SharedLen  int    `json:"shared_len"`
	Salt       string `json:"salt,omitempty"`
	ReportFull bool   `json:"report_full,omitempty"`
	// ImageSeed, ChatText and Question make up a chat step: one generated image, a shared paragraph and a closing question.
	ImageSeed uint64 `json:"image_seed,omitempty"`
	ChatText  string `json:"chat_text,omitempty"`
	Question  string `json:"question,omitempty"`
	MaxTokens int    `json:"max_tokens"`
	// Measured marks the rows the verdict reads; the other rows only set up the engine's cache.
	Measured bool `json:"measured"`
	// NoSend marks a row that only takes the routers' predictions and sends nothing, so it changes no cache.
	NoSend bool `json:"no_send,omitempty"`
}

// Token IDs are drawn from a range of ordinary Qwen2 vocabulary entries.
// The range stays far below the special tokens, which start at 151643, so no drawn ID can change the chat template's meaning or end a sequence.
const (
	tokenLow  = 1000
	tokenHigh = 30000
)

// The dedup case fills pod A's cache past its size so the engine must evict the case's prefixes.
// The runner gives each replica 256 blocks of 64 tokens, 16,384 tokens, and the flood sends floodPrompts x floodLen of new tokens.
const (
	dedupPrefixLen = 1024
	floodLen       = 1024
)

type planner struct {
	rng   *rand.Rand
	steps []Step
}

func (p *planner) tokens(n int) []uint32 {
	out := make([]uint32, n)
	for i := range out {
		out[i] = uint32(tokenLow + p.rng.IntN(tokenHigh-tokenLow))
	}
	return out
}

func (p *planner) add(s Step) {
	s.ID = fmt.Sprintf("%03d-%s-%s-r%d-%s-%s", len(p.steps), s.Hyp, s.Case, s.Rep, s.Phase, s.Pod)
	if s.MaxTokens == 0 {
		s.MaxTokens = 2
	}
	if s.Kind == "" {
		s.Kind = "completion"
	}
	p.steps = append(p.steps, s)
}

func concat(a, b []uint32) []uint32 {
	out := make([]uint32, 0, len(a)+len(b))
	return append(append(out, a...), b...)
}

// warmTail is long enough that the warm prompt fills the engine block holding the prefix's last token.
// With a shorter tail a 528-token prefix warms only 568 tokens, vLLM caches 512 of them, and the case cannot show what it is for.
const warmTail = 104

// sharedPair sends prefix+tailA to pod A to warm it, then prefix+tailB to A as the measured row.
func (p *planner) sharedPair(hyp, cs string, rep, prefixLen int, salt string) {
	prefix := p.tokens(prefixLen)
	p.add(Step{Hyp: hyp, Case: cs, Rep: rep, Phase: "warm", Pod: "a", Tokens: concat(prefix, p.tokens(warmTail)), SharedLen: prefixLen + warmTail, Salt: salt})
	p.add(Step{Hyp: hyp, Case: cs, Rep: rep, Phase: "probe", Pod: "a", Tokens: concat(prefix, p.tokens(40)), SharedLen: prefixLen, Salt: salt, Measured: true})
}

// repeatPair sends the same prompt twice to pod A, so the second is a whole-prompt hit.
func (p *planner) repeatPair(hyp, cs string, rep, n int) {
	prompt := p.tokens(n)
	p.add(Step{Hyp: hyp, Case: cs, Rep: rep, Phase: "warm", Pod: "a", Tokens: prompt, SharedLen: n})
	p.add(Step{Hyp: hyp, Case: cs, Rep: rep, Phase: "probe", Pod: "a", Tokens: prompt, SharedLen: n, Measured: true})
}

// words returns a deterministic paragraph for the chat case.
func (p *planner) words(n int) string {
	vocab := strings.Fields("river stone lantern orbit cedar meadow signal harbor copper violet " +
		"thunder pencil garden marble falcon quiet window ladder silver canyon")
	var b strings.Builder
	for i := range n {
		if i > 0 {
			b.WriteByte(' ')
		}
		b.WriteString(vocab[p.rng.IntN(len(vocab))])
	}
	return b.String()
}

// BuildPlan returns the session's workload for seed, with reps repetitions of each case.
func BuildPlan(seed uint64, reps, floodPrompts int) []Step {
	p := &planner{rng: rand.New(rand.NewPCG(seed, seed^0x9e3779b97f4a7c15))}
	for rep := range reps {
		// Calibration: a shared prefix aligned to both block sizes, where router and engine must agree.
		p.sharedPair("calib", "shared512", rep, 512, "")
		// H1: a shared prefix that ends inside an engine block, and whole-prompt hits.
		for _, n := range []int{528, 544, 560} {
			p.sharedPair("bias", fmt.Sprintf("shared%d", n), rep, n, "")
		}
		for _, n := range []int{512, 576, 600} {
			p.repeatPair("bias", fmt.Sprintf("repeat%d", n), rep, n)
		}
		// Control for the known 1:many extra-key defect (llm-d-router #3788): a salted prompt.
		p.sharedPair("salt", "salted512", rep, 512, fmt.Sprintf("hunt-salt-%d", rep))
		// Control for the same defect with an image.
		text := p.words(360)
		img := p.rng.Uint64()
		p.add(Step{Hyp: "mm", Case: "image", Rep: rep, Phase: "warm", Pod: "a", Kind: "chat", ImageSeed: img, ChatText: text, Question: "Name one word above."})
		p.add(Step{Hyp: "mm", Case: "image", Rep: rep, Phase: "probe", Pod: "a", Kind: "chat", ImageSeed: img, ChatText: text, Question: "Name two words above.", Measured: true})
		// H2: reused-block reports inflate the dedup reference count, so the engine's single removal is suppressed.
		full, inc := p.tokens(dedupPrefixLen), p.tokens(dedupPrefixLen)
		for _, f := range []struct {
			cs     string
			prefix []uint32
			report bool
		}{{"full", full, true}, {"incremental", inc, false}} {
			p.add(Step{Hyp: "dedup", Case: f.cs, Rep: rep, Phase: "warm", Pod: "a", Tokens: concat(f.prefix, p.tokens(16)), SharedLen: dedupPrefixLen + 16})
			for range 3 {
				p.add(Step{Hyp: "dedup", Case: f.cs, Rep: rep, Phase: "repeat", Pod: "a", Tokens: concat(f.prefix, p.tokens(16)), SharedLen: dedupPrefixLen, ReportFull: f.report})
			}
			p.add(Step{Hyp: "dedup", Case: f.cs, Rep: rep, Phase: "pre", Pod: "a", Tokens: concat(f.prefix, p.tokens(16)), SharedLen: dedupPrefixLen, Measured: true})
		}
		for i := range floodPrompts {
			p.add(Step{Hyp: "dedup", Case: fmt.Sprintf("flood%02d", i), Rep: rep, Phase: "flood", Pod: "a", Tokens: p.tokens(floodLen), MaxTokens: 1})
		}
		// The checks read both families' predictions before either is sent again, the control first.
		// The pool processes one pod's events in order, so a control predicted at 0 shows the producer has processed the control's removals and every removal published before them.
		// The full-report family was evicted before the control, so its check then reads an index that has seen its removals.
		for _, f := range []struct {
			cs     string
			prefix []uint32
		}{{"incremental", inc}, {"full", full}} {
			p.add(Step{Hyp: "dedup", Case: f.cs, Rep: rep, Phase: "check", Pod: "a", Tokens: concat(f.prefix, p.tokens(16)), SharedLen: dedupPrefixLen, Measured: true, NoSend: true})
		}
		for _, f := range []struct {
			cs     string
			prefix []uint32
		}{{"full", full}, {"incremental", inc}} {
			p.add(Step{Hyp: "dedup", Case: f.cs, Rep: rep, Phase: "post", Pod: "a", Tokens: concat(f.prefix, p.tokens(16)), SharedLen: dedupPrefixLen, Measured: true})
		}
	}
	return p.steps
}
