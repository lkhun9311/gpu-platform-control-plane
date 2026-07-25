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

// Package gateway implements the tenant-aware OpenAI-compatible serving gateway.
package gateway

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"sync/atomic"
	"time"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/rest"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

// ModelNameIndex is the cache field-index key over InferenceDeployment.spec.model.name.
//
// Routing resolves a requested model to its Service via this index, with no CR field selector and no per-request apiserver call.
const ModelNameIndex = ".spec.model.name"

// Server holds the gateway's shared dependencies and HTTP handlers.
type Server struct {
	// Client reads InferenceDeployment, GPUQuotaPolicy, and the api-keys Secret from the scoped cache.
	Client client.Client
	// Namespace and APIKeySecret locate the api-keys Secret used to resolve tenants.
	Namespace    string
	APIKeySecret string
	// ready flips true once the cache has synced, gating readiness.
	ready atomic.Bool
	// buckets holds the per-tenant token buckets, populated by cmd/gateway/main.go at assembly.
	//
	// Design rationale (design spec Components section): rate limiting only means anything if the remaining-token state survives across requests.
	//
	// A bucket built per request would always look full and never limit anything.
	//
	// So one process-wide registry holds them all.
	buckets *bucketRegistry
	// mode records which admission-control mode admitter implements, purely for the mode label on the admission metrics.
	//
	// It travels alongside admitter rather than being derived from it, since the two are set together by SetAdmitter and a type switch on admitter would need one arm per implementation anyway.
	//
	// The zero value "" is treated as AdmissionOff at the call site, matching admitter's nil default below.
	mode AdmissionMode
	// admitter runs the admission-control stage in chatCompletions, between backend resolution and the proxy handoff.
	//
	// nil (always so unless SetAdmitter is called) makes chatCompletions default to an offAdmitter, so a gateway that never configures admission control keeps its pre-admission-guard behavior exactly.
	admitter Admitter
	// backendOverride swaps out model-to-backend resolution in tests.
	//
	// nil (always so in production) makes resolveBackend use the real backendFor.
	//
	// Why the hook exists (plan Task 6).
	//
	// backendFor builds an in-cluster DNS address of the form http://<name>.<ns>.svc:<port>.
	//
	// No test process can reach that address.
	//
	// Overriding just the resolved address lets the whole pipeline run for real against an httptest server.
	//
	// The production path runs unchanged whenever the hook is nil.
	//
	// So this never bypasses production behavior.
	//
	// The hook returns a bare *url.URL rather than a *BackendRef, since tests only need the pipeline to reach an httptest server; resolveBackend wraps it into a BackendRef carrying just URL and Model.
	backendOverride func(model string) *url.URL
	// responseHeaderTimeout bounds the wait for upstream response headers.
	//
	// Zero selects proxy.go's defaultResponseHeaderTimeout (30s), so production leaves it unset.
	//
	// Why a field rather than a constant.
	//
	// This value directly sets how long a 504 takes to surface.
	//
	// Pinned at 30s, any spec covering the 504 mapping would have to wait 30s, so no such spec gets written and the branch goes unverified.
	//
	// An unverified 504 branch is the dangerous kind, since deleting it degrades silently to 502 rather than failing.
	//
	// A field lets tests drive the same code path with a short bound.
	responseHeaderTimeout time.Duration
}

// markReady marks the gateway ready to serve.
func (s *Server) markReady() { s.ready.Store(true) }

// MarkReady is the exported entry point for the binary to flip readiness after the cache's first sync.
func (s *Server) MarkReady() { s.markReady() }

// InitRateLimiter installs the per-tenant token bucket registry.
//
// Why this method exists.
//
// Both the buckets field and bucketRegistry are unexported, so cmd/gateway/main.go cannot populate them via a struct literal.
//
// Keeping the type unexported means the bucket internals can change without touching the assembly code.
func (s *Server) InitRateLimiter() { s.buckets = newBucketRegistry() }

