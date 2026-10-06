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

package gateway

import (
	"crypto/sha256"
	"crypto/subtle"
	"fmt"
	"net/http"
	"os"
	"strings"
)

// RequireMetricsBearerTokenFile makes /metrics demand the bearer token held in path.
//
// It refuses a missing or empty file rather than serving unauthenticated, because an operator who set the flag believes the endpoint is protected.
// A guard that silently turns itself off is worse than no guard: nobody goes looking for the gap.
// Trailing newlines are trimmed because `echo token > file` and a Secret written from a heredoc both leave one, and a token that silently never matches would lock Prometheus out instead.
// It must be called before MetricsHandler, which reads the token once when it builds the mux.
func (s *Server) RequireMetricsBearerTokenFile(path string) error {
	if path == "" {
		return fmt.Errorf("metrics bearer token file: empty path")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("metrics bearer token file: %w", err)
	}
	token := strings.TrimRight(string(raw), "\r\n")
	if token == "" {
		return fmt.Errorf("metrics bearer token file %s is empty; refusing to serve /metrics unauthenticated", path)
	}
	digest := sha256.Sum256([]byte(token))
	s.metricsTokenDigest = digest[:]
	return nil
}

// requireBearer wraps next so that only a request carrying the configured token reaches it.
//
// Both sides are hashed before the comparison because subtle.ConstantTimeCompare returns early on a length mismatch, which would leak the token's length.
// The 401 carries no body from next, so a refused scrape learns nothing about which series exist.
func requireBearer(digest []byte, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		sum := sha256.Sum256([]byte(got))
		if !ok || subtle.ConstantTimeCompare(sum[:], digest) != 1 {
			w.Header().Set("WWW-Authenticate", `Bearer realm="metrics"`)
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}
