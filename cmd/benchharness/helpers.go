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
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"maps"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"sigs.k8s.io/yaml"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// multiFlag collects a repeated string flag into a slice.
type multiFlag []string

func (m *multiFlag) String() string { return strings.Join(*m, ",") }
func (m *multiFlag) Set(v string) error {
	*m = append(*m, v)
	return nil
}

// writeManifest serializes a manifest as YAML.
func writeManifest(path string, m bench.RunManifest) error {
	data, err := yaml.Marshal(&m)
	if err != nil {
		return fmt.Errorf("marshal manifest: %w", err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return fmt.Errorf("write manifest %s: %w", path, err)
	}
	return nil
}

// readTraceFile loads a trace file produced by gen-trace.
func readTraceFile(path string) ([]bench.TraceRow, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open trace %s: %w", path, err)
	}
	defer func() { _ = f.Close() }()
	return bench.ReadTrace(f)
}

// parseAPIKeys turns "tenant=key,tenant2=key2" into a map.
func parseAPIKeys(s string) map[string]string {
	out := map[string]string{}
	for pair := range strings.SplitSeq(s, ",") {
		pair = strings.TrimSpace(pair)
		if pair == "" {
			continue
		}
		k, v, ok := strings.Cut(pair, "=")
		if ok {
			out[strings.TrimSpace(k)] = strings.TrimSpace(v)
		}
	}
	return out
}

// parsePriorities turns "tenant=0,tenant2=5" into the per-tenant scheduling priority map.
//
// Unlike parseAPIKeys it refuses malformed input instead of skipping it. A dropped API key fails loudly on
// the first request; a dropped priority does not fail at all -- the run completes, the rows look healthy,
// and the arm that was supposed to carry the treatment silently replays the control. An arm whose whole
// hypothesis is the priority field must not be able to lose it quietly.
func parsePriorities(s string) (map[string]int, error) {
	out := map[string]int{}
	for pair := range strings.SplitSeq(s, ",") {
		pair = strings.TrimSpace(pair)
		if pair == "" {
			continue
		}
		k, v, ok := strings.Cut(pair, "=")
		if !ok {
			return nil, fmt.Errorf("priority %q is not tenant=int", pair)
		}
		n, err := strconv.Atoi(strings.TrimSpace(v))
		if err != nil {
			return nil, fmt.Errorf("priority for tenant %q: %q is not an integer", strings.TrimSpace(k), strings.TrimSpace(v))
		}
		out[strings.TrimSpace(k)] = n
	}
	return out, nil
}

// stubConnIDKey carries a per-connection identifier on every request context the stub server handles.
//
// It is a private struct type rather than a string so nothing else can collide with it in the context.
type stubConnIDKey struct{}

// stubStats records what the stub actually observed on its own side of the wire.
//
// The gateway's connection-reuse fix cannot be checked from the gateway: a process cannot honestly report
// that its own connection pool worked, because both the shared-Transport and the per-request-Transport
// versions issue exactly the same number of outbound requests.
//
// What distinguishes them is only visible to whoever accepts the connections, so the backend counts them:
// a shared Transport shows many requests riding few connections, and a Transport rebuilt per request shows
// one connection per request.
type stubStats struct {
	// nextConnID hands out connection identifiers from ConnContext, which runs before any handler and so
	// cannot take the mutex below without ordering itself against request handling.
	nextConnID atomic.Int64

	// mu guards every field below, which are all read together by the /stats snapshot.
	mu sync.Mutex
	// chatConns holds one entry per connection that has carried at least one chat request in this window,
	// with the number of requests it carried.
	//
	// Probe and /stats connections are deliberately excluded: the kubelet opens a fresh connection for every
	// readiness and liveness probe, and counting those would inflate exactly the number under test.
	chatConns map[int64]int
	// requestsServed counts chat requests only, for the same reason.
	requestsServed int64
	// inFlight and peakInFlight track concurrent chat requests, which is what the gateway's outbound
	// per-host connection cap actually has to cover.
	inFlight     int64
	peakInFlight int64
	// accepted, open and peakOpen cover every connection the listener saw, probes included, so the two
	// counts can be compared and probe traffic accounted for rather than assumed away.
	accepted int64
	open     int64
	peakOpen int64
	// byPriority counts chat requests by the priority their body carried, "none" when it carried none, so a
	// rehearsal can see what a gateway that binds priority actually forwarded.
	byPriority map[string]int64
}

