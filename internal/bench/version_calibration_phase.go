package bench

import (
	"context"
	"errors"
	"fmt"
	"time"
)

// CalibrationPhase runs the registered ladder on a fresh engine of treatment A, started after every preflight engine has been stopped.
type CalibrationPhase struct {
	Design VersionStudyDesign
	Engine VisitEngine
	// Ready waits for /health and one answered priming request per input × output class; ctx carries the readiness deadline.
	Ready   func(ctx context.Context) error
	Runtime func(ctx context.Context) (RuntimeIdentity, error)
	// Check compares the runtime with the registration alone, since the bundle is written only after λ0; it is Design.CheckRuntime.
	Check func(treatment string, rt RuntimeIdentity) error
	// WriteIdentity records the runtime A reported before it is judged; an error is a recorder failure.
	WriteIdentity func(rt RuntimeIdentity) error
	// Calibrate runs the registered ladder against the ready engine through RungRunner.Probe and records it, as runVersionCalibration does.
	//
	// It reserves the directory, writes every rung as it ends and writes the artifact last, an unresolved one included.
	// The phase never writes the artifact itself, so a cut ladder is recorded by the same path that records a finished one.
	Calibrate func(ctx context.Context) (CalibrationResult, error)
}

// CalibrationPhaseResult is the ladder's outcome, and why the session stops when there is no λ0.
type CalibrationPhaseResult struct {
	Calibration CalibrationResult
	// Stop is why the session ends here, or empty when the ladder resolved.
	Stop string
}

// Run starts A, waits for readiness, checks its identity, runs the ladder and stops A.
//
// The whole phase, A's start and readiness included, is held to the ladder's MaxSeconds, the only calibration time the budget registers.
// The bound ends the ladder through its context, so RunContext returns it unresolved with a reason naming the bound, and Calibrate writes that.
// An engine that does not start, misses readiness or is refused by the registration stops the session before any rung, with no calibration recorded.
// A failed evidence write, an unreadable runtime or an engine that cannot be confirmed removed is an error.
func (c CalibrationPhase) Run(ctx context.Context) (res CalibrationPhaseResult, err error) {
	// A session already stopped would make A's start fail on its context, which reads as the engine's failure.
	if ctx.Err() != nil {
		res.Stop = fmt.Sprintf("the session stopped before calibration: %v", context.Cause(ctx))
		return res, nil
	}
	bound := time.Duration(c.Design.CalibrationPhaseSeconds()) * time.Second
	pctx, cancel := context.WithTimeoutCause(ctx, bound, fmt.Errorf("calibration reached its %v bound", bound))
	defer cancel()
	s, running, ready, err := startReady(pctx, c.Engine, c.Design, TreatmentA, "calibration-"+TreatmentA, c.Ready)
	if err != nil {
		return res, fmt.Errorf("calibration: %w", err)
	}
	if running {
		defer func() { err = errors.Join(err, stopEngine(ctx, c.Engine, s)) }()
	}
	switch {
	case !ready && pctx.Err() != nil:
		res.Stop = fmt.Sprintf("calibration stopped before A was ready: %v", context.Cause(pctx))
		return res, nil
	case !running:
		res.Stop = "calibration: the engine of A did not start"
		return res, nil
	case !ready:
		res.Stop = fmt.Sprintf("calibration: the engine of A was not ready within %d s of its start", c.Design.Bounds.ReadinessSeconds)
		return res, nil
	}
	rt, err := c.Runtime(pctx)
	switch {
	case err != nil && pctx.Err() != nil:
		res.Stop = fmt.Sprintf("calibration stopped while reading A's runtime identity: %v", context.Cause(pctx))
		return res, nil
	case err != nil:
		return res, fmt.Errorf("calibration: reading the runtime identity: %w", err)
	}
	if err := c.WriteIdentity(rt); err != nil {
		return res, fmt.Errorf("calibration: recording the runtime identity: %w", err)
	}
	// Preflight checked an earlier engine of A; this one is a new process and is checked on its own.
	if err := c.Check(TreatmentA, rt); err != nil {
		res.Stop = fmt.Sprintf("calibration: identity: %v", err)
		return res, nil
	}
	// A ladder handed an ended context runs no rung, yet its recorder would reserve the directory and write rungs that never ran.
	if pctx.Err() != nil {
		res.Stop = fmt.Sprintf("calibration stopped before the first rung: %v", context.Cause(pctx))
		return res, nil
	}
	res.Calibration, err = c.Calibrate(pctx)
	if err != nil {
		return res, fmt.Errorf("calibration: %w", err)
	}
	if !res.Calibration.Resolved {
		res.Stop = res.Calibration.Reason
	}
	return res, nil
}
