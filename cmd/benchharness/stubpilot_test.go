package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
)

// The pilot's stub writes a step log and iteration lines that agree step for step, honours each request's cap,
// and answers the sentinel with a complete terminal record: the evidence the pilot's eligibility rules read.
//
// Mutation that turns it red: print the iteration line with a different index from the sched record, or drop
// the per-request cap.
func TestStubPilotModeWritesAlignedEvidence(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "step.jsonl")
	var iters bytes.Buffer
	pl, err := openStubPilotLog(path, &iters)
	if err != nil {
		t.Fatal(err)
	}
	stop := make(chan struct{})
	defer close(stop)
	go pl.watchSentinel(stop)
	srv := httptest.NewServer(stubMux(stubProfile{tokens: 8, pilot: pl, usage: true}, newStubStats()))
	defer srv.Close()

	send := func(id string, prio, cap int) int {
		body := `{"model":"m","messages":[{"role":"user","content":"` + strings.Repeat("a", 200) + `"}],"max_tokens":` +
			strconv.Itoa(cap) + `,"min_tokens":` + strconv.Itoa(cap) + `,"priority":` + strconv.Itoa(prio) + `,"stream":true}`
		req, _ := http.NewRequest(http.MethodPost, srv.URL+"/v1/chat/completions", strings.NewReader(body))
		req.Header.Set("X-Request-Id", id)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		b, _ := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		return strings.Count(string(b), `"content":"x"`)
	}
	if n := send("pp-A-off-1-0", 0, 4); n != 4 {
		t.Fatalf("a request capped at 4 produced %d tokens", n)
	}
	if n := send("pp-A-off-1-1", 1, 2); n != 2 {
		t.Fatalf("a request capped at 2 produced %d tokens", n)
	}
	if err := os.WriteFile(path+".sentinel", nil, 0o644); err != nil {
		t.Fatal(err)
	}
	var recs []map[string]any
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		recs = nil
		f, _ := os.Open(path)
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			var m map[string]any
			_ = json.Unmarshal(sc.Bytes(), &m)
			recs = append(recs, m)
		}
		_ = f.Close()
		if len(recs) > 0 && recs[len(recs)-1]["ev"] == "terminal" {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if len(recs) == 0 || recs[len(recs)-1]["ev"] != "terminal" {
		t.Fatal("no terminal record after the sentinel")
	}

	var seqs []int
	var sched []map[string]any
	prio := map[string]any{}
	for _, r := range recs {
		if s, ok := r["seq"].(float64); ok {
			seqs = append(seqs, int(s))
		}
		switch r["ev"] {
		case "sched":
			sched = append(sched, r)
		case "add":
			prio[r["id"].(string)] = r["priority"]
		}
	}
	for i, s := range seqs {
		if s != i+1 {
			t.Fatalf("sequence numbers are not 1..n without a gap: %v", seqs)
		}
	}
	term := recs[len(recs)-1]
	if int(term["seq_produced"].(float64)) != len(seqs) || term["buffered"].(float64) != 0 {
		t.Fatalf("the terminal record is not complete: %v", term)
	}
	if prio["chatcmpl-pp-A-off-1-0"] != float64(0) || prio["chatcmpl-pp-A-off-1-1"] != float64(1) {
		t.Fatalf("the add records do not carry the requests' priorities: %v", prio)
	}

	lines := strings.Split(strings.TrimSpace(iters.String()), "\n")
	if len(lines) != len(sched) || len(sched) != 1+3+1+1 {
		t.Fatalf("%d iteration lines for %d steps, want 6 of each (a prefill and cap-1 decodes per request)", len(lines), len(sched))
	}
	re := regexp.MustCompile(`^\(APIServer pid=1\) INFO \d\d-\d\d \d\d:\d\d:\d\d \[loggers\.py:182\] Engine 000: Iteration\((\d+)\): \d+ context requests, (\d+) context tokens, \d+ generation requests, (\d+) generation tokens`)
	for k, line := range lines {
		m := re.FindStringSubmatch(line)
		if m == nil {
			t.Fatalf("iteration line %d is not in vLLM's form: %s", k, line)
		}
		idx, _ := strconv.Atoi(m[1])
		ctx, _ := strconv.Atoi(m[2])
		gen, _ := strconv.Atoi(m[3])
		step := int(sched[k]["step"].(float64))
		total := 0
		for _, v := range sched[k]["tokens"].(map[string]any) {
			total += int(v.(float64))
		}
		if idx != step-1 || ctx+gen != total {
			t.Fatalf("iteration %d (tokens %d) does not match plugin step %d (tokens %d)", idx, ctx+gen, step, total)
		}
	}
}

// With usage reporting off, a prompt outside the frozen table still logs its fallback count, not zero.
//
// Mutation that turns it red: compute prompt counts only when usage is reported (the review of 60f3674).
func TestStubPilotModeCountsPromptsWithoutUsage(t *testing.T) {
	path := filepath.Join(t.TempDir(), "step.jsonl")
	pl, err := openStubPilotLog(path, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(stubMux(stubProfile{tokens: 1, pilot: pl}, newStubStats()))
	defer srv.Close()
	body := `{"model":"m","messages":[{"role":"user","content":"` + strings.Repeat("a", 100) + `"}],"max_tokens":1,"stream":true}`
	resp, err := http.Post(srv.URL+"/v1/chat/completions", "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for line := range strings.SplitSeq(strings.TrimSpace(string(b)), "\n") {
		var m map[string]any
		_ = json.Unmarshal([]byte(line), &m)
		if m["ev"] == "add" {
			if got := int(m["prompt"].(float64)); got != stubPromptTokens(100) {
				t.Fatalf("a 100-character prompt logged %d prompt tokens, want %d", got, stubPromptTokens(100))
			}
			return
		}
	}
	t.Fatal("no add record")
}

// A stopped step log records nothing from the named request on, still answers the sentinel complete for what it
// recorded, and leaves the engine's iteration lines going: the shape only the fence and the alignment can catch.
//
// Mutation that turns it red: keep writing after the stop.
func TestStubPilotLogStopsRecordingAtTheNamedRequest(t *testing.T) {
	path := filepath.Join(t.TempDir(), "step.jsonl")
	var iters bytes.Buffer
	pl, err := openStubPilotLog(path, &iters)
	if err != nil {
		t.Fatal(err)
	}
	pl.stopAt = "pp-A-off-2-"
	p := 0
	pl.add("chatcmpl-pp-A-off-2-0", &p, 68)
	pl.stepFor("chatcmpl-pp-A-off-2-0", 68, 0, true)
	pl.add("chatcmpl-fence-off-2", &p, 1)
	pl.stepFor("chatcmpl-fence-off-2", 1, 0, true)
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(b) != 0 {
		t.Fatalf("the stopped log recorded:\n%s", b)
	}
	if n := strings.Count(iters.String(), "Iteration("); n != 2 {
		t.Fatalf("the engine printed %d iteration lines, want 2", n)
	}
	if pl.seq != 0 {
		t.Fatalf("the stopped log counted %d records it did not write", pl.seq)
	}
}
