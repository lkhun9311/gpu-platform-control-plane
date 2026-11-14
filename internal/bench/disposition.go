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

// A row's Disposition is how its request ended, recorded by Replay on every row it writes.
//
// A failed request's disposition is its ErrorKind, so the closed vocabulary the report buckets by is not duplicated.
// The three below name the outcomes ErrorKind has no word for.
const (
	// DispositionCompleted is a 200 response whose stream sent its own end marker and no error.
	DispositionCompleted = "completed"
	// DispositionUnterminated is a 200 response with no error that did not report its end marker.
	//
	// The HTTP sender never produces it, because it names a stream without [DONE] as a stream error.
	// A sender that does not report termination does, and its rows are then truncations rather than completions.
	DispositionUnterminated = "unterminated"
	// DispositionUnsent is a scheduled request the replay never dispatched, because it was cancelled first.
	//
	// It is also the row's ErrorKind, so every consumer that counts failures counts it without knowing the word.
	DispositionUnsent = "unsent"
)

// errKindCancelled is the ErrorKind of a request whose own replay was cancelled while it was in flight.
//
// It was "transport", which charged the cancellation to the system under test.
const errKindCancelled = "cancelled"

// dispositionOf names how a dispatched request ended.
func dispositionOf(res SendResult) string {
	switch {
	case res.ErrorKind != "":
		return res.ErrorKind
	case res.HTTPStatus == httpStatusOK && res.StreamTerminated:
		return DispositionCompleted
	default:
		return DispositionUnterminated
	}
}

// ReconcileRecording refuses a recording that does not account for every request of the trace it replayed, exactly once.
//
// Equal row counts across arms say nothing when every arm lost the same half, so the reference is the trace itself.
// Each scheduled request needs exactly one row with a disposition, at its scheduled offset and tenant, and no row may name a request the trace does not have.
func ReconcileRecording(trace []TraceRow, rows []RawRow) error {
	want := make(map[int]TraceRow, len(trace))
	for _, tr := range trace {
		want[tr.Index] = tr
	}
	seen := make(map[int]int, len(rows))
	var unexpected, undisposed, mismatched []int
	for _, r := range rows {
		seen[r.Index]++
		tr, ok := want[r.Index]
		switch {
		case !ok:
			unexpected = append(unexpected, r.Index)
		case r.Disposition == "":
			undisposed = append(undisposed, r.Index)
		case r.ScheduledOffsetMs != tr.OffsetMs || r.Tenant != tr.Tenant:
			mismatched = append(mismatched, r.Index)
		}
	}
	var missing, duplicated []int
	for idx := range want {
		switch n := seen[idx]; {
		case n == 0:
			missing = append(missing, idx)
		case n > 1:
			duplicated = append(duplicated, idx)
		}
	}
	var problems []string
	for _, p := range []struct {
		what    string
		indices []int
	}{
		{"scheduled but not recorded", missing},
		{"recorded more than once", duplicated},
		{"recorded but not in the trace", unexpected},
		{"recorded without a disposition", undisposed},
		{"recorded at another offset or tenant than the trace schedules", mismatched},
	} {
		if len(p.indices) > 0 {
			problems = append(problems, fmt.Sprintf("%d request(s) %s (%s)", len(p.indices), p.what, sampleIndices(p.indices)))
		}
	}
	if len(problems) > 0 {
		return fmt.Errorf("the recording does not account for the %d scheduled request(s) exactly once: %s", len(trace), strings.Join(problems, "; "))
	}
	return nil
}

// sampleIndices prints the first few indices in order, enough to find the rows without flooding the error.
func sampleIndices(indices []int) string {
	sort.Ints(indices)
	const shown = 5
	parts := make([]string, 0, shown+1)
	for i, idx := range indices {
		if i == shown {
			parts = append(parts, "...")
			break
		}
		parts = append(parts, fmt.Sprint(idx))
	}
	return "index " + strings.Join(parts, ", ")
}

// validateRecordedRows refuses current rows whose recorded facts contradict one another.
//
// Only rows with a disposition are checked: they come from a replay that writes one row per request with a monotonic clock, so a duplicate or an impossible timeline is a defect in the evidence.
// Historical rows carry no disposition and are read exactly as before, because re-scoring them must reproduce what was published.
func validateRecordedRows(rows []RawRow) error {
	seen := map[int]bool{}
	for _, r := range rows {
		if r.Disposition == "" {
			continue
		}
		if seen[r.Index] {
			return fmt.Errorf("raw row %d appears twice; one replay writes one row per request, so the file merges recordings", r.Index)
		}
		seen[r.Index] = true
		if err := validateDisposition(r); err != nil {
			return fmt.Errorf("raw row %d: %w", r.Index, err)
		}
		if err := validateClockOrder(r); err != nil {
			return fmt.Errorf("raw row %d: %w", r.Index, err)
		}
	}
	return nil
}

// validateDisposition checks that the disposition says what the row's other fields say.
func validateDisposition(r RawRow) error {
	switch {
	case r.ErrorKind != "":
		if r.Disposition != r.ErrorKind {
			return fmt.Errorf("disposition %q contradicts errorKind %q", r.Disposition, r.ErrorKind)
		}
		if r.Disposition == DispositionUnsent && r.SendUnixNanos != 0 {
			return fmt.Errorf("an unsent request carries a send time")
		}
	case r.Disposition == DispositionCompleted:
		if r.HTTPStatus != httpStatusOK || !r.StreamTerminated {
			return fmt.Errorf("a completed request has status %d and stream terminated %t", r.HTTPStatus, r.StreamTerminated)
		}
	case r.Disposition == DispositionUnterminated:
		if r.HTTPStatus != httpStatusOK || r.StreamTerminated {
			return fmt.Errorf("an unterminated request has status %d and stream terminated %t", r.HTTPStatus, r.StreamTerminated)
		}
	default:
		return fmt.Errorf("disposition %q is not one this harness writes for a row with no error", r.Disposition)
	}
	return nil
}

// validateClockOrder checks that the row's monotonic events happened in the only order they can.
func validateClockOrder(r RawRow) error {
	c := r.Clock
	if c == nil {
		return fmt.Errorf("a row with a disposition carries no clock")
	}
	if c.TerminalNanos == nil {
		return fmt.Errorf("a row with a disposition carries no terminal time")
	}
	if c.FirstContentNanos != nil && r.FirstTokenUnixNanos == 0 {
		return fmt.Errorf("the clock records a first content frame the row does not")
	}
	order := []struct {
		name string
		at   *int64
	}{
		{"send", c.SendNanos},
		{"first content", c.FirstContentNanos},
		{"last content", c.LastContentNanos},
		{"stream end", c.EndNanos},
		{"terminal", c.TerminalNanos},
	}
	var prevName string
	var prev *int64
	for _, e := range order {
		if e.at == nil {
			continue
		}
		if prev != nil && *e.at < *prev {
			return fmt.Errorf("%s at %d ns precedes %s at %d ns", e.name, *e.at, prevName, *prev)
		}
		prevName, prev = e.name, e.at
	}
	return nil
}
