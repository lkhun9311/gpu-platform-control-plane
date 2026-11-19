package main

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestPlanIsSeeded(t *testing.T) {
	a, _ := json.Marshal(BuildPlan(7, 2, 3))
	b, _ := json.Marshal(BuildPlan(7, 2, 3))
	c, _ := json.Marshal(BuildPlan(8, 2, 3))
	if string(a) != string(b) {
		t.Fatal("the same seed gave two plans")
	}
	if string(a) == string(c) {
		t.Fatal("two seeds gave the same plan")
	}
}

func TestPlanShapes(t *testing.T) {
	plan := BuildPlan(20261119, 1, 4)
	seen := map[string]int{}
	for _, s := range plan {
		if s.Measured {
			seen[s.Hyp+"/"+s.Case+"/"+s.Phase]++
		}
		for _, tok := range s.Tokens {
			if tok < tokenLow || tok >= tokenHigh {
				t.Fatalf("%s draws token %d outside the plain vocabulary range", s.ID, tok)
			}
		}
	}
	for _, k := range []string{"calib/shared512/probe", "bias/shared528/probe", "bias/repeat512/probe", "bias/repeat600/probe",
		"salt/salted512/probe", "mm/image/probe", "dedup/full/pre", "dedup/full/post", "dedup/incremental/post"} {
		if seen[k] != 1 {
			t.Errorf("measured row %s appears %d times, want 1", k, seen[k])
		}
	}
	// The dedup post rows must come after every flood row, or the eviction they measure has not happened yet.
	lastFlood, firstPost := -1, -1
	for i, s := range plan {
		if s.Phase == "flood" {
			lastFlood = i
		}
		if s.Phase == "post" && firstPost < 0 {
			firstPost = i
		}
	}
	if lastFlood < 0 || firstPost < lastFlood {
		t.Fatalf("post rows start at %d, before the last flood row %d", firstPost, lastFlood)
	}
	// Only the full-report case's repeats carry the report mode, so the incremental case is the control.
	for _, s := range plan {
		if s.ReportFull != (s.Hyp == "dedup" && s.Case == "full" && s.Phase == "repeat") {
			t.Fatalf("%s has report_full=%v", s.ID, s.ReportFull)
		}
	}
}