// newStubStats returns stats with the connection map ready, since inserting into a nil map panics.
func newStubStats() *stubStats {
	return &stubStats{chatConns: make(map[int64]int), byPriority: make(map[string]int64)}
}

// connContext stamps a fresh identifier on each accepted connection's base context.
//
// This is the only hook that sees both the connection and something the handler can read back, which is
// what lets a request be attributed to the connection that carried it.
func (s *stubStats) connContext(ctx context.Context, _ net.Conn) context.Context {
	return context.WithValue(ctx, stubConnIDKey{}, s.nextConnID.Add(1))
}

// connState maintains the accepted and currently-open connection counts.
//
// StateHijacked is treated as closed because the server hands the connection off and will never report it
// closed again, so omitting it would leak the open count upward forever.
func (s *stubStats) connState(_ net.Conn, state http.ConnState) {
	s.mu.Lock()
	defer s.mu.Unlock()
	switch state {
	case http.StateNew:
		s.accepted++
		s.open++
		s.peakOpen = max(s.peakOpen, s.open)
	case http.StateClosed, http.StateHijacked:
		s.open--
	}
}

// begin records the start of one chat request and attributes it to its connection.
func (s *stubStats) begin(ctx context.Context) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.requestsServed++
	s.inFlight++
	s.peakInFlight = max(s.peakInFlight, s.inFlight)
	if id, ok := ctx.Value(stubConnIDKey{}).(int64); ok {
		s.chatConns[id]++
	}
}

// notePriority counts one chat request under the priority its body carried.
func (s *stubStats) notePriority(p string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.byPriority[p]++
}

// end records the completion of one chat request.
func (s *stubStats) end() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.inFlight--
}

// stubStatsSnapshot is the JSON /stats serves, and the shape the evidence script reads its numbers from.
type stubStatsSnapshot struct {
	RequestsServed             int64 `json:"requestsServed"`
	ChatConnections            int   `json:"chatConnections"`
	MaxRequestsOnOneConnection int   `json:"maxRequestsOnOneConnection"`
	InFlight                   int64 `json:"inFlight"`
	PeakInFlight               int64 `json:"peakInFlight"`
	ConnectionsAccepted        int64 `json:"connectionsAccepted"`
	OpenConnections            int64 `json:"openConnections"`
	PeakOpenConnections        int64 `json:"peakOpenConnections"`
	// RequestsByPriority is the window's chat requests by forwarded priority; "none" is a body without one.
	RequestsByPriority map[string]int64 `json:"requestsByPriority"`
}

// snapshot returns the current counters.
func (s *stubStats) snapshot() stubStatsSnapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	snap := stubStatsSnapshot{
		RequestsServed:      s.requestsServed,
		ChatConnections:     len(s.chatConns),
		InFlight:            s.inFlight,
		PeakInFlight:        s.peakInFlight,
		ConnectionsAccepted: s.accepted,
		OpenConnections:     s.open,
		PeakOpenConnections: s.peakOpen,
	}
	for _, n := range s.chatConns {
		snap.MaxRequestsOnOneConnection = max(snap.MaxRequestsOnOneConnection, n)
	}
	snap.RequestsByPriority = maps.Clone(s.byPriority)
	return snap
}

// reset starts a new measurement window so one long-lived stub can serve several load runs.
//
// The counts that describe a window (requests, connections that carried them, peaks) go to zero, while the
// counts that describe the present (in-flight requests, open connections) are carried over, because zeroing
// those would make a still-open connection close into a negative number.
//
// Clearing chatConns means a connection that is already open when a window starts is counted again the
// first time it carries a request in the new window, which is the honest reading: it is a connection
// carrying that window's load.
func (s *stubStats) reset() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.chatConns = make(map[int64]int)
	s.byPriority = make(map[string]int64)
	s.requestsServed = 0
	s.peakInFlight = s.inFlight
	s.accepted = 0
	s.peakOpen = s.open
}

