package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

const committedContract = "../../experiments/a10g-capacity/kit/contract.json"

func loadCommitted(t *testing.T) Contract {
	t.Helper()
	c, err := LoadContract(committedContract)
	if err != nil {
		t.Fatalf("the committed contract does not load: %v", err)
	}
	return c
}

// TestCommittedContractMatchesTheBuild: the contract names this build's image, profile and measured prompt length.
func TestCommittedContractMatchesTheBuild(t *testing.T) {
	c := loadCommitted(t)
	if c.Workload.InputTokens != 512 || c.Workload.OutputTokens != 128 {
		t.Fatalf("workload %d/%d tokens, the contract document says 512/128", c.Workload.InputTokens, c.Workload.OutputTokens)
	}
}

// TestContractRefusesWhatTheBuildCannotRun: each field the build pins is checked, so a drifted contract stops the kit.
func TestContractRefusesWhatTheBuildCannotRun(t *testing.T) {
	for name, mutate := range map[string]func(*Contract){
		"image":       func(c *Contract) { c.Workload.EngineImage = "vllm/vllm-openai:v0.27.1" },
		"profile":     func(c *Contract) { c.Workload.EngineProfile = "v0.27.1-a10g-prefix-cache" },
		"prefix":      func(c *Contract) { c.Workload.PrefixCaching = "on" },
		"chars":       func(c *Contract) { c.Workload.InputChars = 2500 },
		"tokens":      func(c *Contract) { c.Workload.InputTokens = 500 },
		"temperature": func(c *Contract) { c.Workload.Temperature = 0.7 },
		"eos":         func(c *Contract) { c.Workload.IgnoreEOS = false },
		"arrivals":    func(c *Contract) { c.Workload.ArrivalModel = "closed-loop" },
		"revision":    func(c *Contract) { c.Workload.ModelRevision = "main" },
		"stream":      func(c *Contract) { c.Workload.Stream = false },
		"interval":    func(c *Contract) { c.Restart.ProbeIntervalMs = 0 },
		"probe":       func(c *Contract) { c.Restart.ProbeTimeoutS = -1 },
		"bound":       func(c *Contract) { c.Restart.BoundS = 0 },
		"count":       func(c *Contract) { c.Restart.Count = 0 },
	} {
		c := loadCommitted(t)
		mutate(&c)
		if err := c.Check(); err == nil {
			t.Errorf("%s: a drifted contract was accepted", name)
		}
	}
}

// TestEngineCommandIsTheValidatedProfile: the container runs the list the controller renders for v0.27.1-a10g.
func TestEngineCommandIsTheValidatedProfile(t *testing.T) {
	got, err := loadCommitted(t).EngineCommand()
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"Qwen/Qwen2.5-3B-Instruct",
		"--dtype=half", "--max-model-len=16384", "--max-num-seqs=64", "--gpu-memory-utilization=0.90",
		"--no-enable-prefix-caching", "--max-num-batched-tokens=512", "--scheduling-policy=priority", "--no-async-scheduling",
		"--port=8000", "--served-model-name=qwen2.5-3b-instruct",
		"--revision=aa8e72537993ba99e69dfaafa59ed015b17504d1", "--tokenizer-revision=aa8e72537993ba99e69dfaafa59ed015b17504d1"}
	if !slices.Equal(got, want) {
		t.Fatalf("got %v\nwant %v", got, want)
	}
}

// TestBuildTraceIsSeededAndSegmented: one seed gives one trace, every row lies in its segment, and the counts follow the rates.
func TestBuildTraceIsSeededAndSegmented(t *testing.T) {
	segs, err := ParseSegments("baseline:2:150,saturation:10:150,overload:15:90,recovery:2:240")
	if err != nil {
		t.Fatal(err)
	}
	a, sa := BuildTrace(segs, 6750, 2506, 512, 128)
	b, _ := BuildTrace(segs, 6750, 2506, 512, 128)
	c, _ := BuildTrace(segs, 6751, 2506, 512, 128)
	if !slices.Equal(a, b) {
		t.Fatal("one seed drew two traces")
	}
	if slices.Equal(a, c) {
		t.Fatal("two seeds drew one trace")
	}
	byName := map[string]Segment{}
	total := 0
	for _, s := range sa {
		byName[s.Name] = s
		total += s.Planned
		want := s.RateRPS * s.DurationS
		// Five standard deviations of a Poisson count, so a correct generator fails this about never.
		if d := float64(s.Planned) - want; d*d > 25*want {
			t.Errorf("%s planned %d, expected about %.0f", s.Name, s.Planned, want)
		}
	}
	if total != len(a) || sa[3].EndMs != 630_000 || sa[1].StartMs != 150_000 {
		t.Fatalf("segments %+v do not tile the trace of %d rows", sa, len(a))
	}
	prev := int64(-1)
	for i, r := range a {
		s := byName[r.Tenant]
		if r.Index != i || r.OffsetMs < s.StartMs || r.OffsetMs >= s.EndMs || r.OffsetMs < prev {
			t.Fatalf("row %+v is outside its segment %+v or out of order", r, s)
		}
		if r.PromptLenChars != 2506 || r.ExactInputTokens != 512 || r.MaxOutputTokens != 128 {
			t.Fatalf("row %+v does not carry the workload", r)
		}
		prev = r.OffsetMs
	}
}