// rows runs the probe against two fake replicas and returns its measured rows by hypothesis/case.
func rows(t *testing.T, reportFull bool) map[string]record {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	httpPort, err := freePort()
	if err != nil {
		t.Fatal(err)
	}
	zmqPort, err := freePort()
	if err != nil {
		t.Fatal(err)
	}
	// 64 blocks of 64 tokens is 4,096 tokens, so six 1,024-token flood prompts evict everything older.
	for _, addr := range []string{"127.0.0.1", "127.0.0.2"} {
		_, stop, err := startFake(ctx, addr, httpPort, zmqPort, 64, 64, reportFull)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(stop)
	}
	pods, err := parsePods("a=127.0.0.1,b=127.0.0.2", httpPort, zmqPort)
	if err != nil {
		t.Fatal(err)
	}
	out := t.TempDir()
	// PROBE_OUT keeps the records, so the session's offline test can run the verdict on what this test produced.
	if dir := os.Getenv("PROBE_OUT"); dir != "" {
		out = filepath.Join(dir, map[bool]string{true: "report", false: "noreport"}[reportFull])
	}
	o := options{pods: pods, model: "qwen2vl", renderURL: pods[0].base(), out: out, seed: 20261119, reps: 1, flood: 6,
		blockSizes: []int{16, 64}, topicFilter: "kv@", quiet: 150 * time.Millisecond, grace: 100 * time.Millisecond,
		maxSettle: 3 * time.Second, subscribeS: 1500 * time.Millisecond}
	if err := run(ctx, o, io.Discard); err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(filepath.Join(out, "requests.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	got := map[string]record{}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<24)
	for sc.Scan() {
		var r record
		if err := json.Unmarshal(sc.Bytes(), &r); err != nil {
			t.Fatal(err)
		}
		if r.Measured {
			got[r.Hyp+"/"+r.Case+"/"+r.Phase] = r
		}
	}
	return got
}

type want struct {
	realized, r16, r64 int
}

func check(t *testing.T, got map[string]record, key string, w want) {
	t.Helper()
	r, ok := got[key]
	if !ok {
		t.Errorf("%s: no row", key)
		return
	}
	if r.RealizedCached != w.realized || r.Predictions["r16"]["a"].CachedTokens != w.r16 || r.Predictions["r64"]["a"].CachedTokens != w.r64 {
		t.Errorf("%s: realized=%d r16=%d r64=%d, want realized=%d r16=%d r64=%d (err %q)", key, r.RealizedCached,
			r.Predictions["r16"]["a"].CachedTokens, r.Predictions["r64"]["a"].CachedTokens, w.realized, w.r16, w.r64, r.Error)
	}
	if r.Predictions["r16"]["b"].CachedTokens != 0 || r.Predictions["r64"]["b"].CachedTokens != 0 {
		t.Errorf("%s: pod b, which served nothing, is predicted to hold %d / %d tokens", key,
			r.Predictions["r16"]["b"].CachedTokens, r.Predictions["r64"]["b"].CachedTokens)
	}
	if r.RouterTokens != r.EngineTokens {
		t.Errorf("%s: the router counted %d prompt tokens and the engine %d", key, r.RouterTokens, r.EngineTokens)
	}
}

// TestProbeAgainstFakeVLLM runs the pinned router's producers on the event stream of an engine with vLLM's block and eviction rules.
// It shows, before anything is bought, what each hypothesis predicts the session will record, through the same code the session runs.
func TestProbeAgainstFakeVLLM(t *testing.T) {
	got := rows(t, true)
	// Calibration: an aligned shared prefix, where every side agrees.
	check(t, got, "calib/shared512/probe", want{512, 512, 512})
	// H1: a prefix ending inside an engine block is credited at the router's 16-token granularity, which the engine cannot serve.
	check(t, got, "bias/shared528/probe", want{512, 512, 512})
	check(t, got, "bias/shared544/probe", want{512, 544, 512})
	check(t, got, "bias/shared560/probe", want{512, 560, 512})
	// H1: a whole-prompt hit is credited in full, but the engine recomputes the last token and so the whole last block.
	check(t, got, "bias/repeat512/probe", want{448, 512, 512})
	check(t, got, "bias/repeat576/probe", want{512, 576, 576})
	check(t, got, "bias/repeat600/probe", want{576, 576, 576})
	// The known #3788: with a salt the 1:many realign salts every sub-block, so router 16 matches only block 0.
	check(t, got, "salt/salted512/probe", want{512, 16, 512})
	// H2: before the flood both prefixes are served and predicted in full.
	check(t, got, "dedup/full/pre", want{1024, 1024, 1024})
	check(t, got, "dedup/incremental/pre", want{1024, 1024, 1024})
	// H2: after the engine evicted both, the reused-block reports keep the full-report prefix in the index.
	check(t, got, "dedup/full/post", want{0, 1024, 1024})
	check(t, got, "dedup/incremental/post", want{0, 0, 0})
	// The fake has no /render, so the chat row records the token producer's failure rather than a prediction.
	if r := got["mm/image/probe"]; r.Error == "" || len(r.Predictions) != 0 {
		t.Errorf("mm/image/probe: want a recorded render failure, got error %q and %d predictions", r.Error, len(r.Predictions))
	}
}

// TestProbeWithoutReports is the control for H2: an engine that sends no reused-block reports leaves nothing stale.
func TestProbeWithoutReports(t *testing.T) {
	got := rows(t, false)
	check(t, got, "dedup/full/post", want{0, 0, 0})
	check(t, got, "dedup/incremental/post", want{0, 0, 0})
}
