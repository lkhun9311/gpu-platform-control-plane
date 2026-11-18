// Command replay sends experiment A's shared-prefix trace, with its prompts scaled down, through the llm-d-router lab
// open-loop, and records per request where it went, what the serving simulator had cached, and when its first token
// arrived; beside it, it samples every simulator's queue and cache gauges.
//
// It exists for issue #599: the question is whether llm-d-router's prefix scorers place this trace the way gpuaas's
// own PrefixAffinity did, so the arrivals and prompt draws must be the registered ones and nothing else may vary.
// The trace is regenerated from the study's registration rather than read from a file, and the unscaled trace is
// checked against its frozen checksum first, so a replay can never run on a drifted generator.
//
// Every latency it records is a simulator's, which runs no model: it says where requests queued, not how fast a GPU
// would serve them (docs/14_LLMD_KV_ROUTING_LAB.md).
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// frozenTraceSHA256 is hack/eks-serve/prefix-route-study/frozen-traces.sha256's entry per shared seed.
// A replay of a seed not listed here is refused, because nothing would show that its arrivals are the registered ones.
var frozenTraceSHA256 = map[int64]string{
	941: "2bdd82f10730e9e2d1408add4092ced7a09d51ce493cab5956f877df282f9efe",
	942: "2b42ce96ed4037dd83c9e96c4a35956c2b32a1557150adcfa954fc0a8c5392e1",
	943: "4b218170cbb32359446185fccc01a70fd1111b21eec102a08980a7e87ddd2dc5",
}

// record is one request's line in the output.
type record struct {
	Index    int    `json:"index"`
	Group    int    `json:"group"`
	OffsetMs int64  `json:"offset_ms"`
	Arm      string `json:"arm"`
	// RequestID is the id this sends; ServedID is the one the simulator received, which through the gateway is the
	// gateway's and is the key the EPP logs its scores under.
	RequestID string `json:"request_id"`
	ServedID  string `json:"served_request_id"`
	// Times are Unix nanoseconds, so rows from different processes can be ordered against the gauge samples.
	OriginNanos     int64  `json:"origin_unix_nanos"`
	SentNanos       int64  `json:"sent_unix_nanos"`
	FirstTokenNanos int64  `json:"first_token_unix_nanos"`
	EndNanos        int64  `json:"end_unix_nanos"`
	Status          int    `json:"status"`
	Pod             string `json:"pod"`
	ViaEPP          bool   `json:"via_epp"`
	PromptTokens    int    `json:"prompt_tokens"`
	// CachedTokens is -1 when the response carried no count, because 0 is a real answer and must not be manufactured.
	CachedTokens     int    `json:"cached_tokens"`
	CompletionTokens int    `json:"completion_tokens"`
	Done             bool   `json:"done"`
	Error            string `json:"error,omitempty"`
}

// sample is one read of one simulator's gauges.
type sample struct {
	UnixNanos int64              `json:"unix_nanos"`
	Pod       string             `json:"pod"`
	Values    map[string]float64 `json:"values,omitempty"`
	Error     string             `json:"error,omitempty"`
}

// sampledSeries are the simulator series a sample keeps: queue, occupancy and the simulator's own prefix-cache counts.
var sampledSeries = []string{
	"vllm:num_requests_running", "vllm:num_requests_waiting", "vllm:kv_cache_usage_perc",
	"vllm:prefix_cache_hits_total", "vllm:prefix_cache_queries_total",
}

