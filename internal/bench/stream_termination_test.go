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
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

// A stream that stopped arriving and one that finished must not read the same.
//
// WHAT THIS IS FOR. TimeoutMs bounds the whole request and the scanner returns no error at EOF, so a
// response cut off mid-stream produced exactly what a complete one did: ErrorKind "", HTTP 200, a stamped
// first token, and an output-token count. Measured 2026-10-04 before the fix -- a clean stream, a truncated
// stream and one carrying an SSE error object were byte-identical in every field the report reads. All three
// therefore entered the completed population and contributed their TTFT to the tail.
//
// The three facts are kept separate rather than collapsed into ErrorKind, matching how this package already
// splits the FinishReason silences: what the engine said, whether the stream ended, and whether the engine
// reported a failure in band are three different questions.

const streamChunk = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"

func readOneStream(t *testing.T, body string) SendResult {
	t.Helper()
	h := NewHTTPSender("http://127.0.0.1:1", "m", nil, time.Second, SenderConn{})
	resp := &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body))}
	return h.readStream(context.Background(), resp)
}

func TestACleanStreamRecordsItsOwnEndMarker(t *testing.T) {
	res := readOneStream(t, streamChunk+"data: [DONE]\n\n")
	if !res.StreamTerminated {
		t.Error("a stream that sent [DONE] is not recorded as terminated, so it cannot be told from a truncated one")
	}
	if res.ErrorKind != "" {
		t.Errorf("a clean stream reported ErrorKind %q", res.ErrorKind)
	}
	if res.StreamError != "" {
		t.Errorf("a clean stream reported StreamError %q", res.StreamError)
	}
}

func TestATruncatedStreamIsDistinguishableFromACompleteOne(t *testing.T) {
	// The whole defect in one comparison: both of these look complete by every other field.
	clean := readOneStream(t, streamChunk+"data: [DONE]\n\n")
	cut := readOneStream(t, streamChunk)

	if cut.StreamTerminated {
		t.Fatal("a stream that ended without [DONE] was recorded as terminated")
	}
	// Since 2026-11-07 the sender also names the truncation where every reader buckets failures: StreamTerminated
	// alone left the decision to readers, and the report never made it (review r7).
	// Mutation that turns this red: drop the no-[DONE] branch at the end of readStream.
	if clean.ErrorKind != "" || cut.ErrorKind != errorKindStream || cut.StreamError != streamErrorNoEndMarker {
		t.Errorf("clean ErrorKind %q; truncated ErrorKind %q, StreamError %q: a truncated stream must be a stream failure",
			clean.ErrorKind, cut.ErrorKind, cut.StreamError)
	}
	if (clean.FirstTokenUnixNanos != 0) != (cut.FirstTokenUnixNanos != 0) {
		t.Error("one of the two carries a first token and the other does not; the premise has changed")
	}
	if clean.OutputTokens != cut.OutputTokens {
		t.Errorf("output tokens differ (%d vs %d); the premise has changed", clean.OutputTokens, cut.OutputTokens)
	}
}

func TestAnInBandEngineErrorIsNotASuccess(t *testing.T) {
	// Valid JSON with no field this struct declared, which is why it was dropped silently. The HTTP status
	// is 200 because the headers went out before the engine failed, so status cannot carry it either.
	res := readOneStream(t, streamChunk+
		"data: {\"error\":{\"message\":\"engine aborted\",\"type\":\"server_error\"}}\n\n"+
		"data: [DONE]\n\n")

	if res.ErrorKind != "stream" {
		t.Errorf("an SSE error object produced ErrorKind %q; it must be bucketed as a stream failure", res.ErrorKind)
	}
	for _, want := range []string{"server_error", "engine aborted"} {
		if !strings.Contains(res.StreamError, want) {
			t.Errorf("StreamError %q does not carry %q; the engine's own words are what make the failure diagnosable", res.StreamError, want)
		}
	}
	// It returns at the error frame, so the [DONE] that followed is never seen. That is correct and worth
	// pinning: a terminated flag set after a failure would say the response finished normally.
	if res.StreamTerminated {
		t.Error("a stream that failed in band was also recorded as cleanly terminated")
	}
}

// terminationSender returns a fixed SendResult, so what Replay does with it is what is under test.
//
// Its own stub rather than replay_test.go's stubSender, which cannot express these two fields: widening
// that one would change what four existing specs mean, and the question here is narrower.
type terminationSender struct{ res SendResult }

