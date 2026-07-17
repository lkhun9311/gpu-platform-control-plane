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

// An internal test: same package as the code under test, so unexported members such as chatCompletions
// and readModel are reachable, as are router_test.go's newSchemeForTest/policyFor helpers.
package gateway

import (
	"bufio"
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// Shared fixture coordinates. Repeating these literals per spec would let one drift out of step with
// another and break a lookup silently.
const (
	testGatewayNS = "gw"               // namespace holding the api-keys Secret
	testSecret    = "gateway-api-keys" // api-keys Secret name
	testTenant    = "team-vision"      // tenant the key below resolves to
	testKey       = "k1"               // a working API key
	testTenantNS  = "team-vision-ns"   // the policy's TargetNamespace
	testModel     = "llama-3"          // model the InferenceDeployment serves
)

// newProxyServer wires a Server complete enough to exercise the whole request pipeline:
// an api-keys Secret mapping "k1" to "team-vision", that tenant's GPUQuotaPolicy carrying
// TargetNamespace and rateLimit, and an InferenceDeployment serving testModel in that namespace.
//
// rpm is a parameter because only the rate-limit spec should drain its bucket; every other spec must be
// incapable of hitting a 429.
//
// The backendOverride hook (plan Task 6) exists because backendFor yields an in-cluster DNS address of
// the form http://<name>.<ns>.svc:<port>, which this process can never reach. Only the resolved address
// is swapped for the httptest server; a nil hook leaves the production backendFor path intact.
func newProxyServer(upstream string, rpm int32) *Server {
	// The Secret tenant.go's resolveTenant reads to map a key to a tenant.
	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: testSecret, Namespace: testGatewayNS},
		Data:       map[string][]byte{testKey: []byte(testTenant)},
	}
	// policyForTenant matches on Spec.Tenant; backendFor scopes its search by Spec.TargetNamespace.
	policy := &platformv1.GPUQuotaPolicy{
		ObjectMeta: metav1.ObjectMeta{Name: "vision-policy"},
		Spec: platformv1.GPUQuotaPolicySpec{
			Tenant:          testTenant,
			TargetNamespace: testTenantNS,
			// Burst 1 makes the boundary sharp: the first request passes, the next is refused.
			RateLimit: &platformv1.GPUQuotaRateLimit{RequestsPerMinute: rpm, Burst: 1},
		},
	}
	// Without this, testModel resolves to no route at all.
	infd := newInfD("llama", testTenantNS, testModel, 8080, time.Now())

	s := &Server{
		Client:       newRouterClient(secret, policy, infd),
		Namespace:    testGatewayNS,
		APIKeySecret: testSecret,
		buckets:      newBucketRegistry(),
	}
	// Only hook when an upstream is given; an empty string leaves the hook nil so the real backendFor
	// runs, which is how the unroutable-address cases are built.
	if upstream != "" {
		u, err := url.Parse(upstream)
		Expect(err).NotTo(HaveOccurred())
		s.backendOverride = func(string) *url.URL { return u }
	}
	// Readiness is orthogonal to the pipeline specs.
	s.markReady()
	return s
}

// authedRequest builds a POST carrying a valid bearer token.
func authedRequest(body string) *http.Request {
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+testKey)
	return r
}

