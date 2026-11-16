package bench

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

// fakeInstance is one instance's engine, evidence store and queue, recording every call in order.
type fakeInstance struct {
	log      []string
	ready    func(start int) error
	compare  error
	busy     bool
	lag      time.Duration
	mutate   func(rows []RawRow)
	rowsErr  error
	cancelOn string
	cancel   context.CancelFunc
	starts   int
	written  map[string][]RawRow
}

func (f *fakeInstance) Start(_ context.Context, _ VersionStudyDesign, treatment, visit string) (EngineStart, error) {
	f.starts++
	f.log = append(f.log, "start "+visit)
	return EngineStart{Treatment: treatment, Name: visit, StartedAt: time.Now()}, nil
}

func (f *fakeInstance) Stop(_ context.Context, s EngineStart) error {
	f.log = append(f.log, "stop "+s.Name)
	return nil
}

func (f *fakeInstance) Trace(_ int, _ string) ([]TraceRow, error) {
	var trace []TraceRow
	for i := range 10 {
		trace = append(trace, TraceRow{Index: i, OffsetMs: int64(i) * 20, PromptLenChars: 1174, MaxOutputTokens: 64, MinOutputTokens: 64, ExactInputTokens: 256})
	}
	return trace, nil
}

func (f *fakeInstance) WriteManifest(block int, treatment, load string) error {
	f.log = append(f.log, fmt.Sprintf("manifest %d %s %s", block, treatment, load))
	return nil
}

func (f *fakeInstance) WriteRows(block int, treatment, load string, rows []RawRow) error {
	f.log = append(f.log, fmt.Sprintf("rows %d %s %s", block, treatment, load))
	if f.written == nil {
		f.written = map[string][]RawRow{}
	}
	f.written[load] = rows
	return f.rowsErr
}

func (f *fakeInstance) RecordRestart(_ int, _ string, afterLoad string, _ time.Time) error {
	f.log = append(f.log, "restart after "+afterLoad)
	return nil
}

// replay answers every request conformingly, dispatched f.lag after its intended arrival.
func (f *fakeInstance) replay(_ context.Context, _ int, _, load string, trace []TraceRow) []RawRow {
	f.log = append(f.log, "replay "+load)
	if f.cancelOn == load {
		f.cancel()
	}
	rows := make([]RawRow, 0, len(trace))
	for _, tr := range trace {
		r := conformingRow(tr)
		r.ScheduledOffsetMs, r.Tenant = tr.OffsetMs, tr.Tenant
		intended := tr.OffsetMs * int64(time.Millisecond)
		send := intended + int64(f.lag)
		r.Clock.IntendedNanos, r.Clock.SendNanos, r.Clock.TransportWriteNanos = &intended, &send, &send
		rows = append(rows, r)
	}
	if f.mutate != nil {
		f.mutate(rows)
	}
	return rows
}

// visits builds a Visits on f with a design whose window starts at once and whose drain bound is zero, so a cell's
// rows are measured and a busy engine misses its drain within the trace's 180 ms.
func (f *fakeInstance) visits(ctx context.Context) (Visits, context.Context) {
	ctx, f.cancel = context.WithCancel(ctx)
	d := versionAsyncDesign()
	d.WarmupSeconds = 0
	d.Bounds.DrainSeconds = 0
	return Visits{
		Design: d, Sampling: *versionStudySampling(), WindowSeconds: 1, Engine: f,
		Ready: func(context.Context) error {
			if f.ready != nil {
				return f.ready(f.starts)
			}
			return nil
		},
		Runtime: func(context.Context) (RuntimeIdentity, error) { return RuntimeIdentity{}, nil },
		Compare: func(string, RuntimeIdentity) error { return f.compare },
		Queue: func(context.Context) (int, int, error) {
			if f.busy {
				return 1, 0, nil
			}
			return 0, 0, nil
		},
		Replay: f.replay,
		Unavailable: func(_ int, _, _ string, trace []TraceRow, at time.Time) []RawRow {
			return UnavailableRows(trace, ReplayOptions{}, at)
		},
		IO: f, Now: time.Now, PollEvery: 5 * time.Millisecond,
	}, ctx
}

func runVisit(t *testing.T, f *fakeInstance) (VisitOutcome, error) {
	t.Helper()
	v, ctx := f.visits(context.Background())
	defer f.cancel()
	return v.Run(ctx, 1, TreatmentA, LoadOrder(1))
}

