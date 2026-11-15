package bench

import (
	"bytes"
	"strings"
	"testing"
	"time"
)

// conformingRow is a completed row that did exactly the registered work for its trace row.
func conformingRow(tr TraceRow) RawRow {
	sec := int64(time.Second)
	send, end := int64(1)*sec, int64(2)*sec
	reported := true
	return RawRow{
		Index: tr.Index, Disposition: DispositionCompleted, HTTPStatus: 200, StreamTerminated: true,
		EngineUsageReported: &reported, EngineInputTokens: tr.ExactInputTokens, EngineOutputTokens: tr.MaxOutputTokens,
		FinishReason: "length", OutputTokens: 2,
		Clock: &RequestClock{SendNanos: &send, TerminalNanos: &end},
	}
}

// TestStudyDispositionMapsEveryRawOutcome: the raw vocabulary Replay writes and the study's ClassifyRow vocabulary are joined in one place.
func TestStudyDispositionMapsEveryRawOutcome(t *testing.T) {
	p := *versionStudySampling()
	tr := TraceRow{Index: 3, PromptLenChars: 1174, MaxOutputTokens: 64, MinOutputTokens: 64, ExactInputTokens: 256}
	failed := func(kind string, status int) RawRow {
		r := conformingRow(tr)
		r.Disposition, r.ErrorKind, r.HTTPStatus, r.StreamTerminated = kind, kind, status, false
		return r
	}
	for name, c := range map[string]struct {
		row  RawRow
		want RowDisposition
	}{
		"completed and conforming": {conformingRow(tr), DispositionSuccess},
		"timeout":                  {failed("timeout", 0), DispositionTimeout},
		"transport":                {failed("transport", 0), DispositionTransportError},
		"http 500":                 {failed("http", 500), DispositionHTTPError},
		"rejected 429":             {failed(errKindRejected, 429), DispositionHTTPError},
		"broken stream":            {failed("stream", 200), DispositionStreamError},
		"engine unavailable":       {UnavailableRows([]TraceRow{tr}, ReplayOptions{}, time.Unix(100, 0))[0], DispositionEngineUnavailable},
	} {
		got, err := StudyDisposition(p, c.row, tr)
		if err != nil || got != c.want {
			t.Errorf("%s: %q %v, want %q", name, got, err, c.want)
		}
	}
	nonconforming := conformingRow(tr)
	nonconforming.EngineOutputTokens = 1
	for name, row := range map[string]RawRow{
		// A cancellation is the session stopping, not the engine failing, so it is never given an outcome.
		"cancelled":     failed(errKindCancelled, 0),
		"unsent":        failed(DispositionUnsent, 0),
		"nonconforming": nonconforming,
	} {
		if got, err := StudyDisposition(p, row, tr); err == nil {
			t.Errorf("%s: classified as %q, want a refusal", name, got)
		}
	}
}

// TestUnavailableRowsRoundTripThroughTheReader: a visit whose engine missed readiness is accounted for row by row, with no send time made up.
func TestUnavailableRowsRoundTripThroughTheReader(t *testing.T) {
	trace := []TraceRow{
		{Index: 0, OffsetMs: 0, Tenant: PremiumTenant, PromptLenChars: 1174, MaxOutputTokens: 64, ExactInputTokens: 256},
		{Index: 1, OffsetMs: 250, Tenant: PremiumTenant, PromptLenChars: 5183, MaxOutputTokens: 256, ExactInputTokens: 1024},
	}
	rows := UnavailableRows(trace, ReplayOptions{Arm: "A-l060", RequestIDPrefix: "b1-A-l060"}, time.Unix(500, 0))
	var buf bytes.Buffer
	if err := WriteRawRows(&buf, rows); err != nil {
		t.Fatal(err)
	}
	read, err := ReadRawRows(&buf)
	if err != nil {
		t.Fatalf("the reader refused unavailable rows: %v", err)
	}
	if err := ReconcileRecording(trace, read); err != nil {
		t.Fatalf("unavailable rows do not account for the trace: %v", err)
	}
	for _, r := range read {
		if r.SendUnixNanos != 0 || r.Clock.SendNanos != nil || r.Clock.TransportWriteNanos != nil {
			t.Fatalf("row %d carries a send it never had: %+v", r.Index, r.Clock)
		}
		if r.Clock.IntendedNanos == nil || *r.Clock.IntendedNanos != trace[r.Index].OffsetMs*int64(time.Millisecond) {
			t.Fatalf("row %d lost its intended arrival", r.Index)
		}
	}
}

