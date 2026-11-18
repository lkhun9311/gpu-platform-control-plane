package bench

import (
	"context"
	"fmt"
	"math"
)

// Calibration of the version study's operating rate λ0, registered in
// docs/superpowers/specs/2026-11-15-vllm-version-async-study-design.md ("Load").
//
// λ0 is a confirmed stable operating rate of treatment A on this host and workload: the highest rate the ladder found
// stable, re-run on fresh traces and stable again.
// It is not called a sustainable capacity, because a finite window cannot establish one (attack item 2).

// CalibrationRule is the registered ladder and its stability criteria.
type CalibrationRule struct {
	// StartRate is the first rung, Growth the expansion factor, MaxExpansion the expansion rungs allowed.
	StartRate    float64
	Growth       float64
	MaxExpansion int
	// FallbackFactor and MaxFallback step down from a failed first rung, so a slow engine still gets a lower bound.
	FallbackFactor float64
	MaxFallback    int
	// TargetRatio is the bracket the refinement must reach, and MaxRefine its own rung allowance (attack item 3).
	TargetRatio float64
	MaxRefine   int
	// Confirmations is how many more rungs on fresh traces the selected rate must pass, and MaxStepDowns how many lower rates may be tried after a failed confirmation.
	Confirmations int
	MaxStepDowns  int
	// MaxInvalidRetries bounds the rungs repeated because they did not start drained or offered nothing.
	MaxInvalidRetries int
	// Tolerance is the fraction by which departures may trail arrivals, and outstanding work and its trend may grow.
	Tolerance float64
	// OutstandingSlackMin is the least growth in outstanding requests tolerated, because a few in flight at the edges is not a queue.
	OutstandingSlackMin int
	// MaxFailureFraction is the reliability guardrail, judged apart from throughput.
	MaxFailureFraction float64
	// WarmupSeconds, WindowSeconds and DrainSeconds bound one rung.
	WarmupSeconds int
	WindowSeconds int
	DrainSeconds  int
}

// RungObservation is what the runner measured over one rung's window.
type RungObservation struct {
	OfferedRate   float64 `json:"offeredRate"`
	WindowSeconds float64 `json:"windowSeconds"`
	// StartedDrained is true when the client had nothing outstanding and the engine reported no running or waiting request when the rung began.
	StartedDrained bool `json:"startedDrained"`
	// Arrivals are the requests whose intended arrival fell in the window; Departures the requests that reached a terminal outcome in it, whenever they arrived.
	Arrivals   int `json:"arrivals"`
	Departures int `json:"departures"`
	// OutstandingStart and OutstandingEnd are requests in flight at the window's edges, and OutstandingSlopePerSec their least-squares trend over 1 s samples.
	OutstandingStart       int     `json:"outstandingStart"`
	OutstandingEnd         int     `json:"outstandingEnd"`
	OutstandingSlopePerSec float64 `json:"outstandingSlopePerSec"`
	// Failures are the window's arrivals that ended in an HTTP error, stream error, transport error or timeout.
	Failures int `json:"failures"`
	// UnresolvedAtDrain are the window's arrivals with no terminal outcome when the drain deadline passed.
	UnresolvedAtDrain int `json:"unresolvedAtDrain"`
}

// RungClass is the classification of one rung.
type RungClass string

const (
	// RungStable meets every throughput criterion and the reliability guardrail.
	RungStable RungClass = "stable"
	// RungUnstable shows a backlog: departures trailing arrivals, growing outstanding work, a rising trend, or requests unresolved at the drain deadline.
	RungUnstable RungClass = "unstable"
	// RungUnreliable keeps pace but fails more requests than the guardrail allows.
	RungUnreliable RungClass = "unreliable"
	// RungInvalid did not measure the engine: it started undrained or offered nothing.
	RungInvalid RungClass = "invalid"
)