// scaledTrace regenerates the study's trace for seed with every prompt length divided by scale.
//
// The arrivals and each request's prompt group come from streams keyed by the seed alone, so dividing the lengths
// leaves them untouched; this is checked row by row rather than trusted, since the claim rests on it.
func scaledTrace(seed int64, scale int) ([]bench.TraceRow, bench.PrefixLoad, error) {
	st, ok := bench.LookupStudy(bench.StudyPrefixRoute)
	if !ok || st.PrefixLoad == nil {
		return nil, bench.PrefixLoad{}, errors.New("study prefix-route-2026-10-27 is not registered with a load")
	}
	want, ok := frozenTraceSHA256[seed]
	if !ok {
		return nil, bench.PrefixLoad{}, fmt.Errorf("seed %d has no frozen trace checksum", seed)
	}
	full, err := bench.GeneratePrefixTrace(*st.PrefixLoad, seed, false)
	if err != nil {
		return nil, bench.PrefixLoad{}, err
	}
	// The frozen checksum was taken after the study fixed each request's output at its cap, as gen-trace does.
	if st.FixesOutputAtCap {
		if err := bench.FixOutputAtCap(full); err != nil {
			return nil, bench.PrefixLoad{}, err
		}
	}
	var buf bytes.Buffer
	if err := bench.WriteTrace(&buf, full); err != nil {
		return nil, bench.PrefixLoad{}, err
	}
	if got := bench.Checksum(buf.Bytes()); got != want {
		return nil, bench.PrefixLoad{}, fmt.Errorf("seed %d regenerates as %s, frozen as %s", seed, got, want)
	}
	if scale < 1 {
		return nil, bench.PrefixLoad{}, fmt.Errorf("scale %d: prompts can only be shortened", scale)
	}
	load := *st.PrefixLoad
	load.PromptChars /= scale
	load.PrefixChars /= scale
	rows, err := bench.GeneratePrefixTrace(load, seed, false)
	if err != nil {
		return nil, bench.PrefixLoad{}, err
	}
	if len(rows) != len(full) {
		return nil, bench.PrefixLoad{}, fmt.Errorf("scaled trace has %d rows, the frozen one %d", len(rows), len(full))
	}
	for i := range rows {
		if rows[i].OffsetMs != full[i].OffsetMs || rows[i].PrefixGroup != full[i].PrefixGroup {
			return nil, bench.PrefixLoad{}, fmt.Errorf("row %d: scaling moved its arrival or group", i)
		}
	}
	return rows, load, nil
}

// sendOne streams one completion and fills rec from the response as it arrives.
func sendOne(ctx context.Context, client *http.Client, url, model, prompt string, maxTokens int, rec *record) {
	body, _ := json.Marshal(map[string]any{
		"model": model, "prompt": prompt, "max_tokens": maxTokens, "ignore_eos": true, "temperature": 0,
		"stream": true, "stream_options": map[string]any{"include_usage": true},
	})
	endpoint := strings.TrimRight(url, "/") + "/v1/completions"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		rec.Error = err.Error()
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-request-id", rec.RequestID)
	rec.SentNanos = time.Now().UnixNano()
	resp, err := client.Do(req)
	if err != nil {
		rec.Error = err.Error()
		rec.EndNanos = time.Now().UnixNano()
		return
	}
	defer func() { _ = resp.Body.Close() }()
	rec.Status = resp.StatusCode
	rec.Pod = resp.Header.Get("x-inference-pod")
	rec.ServedID = resp.Header.Get("x-request-id")
	// The EPP stamps this on every response it processed, so its presence proves the request took the routed path.
	rec.ViaEPP = resp.Header.Get("x-went-into-resp-headers") == "true"
	if resp.StatusCode != http.StatusOK {
		data, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		rec.Error = fmt.Sprintf("status %d: %s", resp.StatusCode, data)
		rec.EndNanos = time.Now().UnixNano()
		return
	}
	readStream(resp.Body, rec)
	rec.EndNanos = time.Now().UnixNano()
}

// streamChunk is the part of an SSE completion chunk this reads.
type streamChunk struct {
	Choices []struct {
		Text string `json:"text"`
	} `json:"choices"`
	Usage *struct {
		PromptTokens        int `json:"prompt_tokens"`
		CompletionTokens    int `json:"completion_tokens"`
		PromptTokensDetails *struct {
			CachedTokens *int `json:"cached_tokens"`
		} `json:"prompt_tokens_details"`
	} `json:"usage"`
}

