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

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

// Both rules under test were bugs before they were rules, and the comments in server.go say so.
//
// Neither was reachable from a spec while it lived inline. The fallback counter needs two candidates from
// backendsFor, and every existing fallback spec calls tryBackends directly with a nil callback, so none of
// them runs the chatCompletions code that decides these two things. backendOverride returns exactly one
// candidate, so it cannot produce a fallback either.
//
// Pulling the decisions out of the request path is what makes them answerable: each is a total function of
// values the caller already has, so the cases below are the whole input space rather than a sample of it.

var _ = Describe("publishedCode", func() {
	// The status a finished attempt is counted under. Seeded 200, corrected only when nothing answered.

	It("keeps the answered status even when an earlier attempt failed", func() {
		// The regression this pins: a request whose FIRST attempt failed and whose retry SUCCEEDED leaves
		// lastFailure set. Without the answered guard the genuine 200 is overwritten by the failure it
		// recovered from, and a rescue is published as the thing it rescued the client from.
		Expect(publishedCode(true, http.StatusOK, http.StatusBadGateway)).To(Equal(http.StatusOK))
	})

	It("publishes the last failure when nothing reached the client", func() {
		// The regression this pins: every cancelled request. The failure callback only wrote rec.code on a
		// FINAL attempt, the guards inside tryBackends stopped the loop before any final attempt ran, and a
		// request nobody served went into requests_total as a success.
		Expect(publishedCode(false, http.StatusOK, http.StatusGatewayTimeout)).To(Equal(http.StatusGatewayTimeout))
	})

	It("keeps the seeded status when nothing answered and nothing failed either", func() {
		// No attempt reported a status, so there is nothing truer than what the recorder holds. Reaching for
		// a failure code here would invent one.
		Expect(publishedCode(false, http.StatusOK, 0)).To(Equal(http.StatusOK))
	})

	It("keeps an answered failure as itself", func() {
		// A backend that answered 500 answered. The last-failure path must not fire and rewrite it.
		Expect(publishedCode(true, http.StatusInternalServerError, http.StatusBadGateway)).
			To(Equal(http.StatusInternalServerError))
	})
})

var _ = Describe("servedByFallback", func() {
	// Whether this request is one the fallback path rescued. Both halves of the condition earned their place.

	It("is false when no second candidate was tried", func() {
		// The regression this pins: latching on the failure callback instead of tryBackends' own report. The
		// callback fires before the retry guards run, so it counted a fallback whenever a non-final attempt
		// failed — including cancelled requests where no retry ever happened, which the benchmark harness
		// produces on every timeout.
		Expect(servedByFallback(false, http.StatusOK)).To(BeFalse())
	})

	It("is true when a second candidate was tried and served the request", func() {
		Expect(servedByFallback(true, http.StatusOK)).To(BeTrue())
	})

	It("is false when the second candidate was tried and still failed", func() {
		// A fallback that also failed is not a rescue, and counting it as one inverts what the ratio means.
		Expect(servedByFallback(true, http.StatusBadGateway)).To(BeFalse())
	})

	It("is false for a 4xx from the spare", func() {
		// The spare was reached and refused the request on its own merits. The fallback path carried the
		// request but never served an answer, and the metric's name says "served" — which is why the range
		// stops at 400 rather than at 500.
		Expect(servedByFallback(true, http.StatusNotFound)).To(BeFalse())
	})

	// The boundaries, stated as values rather than left to the reader of the comparison.
	DescribeTable("the served range is 2xx and 3xx",
		func(code int, want bool) {
			Expect(servedByFallback(true, code)).To(Equal(want))
		},
		Entry("199 is below the range", 199, false),
		Entry("200 opens it", http.StatusOK, true),
		Entry("308 is still inside", http.StatusPermanentRedirect, true),
		Entry("399 closes it", 399, true),
		Entry("400 is outside", http.StatusBadRequest, false),
	)
})