// ClassifyRung applies the registered criteria.
//
// Throughput is judged first and reliability apart from it: a stable engine with rare independent errors is not a capacity limit,
// and requiring zero failures made the old rule pass such an engine about half the time at 4 req/s (attack item 2).
func (c CalibrationRule) ClassifyRung(o RungObservation) RungClass {
	if !o.StartedDrained || o.Arrivals <= 0 || !(o.OfferedRate > 0) {
		return RungInvalid
	}
	a := float64(o.Arrivals)
	slack := math.Max(float64(c.OutstandingSlackMin), c.Tolerance*a)
	switch {
	case float64(o.Departures) < (1-c.Tolerance)*a,
		float64(o.OutstandingEnd-o.OutstandingStart) > slack,
		math.IsNaN(o.OutstandingSlopePerSec) || o.OutstandingSlopePerSec > c.Tolerance*o.OfferedRate,
		o.UnresolvedAtDrain > 0:
		return RungUnstable
	case float64(o.Failures)/a > c.MaxFailureFraction:
		return RungUnreliable
	}
	return RungStable
}

// OutstandingSlope is the least-squares slope of outstanding-request samples taken every stepSeconds, or NaN for fewer than two.
func OutstandingSlope(samples []int, stepSeconds float64) float64 {
	n := float64(len(samples))
	if len(samples) < 2 || !(stepSeconds > 0) {
		return math.NaN()
	}
	var sx, sy, sxx, sxy float64
	for i, s := range samples {
		x := float64(i) * stepSeconds
		y := float64(s)
		sx, sy, sxx, sxy = sx+x, sy+y, sxx+x*x, sxy+x*y
	}
	return (n*sxy - sx*sy) / (n*sxx - sx*sx)
}

// MaxRungs bounds the ladder, so calibration has a cost ceiling before it starts.
//
// Fallback runs only after the first expansion rung failed, so expansion and fallback together take at most
// max(MaxExpansion, 1+MaxFallback) rungs, never their sum.
func (c CalibrationRule) MaxRungs() int {
	return max(c.MaxExpansion, 1+c.MaxFallback) + c.MaxRefine + c.Confirmations + c.MaxStepDowns*(1+c.Confirmations) +
		c.MaxInvalidRetries
}

// MaxSeconds bounds calibration's wall time from MaxRungs.
func (c CalibrationRule) MaxSeconds() int {
	return c.MaxRungs() * (c.WarmupSeconds + c.WindowSeconds + c.DrainSeconds)
}

// CalibrationSeed is the trace seed of the rung with this ordinal; no block seed is drawn from this range.
func CalibrationSeed(ordinal int) int64 {
	return 2026111500 + int64(ordinal)
}

// CalibrationRung is one rung in the ledger the artifact records.
type CalibrationRung struct {
	Ordinal int
	Rate    float64
	Purpose string
	Class   RungClass
}

// CalibrationResult is the ladder's outcome; Rate is zero whenever Resolved is false.
type CalibrationResult struct {
	Resolved bool
	Rate     float64
	Reason   string
	Rungs    []CalibrationRung
}

// Run executes the registered ladder against probe, which runs one rung from a drained engine and classifies it.
//
// Every way the ladder can fail ends in an explicit unresolved result, and the session stops there: there is no default λ0.
func (c CalibrationRule) Run(probe func(rate float64, ordinal int) RungClass) CalibrationResult {
	return c.run(func(rate float64, ordinal int) (RungClass, bool, bool) {
		return probe(rate, ordinal), true, false
	})
}

