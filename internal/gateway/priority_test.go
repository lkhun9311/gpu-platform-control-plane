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
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

// Binding the engine priority to the tier is the precondition docs/superpowers/specs/2026-10-06-m5b-stays-closed-
// and-what-a-successor-needs-first.md names first: without it a priority-scheduling engine orders work by what the
// caller claims.
var _ = Describe("engine priority bound to the tier", func() {
	var (
		up       *httptest.Server
		received chan map[string]any
		length   chan int64
	)

	BeforeEach(func() {
		received = make(chan map[string]any, 1)
		length = make(chan int64, 1)
		up = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			raw, _ := io.ReadAll(r.Body)
			var body map[string]any
			_ = json.Unmarshal(raw, &body)
			received <- body
			length <- r.ContentLength - int64(len(raw))
			w.WriteHeader(http.StatusOK)
		}))
	})
	AfterEach(func() { up.Close() })

	send := func(tier, body string, bind bool) *httptest.ResponseRecorder {
		s := newAdmissionServer(up.URL, tier, AdmissionOff, offAdmitter{})
		s.BindPriority(bind)
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(body))
		return rr
	}
	plain := `{"model":"` + testModel + `","messages":[{"role":"user","content":"hi"}]}`

	// Mutation that turns this red: return standardEnginePriority for every tier.
	It("forwards a premium tenant's request with priority 0 and says so on the response", func() {
		rr := send(tierPremium, plain, true)
		Expect(rr.Code).To(Equal(http.StatusOK))
		Expect((<-received)["priority"]).To(BeEquivalentTo(premiumEnginePriority))
		Expect(rr.Header().Get(HeaderEnginePriority)).To(Equal("0"))
		Expect(<-length).To(BeZero(), "the forwarded Content-Length disagreed with the rewritten body")
	})

	// Mutation that turns this red: keep a caller-supplied priority instead of overwriting it.
	It("overwrites a standard tenant's own claim to be scheduled first", func() {
		claim := `{"model":"` + testModel + `","priority":-100,"messages":[{"role":"user","content":"hi"}]}`
		rr := send(tierStandard, claim, true)
		Expect(rr.Code).To(Equal(http.StatusOK))
		Expect((<-received)["priority"]).To(BeEquivalentTo(standardEnginePriority))
		Expect(rr.Header().Get(HeaderEnginePriority)).To(Equal("1"))
		Expect(<-length).To(BeZero())
	})

	// Off is the default, and with it the body reaches the engine as the caller sent it.
	It("leaves the body alone when binding is off", func() {
		claim := `{"model":"` + testModel + `","priority":-100,"messages":[{"role":"user","content":"hi"}]}`
		rr := send(tierStandard, claim, false)
		Expect(rr.Code).To(Equal(http.StatusOK))
		Expect((<-received)["priority"]).To(BeEquivalentTo(-100))
		Expect(rr.Header().Get(HeaderEnginePriority)).To(BeEmpty())
	})

	// A retry on another backend rewinds through GetBody, so the rewritten bytes must be what GetBody returns,
	// every time it is called. Mutation that turns this red: replace r.Body but leave r.GetBody on the old bytes.
	It("makes every rewind of the body carry the bound priority", func() {
		r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(plain))
		orig := []byte(plain)
		r.GetBody = func() (io.ReadCloser, error) { return io.NopCloser(strings.NewReader(string(orig))), nil }
		p, err := bindEnginePriority(r, tierStandard)
		Expect(err).NotTo(HaveOccurred())
		Expect(p).To(Equal(standardEnginePriority))
		for range 2 {
			rc, err := r.GetBody()
			Expect(err).NotTo(HaveOccurred())
			raw, _ := io.ReadAll(rc)
			Expect(r.ContentLength).To(BeEquivalentTo(len(raw)))
			var body map[string]any
			Expect(json.Unmarshal(raw, &body)).To(Succeed())
			Expect(body["priority"]).To(BeEquivalentTo(standardEnginePriority))
			Expect(body["model"]).To(Equal(testModel))
		}
	})
})
