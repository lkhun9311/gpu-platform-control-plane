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
	// And the fields that CANNOT tell them apart are asserted equal, so this test says what the new field
	// is for rather than merely that it exists. If a later change made ErrorKind differ here, the comment
	// above would be stale and this would say so.
	if clean.ErrorKind != cut.ErrorKind {
		t.Errorf("ErrorKind now differs (%q vs %q); the truncation is detectable without StreamTerminated and this test's premise has changed",
			clean.ErrorKind, cut.ErrorKind)
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