// lagRow is a dispatched row intended at intendedMs that left the client at writeMs, or only began sending when writeMs is negative.
func lagRow(i int, intendedMs, sendMs, writeMs int64) RawRow {
	ms := int64(time.Millisecond)
	in, send := intendedMs*ms, sendMs*ms
	r := RawRow{Index: i, Disposition: DispositionCompleted, Clock: &RequestClock{IntendedNanos: &in, SendNanos: &send}}
	if writeMs >= 0 {
		w := writeMs * ms
		r.Clock.TransportWriteNanos = &w
	}
	return r
}

// TestCellDispatchLagIsTransportWriteMinusIntendedArrival checks the registered lag, and what a row without a transport write contributes.
func TestCellDispatchLagIsTransportWriteMinusIntendedArrival(t *testing.T) {
	rows := []RawRow{
		lagRow(0, 1000, 1001, 1003), // 3 ms
		lagRow(1, 2000, 2002, 2012), // 12 ms
		lagRow(2, 3000, 3040, -1),   // no transport write: the send attempt's own lag, 40 ms
		lagRow(3, 50, 50, 900),      // outside P
		UnavailableRows([]TraceRow{{Index: 4, OffsetMs: 4000}}, ReplayOptions{}, time.Unix(1, 0))[0],
	}
	inP := func(r RawRow) bool { return *r.Clock.IntendedNanos >= int64(time.Second) }
	lag, err := CellDispatchLag(rows, inP)
	if err != nil {
		t.Fatal(err)
	}
	if lag.Rows != 3 || lag.Max != 40*time.Millisecond || lag.P99 != 40*time.Millisecond {
		t.Fatalf("lag %+v, want 3 dispatched rows in P, max and p99 40 ms", lag)
	}
	// Where the transport write is recorded it is the end of the lag, not the send: 12 ms, not 2 ms.
	written, err := CellDispatchLag(rows[:2], inP)
	if err != nil || written.Max != 12*time.Millisecond {
		t.Fatalf("lag over written rows %+v %v, want a 12 ms maximum from the transport write", written, err)
	}
	d := versionAsyncDesign()
	if !d.LagInvalidates(lag) {
		t.Fatal("a 40 ms p99 over the registered 10 ms did not invalidate the cell")
	}
	if d.LagInvalidates(CellLag{Rows: 10, P99: 9 * time.Millisecond, Max: 99 * time.Millisecond}) {
		t.Fatal("a lag inside both bounds invalidated the cell")
	}
	if !d.LagInvalidates(CellLag{Rows: 10, P99: 5 * time.Millisecond, Max: 101 * time.Millisecond}) {
		t.Fatal("a 101 ms maximum did not invalidate the cell")
	}
	if _, err := CellDispatchLag(rows[4:], inP); err == nil || !strings.Contains(err.Error(), "no dispatched") {
		t.Fatalf("a cell with no dispatched row in P gave a lag: %v", err)
	}
}

// TestRequireAllSuccessRefusesAFailedOutcome: preflight passes only when every request succeeded, not merely when none was refused as nonconforming.
func TestRequireAllSuccessRefusesAFailedOutcome(t *testing.T) {
	p := *versionStudySampling()
	trace := []TraceRow{
		{Index: 0, PromptLenChars: 1174, MaxOutputTokens: 64, ExactInputTokens: 256},
		{Index: 1, PromptLenChars: 1174, MaxOutputTokens: 64, ExactInputTokens: 256},
	}
	ok := []RawRow{conformingRow(trace[0]), conformingRow(trace[1])}
	if err := RequireAllSuccess(p, trace, ok); err != nil {
		t.Fatalf("two conforming successes were refused: %v", err)
	}
	failed := conformingRow(trace[1])
	failed.Disposition, failed.ErrorKind, failed.HTTPStatus, failed.StreamTerminated = "http", "http", 500, false
	if err := RequireAllSuccess(p, trace, []RawRow{ok[0], failed}); err == nil || !strings.Contains(err.Error(), "http-error") {
		t.Fatalf("an HTTP 500 passed preflight: %v", err)
	}
	if err := RequireAllSuccess(p, trace, ok[:1]); err == nil {
		t.Fatal("a missing row passed preflight")
	}
}
