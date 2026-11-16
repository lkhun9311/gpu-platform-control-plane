package bench

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
)

// readinessFake is a Docker that starts no container and an engine whose behaviour each start chooses.
type readinessFake struct {
	mu      sync.Mutex
	calls   [][]string
	running map[string]bool
	starts  int
	// healthyAt is when the current start's /health first answers 200.
	healthyAt time.Time
	// failClass makes the current start answer this (input, output) class with HTTP 500.
	failClass [2]int
	// noServerInfo makes the current start answer /server_info with 404, as an engine without dev mode would.
	noServerInfo bool
	// tokenizeBodies are the /tokenize bodies the engine received, in order.
	tokenizeBodies [][]byte
	// onStart chooses the behaviour of start number n, counted from 1 over the whole run.
	onStart func(n int, f *readinessFake)
	// downloadErr fails the model download as a deadline would, leaving its container behind until it is removed.
	downloadErr error
	removed     []string
	// pullErr fails the first pull after it printed some layers, as a pull cut by its bound does.
	pullErr error
}

func (f *readinessFake) run(_ context.Context, name string, args ...string) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, append([]string{name}, args...))
	switch {
	case args[0] == "image" && args[1] == "inspect":
		return nil, errors.New("Error: No such image: " + args[len(args)-1])
	case args[0] == "pull":
		if f.pullErr != nil {
			return []byte("a1b2: Pull complete\nc3d4: Downloading\n"), f.pullErr
		}
		return []byte("pulled\n"), nil
	case args[0] == "run" && args[1] == "--rm":
		if f.downloadErr != nil {
			f.running[strings.TrimPrefix(args[2], "--name=")] = true
			return nil, f.downloadErr
		}
		return []byte("/root/.cache/huggingface/hub/snapshot\n"), nil
	case args[0] == "run":
		f.starts++
		id := fmt.Sprintf("cid-%d", f.starts)
		f.running[id] = true
		f.healthyAt, f.failClass, f.noServerInfo = time.Now().Add(20*time.Millisecond), [2]int{}, false
		if f.onStart != nil {
			f.onStart(f.starts, f)
		}
		return []byte(id + "\n"), nil
	case args[0] == "inspect":
		id := args[len(args)-1]
		if f.running[id] {
			return []byte("running\n"), nil
		}
		return nil, errors.New("Error: No such object: " + id)
	case args[0] == "rm":
		delete(f.running, args[len(args)-1])
		f.removed = append(f.removed, args[len(args)-1])
		return nil, nil
	}
	return nil, fmt.Errorf("unexpected docker %v", args)
}

// identityAnswers are the fake engine's identity endpoints, with bodies a parser would trip on, so only a raw copy matches.
var identityAnswers = map[string]string{
	"/version":     `{"version": "0.0.0-fake"}` + "\n",
	"/v1/models":   `{"object":"list","data":[{"id":"Qwen/Qwen2.5-3B-Instruct"}]}`,
	"/server_info": `{"vllm_config":  {"model_config": {"dtype": "half"}}, "unseen key": [1, 2]}`,
	"/metrics":     "# HELP vllm:num_requests_running x\nvllm:num_requests_running 0\n",
	"/tokenize":    `{"count":3,"tokens":[1,2,3],"max_model_len":16384}`,
}

