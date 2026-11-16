package bench

import (
	"context"
	"errors"
	"fmt"
	"time"
)

// The paid preflight sends this many requests to each treatment, as the registration's budget row states ("start, readiness, 30 requests").
const preflightRequests = 30

// preflightSpacingMs is the gap between preflight arrivals.
//
// The preflight shows that an engine does the registered work, not how much it can take, so its arrivals are spaced rather than drawn at a rate.
// Thirty arrivals then span 29 s, and with the 60 s request timeout the requests end within 89 s of the first, inside what 600 s of readiness leaves of the 900 s bound.
const preflightSpacingMs = 1000

// PreflightTrace is the registered preflight workload, the same for every treatment (clarified 2026-11-16, #607).
//
// It cycles through the six input x output classes in registration order, so each is sent five times and a class that only fails sometimes is seen more than once.
// It draws nothing at random, so no seed is spent and no block's or rung's requests are previewed.
func (d VersionStudyDesign) PreflightTrace() ([]TraceRow, error) {
	chars, err := d.promptChars()
	if err != nil {
		return nil, err
	}
	var classes [][2]int
	for _, in := range d.InputTokens {
		for _, out := range d.OutputTokens {
			classes = append(classes, [2]int{in.Tokens, out.Tokens})
		}
	}
	// An uneven split would send one class more often than another, and the registration does not say which.
	if len(classes) == 0 || preflightRequests%len(classes) != 0 {
		return nil, fmt.Errorf("%d preflight requests cannot be split evenly over %d input x output classes", preflightRequests, len(classes))
	}
	rows := make([]TraceRow, preflightRequests)
	for i := range rows {
		c := classes[i%len(classes)]
		rows[i] = TraceRow{
			Index: i, OffsetMs: int64(i) * preflightSpacingMs, Tenant: PremiumTenant,
			PromptLenChars: chars[c[0]], MaxOutputTokens: c[1], MinOutputTokens: c[1],
		}
	}
	stampExactTokens(rows)
	return rows, nil
}

// PreflightIO keeps each treatment's preflight evidence; every error it returns is a recorder failure and stops the session.
type PreflightIO interface {
	// WriteIdentity records the runtime the engine reported, before it is judged, so a refused engine is on record too.
	WriteIdentity(treatment string, rt RuntimeIdentity) error
	WriteRows(treatment string, rows []RawRow) error
}

// Preflight checks every treatment's engine before calibration, so a wrong image, flag or tokenizer is found before λ0 is paid for.
type Preflight struct {
	Design   VersionStudyDesign
	Sampling SamplingPolicy
	Engine   VisitEngine
	// Ready waits for /health and one answered priming request per input × output class; ctx carries the readiness deadline.
	Ready   func(ctx context.Context) error
	Runtime func(ctx context.Context) (RuntimeIdentity, error)
	// Check compares the runtime with the registration alone, since no bundle exists yet; it is Design.CheckRuntime.
	Check func(treatment string, rt RuntimeIdentity) error
	// Replay sends the preflight trace with the registered sampling and timeout; its rows carry their own preflight arm and request ids.
	Replay func(ctx context.Context, treatment string, trace []TraceRow) []RawRow
	IO     PreflightIO
}

// PreflightResult says whether the session may go on to calibration.
type PreflightResult struct {
	// Passed lists the treatments whose preflight passed, in the order they ran.
	Passed []string
	// Stop is why the session ends before calibration, or empty when every treatment passed.
	Stop string
}

// Run preflights A, B and C in that order, each on a fresh engine that is stopped before the next starts.
//
// A treatment that cannot pass preflight cannot be compared, so the first failure ends the session and no later treatment runs.
// An engine that fails to start, misses readiness, reports a runtime the registration refuses or fails any of the 30 requests is a stop with that reason.
// A failed evidence write, an unreadable runtime or an engine that cannot be confirmed removed is an error: the session's record or the GPU can no longer be trusted.
func (p Preflight) Run(ctx context.Context) (PreflightResult, error) {
	var res PreflightResult
	trace, err := p.Design.PreflightTrace()
	if err != nil {
		return res, err
	}
	for _, t := range versionStudyTreatments {
		stop, err := p.treatment(ctx, t, trace)
		if err != nil {
			// A stop reason found before the error is kept, so a failed cleanup does not hide why the preflight ended.
			if stop != "" {
				err = fmt.Errorf("%s, then %w", stop, err)
			}
			return res, fmt.Errorf("preflight of treatment %s: %w", t, err)
		}
		if stop != "" {
			res.Stop = fmt.Sprintf("preflight of treatment %s: %s", t, stop)
			return res, nil
		}
		res.Passed = append(res.Passed, t)
	}
	return res, nil
}

