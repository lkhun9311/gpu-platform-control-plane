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
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

// probeTenant labels a series these specs create, so a scrape has a known line to carry or withhold.
//
// Every gateway series is a labelled vector that prints nothing until a child exists, so without one a focused run scrapes an empty body and "no metric bytes" would pass vacuously.
const probeTenant = "metrics-auth-probe"

// metricsMarker is the line the probe series puts in a served scrape and a refused one must not contain.
var metricsMarker = metricPrefix + `rate_limited_total{tenant="` + probeTenant + `"}`

// writeToken puts content in a fresh file and returns its path.
func writeToken(content string) string {
	path := filepath.Join(GinkgoT().TempDir(), "token")
	Expect(os.WriteFile(path, []byte(content), 0o600)).To(Succeed())
	return path
}

// scrape sends one request to the :8081 mux and returns the recorder.
func scrape(s *Server, path, authorization string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, path, nil)
	if authorization != "" {
		req.Header.Set("Authorization", authorization)
	}
	rr := httptest.NewRecorder()
	s.MetricsHandler().ServeHTTP(rr, req)
	return rr
}

var _ = Describe("metrics bearer token", func() {
	BeforeEach(func() {
		rateLimited.WithLabelValues(probeTenant)
		DeferCleanup(func() { rateLimited.DeleteLabelValues(probeTenant) })
	})

	// Mutation that turns this red: drop the `s.metricsTokenDigest != nil` check in MetricsHandler, so /metrics is always wrapped.
	It("leaves /metrics open when no token file is configured", func() {
		rr := scrape(&Server{}, "/metrics", "")
		Expect(rr.Code).To(Equal(http.StatusOK))
		Expect(rr.Body.String()).To(ContainSubstring(metricsMarker))
	})

	Context("with a token file", func() {
		var s *Server

		BeforeEach(func() {
			s = &Server{}
			// The trailing newline is what `echo` and most Secret tooling leave behind.
			Expect(s.RequireMetricsBearerTokenFile(writeToken("s3cret\n"))).To(Succeed())
		})

		// Mutation that turns this red: refuse only when a header is present (`if ok && compare != 1`), so a bare request passes.
		It("refuses a scrape with no Authorization header and sends no metric bytes", func() {
			rr := scrape(s, "/metrics", "")
			Expect(rr.Code).To(Equal(http.StatusUnauthorized))
			Expect(rr.Header().Get("WWW-Authenticate")).To(HavePrefix("Bearer"))
			Expect(rr.Body.String()).NotTo(ContainSubstring(metricsMarker))
		})

		// Mutation that turns this red: refuse only on a missing "Bearer " prefix (`if !ok`), dropping the token comparison.
		It("refuses a scrape with the wrong token and sends no metric bytes", func() {
			rr := scrape(s, "/metrics", "Bearer wrong")
			Expect(rr.Code).To(Equal(http.StatusUnauthorized))
			Expect(rr.Body.String()).NotTo(ContainSubstring(metricsMarker))
		})

		// Mutation that turns this red: stop trimming the trailing newline in RequireMetricsBearerTokenFile, so the stored token never matches.
		It("serves a scrape that carries the right token", func() {
			rr := scrape(s, "/metrics", "Bearer s3cret")
			Expect(rr.Code).To(Equal(http.StatusOK))
			Expect(rr.Body.String()).To(ContainSubstring(metricsMarker))
		})

		// Mutation that turns this red: wrap the whole :8081 mux in requireBearer instead of the /metrics handler alone.
		It("keeps /readyz open, because the kubelet probes it without credentials", func() {
			s.MarkReady()
			rr := scrape(s, "/readyz", "")
			Expect(rr.Code).To(Equal(http.StatusOK))
		})
	})

	// Mutation that turns this red: delete the `token == ""` refusal, so an empty file stores the digest of "" and returns nil.
	It("refuses a token file that is empty or holds only a newline", func() {
		for _, content := range []string{"", "\n", "\r\n"} {
			s := &Server{}
			Expect(s.RequireMetricsBearerTokenFile(writeToken(content))).To(MatchError(ContainSubstring("is empty")))
			Expect(s.metricsTokenDigest).To(BeNil())
		}
	})

	// Mutation that turns this red: discard the os.ReadFile error; the empty-token check then refuses instead, with an error that is not ErrNotExist.
	It("refuses a token file that does not exist", func() {
		s := &Server{}
		err := s.RequireMetricsBearerTokenFile(filepath.Join(GinkgoT().TempDir(), "absent"))
		Expect(err).To(MatchError(os.ErrNotExist))
		Expect(s.metricsTokenDigest).To(BeNil())
	})
})
