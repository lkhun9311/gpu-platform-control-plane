package gateway

import (
	"context"
	"net/http"
	"sync/atomic"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"sigs.k8s.io/controller-runtime/pkg/metrics"
)

// A response that has started can still end before its upstream finishes it, and under a real http.Server ReverseProxy
// says so only by panicking with http.ErrAbortHandler when copying the body fails (issue #571).
// These name the three ways that happens.
const (
	// cutShortUpstream is an upstream that stopped mid-response: the engine died or dropped the connection.
	cutShortUpstream = "upstream_aborted"
	// cutShortClient is a client that went away mid-response.
	cutShortClient = "client_gone"
	// cutShortIdle is the gateway's own idle bound ending a response its upstream left silent.
	cutShortIdle = "idle_timeout"
)

// responsesCutShort counts started responses that ended before their upstream finished them, by cause.
// requests_total cannot carry this: the status line was already sent, so those requests count under the 200 they had.
var responsesCutShort = promauto.With(metrics.Registry).NewCounterVec(prometheus.CounterOpts{
	Name: metricPrefix + "responses_cut_short_total",
	Help: "Responses that had started and ended before their upstream finished them, by tenant, model and cause.",
}, []string{"tenant", "model", "cause"})

// cutShortCause runs proxy and reports why the response it was streaming ended early, or "" when it did not.
// Only http.ErrAbortHandler is caught; any other panic is a bug and continues to unwind.
// The idle bound cancels only the attempt, never the client's own context, so an idle cut is not mistaken for a client
// that left. It is checked first for the rarer case of a client leaving after the bound already fired, where the
// bound is what ended the stream.
func cutShortCause(proxy func(), client context.Context, idleExpired *atomic.Bool) (cause string) {
	defer func() {
		p := recover()
		if p == nil {
			return
		}
		if p != http.ErrAbortHandler { //nolint:errorlint // ReverseProxy panics with this exact sentinel value
			panic(p)
		}
		switch {
		case idleExpired.Load():
			cause = cutShortIdle
		case client.Err() != nil:
			cause = cutShortClient
		default:
			cause = cutShortUpstream
		}
	}()
	proxy()
	return ""
}

// countCutShort counts a response cut short; it does nothing for one that ran to its end.
func countCutShort(tenant, model, cause string) {
	if cause != "" {
		responsesCutShort.WithLabelValues(tenant, model, cause).Inc()
	}
}

// abortIfCutShort raises the abort again once the bookkeeping is done, so net/http still closes the connection without
// a clean end; returning normally would finish the chunked body and hand the client a truncated answer as a whole one.
func abortIfCutShort(cause string) {
	if cause != "" {
		panic(http.ErrAbortHandler)
	}
}