// stubProfile is the response shape the stub emits.
type stubProfile struct {
	// pilot, when set, makes each response produce exactly the request's own output cap and writes the
	// prospective-admission pilot's step log (stubpilot.go); nil for every other caller.
	pilot  *stubPilotLog
	tokens int
	ttft   time.Duration
	itl    time.Duration
	// readyAfter is how long after start /health reports healthy.
	//
	// A real engine loads weights and profiles memory before it serves; this stub is ready the instant it
	// binds, and that difference is not cosmetic where readiness is the thing under observation. M7's
	// pod-kill scenario was unobservable because of it: the replacement Pod went healthy inside a second,
	// so the outage fell between polls and the evidence trail recorded a platform that never changed. Runs
	// disagreed with each other about whether the failure had happened at all.
	//
	// Zero keeps the old behaviour, which is what every other caller wants.
	readyAfter time.Duration
	// metrics serves /metrics with a completed-request counter in vLLM's name.
	//
	// It exists so the m5c rehearsal can drive the matrix's engine-metrics scrape down the path a real engine
	// takes. It is off by default because the gateway's admission guard reads an engine's /metrics too, and
	// every other rehearsal has always met a stub that answered 404 there.
	metrics bool
	// iterLog, when set, prints vLLM v0.27.1's per-iteration log lines for every request the stub serves.
	iterLog *stubIterLog
	// usage, when set, ends each stream with the usage chunk vLLM sends for stream_options.include_usage.
	//
	// The replay records its prompt_tokens as engineInputTokens, and session 2's warm-up check refuses a cell whose
	// verification requests are not 2,048-token requests; a stub that sent no usage chunk made every rehearsal
	// cell read 0 tokens and refused it, so the check's passing path could not be rehearsed.
	usage bool
}

// stubPromptTokens is the token count a stub reports for a prompt of n characters.
//
// The stub has no tokenizer, so it inverts the measured table in internal/bench: a prompt whose length is one the
// table resolved reports that count exactly, as the served engine would, and any other length a rough n/4.
func stubPromptTokens(n int) int {
	for _, t := range bench.ResolvedInputTokenCounts() {
		if r, ok := bench.ResolveInputTokens(t); ok && r.Chars == n {
			return t
		}
	}
	return max(n/4, 1)
}

// stubNonDefaultArgs is the startup line vLLM prints, carrying the keys the instrument-validation harness reads.
//
// The keys and the Python repr are vLLM's own: the paid runs recorded `'enable_prefix_caching': False` in this
// form, and --no-async-scheduling and --enable-logging-iteration-details are the same kind of flag.
// stubWithRevisions adds the revision keys vLLM prints for --revision and --tokenizer-revision, single-quoted as it
// prints every string, to a non-default args line; an empty value adds nothing, as vLLM prints only what was set.
func stubWithRevisions(line, revision, tokenizerRevision string) string {
	body := strings.TrimSuffix(line, "}")
	if revision != "" {
		body += fmt.Sprintf(", 'revision': '%s'", revision)
	}
	if tokenizerRevision != "" {
		body += fmt.Sprintf(", 'tokenizer_revision': '%s'", tokenizerRevision)
	}
	return body + "}"
}

// stubArg is one of the pilot's vLLM flags the stub accepts, with the Python type vLLM prints its value in.
type stubArg struct {
	key, kind string
	val       *string
}

// stubWithArgs adds the pilot's flags that were set to a non-default args line, in vLLM's repr.
func stubWithArgs(line string, args []stubArg, noPrefixCaching bool) string {
	body := strings.TrimSuffix(line, "}")
	if noPrefixCaching {
		body += ", 'enable_prefix_caching': False"
	}
	for _, a := range args {
		if *a.val == "" {
			continue
		}
		if a.kind == "str" {
			body += fmt.Sprintf(", '%s': '%s'", a.key, *a.val)
		} else {
			body += fmt.Sprintf(", '%s': %s", a.key, *a.val)
		}
	}
	return body + "}"
}

