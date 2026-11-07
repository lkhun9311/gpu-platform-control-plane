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
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync/atomic"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

// Review r6, 2026-11-07: findings on the serving path that run through the real handler.
var _ = Describe("static-cap failover", func() {
	body := `{"model":"` + testModel + `","messages":[{"role":"user","content":"hello"}],"stream":true}`

	// static-cap charges the head's bucket; a request charged there and then sent to the spare spent nothing of the
	// spare's, which can then serve past its own cap.
	// Mutation that must turn this red: leave reasonWithinBudget out of pinnedToHead.
	It("keeps a request whose tokens it charged to the head off the spare, and lets an uncharged one fall back", func() {
		var spareHits atomic.Int64
		spare := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_, _ = io.ReadAll(r.Body)
			spareHits.Add(1)
			w.WriteHeader(http.StatusOK)
		}))
		defer spare.Close()
		spareURL, err := url.Parse(spare.URL)
		Expect(err).NotTo(HaveOccurred())
		head := refusedURL()
		for _, tc := range []struct {
			tier string
			hits int64
		}{{tierStandard, 0}, {tierPremium, 1}} {
			spareHits.Store(0)
			// A threshold of 1 token makes every standard request eligible, so the standard one is charged.
			s := newAdmissionServer("", tc.tier, AdmissionStaticCap, newStaticCapAdmitter(1e6, 1_000_000, 1))
			s.backendsOverride = func(string) []*url.URL { return []*url.URL{head, spareURL} }
			rr := httptest.NewRecorder()
			s.Handler().ServeHTTP(rr, authedRequest(body))
			Expect(spareHits.Load()).To(Equal(tc.hits), "tier %s", tc.tier)
			if tc.hits == 0 {
				Expect(rr.Code).NotTo(Equal(http.StatusOK), "a charged request answered from an uncharged backend")
			}
		}
	})
})

// reasonsByBackend is a stateless admitter that admits every backend for the reason its name maps to.
type reasonsByBackend map[string]string

func (reasonsByBackend) AdmitIsStateless() {}

func (m reasonsByBackend) Admit(_ context.Context, _ RequestMeta, b *BackendRef, _, _ string) (bool, string) {
	return true, m[b.Name]
}

var _ = Describe("an admit's reason from a stateless admitter", func() {
	body := `{"model":"` + testModel + `","messages":[{"role":"user","content":"hello"}],"stream":true}`

	// Every successful decision across candidates returned "", so a guard bypassed for want of telemetry
	// reported the same as a healthy admit, in the header, the trace and the reason-labelled metrics.
	// Mutations that must turn this red: return "" on admit, or report the head's reason over a spare's bypass.
	It("reports the head's reason, or a bypass on any candidate in its place", func() {
		up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_, _ = io.ReadAll(r.Body)
			w.WriteHeader(http.StatusOK)
		}))
		defer up.Close()
		u, err := url.Parse(up.URL)
		Expect(err).NotTo(HaveOccurred())
		for _, tc := range []struct {
			reasons reasonsByBackend
			want    string
		}{
			{reasonsByBackend{"head": reasonNotEngaged, "spare": reasonBelowThreshold}, reasonNotEngaged},
			{reasonsByBackend{"head": reasonNotEngaged, "spare": reasonTelemetryStale}, reasonTelemetryStale},
			{reasonsByBackend{"head": reasonBackendUnregistered, "spare": reasonTelemetryStale}, reasonBackendUnregistered},
		} {
			s := newAdmissionServer("", tierStandard, AdmissionKVAware, tc.reasons)
			s.refsOverride = func(string) []*BackendRef {
				return []*BackendRef{{Namespace: "ns", Name: "head", URL: u, Model: testModel}, {Namespace: "ns", Name: "spare", URL: u, Model: testModel}}
			}
			rr := httptest.NewRecorder()
			s.Handler().ServeHTTP(rr, authedRequest(body))
			Expect(rr.Code).To(Equal(http.StatusOK))
			Expect(rr.Header().Get(HeaderAdmissionReason)).To(Equal(tc.want), "%v", tc.reasons)
		}
	})
})

var _ = Describe("kv telemetry freshness", func() {
	// fresh was the verdict at publication, and the next publication waits for the next scrape, so with a scrape
	// interval longer than maxStaleness the guard kept acting on telemetry past its own limit.
	// Mutation that must turn this red: read snap.fresh in Admit instead of freshAt.
	It("expires a snapshot at maxStaleness without another scrape", func() {
		base := time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)
		now := base
		m := newScraperManager(scraperConfig{clock: func() time.Time { return now }})
		backend := &BackendRef{Namespace: "ns", Name: "b", Model: testModel}
		b := &backendScraper{}
		b.snap.Store(&backendSnapshot{engaged: true, fresh: true, freshUntil: base.Add(6 * time.Second)})
		m.mu.Lock()
		m.scrapers[backendKey(backend)] = b
		m.mu.Unlock()
		a := newKVAwareAdmitter(m, 1)
		long := RequestMeta{EstInputTokens: 10}

		now = base.Add(5 * time.Second)
		ok, reason := a.Admit(context.Background(), long, backend, "t", tierStandard)
		Expect(ok).To(BeFalse())
		Expect(reason).To(Equal(reasonKVCachePressure))

		now = base.Add(7 * time.Second)
		ok, reason = a.Admit(context.Background(), long, backend, "t", tierStandard)
		Expect(ok).To(BeTrue(), "an engaged guard kept refusing on telemetry older than maxStaleness")
		Expect(reason).To(Equal(reasonTelemetryStale))
		st, _ := a.Observed(backend)
		Expect(st.Fresh).To(BeFalse())
	})

	// Mutation that must turn this red: leave freshUntil unset in publish.
	It("publishes the time its telemetry expires", func() {
		h := &switchableHandler{mode: "engage"}
		up := httptest.NewServer(h)
		defer up.Close()
		base := time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)
		now := base
		cfg := baseScraperConfig(func() time.Time { return now })
		cfg.maxStaleness = 6 * time.Second
		b := newBackendScraper(*newTestRef("r6-ns", "r6-backend", up.URL), cfg)
		b.tick(context.Background())
		Expect(b.snap.Load().freshUntil).To(Equal(base.Add(6 * time.Second)))
		Expect(b.snap.Load().freshAt(base.Add(7 * time.Second))).To(BeFalse())
	})
})
