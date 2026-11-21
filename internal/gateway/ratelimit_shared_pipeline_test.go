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
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync/atomic"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/prometheus/client_golang/prometheus/testutil"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// stubLimiter answers every request the same way, so a pipeline spec can stand in for Redis being up or down.
type stubLimiter struct {
	allow bool
	err   error
}

func (f stubLimiter) Decide(context.Context, string, *platformv1.GPUQuotaRateLimit) (bool, time.Duration, error) {
	return f.allow, 0, f.err
}

var _ = Describe("the shared rate limit store in the pipeline", func() {
	body := `{"model":"` + testModel + `","messages":[{"role":"user","content":"hello"}],"stream":true}`
	var up *httptest.Server
	var reached atomic.Int32

	BeforeEach(func() {
		reached.Store(0)
		up = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			reached.Add(1)
			w.WriteHeader(http.StatusOK)
		}))
		DeferCleanup(up.Close)
	})

	ref := func(name string, admission AdmissionMode, routing string) *BackendRef {
		u, err := url.Parse(up.URL)
		Expect(err).NotTo(HaveOccurred())
		return &BackendRef{Namespace: testTenantNS, Name: name, URL: u, Model: testModel,
			Admission: admission, MaxHold: 10 * time.Second, Routing: routing}
	}
	serve := func(s *Server) *httptest.ResponseRecorder {
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(body))
		return rr
	}
	sharedServer := func(refs ...*BackendRef) *Server {
		s := newAdmissionServer("", tierPremium, AdmissionOff, offAdmitter{})
		s.useSharedLimiter(stubLimiter{allow: true})
		s.refsOverride = func(string) []*BackendRef { return refs }
		return s
	}

	// HoldCap's protection is its serialisation, which each replica would apply on its own, so the shared store refuses it.
	// Mutation that turns this red: let singleGatewayFeature ignore HoldCap.
	It("refuses a HoldCap backend with 503 under the shared store", func() {
		before := testutil.ToFloat64(singleGatewayRefusals.WithLabelValues(singleGatewayHoldCap))
		rr := serve(sharedServer(ref("capped", AdmissionHoldCap, "")))
		Expect(rr.Code).To(Equal(http.StatusServiceUnavailable))
		expectJSONError(rr, "single_gateway_required")
		Expect(rr.Header().Get("Retry-After")).To(BeEmpty(), "the same request is refused again until the deployment changes")
		Expect(reached.Load()).To(BeZero())
		Expect(testutil.ToFloat64(singleGatewayRefusals.WithLabelValues(singleGatewayHoldCap)) - before).To(Equal(1.0))
	})

	// The control: the memory store serves the same HoldCap backend, so the refusal is the store's and not HoldCap's.
	It("serves a HoldCap backend under the memory store", func() {
		s := newAdmissionServer("", tierPremium, AdmissionOff, offAdmitter{})
		s.refsOverride = func(string) []*BackendRef { return []*BackendRef{ref("capped", AdmissionHoldCap, "")} }
		Expect(serve(s).Code).To(Equal(http.StatusOK))
		Expect(reached.Load()).To(Equal(int32(1)))
	})

	// PrefixAffinity's index lives in one process, so each replica would route on its own third of the prefixes.
	// Mutation that turns this red: let singleGatewayFeature ignore the routing policy.
	It("refuses PrefixAffinity with 503 under the shared store and leaves the index untouched", func() {
		pa := platformv1.RoutingPolicyPrefixAffinity
		s := sharedServer(ref("a", "", pa), ref("b", "", pa))
		before := testutil.ToFloat64(singleGatewayRefusals.WithLabelValues(singleGatewayPrefixAffinity))
		rr := serve(s)
		Expect(rr.Code).To(Equal(http.StatusServiceUnavailable))
		expectJSONError(rr, "single_gateway_required")
		Expect(reached.Load()).To(BeZero())
		Expect(testutil.ToFloat64(singleGatewayRefusals.WithLabelValues(singleGatewayPrefixAffinity)) - before).To(Equal(1.0))
		Expect(s.router).To(BeNil(), "a refused request built the router and recorded its prefix")
	})

	// The controls: a plain backend and RoundRobin both serve under the shared store, so the check is not a blanket refusal.
	It("serves plain and RoundRobin backends under the shared store", func() {
		Expect(serve(sharedServer(ref("plain", "", ""))).Code).To(Equal(http.StatusOK))
		rr := platformv1.RoutingPolicyRoundRobin
		Expect(serve(sharedServer(ref("a", "", rr), ref("b", "", rr))).Code).To(Equal(http.StatusOK))
		Expect(reached.Load()).To(Equal(int32(2)))
	})

	// A limiter that cannot decide answers 503 with a one-second retry, never 429, and never serves.
	// 429 would tell the caller it spent a budget nobody measured, and the harness reads 429 as admission shedding.
	// Mutations that turn this red: answer the error with 429, or admit the request.
	It("answers 503 rate_limit_unavailable when the shared store cannot decide", func() {
		s := sharedServer(ref("plain", "", ""))
		s.useSharedLimiter(stubLimiter{err: ErrRateLimitUnavailable})
		limitedBefore := testutil.ToFloat64(rateLimited.WithLabelValues(testTenant))
		rr := serve(s)
		Expect(rr.Code).To(Equal(http.StatusServiceUnavailable))
		expectJSONError(rr, "rate_limit_unavailable")
		Expect(rr.Header().Get("Retry-After")).To(Equal("1"))
		Expect(reached.Load()).To(BeZero())
		Expect(testutil.ToFloat64(rateLimited.WithLabelValues(testTenant))).To(Equal(limitedBefore),
			"a request nobody measured was counted as over its budget")
	})

	// A shared limiter's refusal is the same 429 the memory store gives, so clients see no difference between stores.
	It("answers 429 when the shared store refuses", func() {
		s := sharedServer(ref("plain", "", ""))
		s.useSharedLimiter(stubLimiter{allow: false})
		rr := serve(s)
		Expect(rr.Code).To(Equal(http.StatusTooManyRequests))
		Expect(reached.Load()).To(BeZero())
	})
})