// It names the model under both 'model_tag' and 'model', as the archived vLLM lines do, because the pilot's engine
// validator requires the 'model' key and refused a rehearsal whose stub printed only the first.
func stubNonDefaultArgs(port int, noAsync, iterDetails bool) string {
	s := fmt.Sprintf("non-default args: {'model_tag': 'stub', 'model': 'stub', 'port': %d", port)
	if noAsync {
		s += ", 'async_scheduling': False"
	}
	if iterDetails {
		s += ", 'enable_logging_iteration_details': True"
	}
	return s + "}"
}

// stubIterLog prints one line per stub step in the format of vLLM v0.27.1's LoggingStatLogger.
//
// The stub has no scheduler, so its steps are invented: one context step for the prompt and one generation step
// per output token after the first, with the context tokens estimated from the body length.
// What the harness checks is that the lines exist and that their indices run on without a gap, and both hold.
type stubIterLog struct {
	mu    sync.Mutex
	out   *os.File
	index int
}

func (l *stubIterLog) request(promptTokens int64, tokens int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	ctx := max(promptTokens, 1)
	_, _ = fmt.Fprintf(l.out, "INFO stub [loggers.py:182] Iteration(%d): 1 context requests, %d context tokens, "+
		"0 generation requests, 0 generation tokens, iteration elapsed time: 1.00 ms, GPU KV cache usage: 0.1%%\n",
		l.index, ctx)
	l.index++
	for range max(tokens-1, 0) {
		_, _ = fmt.Fprintf(l.out, "INFO stub [loggers.py:182] Iteration(%d): 0 context requests, 0 context tokens, "+
			"1 generation requests, 1 generation tokens, iteration elapsed time: 1.00 ms, GPU KV cache usage: 0.1%%\n",
			l.index)
		l.index++
	}
}

// validate refuses a profile that would serve a backend other than the one declared.
//
// Neither bad value fails on its own: `for i := range p.tokens` with a negative count emits nothing at all,
// and time.Sleep of a negative duration returns immediately. A mistyped flag or a stub:// URI therefore does
// not crash the stub — it quietly stands up a different experiment, and the run's numbers describe that one
// while the manifest describes the other. A refusal at startup is the only place this is cheap to catch.
func (p stubProfile) validate() error {
	if p.tokens < 1 {
		return fmt.Errorf("stub profile: tokens is %d; a response with no tokens measures nothing", p.tokens)
	}
	if p.ttft < 0 {
		return fmt.Errorf("stub profile: ttft is %s; a negative delay is served as no delay", p.ttft)
	}
	if p.readyAfter < 0 {
		return fmt.Errorf("stub profile: ready-after is %s; a negative delay is served as no delay", p.readyAfter)
	}
	if p.itl < 0 {
		return fmt.Errorf("stub profile: itl is %s; a negative delay is served as no delay", p.itl)
	}
	return nil
}

