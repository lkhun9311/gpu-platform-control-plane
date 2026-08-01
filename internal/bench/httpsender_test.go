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

package bench

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("HTTPSender", func() {
	It("records first-token, end, and output tokens from a streaming response", func() {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			Expect(r.Header.Get("Authorization")).To(Equal("Bearer premium-key"))
			w.Header().Set("Content-Type", "text/event-stream")
			f := w.(http.Flusher)
			for i := 0; i < 3; i++ {
				fmt.Fprintf(w, "data: {\"choices\":[{\"delta\":{\"content\":\"tok\"}}]}\n\n")
				f.Flush()
				time.Sleep(2 * time.Millisecond)
			}
			fmt.Fprint(w, "data: [DONE]\n\n")
			f.Flush()
		}))
		defer srv.Close()

		sender := NewHTTPSender(srv.URL, "llama-3-8b", map[string]string{"premium-1": "premium-key"}, 5*time.Second)
		res := sender.Send(context.Background(), TraceRow{Tenant: "premium-1", PromptLenChars: 100, MaxOutputTokens: 8}, time.Now().UnixNano())

		Expect(res.HTTPStatus).To(Equal(200))
		Expect(res.ErrorKind).To(BeEmpty())
		Expect(res.OutputTokens).To(Equal(3))
		Expect(res.FirstTokenUnixNanos).To(BeNumerically(">", 0))
		Expect(res.EndUnixNanos).To(BeNumerically(">=", res.FirstTokenUnixNanos))
	})

	It("records a 429 as a rejection, not a completed request", func() {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusTooManyRequests)
			fmt.Fprint(w, `{"error":{"code":"kv_cache_pressure"}}`)
		}))
		defer srv.Close()

		sender := NewHTTPSender(srv.URL, "m", nil, 5*time.Second)
		res := sender.Send(context.Background(), TraceRow{Tenant: "standard-noisy", PromptLenChars: 40000, MaxOutputTokens: 8}, time.Now().UnixNano())

		Expect(res.HTTPStatus).To(Equal(429))
		Expect(res.ErrorKind).To(Equal("rejected"))
		Expect(res.FirstTokenUnixNanos).To(BeZero())
	})

	It("records a slow response past the timeout as a timeout", func() {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			time.Sleep(200 * time.Millisecond)
			w.Header().Set("Content-Type", "text/event-stream")
			fmt.Fprint(w, "data: [DONE]\n\n")
		}))
		defer srv.Close()

		sender := NewHTTPSender(srv.URL, "m", nil, 30*time.Millisecond)
		res := sender.Send(context.Background(), TraceRow{Tenant: "premium-1", PromptLenChars: 100, MaxOutputTokens: 8}, time.Now().UnixNano())

		Expect(res.ErrorKind).To(Equal("timeout"))
	})
})
