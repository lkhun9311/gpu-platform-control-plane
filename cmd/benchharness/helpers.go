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
}

// newStubStats returns stats with the connection map ready, since inserting into a nil map panics.
func newStubStats() *stubStats {
	return &stubStats{chatConns: make(map[int64]int)}
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
	s.requestsServed = 0
	s.peakInFlight = s.inFlight
	s.accepted = 0
	s.peakOpen = s.open
}

// stubProfile is the response shape the stub emits.
type stubProfile struct {
	tokens int
	ttft   time.Duration
	itl    time.Duration
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
	if err != nil || u.Scheme != "stub" {
		return nil
	}
	q := u.Query()
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
	p.tokens = tokens
	p.ttft = time.Duration(ttftMs) * time.Millisecond
	p.itl = time.Duration(itlMs) * time.Millisecond
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
	if err := fs.Parse(args); err != nil {
		return err
	}

	profile := stubProfile{
		tokens: *tokens,
		ttft:   time.Duration(*ttftMs) * time.Millisecond,
		itl:    time.Duration(*itlMs) * time.Millisecond,
	}
	if err := profile.applyModelPath(*modelPath); err != nil {
		return err
	}

	stats := newStubStats()
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
		time.Sleep(profile.ttft)
		for i := range profile.tokens {
			if i > 0 {
				time.Sleep(profile.itl)
			}
			_, _ = fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n")
			f.Flush()
		}
		_, _ = fmt.Fprint(w, "data: [DONE]\n\n")
		f.Flush()
	})
	// /health is on the serving port and not a separate one because the InferenceDeployment controller
	// hardcodes both probes to GET /health on the container's named "http" port; without it the pod never
	// becomes ready and the Service it backs never gets an endpoint.
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	writeStats := func(w http.ResponseWriter, snap stubStatsSnapshot) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(snap)
	}
	mux.HandleFunc("/stats", func(w http.ResponseWriter, _ *http.Request) {
		writeStats(w, stats.snapshot())
	})
	mux.HandleFunc("/stats/reset", func(w http.ResponseWriter, _ *http.Request) {
		stats.reset()
		writeStats(w, stats.snapshot())
	})

	fmt.Printf("stub backend listening on %s (tokens=%d ttft=%s itl=%s)\n", *addr, profile.tokens, profile.ttft, profile.itl)
	srv := &http.Server{
		Addr:              *addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ConnContext:       stats.connContext,
		ConnState:         stats.connState,
	}
	return srv.ListenAndServe()
}
