package bench

import (
	"errors"
	"fmt"
	"reflect"
	"slices"
	"strings"
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
		// The label replaces the row's facts, so it is believed only from a row that shows it was never sent.
		// A row that was sent and answered under this label would otherwise become the arm's failure, when it is a recorder or protocol fault.
		if err := checkNeverDispatched(row); err != nil {
			return "", fmt.Errorf("row %d is labelled %s but %w", row.Index, errKindEngineUnavailable, err)
		}
		f = RowFacts{EngineUnavailable: true}
	}
	return ClassifyRow(p, f)
}

// unavailableIdentity names the RawRow fields a never-sent row still carries: the trace's and the cell's identity, and the label itself.
//
// Every other field is written by a dispatch or by its response, so it is listed by exclusion.
// A field added to RawRow later is then dispatch evidence until it is named here, which errs towards refusing a row.
var unavailableIdentity = map[string]bool{
	"Index": true, "Arm": true, "Tenant": true, "IsNoisy": true, "ScheduledOffsetMs": true, "PromptLenChars": true,
	"EstInputTokens": true, "TerminationRecorded": true, "Study": true, "Priority": true, "RequestID": true,
	"TraceChecksum": true, "LongThreshold": true, "ExactInputTokens": true, "MatchTolerance": true,
	"Disposition": true, "ErrorKind": true, "Clock": true,
}

// unavailableClockIdentity names the clock stamps a never-sent row has: its replay's origin, its intended arrival and its terminal.
var unavailableClockIdentity = map[string]bool{"OriginUnixNanos": true, "IntendedNanos": true, "TerminalNanos": true}

// checkNeverDispatched refuses a row labelled engine-unavailable that is not what UnavailableRows writes.
//
// Such a row has a clock whose terminal is its origin, a disposition equal to the label, and nothing a send or a response would have stamped.
// The intended arrival is not checked here, because ReconcileRecording ties it to the trace for every row.
func checkNeverDispatched(row RawRow) error {
	if row.Disposition != row.ErrorKind {
		return fmt.Errorf("carries disposition %q", row.Disposition)
	}
	c := row.Clock
	if c == nil || c.TerminalNanos == nil || *c.TerminalNanos != 0 {
		return errors.New("has no terminal time at its origin, which is when an unavailable visit records every request")
	}
	var found []string
	nonZero := func(v reflect.Value, identity map[string]bool, prefix string) {
		for i := range v.NumField() {
			if name := v.Type().Field(i).Name; !identity[name] && !v.Field(i).IsZero() {
				found = append(found, prefix+name)
			}
		}
	}
	nonZero(reflect.ValueOf(row), unavailableIdentity, "")
	nonZero(reflect.ValueOf(*c), unavailableClockIdentity, "Clock.")
	if len(found) > 0 {
		return fmt.Errorf("carries what only a dispatch or its response records: %s", strings.Join(found, ", "))
	}
	return nil
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
