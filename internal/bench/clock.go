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

import "time"

// RequestClock is one request's timeline as elapsed time on Go's monotonic clock, measured from its replay's origin.
//
// The unix stamps on RawRow are wall-clock readings, and a difference of two of them moves with every NTP step or slew between them.
// time.Time.Sub uses the monotonic reading when both operands carry one, which is what every latency here is computed from.
// The unix stamps stay on the row for correlation with the gateway's and the engine's records, which are only on the wall clock.
//
// Every event is a pointer because zero is a real elapsed time (a request sent at the origin), so absence needs its own value.
type RequestClock struct {
	// OriginUnixNanos is the replay origin's wall-clock instant.
	//
	// It is never subtracted from; it says which replay the elapsed times are measured from, so rows of two replays are never differenced.
	OriginUnixNanos int64 `json:"originUnixNanos"`
	// SendNanos is when the scheduler dispatched the request; nil only for a request that was never sent.
	SendNanos *int64 `json:"sendNanos,omitempty"`
	// FirstContentNanos and LastContentNanos are the first and the last content frame's arrival; nil when none arrived.
	//
	// The last content frame is kept apart from the stream's end because the usage chunk and the end marker follow it, and that trailer is not output.
	FirstContentNanos *int64 `json:"firstContentNanos,omitempty"`
	LastContentNanos  *int64 `json:"lastContentNanos,omitempty"`
	// EndNanos is when the response stream finished or broke, the same instant as RawRow.EndUnixNanos; nil when no stream ended.
	EndNanos *int64 `json:"endNanos,omitempty"`
}

// elapsedSince is t measured from origin on the monotonic clock, or nil when t was never stamped.
func elapsedSince(origin, t time.Time) *int64 {
	if t.IsZero() {
		return nil
	}
	n := int64(t.Sub(origin))
	return &n
}

// clockSpan returns to minus from when both are on the row's clock, and whether they were.
//
// A negative span cannot come from the monotonic clock, so it is refused rather than returned as a latency.
func clockSpan(from, to *int64) (int64, bool) {
	if from == nil || to == nil || *to < *from {
		return 0, false
	}
	return *to - *from, true
}

// activeSpanNanos is the span from the first send to the last stream end over rows, and how it was measured.
//
// When every row carries a clock from one replay, the span is read off that monotonic clock.
// Otherwise it is the wall-clock span the report always used, because rows from several replays, or written before the clock existed, share no monotonic origin.
func activeSpanNanos(rows []RawRow) int64 {
	if span, ok := monotonicActiveSpan(rows); ok {
		return span
	}
	var firstSend, lastEnd int64
	for _, r := range rows {
		if r.SendUnixNanos > 0 && (firstSend == 0 || r.SendUnixNanos < firstSend) {
			firstSend = r.SendUnixNanos
		}
		if r.EndUnixNanos > lastEnd {
			lastEnd = r.EndUnixNanos
		}
	}
	return lastEnd - firstSend
}

// monotonicActiveSpan is activeSpanNanos on the clock, and false when the rows do not all share one replay's clock.
func monotonicActiveSpan(rows []RawRow) (int64, bool) {
	if len(rows) == 0 {
		return 0, false
	}
	var firstSend, lastEnd *int64
	for _, r := range rows {
		if r.Clock == nil || r.Clock.OriginUnixNanos != rows[0].Clock.OriginUnixNanos {
			return 0, false
		}
		// A sender that reports no time.Time values leaves the clock without events the unix stamps have, and the clock then cannot say the span.
		if (r.SendUnixNanos != 0) != (r.Clock.SendNanos != nil) || (r.EndUnixNanos != 0) != (r.Clock.EndNanos != nil) {
			return 0, false
		}
		if s := r.Clock.SendNanos; s != nil && (firstSend == nil || *s < *firstSend) {
			firstSend = s
		}
		if e := r.Clock.EndNanos; e != nil && (lastEnd == nil || *e > *lastEnd) {
			lastEnd = e
		}
	}
	// No completed stream leaves the span at zero, exactly as the wall-clock path does with no end stamp.
	if firstSend == nil || lastEnd == nil {
		return 0, true
	}
	return clockSpanOrZero(firstSend, lastEnd), true
}

// clockSpanOrZero is clockSpan with a refused span read as zero, which SetActiveSeconds treats as no throughput.
func clockSpanOrZero(from, to *int64) int64 {
	span, ok := clockSpan(from, to)
	if !ok {
		return 0
	}
	return span
}
