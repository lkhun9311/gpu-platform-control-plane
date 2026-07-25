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

// maxBodyBytes caps how much of a request body readRequestMeta will buffer.
//
// Design rationale (design spec Error codes section): readRequestMeta holds the body in memory to look at the model field, so an unbounded body is a memory-exhaustion vector.
//
// 1MB is far above a normal chat completions request (tens of KB) while keeping a single request unable to threaten the process.
const maxBodyBytes = 1 << 20 // 1MB

// ErrNoModel is the sentinel reported when the body carries no model field.
//
// It mirrors ErrNoPolicy in ratelimit.go and ErrNoRoute in router.go so callers can match on it exactly.
var ErrNoModel = errors.New("request body has no model field")

// RequestMeta is the admission-relevant metadata extracted from a chat-completions request body.
//
// The admission guard (a later task) reads these fields to decide whether to admit a request.
//
// This task only extracts them; nothing here yet changes what gets admitted.
type RequestMeta struct {
	// Model is the requested model name, already validated non-empty by readRequestMeta.
	Model string
	// EstInputTokens is a conservative, text-only estimate of the prompt's input tokens.
	//
	// It is the ceiling of the total prompt byte length divided by 4, never an exact count.
	//
	// Byte length is used deliberately: it equals the character count for ASCII and over-counts for multibyte UTF-8, which keeps the estimate conservative (it never reads lower than the true token cost implies).
	//
	// The gateway never claims to know the true token count; a real tokenizer calibration is a later GPU-free step, not this one.
	EstInputTokens int
	// NonTextContent is true when at least one message's content was not a plain string.
	//
	// A true value means EstInputTokens is a known-approximate lower bound rather than a byte-accurate estimate, since a non-string part's true token cost cannot be read off its byte length.
	NonTextContent bool
}

// chatMessage is the shape readRequestMeta needs from each entry in messages.
//
// Content stays raw JSON rather than string because the OpenAI schema allows it to be either a plain string or an array of content parts, and readRequestMeta must tell the two apart rather than assume one.
type chatMessage struct {
	Content json.RawMessage `json:"content"`
}

// newRequestID returns a random hex identifier for a single request.
//
// crypto/rand rather than math/rand: math/rand is deterministic from its seed, so separate Pods can emit the same id.
//
// Colliding ids merge unrelated requests when logs are stitched together, which defeats the point of the id.
//
// On the (practically unreachable) error path we fall back to a timestamp-derived value, since a weaker id still beats no id at all.
func newRequestID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "req-" + strconv.FormatInt(time.Now().UnixNano(), 16)
	}
	return hex.EncodeToString(b)
}

// readRequestMeta extracts admission-relevant metadata from the request body and returns the body restored for replay.
//
// It returns the restored body, the metadata, and an error.
//
// The restore is what makes this safe: r.Body is a one-shot stream, so reading it here would leave the proxy nothing to forward and the model server would see an empty body.
//
// The gateway would pass that failure through verbatim, hiding the fact that the gateway caused it.
//
// Only model and messages[].content are decoded.
//
// The gateway routes on model and estimates admission cost from content, and must forward everything else untouched; modelling the whole schema would mean editing the gateway whenever the OpenAI API grows a field, and would silently drop any field not yet declared.
func readRequestMeta(r *http.Request) (io.ReadCloser, RequestMeta, error) {
	// The nil first argument means MaxBytesReader will not write a response itself; the caller owns the status code.
	//
	// Exceeding the cap surfaces as a read error, which the caller maps to 400.
	limited := http.MaxBytesReader(nil, r.Body, maxBodyBytes)
	buf, err := io.ReadAll(limited)
	if err != nil {
		return nil, RequestMeta{}, err
	}

	var probe struct {
		Model    string        `json:"model"`
		Messages []chatMessage `json:"messages"`
	}
	if err := json.Unmarshal(buf, &probe); err != nil {
		return nil, RequestMeta{}, err
	}
	if probe.Model == "" {
		return nil, RequestMeta{}, ErrNoModel
	}

	meta := RequestMeta{Model: probe.Model}
	var totalChars int
	for _, m := range probe.Messages {
		// An absent content field, or an explicit JSON null, carries no text and is not a non-text part either.
		if len(m.Content) == 0 || string(m.Content) == "null" {
			continue
		}
		var text string
		if err := json.Unmarshal(m.Content, &text); err == nil {
			totalChars += len(text)
			continue
		}
		// content did not decode as a plain string, so it is an array, object, or number: the OpenAI multimodal shape.
		//
		// The true token cost of that part cannot be read off a character count, so flag the estimate as approximate.
		//
		// Its raw JSON byte length is still added, so the estimate is never undercounted, only ever imprecise.
		meta.NonTextContent = true
		totalChars += len(m.Content)
	}
	// Ceiling division, not floor: a conservative estimate must never read lower than the total byte length implies.
	meta.EstInputTokens = (totalChars + 3) / 4

	// Hand back a reader over the bytes just consumed, byte-for-byte identical to the original.
	return io.NopCloser(bytes.NewReader(buf)), meta, nil
}

