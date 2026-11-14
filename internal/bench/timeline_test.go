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
	"strings"
	"testing"
	"time"
)

// clockedRow is a current row: sent at sendMs, first content after ttftMs, last content at lastMs, stream end at endMs, terminal 1 ms later.
func clockedRow(i int, sendMs, ttftMs, lastMs, endMs float64, frames int) RawRow {
	base := int64(1_700_000_000_000_000_000)
	ms := func(v float64) *int64 { n := int64(v * 1e6); return &n }
	r := RawRow{
		Index: i, Tenant: PremiumTenant, HTTPStatus: 200, StreamTerminated: true, OutputTokens: frames,
		ScheduledOffsetMs:   int64(sendMs),
		SendUnixNanos:       base + int64(sendMs*1e6),
		FirstTokenUnixNanos: base + int64((sendMs+ttftMs)*1e6),
		EndUnixNanos:        base + int64(endMs*1e6),
		Disposition:         DispositionCompleted,
		Clock: &RequestClock{
			OriginUnixNanos:   base,
			SendNanos:         ms(sendMs),
			FirstContentNanos: ms(sendMs + ttftMs),
			LastContentNanos:  ms(lastMs),
			EndNanos:          ms(endMs),
			TerminalNanos:     ms(endMs + 1),
		},
	}
	gaps := make([]int64, 0, frames-1)
	for k := 1; k < frames; k++ {
		gaps = append(gaps, int64((lastMs-sendMs-ttftMs)*1000)/int64(frames-1))
	}
	r.ContentGapsMicros = gaps
	return r
}

// A first token that was observed stays observed when the stream later fails, in its own population beside the completed-request tail.
// Audit finding 6: TTFT was taken from completed rows only, so an arm that failed its slow streams after their first token showed a better TTFT.
// Mutation that turns it red: skip rows with an ErrorKind in the observed-TTFT population.
func TestObservedTTFTKeepsAFirstTokenTheStreamLaterLost(t *testing.T) {
	ok := clockedRow(0, 0, 10, 50, 60, 5)
	lost := clockedRow(1, 10, 900, 1000, 1000, 3)
	lost.ErrorKind, lost.Disposition, lost.StreamTerminated = errorKindStream, errorKindStream, false
	s := Summarize("a", []RawRow{ok, lost})
	if s.TTFTMsP99 != 10 {
		t.Fatalf("the completed-request TTFT p99 changed to %g; it must stay what it was", s.TTFTMsP99)
	}
	if !s.TTFTObserved.Valid || s.TTFTObserved.N != 2 || s.TTFTObserved.P99 != 900 {
		t.Fatalf("observed TTFT = %+v; want 2 samples with p99 900", s.TTFTObserved)
	}
}

// TPOT runs from the first to the last content frame, so the usage chunk and end marker after the last token are not charged to it.
// Audit finding 8: TPOT used the end marker's time, so a slow trailer after identical content made one arm's TPOT worse.
// Mutation that turns it red: use EndNanos instead of LastContentNanos in tpotToLastContent.
func TestTPOTEndsAtTheLastContentFrame(t *testing.T) {
	// Five frames from 10 ms to 50 ms, then a 500 ms trailer before the end marker.
	r := clockedRow(0, 0, 10, 50, 550, 5)
	s := Summarize("a", []RawRow{r})
	if !s.TPOTToLastContent.Valid || s.TPOTToLastContent.P50 != 10 {
		t.Fatalf("TPOT to last content = %+v; want 10 ms, (50 - 10) / 4", s.TPOTToLastContent)
	}
	if s.TPOTMsP50 != 135 {
		t.Fatalf("the historical TPOT changed to %g; it must stay (550 - 10) / 4 = 135", s.TPOTMsP50)
	}
}

// The content-gap percentiles are taken over individual gaps, so one long stall among short gaps reaches the tail.
// Audit finding 8: the "inter-content-frame p99" was a p99 of per-request averages, which averages a stall away.
// Mutation that turns it red: append the per-row average gap instead of each recorded gap.
func TestContentGapPercentilesComeFromIndividualGaps(t *testing.T) {
	var rows []RawRow
	for i := range 10 {
		send := float64(i * 1000)
		r := clockedRow(i, send, 10, send+10+99, send+200, 100)
		// Ninety-nine 1 ms gaps, except row 0, whose last gap is a 500 ms stall.
		r.ContentGapsMicros = make([]int64, 99)
		for k := range r.ContentGapsMicros {
			r.ContentGapsMicros[k] = 1000
		}
		if i == 0 {
			r.ContentGapsMicros[98] = 500_000
		}
		rows = append(rows, r)
	}
	s := Summarize("a", rows)
	if !s.ContentGaps.Valid || s.ContentGaps.N != 990 {
		t.Fatalf("content gaps = %+v; want 990 samples", s.ContentGaps)
	}
	if s.ContentGaps.P50 != 1 {
		t.Fatalf("content gap p50 = %g; want 1 ms", s.ContentGaps.P50)
	}
	// 1 of 990 gaps is the stall, so it is above p99; the max is what the stall must reach.
	if s.ContentGaps.Max != 500 {
		t.Fatalf("content gap max = %g; want the 500 ms stall", s.ContentGaps.Max)
	}
}