// Specs for the pipeline's error-code mapping.
//
// The regression these prevent (design spec Error codes section): the pipeline runs auth, then policy,
// then rate limit, then body parse, then routing, and each stage's failure must map to a distinct code.
// Reorder it — rate limiting ahead of auth, say — and an unauthenticated request can drain someone
// else's bucket. Collapse the codes and a caller can no longer tell what to retry from what to fix.
var _ = Describe("chat completions pipeline", func() {
	It("returns 405 for a non-POST method on the completions path", func() {
		// Right path, wrong method. A mux that ignores the method sends this into the pipeline, where it
		// becomes a 401 or 400 and fails this spec.
		s := newProxyServer("", 600)
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/v1/chat/completions", nil))
		Expect(rr.Code).To(Equal(http.StatusMethodNotAllowed))
	})

	It("returns 404 for an unknown path", func() {
		s := newProxyServer("", 600)
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, httptest.NewRequest(http.MethodPost, "/v1/embeddings", nil))
		Expect(rr.Code).To(Equal(http.StatusNotFound))
	})

	It("returns 401 when the bearer token is missing", func() {
		s := newProxyServer("", 600)
		rr := httptest.NewRecorder()
		// Deliberately no Authorization header.
		r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"model":"llama-3"}`))
		s.Handler().ServeHTTP(rr, r)
		Expect(rr.Code).To(Equal(http.StatusUnauthorized))
	})

	It("returns 401 when the bearer token is unknown", func() {
		s := newProxyServer("", 600)
		rr := httptest.NewRecorder()
		r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"model":"llama-3"}`))
		// A key absent from the Secret: auth must turn on existence, not shape.
		r.Header.Set("Authorization", "Bearer nope")
		s.Handler().ServeHTTP(rr, r)
		Expect(rr.Code).To(Equal(http.StatusUnauthorized))
	})

	It("returns 403 when the tenant has no policy", func() {
		// A tenant that authenticates but has no GPUQuotaPolicy planted for it.
		secret := &corev1.Secret{
			ObjectMeta: metav1.ObjectMeta{Name: testSecret, Namespace: testGatewayNS},
			Data:       map[string][]byte{"k2": []byte("no-policy-tenant")},
		}
		s := &Server{
			Client:       newRouterClient(secret),
			Namespace:    testGatewayNS,
			APIKeySecret: testSecret,
			buckets:      newBucketRegistry(),
		}
		s.markReady()
		rr := httptest.NewRecorder()
		r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"model":"llama-3"}`))
		r.Header.Set("Authorization", "Bearer k2")
		s.Handler().ServeHTTP(rr, r)
		// 403, not 401: identity was established and authorization was not.
		Expect(rr.Code).To(Equal(http.StatusForbidden))
	})

	It("returns 429 once the tenant bucket is exhausted", func() {
		// The upstream's response is irrelevant here.
		up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusOK)
		}))
		defer up.Close()
		// rpm=1, burst=1: the first request drains the bucket, and refilling once a minute leaves no
		// chance of the next one slipping through.
		s := newProxyServer(up.URL, 1)

		first := httptest.NewRecorder()
		s.Handler().ServeHTTP(first, authedRequest(`{"model":"llama-3"}`))
		Expect(first.Code).To(Equal(http.StatusOK)) // a token was available

		second := httptest.NewRecorder()
		s.Handler().ServeHTTP(second, authedRequest(`{"model":"llama-3"}`))
		Expect(second.Code).To(Equal(http.StatusTooManyRequests)) // none left
	})

	It("returns 400 for a malformed JSON body", func() {
		s := newProxyServer("", 600)
		rr := httptest.NewRecorder()
		// Unterminated JSON.
		s.Handler().ServeHTTP(rr, authedRequest(`{"model":`))
		Expect(rr.Code).To(Equal(http.StatusBadRequest))
	})

	It("returns 400 when the model field is missing", func() {
		s := newProxyServer("", 600)
		rr := httptest.NewRecorder()
		// Valid JSON, no model key. Routing depends entirely on it, so there is nowhere to go.
		s.Handler().ServeHTTP(rr, authedRequest(`{"messages":[]}`))
		Expect(rr.Code).To(Equal(http.StatusBadRequest))
	})

	It("returns 404 for an unknown model", func() {
		// No hook, so the real backendFor runs and the name matches no planted InferenceDeployment.
		s := newProxyServer("", 600)
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(`{"model":"does-not-exist"}`))
		Expect(rr.Code).To(Equal(http.StatusNotFound))
	})

	It("proxies the upstream status and body on the happy path and sets X-Request-Id", func() {
		up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// The upstream must receive the id too; setting it only on the response makes logs unstitchable.
			Expect(r.Header.Get("X-Request-Id")).NotTo(BeEmpty())
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte(`{"id":"chatcmpl-1"}`))
		}))
		defer up.Close()
		s := newProxyServer(up.URL, 600)

		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(`{"model":"llama-3"}`))

		// The upstream's status must pass through rather than be flattened to 200.
		Expect(rr.Code).To(Equal(http.StatusCreated))
		Expect(rr.Body.String()).To(Equal(`{"id":"chatcmpl-1"}`))
		Expect(rr.Header().Get("X-Request-Id")).NotTo(BeEmpty())
	})

	It("reuses an inbound X-Request-Id instead of generating a new one", func() {
		up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusOK)
		}))
		defer up.Close()
		s := newProxyServer(up.URL, 600)

		rr := httptest.NewRecorder()
		r := authedRequest(`{"model":"llama-3"}`)
		r.Header.Set("X-Request-Id", "caller-supplied-id")
		s.Handler().ServeHTTP(rr, r)

		// A caller that already carries an id keeps it, or the trace breaks.
		Expect(rr.Header().Get("X-Request-Id")).To(Equal("caller-supplied-id"))
	})

	It("returns 502 when the upstream refuses the connection", func() {
		// Start and immediately close to obtain an address nobody listens on, so the dial is refused.
		up := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
		addr := up.URL
		up.Close()
		s := newProxyServer(addr, 600)

		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(`{"model":"llama-3"}`))
		// 502: the gateway is fine, the upstream is unreachable.
		Expect(rr.Code).To(Equal(http.StatusBadGateway))
	})

	// This spec pairs with the 502 one to pin both branches of proxy.go's ErrorHandler.
	//
	// Why 502 alone is not enough (design spec Error codes section): deleting the timeout check
	// (errors.As + ne.Timeout()) entirely leaves the 502 default in place, so the spec above still passes.
	// The 504 mapping is therefore a behavior that can vanish silently. Operationally the two are
	// different signals — 502 means the backend is gone, 504 means it is alive but not answering — and
	// losing the distinction sends incident response after the wrong thing.
	It("returns 504 when the upstream does not send response headers in time", func() {
		// An upstream that accepts the connection but sends no response headers: exactly what 504 denotes.
		release := make(chan struct{})
		up := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
			// Write nothing and hold. Returning would let Go write a 200 instead.
			// The time.After bound is here for the same reason as in the streaming specs: if the test
			// fails and release is never closed, this goroutine would keep up.Close() from returning and
			// hang the whole suite.
			select {
			case <-release:
			case <-time.After(10 * time.Second):
			}
		}))
		// Deferred calls run last-registered-first, so release closes and frees the handler before
		// up.Close() runs and blocks on it.
		defer up.Close()
		defer close(release)

		s := newProxyServer(up.URL, 600)
		// The 30s production default would cost this one spec 30 seconds; a short bound in tests only
		// drives the identical code path immediately.
		s.responseHeaderTimeout = 50 * time.Millisecond

		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(`{"model":"llama-3"}`))
		// The connection succeeded but no header arrived in time, so this is 504, not 502.
		Expect(rr.Code).To(Equal(http.StatusGatewayTimeout))
	})
})

// Streaming specs.
//
// The regression these prevent (design spec Request flow section): stream:true emits tokens as they are
// generated, and a proxy that buffers hands the client everything only once generation completes, so the
// full latency is felt. Status-and-body assertions cannot catch this, because the final result is
// identical either way — only the timing differs. So these specs assert the timing directly.
var _ = Describe("streaming", func() {
	It("delivers upstream chunks progressively instead of buffering them", func() {
		// release lets the test decide when the upstream may send its second chunk.
		// A struct{} channel carries no value; it signals the event itself.
		release := make(chan struct{})
		up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			// Write the first chunk and push it out immediately.
			_, _ = fmt.Fprintf(w, "data: chunk-1\n\n")
			w.(http.Flusher).Flush()
			// Block until the test confirms the first chunk arrived. This wait is the whole spec: if the
			// proxy buffers, the client never sees chunk-1 and never closes release.
			//
			// The time.After arm exists so a failing test does not strand this goroutine here, which would
			// hang httptest's Close and with it the suite. Failures should be fast and loud.
			select {
			case <-release:
			case <-time.After(10 * time.Second):
				return
			}
			_, _ = fmt.Fprintf(w, "data: chunk-2\n\n")
			w.(http.Flusher).Flush()
		}))
		defer up.Close()
		s := newProxyServer(up.URL, 600)

		// A real server, not httptest.NewRecorder: a recorder is an in-memory buffer with no notion of
		// when bytes arrived, so it cannot observe streaming at all. Only a real connection can show that
		// the first chunk lands before the handler returns.
		gw := httptest.NewServer(s.Handler())
		defer gw.Close()

		// A deadline on the request, so buffering fails the spec instead of hanging it: without one the
		// read below simply blocks forever and stalls the suite. With it, the read breaks at the deadline
		// and the failure is immediate and unambiguous.
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		req, err := http.NewRequestWithContext(ctx, http.MethodPost,
			gw.URL+"/v1/chat/completions", strings.NewReader(`{"model":"llama-3","stream":true}`))
		Expect(err).NotTo(HaveOccurred())
		req.Header.Set("Authorization", "Bearer "+testKey)

		resp, err := http.DefaultClient.Do(req)
		Expect(err).NotTo(HaveOccurred())
		defer func() { _ = resp.Body.Close() }()
		Expect(resp.StatusCode).To(Equal(http.StatusOK))

		// Reading the first line while the upstream still holds the second chunk, and its handler has not
		// returned, is precisely the evidence that bytes flowed without buffering.
		reader := bufio.NewReader(resp.Body)
		line, err := reader.ReadString('\n')
		Expect(err).NotTo(HaveOccurred())
		Expect(line).To(Equal("data: chunk-1\n"))

		// The first chunk landed, so let the upstream continue.
		close(release)

		// The second must follow, showing the stream was not severed mid-flight.
		Eventually(func() string {
			l, _ := reader.ReadString('\n')
			return l
		}, 5*time.Second).Should(Or(Equal("\n"), Equal("data: chunk-2\n")))
	})

	// This spec, and only this one, pins p.FlushInterval = -1.
	//
	// Why the SSE spec above cannot: httputil.ReverseProxy's flushInterval() overrides the configured
	// value and flushes immediately whenever
	//   1. the response Content-Type is text/event-stream, or
	//   2. the response Content-Length is unknown (res.ContentLength == -1, i.e. chunked streaming).
	// Real streaming responses always hit one of those, so with such a response the spec above passes even
	// with p.FlushInterval reset to 0 (verified). It pins that statusRecorder does not mask Flusher, but
	// not the interval itself.
	//
	// So this builds the one case where the setting is actually consulted: an upstream that declares a
	// Content-Length and still delivers the body in pieces. Neither override applies, so p.FlushInterval
	// governs, and at 0 the proxy batches the body and the first chunk misses its deadline.
	It("uses the configured flush interval when the upstream declares a content length", func() {
		release := make(chan struct{})
		up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			// A declared Content-Length plus a non-SSE Content-Type: both are needed for ReverseProxy to
			// consult our setting rather than override it.
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("Content-Length", "16") // "chunk-1\n" + "chunk-2\n"
			w.WriteHeader(http.StatusOK)
			_, _ = fmt.Fprintf(w, "chunk-1\n")
			w.(http.Flusher).Flush()
			select {
			case <-release:
			case <-time.After(10 * time.Second):
				return
			}
			_, _ = fmt.Fprintf(w, "chunk-2\n")
			w.(http.Flusher).Flush()
		}))
		defer up.Close()
		s := newProxyServer(up.URL, 600)

		gw := httptest.NewServer(s.Handler())
		defer gw.Close()

		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		req, err := http.NewRequestWithContext(ctx, http.MethodPost,
			gw.URL+"/v1/chat/completions", strings.NewReader(`{"model":"llama-3","stream":true}`))
		Expect(err).NotTo(HaveOccurred())
		req.Header.Set("Authorization", "Bearer "+testKey)

		resp, err := http.DefaultClient.Do(req)
		Expect(err).NotTo(HaveOccurred())
		defer func() { _ = resp.Body.Close() }()

		// At any interval other than -1 the first chunk stays held until the upstream handler returns, and
		// the upstream is waiting on release, so this read hits the deadline and fails.
		reader := bufio.NewReader(resp.Body)
		line, err := reader.ReadString('\n')
		Expect(err).NotTo(HaveOccurred())
		Expect(line).To(Equal("chunk-1\n"))

		close(release)
	})
})

// Pins the exposed metric names to the design contract.
//
// The regression this prevents (docs/05 Minimum metrics section): docs/05 pins the four series to the
// gpuaas_gateway_ prefix. Those names are a contract, not a label — dashboards and alert rules query the
// exact strings. Get the prefix wrong and the gateway runs perfectly and every test still passes; it
// surfaces only in production as "the graphs are empty", by which point it is too late. Before this spec
// existed the implementation used a gateway_ prefix and all 33 specs passed. So the doc's names are
// transcribed here verbatim, and the code failing to match the doc now fails immediately.
var _ = Describe("metric names", func() {
	It("exposes exactly the series docs/05 pins", func() {
		// Drive three real paths so all four series carry a value.
		//
		// The traffic is necessary: a labelled CounterVec/HistogramVec appears in a scrape only once a
		// label combination has actually been used. Registration alone exposes no name.

		// (1) A 200 -> requests_total, request_duration_seconds
		up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusOK)
		}))
		defer up.Close()
		ok := newProxyServer(up.URL, 600)
		ok.Handler().ServeHTTP(httptest.NewRecorder(), authedRequest(`{"model":"llama-3"}`))

		// (2) A 429 -> rate_limited_total
		limited := newProxyServer(up.URL, 1)
		limited.Handler().ServeHTTP(httptest.NewRecorder(), authedRequest(`{"model":"llama-3"}`))
		limited.Handler().ServeHTTP(httptest.NewRecorder(), authedRequest(`{"model":"llama-3"}`))

		// (3) A 502 -> upstream_errors_total
		dead := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
		addr := dead.URL
		dead.Close()
		broken := newProxyServer(addr, 600)
		broken.Handler().ServeHTTP(httptest.NewRecorder(), authedRequest(`{"model":"llama-3"}`))

		// Scrape /metrics on :8081 for real.
		rr := httptest.NewRecorder()
		ok.MetricsHandler().ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/metrics", nil))
		Expect(rr.Code).To(Equal(http.StatusOK))
		body := rr.Body.String()

		// Transcribed from the Minimum metrics section of docs/05.
		// Changing the code without changing the doc fails right here.
		Expect(body).To(ContainSubstring("gpuaas_gateway_requests_total"))
		Expect(body).To(ContainSubstring("gpuaas_gateway_request_duration_seconds_bucket"))
		Expect(body).To(ContainSubstring("gpuaas_gateway_rate_limited_total"))
		Expect(body).To(ContainSubstring("gpuaas_gateway_upstream_errors_total"))
	})
})

// Specs for readModel itself.
//
// Separate from the handler specs because those only observe a 400, never whether a consumed body is
// handed on intact. readModel consumes the body to peek at model, and failing to restore it leaves the
// upstream with an empty one — a bug the proxy's 200 would hide from every spec above.
var _ = Describe("readModel", func() {
	It("restores the body so the upstream still receives it intact", func() {
		body := `{"model":"llama-3","messages":[{"role":"user","content":"hi"}]}`
		r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))

		restored, model, err := readModel(r)
		Expect(err).NotTo(HaveOccurred())
		Expect(model).To(Equal("llama-3"))

		// The restored body must match the original byte for byte.
		buf := make([]byte, len(body))
		n, _ := restored.Read(buf)
		Expect(string(buf[:n])).To(Equal(body))
	})

	It("rejects a body that exceeds the size limit", func() {
		// A body past maxBodyBytes.
		//
		// Why the cap matters (design spec Error codes section): without it a malicious client can exhaust
		// gateway memory, and readModel — which buffers the body to find model — is exactly that vector.
		big := `{"model":"llama-3","pad":"` + strings.Repeat("a", maxBodyBytes) + `"}`
		r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(big))

		_, _, err := readModel(r)
		Expect(err).To(HaveOccurred())
	})
})

// A compile-time assertion: if the type stops satisfying the interface, this fails to build.
var _ client.Object = &platformv1.InferenceDeployment{}