func (s terminationSender) Send(_ context.Context, _ TraceRow, sendUnixNanos int64) SendResult {
	out := s.res
	out.FirstTokenUnixNanos = sendUnixNanos + 1
	out.EndUnixNanos = sendUnixNanos + 2
	// The recorded stream's own monotonic stamps belong to an earlier read, so they are dropped with the unix ones they no longer match.
	out.FirstContentAt, out.LastContentAt, out.EndAt, out.ContentAt = time.Time{}, time.Time{}, time.Time{}, nil
	return out
}

// The two fields reach the ROW, and survive the file.
//
// readStream computing them correctly says nothing about whether anything downstream can see them: Replay
// builds RawRow field by field, so a result field with no corresponding line in that literal is computed and
// discarded. This repository has shipped exactly that -- a count the engine was sending that nothing copied.
// Driving Replay and then a JSON round-trip is what covers the two steps the unit tests above cannot.
func TestTheTerminationFactsReachTheRowAndSurviveTheFile(t *testing.T) {
	for _, tc := range []struct {
		name string
		res  SendResult
	}{
		{"truncated", SendResult{HTTPStatus: 200, OutputTokens: 1}},
		{"clean", SendResult{HTTPStatus: 200, OutputTokens: 1, StreamTerminated: true}},
		{"in-band error", SendResult{HTTPStatus: 200, OutputTokens: 1, ErrorKind: "stream", StreamError: "server_error: engine aborted"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rows := Replay(context.Background(), terminationSender{res: tc.res}, evenTrace(2, 1), ReplayOptions{Arm: ArmShared})
			if len(rows) == 0 {
				t.Fatal("the replay produced no rows")
			}
			for i, r := range rows {
				if r.StreamTerminated != tc.res.StreamTerminated {
					t.Errorf("row %d carries StreamTerminated=%t and the sender reported %t; the copy into RawRow is missing",
						i, r.StreamTerminated, tc.res.StreamTerminated)
				}
				if r.StreamError != tc.res.StreamError {
					t.Errorf("row %d carries StreamError %q and the sender reported %q", i, r.StreamError, tc.res.StreamError)
				}
			}

			// And through the file, because the archive is what a later reader has.
			var buf bytes.Buffer
			if err := WriteRawRows(&buf, rows); err != nil {
				t.Fatalf("write: %v", err)
			}
			back, err := ReadRawRows(bytes.NewReader(buf.Bytes()))
			if err != nil {
				t.Fatalf("read: %v", err)
			}
			if len(back) != len(rows) {
				t.Fatalf("round-trip returned %d rows for %d written", len(back), len(rows))
			}
			for i := range back {
				if back[i].StreamTerminated != rows[i].StreamTerminated || back[i].StreamError != rows[i].StreamError {
					t.Errorf("row %d lost its termination facts in the file: terminated %t->%t, error %q->%q",
						i, rows[i].StreamTerminated, back[i].StreamTerminated, rows[i].StreamError, back[i].StreamError)
				}
			}
		})
	}
}

// A row written before these fields existed must not read as "truncated".
//
// `omitempty` means false is absent in the JSON, so every archive this project already holds comes back with
// StreamTerminated false -- the same value a genuinely truncated response produces. That ambiguity is real
// and is recorded on the field; what this pins is that reading such a row is not an error, so the existing
// evidence stays readable.
func TestEvidenceWrittenBeforeTheseFieldsStillReads(t *testing.T) {
	const old = `{"index":0,"arm":"shared","tenant":"premium-1","sendUnixNanos":1,"firstTokenUnixNanos":2,"endUnixNanos":3,"estInputTokens":10,"outputTokens":5,"httpStatus":200}`
	rows, err := ReadRawRows(strings.NewReader(old + "\n"))
	if err != nil {
		t.Fatalf("a row predating the termination fields was refused: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected one row, got %d", len(rows))
	}
	if rows[0].StreamTerminated {
		t.Error("an absent field read as true")
	}
	if rows[0].StreamError != "" {
		t.Errorf("an absent field read as %q", rows[0].StreamError)
	}
}

// terminationRows is a file of premium rows as the harness wrote them between 2026-10-04 and 2026-11-07: the key
// present only on rows whose stream ended, so `ended` decides which rows carry it.
func terminationRows(t *testing.T, ended []bool) []RawRow {
	t.Helper()
	var b strings.Builder
	for i, e := range ended {
		term := ""
		if e {
			term = `,"streamTerminated":true`
		}
		fmt.Fprintf(&b, `{"index":%d,"arm":"shared","tenant":"premium-1","sendUnixNanos":%d,"firstTokenUnixNanos":%d,"endUnixNanos":%d,"estInputTokens":10,"outputTokens":3,"httpStatus":200%s}`+"\n",
			i, int64(i+1)*1e9, int64(i+1)*1e9+int64(10+i)*1e6, int64(i+1)*1e9+int64(20+i)*1e6, term)
	}
	rows, err := ReadRawRows(strings.NewReader(b.String()))
	if err != nil {
		t.Fatal(err)
	}
	return rows
}