// SetAdmitter installs the admission-control implementation and the mode label it reports on metrics.
//
// Why this method exists (mirrors InitRateLimiter above): admitter is unexported, so cmd/gateway/main.go cannot populate it via a struct literal.
//
// mode travels through the same call so the two can never drift out of step with each other.
func (s *Server) SetAdmitter(mode AdmissionMode, a Admitter) {
	s.mode = mode
	s.admitter = a
}

// readyz returns 200 only once the cache has synced, else 503 so the Pod stays out of Service endpoints.
func (s *Server) readyz(w http.ResponseWriter, _ *http.Request) {
	if !s.ready.Load() {
		http.Error(w, "cache not synced", http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusOK)
}

// fail ends the request with the given status code and records it.
//
// Why route this through one helper.
//
// Every failure branch must both write a code and count it.
//
// Routing them all through one helper is what keeps a branch from silently going unobserved.
//
// model may be empty: the auth, policy, and rate-limit stages run before the body is parsed, so no model is known yet.
//
// The empty label records exactly that.
//
// The response body is the OpenAI-style JSON envelope from writeJSONError, not plaintext, so every gateway failure looks the same to a client regardless of which pipeline stage produced it.
func (s *Server) fail(w http.ResponseWriter, tenant, model string, code int) {
	requests.WithLabelValues(tenant, model, strconv.Itoa(code)).Inc()
	writeJSONError(w, code, http.StatusText(code))
}

// failReason ends the request with status and an explicit machine-readable reason, then records it.
//
// Why this cannot just be fail(): the admission guard's reasons ("input_rate_limit" here, "kv_cache_pressure" in Task 3) are not derivable from the HTTP status the way fail()'s errorCode mapping assumes, since both share status 429.
//
// Retry-After is set to 5s (design spec Config and API section) because an admission-guard 429 is expected to clear once bucket capacity or backend pressure recovers, unlike the RPM limiter's 429, which carries no such hint.
func (s *Server) failReason(w http.ResponseWriter, tenant, model string, code int, reason string) {
	requests.WithLabelValues(tenant, model, strconv.Itoa(code)).Inc()
	w.Header().Set("Retry-After", "5")
	writeJSONErrorCode(w, code, reason, http.StatusText(code))
}

// resolveBackend resolves a model to its backend.
//
// It prefers the test hook over the real backendFor.
func (s *Server) resolveBackend(ctx context.Context, policy *platformv1.GPUQuotaPolicy, model string) (*BackendRef, error) {
	if s.backendOverride != nil {
		// The hook only fabricates a URL; Namespace/Name/Port stay zero-valued, since tests using it only need the pipeline to reach an httptest server, not a real backend's identity.
		return &BackendRef{URL: s.backendOverride(model), Model: model}, nil
	}
	return s.backendFor(ctx, policy, model)
}

// chatCompletions serves the OpenAI-compatible chat completions pipeline.
//
// The ordering is the point (design spec Request flow section).
//
//  1. request id: every log line and the upstream call share one id, or tracing breaks.
//  2. auth: an unidentified request stops here (401).
//  3. policy: identified but unauthorized stops here (403).
//  4. rate limit: over its share stops here (429).
//  5. body parse: extract the model (400).
//  6. routing: resolve the model to a backend (404).
//  7. admission: off/static-cap/kv-aware decide whether the request proceeds (429).
//  8. proxy: hand off upstream (502/504, or whatever the upstream returns).
//
// Why auth precedes rate limiting.
//
// The limiter keys on tenant and cannot judge without one.
//
// Limiting anonymous traffic would also let an attacker drain someone else's bucket and stall that tenant.
//
// Why rate limiting precedes body parsing.
//
// Parsing buffers up to 1MB.
//
// Reading the body of a request destined for rejection would let a flooding client keep spending gateway memory.
//
// So rejections happen before that cost is paid.
func (s *Server) chatCompletions(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	// 1. request id: reuse a caller-supplied id when present.
	//
	// Why an incoming id is reused.
	//
	// Keeping it is what stitches the caller's traces and ours together.
	//
	// Always minting a new one would sever that link.
	rid := r.Header.Get("X-Request-Id")
	if rid == "" {
		rid = newRequestID()
	}
	// Set it on both the response and the upstream request.
	//
	// Response-only leaves the request unfindable in upstream logs, and request-only leaves the client unable to quote its own id.
	w.Header().Set("X-Request-Id", rid)
	r.Header.Set("X-Request-Id", rid)

	// 2. Resolve the API key to a tenant.
	tenant, ok := s.resolveTenant(ctx, r)
	if !ok {
		s.fail(w, "", "", http.StatusUnauthorized)
		return
	}

	// 3. Find the tenant's GPUQuotaPolicy.
	//
	// errors.Is separates "no policy" (an ordinary outcome) from a broken read.
	//
	// Conflating them would show an apiserver outage as a 403 and send operators hunting through policy config.
	policy, err := s.policyForTenant(ctx, tenant)
	if errors.Is(err, ErrNoPolicy) {
		s.fail(w, tenant, "", http.StatusForbidden)
		return
	}
	if err != nil {
		// The lookup itself failed.
		//
		// This is not the client's fault.
		log.FromContext(ctx).Error(err, "policy lookup failed", "tenant", tenant, "request_id", rid)
		s.fail(w, tenant, "", http.StatusBadGateway)
		return
	}

	// 4. Take a token from the tenant's bucket.
	if !s.buckets.Allow(tenant, policy.Spec.RateLimit) {
		// Counted separately from requests{code="429"}; the two answer different questions.
		rateLimited.WithLabelValues(tenant).Inc()
		s.fail(w, tenant, "", http.StatusTooManyRequests)
		return
	}

	// 5. Extract admission metadata and recover the body.
	//
	// Malformed JSON, a missing model, and an oversized body all land here.
	//
	// All three are the client's to fix.
	body, meta, err := readRequestMeta(r)
	if err != nil {
		s.fail(w, tenant, "", http.StatusBadRequest)
		return
	}
	// Put the restored body back, or the upstream receives an empty one.
	r.Body = body

	// 6. Resolve the model to a backend.
	target, err := s.resolveBackend(ctx, policy, meta.Model)
	if errors.Is(err, ErrNoRoute) {
		// An ordinary "no such model" outcome.
		s.fail(w, tenant, meta.Model, http.StatusNotFound)
		return
	}
	if err != nil {
		log.FromContext(ctx).Error(err, "backend lookup failed", "tenant", tenant, "model", meta.Model, "request_id", rid)
		s.fail(w, tenant, meta.Model, http.StatusBadGateway)
		return
	}

	// 7. Admission control: decide whether the request may proceed.
	//
	// Design rationale (design spec Pipeline placement section): this sits after backend resolution and before the proxy handoff, so an unroutable model (404, step 6) never consumes admission budget, while every request that will actually reach a backend is metered before it does.
	//
	// tier comes from the policy already fetched in step 3, not from the request, since tier is a property of the tenant's contract rather than something a caller can assert about itself.
	tier := tierForPolicy(policy)
	admitter := s.admitter
	if admitter == nil {
		// SetAdmitter was never called, so behave exactly as if the guard did not exist.
		admitter = offAdmitter{}
	}
	mode := s.mode
	if mode == "" {
		mode = AdmissionOff
	}
	admit, reason := admitter.Admit(ctx, meta, target, tenant, tier)
	decision := "admit"
	if !admit {
		decision = "reject"
	}
	// Recorded for every request, admitted or not, so the admit rate and admitted-vs-offered token fraction can both be read straight off these two series without diffing against requests_total.
	admissionDecisions.WithLabelValues(string(mode), tenant, meta.Model, decision, reason).Inc()
	admissionInputTokens.WithLabelValues(string(mode), tenant, decision).Add(float64(meta.EstInputTokens))
	if !admit {
		s.failReason(w, tenant, meta.Model, http.StatusTooManyRequests, reason)
		return
	}

	// 8. From here the response is the upstream's, passed through rather than composed.
	start := time.Now()
	rec := &statusRecorder{ResponseWriter: w, code: http.StatusOK}
	newReverseProxy(target.URL, s.responseHeaderTimeout, func(c int) {
		upstreamErrors.WithLabelValues(tenant, meta.Model).Inc()
		// ErrorHandler writes its code via writeJSONError, which may not pass through statusRecorder, so record it here to keep the metric consistent with what the client actually received.
		rec.code = c
	}).ServeHTTP(rec, r)

	// ServeHTTP returning means the response finished sending (for a stream, that the stream closed).
	//
	// This therefore measures the whole request rather than time-to-first-byte.
	requests.WithLabelValues(tenant, meta.Model, strconv.Itoa(rec.code)).Inc()
	requestDuration.WithLabelValues(tenant, meta.Model).Observe(time.Since(start).Seconds())
}

// Handler is the serving mux on :8080.
//
// Why the method is part of the pattern (design spec Error codes section).
//
// Since Go 1.22 a ServeMux pattern may name a method.
//
// The mux therefore answers 405 for a right-path/wrong-method request and 404 for an unregistered path, without either being hand-written.
//
// Registering the bare path would let a GET fall into the pipeline and surface as 401 or 400 where 405 belongs.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/chat/completions", s.chatCompletions)
	mux.HandleFunc("/readyz", s.readyz)
	return mux
}

