package bench

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"time"
)

// CellValidity applies invalidation rules 1 to 3 to one cell's rows, without looking at any endpoint value.
//
// It returns the broken rule, or empty when the cell is valid, and whether dispatch lag is among the reasons.
// Rows of a visit whose engine was unavailable are outcomes: they reconcile and classify, and carry no lag.
func (d VersionStudyDesign) CellValidity(p SamplingPolicy, windowSeconds int, trace []TraceRow, rows []RawRow) (string, bool) {
	byIndex := make(map[int]TraceRow, len(trace))
	for _, tr := range trace {
		byIndex[tr.Index] = tr
	}
	// Neither an accounting failure nor a protocol fault ends the check: lag is judged too, because two lagged blocks of one
	// treatment stop the campaign, and a cell that also broke another rule must still count toward that.
	measured := func(r RawRow) bool { return d.PhaseOf(byIndex[r.Index].OffsetMs, windowSeconds) == PhaseMeasure }
	if err := ReconcileRecording(trace, rows); err != nil {
		lagReason := ""
		if lag, ok := leastCellLag(trace, rows, measured); ok && d.LagInvalidates(lag) {
			lagReason = fmt.Sprintf("dispatch lag of at least p99 %v, max %v over the %d measured requests", lag.P99, lag.Max, lag.Rows)
		}
		return joinReason(fmt.Sprintf("incomplete accounting: %v", err), lagReason), lagReason != ""
	}
	protocol := ""
	for _, r := range rows {
		if _, err := StudyDisposition(p, r, byIndex[r.Index]); err != nil {
			protocol = fmt.Sprintf("protocol fault: %v", err)
			break
		}
	}
	lagReason := ""
	lag, err := CellDispatchLag(rows, measured)
	switch {
	case err != nil:
		// Only an unavailable visit leaves the population with no dispatched row; any other cell has sent something.
		for _, r := range rows {
			if measured(r) && r.ErrorKind != errKindEngineUnavailable {
				lagReason = fmt.Sprintf("dispatch lag: %v", err)
				break
			}
		}
	case d.LagInvalidates(lag):
		lagReason = fmt.Sprintf("dispatch lag p99 %v, max %v over %d rows", lag.P99, lag.Max, lag.Rows)
	}
	return joinReason(protocol, lagReason), lagReason != ""
}

// leastCellLag is the smallest dispatch lag a cell's measured population can have when its recording does not account for it.
//
// A measured request recorded exactly once, at its own offset, gives its own lag, and one recorded unsent gives none.
// Every other measured request of the trace counts as a lag of 0, the least it could add, so the p99 and maximum are lower
// bounds and a breach of them is a breach the full recording would show too.
// Copies count as unrecorded, so a request written many times cannot outweigh the requests the trace holds once.
// It reports false when no recorded row gives a lag, because then the recording establishes none.
func leastCellLag(trace []TraceRow, rows []RawRow, measured func(RawRow) bool) (CellLag, bool) {
	byIndex := make(map[int]TraceRow, len(trace))
	for _, tr := range trace {
		byIndex[tr.Index] = tr
	}
	seen := make(map[int]int, len(rows))
	for _, r := range rows {
		seen[r.Index]++
	}
	known := make(map[int]RawRow, len(rows))
	for _, r := range rows {
		// A row placed anywhere but its trace offset has no established intended arrival, so its apparent lag is no evidence.
		if tr, ok := byIndex[r.Index]; ok && seen[r.Index] == 1 && r.ScheduledOffsetMs == tr.OffsetMs && intendedAtOffset(r.Clock, tr.OffsetMs) {
			known[r.Index] = r
		}
	}
	var lags []float64
	sent := false
	for _, tr := range trace {
		probe := RawRow{Index: tr.Index}
		if !measured(probe) {
			continue
		}
		r, ok := known[tr.Index]
		if !ok {
			lags = append(lags, 0)
			continue
		}
		lag, err := CellDispatchLag([]RawRow{r}, func(RawRow) bool { return true })
		if err != nil {
			// The request was recorded and not dispatched, so it is outside the population.
			continue
		}
		sent = true
		lags = append(lags, float64(lag.Max))
	}
	if !sent {
		return CellLag{}, false
	}
	slices.Sort(lags)
	return CellLag{Rows: len(lags), P99: time.Duration(percentile(lags, 0.99)), Max: time.Duration(lags[len(lags)-1])}, true
}

