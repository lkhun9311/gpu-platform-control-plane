package bench

import (
	"errors"
	"fmt"
	"slices"
	"time"
)

// The version study's two vocabularies meet here.
//
// Replay writes a raw disposition per row: "completed", or the request's ErrorKind ("timeout", "http", "stream", ...).
// ClassifyRow gives the study's RowDisposition ("success", "timeout", "http-error", ...) after its conformance checks.
// StudyDisposition is the one translation between them, so no caller maps them on its own.

// errKindEngineUnavailable is the raw ErrorKind of a row whose visit's engine missed its readiness deadline.
//
// It is the study's own word, so the raw row and the study disposition name the outcome the same way.
const errKindEngineUnavailable = string(DispositionEngineUnavailable)

// UnavailableRows records every request of a visit whose engine never became ready, without inventing a send.
//
// Each row keeps its trace identity and its intended arrival, measured from at, the moment the visit was declared
// unavailable.
// It carries no send, transport-write or content time, and its terminal is that same moment, so the reader's
// clock-order check holds and no latency can be computed from it.
func UnavailableRows(trace []TraceRow, opts ReplayOptions, at time.Time) []RawRow {
	rows := make([]RawRow, 0, len(trace))
	zero := int64(0)
	for _, tr := range trace {
		intended := tr.OffsetMs * int64(time.Millisecond)
		rows = append(rows, RawRow{
			Index: tr.Index, Study: opts.Study, Arm: opts.Arm,
			RequestID: RequestIDFor(opts.RequestIDPrefix, tr.Index), Tenant: tr.Tenant, IsNoisy: tr.IsNoisy,
			ScheduledOffsetMs: tr.OffsetMs, PromptLenChars: tr.PromptLenChars, ExactInputTokens: tr.ExactInputTokens,
			TraceChecksum: opts.TraceChecksum, TerminationRecorded: true,
			Disposition: errKindEngineUnavailable, ErrorKind: errKindEngineUnavailable,
			Clock: &RequestClock{OriginUnixNanos: at.UnixNano(), IntendedNanos: &intended, TerminalNanos: &zero},
		})
	}
	return rows
}

// StudyDisposition gives one replayed row the study's disposition, or an error when the row is not an outcome at all.
//
// A cancelled or unsent request is the session stopping, never the engine failing, so it is refused rather than
// charged to a treatment.
// A completed row that did not do the registered work is refused too: ClassifyRow says a nonconforming row
// invalidates its cell, and an error is how that reaches the caller.
func StudyDisposition(p SamplingPolicy, row RawRow, tr TraceRow) (RowDisposition, error) {
	switch row.ErrorKind {
	case errKindCancelled, DispositionUnsent:
		return "", fmt.Errorf("row %d was %s by the session, which is not an outcome of the engine", row.Index, row.ErrorKind)
	}
	f := rowFacts(row, tr)
	if row.ErrorKind == errKindEngineUnavailable {
		f = RowFacts{EngineUnavailable: true}
	}
	return ClassifyRow(p, f)
}

// rowFacts is what ClassifyRow needs from one replayed row and the trace row it was sent from.
func rowFacts(row RawRow, tr TraceRow) RowFacts {
	return RowFacts{
		Dispatched:           row.Clock != nil && row.Clock.SendNanos != nil,
		HTTPStatus:           row.HTTPStatus,
		StreamCompleted:      row.Disposition == DispositionCompleted,
		TimedOut:             row.ErrorKind == "timeout",
		TransportError:       row.ErrorKind == "transport",
		UsagePresent:         row.EngineUsageReported != nil && *row.EngineUsageReported,
		PromptTokens:         row.EngineInputTokens,
		ExpectedPromptTokens: tr.ExactInputTokens,
		CompletionTokens:     row.EngineOutputTokens,
		CapTokens:            tr.MaxOutputTokens,
		FinishReason:         row.FinishReason,
		ContentFrames:        row.OutputTokens,
	}
}

// CellLag is a cell's dispatch lag over its measured population: how late requests left the client.
type CellLag struct {
	// Rows is how many dispatched rows of the population the lag was taken over.
	Rows int
	P99  time.Duration
	Max  time.Duration
}

// CellDispatchLag is transport write minus intended arrival, over the dispatched rows inP selects.
//
// A dispatched row with no transport write (a connection that failed before the request was written) contributes
// its send attempt's lag instead: the client's own delay up to the moment it tried, which a zero would understate.
// Rows of an unavailable visit were never dispatched and carry no lag; they are accounted for by their disposition.
// A population with no dispatched row has no lag, which is an error rather than an excellent one.
func CellDispatchLag(rows []RawRow, inP func(RawRow) bool) (CellLag, error) {
	var lags []float64
	for _, r := range rows {
		c := r.Clock
		if c == nil || c.IntendedNanos == nil || c.SendNanos == nil || !inP(r) {
			continue
		}
		left := *c.SendNanos
		if c.TransportWriteNanos != nil {
			left = *c.TransportWriteNanos
		}
		lags = append(lags, float64(left-*c.IntendedNanos))
	}
	if len(lags) == 0 {
		return CellLag{}, errors.New("no dispatched row in the population, so the cell has no dispatch lag")
	}
	slices.Sort(lags)
	return CellLag{
		Rows: len(lags),
		P99:  time.Duration(percentile(lags, 0.99)),
		Max:  time.Duration(lags[len(lags)-1]),
	}, nil
}

// LagInvalidates says whether a cell's lag breaks the registered bounds, which invalidates the cell.
func (d VersionStudyDesign) LagInvalidates(l CellLag) bool {
	ms := float64(time.Millisecond)
	return float64(l.P99) > d.DispatchLagP99Ms*ms || float64(l.Max) > d.DispatchLagMaxMs*ms
}

// RequireAllSuccess passes only when every request of the trace has exactly one row and that row succeeded.
//
// ClassifyRow returns no error for an HTTP 500 or a timeout, because those are outcomes; a preflight that checked
// only for errors would pass a treatment that failed every request.
func RequireAllSuccess(p SamplingPolicy, trace []TraceRow, rows []RawRow) error {
	if err := ReconcileRecording(trace, rows); err != nil {
		return err
	}
	byIndex := make(map[int]TraceRow, len(trace))
	for _, tr := range trace {
		byIndex[tr.Index] = tr
	}
	for _, r := range rows {
		d, err := StudyDisposition(p, r, byIndex[r.Index])
		if err != nil {
			return err
		}
		if d != DispositionSuccess {
			return fmt.Errorf("row %d ended %s", r.Index, d)
		}
	}
	return nil
}