// statusRecorder wraps a ResponseWriter to capture the status code the proxy actually wrote.
//
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
// This method is load-bearing (design spec Request flow section): embedding only promotes the methods declared on the embedded interface, and http.ResponseWriter has no Flush.
//
// Without this, the wrapper fails the http.Flusher check that ReverseProxy makes before streaming, and the proxy silently buffers regardless of FlushInterval.
//
// Wrapping the writer would kill streaming on its own.
func (rec *statusRecorder) Flush() {
	if f, ok := rec.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// errorBody is the OpenAI-style JSON envelope every gateway error response carries.
//
// Design rationale (design spec Pipeline placement section): the design promises an OpenAI-style JSON error contract, but fail() used to write plaintext via http.Error.
//
// A later task adds two new 429 codes as JSON; leaving everything else plaintext would make those two the odd ones out instead of the norm.
type errorBody struct {
	Error errorDetail `json:"error"`
}

// errorDetail carries the machine-readable code and human-readable message inside errorBody.
type errorDetail struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// errorCode maps an HTTP status to the stable code the JSON error body reports.
//
// The mapping is written out explicitly rather than derived from http.StatusText, since a machine-readable code must stay a fixed string even if the status text behind it ever changes wording.
//
// An unmapped status falls back to "internal_error"; every status this gateway actually emits is listed, so the default path is not expected to run.
func errorCode(status int) string {
	switch status {
	case http.StatusBadRequest:
		return "bad_request"
	case http.StatusUnauthorized:
		return "unauthorized"
	case http.StatusForbidden:
		return "no_policy"
	case http.StatusNotFound:
		return "model_not_found"
	case http.StatusTooManyRequests:
		return "rate_limited"
	case http.StatusBadGateway:
		return "bad_gateway"
	case http.StatusGatewayTimeout:
		return "upstream_timeout"
	default:
		return "internal_error"
	}
}

// writeJSONError writes the OpenAI-style JSON error envelope with the given status and message.
//
// Every gateway failure path (fail() below and the reverse proxy's ErrorHandler) returns through here, so the response shape stays identical regardless of which pipeline stage rejected the request.
func writeJSONError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	// Encoding into a fixed struct cannot fail; the error is ignored deliberately rather than handled for a write that has already committed its status code.
	_ = json.NewEncoder(w).Encode(errorBody{Error: errorDetail{Code: errorCode(status), Message: message}})
}

// defaultResponseHeaderTimeout bounds the wait for upstream response headers in production.
//
// 30s is the compromise: a model server can spend seconds on prefill before the first token, so a short cap severs healthy requests, while an unbounded wait lets hung requests pile up and exhaust connections.
const defaultResponseHeaderTimeout = 30 * time.Second

// newReverseProxy returns a streaming-capable reverse proxy to target, reporting 502/504 through onErr.
//
// A zero responseHeaderTimeout means "unset" and selects defaultResponseHeaderTimeout.
//
// Zero cannot be passed through as-is: http.Transport reads it as "no limit", which is the exact failure being bounded.
func newReverseProxy(target *url.URL, responseHeaderTimeout time.Duration, onErr func(code int)) *httputil.ReverseProxy {
	p := httputil.NewSingleHostReverseProxy(target)
	if responseHeaderTimeout == 0 {
		responseHeaderTimeout = defaultResponseHeaderTimeout
	}

	// FlushInterval = -1 means "flush immediately, never buffer".
	//
	// Design rationale (design spec Request flow section): stream:true emits tokens one at a time, and a proxy that batches them hands the client everything only once generation finishes, which defeats streaming.
	//
	// The setting's real reach is narrower than it looks, and it is worth knowing exactly.
	//
	// httputil.ReverseProxy's flushInterval() ignores this value and flushes immediately anyway when:
	//
	//   1. the response Content-Type is text/event-stream, or
	//   2. the response Content-Length is unknown (res.ContentLength == -1, i.e. chunked streaming).
	//
	// Real streaming responses almost always hit one of those, so for them this line changes nothing.
	//
	// It only changes behavior when an upstream declares a Content-Length and still delivers the body in pieces.
	//
	// The "uses the configured flush interval..." spec in proxy_test.go pins exactly that case.
	//
	// It stays despite the narrow reach because relying on Go's auto-detection would leave our intent unstated: this gateway buffers no response, and that intent belongs in the code.
	p.FlushInterval = -1

	// Transport tunes the outbound connection.
	//
	// Design rationale (design spec Request flow section): http.DefaultTransport has no response-header timeout, so a model server that accepts a connection and never answers pins the request forever; enough of those exhaust the gateway's connections and memory.
	//
	// There is deliberately no overall Timeout: a healthy stream legitimately runs for minutes, and an overall cap would sever it.
	//
	// Only the wait for the first response header is bounded; the time the body spends streaming is not.
	p.Transport = &http.Transport{
		// ResponseHeaderTimeout bounds the wait for response headers.
		//
		// Exceeding it becomes a timeout error, mapped to 504 below.
		ResponseHeaderTimeout: responseHeaderTimeout,
		// IdleConnTimeout keeps connections warm for reuse, avoiding a TCP handshake per request.
		IdleConnTimeout: 90 * time.Second,
	}

	// ErrorHandler runs when the upstream could not be reached.
	//
	// Design rationale (design spec Error codes section): the default handler always writes 502, collapsing "connection refused" and "no response in time" into one code.
	//
	// They are different operational signals: 502 means the backend Pod is gone or the Service is miswired, 504 means it is alive but hung or slow.
	//
	// They call for different responses, so they get different codes.
	p.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, err error) {
		// Connection refused, DNS failure, and similar land here.
		code := http.StatusBadGateway
		// errors.As walks the error chain, so a timeout wrapped with %w is still detected; a plain type assertion would miss it.
		var ne net.Error
		if errors.As(err, &ne) && ne.Timeout() {
			code = http.StatusGatewayTimeout
		}
		onErr(code)
		writeJSONError(w, code, err.Error())
	}

	return p
}
