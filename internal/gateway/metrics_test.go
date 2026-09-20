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
	"strconv"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/prometheus/client_golang/prometheus/testutil"
)

// Two gaps that the package's coverage number cannot show, and that the existing metric specs do not close.
//
// internal/gateway sits at 91.4% of statements, and both lines asserted below were already inside it: the
// counters are incremented on paths other specs drive for their own reasons, so the statements execute.
// What was missing is different in each case.
//
// proxy_test.go's "metrics endpoint" spec drives a 200, a 429 and a 502 and then asserts that four series
// NAMES appear in /metrics. That pins the documented series list against the code, which is what it says it
// is for — but a counter incremented under the wrong label, or not at all, leaves every one of those names
// present and the spec green.
//
// So these assert values, in the style kvguard_test.go already uses. The sentinel-label case is deliberately
// not repeated here: proxy_test.go:769 already covers it, and more strictly, by scraping /metrics and
// checking neither probe name appears anywhere in the body.

// requestsFor reads one requests_total cell.
//
// The exact cell rather than the series total, because a counter incremented under the wrong code still
// moves the total and a spec watching the total would pass.
func requestsFor(tenant, model string, code int) float64 {
	return testutil.ToFloat64(requests.WithLabelValues(tenant, model, strconv.Itoa(code)))
}

var _ = Describe("requests_total cells", func() {
	// Each spec takes a before/after reading. The registry is shared across the suite, so an absolute value
	// would depend on spec ordering; a delta does not.

	It("counts an unauthenticated request under the empty tenant and model", func() {
		// server.go answers 401 before a tenant exists, so the labels it can honestly supply are empty. This
		// pins that: a future version reaching for a tenant name here would have to invent one, and inventing
		// it is how an unauthenticated caller starts choosing label values.
		s := newProxyServer("", 60)
		before := requestsFor("", "", http.StatusUnauthorized)

		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil))

		Expect(rr.Code).To(Equal(http.StatusUnauthorized))
		Expect(requestsFor("", "", http.StatusUnauthorized)).To(Equal(before + 1))
	})
})

var _ = Describe("rate_limited_total and requests{code=429}", func() {
	// server.go: "Counted separately from requests{code=429}; the two answer different questions."
	//
	// Nothing checked that they stay separate. One counts refusals by the RPM limiter; the other counts every
	// 429 the gateway emits, which since M5 also includes admission-guard refusals. Making either a function
	// of the other — or dropping one increment — keeps both series present in /metrics and every existing
	// spec green, while the ratio an operator reads to tell "over budget" from "backend under pressure"
	// quietly stops meaning anything.

	It("both move when the RPM limiter refuses a request", func() {
		// Burst 1 so the second request in the window is refused by the bucket rather than anything after it.
		s := newProxyServerWithBurst("", 1, 1)
		beforeRequests := requestsFor(testTenant, "", http.StatusTooManyRequests)
		beforeLimited := testutil.ToFloat64(rateLimited.WithLabelValues(testTenant))

		// The first request drains the bucket; its outcome is not what this spec is about.
		s.Handler().ServeHTTP(httptest.NewRecorder(), authedRequest(`{"model":"`+testModel+`"}`))

		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(`{"model":"`+testModel+`"}`))
		Expect(rr.Code).To(Equal(http.StatusTooManyRequests))

		Expect(requestsFor(testTenant, "", http.StatusTooManyRequests)).To(Equal(beforeRequests+1),
			"the refusal must appear in requests_total under 429")
		Expect(testutil.ToFloat64(rateLimited.WithLabelValues(testTenant))).To(Equal(beforeLimited+1),
			"and in rate_limited_total, which is what separates an over-budget tenant from a pressured backend")
	})

	It("only requests_total moves when the refusal is not the limiter's", func() {
		// A malformed body is refused at step 5, after a token has already been taken. Nothing here is a
		// rate-limit event, and counting it as one would inflate the numerator of that same ratio.
		s := newProxyServer("", 60)
		beforeRequests := requestsFor(testTenant, "", http.StatusBadRequest)
		beforeLimited := testutil.ToFloat64(rateLimited.WithLabelValues(testTenant))

		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(`{"model":`))

		Expect(rr.Code).To(Equal(http.StatusBadRequest))
		Expect(requestsFor(testTenant, "", http.StatusBadRequest)).To(Equal(beforeRequests + 1))
		Expect(testutil.ToFloat64(rateLimited.WithLabelValues(testTenant))).To(Equal(beforeLimited),
			"a parse failure is not a budget refusal")
	})
})