// An empty population or one with rows that lack the evidence is reported invalid with a reason and no number, never as 0.
// Audit finding 7: an empty TPOT sample became 0 ms, and under engine tokens a TPOT was published over the rows that happened to carry usage.
// Mutation that turns it red: let newDistribution publish quantiles when rows are missing, or mark an empty one valid.
func TestDistributionsRefuseEmptyOrIncompletePopulations(t *testing.T) {
	historical := completedRow(0, 10, 10)
	historical.Tenant = PremiumTenant
	s := Summarize("a", []RawRow{historical})
	for name, d := range map[string]Distribution{"tpot": s.TPOTToLastContent, "gaps": s.ContentGaps, "lag": s.DispatchLag} {
		if d.Valid || d.InvalidReason == "" || d.P99 != 0 {
			t.Fatalf("%s from a row that never recorded it = %+v; want invalid with a reason and no number", name, d)
		}
	}
	empty := Summarize("a", nil)
	if empty.TTFTObserved.Valid || !strings.Contains(empty.TTFTObserved.InvalidReason, "no samples") {
		t.Fatalf("an empty arm's observed TTFT = %+v", empty.TTFTObserved)
	}
	// Under engine tokens, a delivered row with no usage leaves TPOT invalid rather than computed over the rest.
	// No registered study counts engine tokens yet, so the contract is handed to the timeline directly.
	withUsage := clockedRow(0, 0, 10, 50, 60, 5)
	withUsage.EngineOutputTokens = 5
	noUsage := clockedRow(1, 100, 10, 150, 160, 5)
	var tok ArmSummary
	tok.summarizeTimeline([]RawRow{withUsage, noUsage}, OutputCountEngineTokens)
	if tok.TPOTToLastContent.Valid {
		t.Fatalf("TPOT was published over the rows that carried usage: %+v", tok.TPOTToLastContent)
	}
}

// Dispatch lag is how late each request left against its schedule, on the monotonic clock.
// Audit finding 10 (measurement half): nothing in the evidence measured how far the arrival process drifted.
// Mutation that turns it red: compute the lag from SendUnixNanos.
func TestDispatchLagIsMeasuredOnTheClock(t *testing.T) {
	a := clockedRow(0, 0, 10, 50, 60, 5)
	b := clockedRow(1, 100, 10, 150, 160, 5)
	b.ScheduledOffsetMs = 97
	// A wall-clock step that the monotonic clock never saw.
	b.SendUnixNanos += int64(time.Hour)
	s := Summarize("a", []RawRow{a, b})
	if !s.DispatchLag.Valid || s.DispatchLag.Max != 3 {
		t.Fatalf("dispatch lag = %+v; want a max of 3 ms", s.DispatchLag)
	}
}

// The observed window runs from the first send to the last terminal outcome, so a request that waited 30 s for headers and timed out is inside it.
// Audit finding 9: the throughput window ended at the last completed stream, so a run's failures could fall outside the time it was charged.
// Mutation that turns it red: end the observed window at EndNanos instead of TerminalNanos.
func TestObservedWindowIncludesEveryTerminalOutcome(t *testing.T) {
	done := clockedRow(0, 0, 10, 900, 1000, 5)
	timedOut := RawRow{
		Index: 1, Tenant: PremiumTenant, ErrorKind: errKindTimeout, Disposition: errKindTimeout,
		SendUnixNanos: done.SendUnixNanos + 1,
		Clock:         &RequestClock{OriginUnixNanos: done.Clock.OriginUnixNanos, SendNanos: elapsed(0), TerminalNanos: elapsed(30 * time.Second)},
	}
	s := Summarize("a", []RawRow{done, timedOut})
	if s.ActiveSeconds != 1 {
		t.Fatalf("the historical active span changed to %g s", s.ActiveSeconds)
	}
	if !s.ObservedWindowValid || s.ObservedSeconds != 30 {
		t.Fatalf("observed window = %g s (valid %t); want 30 s", s.ObservedSeconds, s.ObservedWindowValid)
	}
}