// applyModelPath overrides the profile from a "stub://" model path, and ignores anything else.
//
// Why the profile arrives this way at all: the InferenceDeployment controller builds every serving
// container with exactly the argument list `--model <name> --model-path <storageUri>`, so a stub deployed
// as an InferenceDeployment has no other per-deployment knob to reach.
//
// Encoding the response shape in the storage URI is therefore not a shortcut around the CR, it is the only
// field the CR gives a backend to be configured through, and it keeps the evidence script able to stand up
// a fast backend and a slow one from the same image.
//
// A path that is not a stub URI is left alone, so a real serving runtime's storage URI passes through
// untouched.
func (p *stubProfile) applyModelPath(modelPath string) error {
	if modelPath == "" {
		return nil
	}
	u, err := url.Parse(modelPath)
	if err != nil {
		// A parse failure and "not a stub URI" were one condition, which meant a malformed stub:// URI ran the
		// defaults while the CR described the profile the author intended. They are separated by intent: a
		// string that announces itself as a stub URI and then does not parse is a typo in the one field this
		// backend can be configured through, and guessing is how a run measures a backend nobody asked for. A
		// real serving runtime's storage URI still passes through untouched, because it does not claim to be
		// one of ours.
		if strings.HasPrefix(modelPath, "stub:") {
			return fmt.Errorf("model path %q announces the stub scheme but does not parse: %w", modelPath, err)
		}
		return nil
	}
	if u.Scheme != "stub" {
		return nil
	}
	// url.Values.Query() is not used, and that is the third way this function used to serve the defaults
	// quietly: Query() DISCARDS anything it cannot parse and returns no error, so "tokens=%zz" arrives as no
	// tokens parameter at all — past the unknown-key check below, because the key never appears — and the
	// default stands. ParseQuery reports it.
	q, qerr := url.ParseQuery(u.RawQuery)
	if qerr != nil {
		return fmt.Errorf("model path %q: its parameters do not parse: %w", modelPath, qerr)
	}
	// An unrecognised parameter is refused for the same reason an unparseable value is, and it is the likelier
	// mistake of the two: "token=4" for "tokens=4" reads correctly to a human, is silently not a parameter this
	// understands, and leaves the default in place. Nothing downstream can notice, because the default is a
	// valid profile — the startup validation added beside this cannot catch it either. The refusal names what
	// is accepted, since the whole point is that the author believed they had set something.
	for key := range q {
		switch key {
		case "tokens", "ttft-ms", "itl-ms", "ready-after-ms":
		default:
			return fmt.Errorf("model path %q: unknown parameter %q; the stub accepts tokens, ttft-ms, itl-ms and ready-after-ms",
				modelPath, key)
		}
	}
	// intParam returns the named query parameter, or def when it is absent.
	//
	// A present-but-unparseable value is an error rather than a silent fall back to the default, because a
	// typo in a profile would otherwise produce a run whose backend was not the one the evidence claims.
	intParam := func(key string, def int) (int, error) {
		raw := q.Get(key)
		if raw == "" {
			return def, nil
		}
		v, err := strconv.Atoi(raw)
		if err != nil {
			return 0, fmt.Errorf("model path %q: %s is not a number: %w", modelPath, key, err)
		}
		return v, nil
	}

	tokens, err := intParam("tokens", p.tokens)
	if err != nil {
		return err
	}
	ttftMs, err := intParam("ttft-ms", int(p.ttft/time.Millisecond))
	if err != nil {
		return err
	}
	itlMs, err := intParam("itl-ms", int(p.itl/time.Millisecond))
	if err != nil {
		return err
	}
	readyMs, err := intParam("ready-after-ms", int(p.readyAfter/time.Millisecond))
	if err != nil {
		return err
	}
	p.tokens = tokens
	p.ttft = time.Duration(ttftMs) * time.Millisecond
	p.itl = time.Duration(itlMs) * time.Millisecond
	p.readyAfter = time.Duration(readyMs) * time.Millisecond
	return nil
}

