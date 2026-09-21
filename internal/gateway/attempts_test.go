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

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/prometheus/client_golang/prometheus/testutil"
)

// backend_attempts_total exists to answer one question requests_total cannot: was the serving stack asked?
//
// The specs below are written as pairs. Each drives a request, then asserts what happened to BOTH counters,
// because the whole point of the new series is that the two disagree — and a spec that watched only the new
// one would pass just as well if it were a copy of the old.
//
// The second pair is the one that earns the counter. A 429 from the admission guard carries the resolved
// model name (server.go:488), exactly as an attempted request does, so in requests_total it is indistinguishable
// from a backend that answered 429 itself.

func attemptsFor(tenant, model string) float64 {
	return testutil.ToFloat64(backendAttempts.WithLabelValues(tenant, model))
}

var _ = Describe("backend_attempts_total", func() {
	It("rises with requests_total when a backend is actually asked", func() {
		upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusOK)
		}))
		defer upstream.Close()

		s := newProxyServer(upstream.URL, 60)
		beforeAttempts := attemptsFor(testTenant, testModel)
		beforeRequests := requestsFor(testTenant, testModel, http.StatusOK)

		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(`{"model":"`+testModel+`"}`))

		Expect(rr.Code).To(Equal(http.StatusOK))
		Expect(attemptsFor(testTenant, testModel)).To(Equal(beforeAttempts+1),
			"a request that reached a backend is the population every serving question is asked over")
		Expect(requestsFor(testTenant, testModel, http.StatusOK)).To(Equal(beforeRequests + 1))
	})

	It("does not rise when the limiter refuses, while requests_total does", func() {
		// Burst 1, so the second request in the window is refused at step 4 — before the model is even parsed.
		s := newProxyServerWithBurst("", 1, 1)
		s.Handler().ServeHTTP(httptest.NewRecorder(), authedRequest(`{"model":"`+testModel+`"}`))

		beforeAttempts := attemptsFor(testTenant, testModel)
		beforeRequests := requestsFor(testTenant, "", http.StatusTooManyRequests)

		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(`{"model":"`+testModel+`"}`))

		Expect(rr.Code).To(Equal(http.StatusTooManyRequests))
		Expect(attemptsFor(testTenant, testModel)).To(Equal(beforeAttempts),
			"nothing was asked of a backend, so the denominator must not grow")
		Expect(requestsFor(testTenant, "", http.StatusTooManyRequests)).To(Equal(beforeRequests+1),
			"but the refusal is still a request the gateway answered")
	})

	It("does not rise when the caller is unauthenticated", func() {
		// Ends at step 2, the earliest exit there is. Asserted because the empty-label cell is where a future
		// version reaching for a tenant name would show up, and this counter must not be the place it does.
		s := newProxyServer("", 60)
		before := attemptsFor("", "")

		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil))

		Expect(rr.Code).To(Equal(http.StatusUnauthorized))
		Expect(attemptsFor("", "")).To(Equal(before))
	})
})
