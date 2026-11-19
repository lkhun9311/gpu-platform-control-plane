package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// serve writes the frames of one chat stream, sleeping before the first content frame so TTFT can be told apart
// from the time of the role-only first frame.
func serve(t *testing.T, frames []string, gapBeforeContent time.Duration) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		fl := w.(http.Flusher)
		for i, f := range frames {
			if i == 1 {
				time.Sleep(gapBeforeContent)
			}
			fmt.Fprintf(w, "data: %s\n\n", f)
			fl.Flush()
		}
	}))
}

var (
	roleOnly = `{"choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}`
	tok      = `{"choices":[{"index":0,"delta":{"content":"a "},"finish_reason":null}]}`
	finish   = `{"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}`
	usage    = `{"choices":[],"usage":{"prompt_tokens":9,"completion_tokens":3,"total_tokens":12}}`
)

func TestCompleteStream(t *testing.T) {
	srv := serve(t, []string{roleOnly, tok, tok, tok, finish, usage, "[DONE]"}, 50*time.Millisecond)
	defer srv.Close()
	rec := send(srv.Client(), srv.URL, "m", "id-1", "hi", arrival{maxTokens: 3}, 5*time.Second)
	if !rec.Done || rec.ContentChunks != 3 || rec.UsageCompletionTokens == nil || *rec.UsageCompletionTokens != 3 ||
		rec.FinishReason != "length" || rec.Chunks != 7 || rec.BadEvents != 0 {
		t.Fatalf("complete stream misread: %+v", rec)
	}
	// The role-only frame arrives before the gap, so a TTFT under the gap means the wrong frame was timed.
	if rec.TTFTMs < 50 {
		t.Fatalf("TTFT %.1f ms timed the role-only frame, not the first generated text", rec.TTFTMs)
	}
}

func TestTruncatedStreamIsNotDone(t *testing.T) {
	srv := serve(t, []string{roleOnly, tok, tok}, 0)
	defer srv.Close()
	rec := send(srv.Client(), srv.URL, "m", "id-2", "hi", arrival{maxTokens: 3}, 5*time.Second)
	if rec.Done || rec.UsageCompletionTokens != nil || rec.ContentChunks != 2 {
		t.Fatalf("truncated stream read as complete: %+v", rec)
	}
}

func TestErrorEventIsRecorded(t *testing.T) {
	srv := serve(t, []string{roleOnly, `{"error":{"message":"boom","code":500}}`, "[DONE]"}, 0)
	defer srv.Close()
	rec := send(srv.Client(), srv.URL, "m", "id-3", "hi", arrival{maxTokens: 3}, 5*time.Second)
	if rec.StreamError == "" || !rec.Done {
		t.Fatalf("error event not recorded: %+v", rec)
	}
}
