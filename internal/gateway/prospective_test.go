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
	"strings"
	"sync"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("prospective admission", func() {
	backend := &BackendRef{URL: &url.URL{Scheme: "http", Host: "engine-a:8000"}}
	meta := func(tokens int) RequestMeta { return RequestMeta{EstInputTokens: tokens} }

	// Mutation that turns this red: check the prefill cap before adding the request's own tokens.
	It("reserves a standard request's input and a stream, and refuses what does not fit", func() {
		p := newProspectiveAdmitter(1000, 2)
		r1, ok, why := p.Reserve(context.Background(), meta(600), backend, "t", tierStandard)
		Expect(ok).To(BeTrue())
		Expect(why).To(Equal(reasonReserved))
		_, ok, why = p.Reserve(context.Background(), meta(500), backend, "t", tierStandard)
		Expect(ok).To(BeFalse())
		Expect(why).To(Equal(reasonPrefillReservationFull))
		tokens, streams := p.held(backend)
		Expect(tokens).To(Equal(600))
		Expect(streams).To(Equal(1))

		// The prefill comes back at the first byte; the stream stays until the request ends.
		r1.PrefillDone()
		r1.PrefillDone()
		tokens, streams = p.held(backend)
		Expect(tokens).To(BeZero())
		Expect(streams).To(Equal(1))
		r1.Done()
		r1.Done()
		tokens, streams = p.held(backend)
		Expect(tokens).To(BeZero())
		Expect(streams).To(BeZero(), "a second Done released a stream that was not held")
	})

	// Mutation that turns this red: compare running streams with > instead of >=.
	It("refuses a standard request while the backend runs its cap of standard streams", func() {
		p := newProspectiveAdmitter(100000, 2)
		for range 2 {
			r, ok, _ := p.Reserve(context.Background(), meta(10), backend, "t", tierStandard)
			Expect(ok).To(BeTrue())
			r.PrefillDone()
		}
		_, ok, why := p.Reserve(context.Background(), meta(10), backend, "t", tierStandard)
		Expect(ok).To(BeFalse())
		Expect(why).To(Equal(reasonStandardStreamsFull))
	})

	It("admits premium without holding anything, even when the standard tier is full", func() {
		p := newProspectiveAdmitter(10, 1)
		_, ok, _ := p.Reserve(context.Background(), meta(10), backend, "t", tierStandard)
		Expect(ok).To(BeTrue())
		r, ok, why := p.Reserve(context.Background(), meta(5000), backend, "t", tierPremium)
		Expect(ok).To(BeTrue())
		Expect(why).To(Equal(reasonPremiumUnreserved))
		Expect(r).To(BeNil())
		tokens, streams := p.held(backend)
		Expect(tokens).To(Equal(10))
		Expect(streams).To(Equal(1))
	})

	// The two caps are checked and taken in one critical section; if they were not, concurrent requests could
	// each see room for one more. Run under -race as well.
	It("never holds more than its caps under concurrent reservations", func() {
		p := newProspectiveAdmitter(1000, 5)
		var wg sync.WaitGroup
		var mu sync.Mutex
		var held []*reservation
		for range 200 {
			wg.Go(func() {
				if r, ok, _ := p.Reserve(context.Background(), meta(150), backend, "t", tierStandard); ok {
					mu.Lock()
					held = append(held, r)
					mu.Unlock()
				}
			})
		}
		wg.Wait()
		tokens, streams := p.held(backend)
		Expect(tokens).To(BeNumerically("<=", 1000))
		Expect(streams).To(BeNumerically("<=", 5))
		Expect(held).To(HaveLen(streams))
		for _, r := range held {
			r.Done()
		}
		tokens, streams = p.held(backend)
		Expect(tokens).To(BeZero())
		Expect(streams).To(BeZero())
	})
})