// readStream records the first content chunk's arrival, the usage chunk and the terminating [DONE].
//
// The first token is the first chunk carrying text, as experiment A defined it, not the first byte, because a role or
// empty chunk would make a queued request look served.
func readStream(r io.Reader, rec *record) {
	rec.CachedTokens = -1
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for sc.Scan() {
		line := sc.Text()
		data, ok := strings.CutPrefix(line, "data: ")
		if !ok {
			continue
		}
		if data == "[DONE]" {
			rec.Done = true
			continue
		}
		var c streamChunk
		if err := json.Unmarshal([]byte(data), &c); err != nil {
			rec.Error = "decode chunk: " + err.Error()
			continue
		}
		if rec.FirstTokenNanos == 0 && len(c.Choices) > 0 && c.Choices[0].Text != "" {
			rec.FirstTokenNanos = time.Now().UnixNano()
		}
		if c.Usage != nil {
			rec.PromptTokens = c.Usage.PromptTokens
			rec.CompletionTokens = c.Usage.CompletionTokens
			if d := c.Usage.PromptTokensDetails; d != nil && d.CachedTokens != nil {
				rec.CachedTokens = *d.CachedTokens
			}
		}
	}
	if err := sc.Err(); err != nil && rec.Error == "" {
		rec.Error = "read stream: " + err.Error()
	}
	if !rec.Done && rec.Error == "" {
		rec.Error = "stream ended without [DONE]"
	}
}

// parseGauges keeps the sampled series from a Prometheus text exposition, summed over label sets.
//
// The simulator labels its series by model, and with one model a sum is the value; a sum also keeps a second label
// set from being silently dropped.
func parseGauges(text string) map[string]float64 {
	out := map[string]float64{}
	for line := range strings.SplitSeq(text, "\n") {
		if line == "" || line[0] == '#' {
			continue
		}
		name, rest, _ := strings.Cut(line, " ")
		if i := strings.IndexByte(name, '{'); i >= 0 {
			name = name[:i]
			if _, after, ok := strings.CutLast(line, "}"); ok {
				rest = strings.TrimSpace(after)
			}
		}
		for _, want := range sampledSeries {
			if name != want {
				continue
			}
			f := strings.Fields(rest)
			if len(f) == 0 {
				continue
			}
			if v, err := strconv.ParseFloat(f[0], 64); err == nil {
				out[name] += v
			}
		}
	}
	return out
}