func TestParseSegmentsRefusesBadInput(t *testing.T) {
	for _, s := range []string{"", "a:1", "a:0:10", "a:1:-1", "a:1:10,a:2:10", ":1:1", "a:NaN:1", "a:Inf:1"} {
		if _, err := ParseSegments(s); err == nil {
			t.Errorf("%q was accepted", s)
		}
	}
}

// fakeEngine answers like vLLM's streaming chat endpoint: 512 prompt tokens for the contract's prompt and exactly max_tokens frames.
func fakeEngine(t *testing.T, ready *atomic.Bool) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if ready != nil && !ready.Load() {
			http.Error(w, "loading", http.StatusServiceUnavailable)
			return
		}
		var body struct {
			MaxTokens int  `json:"max_tokens"`
			MinTokens int  `json:"min_tokens"`
			IgnoreEOS bool `json:"ignore_eos"`
			Messages  []struct {
				Content string `json:"content"`
			} `json:"messages"`
		}
		raw, _ := io.ReadAll(r.Body)
		if err := json.Unmarshal(raw, &body); err != nil || body.MinTokens != body.MaxTokens || !body.IgnoreEOS {
			http.Error(w, "not the contract's body: "+string(raw), http.StatusBadRequest)
			return
		}
		prompt := len(body.Messages[0].Content) / 4
		if len(body.Messages[0].Content) == 2506 {
			prompt = 512
		}
		f := w.(http.Flusher)
		w.Header().Set("Content-Type", "text/event-stream")
		for i := range body.MaxTokens {
			fr := "null"
			if i == body.MaxTokens-1 {
				fr = `"length"`
			}
			_, _ = fmt.Fprintf(w, "data: {\"choices\":[{\"delta\":{\"content\":\"x\"},\"finish_reason\":%s}]}\n\n", fr)
			f.Flush()
		}
		_, _ = fmt.Fprintf(w, "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":%d,\"completion_tokens\":%d}}\n\ndata: [DONE]\n\n", prompt, body.MaxTokens)
	}))
}

// TestStageReplaysAndReconciles: a short stage against a fake engine completes every row and records a reconciled ledger.
func TestStageReplaysAndReconciles(t *testing.T) {
	srv := fakeEngine(t, nil)
	defer srv.Close()
	dir := filepath.Join(t.TempDir(), "stage")
	var out strings.Builder
	err := stageCmd([]string{"--contract", committedContract, "--segments", "a:40:0.5,b:20:0.5", "--seed", "7",
		"--target", srv.URL, "--out", dir, "--request-id-prefix", "t-stage"}, &out)
	if err != nil {
		t.Fatal(err)
	}
	rows := readRows(t, filepath.Join(dir, "raw.jsonl"))
	live := readRows(t, filepath.Join(dir, "raw.live.jsonl"))
	if len(rows) == 0 || len(live) != len(rows) {
		t.Fatalf("%d rows, %d live rows", len(rows), len(live))
	}
	for _, r := range rows {
		if r.Disposition != bench.DispositionCompleted || r.EngineInputTokens != 512 || r.EngineOutputTokens != 128 || r.FinishReason != "length" {
			t.Fatalf("row %+v did not complete under the contract", r)
		}
		if r.Clock == nil || r.Clock.DoneNanos == nil || r.Clock.FirstContentNanos == nil || r.Clock.IntendedNanos == nil {
			t.Fatalf("row %d lacks the clock the analysis reads", r.Index)
		}
	}
	var meta StageMeta
	b, _ := os.ReadFile(filepath.Join(dir, "meta.json"))
	if err := json.Unmarshal(b, &meta); err != nil || meta.Reconciled == nil || !*meta.Reconciled || meta.Rows != len(rows) {
		t.Fatalf("meta %s", b)
	}
	// A second run into the same directory is refused, so stale rows can never be read as this run's.
	if err := stageCmd([]string{"--contract", committedContract, "--segments", "a:1:1", "--seed", "7",
		"--target", srv.URL, "--out", dir, "--request-id-prefix", "t"}, &out); err == nil {
		t.Fatal("an existing stage directory was reused")
	}
}

func readRows(t *testing.T, path string) []bench.RawRow {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = f.Close() }()
	rows, err := bench.ReadRawRows(bufio.NewReader(f))
	if err != nil {
		t.Fatal(err)
	}
	return rows
}

func shortRestart(c Contract) Contract {
	c.Restart.ProbeIntervalMs = 20
	c.Restart.ProbeTimeoutS = 2
	c.Restart.BoundS = 1
	return c
}

