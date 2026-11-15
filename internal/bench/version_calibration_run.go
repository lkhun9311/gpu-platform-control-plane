package bench

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	dto "github.com/prometheus/client_model/go"
	"github.com/prometheus/common/expfmt"
	"github.com/prometheus/common/model"
)

// CalibrationTrace is one rung's workload: the registered mixture at rate, seeded by the rung's ordinal, cut at warm-up plus window.
//
// The seed comes from CalibrationSeed, a range no block seed is drawn from, so a rung never previews a block's requests.
// A rung's warm-up is not stratified: the registration qualifies the campaign's warm-ups, not the ladder's.
func (d VersionStudyDesign) CalibrationTrace(ordinal int, rate float64) ([]TraceRow, error) {
	chars, err := d.promptChars()
	if err != nil {
		return nil, err
	}
	c := d.Calibration
	rows, err := d.arrivalStream(CalibrationSeed(ordinal), rate, float64(c.WarmupSeconds+c.WindowSeconds)*1000, chars)
	if err != nil {
		return nil, err
	}
	stampExactTokens(rows)
	return rows, nil
}

// ObserveRung reads one rung's observation off the replayed rows' own monotonic clock.
//
// The window is the rung's, in intended-arrival time. A request is outstanding at t when it arrived before t and had not ended by t.
// A row without an intended arrival or a disposition cannot be placed, so the rung is refused rather than counted around it.
func ObserveRung(rows []RawRow, rate float64, rule CalibrationRule, startedDrained bool) (RungObservation, error) {
	sec := int64(time.Second)
	start := int64(rule.WarmupSeconds) * sec
	end := start + int64(rule.WindowSeconds)*sec
	deadline := end + int64(rule.DrainSeconds)*sec
	o := RungObservation{OfferedRate: rate, WindowSeconds: float64(rule.WindowSeconds), StartedDrained: startedDrained}
	type span struct{ from, to int64 }
	spans := make([]span, 0, len(rows))
	for _, r := range rows {
		if r.Clock == nil || r.Clock.IntendedNanos == nil {
			return RungObservation{}, fmt.Errorf("row %d carries no intended arrival, so its rung window cannot be placed", r.Index)
		}
		if r.Disposition == "" {
			return RungObservation{}, fmt.Errorf("row %d carries no disposition", r.Index)
		}
		in := *r.Clock.IntendedNanos
		// A request that never ended is open for the whole rung and past any deadline.
		to := int64(1<<62 - 1)
		if r.Clock.TerminalNanos != nil {
			to = *r.Clock.TerminalNanos
		}
		spans = append(spans, span{in, to})
		if in >= start && in < end {
			o.Arrivals++
			if r.Disposition != DispositionCompleted {
				o.Failures++
			}
			if to > deadline {
				o.UnresolvedAtDrain++
			}
		}
		if to >= start && to < end {
			o.Departures++
		}
	}
	outstanding := func(t int64) int {
		n := 0
		for _, s := range spans {
			if s.from < t && t < s.to {
				n++
			}
		}
		return n
	}
	o.OutstandingStart, o.OutstandingEnd = outstanding(start), outstanding(end)
	samples := make([]int, 0, rule.WindowSeconds+1)
	for t := start; t <= end; t += sec {
		samples = append(samples, outstanding(t))
	}
	o.OutstandingSlopePerSec = OutstandingSlope(samples, 1)
	return o, nil
}

// EngineQueueReader returns the engine's own running and waiting request counts.
type EngineQueueReader func(ctx context.Context) (running, waiting int, err error)

// maxEngineMetricsBytes bounds one metrics read, so a misbehaving endpoint cannot exhaust memory.
const maxEngineMetricsBytes = 8 << 20

// ParseEngineQueue reads vLLM's running and waiting gauges from Prometheus text, summed over their series.
//
// Missing gauges are an error: an engine that does not report its queue cannot be shown drained.
func ParseEngineQueue(r io.Reader) (running, waiting int, err error) {
	parser := expfmt.NewTextParser(model.LegacyValidation)
	mfs, err := parser.TextToMetricFamilies(io.LimitReader(r, maxEngineMetricsBytes))
	if err != nil {
		return 0, 0, fmt.Errorf("parse engine metrics: %w", err)
	}
	sum := func(name string) (int, error) {
		mf, ok := mfs[name]
		if !ok || len(mf.GetMetric()) == 0 {
			return 0, fmt.Errorf("engine metrics carry no %s", name)
		}
		total := 0.0
		for _, m := range mf.GetMetric() {
			total += gaugeOrUntyped(m)
		}
		return int(total), nil
	}
	if running, err = sum("vllm:num_requests_running"); err != nil {
		return 0, 0, err
	}
	if waiting, err = sum("vllm:num_requests_waiting"); err != nil {
		return 0, 0, err
	}
	return running, waiting, nil
}

// gaugeOrUntyped is a sample's value whether the exposition typed it as a gauge or left it untyped.
func gaugeOrUntyped(m *dto.Metric) float64 {
	if g := m.GetGauge(); g != nil {
		return g.GetValue()
	}
	return m.GetUntyped().GetValue()
}