// TestVisitRunsBothLoadsOnOneEngine: identity before execution, both cells in order, one engine, stopped at the end.
func TestVisitRunsBothLoadsOnOneEngine(t *testing.T) {
	f := &fakeInstance{}
	out, err := runVisit(t, f)
	if err != nil || out.Invalid != "" {
		t.Fatalf("outcome %+v err %v", out, err)
	}
	want := "start b1-A-1|manifest 1 A l060|replay l060|rows 1 A l060|manifest 1 A l090|replay l090|rows 1 A l090|stop b1-A-1"
	if got := strings.Join(f.log, "|"); got != want {
		t.Fatalf("calls\n %s\nwant\n %s", got, want)
	}
}

// TestVisitOutcomes: what each event on the instance makes of the visit.
func TestVisitOutcomes(t *testing.T) {
	t.Run("a missed readiness deadline is an outcome, recorded without a send", func(t *testing.T) {
		f := &fakeInstance{ready: func(int) error { return errors.New("health never 200") }}
		out, err := runVisit(t, f)
		if err != nil || out.Invalid != "" || strings.Contains(strings.Join(f.log, "|"), "replay") {
			t.Fatalf("outcome %+v err %v calls %v", out, err, f.log)
		}
		if r := f.written[LoadL090][0]; r.ErrorKind != errKindEngineUnavailable {
			t.Fatalf("row %+v, want engine-unavailable", r)
		}
	})
	t.Run("a runtime that is not the bundle's invalidates the visit before any send", func(t *testing.T) {
		f := &fakeInstance{compare: errors.New("engine reports v0.31.0")}
		out, err := runVisit(t, f)
		if err != nil || !strings.HasPrefix(out.Invalid, "identity") || strings.Contains(strings.Join(f.log, "|"), "manifest") {
			t.Fatalf("outcome %+v err %v calls %v", out, err, f.log)
		}
	})
	t.Run("an engine that does not drain is restarted before the next load", func(t *testing.T) {
		f := &fakeInstance{busy: true}
		out, err := runVisit(t, f)
		got := strings.Join(f.log, "|")
		if err != nil || out.Invalid != "" || f.starts != 2 ||
			!strings.Contains(got, "rows 1 A l060|restart after l060|stop b1-A-1|start b1-A-2|manifest 1 A l090") ||
			!strings.HasSuffix(got, "stop b1-A-2") {
			t.Fatalf("outcome %+v err %v calls %s", out, err, got)
		}
	})
	t.Run("dispatch lag invalidates and is marked", func(t *testing.T) {
		f := &fakeInstance{lag: 20 * time.Millisecond}
		out, err := runVisit(t, f)
		if err != nil || !out.LagInvalid || !strings.Contains(out.Invalid, "dispatch lag") {
			t.Fatalf("outcome %+v err %v", out, err)
		}
	})
	t.Run("a nonconforming completion is a protocol fault", func(t *testing.T) {
		f := &fakeInstance{mutate: func(rows []RawRow) { rows[3].EngineOutputTokens = 1 }}
		out, err := runVisit(t, f)
		if err != nil || out.LagInvalid || !strings.Contains(out.Invalid, "protocol fault") {
			t.Fatalf("outcome %+v err %v", out, err)
		}
	})
	t.Run("a missing row is incomplete accounting", func(t *testing.T) {
		f := &fakeInstance{mutate: func(rows []RawRow) { rows[5] = rows[4] }}
		out, err := runVisit(t, f)
		if err != nil || !strings.Contains(out.Invalid, "incomplete accounting") {
			t.Fatalf("outcome %+v err %v", out, err)
		}
	})
	t.Run("a failed rows write is a recorder failure", func(t *testing.T) {
		f := &fakeInstance{rowsErr: errors.New("no space left on device")}
		if _, err := runVisit(t, f); err == nil || !strings.HasSuffix(strings.Join(f.log, "|"), "stop b1-A-1") {
			t.Fatalf("err %v calls %v, want an error and the engine stopped", err, f.log)
		}
	})
	t.Run("a cancelled cell keeps its rows and runs nothing after", func(t *testing.T) {
		f := &fakeInstance{cancelOn: LoadL060}
		_, err := runVisit(t, f)
		got := strings.Join(f.log, "|")
		if err != nil || !strings.Contains(got, "rows 1 A l060") || strings.Contains(got, "l090") {
			t.Fatalf("err %v calls %s", err, got)
		}
	})
}
