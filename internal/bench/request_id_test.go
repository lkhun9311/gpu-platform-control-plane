package bench

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// TestRequestIDsJoinTheClientRowToTheEngine pins the join the step-boundary instrument depends on: the id a
// request is sent with is the id its raw row records, and a run that sets no prefix sends and records nothing.
// Mutation that turns it red: build the header from row.Index alone, or drop RequestID from the raw row.
func TestRequestIDsJoinTheClientRowToTheEngine(t *testing.T) {
	var mu sync.Mutex
	seen := map[string]bool{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		seen[r.Header.Get("X-Request-Id")] = true
		mu.Unlock()
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\ndata: [DONE]\n\n"))
	}))
	defer srv.Close()
	rows := []TraceRow{{Index: 0, OffsetMs: 0, PromptLenChars: 10, MaxOutputTokens: 1},
		{Index: 1, OffsetMs: 1, PromptLenChars: 10, MaxOutputTokens: 1}}

	for _, prefix := range []string{"stagger-step-2-measured-n42", ""} {
		mu.Lock()
		seen = map[string]bool{}
		mu.Unlock()
		s := NewHTTPSender(srv.URL, "m", nil, 5*time.Second, SenderConn{MaxIdleConnsPerHost: 2})
		s.SetRequestIDPrefix(prefix)
		raw := Replay(context.Background(), s, rows, ReplayOptions{Study: "s", Arm: "a", RequestIDPrefix: prefix})
		var buf bytes.Buffer
		if err := WriteRawRows(&buf, raw); err != nil {
			t.Fatal(err)
		}
		for _, r := range raw {
			want := ""
			if prefix != "" {
				want = prefix + "-" + []string{"0", "1"}[r.Index]
			}
			if r.RequestID != want {
				t.Fatalf("prefix %q: row %d recorded id %q, want %q", prefix, r.Index, r.RequestID, want)
			}
			mu.Lock()
			sent := seen[want]
			mu.Unlock()
			if !sent {
				t.Fatalf("prefix %q: row %d was not sent with X-Request-Id %q; the server saw %v", prefix, r.Index, want, seen)
			}
		}
		// A run without a prefix writes rows byte-identical to every earlier run's: no requestId key at all.
		if prefix == "" && strings.Contains(buf.String(), "requestId") {
			t.Fatalf("a run with no prefix wrote a requestId field: %s", buf.String())
		}
	}
}

// TestRecordTimingStampsEveryOutcomeAndNothingOtherwise pins the pilot's two replay stamps: the origin on every
// row, and the return on every outcome, a refusal and a transport failure included, while a run that does not
// ask for them writes rows without either key.
// Mutation that turns it red: stamp ReturnedUnixNanos only when EndUnixNanos is set, or drop RecordTiming's gate.
func TestRecordTimingStampsEveryOutcomeAndNothingOtherwise(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.Header.Get("X-Request-Id"), "-1") {
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\ndata: [DONE]\n\n"))
	}))
	defer srv.Close()
	rows := []TraceRow{{Index: 0, OffsetMs: 0, PromptLenChars: 10, MaxOutputTokens: 1},
		{Index: 1, OffsetMs: 1, PromptLenChars: 10, MaxOutputTokens: 1}}
	s := NewHTTPSender(srv.URL, "m", nil, 5*time.Second, SenderConn{MaxIdleConnsPerHost: 2})
	s.SetRequestIDPrefix("p")
	raw := Replay(context.Background(), s, rows, ReplayOptions{Study: "s", Arm: "a", RequestIDPrefix: "p", RecordTiming: true})
	if len(raw) != 2 {
		t.Fatalf("got %d rows", len(raw))
	}
	for _, r := range raw {
		if r.ReplayOriginUnixNanos == 0 || r.ReturnedUnixNanos == 0 {
			t.Fatalf("row %d (status %d) lacks a timing stamp: origin %d returned %d", r.Index, r.HTTPStatus, r.ReplayOriginUnixNanos, r.ReturnedUnixNanos)
		}
		if r.ReturnedUnixNanos < r.SendUnixNanos || r.SendUnixNanos < r.ReplayOriginUnixNanos {
			t.Fatalf("row %d stamps are out of order: origin %d send %d returned %d", r.Index, r.ReplayOriginUnixNanos, r.SendUnixNanos, r.ReturnedUnixNanos)
		}
	}
	if raw[0].ReplayOriginUnixNanos != raw[1].ReplayOriginUnixNanos {
		t.Fatal("two rows of one replay carry different origins")
	}
	if raw[1].EndUnixNanos != 0 {
		t.Fatal("a refusal was given an end, which the report reads as completed")
	}

	plain := Replay(context.Background(), s, rows, ReplayOptions{Study: "s", Arm: "a", RequestIDPrefix: "p"})
	var buf bytes.Buffer
	if err := WriteRawRows(&buf, plain); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(buf.String(), "replayOriginUnixNanos") || strings.Contains(buf.String(), "returnedUnixNanos") {
		t.Fatalf("a run that recorded no timing wrote its keys: %s", buf.String())
	}
}
