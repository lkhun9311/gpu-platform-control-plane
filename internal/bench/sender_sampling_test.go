package bench

import (
	"context"
	"encoding/json"
	"io"
	"maps"
	"net/http"
	"net/http/httptest"
	"slices"
	"sync"
	"testing"
	"time"
)

// captureChatBodies serves one clean stream per request and keeps every request body it was sent.
func captureChatBodies(t *testing.T) (*httptest.Server, func() []map[string]any) {
	t.Helper()
	var mu sync.Mutex
	var bodies []map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		var b map[string]any
		_ = json.Unmarshal(raw, &b)
		mu.Lock()
		bodies = append(bodies, b)
		mu.Unlock()
		w.Header().Set("Content-Type", "text/event-stream")
		f := w.(http.Flusher)
		for _, frame := range []string{
			`{"choices":[{"delta":{"content":"a"}}]}`,
			`{"choices":[{"delta":{"content":"b"},"finish_reason":"length"}]}`,
		} {
			_, _ = io.WriteString(w, "data: "+frame+"\n\n")
			f.Flush()
			time.Sleep(2 * time.Millisecond)
		}
		_, _ = io.WriteString(w, `data: {"choices":[],"usage":{"prompt_tokens":7,"completion_tokens":2}}`+"\n\n")
		f.Flush()
		time.Sleep(2 * time.Millisecond)
		_, _ = io.WriteString(w, "data: [DONE]\n\n")
		f.Flush()
	}))
	t.Cleanup(srv.Close)
	return srv, func() []map[string]any {
		mu.Lock()
		defer mu.Unlock()
		return slices.Clone(bodies)
	}
}

// TestSenderSendsTheRegisteredSamplingFields: the version study's arms are comparable only if every request carries the frozen policy.
// The run that sampled at 0.7 did so because nothing was sent and the model's generation_config filled the gap.
func TestSenderSendsTheRegisteredSamplingFields(t *testing.T) {
	srv, bodies := captureChatBodies(t)
	s := NewHTTPSender(srv.URL, "m", nil, 5*time.Second, SenderConn{MaxIdleConnsPerHost: 4, DrainForReuse: true})
	if err := s.SetSampling(versionStudySampling()); err != nil {
		t.Fatal(err)
	}
	row := TraceRow{Index: 41, Tenant: "t", PromptLenChars: 40, MaxOutputTokens: 64}
	if res := s.Send(context.Background(), row, time.Now().UnixNano()); res.ErrorKind != "" {
		t.Fatalf("send failed: %+v", res)
	}
	want, err := versionStudySampling().RequestFields(row)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(want)
	var wantMap map[string]any
	_ = json.Unmarshal(raw, &wantMap)
	got := bodies()[0]
	for k, v := range wantMap {
		if got[k] != v {
			t.Errorf("body %s = %v, the policy's field is %v", k, got[k], v)
		}
	}
	// Exact cap: both bounds equal the row's cap, and EOS cannot end the request early.
	if got["min_tokens"] != float64(64) || got["max_tokens"] != float64(64) || got["ignore_eos"] != true {
		t.Fatalf("length fields %v %v %v, want 64 64 true", got["min_tokens"], got["max_tokens"], got["ignore_eos"])
	}
}

// TestSenderWithoutSamplingSendsTheBodyEveryEarlierStudySent: a changed body is a changed treatment until shown otherwise.
func TestSenderWithoutSamplingSendsTheBodyEveryEarlierStudySent(t *testing.T) {
	srv, bodies := captureChatBodies(t)
	s := NewHTTPSender(srv.URL, "m", nil, 5*time.Second, SenderConn{MaxIdleConnsPerHost: 4, DrainForReuse: true})
	s.Send(context.Background(), TraceRow{Index: 1, Tenant: "t", PromptLenChars: 40, MaxOutputTokens: 64}, time.Now().UnixNano())
	keys := slices.Sorted(maps.Keys(bodies()[0]))
	if want := []string{"max_tokens", "messages", "model", "stream", "stream_options"}; !slices.Equal(keys, want) {
		t.Fatalf("body keys %v, want exactly %v", keys, want)
	}
}

// TestSetSamplingRefusesAnInvalidPolicy: an invalid policy found at the first request would leave a half-sent run.
func TestSetSamplingRefusesAnInvalidPolicy(t *testing.T) {
	s := NewHTTPSender("http://unused", "m", nil, time.Second, SenderConn{MaxIdleConnsPerHost: 1})
	bad := *versionStudySampling()
	bad.Temperature = 0.7
	bad.Seed = SeedOmitGreedy
	if err := s.SetSampling(&bad); err == nil {
		t.Fatal("a seedless policy at temperature 0.7 was accepted")
	}
}

// TestReplayStampsIntendedArrivalTransportWriteAndTrailer: the version study's latencies run from intended arrival, and its trailer diagnostic needs both trailer stamps.
func TestReplayStampsIntendedArrivalTransportWriteAndTrailer(t *testing.T) {
	srv, _ := captureChatBodies(t)
	s := NewHTTPSender(srv.URL, "m", nil, 5*time.Second, SenderConn{MaxIdleConnsPerHost: 4, DrainForReuse: true})
	trace := []TraceRow{
		{Index: 0, Tenant: "t", OffsetMs: 0, PromptLenChars: 40, MaxOutputTokens: 2},
		{Index: 1, Tenant: "t", OffsetMs: 30, PromptLenChars: 40, MaxOutputTokens: 2},
	}
	rows := Replay(context.Background(), s, trace, ReplayOptions{Arm: "a"})
	for _, r := range rows {
		c := r.Clock
		if c == nil || c.IntendedNanos == nil || c.TransportWriteNanos == nil || c.UsageNanos == nil || c.DoneNanos == nil {
			t.Fatalf("row %d clock %+v, want intended, transport-write, usage and done stamps", r.Index, c)
		}
		if want := trace[r.Index].OffsetMs * int64(time.Millisecond); *c.IntendedNanos != want {
			t.Errorf("row %d intended %d, want the trace offset %d", r.Index, *c.IntendedNanos, want)
		}
		// Each stamp follows the one before it on the same monotonic clock.
		order := []*int64{c.IntendedNanos, c.SendNanos, c.TransportWriteNanos, c.FirstContentNanos, c.LastContentNanos, c.UsageNanos, c.DoneNanos, c.EndNanos}
		for k := 1; k < len(order); k++ {
			if *order[k] < *order[k-1] {
				t.Errorf("row %d stamp %d (%d) precedes stamp %d (%d)", r.Index, k, *order[k], k-1, *order[k-1])
			}
		}
		ttft, ok := c.FromIntended(c.FirstContentNanos)
		if !ok || ttft != *c.FirstContentNanos-*c.IntendedNanos {
			t.Errorf("row %d TTFT from intended %d %v", r.Index, ttft, ok)
		}
	}
}

// TestFromIntendedRefusesAMissingStamp: a request with no content has no TTFT, which the endpoint counts as +∞, never as zero.
func TestFromIntendedRefusesAMissingStamp(t *testing.T) {
	ten := int64(10)
	c := RequestClock{IntendedNanos: &ten}
	if _, ok := c.FromIntended(nil); ok {
		t.Fatal("a missing stamp gave a latency")
	}
	if _, ok := (RequestClock{}).FromIntended(&ten); ok {
		t.Fatal("a row with no intended arrival gave a latency")
	}
}
