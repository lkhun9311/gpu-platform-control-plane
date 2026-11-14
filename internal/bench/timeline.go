/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package bench

import (
	"fmt"
	"sort"
	"strings"
)

// Distribution is a population's quantiles, how many samples they rest on, and whether they are a measurement at all.
//
// The historical fields beside it (TTFTMsP99, TPOTMsP99, ...) are bare numbers, and an empty population printed there as 0, the best latency there is.
// Here an empty or incomplete population is Valid false with a reason, and its quantiles stay zero so no consumer can read one off by accident.
type Distribution struct {
	// N is how many samples the quantiles rest on.
	N int
	// P50, P95, P99 and Max are nearest-rank quantiles in milliseconds, set only when Valid.
	P50, P95, P99, Max float64
	// Valid says the quantiles describe the whole registered population.
	Valid bool
	// InvalidReason says why there is no number, when there is none.
	InvalidReason string
}

// newDistribution builds a Distribution over samples, refusing it when missing rows of the population carry no sample.
//
// A quantile over the rows that happened to record the evidence describes a different population, often the faster one, so it is refused rather than published.
func newDistribution(samples []float64, missing int, missingWhat string) Distribution {
	d := Distribution{N: len(samples)}
	if missing > 0 {
		d.InvalidReason = fmt.Sprintf("%d row(s) of the population %s, so quantiles over the rest would describe another population", missing, missingWhat)
		return d
	}
	sorted := append([]float64(nil), samples...)
	sort.Float64s(sorted)
	var err error
	for _, q := range []struct {
		at  float64
		out *float64
	}{{0.50, &d.P50}, {0.95, &d.P95}, {0.99, &d.P99}, {1, &d.Max}} {
		if *q.out, err = percentileOf(sorted, q.at); err != nil {
			return Distribution{N: len(samples), InvalidReason: err.Error()}
		}
	}
	d.Valid = true
	return d
}

// summarizeTimeline fills the quantities read off the monotonic clock and the recorded content gaps.
//
// They are new fields beside the historical ones, never replacements: a study already published keeps every number it was scored with.
// A row written before the clock existed has none of this evidence, so these come out invalid on historical rows instead of guessed.
func (s *ArmSummary) summarizeTimeline(rows []RawRow, contract OutputCountContract) {
	var ttft, tpot, gaps, lag []float64
	var tpotMissing, gapsMissing, lagMissing int
	for _, r := range rows {
		// Observed TTFT is the premium population the tail is about, minus the requests the admission policy shed by design.
		// A first token stays observed whatever happened to the stream afterwards.
		if !r.IsNoisy && !shedByAdmission(r) {
			if v, ok := r.TTFTNanos(); ok {
				ttft = append(ttft, nanosToMs(v))
			}
		}
		if v, inPop, ok := tpotToLastContent(r, contract); inPop {
			if ok {
				tpot = append(tpot, v)
			} else {
				tpotMissing++
			}
		}
		if inPop, ok := hasRecordedGaps(r); inPop {
			if ok {
				for _, g := range r.ContentGapsMicros {
					gaps = append(gaps, float64(g)/1000)
				}
			} else {
				gapsMissing++
			}
		}
		if r.SendUnixNanos != 0 {
			if r.Clock == nil || r.Clock.SendNanos == nil {
				lagMissing++
			} else {
				lag = append(lag, nanosToMs(*r.Clock.SendNanos)-float64(r.ScheduledOffsetMs))
			}
		}
	}
	s.TTFTObserved = newDistribution(ttft, 0, "")
	s.TPOTToLastContent = newDistribution(tpot, tpotMissing, "carry no last-content time or no countable output")
	s.ContentGaps = newDistribution(gaps, gapsMissing, "streamed two or more content frames without recording their gaps (the study does not record timing)")
	s.DispatchLag = newDistribution(lag, lagMissing, "were sent without a monotonic send time")
	s.ObservedSeconds, s.ObservedWindowValid = observedWindowSeconds(rows)
}

