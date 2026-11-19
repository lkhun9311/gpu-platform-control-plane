// Command loadgen sends a seeded, bursty, open-loop stream of streaming chat completions and records one JSON line per
// request.
//
// Arrivals are fixed before the first request is sent, so a slow or rejected response never delays the next arrival
// and the same seed gives the same schedule, prompts and max_tokens in every run.
// Each request carries a client id in x-request-id; the simulator echoes the id the EPP routed under, and
// x-inference-pod names the pod that served it.
//
// TTFT is measured to the first stream event that carries generated text.
// A stream counts as complete only when it ends with "data: [DONE]" and no error event; the analyzer checks this.
//
// Changing -burst-size changes how many draws each burst takes from the seeded source, so the burst gaps after the
// first burst differ too.
// A control run with a smaller burst size is therefore a different schedule, not the burst schedule thinned out.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

type record struct {
	ID          string  `json:"id"`
	Burst       int     `json:"burst"`
	PromptWords int     `json:"prompt_words"`
	MaxTokens   int     `json:"max_tokens"`
	SchedMs     float64 `json:"sched_ms"`
	SentUnixNs  int64   `json:"sent_unix_ns"`
	Status      int     `json:"status"`
	Dropped     string  `json:"dropped_reason,omitempty"`
	QueueMs     string  `json:"fc_queue_ms,omitempty"`
	Pod         string  `json:"pod,omitempty"`
	ServedID    string  `json:"served_id,omitempty"`
	TTFTMs      float64 `json:"ttft_ms,omitempty"`
	E2EMs       float64 `json:"e2e_ms"`
	DoneUnixNs  int64   `json:"done_unix_ns"`
	Chunks      int     `json:"chunks,omitempty"`
	Body        string  `json:"body,omitempty"`
	Err         string  `json:"err,omitempty"`
	// The fields below were added after the 36 runs of 2026-11-19 and are absent from their records.
	// ContentChunks counts stream events whose delta carries non-empty generated text.
	ContentChunks int `json:"content_chunks,omitempty"`
	// UsageCompletionTokens is the server's own count of generated tokens, from the include_usage event.
	UsageCompletionTokens *int `json:"usage_completion_tokens,omitempty"`
	// FinishReason is the last non-empty finish_reason seen on any choice.
	FinishReason string `json:"finish_reason,omitempty"`
	// Done is true when the stream ended with the "data: [DONE]" terminator.
	// It is always written, so its presence tells the analyzer a record has the completion fields.
	Done        bool   `json:"done"`
	StreamError string `json:"stream_error,omitempty"`
	BadEvents   int    `json:"bad_events,omitempty"`
}

type arrival struct {
	at          time.Duration
	burst       int
	promptWords int
	maxTokens   int
}

// schedule draws every arrival from one seeded source: burst start gaps are exponential, requests inside a burst are
// spread uniformly over a short window, and each request gets its own prompt length and max_tokens.
func schedule(seed int64, bursts, size int, meanGap, window time.Duration, minWords, maxWords, minTok, maxTok int) []arrival {
	r := rand.New(rand.NewSource(seed))
	var out []arrival
	start := 500 * time.Millisecond
	for b := 0; b < bursts; b++ {
		for i := 0; i < size; i++ {
			off := time.Duration(0)
			if window > 0 {
				off = time.Duration(r.Int63n(int64(window)))
			}
			out = append(out, arrival{
				at:          start + off,
				burst:       b,
				promptWords: minWords + r.Intn(maxWords-minWords+1),
				maxTokens:   minTok + r.Intn(maxTok-minTok+1),
			})
		}
		start += time.Duration(r.ExpFloat64() * float64(meanGap))
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].at < out[j].at })
	return out
}

var words = strings.Fields("alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra tango uniform victor whiskey xray yankee zulu")

func prompt(seed int64, idx, n int) string {
	r := rand.New(rand.NewSource(seed*1_000_003 + int64(idx)))
	var b strings.Builder
	for i := 0; i < n; i++ {
		if i > 0 {
			b.WriteByte(' ')
		}
		b.WriteString(words[r.Intn(len(words))])
	}
	return b.String()
}