// treatment runs one treatment's preflight inside its registered bound, counted from before the engine's start.
func (p Preflight) treatment(ctx context.Context, t string, trace []TraceRow) (stop string, err error) {
	bound := time.Duration(p.Design.Bounds.PreflightSecondsPerTreatment) * time.Second
	tctx, cancel := context.WithTimeoutCause(ctx, bound, fmt.Errorf("the %v preflight bound passed", bound))
	defer cancel()
	// cut names why the treatment's context ended, the session's own stop before the bound, so neither is charged to the engine.
	cut := func(during string) string {
		if ctx.Err() != nil {
			return fmt.Sprintf("the session stopped during %s: %v", during, context.Cause(ctx))
		}
		return fmt.Sprintf("%v during %s", context.Cause(tctx), during)
	}
	s, running, ready, err := startReady(tctx, p.Engine, p.Design, t, "preflight-"+t, p.Ready)
	if err != nil {
		return "", err
	}
	if running {
		defer func() { err = errors.Join(err, stopEngine(ctx, p.Engine, s)) }()
	}
	if !ready {
		if tctx.Err() != nil {
			return cut("start and readiness"), nil
		}
		if !running {
			return "the engine did not start", nil
		}
		return fmt.Sprintf("the engine was not ready within %d s of its start", p.Design.Bounds.ReadinessSeconds), nil
	}
	rt, err := p.Runtime(tctx)
	switch {
	case err != nil && tctx.Err() != nil:
		return cut("the runtime identity read"), nil
	case err != nil:
		return "", fmt.Errorf("reading the runtime identity: %w", err)
	}
	if err := p.IO.WriteIdentity(t, rt); err != nil {
		return "", fmt.Errorf("recording the runtime identity: %w", err)
	}
	if err := p.Check(t, rt); err != nil {
		return fmt.Sprintf("identity: %v", err), nil
	}
	rows := p.Replay(tctx, t, trace)
	if err := p.IO.WriteRows(t, rows); err != nil {
		return "", fmt.Errorf("recording the preflight rows: %w", err)
	}
	// A request the session cut off is not the engine's failure, so the cut is reported before the rows are judged.
	if tctx.Err() != nil {
		return cut("the preflight requests"), nil
	}
	if err := RequireAllSuccess(p.Sampling, trace, rows); err != nil {
		return fmt.Sprintf("preflight requests: %v", err), nil
	}
	return "", nil
}

// startReady starts a fresh engine and waits for it up to the readiness bound, counted from the process start and cut by ctx.
//
// running is true whenever a container exists to stop, and ready only for an engine that became ready in time.
// A start that left nothing behind is not an error; one whose container could not be confirmed removed (ErrEngineCleanup) is.
func startReady(ctx context.Context, e VisitEngine, d VersionStudyDesign, treatment, name string, ready func(context.Context) error) (s EngineStart, running, isReady bool, err error) {
	s, err = e.Start(ctx, d, treatment, name)
	if err != nil {
		if errors.Is(err, ErrEngineCleanup) {
			return EngineStart{}, false, false, fmt.Errorf("starting %s: %w", treatment, err)
		}
		return EngineStart{}, false, false, nil
	}
	rctx, cancel := context.WithDeadline(ctx, s.StartedAt.Add(time.Duration(d.Bounds.ReadinessSeconds)*time.Second))
	defer cancel()
	return s, true, ready(rctx) == nil && rctx.Err() == nil, nil
}

// stopEngine removes an engine even after ctx ended, because an engine left running would share the GPU with the next.
func stopEngine(ctx context.Context, e VisitEngine, s EngineStart) error {
	if err := e.Stop(context.WithoutCancel(ctx), s); err != nil {
		return fmt.Errorf("stopping engine %s: %w", s.Name, err)
	}
	return nil
}