// tpotToLastContent is one completed row's time per output unit after the first, measured to the last content frame.
//
// inPop says the row belongs to the TPOT population: a completed response with at least two content frames, the fewest a span between frames exists for.
// ok says it could be measured; a member without a clock, or without a count under its contract, cannot be.
func tpotToLastContent(r RawRow, contract OutputCountContract) (v float64, inPop, ok bool) {
	if r.HTTPStatus != httpStatusOK || r.ErrorKind != "" || r.OutputTokens < 2 {
		return 0, false, false
	}
	n, measurable := contract.count(r)
	if !measurable || n < 2 || r.Clock == nil {
		return 0, true, false
	}
	span, spanOK := clockSpan(r.Clock.FirstContentNanos, r.Clock.LastContentNanos)
	if !spanOK {
		return 0, true, false
	}
	return nanosToMs(span) / float64(n-1), true, true
}

// hasRecordedGaps says whether the row streamed gaps the population needs, and whether it recorded every one of them.
//
// Failed streams are included: the gaps they delivered before failing were observed, and dropping them would keep only the streams that survived.
func hasRecordedGaps(r RawRow) (inPop, ok bool) {
	if r.HTTPStatus != httpStatusOK || r.OutputTokens < 2 {
		return false, false
	}
	return true, len(r.ContentGapsMicros) == r.OutputTokens-1
}

// observedWindowSeconds is the span from the first send to the last terminal outcome on one replay's monotonic clock.
//
// ActiveSeconds ends at the last completed stream, so a request that waited 30 s for headers and timed out lay outside the time the arm was charged.
// This window ends at the last outcome of any kind, and is invalid unless every row carries a terminal time on the same clock.
func observedWindowSeconds(rows []RawRow) (float64, bool) {
	if len(rows) == 0 || rows[0].Clock == nil {
		return 0, false
	}
	var first, last *int64
	for _, r := range rows {
		c := r.Clock
		if c == nil || c.OriginUnixNanos != rows[0].Clock.OriginUnixNanos || c.TerminalNanos == nil {
			return 0, false
		}
		if c.SendNanos != nil && (first == nil || *c.SendNanos < *first) {
			first = c.SendNanos
		}
		if last == nil || *c.TerminalNanos > *last {
			last = c.TerminalNanos
		}
	}
	span, ok := clockSpan(first, last)
	if !ok {
		return 0, false
	}
	return nanosToMs(span) / 1000, true
}

// formatTimeline is the report's section on the clock-derived quantities, empty unless some arm recorded a clock.
//
// Historical evidence has no clock, so its report renders exactly as it always did.
func formatTimeline(summaries []ArmSummary) string {
	recorded := false
	for _, s := range summaries {
		recorded = recorded || s.ObservedWindowValid || s.DispatchLag.N > 0
	}
	if !recorded {
		return ""
	}
	var b strings.Builder
	b.WriteString("\nMonotonic timeline (ms; n is the sample count, and an invalid population prints its reason instead of a number)\n")
	for _, s := range summaries {
		fmt.Fprintf(&b, "%s: observed window %s\n", s.Arm, formatWindow(s))
		for _, m := range []struct {
			name string
			d    Distribution
		}{
			{"TTFT observed (incl. streams that later failed)", s.TTFTObserved},
			{"TPOT to last content", s.TPOTToLastContent},
			{"content gap", s.ContentGaps},
			{"dispatch lag", s.DispatchLag},
		} {
			fmt.Fprintf(&b, "  %-48s %s\n", m.name, formatDistribution(m.d))
		}
	}
	return b.String()
}

func formatWindow(s ArmSummary) string {
	if !s.ObservedWindowValid {
		return "not measured"
	}
	return fmt.Sprintf("%.3f s", s.ObservedSeconds)
}

func formatDistribution(d Distribution) string {
	if !d.Valid {
		return fmt.Sprintf("n=%d invalid: %s", d.N, d.InvalidReason)
	}
	return fmt.Sprintf("n=%d p50 %.1f p95 %.1f p99 %.1f max %.1f", d.N, d.P50, d.P95, d.P99, d.Max)
}