// HTTPEngineQueue reads the queue gauges from an engine's metrics URL.
func HTTPEngineQueue(client *http.Client, metricsURL string) EngineQueueReader {
	return func(ctx context.Context) (int, int, error) {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, metricsURL, nil)
		if err != nil {
			return 0, 0, err
		}
		resp, err := client.Do(req)
		if err != nil {
			return 0, 0, err
		}
		defer func() { _ = resp.Body.Close() }()
		if resp.StatusCode != http.StatusOK {
			return 0, 0, fmt.Errorf("engine metrics returned %d", resp.StatusCode)
		}
		return ParseEngineQueue(resp.Body)
	}
}

// WaitDrained polls the engine until it reports nothing running or waiting, and reports false if the bound passes first.
//
// It always reads at least once, on the caller's context, so a bound already used up still tells an idle engine from a busy one.
// A failed read is not idle: an engine whose queue cannot be read cannot be shown drained.
func WaitDrained(ctx context.Context, read EngineQueueReader, bound, every time.Duration) bool {
	deadline := time.Now().Add(bound)
	for {
		if running, waiting, err := read(ctx); err == nil && running == 0 && waiting == 0 {
			return true
		}
		left := time.Until(deadline)
		if left <= 0 {
			return false
		}
		select {
		case <-ctx.Done():
			return false
		case <-time.After(min(every, left)):
		}
	}
}

// RungRunner runs the registered ladder's rungs against one engine and keeps every rung's rows and observation.
type RungRunner struct {
	Design VersionStudyDesign
	Sender Sender
	// Sampling is the study's policy, which every completed row must conform to before the rung counts.
	Sampling SamplingPolicy
	Queue    EngineQueueReader
	// PollEvery is how often the drained check reads the engine.
	PollEvery time.Duration
	// OnRung receives each rung's rows, observation and class, so a session can keep the evidence before the ladder moves on.
	OnRung func(ordinal int, rows []RawRow, o RungObservation, cls RungClass, err error)
	// drainDeadline is the previous rung's warm-up plus window plus drain, measured from its replay's start.
	drainDeadline time.Time
}

// drainBound is how long the next rung may wait for the engine to drain.
//
// It is what is left of the previous rung's deadline, never a fresh allowance, so a rung that overran into its drain does not lengthen the next.
// That keeps every rung inside the warm-up plus window plus drain that CalibrationRule.MaxSeconds budgets.
func (r *RungRunner) drainBound(now time.Time) time.Duration {
	if r.drainDeadline.IsZero() {
		return time.Duration(r.Design.Calibration.DrainSeconds) * time.Second
	}
	return max(r.drainDeadline.Sub(now), 0)
}

// Probe runs one rung from a drained engine and classifies it; it is the probe CalibrationRule.Run calls.
//
// Anything that keeps the rung from measuring the engine makes it invalid, and the ladder's retry bound then decides whether calibration stops.
func (r *RungRunner) Probe(ctx context.Context, rate float64, ordinal int) RungClass {
	rule := r.Design.Calibration
	report := func(rows []RawRow, o RungObservation, cls RungClass, err error) RungClass {
		if r.OnRung != nil {
			r.OnRung(ordinal, rows, o, cls, err)
		}
		return cls
	}
	drained := WaitDrained(ctx, r.Queue, r.drainBound(time.Now()), r.PollEvery)
	if !drained {
		// The retry gets its own bounded allowance; the ladder budgets every retry as a full rung.
		r.drainDeadline = time.Time{}
		return report(nil, RungObservation{OfferedRate: rate}, RungInvalid, errors.New("the engine did not report an empty queue within the drain bound"))
	}
	trace, err := r.Design.CalibrationTrace(ordinal, rate)
	if err != nil {
		return report(nil, RungObservation{OfferedRate: rate}, RungInvalid, err)
	}
	// The prefix goes on the wire as well as on the rows, so each row can be joined to the engine's own log.
	prefix := fmt.Sprintf("cal%d", ordinal)
	if s, ok := r.Sender.(interface{ SetRequestIDPrefix(string) }); ok {
		s.SetRequestIDPrefix(prefix)
	}
	r.drainDeadline = time.Now().Add(time.Duration(rule.WarmupSeconds+rule.WindowSeconds+rule.DrainSeconds) * time.Second)
	rows := Replay(ctx, r.Sender, trace, ReplayOptions{Arm: fmt.Sprintf("calibration-%d", ordinal), RequestIDPrefix: prefix})
	o, err := ObserveRung(rows, rate, rule, drained)
	if err != nil {
		return report(rows, o, RungInvalid, err)
	}
	// A completed request that did not do the registered work makes the rung measure a lighter workload, so it invalidates the rung.
	if err := r.checkConformance(trace, rows); err != nil {
		return report(rows, o, RungInvalid, err)
	}
	return report(rows, o, rule.ClassifyRung(o), nil)
}

// checkConformance runs every replayed row through ClassifyRow, the study's own conformance rule, against its trace row.
func (r *RungRunner) checkConformance(trace []TraceRow, rows []RawRow) error {
	byIndex := make(map[int]TraceRow, len(trace))
	for _, t := range trace {
		byIndex[t.Index] = t
	}
	for _, row := range rows {
		tr, ok := byIndex[row.Index]
		if !ok {
			return fmt.Errorf("row %d is not in the rung's trace", row.Index)
		}
		if _, err := ClassifyRow(r.Sampling, rowFacts(row, tr)); err != nil {
			return fmt.Errorf("row %d does not conform: %w", row.Index, err)
		}
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
