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

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	// metrics is controller-runtime's global registry, which this project's controllers already use.
	"sigs.k8s.io/controller-runtime/pkg/metrics"
)

// metricPrefix namespaces every series this component exposes.
//
// This string is a contract, not a preference (docs/05 Minimum metrics section).
//
// The doc pins the four series to gpuaas_gateway_, and dashboards and alert rules query those exact strings.
//
// Change it and the gateway still works perfectly while the graphs go empty, with nothing in the code to show why.
//
// The "metric names" spec in proxy_test.go transcribes the doc's names to hold this constant in place.
//
// The reason for having a prefix at all is Prometheus convention.
//
// It selects the whole component's series with one match and keeps these names from colliding with the controllers' metrics on the same registry.
const metricPrefix = "gpuaas_gateway_"

// The four series the gateway exposes.
//
// Label rationale (design spec Observability section).
//
// tenant and model make "who used which model, how much" directly aggregatable, which is the input to billing and capacity planning.
//
// Unbounded-cardinality values (request ids, API keys) are never labels, since they would explode the series count.
var (
	// requests counts handled requests by tenant, model, and status code.
	//
	// The code label separates success from failure in one series, answering "are 429s spiking?" directly.
	requests = promauto.With(metrics.Registry).NewCounterVec(
		prometheus.CounterOpts{
			Name: metricPrefix + "requests_total",
			Help: "Total gateway requests by tenant, model, and response code.",
		},
		[]string{"tenant", "model", "code"},
	)

	// requestDuration observes request latency in seconds.
	//
	// A histogram rather than a counter: an average hides "mostly fast, a few terrible", and latency SLOs are always stated as quantiles, which need the distribution.
	//
	// The buckets are custom because DefBuckets tops out at 10s, tuned for ordinary web requests.
	//
	// Token generation routinely runs far longer, so the range extends to 120s; too low a ceiling piles every slow request into +Inf and makes p99 uncomputable.
	requestDuration = promauto.With(metrics.Registry).NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    metricPrefix + "request_duration_seconds",
			Help:    "Gateway request duration in seconds by tenant and model.",
			Buckets: []float64{0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120},
		},
		[]string{"tenant", "model"},
	)

	// rateLimited counts requests rejected by the limiter, by tenant.
	//
	// It overlaps requests{code="429"} by value but exists for a distinct question: which tenant is exceeding its share.
	//
	// With tenant as the only label it feeds an alert rule without summing away model.
	//
	// There is no model label because the limiter runs before the body is parsed (see the ordering in chatCompletions), so the model is not yet known at that point.
	rateLimited = promauto.With(metrics.Registry).NewCounterVec(
		prometheus.CounterOpts{
			Name: metricPrefix + "rate_limited_total",
			Help: "Total requests rejected by the per-tenant rate limiter.",
		},
		[]string{"tenant"},
	)

	// upstreamErrors counts failures to reach the backend, by tenant and model.
	//
	// Design rationale (design spec Observability section).
	//
	// 502/504 are the backend's fault, not the gateway's.
	//
	// Separating them answers "do I look at the gateway or the model server?" immediately.
	upstreamErrors = promauto.With(metrics.Registry).NewCounterVec(
		prometheus.CounterOpts{
			Name: metricPrefix + "upstream_errors_total",
			Help: "Total upstream connection failures by tenant and model.",
		},
		[]string{"tenant", "model"},
	)

	// admissionDecisions counts every admission-control decision by mode, tenant, model, decision, and reason.
	//
	// Design rationale (design spec Metrics section): decision is "admit" or "reject", and reason is empty on admit and the rejection's machine-readable code (e.g. "input_rate_limit") on reject.
	//
	// Every request records here, admitted or not, and for every mode including "off".
	//
	// Recording only rejections would leave no way to compute an admit rate without also diffing against requests_total, which carries a different set of labels and is not guaranteed to line up 1:1 with admission decisions.
	admissionDecisions = promauto.With(metrics.Registry).NewCounterVec(
		prometheus.CounterOpts{
			Name: metricPrefix + "admission_decisions_total",
			Help: "Total admission-control decisions by mode, tenant, model, decision, and reason.",
		},
		[]string{"mode", "tenant", "model", "decision", "reason"},
	)

	// admissionInputTokens accumulates each request's estimated input tokens by mode, tenant, and decision.
	//
	// Design rationale (design spec Metrics section, "Decision counts alone cannot prove admission matching; the input-token counter is mandatory."): the static-cap and kv-aware arms are compared by admitted-work fraction (admitted input tokens over offered input tokens), a ratio decision counts cannot express since a decision counts requests, not the token volume each one carries.
	admissionInputTokens = promauto.With(metrics.Registry).NewCounterVec(
		prometheus.CounterOpts{
			Name: metricPrefix + "admission_input_tokens_total",
			Help: "Total estimated input tokens seen by admission control by mode, tenant, and decision.",
		},
		[]string{"mode", "tenant", "decision"},
	)

	// admissionGuardEngaged reports the kv-aware guard's current pressure state per backend: 1
	// while ENGAGED, 0 while RELEASED.
	//
	// Design rationale (design spec Metrics section, arm C): a gauge rather than a counter,
	// since this is a current state, not an accumulating count. It reflects the pressure state
	// machine's internal engaged flag exactly as last published, regardless of telemetry
	// freshness; gpuaas_gateway_backend_telemetry_fresh is the series that tells a reader
	// whether this value (and the two below) are still trustworthy.
	admissionGuardEngaged = promauto.With(metrics.Registry).NewGaugeVec(
		prometheus.GaugeOpts{
			Name: metricPrefix + "admission_guard_engaged",
			Help: "Whether the kv-aware admission guard is currently ENGAGED (1) or RELEASED (0) for a backend.",
		},
		[]string{"namespace", "backend", "model"},
	)

	// backendKVCacheUsage is the last successfully scraped KV-cache usage fraction for a
	// backend, in [0,1].
	//
	// It holds its last value across a scrape failure rather than resetting to 0, matching
	// "last scraped value" in the design spec's Metrics section; telemetry_fresh is what tells a
	// reader the value may now be stale.
	backendKVCacheUsage = promauto.With(metrics.Registry).NewGaugeVec(
		prometheus.GaugeOpts{
			Name: metricPrefix + "backend_kv_cache_usage",
			Help: "Last scraped vLLM KV-cache usage fraction for a backend, in [0,1].",
		},
		[]string{"namespace", "backend", "model"},
	)

	// backendWaitingRequests is the last successfully scraped waiting-queue depth for a backend.
	backendWaitingRequests = promauto.With(metrics.Registry).NewGaugeVec(
		prometheus.GaugeOpts{
			Name: metricPrefix + "backend_waiting_requests",
			Help: "Last scraped vLLM waiting-queue depth for a backend.",
		},
		[]string{"namespace", "backend", "model"},
	)

	// backendTelemetryFresh reports whether a backend's kv-aware telemetry is within
	// maxStaleness of now: 1 fresh, 0 stale (design spec Arm C section, "Expose telemetry
	// freshness").
	//
	// This is the series that distinguishes a genuinely quiet backend (fresh, cacheUsage low)
	// from one the scraper has simply lost contact with (stale, cacheUsage frozen at whatever it
	// last read); admissionGuardEngaged and the two gauges above cannot tell those apart on
	// their own.
	backendTelemetryFresh = promauto.With(metrics.Registry).NewGaugeVec(
		prometheus.GaugeOpts{
			Name: metricPrefix + "backend_telemetry_fresh",
			Help: "Whether a backend's kv-aware telemetry is fresh (1) or stale (0), i.e. within maxStaleness of the last successful scrape.",
		},
		[]string{"namespace", "backend"},
	)

	// backendScrapeErrors counts failed /metrics scrapes by backend.
	//
	// A rising rate here alongside backendTelemetryFresh dropping to 0 is what operationally
	// distinguishes "the backend is fine but the scrape target/network is broken" from "the
	// backend, and everything talking to it, is just quiet".
	backendScrapeErrors = promauto.With(metrics.Registry).NewCounterVec(
		prometheus.CounterOpts{
			Name: metricPrefix + "backend_scrape_errors_total",
			Help: "Total failed vLLM /metrics scrapes by backend.",
		},
		[]string{"namespace", "backend"},
	)
)

// metricsHTTPHandler exposes the registered series.
//
// HandlerFor is bound to controller-runtime's registry deliberately: the argument-less promhttp.Handler() serves Prometheus's global default registry, where none of the series above are registered.
func metricsHTTPHandler() http.Handler {
	return promhttp.HandlerFor(metrics.Registry, promhttp.HandlerOpts{})
}
