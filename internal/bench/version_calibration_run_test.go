package bench

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// smallRule is a rung of 10 s warm-up, 20 s window and 5 s drain, so synthetic rows stay readable.
func smallRule() CalibrationRule {
	r := versionAsyncDesign().Calibration
	r.WarmupSeconds, r.WindowSeconds, r.DrainSeconds = 10, 20, 5
	return r
}

// rungRow is a row that arrived at intended seconds and ended at terminal seconds, or never when terminal is negative.
func rungRow(i int, intended, terminal float64, disposition string) RawRow {
	sec := float64(time.Second)
	in := int64(intended * sec)
	r := RawRow{Index: i, Disposition: disposition, Clock: &RequestClock{IntendedNanos: &in}}
	if terminal >= 0 {
		te := int64(terminal * sec)
		r.Clock.TerminalNanos = &te
	}
	return r
}

// TestObserveRungCountsTheWindowFromTheRowsOwnClock checks every field against a hand-built rung.
func TestObserveRungCountsTheWindowFromTheRowsOwnClock(t *testing.T) {
	rule := smallRule()
	rows := []RawRow{
		rungRow(0, 5, 12, DispositionCompleted),  // warm-up arrival, departs in the window, in flight at its start
		rungRow(1, 11, 13, DispositionCompleted), // window arrival and departure
		rungRow(2, 15, 16, "timeout"),            // window arrival that failed
		rungRow(3, 28, 31, DispositionCompleted), // window arrival in flight at the window's end, resolved inside the drain
		rungRow(4, 29, 36, DispositionCompleted), // window arrival resolved after the drain deadline
		rungRow(5, 30, 31, DispositionCompleted), // arrives exactly at the window's end: not an arrival of it
	}
	o, err := ObserveRung(rows, 2, rule, true)
	if err != nil {
		t.Fatal(err)
	}
	if o.Arrivals != 4 || o.Departures != 3 || o.Failures != 1 || o.UnresolvedAtDrain != 1 {
		t.Fatalf("arrivals %d departures %d failures %d unresolved %d, want 4 3 1 1", o.Arrivals, o.Departures, o.Failures, o.UnresolvedAtDrain)
	}
	if o.OutstandingStart != 1 || o.OutstandingEnd != 2 {
		t.Fatalf("outstanding %d -> %d, want 1 -> 2", o.OutstandingStart, o.OutstandingEnd)
	}
	if o.WindowSeconds != 20 || o.OfferedRate != 2 || !o.StartedDrained || math.IsNaN(o.OutstandingSlopePerSec) {
		t.Fatalf("observation %+v", o)
	}
}

