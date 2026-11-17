package bench

import (
	"bytes"
	"reflect"
	"strings"
	"testing"
	"time"
)

// conformingRow is a completed row that did exactly the registered work for its trace row.
func conformingRow(tr TraceRow) RawRow {
	sec := int64(time.Second)
	intended := tr.OffsetMs * int64(time.Millisecond)
	send, end := intended+sec, intended+2*sec
	reported := true
	return RawRow{
		Index: tr.Index, ScheduledOffsetMs: tr.OffsetMs, Tenant: tr.Tenant,
		Disposition: DispositionCompleted, HTTPStatus: 200, StreamTerminated: true,
		EngineUsageReported: &reported, EngineInputTokens: tr.ExactInputTokens, EngineOutputTokens: tr.MaxOutputTokens,
		FinishReason: "length", OutputTokens: 2,
		Clock: &RequestClock{IntendedNanos: &intended, SendNanos: &send, TerminalNanos: &end},
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

// unavailableIdentityFields are the RawRow fields an unavailable row may carry: the trace's and the cell's identity, which an unsent row has too.
//
// Every other field is something the request's dispatch or its response wrote, which an engine that was never ready cannot have produced.
var unavailableIdentityFields = map[string]bool{
	"Index": true, "Arm": true, "Tenant": true, "IsNoisy": true, "ScheduledOffsetMs": true, "PromptLenChars": true,
	"EstInputTokens": true, "TerminationRecorded": true, "Study": true, "Priority": true, "RequestID": true,
	"TraceChecksum": true, "LongThreshold": true, "ExactInputTokens": true, "MatchTolerance": true,
	// The label itself and the clock are checked on their own below.
	"Disposition": true, "ErrorKind": true, "Clock": true,
}

// nonZero sets v to a value that is not its type's zero, so a pointer becomes a pointer to zero, which still records an event.
func nonZero(t *testing.T, v reflect.Value) {
	t.Helper()
	switch v.Kind() {
	case reflect.Int, reflect.Int64:
		v.SetInt(1)
	case reflect.Float64:
		v.SetFloat(1)
	case reflect.String:
		v.SetString("x")
	case reflect.Bool:
		v.SetBool(true)
	case reflect.Pointer:
		v.Set(reflect.New(v.Type().Elem()))
	case reflect.Slice:
		v.Set(reflect.MakeSlice(v.Type(), 1, 1))
	default:
		t.Fatalf("no non-zero value for kind %s", v.Kind())
	}
}

// TestAnUnavailableLabelNeverErasesDispatchEvidence: engine-unavailable is an outcome only for a row that shows it was never sent.
//
// StudyDisposition used to replace a labelled row's facts with an unavailable engine's, so a row that was sent and answered became the arm's failure.
// Every RawRow and clock field outside the identity a scheduled row carries is set in turn, and each must turn the label into a refusal.
func TestAnUnavailableLabelNeverErasesDispatchEvidence(t *testing.T) {
	p := *versionStudySampling()
	tr := TraceRow{Index: 3, OffsetMs: 250, Tenant: PremiumTenant, PromptLenChars: 1174, MaxOutputTokens: 64, MinOutputTokens: 64, ExactInputTokens: 256}
	genuine := func() RawRow {
		return UnavailableRows([]TraceRow{tr}, ReplayOptions{Study: "s", Arm: "A-l060", RequestIDPrefix: "b1", TraceChecksum: "c"}, time.Unix(100, 0))[0]
	}
	if d, err := StudyDisposition(p, genuine(), tr); err != nil || d != DispositionEngineUnavailable {
		t.Fatalf("a genuine unavailable row gave %q %v", d, err)
	}
	fields := reflect.TypeFor[RawRow]()
	for i := range fields.NumField() {
		name := fields.Field(i).Name
		if unavailableIdentityFields[name] {
			continue
		}
		t.Run(name, func(t *testing.T) {
			row := genuine()
			nonZero(t, reflect.ValueOf(&row).Elem().Field(i))
			if d, err := StudyDisposition(p, row, tr); err == nil {
				t.Fatalf("a row carrying %s was classified %q", name, d)
			}
		})
	}
	clockFields := reflect.TypeFor[RequestClock]()
	for i := range clockFields.NumField() {
		name := clockFields.Field(i).Name
		// The origin and the intended arrival are stamped without sending; the intended arrival is reconciled with the trace.
		if name == "OriginUnixNanos" || name == "IntendedNanos" || name == "TerminalNanos" {
			continue
		}
		t.Run("Clock."+name, func(t *testing.T) {
			row := genuine()
			nonZero(t, reflect.ValueOf(row.Clock).Elem().Field(i))
			if d, err := StudyDisposition(p, row, tr); err == nil {
				t.Fatalf("a row whose clock stamps %s was classified %q", name, d)
			}
		})
	}
	sent := conformingRow(tr)
	sent.Disposition, sent.ErrorKind = errKindEngineUnavailable, errKindEngineUnavailable
	for name, mutate := range map[string]func(*RawRow){
		"no clock":                     func(r *RawRow) { r.Clock = nil },
		"no terminal time":             func(r *RawRow) { r.Clock.TerminalNanos = nil },
		"terminal after the origin":    func(r *RawRow) { n := int64(1); r.Clock.TerminalNanos = &n },
		"another disposition":          func(r *RawRow) { r.Disposition = DispositionCompleted },
		"a completed, answered stream": func(r *RawRow) { *r = sent },
	} {
		t.Run(name, func(t *testing.T) {
			row := genuine()
			mutate(&row)
			if d, err := StudyDisposition(p, row, tr); err == nil {
				t.Fatalf("classified %q", d)
			}
		})
	}
}

// TestADispatchedRowLabelledUnavailableIsAProtocolFault: the contradiction invalidates the cell instead of becoming the arm's failure.
func TestADispatchedRowLabelledUnavailableIsAProtocolFault(t *testing.T) {
	d := versionAsyncDesign()
	p := *versionStudySampling()
	trace := []TraceRow{evalTraceRow(0, 0), evalTraceRow(1, 10)}
	genuine := UnavailableRows(trace, ReplayOptions{}, time.Unix(0, 0))
	if reason, lag := d.CellValidity(p, 180, trace, genuine); reason != "" || lag {
		t.Fatalf("a genuinely unavailable cell is invalid: %q (lag %v)", reason, lag)
	}
	sent := timedRow(trace[1], 0, 100, 1000)
	sent.Disposition, sent.ErrorKind = errKindEngineUnavailable, errKindEngineUnavailable
	rows := []RawRow{genuine[0], sent}
	if reason, _ := d.CellValidity(p, 180, trace, rows); !strings.Contains(reason, "protocol fault") {
		t.Errorf("cell validity %q, want a protocol fault", reason)
	}
	if out, err := d.CellOutcomes(p, 180, trace, rows); err == nil {
		t.Errorf("outcomes %+v from a sent row labelled unavailable", out)
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
		// What the evaluator reads back from the file must still be the outcome, not a contradiction.
		if d, err := StudyDisposition(*versionStudySampling(), r, trace[r.Index]); err != nil || d != DispositionEngineUnavailable {
			t.Fatalf("row %d read back as %q %v", r.Index, d, err)
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

// TestALateIntendedArrivalIsRefusedByEveryConsumer: an intended arrival later than the trace offset hides the client's lag.
//
// The request left 300 ms late, which breaks the lag bound and is 400 ms of TTFT.
// Stamped 300 ms late as well, the same row shows no lag and a 100 ms TTFT, so the cell would pass and report the smaller number.
func TestALateIntendedArrivalIsRefusedByEveryConsumer(t *testing.T) {
	d := versionAsyncDesign()
	p := *versionStudySampling()
	trace := []TraceRow{evalTraceRow(0, 0)}
	honest := timedRow(trace[0], 300, 400, 2000)
	if reason, lag := d.CellValidity(p, 180, trace, []RawRow{honest}); !lag || !strings.Contains(reason, "dispatch lag") {
		t.Fatalf("the honest row gives %q (lag %v), want a lag invalidation, so the forged stamp is what hides it", reason, lag)
	}
	forged := honest
	c := *honest.Clock
	late := *c.IntendedNanos + int64(300*time.Millisecond)
	c.IntendedNanos = &late
	forged.Clock = &c
	rows := []RawRow{forged}
	if reason, lag := d.CellValidity(p, 180, trace, rows); !strings.Contains(reason, "incomplete accounting") || lag {
		t.Errorf("cell validity %q (lag %v), want incomplete accounting and no lag reason", reason, lag)
	}
	if out, err := d.CellOutcomes(p, 180, trace, rows); err == nil {
		t.Errorf("outcomes %+v from a row stamped after its trace offset", out)
	}
	if err := RequireAllSuccess(p, trace, rows); err == nil {
		t.Error("preflight passed a row stamped after its trace offset")
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
