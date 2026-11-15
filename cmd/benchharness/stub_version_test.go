package main

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// versionStudyStub is the profile a version study rehearsal runs: usage reported, each request's own cap honoured, and
// the finish reason a real engine gives.
func versionStudyStub() stubProfile {
	return stubProfile{tokens: 8, ttft: time.Millisecond, usage: true, tokensFromRequest: true, finishReasons: true}
}

// TestTheStubAnswersTheVersionStudyAsAConformingEngine: every registered request shape, sent by the study's own sender
// with its sampling, comes back as a row the study classifies a success, so a rehearsal can reach its passing path.
func TestTheStubAnswersTheVersionStudyAsAConformingEngine(t *testing.T) {
	st, ok := bench.LookupStudy(bench.StudyVersionAsync)
	if !ok || st.Sampling == nil {
		t.Fatal("the version study is not registered with a sampling policy")
	}
	srv := httptest.NewServer(stubMux(versionStudyStub(), newStubStats()))
	defer srv.Close()
	sender := bench.NewHTTPSender(srv.URL, "m", nil, 5*time.Second, bench.SenderConn{})
	if err := sender.SetSampling(st.Sampling); err != nil {
		t.Fatal(err)
	}
	var trace []bench.TraceRow
	for _, in := range []int{256, 1024, 2048} {
		r, ok := bench.ResolveInputTokens(in)
		if !ok {
			t.Fatalf("input length %d is not resolved", in)
		}
		for _, out := range []int{64, 256} {
			trace = append(trace, bench.TraceRow{
				Index: len(trace), OffsetMs: int64(len(trace)), PromptLenChars: r.Chars,
				MaxOutputTokens: out, MinOutputTokens: out, ExactInputTokens: in,
			})
		}
	}
	rows := bench.Replay(context.Background(), sender, trace, bench.ReplayOptions{Arm: "A-l060", Study: bench.StudyVersionAsync})
	for i, r := range rows {
		d, err := bench.StudyDisposition(*st.Sampling, r, trace[r.Index])
		if err != nil || d != bench.DispositionSuccess {
			t.Errorf("row %d (%d chars, cap %d): disposition %q, err %v; finish %q, usage %d/%d", i, trace[r.Index].PromptLenChars,
				trace[r.Index].MaxOutputTokens, d, err, r.FinishReason, r.EngineInputTokens, r.EngineOutputTokens)
		}
	}
}

// metricsLine reads one gauge from the stub's /metrics.
func metricsLine(t *testing.T, url, name string) string {
	t.Helper()
	resp, err := http.Get(url + "/metrics")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = resp.Body.Close() }()
	b, _ := io.ReadAll(resp.Body)
	for line := range strings.SplitSeq(string(b), "\n") {
		if v, ok := strings.CutPrefix(line, name+" "); ok {
			return v
		}
	}
	t.Fatalf("/metrics has no %s:\n%s", name, b)
	return ""
}

// TestTheStubQueuesBeyondItsCapacity: with a capacity, requests past it wait, and the gauges the drain check reads say so.
//
// Without it the stub serves any rate in parallel, so a calibration ladder against it never finds an upper bracket.
func TestTheStubQueuesBeyondItsCapacity(t *testing.T) {
	p := versionStudyStub()
	p.ttft = 300 * time.Millisecond
	p.metrics = true
	p.capacity = newStubCapacity(2)
	srv := httptest.NewServer(stubMux(p, newStubStats()))
	defer srv.Close()
	body := `{"messages":[{"role":"user","content":"x"}],"max_tokens":2,"stream":true}`
	var wg sync.WaitGroup
	for range 5 {
		wg.Go(func() {
			resp, err := http.Post(srv.URL+"/v1/chat/completions", "application/json", strings.NewReader(body))
			if err == nil {
				_, _ = io.Copy(io.Discard, resp.Body)
				_ = resp.Body.Close()
			}
		})
	}
	deadline := time.Now().Add(2 * time.Second)
	for metricsLine(t, srv.URL, "vllm:num_requests_waiting") != "3" {
		if time.Now().After(deadline) {
			t.Fatalf("running %s waiting %s, want 2 and 3", metricsLine(t, srv.URL, "vllm:num_requests_running"), metricsLine(t, srv.URL, "vllm:num_requests_waiting"))
		}
		time.Sleep(10 * time.Millisecond)
	}
	if got := metricsLine(t, srv.URL, "vllm:num_requests_running"); got != "2" {
		t.Fatalf("running %s with a capacity of 2", got)
	}
	wg.Wait()
	if r, w := metricsLine(t, srv.URL, "vllm:num_requests_running"), metricsLine(t, srv.URL, "vllm:num_requests_waiting"); r != "0" || w != "0" {
		t.Fatalf("after every request ended: running %s waiting %s", r, w)
	}
}

// TestAQueuedRequestWhoseClientLeftLeavesTheQueue: an abandoned wait must not hold a place the drain check counts.
func TestAQueuedRequestWhoseClientLeftLeavesTheQueue(t *testing.T) {
	p := versionStudyStub()
	p.ttft = time.Second
	p.metrics = true
	p.capacity = newStubCapacity(1)
	srv := httptest.NewServer(stubMux(p, newStubStats()))
	defer srv.Close()
	body := `{"messages":[{"role":"user","content":"x"}],"max_tokens":2,"stream":true}`
	go func() {
		resp, err := http.Post(srv.URL+"/v1/chat/completions", "application/json", strings.NewReader(body))
		if err == nil {
			_, _ = io.Copy(io.Discard, resp.Body)
			_ = resp.Body.Close()
		}
	}()
	ctx, cancel := context.WithCancel(context.Background())
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, srv.URL+"/v1/chat/completions", strings.NewReader(body))
	done := make(chan struct{})
	go func() {
		defer close(done)
		if resp, err := http.DefaultClient.Do(req); err == nil {
			_ = resp.Body.Close()
		}
	}()
	deadline := time.Now().Add(2 * time.Second)
	for metricsLine(t, srv.URL, "vllm:num_requests_waiting") != "1" {
		if time.Now().After(deadline) {
			t.Fatal("the second request never queued")
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	<-done
	deadline = time.Now().Add(2 * time.Second)
	for metricsLine(t, srv.URL, "vllm:num_requests_waiting") != "0" {
		if time.Now().After(deadline) {
			t.Fatal("an abandoned request stayed in the queue")
		}
		time.Sleep(10 * time.Millisecond)
	}
}