// sampler reads every target's /metrics each interval until ctx ends.
// A failed read is recorded as an error row, never as a zero, so a gap in the evidence stays visible.
func sampler(ctx context.Context, targets map[string]string, every time.Duration, enc *json.Encoder, mu *sync.Mutex) {
	client := &http.Client{Timeout: every}
	tick := time.NewTicker(every)
	defer tick.Stop()
	for {
		for pod, url := range targets {
			s := sample{UnixNanos: time.Now().UnixNano(), Pod: pod}
			resp, err := client.Get(url)
			if err == nil {
				data, rerr := io.ReadAll(resp.Body)
				_ = resp.Body.Close()
				switch {
				case rerr != nil:
					s.Error = rerr.Error()
				case resp.StatusCode != http.StatusOK:
					s.Error = fmt.Sprintf("status %d", resp.StatusCode)
				default:
					s.Values = parseGauges(string(data))
				}
			} else {
				s.Error = err.Error()
			}
			mu.Lock()
			_ = enc.Encode(s)
			mu.Unlock()
		}
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}

// parseTargets reads "pod=url,pod=url".
func parseTargets(s string) (map[string]string, error) {
	out := map[string]string{}
	for item := range strings.SplitSeq(s, ",") {
		if item = strings.TrimSpace(item); item == "" {
			continue
		}
		pod, url, ok := strings.Cut(item, "=")
		if !ok || pod == "" || url == "" {
			return nil, fmt.Errorf("bad metrics target %q, want pod=url", item)
		}
		out[pod] = url
	}
	return out, nil
}

func main() {
	url := flag.String("url", "http://127.0.0.1:30598", "the lab gateway")
	model := flag.String("model", "TinyLlama/TinyLlama-1.1B-Chat-v1.0", "model name")
	seed := flag.Int64("seed", 942, "experiment A's shared-trace seed")
	scale := flag.Int("scale", 10, "divide every prompt length by this")
	arm := flag.String("arm", "", "arm label written into every row and request id")
	maxTokens := flag.Int("max-tokens", 64, "output tokens per request, experiment A's 64")
	timeout := flag.Duration("timeout", 30*time.Second, "whole-request timeout, experiment A's 30 s")
	limit := flag.Int("limit", 0, "send only the first N requests, for a smoke test; 0 sends all")
	out := flag.String("out", "", "requests JSONL")
	samplesOut := flag.String("samples", "", "gauge samples JSONL")
	metrics := flag.String("metrics", "", "pod=url,... of each simulator's /metrics")
	every := flag.Duration("sample-every", time.Second, "gauge sampling interval")
	printTrace := flag.Bool("print-trace", false, "print the scaled trace's shape and exit")
	flag.Parse()

	rows, load, err := scaledTrace(*seed, *scale)
	if err != nil {
		fmt.Fprintln(os.Stderr, "replay:", err)
		os.Exit(2)
	}
	if *printTrace {
		fmt.Printf("seed %d: %d requests over %d ms at %.2f/s, %d groups, "+
			"prompt %d chars of which %d shared, output %d tokens\n",
			*seed, len(rows), load.DurationMs, load.RatePerSec, load.Groups, load.PromptChars, load.PrefixChars, *maxTokens)
		return
	}
	if *arm == "" || *out == "" {
		fmt.Fprintln(os.Stderr, "replay: -arm and -out are required")
		os.Exit(2)
	}
	if *limit > 0 && *limit < len(rows) {
		rows = rows[:*limit]
	}
	targets, err := parseTargets(*metrics)
	if err != nil {
		fmt.Fprintln(os.Stderr, "replay:", err)
		os.Exit(2)
	}
	f, err := os.OpenFile(*out, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		fmt.Fprintln(os.Stderr, "replay:", err)
		os.Exit(2)
	}
	defer func() { _ = f.Close() }()
	enc := json.NewEncoder(f)
	var mu sync.Mutex

	ctx, stop := context.WithCancel(context.Background())
	var samplerDone sync.WaitGroup
	if len(targets) > 0 && *samplesOut != "" {
		sf, err := os.OpenFile(*samplesOut, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
		if err != nil {
			fmt.Fprintln(os.Stderr, "replay:", err)
			os.Exit(2)
		}
		defer func() { _ = sf.Close() }()
		var smu sync.Mutex
		samplerDone.Go(func() { sampler(ctx, targets, *every, json.NewEncoder(sf), &smu) })
	}

	// One pooled client with room for every request in flight, so a request never waits for a connection and the
	// load stays open-loop as experiment A's sender was.
	client := &http.Client{Timeout: *timeout, Transport: &http.Transport{MaxIdleConnsPerHost: 600, MaxConnsPerHost: 600}}
	origin := time.Now().Add(500 * time.Millisecond)
	var wg sync.WaitGroup
	failed := 0
	var fmu sync.Mutex
	for _, row := range rows {
		time.Sleep(time.Until(origin.Add(time.Duration(row.OffsetMs) * time.Millisecond)))
		wg.Add(1)
		go func(row bench.TraceRow) {
			defer wg.Done()
			rec := record{Index: row.Index, Group: row.PrefixGroup, OffsetMs: row.OffsetMs, Arm: *arm,
				RequestID: fmt.Sprintf("%s-%d", *arm, row.Index), OriginNanos: origin.UnixNano()}
			sendOne(context.Background(), client, *url, *model, bench.PromptForRow(row), *maxTokens, &rec)
			if rec.Error != "" {
				fmu.Lock()
				failed++
				fmu.Unlock()
			}
			mu.Lock()
			_ = enc.Encode(rec)
			mu.Unlock()
		}(row)
	}
	wg.Wait()
	// Sample a few more seconds, so the drain after the last request is in the evidence.
	time.Sleep(3 * *every)
	stop()
	samplerDone.Wait()
	// Every row is written either way; a run with a failed request exits non-zero so it cannot be read as clean.
	if failed > 0 {
		fmt.Fprintf(os.Stderr, "replay: %d of %d requests failed\n", failed, len(rows))
		os.Exit(1)
	}
}