// TestObserveRungRefusesRowsWithoutAClock: a rung measured without intended arrivals cannot be placed in its window, so it is not guessed.
func TestObserveRungRefusesRowsWithoutAClock(t *testing.T) {
	rule := smallRule()
	for name, row := range map[string]RawRow{
		"no clock":       {Index: 0, Disposition: DispositionCompleted},
		"no intended":    {Index: 0, Disposition: DispositionCompleted, Clock: &RequestClock{}},
		"no disposition": rungRow(0, 11, 12, ""),
	} {
		if _, err := ObserveRung([]RawRow{row}, 1, rule, true); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

// TestObserveRungUnresolvedCountsARequestThatNeverEnded: a request still open when the replay returned is past any deadline.
func TestObserveRungUnresolvedCountsARequestThatNeverEnded(t *testing.T) {
	o, err := ObserveRung([]RawRow{rungRow(0, 12, -1, DispositionCompleted)}, 1, smallRule(), true)
	if err != nil {
		t.Fatal(err)
	}
	if o.UnresolvedAtDrain != 1 || o.Departures != 0 {
		t.Fatalf("unresolved %d departures %d, want 1 0", o.UnresolvedAtDrain, o.Departures)
	}
}

// TestCalibrationTraceIsSeededByOrdinalAndCutAtTheRung: rung traces never reuse a block's seed and span exactly warm-up plus window.
func TestCalibrationTraceIsSeededByOrdinalAndCutAtTheRung(t *testing.T) {
	d := versionAsyncDesign()
	rule := d.Calibration
	a, err := d.CalibrationTrace(1, 3)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := d.CalibrationTrace(2, 3)
	if len(a) == 0 || a[0] == b[0] {
		t.Fatal("two ordinals gave the same opening row")
	}
	end := int64(rule.WarmupSeconds+rule.WindowSeconds) * 1000
	for _, r := range a {
		if r.OffsetMs >= end || r.ExactInputTokens == 0 {
			t.Fatalf("row %+v is past the rung or carries no frozen token count", r)
		}
	}
	if got := float64(len(a)) / float64(rule.WarmupSeconds+rule.WindowSeconds); math.Abs(got-3)/3 > 0.15 {
		t.Fatalf("rate %.2f, want about 3", got)
	}
	if _, err := d.CalibrationTrace(1, 0); err == nil {
		t.Fatal("a zero rate was accepted")
	}
}

// TestParseEngineQueueReadsRunningAndWaiting: the drained check reads the engine's own gauges, summed over series.
func TestParseEngineQueueReadsRunningAndWaiting(t *testing.T) {
	text := "# TYPE vllm:num_requests_running gauge\nvllm:num_requests_running{model_name=\"m\"} 2\n" +
		"# TYPE vllm:num_requests_waiting gauge\nvllm:num_requests_waiting{model_name=\"m\"} 3\n"
	running, waiting, err := ParseEngineQueue(strings.NewReader(text))
	if err != nil || running != 2 || waiting != 3 {
		t.Fatalf("running %d waiting %d err %v", running, waiting, err)
	}
	if _, _, err := ParseEngineQueue(strings.NewReader("# TYPE other gauge\nother 1\n")); err == nil {
		t.Fatal("metrics without the queue gauges were accepted as idle")
	}
	// Each of these would read as 0 running, which is the drained answer, while the engine says something else.
	idleWaiting := "# TYPE vllm:num_requests_waiting gauge\nvllm:num_requests_waiting 0\n"
	for name, running := range map[string]string{
		"a fraction":       "# TYPE vllm:num_requests_running gauge\nvllm:num_requests_running 0.5\n",
		"a counter":        "# TYPE vllm:num_requests_running counter\nvllm:num_requests_running 2\n",
		"a negative count": "# TYPE vllm:num_requests_running gauge\nvllm:num_requests_running -1\n",
		"NaN":              "# TYPE vllm:num_requests_running gauge\nvllm:num_requests_running NaN\n",
		"an overflow":      "# TYPE vllm:num_requests_running gauge\nvllm:num_requests_running 1e300\n",
	} {
		if r, w, err := ParseEngineQueue(strings.NewReader(running + idleWaiting)); err == nil {
			t.Errorf("%s was read as running %d waiting %d", name, r, w)
		}
	}
	// An untyped exposition still carries the count, so it is read rather than refused.
	untyped := "vllm:num_requests_running 1\nvllm:num_requests_waiting 0\n"
	if r, w, err := ParseEngineQueue(strings.NewReader(untyped)); err != nil || r != 1 || w != 0 {
		t.Fatalf("untyped gauges read as running %d waiting %d err %v", r, w, err)
	}
}

// TestWaitDrainedReturnsOnlyOnAnIdleEngine: a rung starts drained or not at all.
func TestWaitDrainedReturnsOnlyOnAnIdleEngine(t *testing.T) {
	calls := 0
	idleAfter := func(n int) EngineQueueReader {
		return func(context.Context) (int, int, error) {
			calls++
			if calls > n {
				return 0, 0, nil
			}
			return 1, 0, nil
		}
	}
	if !WaitDrained(context.Background(), idleAfter(2), time.Second, time.Millisecond) {
		t.Fatal("an engine idle after two polls was not seen drained")
	}
	calls = 0
	if WaitDrained(context.Background(), idleAfter(1<<30), 20*time.Millisecond, time.Millisecond) {
		t.Fatal("a busy engine was seen drained")
	}
	waitingOnly := func(context.Context) (int, int, error) { return 0, 2, nil }
	if WaitDrained(context.Background(), waitingOnly, 20*time.Millisecond, time.Millisecond) {
		t.Fatal("an engine with waiting requests and none running was seen drained")
	}
	failing := func(context.Context) (int, int, error) { return 0, 0, errors.New("unreachable") }
	if WaitDrained(context.Background(), failing, 20*time.Millisecond, time.Millisecond) {
		t.Fatal("an unreachable engine was seen drained")
	}
}

// stubEngine serves conforming SSE responses after delay, and its own queue gauges at /metrics.
//
// A conforming response reports the registered prompt count for the prompt's size and exactly the requested output, ended by length.
// shortOutput makes it report one output token whatever was asked, as an engine ignoring the requested length would.
func stubEngine(t *testing.T, delay time.Duration, busyMetrics bool) (*httptest.Server, *atomic.Int64) {
	return stubEngineWith(t, delay, busyMetrics, false)
}

func stubEngineWith(t *testing.T, delay time.Duration, busyMetrics, shortOutput bool) (*httptest.Server, *atomic.Int64) {
	t.Helper()
	var inflight, served atomic.Int64
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		served.Add(1)
		inflight.Add(1)
		defer inflight.Add(-1)
		var body struct {
			MaxTokens int `json:"max_tokens"`
			Messages  []struct {
				Content string `json:"content"`
			} `json:"messages"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		time.Sleep(delay)
		out := body.MaxTokens
		if shortOutput {
			out = 1
		}
		prompt := 0
		if len(body.Messages) > 0 {
			prompt = versionStudyExactTokens()[len(body.Messages[0].Content)]
		}
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, `data: {"choices":[{"delta":{"content":"a"}}]}`+"\n\n")
		_, _ = io.WriteString(w, `data: {"choices":[{"delta":{"content":"b"},"finish_reason":"length"}]}`+"\n\n")
		_, _ = fmt.Fprintf(w, "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":%d,\"completion_tokens\":%d}}\n\n", prompt, out)
		_, _ = io.WriteString(w, "data: [DONE]\n\n")
	})
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, _ *http.Request) {
		running := inflight.Load()
		if busyMetrics {
			running = 1
		}
		_, _ = fmt.Fprintf(w, "vllm:num_requests_running %d\nvllm:num_requests_waiting 0\n", running)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv, &served
}

// fastDesign is the registered design with a 1 s warm-up, 3 s window and 2 s drain, so a rung runs in seconds.
func fastDesign() VersionStudyDesign {
	d := versionAsyncDesign()
	d.Calibration.WarmupSeconds, d.Calibration.WindowSeconds, d.Calibration.DrainSeconds = 1, 3, 2
	return d
}

// TestRungRunnerClassifiesAgainstAStubEngine runs whole rungs: a fast engine is stable, a saturated one unstable, a never-idle one invalid.
func TestRungRunnerClassifiesAgainstAStubEngine(t *testing.T) {
	for name, c := range map[string]struct {
		delay time.Duration
		rate  float64
		busy  bool
		want  RungClass
	}{
		"fast engine at a low rate":      {10 * time.Millisecond, 5, false, RungStable},
		"slow engine behind its load":    {2500 * time.Millisecond, 20, false, RungUnstable},
		"engine that never reports idle": {10 * time.Millisecond, 5, true, RungInvalid},
	} {
		t.Run(name, func(t *testing.T) {
			srv, served := stubEngine(t, c.delay, c.busy)
			var got RungObservation
			r := &RungRunner{
				Design:    fastDesign(),
				Sender:    NewHTTPSender(srv.URL, "m", nil, 30*time.Second, SenderConn{MaxIdleConnsPerHost: 64, DrainForReuse: true}),
				Sampling:  *versionStudySampling(),
				Queue:     HTTPEngineQueue(srv.Client(), srv.URL+"/metrics"),
				PollEvery: 50 * time.Millisecond,
				OnRung:    func(_ int, _ []RawRow, o RungObservation, _ RungClass, _ error) { got = o },
			}
			if cls := r.Probe(context.Background(), c.rate, 1); cls != c.want {
				t.Fatalf("class %s, want %s (observation %+v)", cls, c.want, got)
			}
			// A rung that cannot start drained sends nothing, because on a paid instance every request costs.
			if c.busy && served.Load() != 0 {
				t.Fatalf("%d requests were sent to an engine that never reported idle", served.Load())
			}
		})
	}
}

// TestRungRunnerSendsTheRequestIDsItRecords: calibration rows are joined to the engine's own log by request id, so the id must be on the wire.
func TestRungRunnerSendsTheRequestIDsItRecords(t *testing.T) {
	var mu sync.Mutex
	ids := map[string]bool{}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		ids[r.Header.Get("X-Request-Id")] = true
		mu.Unlock()
		_, _ = io.Copy(io.Discard, r.Body)
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, `data: {"choices":[{"delta":{"content":"a"}}]}`+"\n\ndata: [DONE]\n\n")
	})
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "vllm:num_requests_running 0\nvllm:num_requests_waiting 0\n")
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	var rows []RawRow
	r := &RungRunner{
		Design:    fastDesign(),
		Sender:    NewHTTPSender(srv.URL, "m", nil, 5*time.Second, SenderConn{MaxIdleConnsPerHost: 8, DrainForReuse: true}),
		Sampling:  *versionStudySampling(),
		Queue:     HTTPEngineQueue(srv.Client(), srv.URL+"/metrics"),
		PollEvery: 10 * time.Millisecond,
		OnRung:    func(_ int, rs []RawRow, _ RungObservation, _ RungClass, _ error) { rows = rs },
	}
	r.Probe(context.Background(), 3, 4)
	if len(rows) == 0 {
		t.Fatal("no rows")
	}
	for _, row := range rows {
		if row.RequestID == "" || !ids[row.RequestID] {
			t.Fatalf("row %d records id %q, which was never sent", row.Index, row.RequestID)
		}
	}
}

// TestRungRunnerInvalidatesANonconformingEngine: an engine that ignores the requested length serves a lighter workload, and λ0 must not come from it.
func TestRungRunnerInvalidatesANonconformingEngine(t *testing.T) {
	srv, _ := stubEngineWith(t, 10*time.Millisecond, false, true)
	var gotErr error
	r := &RungRunner{
		Design:    fastDesign(),
		Sender:    NewHTTPSender(srv.URL, "m", nil, 30*time.Second, SenderConn{MaxIdleConnsPerHost: 64, DrainForReuse: true}),
		Sampling:  *versionStudySampling(),
		Queue:     HTTPEngineQueue(srv.Client(), srv.URL+"/metrics"),
		PollEvery: 50 * time.Millisecond,
		OnRung:    func(_ int, _ []RawRow, _ RungObservation, _ RungClass, err error) { gotErr = err },
	}
	if cls := r.Probe(context.Background(), 5, 1); cls != RungInvalid || gotErr == nil || !strings.Contains(gotErr.Error(), "exact-cap") {
		t.Fatalf("class %s err %v, want invalid for a nonconforming completion", cls, gotErr)
	}
}

// TestDrainBoundSharesTheRungsDeadline: the next rung waits only for what is left of the previous rung's drain, so rungs stay inside MaxSeconds.
func TestDrainBoundSharesTheRungsDeadline(t *testing.T) {
	d := fastDesign()
	r := &RungRunner{Design: d}
	now := time.Unix(1000, 0)
	if got := r.drainBound(now); got != time.Duration(d.Calibration.DrainSeconds)*time.Second {
		t.Fatalf("first rung bound %v, want the full drain", got)
	}
	r.drainDeadline = now.Add(700 * time.Millisecond)
	if got := r.drainBound(now); got != 700*time.Millisecond {
		t.Fatalf("bound %v, want what is left of the previous deadline", got)
	}
	r.drainDeadline = now.Add(-time.Second)
	if got := r.drainBound(now); got != 0 {
		t.Fatalf("bound %v after the deadline passed, want 0", got)
	}
}

// TestWaitDrainedReadsOnceWithNoTimeLeft: a passed deadline still allows one real read, so an idle engine is seen idle.
func TestWaitDrainedReadsOnceWithNoTimeLeft(t *testing.T) {
	reads := 0
	idle := func(ctx context.Context) (int, int, error) {
		reads++
		if ctx.Err() != nil {
			return 0, 0, ctx.Err()
		}
		return 0, 0, nil
	}
	if !WaitDrained(context.Background(), idle, 0, time.Millisecond) || reads != 1 {
		t.Fatalf("an idle engine with no time left was not seen drained (%d reads)", reads)
	}
}

// TestProbeGivesARetryItsOwnDrainAllowance: after a rung could not start drained, its retry is not handed the expired deadline.
func TestProbeGivesARetryItsOwnDrainAllowance(t *testing.T) {
	d := fastDesign()
	busy := func(context.Context) (int, int, error) { return 1, 0, nil }
	r := &RungRunner{Design: d, Queue: busy, PollEvery: 10 * time.Millisecond}
	r.drainDeadline = time.Now().Add(-time.Minute)
	if cls := r.Probe(context.Background(), 1, 1); cls != RungInvalid {
		t.Fatalf("class %s, want invalid", cls)
	}
	if got := r.drainBound(time.Now()); got != time.Duration(d.Calibration.DrainSeconds)*time.Second {
		t.Fatalf("the retry's drain bound is %v, want its own full allowance", got)
	}
}

// TestWaitDrainedRejectsAnAnswerAfterTheBound: an idle reading that arrives after the drain bound does not start a rung the bound already ended.
func TestWaitDrainedRejectsAnAnswerAfterTheBound(t *testing.T) {
	slowIdle := func(ctx context.Context) (int, int, error) {
		select {
		case <-time.After(100 * time.Millisecond):
			return 0, 0, nil
		case <-ctx.Done():
			return 0, 0, ctx.Err()
		}
	}
	start := time.Now()
	if WaitDrained(context.Background(), slowIdle, 20*time.Millisecond, time.Millisecond) {
		t.Fatal("an idle answer that took longer than the bound started the rung")
	}
	if took := time.Since(start); took > 80*time.Millisecond {
		t.Fatalf("the check ran %v past a 20 ms bound", took)
	}
	ignoresCtx := func(context.Context) (int, int, error) { time.Sleep(60 * time.Millisecond); return 0, 0, nil }
	if WaitDrained(context.Background(), ignoresCtx, 20*time.Millisecond, time.Millisecond) {
		t.Fatal("an idle answer received after the bound started the rung")
	}
}
