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
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"
)

// HTTPSender replays a trace row as a streaming OpenAI chat-completions request against the gateway.
//
// It records first-token and end timestamps on the client's own clock, which is the only honest source for TTFT because the gateway's request histogram does not start until the proxy handoff.
type HTTPSender struct {
	client     *http.Client
	gatewayURL string
	model      string
	// apiKeys maps a trace tenant to the API key the gateway resolves it from, so one sender can drive premium and standard tenants through the real identity chain.
	apiKeys map[string]string
	// timeout bounds a single request; on expiry the row is recorded as a timeout rather than dropped.
	timeout time.Duration
	// now is injected only by tests; production uses the wall clock.
	now func() time.Time
}

// NewHTTPSender builds a sender targeting gatewayURL for model, resolving each tenant through apiKeys.
func NewHTTPSender(gatewayURL, model string, apiKeys map[string]string, timeout time.Duration) *HTTPSender {
	return &HTTPSender{
		client: &http.Client{
			// No redirects: the gateway answers directly, and a redirect would point somewhere unmeasured.
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
		gatewayURL: strings.TrimRight(gatewayURL, "/"),
		model:      model,
		apiKeys:    apiKeys,
		timeout:    timeout,
		now:        time.Now,
	}
}

// chatRequest is the minimal OpenAI chat-completions body the harness sends.
type chatRequest struct {
	Model     string       `json:"model"`
	Messages  []chatReqMsg `json:"messages"`
	MaxTokens int          `json:"max_tokens"`
	Stream    bool         `json:"stream"`
}

type chatReqMsg struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// Send dispatches one streaming request and returns its raw timing result.
//
// A non-200 status maps to a result with that status and an error kind, so admission rejections (429) are recorded as rejections rather than as completed requests; a deadline maps to a timeout; a transport failure maps to a transport error.
func (h *HTTPSender) Send(ctx context.Context, row TraceRow, sendUnixNanos int64) SendResult {
	reqCtx, cancel := context.WithTimeout(ctx, h.timeout)
	defer cancel()

	body := chatRequest{
		Model:     h.model,
		Messages:  []chatReqMsg{{Role: "user", Content: strings.Repeat("x", row.PromptLenChars)}},
		MaxTokens: row.MaxOutputTokens,
		Stream:    true,
	}
	buf, err := json.Marshal(body)
	if err != nil {
		return SendResult{ErrorKind: "encode"}
	}

	req, err := http.NewRequestWithContext(reqCtx, http.MethodPost, h.gatewayURL+"/v1/chat/completions", bytes.NewReader(buf))
	if err != nil {
		return SendResult{ErrorKind: "transport"}
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "text/event-stream")
	if key := h.apiKeys[row.Tenant]; key != "" {
		req.Header.Set("Authorization", "Bearer "+key)
	}

	resp, err := h.client.Do(req)
	if err != nil {
		if errors.Is(reqCtx.Err(), context.DeadlineExceeded) {
			return SendResult{ErrorKind: "timeout"}
		}
		return SendResult{ErrorKind: "transport"}
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		kind := "http"
		if resp.StatusCode == http.StatusTooManyRequests {
			kind = "rejected"
		}
		return SendResult{HTTPStatus: resp.StatusCode, ErrorKind: kind}
	}

	return h.readStream(reqCtx, resp)
}

// readStream consumes the server-sent-events response, recording first-token and end times and counting output tokens.
//
// vLLM's OpenAI-compatible stream emits one "data: {json}" line per token chunk and a final "data: [DONE]".
//
// Each chunk carrying a non-empty content delta counts as one output token, which is an approximation the report labels as such; an exact count needs the tokenizer, deferred to the paid run.
func (h *HTTPSender) readStream(ctx context.Context, resp *http.Response) SendResult {
	res := SendResult{HTTPStatus: http.StatusOK}
	sc := bufio.NewScanner(resp.Body)
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)

	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		data := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if data == "[DONE]" {
			break
		}

		var chunk struct {
			Choices []struct {
				Delta struct {
					Content string `json:"content"`
				} `json:"delta"`
			} `json:"choices"`
		}
		if err := json.Unmarshal([]byte(data), &chunk); err != nil {
			// A malformed chunk mid-stream is a stream error, but any first token already observed still stands.
			res.ErrorKind = "stream"
			res.EndUnixNanos = h.now().UnixNano()
			return res
		}
		if len(chunk.Choices) > 0 && chunk.Choices[0].Delta.Content != "" {
			if res.FirstTokenUnixNanos == 0 {
				res.FirstTokenUnixNanos = h.now().UnixNano()
			}
			res.OutputTokens++
		}
	}
	if err := sc.Err(); err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			res.ErrorKind = "timeout"
		} else {
			res.ErrorKind = "stream"
		}
	}
	res.EndUnixNanos = h.now().UnixNano()
	return res
}