// MetricsHandler is the observability mux on :8081.
//
// Design rationale (design spec Components section): user traffic (:8080) and observability (:8081) are split across ports so /metrics stays cluster-internal.
//
// Per-tenant usage metrics would let a user infer other tenants' activity, so the split is mandatory.
//
// Both muxes serve /readyz so a probe on either port gets the same answer.
func (s *Server) MetricsHandler() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("/metrics", metricsHTTPHandler())
	mux.HandleFunc("/readyz", s.readyz)
	return mux
}

// NewCache builds a scoped cache over the gateway's read set plus a delegating client that reads the cache and writes the apiserver.
//
// It registers the model-name field indexer used for routing.
func NewCache(ctx context.Context, cfg *rest.Config, scheme *runtime.Scheme, namespace string) (cache.Cache, client.Client, error) {
	ca, err := cache.New(cfg, cache.Options{
		Scheme:           scheme,
		DefaultTransform: cache.TransformStripManagedFields(),
		// Watch Secrets only in the namespace the gateway runs in.
		//
		// Why the scope matters (it is what the design spec's Components section means by "scoped cache").
		//
		// controller-runtime caches every namespace when no scope is given (cache.Options docs: "An empty map ... means that all namespaces will be cached").
		//
		// Unscoped, the gateway would hold every Secret in the cluster in memory.
		//
		// That includes other components' credentials and TLS private keys.
		//
		// It is the one component taking external traffic directly, so a compromise would leak all of it.
		//
		// It needs exactly one Secret, so the watch is confined to that Secret's namespace.
		//
		// This must stay in step with RBAC.
		//
		// config/gateway/rbac.yaml grants secrets reads through a Role in the gateway namespace only.
		//
		// Without this scope the cache tries to list/watch secrets in every namespace, is denied, and never syncs, so readiness never opens.
		//
		// The gateway then serves nothing.
		//
		// InferenceDeployment is deliberately absent.
		//
		// Tenants live in different namespaces and the gateway must serve any of them, so its scope cannot be narrowed ahead of time.
		//
		// GPUQuotaPolicy is cluster-scoped and has no namespace to begin with.
		ByObject: map[client.Object]cache.ByObject{
			&corev1.Secret{}: {
				Namespaces: map[string]cache.Config{
					namespace: {},
				},
			},
		},
	})
	if err != nil {
		return nil, nil, fmt.Errorf("new cache: %w", err)
	}
	// Index InferenceDeployment by its served model name for routing lookups.
	if err := ca.IndexField(ctx, &platformv1.InferenceDeployment{}, ModelNameIndex, func(o client.Object) []string {
		return []string{o.(*platformv1.InferenceDeployment).Spec.Model.Name}
	}); err != nil {
		return nil, nil, fmt.Errorf("index %s: %w", ModelNameIndex, err)
	}
	cl, err := client.New(cfg, client.Options{Scheme: scheme, Cache: &client.CacheOptions{Reader: ca}})
	if err != nil {
		return nil, nil, fmt.Errorf("new delegating client: %w", err)
	}
	return ca, cl, nil
}
