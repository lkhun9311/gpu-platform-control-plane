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
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// A cancelled replay still returns one row per scheduled request, the unsent ones marked as such with a terminal time.
// Audit finding 4: the unsent rows were dropped, so a run that stopped halfway looked like a shorter run.
// Mutation that turns it red: drop the rows whose SendUnixNanos is zero again, or leave their disposition empty.
func TestReplayKeepsAnUnsentRowForEveryScheduledRequest(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	trace := evenTrace(5, 10)
	calls := 0
	rows := Replay(ctx, stubSender{ttftDelay: time.Millisecond, totalDelay: 2 * time.Millisecond, outputTokens: 2, status: 200}, trace, ReplayOptions{
		Arm: "a",
		sleepUntil: func(context.Context, time.Time) {
			calls++
			if calls == 3 {
				cancel()
			}
		},
	})
	if len(rows) != len(trace) {
		t.Fatalf("got %d rows for %d scheduled requests", len(rows), len(trace))
	}
	unsent := 0
	for _, r := range rows {
		if r.Disposition == "" {
			t.Fatalf("row %d carries no disposition", r.Index)
		}
		if r.Clock == nil || r.Clock.TerminalNanos == nil {
			t.Fatalf("row %d carries no terminal time", r.Index)
		}
		if r.Disposition == DispositionUnsent {
			unsent++
			if r.SendUnixNanos != 0 || r.ErrorKind != DispositionUnsent || r.Tenant == "" {
				t.Fatalf("unsent row %d is not marked as one: %+v", r.Index, r)
			}
		}
	}
	if unsent != 3 {
		t.Fatalf("%d rows unsent; want the 3 scheduled after the cancellation", unsent)
	}
	if err := ReconcileRecording(trace, rows); err != nil {
		t.Fatalf("a recording with every request accounted for was refused: %v", err)
	}
}

// Every outcome gets a terminal time and a disposition, including a failure before any header and a refusal.
// Audit finding 9: pre-header failures and non-200 responses had no end time, so nothing said when they ended.
// Mutation that turns it red: set TerminalNanos only when the stream ended.
func TestEveryOutcomeHasATerminalTimeAndDisposition(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.Header.Get("X-Request-Id"), "-1") {
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\ndata: [DONE]\n\n"))
	}))
	s := NewHTTPSender(srv.URL, "m", nil, 5*time.Second, SenderConn{MaxIdleConnsPerHost: 2})
	s.SetRequestIDPrefix("p")
	trace := []TraceRow{{Index: 0, PromptLenChars: 8, MaxOutputTokens: 1}, {Index: 1, OffsetMs: 1, PromptLenChars: 8, MaxOutputTokens: 1}}
	rows := Replay(context.Background(), s, trace, ReplayOptions{RequestIDPrefix: "p"})
	srv.Close()
	// A closed server fails before any header arrives.
	dead := Replay(context.Background(), s, trace[:1], ReplayOptions{RequestIDPrefix: "p"})
	want := map[string]string{"completed": DispositionCompleted, "rejected": errKindRejected, "transport": "transport"}
	got := map[string]RawRow{"completed": rows[0], "rejected": rows[1], "transport": dead[0]}
	for name, r := range got {
		if r.Disposition != want[name] {
			t.Fatalf("%s row has disposition %q", name, r.Disposition)
		}
		if r.Clock == nil || r.Clock.TerminalNanos == nil || r.Clock.SendNanos == nil || *r.Clock.TerminalNanos < *r.Clock.SendNanos {
			t.Fatalf("%s row has no ordered terminal time: %+v", name, r.Clock)
		}
	}
}

// A request cancelled in flight is recorded as cancelled, not as a transport failure of the system under test.
// Mutation that turns it red: remove the context.Canceled check in Send.
func TestHTTPSenderNamesACancelledRequest(t *testing.T) {
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { <-release }))
	defer srv.Close()
	defer close(release)
	s := NewHTTPSender(srv.URL, "m", nil, 5*time.Second, SenderConn{MaxIdleConnsPerHost: 2})
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	ctx, cancelNow := context.WithCancel(ctx)
	go func() { time.Sleep(20 * time.Millisecond); cancelNow() }()
	res := s.Send(ctx, TraceRow{Index: 0, PromptLenChars: 8, MaxOutputTokens: 1}, time.Now().UnixNano())
	if res.ErrorKind != errKindCancelled {
		t.Fatalf("a cancelled request recorded ErrorKind %q", res.ErrorKind)
	}
}