// engine serves /health and conforming streams, as the fake's current start chooses.
func (f *readinessFake) engine(t *testing.T) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		f.mu.Lock()
		ok := !time.Now().Before(f.healthyAt)
		f.mu.Unlock()
		if !ok {
			w.WriteHeader(http.StatusServiceUnavailable)
		}
	})
	for path, body := range identityAnswers {
		mux.HandleFunc(path, func(w http.ResponseWriter, r *http.Request) {
			f.mu.Lock()
			missing := f.noServerInfo && r.URL.Path == "/server_info"
			if r.URL.Path == "/tokenize" {
				b, _ := io.ReadAll(r.Body)
				f.tokenizeBodies = append(f.tokenizeBodies, b)
			}
			f.mu.Unlock()
			if missing {
				http.NotFound(w, r)
				return
			}
			if r.URL.Path == "/server_info" && r.URL.Query().Get("config_format") != "json" {
				http.Error(w, "wrong query", http.StatusBadRequest)
				return
			}
			_, _ = io.WriteString(w, body)
		})
	}
	mux.HandleFunc("/v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			MaxTokens int `json:"max_tokens"`
			Messages  []struct {
				Content string `json:"content"`
			} `json:"messages"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		prompt := versionStudyExactTokens()[len(body.Messages[0].Content)]
		f.mu.Lock()
		fail := f.failClass == [2]int{prompt, body.MaxTokens}
		f.mu.Unlock()
		if fail {
			http.Error(w, "engine error", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, `data: {"choices":[{"delta":{"content":"a"}}]}`+"\n\n")
		_, _ = io.WriteString(w, `data: {"choices":[{"delta":{"content":"b"},"finish_reason":"length"}]}`+"\n\n")
		_, _ = fmt.Fprintf(w, "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":%d,\"completion_tokens\":%d}}\n\n", prompt, body.MaxTokens)
		_, _ = io.WriteString(w, "data: [DONE]\n\n")
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

// readinessRun is a run against the fake with the registered design and a readiness bound of boundSeconds.
func readinessRun(t *testing.T, f *readinessFake, boundSeconds int) *ReadinessRun {
	t.Helper()
	f.running = map[string]bool{}
	srv := f.engine(t)
	root := t.TempDir()
	out := filepath.Join(root, "out")
	if err := os.Mkdir(out, 0o700); err != nil {
		t.Fatal(err)
	}
	d := versionAsyncDesign()
	d.Bounds.ReadinessSeconds = boundSeconds
	return &ReadinessRun{
		Study:  StudyVersionAsync,
		Design: d,
		Engine: &DockerEngine{
			Run: f.run, HFCache: filepath.Join(root, "hf"), CompileCacheRoot: filepath.Join(root, "compile"),
			ServedName: d.Model, Port: 8000, NamePrefix: "readiness",
		},
		EngineURL: srv.URL,
		Sampling:  *versionStudySampling(),
		NewSender: func() (Sender, error) {
			s := NewHTTPSender(srv.URL, d.Model, nil, 5*time.Second, SenderConn{})
			return s, s.SetSampling(versionStudySampling())
		},
		Health: &http.Client{Timeout: time.Second},
		Logs: func(context.Context, string) ([]byte, error) {
			return []byte("INFO engine log\n"), nil
		},
		Out:        out,
		PollEvery:  5 * time.Millisecond,
		StateEvery: 50 * time.Millisecond,
	}
}

// readStart reads one start record the run wrote.
func readStart(t *testing.T, out, treatment string, n int) ReadinessStart {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(out, fmt.Sprintf("start-%s-%d.json", treatment, n)))
	if err != nil {
		t.Fatal(err)
	}
	var s ReadinessStart
	if err := json.Unmarshal(data, &s); err != nil {
		t.Fatal(err)
	}
	return s
}

// TestReadinessTimingsAreOrderedAndEveryStartIsTheStudysContainer: on an engine that becomes ready, every start's
// stamps run container, health, each priming answer, ready, inside the bound; pulls and the download come first and
// apart; and every container is removed before the next starts.
func TestReadinessTimingsAreOrderedAndEveryStartIsTheStudysContainer(t *testing.T) {
	f := &readinessFake{}
	r := readinessRun(t, f, 5)
	sum, err := r.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !sum.AllReady || len(sum.Pulls) != 2 || sum.Pulls[0].Image == sum.Pulls[1].Image || sum.ModelDownload.Step != "model-download" {
		t.Fatalf("summary %+v: want every start ready, two distinct pulls and the download", sum)
	}
	classes, _ := r.Design.PrimingRows()
	warmed := map[string][][]string{
		TreatmentA: {{}, {"A"}, {"A"}},
		TreatmentB: {{}, {"B"}, {"B"}},
		TreatmentC: {{"B"}, {"B", "C"}, {"B", "C"}},
	}
	for _, tr := range []string{TreatmentA, TreatmentB, TreatmentC} {
		for n := 1; n <= 3; n++ {
			s := readStart(t, r.Out, tr, n)
			if s.Outcome != ReadinessReady || s.ContainerStartedSeconds == nil || s.HealthSeconds == nil || s.ReadySeconds == nil {
				t.Fatalf("%s #%d: %+v, want a ready start with every stamp", tr, n, s)
			}
			if !slices.Equal(s.CompileCacheWarmedBy, warmed[tr][n-1]) {
				t.Errorf("%s #%d compile cache warmed by %v, want %v", tr, n, s.CompileCacheWarmedBy, warmed[tr][n-1])
			}
			want, _ := r.Engine.RunArgs(r.Design, tr, fmt.Sprintf("ready-%s-%d", tr, n))
			if got := slices.DeleteFunc(slices.Clone(s.RunArgs), func(a string) bool { return strings.HasPrefix(a, "--label="+attemptLabel) }); !slices.Equal(got, want) {
				t.Errorf("%s #%d ran %v, want the study's %v", tr, n, got, want)
			}
			stamps := []float64{0, *s.ContainerStartedSeconds, *s.HealthSeconds}
			if len(s.Priming) != len(classes) {
				t.Fatalf("%s #%d sent %d priming requests, want one per class (%d)", tr, n, len(s.Priming), len(classes))
			}
			for i, p := range s.Priming {
				if p.InputTokens != versionStudyExactTokens()[classes[i].PromptLenChars] || p.OutputTokens != classes[i].MaxOutputTokens || p.Disposition != string(DispositionSuccess) {
					t.Errorf("%s #%d priming %d: %+v", tr, n, i, p)
				}
				stamps = append(stamps, p.AnsweredSeconds)
			}
			stamps = append(stamps, *s.ReadySeconds, float64(s.BoundSeconds))
			if !slices.IsSorted(stamps) {
				t.Errorf("%s #%d stamps out of order: %v", tr, n, stamps)
			}
			if log, err := os.ReadFile(filepath.Join(r.Out, s.LogFile)); err != nil || string(log) != "INFO engine log\n" {
				t.Errorf("%s #%d engine log %q (%v), want the container's log kept whole", tr, n, log, err)
			}
			checkCapture(t, r.Out, s)
		}
	}
	if len(f.tokenizeBodies) != 9 {
		t.Fatalf("/tokenize was called %d times, want once per start", len(f.tokenizeBodies))
	}
	var tok map[string]any
	if err := json.Unmarshal(f.tokenizeBodies[0], &tok); err != nil {
		t.Fatal(err)
	}
	if tok["add_generation_prompt"] != true || tok["add_special_tokens"] != false || tok["model"] != r.Design.Model {
		t.Fatalf("/tokenize body %s, want a chat body with the generation prompt and no special tokens", f.tokenizeBodies[0])
	}
	for _, b := range f.tokenizeBodies[1:] {
		if string(b) != string(f.tokenizeBodies[0]) {
			t.Fatalf("/tokenize bodies differ between starts: %s and %s", f.tokenizeBodies[0], b)
		}
	}
	// Pulls and the download precede every start, and each container is removed before the next is run.
	var lastPull, firstRun int
	open := ""
	for i, c := range f.calls {
		switch {
		case c[1] == "pull" || (c[1] == "run" && c[2] == "--rm"):
			lastPull = i
		case c[1] == "run":
			if firstRun == 0 {
				firstRun = i
			}
			if open != "" {
				t.Fatalf("call %d starts a container while %s is still running", i, open)
			}
			open = "running"
		case c[1] == "rm":
			open = ""
		}
	}
	if lastPull > firstRun {
		t.Fatalf("a pull or the download (call %d) came after the first start (call %d)", lastPull, firstRun)
	}
}

// checkCapture holds a ready start's identity files to the bytes the engine sent and the body it was sent.
func checkCapture(t *testing.T, out string, s ReadinessStart) {
	t.Helper()
	want := map[string]string{
		"version": "/version", "models": "/v1/models", "server-info": "/server_info?config_format=json",
		"metrics": "/metrics", "tokenize": "/tokenize",
	}
	if len(s.Capture) != len(want) {
		t.Fatalf("%s #%d captured %d endpoints, want %d: %+v", s.Treatment, s.Ordinal, len(s.Capture), len(want), s.Capture)
	}
	for _, c := range s.Capture {
		if want[c.Name] != c.Path || c.Status != http.StatusOK || c.Error != "" {
			t.Errorf("%s #%d capture %+v", s.Treatment, s.Ordinal, c)
			continue
		}
		got, err := os.ReadFile(filepath.Join(out, c.File))
		path, _, _ := strings.Cut(c.Path, "?")
		if err != nil || string(got) != identityAnswers[path] {
			t.Errorf("%s #%d %s saved %q (%v), want the raw answer %q", s.Treatment, s.Ordinal, c.Name, got, err, identityAnswers[path])
		}
		if c.Name == "tokenize" {
			body, err := os.ReadFile(filepath.Join(out, c.RequestFile))
			if err != nil || !strings.Contains(string(body), `"add_generation_prompt":true`) || !strings.Contains(string(body), `"messages"`) {
				t.Errorf("%s #%d tokenize request file %q (%v), want the chat body sent", s.Treatment, s.Ordinal, body, err)
			}
		}
	}
}

// TestReadinessACaptureFailureIsRecordedAndReadinessStands: identity capture is secondary, so an endpoint that fails
// is recorded on that start, and neither its readiness nor the rest of the run is touched.
func TestReadinessACaptureFailureIsRecordedAndReadinessStands(t *testing.T) {
	f := &readinessFake{onStart: func(n int, f *readinessFake) {
		if n == 2 {
			f.noServerInfo = true
		}
	}}
	r := readinessRun(t, f, 5)
	sum, err := r.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	s := readStart(t, r.Out, TreatmentA, 2)
	if s.Outcome != ReadinessReady || len(s.Capture) != 5 {
		t.Fatalf("A #2: %+v, want ready with every endpoint attempted", s)
	}
	for _, c := range s.Capture {
		if (c.Name == "server-info") != (c.Error != "") {
			t.Errorf("A #2 capture %+v: only server-info should carry an error", c)
		}
		if c.Name == "server-info" && c.Status != http.StatusNotFound {
			t.Errorf("A #2 server-info status %d, want the 404 recorded", c.Status)
		}
	}
	if !sum.AllReady || f.starts != 9 {
		t.Fatalf("all ready %v after %d starts: a capture failure must not touch readiness or stop the run", sum.AllReady, f.starts)
	}
}

// TestReadinessRecordsAMissedDeadlineAndGoesOn: a start whose /health comes after the bound is missed, the run
// continues to the other starts, and the summary gives no warm maximum it cannot support.
func TestReadinessRecordsAMissedDeadlineAndGoesOn(t *testing.T) {
	f := &readinessFake{onStart: func(n int, f *readinessFake) {
		if n == 2 {
			f.healthyAt = time.Now().Add(time.Hour)
		}
	}}
	r := readinessRun(t, f, 1)
	sum, err := r.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	s := readStart(t, r.Out, TreatmentA, 2)
	if s.Outcome != ReadinessMissed || s.HealthSeconds != nil || s.ReadySeconds != nil {
		t.Fatalf("A #2: %+v, want missed with no health or ready stamp", s)
	}
	if len(s.Capture) != 0 || s.CaptureSkipped == "" {
		t.Fatalf("A #2 captured %+v from an engine that was not ready", s.Capture)
	}
	if got := readStart(t, r.Out, TreatmentC, 3); got.Outcome != ReadinessReady {
		t.Fatalf("the run did not go on after the miss: C #3 is %+v", got)
	}
	a := sum.Treatments[0]
	if sum.AllReady || a.Missed != 1 || a.WarmReady != 1 || a.WarmMaxSeconds != nil || a.WarmMedianSeconds != nil {
		t.Fatalf("summary of A %+v (all ready %v): want one miss and no warm figures", a, sum.AllReady)
	}
}

// TestReadinessAFailedPrimingRequestIsNotReady: /health alone is not readiness; one class answered with an error makes the start failed.
func TestReadinessAFailedPrimingRequestIsNotReady(t *testing.T) {
	f := &readinessFake{onStart: func(n int, f *readinessFake) {
		if n == 4 {
			f.failClass = [2]int{2048, 256}
		}
	}}
	r := readinessRun(t, f, 5)
	sum, err := r.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	s := readStart(t, r.Out, TreatmentB, 1)
	if s.Outcome != ReadinessFailed || s.HealthSeconds == nil || s.ReadySeconds != nil {
		t.Fatalf("B #1: %+v, want failed after health with no ready stamp", s)
	}
	if last := s.Priming[len(s.Priming)-1]; last.Error == "" || last.InputTokens != 2048 || last.OutputTokens != 256 {
		t.Fatalf("B #1's last priming record %+v, want the (2048, 256) failure", last)
	}
	b := sum.Treatments[1]
	if sum.AllReady || b.FirstSeconds != nil || b.FirstOutcome != ReadinessFailed || b.Failed != 1 {
		t.Fatalf("summary of B %+v: want a failed first start with no figure", b)
	}
}

// TestReadinessAWriteFailureEndsTheRunAndStillRemovesTheContainer: a record that cannot be kept is an error, never a skip.
func TestReadinessAWriteFailureEndsTheRunAndStillRemovesTheContainer(t *testing.T) {
	var r *ReadinessRun
	f := &readinessFake{onStart: func(n int, f *readinessFake) {
		if n == 1 {
			// The record's name is taken while the start runs, so writing it must fail.
			_ = os.WriteFile(filepath.Join(r.Out, "start-A-1.json"), []byte("{}"), 0o600)
		}
	}}
	r = readinessRun(t, f, 5)
	if _, err := r.Run(context.Background()); err == nil || !strings.Contains(err.Error(), "start-A-1.json") {
		t.Fatalf("err %v, want the failed write of start-A-1.json", err)
	}
	if f.starts != 1 || len(f.running) != 0 {
		t.Fatalf("%d start(s), %d container(s) left running; want the run to stop after the first, with it removed", f.starts, len(f.running))
	}
	if _, err := os.Stat(filepath.Join(r.Out, "summary.json")); !os.IsNotExist(err) {
		t.Fatalf("a summary was written after a lost record: %v", err)
	}
}

// TestReadinessKeepsTheOutputOfAPullItsBoundCut: a pull that ran out of time must show how far it got.
func TestReadinessKeepsTheOutputOfAPullItsBoundCut(t *testing.T) {
	f := &readinessFake{pullErr: errors.New("signal: killed")}
	r := readinessRun(t, f, 5)
	if _, err := r.Run(context.Background()); err == nil || !strings.Contains(err.Error(), "pull") {
		t.Fatalf("err %v, want the failed pull", err)
	}
	data, err := os.ReadFile(filepath.Join(r.Out, "pull-1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var rec StepRecord
	if err := json.Unmarshal(data, &rec); err != nil || rec.Error == "" || !strings.Contains(rec.Output, "a1b2: Pull complete") {
		t.Fatalf("pull record %+v err %v, want the error and the layers it reached", rec, err)
	}
}

// TestReadinessRemovesAModelDownloadItsDeadlineCut: the deadline kills the docker CLI, and the container must not go on downloading.
func TestReadinessRemovesAModelDownloadItsDeadlineCut(t *testing.T) {
	f := &readinessFake{downloadErr: context.DeadlineExceeded}
	r := readinessRun(t, f, 5)
	if _, err := r.Run(context.Background()); err == nil || !strings.Contains(err.Error(), "model-download") {
		t.Fatalf("err %v, want the failed download", err)
	}
	if len(f.running) != 0 || len(f.removed) != 1 || !strings.HasPrefix(f.removed[0], "readiness-model-download-") || f.starts != 0 {
		t.Fatalf("running %v, removed %v after %d start(s); want the download container removed and no engine started", f.running, f.removed, f.starts)
	}
}

// TestReadinessRefusesAWarmCompileCache: a cache filled before the run would make every first start look cold when it is not.
func TestReadinessRefusesAWarmCompileCache(t *testing.T) {
	f := &readinessFake{}
	r := readinessRun(t, f, 5)
	if err := os.MkdirAll(filepath.Join(r.Engine.CompileCacheRoot, "leftover"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Run(context.Background()); err == nil || !strings.Contains(err.Error(), "compile cache") {
		t.Fatalf("err %v, want a refusal of the filled compile cache", err)
	}
	if len(f.calls) != 0 {
		t.Fatalf("docker was called %d time(s) before the refusal", len(f.calls))
	}
}

// TestSummarizeReadinessMedianOfTwoIsTheirMean pins the definition SummarizeReadiness documents.
func TestSummarizeReadinessMedianOfTwoIsTheirMean(t *testing.T) {
	v := func(x float64) *float64 { return &x }
	got := SummarizeReadiness("A", []ReadinessStart{
		{Outcome: ReadinessReady, ReadySeconds: v(300)},
		{Outcome: ReadinessReady, ReadySeconds: v(100)},
		{Outcome: ReadinessReady, ReadySeconds: v(140)},
	})
	if *got.FirstSeconds != 300 || *got.WarmMaxSeconds != 140 || *got.WarmMedianSeconds != 120 {
		t.Fatalf("first %v max %v median %v, want 300, 140, 120", *got.FirstSeconds, *got.WarmMaxSeconds, *got.WarmMedianSeconds)
	}
}