// VisitEngine starts and stops one treatment's engine; DockerEngine is one.
type VisitEngine interface {
	Start(ctx context.Context, d VersionStudyDesign, treatment, visit string) (EngineStart, error)
	Stop(ctx context.Context, s EngineStart) error
}

// CellIO is the session's evidence store for one campaign: the frozen traces in, the manifests and rows out.
//
// Every write error it returns is a recorder failure; the visit stops on it.
type CellIO interface {
	Trace(block int, load string) ([]TraceRow, error)
	// WriteManifest writes the cell's v3 manifest; it runs before the cell's first request, as identity before execution requires.
	WriteManifest(block int, treatment, load string) error
	WriteRows(block int, treatment, load string, rows []RawRow) error
	// RecordRestart notes a drain restart, which the registration records and does not count as invalidating.
	RecordRestart(block int, treatment, afterLoad string, at time.Time) error
}

// Visits run every treatment's visit in a block against one instance.
type Visits struct {
	Design        VersionStudyDesign
	Sampling      SamplingPolicy
	WindowSeconds int
	Engine        VisitEngine
	// Ready waits for /health and one answered priming request per input × output class; ctx carries the readiness deadline.
	Ready func(ctx context.Context) error
	// Runtime reads the running engine's identity, which the bundle's CompareRuntime checks (rule 4).
	Runtime func(ctx context.Context) (RuntimeIdentity, error)
	Compare func(treatment string, rt RuntimeIdentity) error
	Queue   EngineQueueReader
	// Replay sends one cell's trace; it is Replay with the session's sender and the cell's options.
	Replay func(ctx context.Context, block int, treatment, load string, trace []TraceRow) []RawRow
	// Unavailable records a cell whose engine never became ready; it is UnavailableRows with the cell's options, so
	// those rows carry the same study, arm and request ids as replayed ones.
	Unavailable func(block int, treatment, load string, trace []TraceRow, at time.Time) []RawRow
	IO          CellIO
	Now         func() time.Time
	PollEvery   time.Duration
}

// visitEngine is the engine a visit is on, whether a container exists to stop, and whether it ever became ready.
type visitEngine struct {
	start   EngineStart
	running bool
	ready   bool
}

// stop removes the visit's engine; a failure is a recorder failure, since the next engine would share the GPU with it.
func (v Visits) stop(ctx context.Context, e visitEngine) error {
	if !e.running {
		return nil
	}
	return stopEngine(ctx, v.Engine, e.start)
}