// stubServe runs a trivial streaming chat-completions backend.
//
// It lets the gen -> replay -> report path be exercised end to end with no GPU and no cluster, and, when
// built into an image and named by an InferenceDeployment, it is also the backend the gateway-path
// evidence script routes real load to.
//
// It emits a fixed number of token chunks after an optional first-token and inter-token delay.
//
// That produces realistic-shaped raw evidence for a dry run.
func stubServe(args []string) error {
	fs := flag.NewFlagSet("stub-serve", flag.ExitOnError)
	addr := fs.String("addr", ":8090", "listen address")
	tokens := fs.Int("tokens", 8, "output tokens per response")
	ttftMs := fs.Int("ttft-ms", 5, "delay before the first token")
	itlMs := fs.Int("itl-ms", 2, "delay between tokens")
	// --model and --model-path exist because the InferenceDeployment controller passes them to every
	// serving container it builds, so a stub that did not accept them would fail to parse its own arguments
	// and crash-loop the moment it is deployed as an InferenceDeployment.
	//
	// --model is accepted and ignored: the stub answers for whatever model is asked of it, and the gateway
	// has already decided the routing by the time a request arrives here.
	_ = fs.String("model", "", "model name; accepted for InferenceDeployment compatibility and ignored")
	modelPath := fs.String("model-path", "", "storage URI; a \"stub://...\" URI overrides the response profile")
	metrics := fs.Bool("metrics", false, "serve /metrics with a completed-request counter in vLLM's name")
	// The three flags below are vLLM's, accepted so the instrument-validation harness can append them to a stub
	// engine exactly as it appends them to the real one, and answered the way vLLM v0.27.1 answers them.
	//
	// The harness refuses a cell whose engine does not report the configuration its arm registers, and reads
	// that report from the `non-default args:` line and the `Iteration(` lines; a stub that printed neither
	// could only rehearse the refusal, never the path.
	port := fs.Int("port", 0, "vLLM's port flag; when set it overrides --addr and the vLLM-style non-default args line is printed")
	noAsync := fs.Bool("no-async-scheduling", false, "vLLM's flag; reported as async_scheduling False")
	iterDetails := fs.Bool("enable-logging-iteration-details", false, "vLLM's flag; one Iteration( line per stub step")
	// Session 3 pins the model and tokenizer revision on the engine's command line and refuses a cell whose engine does
	// not report them, so the stub accepts both and reports them in vLLM's form.
	revision := fs.String("revision", "", "vLLM's model revision flag; reported in the non-default args line")
	tokenizerRevision := fs.String("tokenizer-revision", "", "vLLM's tokenizer revision flag; reported likewise")
	// The prospective-admission pilot's engine flags, accepted and reported in vLLM's form, so the pilot's
	// whole-line engine validator meets the line it reads on the card. --scheduler-cls naming the pilot's step
	// logger switches on pilot mode: the step log at STEP_LOG_PATH, and output fixed at each request's own cap.
	var pilotArgs []stubArg
	for _, f := range []struct{ name, key, kind string }{
		{"dtype", "dtype", "str"}, {"max-model-len", "max_model_len", "int"}, {"max-num-seqs", "max_num_seqs", "int"},
		{"gpu-memory-utilization", "gpu_memory_utilization", "float"},
		{"max-num-batched-tokens", "max_num_batched_tokens", "int"}, {"scheduling-policy", "scheduling_policy", "str"},
		{"scheduler-cls", "scheduler_cls", "str"},
	} {
		pilotArgs = append(pilotArgs, stubArg{key: f.key, kind: f.kind, val: fs.String(f.name, "", "vLLM's flag; reported in the non-default args line")})
	}
	noPrefixCaching := fs.Bool("no-enable-prefix-caching", false, "vLLM's flag; reported as enable_prefix_caching False")
	stopStepLogAt := fs.String("stub-stop-step-log-at", "", "pilot mode: stop the step log at the first request whose ID contains this, to rehearse an ineligible arm")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *port > 0 {
		*addr = fmt.Sprintf(":%d", *port)
		fmt.Println(stubWithRevisions(stubWithArgs(stubNonDefaultArgs(*port, *noAsync, *iterDetails), pilotArgs, *noPrefixCaching), *revision, *tokenizerRevision))
	}

	profile := stubProfile{
		tokens:  *tokens,
		ttft:    time.Duration(*ttftMs) * time.Millisecond,
		itl:     time.Duration(*itlMs) * time.Millisecond,
		metrics: *metrics,
	}
	if err := profile.applyModelPath(*modelPath); err != nil {
		return err
	}
	// Validated after applyModelPath, not before, because a stub:// URI can replace every field and a check
	// on the flags alone would pass a profile that no longer exists.
	if err := profile.validate(); err != nil {
		return err
	}

	stats := newStubStats()
	if *iterDetails {
		profile.iterLog = &stubIterLog{out: os.Stdout}
	}
	for _, a := range pilotArgs {
		if a.key == "scheduler_cls" && *a.val == "pilot_step_logger.PilotStepLoggingScheduler" {
			path := os.Getenv("STEP_LOG_PATH")
			if path == "" {
				return fmt.Errorf("the pilot's step logger was asked for and STEP_LOG_PATH is unset")
			}
			pl, err := openStubPilotLog(path, os.Stdout)
			if err != nil {
				return err
			}
			pl.stopAt = *stopStepLogAt
			profile.pilot = pl
			// The pilot's own log carries the iteration lines, with timestamps; the session-era log is not printed too.
			profile.iterLog = nil
			go pl.watchSentinel(make(chan struct{}))
		}
	}
	profile.usage = *port > 0
	mux := stubMux(profile, stats)
	fmt.Printf("stub backend listening on %s (tokens=%d ttft=%s itl=%s readyAfter=%s)\n", *addr, profile.tokens, profile.ttft, profile.itl, profile.readyAfter)
	srv := &http.Server{
		Addr:              *addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ConnContext:       stats.connContext,
		ConnState:         stats.connState,
	}
	return srv.ListenAndServe()
}

