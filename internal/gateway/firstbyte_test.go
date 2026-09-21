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
	"github.com/prometheus/client_golang/prometheus"
	dto "github.com/prometheus/client_model/go"
)

// time_to_first_byte_seconds differs from request_duration_seconds in two ways a spec has to pin, because
// both are latencies in seconds over the same population and getting them confused would look plausible.
//
// The first is WHEN: requestDuration is observed after ServeHTTP returns, this one the moment a byte reaches
// the client. The second is WHETHER: a request that produced no byte has no first-byte latency at all, and
// filing the elapsed time anyway would enter every cancelled request as a slow success.

// firstByteSamples reads the histogram's observation count for one label pair.
//
// testutil.ToFloat64 cannot do this -- it refuses anything but a single-value metric -- and CollectAndCount
// returns the number of SERIES, which is 1 both before and after an observation. The sample count is the only
// reading that answers "was an observation made", so the child is written out and read back directly.
func firstByteSamples(tenant, model string) uint64 {
	m := &dto.Metric{}
	o, err := timeToFirstByte.GetMetricWithLabelValues(tenant, model)
	if err != nil {
		return 0
	}
	if err := o.(prometheus.Metric).Write(m); err != nil {
		return 0
	}
	return m.GetHistogram().GetSampleCount()
}

var _ = Describe("time_to_first_byte_seconds", func() {
	It("is observed when a backend answers", func() {
		upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusOK)
		}))
		defer upstream.Close()

		s := newProxyServer(upstream.URL, 60)
		before := firstByteSamples(testTenant, testModel)

		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(`{"model":"`+testModel+`"}`))

		Expect(rr.Code).To(Equal(http.StatusOK))
		Expect(firstByteSamples(testTenant, testModel)).To(Equal(before+1),
			"a response the client received has a first-byte latency")
	})

	It("is not observed when the request never reached a backend", func() {
		// Refused at step 2, so nothing was ever written to the client. This pins the guard in server.go: an
		// observation here would be an elapsed time that is not a first-byte latency, filed as if it were.
		s := newProxyServer("", 60)
		before := firstByteSamples("", "")

		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil))

		Expect(rr.Code).To(Equal(http.StatusUnauthorized))
		Expect(firstByteSamples("", "")).To(Equal(before))
	})

	It("is observed when the gateway writes the error itself", func() {
		// Start and immediately close, so the dial is refused -- the convention proxy_test.go:337 uses.
		//
		// This is the spec that corrected the design. The guard in server.go was written believing a failed
		// request had no first byte; a probe showed the 502 envelope proxy.go's ErrorHandler writes IS one,
		// and the same holds for a header timeout and an already-cancelled context. So the series covers
		// errors, deliberately: one that counted only successes would improve as the backend got worse.
		up := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
		addr := up.URL
		up.Close()

		s := newProxyServer(addr, 600)
		before := firstByteSamples(testTenant, testModel)

		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(`{"model":"`+testModel+`"}`))

		Expect(rr.Code).To(Equal(http.StatusBadGateway))
		Expect(firstByteSamples(testTenant, testModel)).To(Equal(before+1),
			"the error envelope reached the client, so its latency is a real first-byte latency")
	})

	It("stamps the first write and not a later one", func() {
		// markFirstByte guards on the zero value rather than on answered. answered is set by BOTH paths, so a
		// guard on it would let a second write move a timestamp that already meant something -- and for a
		// streaming response the second write is the one that carries tokens, arriving arbitrarily later.
		rec := &statusRecorder{ResponseWriter: httptest.NewRecorder(), code: http.StatusOK}

		rec.WriteHeader(http.StatusOK)
		stamped := rec.firstByteAt
		Expect(stamped.IsZero()).To(BeFalse())

		_, _ = rec.Write([]byte("a later chunk"))
		Expect(rec.firstByteAt).To(Equal(stamped),
			"a second write must not move a timestamp that already means something")
	})

	It("stamps a body write that never called WriteHeader", func() {
		// A handler may write a body without a status line, which implicitly means 200. That byte reached the
		// client exactly as a header would have, so it has to stamp too.
		rec := &statusRecorder{ResponseWriter: httptest.NewRecorder(), code: http.StatusOK}

		_, _ = rec.Write([]byte("body first"))
		Expect(rec.firstByteAt.IsZero()).To(BeFalse())
	})

	It("leaves the stamp zero when nothing was written", func() {
		rec := &statusRecorder{ResponseWriter: httptest.NewRecorder(), code: http.StatusOK}
		Expect(rec.firstByteAt.IsZero()).To(BeTrue(),
			"the zero value is what tells the caller there is no first-byte latency to report")
	})
})