// Run is a VisitRunner: a fresh engine, its readiness bound, both loads in order with drained starts, a restart after any
// drain that did not end in time, then the engine's stop.
//
// An engine that misses readiness makes its cells unavailable, an outcome of the arm, not an invalid cell.
// A runtime that is not the bundle's invalidates the visit before any request is sent (rule 4).
// An engine that cannot be confirmed removed is an error, never an outcome: the next engine would share the GPU with it.
func (v Visits) Run(ctx context.Context, block int, treatment string, loads []string) (out VisitOutcome, err error) {
	starts := 0
	eng, err := v.startEngine(ctx, block, treatment, &starts)
	if err != nil {
		return out, err
	}
	defer func() { err = errors.Join(err, v.stop(ctx, eng)) }()
	if eng.ready {
		rt, err := v.Runtime(ctx)
		if err != nil {
			return out, fmt.Errorf("reading the runtime identity: %w", err)
		}
		if err := v.Compare(treatment, rt); err != nil {
			out.Invalid = fmt.Sprintf("identity: %v", err)
			return out, nil
		}
	}
	for i, load := range loads {
		trace, err := v.IO.Trace(block, load)
		if err != nil {
			return out, fmt.Errorf("trace of block %d at %s: %w", block, load, err)
		}
		if err := v.IO.WriteManifest(block, treatment, load); err != nil {
			return out, fmt.Errorf("manifest of block %d %s %s: %w", block, treatment, load, err)
		}
		origin := v.Now()
		var rows []RawRow
		if eng.ready {
			rows = v.Replay(ctx, block, treatment, load, trace)
		} else {
			rows = v.Unavailable(block, treatment, load, trace, origin)
		}
		// A cell the deadline cut short keeps what it recorded; its block is stopped and never analysed.
		if err := v.IO.WriteRows(block, treatment, load, rows); err != nil {
			return out, fmt.Errorf("rows of block %d %s %s: %w", block, treatment, load, err)
		}
		if ctx.Err() != nil {
			return out, nil
		}
		if reason, lag := v.Design.CellValidity(v.Sampling, v.WindowSeconds, trace, rows); reason != "" {
			out.Invalid = joinReason(out.Invalid, fmt.Sprintf("%s: %s", load, reason))
			out.LagInvalid = out.LagInvalid || lag
		}
		if i == len(loads)-1 || !eng.ready {
			continue
		}
		deadline, err := CellDrainDeadline(origin, trace, time.Duration(v.Design.Bounds.DrainSeconds)*time.Second)
		if err != nil {
			return out, err
		}
		if WaitDrainedUntil(ctx, v.Queue, deadline, v.PollEvery) {
			continue
		}
		if err := ctx.Err(); err != nil {
			return out, nil
		}
		// The next load must start on an idle engine, so one that has not drained by the bound is replaced.
		if err := v.IO.RecordRestart(block, treatment, load, v.Now()); err != nil {
			return out, fmt.Errorf("recording a drain restart: %w", err)
		}
		if err := v.stop(ctx, eng); err != nil {
			return out, err
		}
		eng = visitEngine{}
		if eng, err = v.startEngine(ctx, block, treatment, &starts); err != nil {
			return out, err
		}
		if eng.ready {
			rt, err := v.Runtime(ctx)
			if err != nil {
				return out, fmt.Errorf("reading the runtime identity: %w", err)
			}
			if err := v.Compare(treatment, rt); err != nil {
				out.Invalid = joinReason(out.Invalid, fmt.Sprintf("identity after restart: %v", err))
				return out, nil
			}
		}
	}
	return out, nil
}

// startEngine starts a fresh engine and waits for it up to the readiness bound, counted from the process start.
//
// A failed start that left nothing behind is the engine's outcome, like a missed deadline; one whose container could not be
// confirmed removed (ErrEngineCleanup) is an error.
func (v Visits) startEngine(ctx context.Context, block int, treatment string, starts *int) (visitEngine, error) {
	*starts++
	s, err := v.Engine.Start(ctx, v.Design, treatment, fmt.Sprintf("b%d-%s-%d", block, treatment, *starts))
	if err != nil {
		if errors.Is(err, ErrEngineCleanup) {
			return visitEngine{}, fmt.Errorf("starting %s: %w", treatment, err)
		}
		return visitEngine{}, nil
	}
	readyCtx, cancel := context.WithDeadline(ctx, s.StartedAt.Add(time.Duration(v.Design.Bounds.ReadinessSeconds)*time.Second))
	defer cancel()
	return visitEngine{start: s, running: true, ready: v.Ready(readyCtx) == nil && readyCtx.Err() == nil}, nil
}

// joinReason joins the reasons that are not empty, one per line, so a rule that held adds no blank line.
func joinReason(reasons ...string) string {
	var errs []error
	for _, r := range reasons {
		if r != "" {
			errs = append(errs, errors.New(r))
		}
	}
	if len(errs) == 0 {
		return ""
	}
	return errors.Join(errs...).Error()
}