// stubMux builds the stub backend's routes, separated from stubServe so the handlers can be exercised
// without binding a port.
//
// The seam is not cosmetic: the streaming handler's obligation to abandon a request whose client has gone
// away is a claim about what happens DURING a response, and nothing that only starts a listener can assert
// it. It went unnoticed for exactly that reason.
func stubMux(profile stubProfile, stats *stubStats) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		stats.begin(r.Context())
		defer stats.end()
		w.Header().Set("Content-Type", "text/event-stream")
		f, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, "streaming unsupported", http.StatusInternalServerError)
			return
		}
		// Every wait and every write is abandoned the moment the client goes away.
		//
		// The bare time.Sleep this replaces ignored r.Context(), so a request the harness had already timed
		// out kept its handler asleep for the whole configured response — and stats.begin/end counted it as
		// in flight the entire time. peakInFlight is what PoolSizeForTrace is derived from, so the contamination
		// landed in the instrument's own sizing, not merely in a log line. Ignoring write errors kept it
		// writing into a closed connection for the same span.
		wait := func(d time.Duration) bool {
			if d <= 0 {
				return true
			}
			timer := time.NewTimer(d)
			defer timer.Stop()
			select {
			case <-timer.C:
				return true
			case <-r.Context().Done():
				return false
			}
		}
		emit := func(chunk string) bool {
			if _, err := fmt.Fprint(w, chunk); err != nil {
				return false
			}
			f.Flush()
			return true
		}
		promptTokens := 0
		// The body is read whole once, so the priority can be counted whatever the profile, and the usage
		// profile decodes the same bytes it always did.
		raw, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "unreadable request body: "+err.Error(), http.StatusBadRequest)
			return
		}
		var prio struct {
			Priority *json.Number `json:"priority"`
		}
		label := "none"
		if json.Unmarshal(raw, &prio) == nil && prio.Priority != nil {
			label = prio.Priority.String()
		}
		stats.notePriority(label)
		// The pilot's step log records each request's prompt whether or not usage is reported, so it needs the
		// count too; without it a length outside the frozen table logged a zero-token prompt (review of 60f3674).
		if profile.usage || profile.pilot != nil {
			var body struct {
				Messages []struct {
					Content string `json:"content"`
				} `json:"messages"`
			}
			if err := json.Unmarshal(raw, &body); err != nil {
				http.Error(w, "unreadable request body: "+err.Error(), http.StatusBadRequest)
				return
			}
			for _, m := range body.Messages {
				promptTokens += stubPromptTokens(len([]rune(m.Content)))
			}
		}
		if profile.pilot != nil {
			// The pilot's traces carry its frozen counts and each session checks them against its engine, so the
			// stub reports those counts for the frozen lengths, as the engine they were measured on does.
			var body struct {
				Messages []struct {
					Content string `json:"content"`
				} `json:"messages"`
			}
			if json.Unmarshal(raw, &body) == nil && len(body.Messages) == 1 {
				if st, ok := bench.LookupStudy(bench.StudyProspectivePilot); ok {
					if n, ok := st.FrozenExactTokens[len([]rune(body.Messages[0].Content))]; ok {
						promptTokens = n
					}
				}
			}
		}
		tokens := profile.tokens
		if profile.pilot != nil {
			var pr stubPilotRequest
			_ = json.Unmarshal(raw, &pr)
			if pr.MaxTokens > 0 {
				tokens = pr.MaxTokens
			}
			id := "chatcmpl-" + r.Header.Get("X-Request-Id")
			profile.pilot.add(id, pr.Priority, promptTokens)
			profile.pilot.stepFor(id, max(promptTokens, 1), 0, true)
		}
		if !wait(profile.ttft) {
			return
		}
		if profile.iterLog != nil {
			// The prompt tokens the usage chunk reports, when there is one, so the log's context steps and the replay's
			// engineInputTokens agree as they do on the engine; a session-2 warm-up reconciles the two and refused a
			// rehearsal whose stub logged the body length over four instead.
			prompt := r.ContentLength / 4
			if profile.usage {
				prompt = int64(promptTokens)
			}
			profile.iterLog.request(prompt, profile.tokens)
		}
		for i := range tokens {
			if i > 0 && !wait(profile.itl) {
				return
			}
			// Each decode step is recorded before its token is sent, so a step is never logged after the response
			// that depended on it has reached the client.
			if i > 0 && profile.pilot != nil {
				profile.pilot.stepFor("chatcmpl-"+r.Header.Get("X-Request-Id"), 1, promptTokens+i, false)
			}
			if !emit("data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n") {
				return
			}
		}
		if profile.usage && !emit(fmt.Sprintf("data: {\"choices\":[],\"usage\":{\"prompt_tokens\":%d,\"completion_tokens\":%d}}\n\n",
			promptTokens, tokens)) {
			return
		}
		_ = emit("data: [DONE]\n\n")
	})
	// /health is on the serving port and not a separate one because the InferenceDeployment controller
	// hardcodes both probes to GET /health on the container's named "http" port; without it the pod never
	// becomes ready and the Service it backs never gets an endpoint.
	//
	// Before readyAfter has elapsed it reports 503, which is what a serving container looks like while it is
	// still loading. Without that this stub is ready the instant it binds, and a scenario that kills a Pod
	// has nothing observable to show: the replacement is healthy before the next poll, and the evidence
	// trail records a platform that never changed.
	startedAt := time.Now()
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		if profile.readyAfter > 0 && time.Since(startedAt) < profile.readyAfter {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	if profile.metrics {
		// One counter, in the name vLLM gives it, and nothing that would pass for a latency: a stub's timings
		// are its configuration, and a histogram of them would look like a measurement in an archive.
		mux.HandleFunc("/metrics", func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "text/plain; version=0.0.4")
			_, _ = fmt.Fprintf(w, "# HELP vllm:request_success_total Requests this stub began serving.\n"+
				"# TYPE vllm:request_success_total counter\nvllm:request_success_total %d\n", stats.snapshot().RequestsServed)
		})
	}
	writeStats := func(w http.ResponseWriter, snap stubStatsSnapshot) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(snap)
	}
	mux.HandleFunc("/stats", func(w http.ResponseWriter, _ *http.Request) {
		writeStats(w, stats.snapshot())
	})
	mux.HandleFunc("/stats/reset", func(w http.ResponseWriter, r *http.Request) {
		// POST-only. This endpoint destroys the connection accounting an evidence run is in the middle of
		// collecting, and a GET is what a probe, a link prefetch, a browser or a stray curl issues — the
		// kubelet already GETs this port for /health. Requiring POST removes the accidental route.
		//
		// It is NOT authentication, and this comment says so rather than implying the hole is closed:
		// anything that can reach the Service can still POST here. The stub exists only inside the evidence
		// cluster, so the realistic failure is an accident rather than an adversary; a real fix is a separate
		// administrative listener, which is more machinery than a measurement stub has earned.
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", http.MethodPost)
			http.Error(w, "reset requires POST: a GET here would silently discard a run's counters",
				http.StatusMethodNotAllowed)
			return
		}
		stats.reset()
		writeStats(w, stats.snapshot())
	})

	return mux
}