// TestRestartTimesTheFirstSuccessfulProbe: the window runs from the kill to the first probe the contract calls successful.
func TestRestartTimesTheFirstSuccessfulProbe(t *testing.T) {
	var ready atomic.Bool
	ready.Store(true)
	srv := fakeEngine(t, &ready)
	defer srv.Close()
	var calls []string
	Shell = func(_ context.Context, line string) error {
		calls = append(calls, line)
		switch line {
		case "kill":
			ready.Store(false)
		case "start":
			go func() {
				// The engine comes back while probes are already being refused.
				<-timeAfterMs(150)
				ready.Store(true)
			}()
		}
		return nil
	}
	defer func() { Shell = shellDefault }()
	rec := Restart(context.Background(), shortRestart(loadCommitted(t)), srv.URL, "kill", "start", 1)
	if rec.Outcome != "serving" || rec.WindowMs == nil || *rec.WindowMs < 150 {
		t.Fatalf("record %+v", rec)
	}
	if !slices.Equal(calls, []string{"kill", "start"}) {
		t.Fatalf("commands %v", calls)
	}
	if len(rec.Probes) < 2 || rec.Probes[0].OK || rec.Probes[0].HTTPStatus != http.StatusServiceUnavailable || !rec.Probes[len(rec.Probes)-1].OK {
		t.Fatalf("probes %+v: the refused probes before the first success are part of the record", rec.Probes)
	}
}

// TestRestartReportsAnEngineThatNeverServes: no success inside the bound is an outcome, not a window.
func TestRestartReportsAnEngineThatNeverServes(t *testing.T) {
	var ready atomic.Bool
	srv := fakeEngine(t, &ready)
	defer srv.Close()
	Shell = func(context.Context, string) error { return nil }
	defer func() { Shell = shellDefault }()
	rec := Restart(context.Background(), shortRestart(loadCommitted(t)), srv.URL, "kill", "start", 1)
	if rec.WindowMs != nil || !strings.HasPrefix(rec.Outcome, "not serving within") || len(rec.Probes) == 0 {
		t.Fatalf("record %+v", rec)
	}
}

// TestProbeOKNeedsTheTokenContract: a 200 with [DONE] but the wrong counts is not a successful probe.
func TestProbeOKNeedsTheTokenContract(t *testing.T) {
	good := bench.SendResult{HTTPStatus: 200, StreamTerminated: true, PromptTokens: 512, EngineOutputTokens: 16, FinishReason: "length"}
	if !probeOK(good, 512, 16) {
		t.Fatal("the contract's probe was refused")
	}
	for name, r := range map[string]bench.SendResult{
		"prompt": {HTTPStatus: 200, StreamTerminated: true, PromptTokens: 511, EngineOutputTokens: 16, FinishReason: "length"},
		"output": {HTTPStatus: 200, StreamTerminated: true, PromptTokens: 512, EngineOutputTokens: 15, FinishReason: "length"},
		"finish": {HTTPStatus: 200, StreamTerminated: true, PromptTokens: 512, EngineOutputTokens: 16, FinishReason: "stop"},
		"done":   {HTTPStatus: 200, PromptTokens: 512, EngineOutputTokens: 16, FinishReason: "length"},
		"status": {HTTPStatus: 503},
	} {
		if probeOK(r, 512, 16) {
			t.Errorf("%s: accepted %+v", name, r)
		}
	}
}

var shellDefault = Shell

func timeAfterMs(n int) <-chan time.Time { return time.After(time.Duration(n) * time.Millisecond) }

// TestStageSendsTheAPIKeyOnEverySegment: the gateway refuses a request without the key, so every segment must carry it.
func TestStageSendsTheAPIKeyOnEverySegment(t *testing.T) {
	inner := fakeEngine(t, nil)
	defer inner.Close()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer k1" {
			http.Error(w, "no key", http.StatusUnauthorized)
			return
		}
		inner.Config.Handler.ServeHTTP(w, r)
	}))
	defer srv.Close()
	dir := filepath.Join(t.TempDir(), "stage")
	if err := stageCmd([]string{"--contract", committedContract, "--segments", "a:40:0.3,b:40:0.3", "--seed", "3",
		"--target", srv.URL, "--out", dir, "--request-id-prefix", "k", "--api-key", "k1"}, io.Discard); err != nil {
		t.Fatal(err)
	}
	for _, r := range readRows(t, filepath.Join(dir, "raw.jsonl")) {
		if r.Disposition != bench.DispositionCompleted {
			t.Fatalf("row %d of %s: %s %d", r.Index, r.Tenant, r.Disposition, r.HTTPStatus)
		}
	}
}

// TestRestartRefusesAnUnwritableRecordBeforeTheKill: no evidence file, no kill.
func TestRestartRefusesAnUnwritableRecordBeforeTheKill(t *testing.T) {
	var calls []string
	Shell = func(_ context.Context, line string) error { calls = append(calls, line); return nil }
	defer func() { Shell = shellDefault }()
	for _, out := range []string{filepath.Join(t.TempDir(), "missing", "r.json"), committedContract} {
		err := restartCmd([]string{"--contract", committedContract, "--target", "http://127.0.0.1:1", "--kill-cmd", "kill",
			"--start-cmd", "start", "--index", "1", "--out", out}, io.Discard)
		if err == nil {
			t.Fatalf("%s: the restart ran", out)
		}
	}
	if len(calls) != 0 {
		t.Fatalf("commands ran before the record was reserved: %v", calls)
	}
}
