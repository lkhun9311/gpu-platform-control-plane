package bench

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
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

// stubEngine serves one-token SSE responses after delay, and its own queue gauges at /metrics.
func stubEngine(t *testing.T, delay time.Duration, busyMetrics bool) (*httptest.Server, *atomic.Int64) {
	t.Helper()
	var inflight, served atomic.Int64
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		served.Add(1)
		inflight.Add(1)
		defer inflight.Add(-1)
		_, _ = io.Copy(io.Discard, r.Body)
		time.Sleep(delay)
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, `data: {"choices":[{"delta":{"content":"a"},"finish_reason":"length"}]}`+"\n\n")
		_, _ = io.WriteString(w, `data: {"choices":[],"usage":{"prompt_tokens":7,"completion_tokens":1}}`+"\n\n")
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