// In a file that recorded termination, a stream that did not end is a failure, never a completion in the tail.
//
// Mutations that turn this red: drop classifyTermination's reclassification, or infer the record per row
// instead of per file (an absent key then reads as unrecorded and the row stays a completion).
func TestTheReportCountsAStreamThatDidNotEndAsAFailure(t *testing.T) {
	rows := terminationRows(t, []bool{true, true, false, true})
	if !rows[2].TerminationRecorded || rows[2].StreamTerminated {
		t.Fatalf("the file recorded termination and row 2 did not end, but it reads recorded=%t ended=%t",
			rows[2].TerminationRecorded, rows[2].StreamTerminated)
	}
	s := Summarize("shared", rows)
	if s.Completed != 3 || s.Failed != 1 || s.TruncatedStreams != 1 || s.TailSampleSize != 3 {
		t.Errorf("completed %d, failed %d, truncated %d, tail %d; want 3, 1, 1, 3", s.Completed, s.Failed, s.TruncatedStreams, s.TailSampleSize)
	}
	if rows[2].ErrorKind != "" {
		t.Error("Summarize changed its caller's rows")
	}
	if !strings.Contains(FormatReport([]ArmSummary{s}, nil, 0), "1 stream(s) ended without [DONE] and count as failures") {
		t.Error("the report does not say that a stream ended without [DONE]")
	}
}

// A file that never recorded termination leaves its completions standing and says they rest on that silence.
//
// Mutation that turns this red: stop counting TerminationUnknown, or treat an unrecorded file as truncated.
func TestTheReportNamesCompletionsWhoseTerminationWasNeverRecorded(t *testing.T) {
	rows := terminationRows(t, []bool{false, false, false})
	s := Summarize("shared", rows)
	if s.Completed != 3 || s.TruncatedStreams != 0 || s.TerminationUnknown != 3 {
		t.Errorf("completed %d, truncated %d, unknown %d; want 3, 0, 3", s.Completed, s.TruncatedStreams, s.TerminationUnknown)
	}
	if !strings.Contains(FormatReport([]ArmSummary{s}, nil, 0), "3 completion(s) come from rows that never recorded") {
		t.Error("the report does not name the completions whose termination is unknown")
	}
}

// A truncation the sender itself names reaches the report's count, not only its failures (bare review of r7).
//
// Mutation that turns this red: drop the first branch of classifyTermination.
func TestATruncationTheSenderNamedIsCountedByTheReport(t *testing.T) {
	ok := readOneStream(t, streamChunk+streamChunk+"data: [DONE]\n\n")
	cut := readOneStream(t, streamChunk+streamChunk)
	rows := Replay(context.Background(), sequenceSender{results: []SendResult{ok, cut}}, evenTrace(2, 1), ReplayOptions{Arm: ArmShared})
	var buf bytes.Buffer
	if err := WriteRawRows(&buf, rows); err != nil {
		t.Fatal(err)
	}
	back, err := ReadRawRows(&buf)
	if err != nil {
		t.Fatal(err)
	}
	s := Summarize(ArmShared, back)
	if s.TruncatedStreams != 1 || s.Failed != 1 {
		t.Errorf("truncated %d, failed %d; want 1, 1", s.TruncatedStreams, s.Failed)
	}
	if !strings.Contains(FormatReport([]ArmSummary{s}, nil, 0), "1 stream(s) ended without [DONE]") {
		t.Error("the report does not name the truncation the sender recorded")
	}
}

// sequenceSender returns its results in order, stamped on the scheduler's clock.
type sequenceSender struct{ results []SendResult }

func (s sequenceSender) Send(_ context.Context, row TraceRow, sendUnixNanos int64) SendResult {
	out := s.results[row.Index%len(s.results)]
	out.FirstTokenUnixNanos = sendUnixNanos + 1
	out.EndUnixNanos = sendUnixNanos + 2
	// The recorded stream's own monotonic stamps belong to an earlier read, so they are dropped with the unix ones they no longer match.
	out.FirstContentAt, out.LastContentAt, out.EndAt, out.ContentAt = time.Time{}, time.Time{}, time.Time{}, nil
	return out
}