// The pipeline releases what the admitter holds: the prefill at the first byte of body, everything when the
// request ends, whichever way it ends.
var _ = Describe("prospective admission in the pipeline", func() {
	body := `{"model":"` + testModel + `","messages":[{"role":"user","content":"` + strings.Repeat("a", 4000) + `"}]}`

	// Mutation that turns this red: drop onFirstBody from the recorder, or release it on WriteHeader instead.
	//
	// The gateway is served for real and read by a client, so each check runs after the client has actually
	// received what it is checking: the headers when Do returns, the first chunk when the read returns. Checking
	// when the upstream had merely sent its headers raced the gateway's own forwarding of them, and the
	// release-on-WriteHeader mutation stayed green.
	It("holds the prefill until the first body byte, and the stream until the request ends", func() {
		release, finish := make(chan struct{}), make(chan struct{})
		var once1, once2 sync.Once
		open := func() { once1.Do(func() { close(release) }) }
		end := func() { once2.Do(func() { close(finish) }) }
		up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			w.(http.Flusher).Flush()
			<-release
			_, _ = w.Write([]byte("data: {}\n\n"))
			w.(http.Flusher).Flush()
			<-finish
		}))
		defer up.Close()
		defer end()
		defer open()
		p := newProspectiveAdmitter(100000, 4)
		gw := httptest.NewServer(newAdmissionServer(up.URL, tierStandard, AdmissionProspective, p).Handler())
		defer gw.Close()
		u, _ := url.Parse(up.URL)
		ref := &BackendRef{URL: u}

		req, _ := http.NewRequest(http.MethodPost, gw.URL+"/v1/chat/completions", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+testKey)
		resp, err := http.DefaultClient.Do(req)
		Expect(err).NotTo(HaveOccurred())
		defer func() { _ = resp.Body.Close() }()
		Expect(resp.StatusCode).To(Equal(http.StatusOK))
		tokens, streams := p.held(ref)
		Expect(tokens).To(BeNumerically(">", 0), "the prefill was released on the status line, before any body byte")
		Expect(streams).To(Equal(1))

		open()
		buf := make([]byte, 1)
		_, err = resp.Body.Read(buf)
		Expect(err).NotTo(HaveOccurred())
		Eventually(func() int { t, _ := p.held(ref); return t }).Should(BeZero())
		_, streams = p.held(ref)
		Expect(streams).To(Equal(1), "the stream was released at the first byte rather than at the end")

		end()
		_, _ = io.ReadAll(resp.Body)
		Eventually(func() int { _, n := p.held(ref); return n }).Should(BeZero())
		tokens, _ = p.held(ref)
		Expect(tokens).To(BeZero())
	})

	// Mutation that turns this red: delete `defer res.Done()` from chatCompletions.
	It("releases everything when the upstream fails before answering", func() {
		up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			hj, _ := w.(http.Hijacker)
			conn, _, _ := hj.Hijack()
			_ = conn.Close()
		}))
		defer up.Close()
		p := newProspectiveAdmitter(100000, 4)
		s := newAdmissionServer(up.URL, tierStandard, AdmissionProspective, p)
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(body))
		Expect(rr.Code).To(BeNumerically(">=", 500))
		u, _ := url.Parse(up.URL)
		tokens, streams := p.held(&BackendRef{URL: u})
		Expect(tokens).To(BeZero())
		Expect(streams).To(BeZero())
	})

	It("releases everything when the client goes away mid-request", func() {
		started := make(chan struct{})
		up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// The body is read first: net/http notices a closed connection, and cancels r.Context(), only once
			// the handler has consumed the request body, so a handler that never reads it never sees the cancel.
			_, _ = io.ReadAll(r.Body)
			close(started)
			<-r.Context().Done()
		}))
		defer up.Close()
		p := newProspectiveAdmitter(100000, 4)
		s := newAdmissionServer(up.URL, tierStandard, AdmissionProspective, p)
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan struct{})
		go func() {
			defer close(done)
			s.Handler().ServeHTTP(httptest.NewRecorder(), authedRequest(body).WithContext(ctx))
		}()
		<-started
		cancel()
		Eventually(done, 5*time.Second).Should(BeClosed())
		u, _ := url.Parse(up.URL)
		tokens, streams := p.held(&BackendRef{URL: u})
		Expect(tokens).To(BeZero())
		Expect(streams).To(BeZero())
	})

	// Mutation that turns this red: make forwardTargets return every candidate.
	It("does not fall back from the backend a standard request reserved on, while premium still does", func() {
		served := 0
		var mu sync.Mutex
		live := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_, _ = io.ReadAll(r.Body)
			mu.Lock()
			served++
			mu.Unlock()
			w.WriteHeader(http.StatusOK)
		}))
		defer live.Close()
		dead := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
		deadURL, _ := url.Parse(dead.URL)
		dead.Close()
		liveURL, _ := url.Parse(live.URL)
		for _, tc := range []struct {
			tier   string
			served int
		}{{tierStandard, 0}, {tierPremium, 1}} {
			mu.Lock()
			served = 0
			mu.Unlock()
			p := newProspectiveAdmitter(100000, 4)
			s := newAdmissionServer("", tc.tier, AdmissionProspective, p)
			s.backendsOverride = func(string) []*url.URL { return []*url.URL{deadURL, liveURL} }
			rr := httptest.NewRecorder()
			s.Handler().ServeHTTP(rr, authedRequest(body))
			mu.Lock()
			Expect(served).To(Equal(tc.served), "tier %s", tc.tier)
			mu.Unlock()
			for _, u := range []*url.URL{deadURL, liveURL} {
				tokens, streams := p.held(&BackendRef{URL: u})
				Expect(tokens+streams).To(BeZero(), "tier %s left a hold on %s", tc.tier, u)
			}
		}
	})

	It("answers 413 to a request larger than the whole reservation", func() {
		up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) }))
		defer up.Close()
		s := newAdmissionServer(up.URL, tierStandard, AdmissionProspective, newProspectiveAdmitter(100, 4))
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(body))
		Expect(rr.Code).To(Equal(http.StatusRequestEntityTooLarge))
		Expect(rr.Header().Get(HeaderAdmissionReason)).To(Equal(reasonInputExceedsReservation))
	})
})
