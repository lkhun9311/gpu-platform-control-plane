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

package main

import (
	"encoding/csv"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// The tests drive the built command through its flags and read its stdout and TSV, never its Go functions.
// That keeps them valid against any version of main.go.
// So the same test can show the old loadgen counting a cut stream as success.
func TestMain(m *testing.M) {
	if os.Getenv("LOADGEN_TEST_RUN_MAIN") == "1" {
		main()
		os.Exit(0)
	}
	os.Exit(m.Run())
}

const chunk = `data: {"choices":[{"delta":{"content":"hi"}}]}` + "\n\n"

// loadgen runs the command against url for two requests and returns its summary fields and TSV rows.
func loadgen(t *testing.T, url string, extra ...string) (map[string]int, []map[string]string) {
	t.Helper()
	out := filepath.Join(t.TempDir(), "rows.tsv")
	args := append([]string{"-url", url + "/v1/chat/completions", "-key", "k", "-model", "m",
		"-rate", "20", "-duration", "100ms", "-out", out}, extra...)
	cmd := exec.Command(os.Args[0], args...)
	cmd.Env = append(os.Environ(), "LOADGEN_TEST_RUN_MAIN=1")
	stdout, err := cmd.Output()
	if err != nil {
		t.Fatalf("loadgen %v: %v, stdout %q", args, err, stdout)
	}
	summary := map[string]int{}
	for f := range strings.FieldsSeq(string(stdout)) {
		k, v, ok := strings.Cut(f, "=")
		if !ok {
			continue
		}
		n, err := strconv.Atoi(v)
		if err != nil {
			t.Fatalf("summary field %q is not a count", f)
		}
		summary[k] = n
	}
	f, err := os.Open(out)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = f.Close() }()
	r := csv.NewReader(f)
	r.Comma = '\t'
	r.FieldsPerRecord = -1
	recs, err := r.ReadAll()
	if err != nil {
		t.Fatal(err)
	}
	var rows []map[string]string
	for _, rec := range recs[1:] {
		m := map[string]string{}
		for i, h := range recs[0] {
			if i < len(rec) {
				m[h] = rec[i]
			}
		}
		rows = append(rows, m)
	}
	if summary["sent"] != 2 || len(rows) != 2 {
		t.Fatalf("want 2 requests sent and 2 rows, got summary %v and %d rows", summary, len(rows))
	}
	return summary, rows
}

func sse(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(chunk))
	w.(http.Flusher).Flush()
}

// A 200 whose connection drops mid-stream was admitted and proxied, but nothing was served to the end.
// The old loadgen discarded the body's read error and counted it as ok.
func TestCutStreamAfter200IsNotSuccess(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		sse(w)
		conn, _, err := w.(http.Hijacker).Hijack()
		if err != nil {
			t.Error(err)
			return
		}
		// Closing the socket without the chunked terminator is a stream cut, as a killed gateway Pod produces.
		_ = conn.Close()
	}))
	defer srv.Close()

	summary, rows := loadgen(t, srv.URL)
	if summary["ok"] != 0 {
		t.Errorf("ok=%d for two streams cut after 200, want 0", summary["ok"])
	}
	if summary["status200"] != 2 || summary["stream_cut"] != 2 {
		t.Errorf("want status200=2 stream_cut=2, got %v", summary)
	}
	for _, r := range rows {
		if r["status"] != "200" || r["outcome"] != "stream_cut" || r["done"] != "0" {
			t.Errorf("row %v: want status 200, outcome stream_cut, done 0", r)
		}
	}
}

// A stream that ends cleanly but without data: [DONE] stopped arriving; it did not finish.
func TestStreamWithoutDoneIsNotSuccess(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { sse(w) }))
	defer srv.Close()

	summary, rows := loadgen(t, srv.URL)
	if summary["ok"] != 0 || summary["stream_cut"] != 2 {
		t.Errorf("want ok=0 stream_cut=2, got %v", summary)
	}
	for _, r := range rows {
		if r["outcome"] != "stream_cut" {
			t.Errorf("row %v: want outcome stream_cut", r)
		}
	}
}

// The control: a complete stream is a success, so the two tests above cannot pass by counting nothing.
func TestCompleteStreamIsSuccess(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		sse(w)
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer srv.Close()

	summary, rows := loadgen(t, srv.URL)
	if summary["ok"] != 2 || summary["other"] != 0 {
		t.Errorf("want ok=2 other=0, got %v", summary)
	}
	for _, r := range rows {
		if r["outcome"] != "completed" || r["done"] != "1" || r["ttft_ms"] == "-1.000" {
			t.Errorf("row %v: want outcome completed, done 1 and a first-token time", r)
		}
	}
}

// 429 and 5xx stay apart, because one is the limiter working and the other is the limiter or backend failing.
func TestRefusalsAreCountedByStatus(t *testing.T) {
	var n atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if n.Add(1) == 1 {
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer srv.Close()

	summary, _ := loadgen(t, srv.URL)
	if summary["ok"] != 0 || summary["limited"] != 1 || summary["http5xx"] != 1 {
		t.Errorf("want ok=0 limited=1 http5xx=1, got %v", summary)
	}
}

// A deadline that expires after the 200 keeps both facts: the status was 200 and the outcome is a timeout.
func TestTimeoutAfter200KeepsTheStatus(t *testing.T) {
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		sse(w)
		<-release
	}))
	defer srv.Close()
	defer close(release)

	summary, rows := loadgen(t, srv.URL, "-timeout", (300 * time.Millisecond).String())
	if summary["ok"] != 0 || summary["timeout"] != 2 {
		t.Errorf("want ok=0 timeout=2, got %v", summary)
	}
	for _, r := range rows {
		if r["status"] != "200" || r["outcome"] != "timeout" {
			t.Errorf("row %v: want status 200 and outcome timeout", r)
		}
	}
}
