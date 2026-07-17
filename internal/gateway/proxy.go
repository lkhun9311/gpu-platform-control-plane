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
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strconv"
	"time"
)

// maxBodyBytes caps how much of a request body readModel will buffer.
//
// Design rationale (design spec Error codes section): readModel holds the body in memory to look at
// the model field, so an unbounded body is a memory-exhaustion vector. 1MB is far above a normal
// chat completions request (tens of KB) while keeping a single request unable to threaten the process.
const maxBodyBytes = 1 << 20 // 1MB

// ErrNoModel is the sentinel reported when the body carries no model field.
// It mirrors ErrNoPolicy in ratelimit.go and ErrNoRoute in router.go so callers can match on it exactly.
var ErrNoModel = errors.New("request body has no model field")

// newRequestID returns a random hex identifier for a single request.
//
// crypto/rand rather than math/rand: math/rand is deterministic from its seed, so separate Pods can
// emit the same id. Colliding ids merge unrelated requests when logs are stitched together, which
// defeats the point of the id. On the (practically unreachable) error path we fall back to a
// timestamp-derived value, since a weaker id still beats no id at all.
func newRequestID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "req-" + strconv.FormatInt(time.Now().UnixNano(), 16)
	}
	return hex.EncodeToString(b)
}

// readModel extracts the model name from the request body and returns the body restored for replay.
// It returns the restored body, the model name, and an error.
//
// The restore is what makes this safe: r.Body is a one-shot stream, so reading it here would leave
// the proxy nothing to forward and the model server would see an empty body. The gateway would pass
// that failure through verbatim, hiding the fact that the gateway caused it.
//
// Only the model field is decoded. The gateway routes on model and must forward everything else
// untouched; modelling the whole schema would mean editing the gateway whenever the OpenAI API grows
// a field, and would silently drop any field not yet declared.
func readModel(r *http.Request) (io.ReadCloser, string, error) {
	// The nil first argument means MaxBytesReader will not write a response itself; the caller owns
	// the status code. Exceeding the cap surfaces as a read error, which the caller maps to 400.
	limited := http.MaxBytesReader(nil, r.Body, maxBodyBytes)
	buf, err := io.ReadAll(limited)
	if err != nil {
		return nil, "", err
	}

	var probe struct {
		Model string `json:"model"`
	}
	if err := json.Unmarshal(buf, &probe); err != nil {
		return nil, "", err
	}
	if probe.Model == "" {
		return nil, "", ErrNoModel
	}

	// Hand back a reader over the bytes just consumed, byte-for-byte identical to the original.
	return io.NopCloser(bytes.NewReader(buf)), probe.Model, nil
}

// statusRecorder wraps a ResponseWriter to capture the status code the proxy actually wrote.
// http.ResponseWriter offers no way to read back the code, and metrics need it after the response is sent.
type statusRecorder struct {
	http.ResponseWriter
	// code defaults to 200 because a handler that calls Write without WriteHeader implicitly sends 200.
	code int
}

// WriteHeader records the status code and forwards it to the wrapped writer.
func (rec *statusRecorder) WriteHeader(c int) {
	rec.code = c
	rec.ResponseWriter.WriteHeader(c)
}

// Flush forwards to the wrapped writer's Flusher when it has one.
//
// This method is load-bearing (design spec Request flow section): embedding only promotes the methods
// declared on the embedded interface, and http.ResponseWriter has no Flush. Without this, the wrapper
// fails the http.Flusher check that ReverseProxy makes before streaming, and the proxy silently
// buffers regardless of FlushInterval. Wrapping the writer would kill streaming on its own.
func (rec *statusRecorder) Flush() {
	if f, ok := rec.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// defaultResponseHeaderTimeout bounds the wait for upstream response headers in production.
//
// 30s is the compromise: a model server can spend seconds on prefill before the first token, so a short
// cap severs healthy requests, while an unbounded wait lets hung requests pile up and exhaust connections.
const defaultResponseHeaderTimeout = 30 * time.Second

// newReverseProxy returns a streaming-capable reverse proxy to target, reporting 502/504 through onErr.
//
// A zero responseHeaderTimeout means "unset" and selects defaultResponseHeaderTimeout. Zero cannot be
// passed through as-is: http.Transport reads it as "no limit", which is the exact failure being bounded.
func newReverseProxy(target *url.URL, responseHeaderTimeout time.Duration, onErr func(code int)) *httputil.ReverseProxy {
	p := httputil.NewSingleHostReverseProxy(target)
	if responseHeaderTimeout == 0 {
		responseHeaderTimeout = defaultResponseHeaderTimeout
	}

	// FlushInterval = -1 means "flush immediately, never buffer".
	//
	// Design rationale (design spec Request flow section): stream:true emits tokens one at a time, and a
	// proxy that batches them hands the client everything only once generation finishes, which defeats streaming.
	//
	// The setting's real reach is narrower than it looks, and it is worth knowing exactly.
	// httputil.ReverseProxy's flushInterval() ignores this value and flushes immediately anyway when:
	//   1. the response Content-Type is text/event-stream, or
	//   2. the response Content-Length is unknown (res.ContentLength == -1, i.e. chunked streaming).
	// Real streaming responses almost always hit one of those, so for them this line changes nothing.
	// It only changes behavior when an upstream declares a Content-Length and still delivers the body in
	// pieces. The "uses the configured flush interval..." spec in proxy_test.go pins exactly that case.
	//
	// It stays despite the narrow reach because relying on Go's auto-detection would leave our intent
	// unstated: this gateway buffers no response, and that intent belongs in the code.
	p.FlushInterval = -1

	// Transport tunes the outbound connection.
	//
	// Design rationale (design spec Request flow section): http.DefaultTransport has no response-header
	// timeout, so a model server that accepts a connection and never answers pins the request forever;
	// enough of those exhaust the gateway's connections and memory.
	//
	// There is deliberately no overall Timeout: a healthy stream legitimately runs for minutes, and an
	// overall cap would sever it. Only the wait for the first response header is bounded; the time the
	// body spends streaming is not.
	p.Transport = &http.Transport{
		// ResponseHeaderTimeout bounds the wait for response headers; exceeding it becomes a timeout error, mapped to 504 below.
		ResponseHeaderTimeout: responseHeaderTimeout,
		// IdleConnTimeout keeps connections warm for reuse, avoiding a TCP handshake per request.
		IdleConnTimeout: 90 * time.Second,
	}

	// ErrorHandler runs when the upstream could not be reached.
	//
	// Design rationale (design spec Error codes section): the default handler always writes 502, collapsing
	// "connection refused" and "no response in time" into one code. They are different operational signals —
	// 502 means the backend Pod is gone or the Service is miswired, 504 means it is alive but hung or slow —
	// and they call for different responses, so they get different codes.
	p.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, err error) {
		// Connection refused, DNS failure, and similar land here.
		code := http.StatusBadGateway
		// errors.As walks the error chain, so a timeout wrapped with %w is still detected;
		// a plain type assertion would miss it.
		var ne net.Error
		if errors.As(err, &ne) && ne.Timeout() {
			code = http.StatusGatewayTimeout
		}
		onErr(code)
		http.Error(w, err.Error(), code)
	}

	return p
}
