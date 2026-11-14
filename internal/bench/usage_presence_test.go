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
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

const usageContent = "data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"b\"}}]}\n\n"

func sendBody(t *testing.T, body string) SendResult {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, body)
	}))
	defer srv.Close()
	s := NewHTTPSender(srv.URL, "m", nil, 5*time.Second, SenderConn{MaxIdleConnsPerHost: 2})
	return s.Send(context.Background(), TraceRow{Index: 0, PromptLenChars: 8, MaxOutputTokens: 2}, time.Now().UnixNano())
}

// Whether the engine reported usage is recorded apart from what it reported, so a missing count and a zero or negative one stay different facts.
// Audit finding 7: missing, zero and negative counts all collapsed into "no count", so a defect in the engine's accounting read as an instrument gap.
// Mutation that turns it red: set UsageReported only when completion_tokens is positive, or drop non-positive counts again.
func TestSenderRecordsUsagePresenceApartFromItsCount(t *testing.T) {
	absent := sendBody(t, usageContent+"data: [DONE]\n\n")
	if absent.UsageReported || absent.EngineOutputTokens != 0 {
		t.Fatalf("no usage chunk: reported %t, count %d", absent.UsageReported, absent.EngineOutputTokens)
	}
	zero := sendBody(t, usageContent+"data: {\"choices\":[],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":0}}\n\ndata: [DONE]\n\n")
	if !zero.UsageReported || zero.EngineOutputTokens != 0 {
		t.Fatalf("usage with zero tokens: reported %t, count %d", zero.UsageReported, zero.EngineOutputTokens)
	}
	negative := sendBody(t, usageContent+"data: {\"choices\":[],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":-3}}\n\ndata: [DONE]\n\n")
	if !negative.UsageReported || negative.EngineOutputTokens != -3 {
		t.Fatalf("usage with a negative count: reported %t, count %d", negative.UsageReported, negative.EngineOutputTokens)
	}
}

// The report counts delivered rows with no usage and rows whose usage contradicts their content, separately.
// Mutation that turns it red: stop tallying either bucket in tallyUsage.
func TestSummarizeSeparatesMissingFromInvalidUsage(t *testing.T) {
	reported, missing := true, false
	row := func(i, engine int, present *bool) RawRow {
		r := completedRow(i, 10, 10)
		r.Tenant = PremiumTenant
		r.StreamTerminated = true
		r.EngineOutputTokens = engine
		r.EngineUsageReported = present
		return r
	}
	rows := []RawRow{
		row(0, 8, &reported),
		row(1, 0, &missing),
		row(2, 0, &reported),
		row(3, -2, &reported),
		row(4, 0, nil),
	}
	s := Summarize("a", rows)
	if s.UsageReportedRows != 3 || s.UsageMissingRows != 1 || s.UsageInvalidRows != 2 || s.UsageNotRecordedRows != 1 {
		t.Fatalf("reported %d missing %d invalid %d not recorded %d; want 3, 1, 2, 1",
			s.UsageReportedRows, s.UsageMissingRows, s.UsageInvalidRows, s.UsageNotRecordedRows)
	}
}

// Replay carries the sender's presence onto the row, as a value on every sent row.
// Mutation that turns it red: leave EngineUsageReported nil in Replay.
func TestReplayRecordsUsagePresence(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, usageContent+"data: [DONE]\n\n")
	}))
	defer srv.Close()
	s := NewHTTPSender(srv.URL, "m", nil, 5*time.Second, SenderConn{MaxIdleConnsPerHost: 2})
	rows := Replay(context.Background(), s, []TraceRow{{Index: 0, PromptLenChars: 8, MaxOutputTokens: 2}}, ReplayOptions{})
	if rows[0].EngineUsageReported == nil || *rows[0].EngineUsageReported {
		t.Fatalf("a response without usage recorded presence %v", rows[0].EngineUsageReported)
	}
}
