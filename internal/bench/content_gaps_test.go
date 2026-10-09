package bench

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// The replay keeps each inter-token gap the client saw, when it records timing, so a single long gap among short ones
// is visible: three frames 20 ms and then 120 ms apart give gaps near 20 and 120 ms, not one average of 70.
// Mutation that turns it red: stop appending content times in the sender, or average the gaps.
func TestReplayRecordsEachContentGap(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		for i, pause := range []time.Duration{0, 20 * time.Millisecond, 120 * time.Millisecond} {
			time.Sleep(pause)
			_, _ = fmt.Fprintf(w, "data: {\"choices\":[{\"delta\":{\"content\":\"t%d\"}}]}\n\n", i)
			w.(http.Flusher).Flush()
		}
		_, _ = fmt.Fprint(w, "data: [DONE]\n\n")
	}))
	defer srv.Close()
	s := NewHTTPSender(srv.URL, "m", nil, 5*time.Second, SenderConn{MaxIdleConnsPerHost: 2})
	s.SetRecordContentTimes(true)
	trace := []TraceRow{{Index: 0, OffsetMs: 0, Tenant: PremiumTenant, PromptLenChars: 8, MaxOutputTokens: 3}}
	rows := Replay(context.Background(), s, trace, ReplayOptions{RecordTiming: true})
	if len(rows) != 1 || len(rows[0].ContentGapsMicros) != 2 {
		t.Fatalf("want two gaps, got %+v", rows)
	}
	g := rows[0].ContentGapsMicros
	if g[0] < 15_000 || g[0] > 60_000 || g[1] < 110_000 || g[1] > 200_000 {
		t.Fatalf("gaps %v us, want about 20,000 then 120,000", g)
	}
	// Without timing, nothing is kept, so other studies' raw files do not grow.
	rows = Replay(context.Background(), s, trace, ReplayOptions{})
	if rows[0].ContentGapsMicros != nil {
		t.Fatalf("gaps were kept without RecordTiming: %v", rows[0].ContentGapsMicros)
	}
}
