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
	"flag"
	"fmt"
	"net/http"
	"os"
	"strings"
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

// stubServe runs a trivial streaming chat-completions backend.
//
// It lets the gen -> replay -> report path be exercised end to end with no GPU and no cluster.
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
	if err := fs.Parse(args); err != nil {
		return err
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		f, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, "streaming unsupported", http.StatusInternalServerError)
			return
		}
		time.Sleep(time.Duration(*ttftMs) * time.Millisecond)
		for i := range *tokens {
			if i > 0 {
				time.Sleep(time.Duration(*itlMs) * time.Millisecond)
			}
			_, _ = fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n")
			f.Flush()
		}
		_, _ = fmt.Fprint(w, "data: [DONE]\n\n")
		f.Flush()
	})

	fmt.Printf("stub backend listening on %s\n", *addr)
	srv := &http.Server{Addr: *addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	return srv.ListenAndServe()
}