// A recording is refused unless every scheduled request has exactly one row with a disposition, and no row is unscheduled.
// Mutation that turns it red: make ReconcileRecording ignore any one of missing, duplicate, unexpected or undisposed rows.
func TestReconcileRecordingRefusesAnIncompleteRecording(t *testing.T) {
	trace := evenTrace(4, 10)
	rows := Replay(context.Background(), stubSender{ttftDelay: time.Millisecond, totalDelay: 2 * time.Millisecond, outputTokens: 2, status: 200}, trace, ReplayOptions{sleepUntil: func(context.Context, time.Time) {}})
	if err := ReconcileRecording(trace, rows); err != nil {
		t.Fatalf("a complete recording was refused: %v", err)
	}
	missing := rows[:2]
	dup := append(append([]RawRow{}, rows...), rows[0])
	extra := append(append([]RawRow{}, rows...), RawRow{Index: 99, Disposition: DispositionCompleted})
	undisposed := append([]RawRow{}, rows...)
	undisposed[1].Disposition = ""
	moved := append([]RawRow{}, rows...)
	moved[2].ScheduledOffsetMs += 5
	for name, rs := range map[string][]RawRow{"missing": missing, "duplicate": dup, "unexpected": extra, "undisposed": undisposed, "rescheduled": moved} {
		if err := ReconcileRecording(trace, rs); err == nil {
			t.Fatalf("a %s recording was accepted", name)
		}
	}
}

// Rows that carry a disposition are from a harness that records one row per request, so a file of them is checked as it is read.
// Audit finding 16: duplicated rows and impossible timelines were accepted as evidence.
// Rows without a disposition are historical and are read as they always were.
// Mutation that turns it red: remove validateRecordedRows from ReadRawRows.
func TestReadRawRowsRefusesSemanticallyInvalidCurrentRows(t *testing.T) {
	rows := Replay(context.Background(), stubSender{ttftDelay: time.Millisecond, totalDelay: 2 * time.Millisecond, outputTokens: 2, status: 200}, evenTrace(2, 10), ReplayOptions{sleepUntil: func(context.Context, time.Time) {}})
	encode := func(rs []RawRow) *bytes.Buffer {
		var buf bytes.Buffer
		if err := WriteRawRows(&buf, rs); err != nil {
			t.Fatal(err)
		}
		return &buf
	}
	if _, err := ReadRawRows(encode(rows)); err != nil {
		t.Fatalf("valid current rows were refused: %v", err)
	}
	dup := append(append([]RawRow{}, rows...), rows[1])
	backwards := append([]RawRow{}, rows...)
	c := *backwards[0].Clock
	before := *c.SendNanos - 1
	c.TerminalNanos = &before
	backwards[0].Clock = &c
	mislabelled := append([]RawRow{}, rows...)
	mislabelled[0].ErrorKind = "timeout"
	unknown := append([]RawRow{}, rows...)
	unknown[1].Disposition = "fine"
	for name, rs := range map[string][]RawRow{"duplicate": dup, "terminal before send": backwards, "disposition contradicts errorKind": mislabelled, "unknown disposition": unknown} {
		if _, err := ReadRawRows(encode(rs)); err == nil {
			t.Fatalf("%s rows were read as evidence", name)
		}
	}
	historical := []RawRow{completedRow(0, 5, 10), completedRow(0, 6, 10)}
	if _, err := ReadRawRows(encode(historical)); err != nil {
		t.Fatalf("historical rows without a disposition were refused: %v", err)
	}
}

// A current row records whether its stream ended, whatever the rest of its file says, so it is never "termination unknown".
// Audit finding 25: termination was inferred per file, and a file in which no row happened to carry the key read every completion as unknown.
// Mutation that turns it red: derive TerminationRecorded from the file alone again.
func TestACurrentRowIsNeverTerminationUnknown(t *testing.T) {
	r := completedRow(0, 5, 10)
	r.Disposition = DispositionUnterminated
	r.Clock = &RequestClock{OriginUnixNanos: r.SendUnixNanos, SendNanos: elapsed(0), TerminalNanos: elapsed(7 * time.Millisecond)}
	var buf bytes.Buffer
	if err := WriteRawRows(&buf, []RawRow{r}); err != nil {
		t.Fatal(err)
	}
	back, err := ReadRawRows(&buf)
	if err != nil {
		t.Fatal(err)
	}
	s := Summarize("a", back)
	if s.TerminationUnknown != 0 || s.Completed != 0 || s.TruncatedStreams != 1 {
		t.Fatalf("unknown %d completed %d truncated %d; want 0, 0, 1", s.TerminationUnknown, s.Completed, s.TruncatedStreams)
	}
}