// run is Run with a probe that can also halt the ladder.
//
// The probe reports whether it ran the rung, which is then listed with the class it returned, and whether the ladder
// halts after it.
// A halted ladder lists no rung its probe did not run, because every listed rung must have its own evidence.
func (c CalibrationRule) run(probe func(rate float64, ordinal int) (cls RungClass, ran, halt bool)) CalibrationResult {
	res := CalibrationResult{}
	retries := 0
	halted := false
	stop := func(format string, args ...any) CalibrationResult {
		res.Resolved, res.Rate, res.Reason = false, 0, fmt.Sprintf(format, args...)
		return res
	}
	// rung runs one rate, repeating it once per allowed retry while it is invalid.
	rung := func(rate float64, purpose string) (RungClass, bool) {
		for {
			cls, ran, halt := probe(rate, len(res.Rungs)+1)
			if ran {
				res.Rungs = append(res.Rungs, CalibrationRung{len(res.Rungs) + 1, rate, purpose, cls})
			}
			if halt {
				halted = true
				return cls, false
			}
			if cls != RungInvalid {
				return cls, true
			}
			if retries >= c.MaxInvalidRetries {
				return cls, false
			}
			retries++
		}
	}
	// failed ends the ladder at a rung that did not return a usable class.
	failed := func() CalibrationResult {
		if halted {
			return stop("calibration halted before the ladder resolved")
		}
		return stop("calibration unresolved: rungs stayed invalid after %d retries", c.MaxInvalidRetries)
	}
	unreliable := func() int {
		n := 0
		for _, r := range res.Rungs {
			if r.Class == RungUnreliable {
				n++
			}
		}
		return n
	}

	lo, hi := 0.0, math.Inf(1)
	rate := c.StartRate
	for range c.MaxExpansion {
		cls, ok := rung(rate, "expansion")
		if !ok {
			return failed()
		}
		if cls != RungStable {
			hi = rate
			break
		}
		lo = rate
		rate *= c.Growth
	}
	if math.IsInf(hi, 1) {
		return stop("calibration unresolved: no upper bracket; all %d expansion rungs up to %v req/s were stable", c.MaxExpansion, lo)
	}
	if lo == 0 {
		rate = hi
		for range c.MaxFallback {
			rate *= c.FallbackFactor
			cls, ok := rung(rate, "fallback")
			if !ok {
				return failed()
			}
			if cls == RungStable {
				lo = rate
				break
			}
			hi = rate
		}
		if lo == 0 {
			return stop("calibration unresolved: no stable rate down to the lower fallback %v req/s (%d rungs failed the reliability guardrail)", rate, unreliable())
		}
	}
	for range c.MaxRefine {
		if hi/lo <= c.TargetRatio {
			break
		}
		mid := math.Sqrt(lo * hi)
		cls, ok := rung(mid, "refinement")
		if !ok {
			return failed()
		}
		if cls == RungStable {
			lo = mid
		} else {
			hi = mid
		}
	}
	if hi/lo > c.TargetRatio {
		return stop("calibration unresolved: bracket [%v, %v] still wider than %v after %d refinement rungs", lo, hi, c.TargetRatio, c.MaxRefine)
	}

	// The selected rate passed once; it must pass again on fresh traces, and a rate stepped down to must pass every time.
	candidate, needed := lo, c.Confirmations
	for step := 0; step <= c.MaxStepDowns; step++ {
		confirmed := true
		for range needed {
			cls, ok := rung(candidate, "confirmation")
			if !ok {
				return failed()
			}
			if cls != RungStable {
				confirmed = false
				break
			}
		}
		if confirmed {
			res.Resolved, res.Rate = true, candidate
			return res
		}
		candidate /= c.TargetRatio
		needed = 1 + c.Confirmations
	}
	return stop("calibration unresolved: no rate confirmed after %d step-downs (%d rungs failed the reliability guardrail)", c.MaxStepDowns, unreliable())
}

// RunContext runs the ladder like Run, but stops it when ctx ends, the probe receiving ctx for its own steps.
//
// Once ctx has ended the ladder halts: no further rung is run or listed, so every listed rung has the evidence its probe wrote.
// A rung the session cut off is listed with the class its probe returned, which is the class its own record holds, but
// it never decides the ladder.
// The result is then unresolved with a reason naming the session, never an engine verdict, so a deadline or an
// operator stop is not mistaken for a capacity found or missed.
// A ladder that resolved before ctx ended keeps its result.
func (c CalibrationRule) RunContext(ctx context.Context, probe func(ctx context.Context, rate float64, ordinal int) RungClass) CalibrationResult {
	halted := false
	res := c.run(func(rate float64, ordinal int) (RungClass, bool, bool) {
		if ctx.Err() != nil {
			halted = true
			return RungInvalid, false, true
		}
		cls := probe(ctx, rate, ordinal)
		halted = ctx.Err() != nil
		return cls, true, halted
	})
	if halted {
		res.Resolved, res.Rate = false, 0
		res.Reason = fmt.Sprintf("calibration stopped: the session ended (%v) before the ladder resolved", context.Cause(ctx))
	}
	return res
}