func main() {
	url := flag.String("url", "http://127.0.0.1:30611", "gateway base URL")
	model := flag.String("model", "TinyLlama/TinyLlama-1.1B-Chat-v1.0", "model name")
	seed := flag.Int64("seed", 1, "seed for arrivals, prompts and max_tokens")
	bursts := flag.Int("bursts", 40, "number of bursts")
	size := flag.Int("burst-size", 24, "requests per burst")
	meanGap := flag.Duration("mean-gap", 1500*time.Millisecond, "mean gap between burst starts (exponential)")
	window := flag.Duration("window", 20*time.Millisecond, "a burst's requests start uniformly within this window")
	minWords := flag.Int("min-words", 20, "minimum prompt words")
	maxWords := flag.Int("max-words", 200, "maximum prompt words")
	minTok := flag.Int("min-tokens", 16, "minimum max_tokens")
	maxTok := flag.Int("max-tokens", 64, "maximum max_tokens")
	runTag := flag.String("tag", "run", "prefix of each request's x-request-id")
	out := flag.String("out", "requests.jsonl", "output JSON lines")
	timeout := flag.Duration("timeout", 120*time.Second, "per-request timeout")
	renderURL := flag.String("render-url", "", "if set, send nothing: write each planned request's prompt token count from this vLLM render server")
	flag.Parse()

	plan := schedule(*seed, *bursts, *size, *meanGap, *window, *minWords, *maxWords, *minTok, *maxTok)
	if *renderURL != "" {
		if err := tokenCounts(*renderURL, *model, *seed, *runTag, plan, *out); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	f, err := os.Create(*out)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer f.Close()
	enc := json.NewEncoder(f)
	var mu sync.Mutex

	// One connection per in-flight request, so connection reuse never serializes a burst on the client side.
	client := &http.Client{Transport: &http.Transport{MaxIdleConnsPerHost: 1024, MaxConnsPerHost: 0, DisableCompression: true}}
	var wg sync.WaitGroup
	t0 := time.Now()
	for i, a := range plan {
		if d := time.Until(t0.Add(a.at)); d > 0 {
			time.Sleep(d)
		}
		wg.Add(1)
		go func(i int, a arrival) {
			defer wg.Done()
			rec := send(client, *url, *model, fmt.Sprintf("%s-%05d", *runTag, i), prompt(*seed, i, a.promptWords), a, *timeout)
			rec.SchedMs = float64(a.at) / float64(time.Millisecond)
			mu.Lock()
			_ = enc.Encode(rec)
			mu.Unlock()
		}(i, a)
	}
	wg.Wait()
	fmt.Fprintf(os.Stderr, "loadgen: %d requests in %s\n", len(plan), time.Since(t0).Round(time.Millisecond))
}

// send returns a named result so the deferred completion stamp lands in the record the caller receives.
func send(client *http.Client, url, model, id, text string, a arrival, timeout time.Duration) (rec record) {
	rec = record{ID: id, Burst: a.burst, PromptWords: a.promptWords, MaxTokens: a.maxTokens}
	body, _ := json.Marshal(map[string]any{
		"model":      model,
		"messages":   []map[string]string{{"role": "user", "content": text}},
		"max_tokens": a.maxTokens,
		// ignore_eos makes the simulator generate exactly max_tokens, so a request's duration is fixed by the plan.
		"ignore_eos":     true,
		"stream":         true,
		"stream_options": map[string]bool{"include_usage": true},
	})
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, url+"/v1/chat/completions", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-request-id", id)
	start := time.Now()
	rec.SentUnixNs = start.UnixNano()
	defer func() {
		end := time.Now()
		rec.DoneUnixNs = end.UnixNano()
		rec.E2EMs = float64(end.Sub(start)) / float64(time.Millisecond)
	}()
	resp, err := client.Do(req)
	if err != nil {
		rec.Err = err.Error()
		return rec
	}
	defer resp.Body.Close()
	rec.Status = resp.StatusCode
	rec.Dropped = resp.Header.Get("x-llm-d-request-dropped-reason")
	rec.QueueMs = resp.Header.Get("x-llm-d-flow-queue-duration-ms")
	rec.Pod = resp.Header.Get("x-inference-pod")
	rec.ServedID = resp.Header.Get("x-request-id")
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		rec.Body = string(b)
		return rec
	}
	sc := bufio.NewScanner(resp.Body)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		rec.Chunks++
		payload := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if payload == "[DONE]" {
			rec.Done = true
			continue
		}
		var ev streamEvent
		if err := json.Unmarshal([]byte(payload), &ev); err != nil {
			rec.BadEvents++
			continue
		}
		if ev.Error != nil {
			rec.StreamError = string(*ev.Error)
		}
		if ev.Usage != nil {
			n := ev.Usage.CompletionTokens
			rec.UsageCompletionTokens = &n
		}
		for _, ch := range ev.Choices {
			if ch.Delta.Content != "" {
				// TTFT is the first event that carries generated text, not the role-only or empty first event.
				if rec.ContentChunks == 0 {
					rec.TTFTMs = float64(time.Since(start)) / float64(time.Millisecond)
				}
				rec.ContentChunks++
			}
			if ch.FinishReason != nil && *ch.FinishReason != "" {
				rec.FinishReason = *ch.FinishReason
			}
		}
	}
	if err := sc.Err(); err != nil {
		rec.Err = err.Error()
	}
	return rec
}

// streamEvent is the part of an OpenAI chat-completion stream chunk this tool reads.
type streamEvent struct {
	Choices []struct {
		Delta struct {
			Content string `json:"content"`
		} `json:"delta"`
		FinishReason *string `json:"finish_reason"`
	} `json:"choices"`
	Usage *struct {
		CompletionTokens int `json:"completion_tokens"`
	} `json:"usage"`
	Error *json.RawMessage `json:"error"`
}

// tokenCounts renders every planned prompt through the same /v1/chat/completions/render endpoint the EPP's
// token-producer calls, so the analysis can charge each request the prompt tokens the EPP charged it.
func tokenCounts(renderURL, model string, seed int64, tag string, plan []arrival, out string) error {
	f, err := os.Create(out)
	if err != nil {
		return err
	}
	defer f.Close()
	enc := json.NewEncoder(f)
	for i, a := range plan {
		body, _ := json.Marshal(map[string]any{
			"model":      model,
			"messages":   []map[string]string{{"role": "user", "content": prompt(seed, i, a.promptWords)}},
			"max_tokens": a.maxTokens,
		})
		resp, err := http.Post(renderURL+"/v1/chat/completions/render", "application/json", bytes.NewReader(body))
		if err != nil {
			return err
		}
		var r struct {
			TokenIDs []int `json:"token_ids"`
		}
		err = json.NewDecoder(resp.Body).Decode(&r)
		resp.Body.Close()
		if err != nil || resp.StatusCode != http.StatusOK || len(r.TokenIDs) == 0 {
			return fmt.Errorf("render of request %d: status %d, %d tokens, err %v", i, resp.StatusCode, len(r.TokenIDs), err)
		}
		if err := enc.Encode(map[string]any{"id": fmt.Sprintf("%s-%05d", tag, i), "prompt_tokens": len(r.TokenIDs), "max_tokens": a.maxTokens}); err != nil {
			return err
		}
	}
	return nil
}
