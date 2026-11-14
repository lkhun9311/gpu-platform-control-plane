/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package bench

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func elapsed(d time.Duration) *int64 {
	n := int64(d)
	return &n
}

// A row's latencies come from its monotonic clock whenever the row carries one, so a wall-clock step cannot reach them.
// Audit finding 11: TTFT and E2E were differences of UnixNano values, so an NTP step between send and first token produced a negative or inflated latency.
// Here the wall clock stepped back one second between send and first token; the monotonic clock says 5 ms.
// Mutation that turns it red: make TTFTNanos or E2ENanos ignore r.Clock.
func TestRowLatenciesUseTheMonotonicClock(t *testing.T) {
	base := int64(1_700_000_000_000_000_000)
	r := RawRow{
		HTTPStatus:          200,
		SendUnixNanos:       base,
		FirstTokenUnixNanos: base - int64(time.Second),
		EndUnixNanos:        base - int64(time.Second) + int64(4*time.Millisecond),
		Clock: &RequestClock{
			OriginUnixNanos:   base,
			SendNanos:         elapsed(0),
			FirstContentNanos: elapsed(5 * time.Millisecond),
			LastContentNanos:  elapsed(8 * time.Millisecond),
			EndNanos:          elapsed(9 * time.Millisecond),
		},
	}
	if ttft, ok := r.TTFTNanos(); !ok || ttft != int64(5*time.Millisecond) {
		t.Fatalf("TTFT = %d, %t; want 5ms from the monotonic clock", ttft, ok)
	}
	if e2e, ok := r.E2ENanos(); !ok || e2e != int64(9*time.Millisecond) {
		t.Fatalf("E2E = %d, %t; want 9ms from the monotonic clock", e2e, ok)
	}
}

// A row with no clock is a row written before it existed, and its latencies stay the wall-clock differences they always were.
// Mutation that turns it red: return false from TTFTNanos when Clock is nil.
func TestRowLatenciesWithoutAClockKeepTheHistoricalArithmetic(t *testing.T) {
	r := completedRow(0, 12, 100)
	if ttft, ok := r.TTFTNanos(); !ok || ttft != int64(12*time.Millisecond) {
		t.Fatalf("TTFT = %d, %t; want the 12ms the unix stamps give", ttft, ok)
	}
}

// wallSteppedSender reports its unix stamps one second behind the scheduler's while its time.Time values carry the true elapsed times, as a wall-clock step back would.
type wallSteppedSender struct{}

func (wallSteppedSender) Send(_ context.Context, _ TraceRow, sendUnixNanos int64) SendResult {
	sendAt := time.Unix(0, sendUnixNanos)
	step := int64(time.Second)
	return SendResult{
		HTTPStatus:          200,
		StreamTerminated:    true,
		OutputTokens:        3,
		FirstTokenUnixNanos: sendUnixNanos - step + int64(5*time.Millisecond),
		EndUnixNanos:        sendUnixNanos - step + int64(9*time.Millisecond),
		FirstContentAt:      sendAt.Add(5 * time.Millisecond),
		LastContentAt:       sendAt.Add(8 * time.Millisecond),
		EndAt:               sendAt.Add(9 * time.Millisecond),
	}
}

// Replay derives the row's clock from the sender's time.Time values, never from its unix stamps.
// Mutation that turns it red: stop setting Clock in Replay, or derive it from the unix stamps.
func TestReplayRecordsTheRequestClock(t *testing.T) {
	origin := time.Unix(0, 1_700_000_000_000_000_000)
	rows := Replay(context.Background(), wallSteppedSender{}, evenTrace(2, 10), ReplayOptions{
		clock:      func() time.Time { return origin.Add(10 * time.Millisecond) },
		sleepUntil: func(context.Context, time.Time) {},
	})
	if len(rows) != 2 {
		t.Fatalf("got %d rows", len(rows))
	}
	for _, r := range rows {
		if r.Clock == nil || r.Clock.SendNanos == nil || r.Clock.FirstContentNanos == nil || r.Clock.LastContentNanos == nil || r.Clock.EndNanos == nil {
			t.Fatalf("row %d carries no complete clock: %+v", r.Index, r.Clock)
		}
		if ttft, ok := r.TTFTNanos(); !ok || ttft != int64(5*time.Millisecond) {
			t.Fatalf("row %d TTFT = %d, %t; want 5ms", r.Index, ttft, ok)
		}
	}
}

// The HTTP sender stamps every event from one time.Now call that keeps its monotonic reading, and the row's clock is ordered.
// Mutation that turns it red: build FirstContentAt from time.Unix(0, ...), which strips the monotonic reading.
func TestHTTPSenderStampsMonotonicTimes(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\n"))
		w.(http.Flusher).Flush()
		time.Sleep(5 * time.Millisecond)
		_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"b\"}}]}\n\ndata: [DONE]\n\n"))
	}))
	defer srv.Close()
	s := NewHTTPSender(srv.URL, "m", nil, 5*time.Second, SenderConn{MaxIdleConnsPerHost: 2})
	res := s.Send(context.Background(), TraceRow{Index: 0, PromptLenChars: 8, MaxOutputTokens: 2}, time.Now().UnixNano())
	for name, at := range map[string]time.Time{"first content": res.FirstContentAt, "last content": res.LastContentAt, "end": res.EndAt} {
		if at.IsZero() || !strings.Contains(at.String(), "m=") {
			t.Fatalf("%s %v carries no monotonic reading", name, at)
		}
	}
	rows := Replay(context.Background(), s, []TraceRow{{Index: 0, PromptLenChars: 8, MaxOutputTokens: 2}}, ReplayOptions{})
	c := rows[0].Clock
	if c == nil || c.SendNanos == nil || c.FirstContentNanos == nil || c.LastContentNanos == nil || c.EndNanos == nil {
		t.Fatalf("row carries no complete clock: %+v", c)
	}
	if *c.SendNanos > *c.FirstContentNanos || *c.FirstContentNanos >= *c.LastContentNanos || *c.LastContentNanos > *c.EndNanos {
		t.Fatalf("clock out of order: send %d first %d last %d end %d", *c.SendNanos, *c.FirstContentNanos, *c.LastContentNanos, *c.EndNanos)
	}
}

// One replay's active span is read off its monotonic clock, so a wall step inside the run cannot stretch or shrink the throughput denominator.
// Mutation that turns it red: make activeSpanNanos use the unix stamps when every row carries a clock.
func TestActiveSecondsUseTheMonotonicClock(t *testing.T) {
	base := int64(1_700_000_000_000_000_000)
	var rows []RawRow
	for i := range 2 {
		send := time.Duration(i) * time.Second
		rows = append(rows, RawRow{
			Index: i, Tenant: PremiumTenant, HTTPStatus: 200, StreamTerminated: true, OutputTokens: 4,
			SendUnixNanos:       base + int64(send),
			FirstTokenUnixNanos: base + int64(send) + int64(10*time.Millisecond),
			// The wall clock jumped 100 s forward during the second request.
			EndUnixNanos: base + int64(send) + int64(time.Second) + int64(i)*int64(100*time.Second),
			Clock: &RequestClock{
				OriginUnixNanos:   base,
				SendNanos:         elapsed(send),
				FirstContentNanos: elapsed(send + 10*time.Millisecond),
				LastContentNanos:  elapsed(send + 900*time.Millisecond),
				EndNanos:          elapsed(send + time.Second),
			},
		})
	}
	s := Summarize("a", rows)
	if s.ActiveSeconds != 2 {
		t.Fatalf("ActiveSeconds = %g; want 2 from the monotonic clock", s.ActiveSeconds)
	}
}
