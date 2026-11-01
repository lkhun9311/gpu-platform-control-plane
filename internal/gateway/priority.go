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
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
)

// The engine priority a tier is bound to.
//
// vLLM's priority scheduling serves a lower value first, and a request that carries none is scheduled as 0.
// Premium is therefore 0 and standard 1: binding can only move standard work behind premium, never move
// premium behind anything, and an engine left in FCFS mode ignores the field.
const (
	premiumEnginePriority  = 0
	standardEnginePriority = 1
)

// HeaderEnginePriority carries the priority the gateway wrote into the forwarded request.
//
// A replay records it beside the tier, so the evidence says what the engine was told rather than what the
// policy implied.
const HeaderEnginePriority = "X-Engine-Priority"

// enginePriorityForTier is the priority a tier's requests are forwarded with.
func enginePriorityForTier(tier string) int {
	if tier == tierPremium {
		return premiumEnginePriority
	}
	return standardEnginePriority
}

// bindEnginePriority rewrites the request body so its "priority" is the tier's, whatever the caller sent.
//
// A caller-supplied priority is overwritten rather than refused: the tier is a property of the tenant's
// contract, and a field the caller can set would let any tenant schedule itself as premium. The body is
// replaced together with GetBody and ContentLength, because a retry on another backend rewinds through
// GetBody and the transport sends ContentLength; leaving either on the old bytes would forward the old
// priority or a truncated body.
func bindEnginePriority(r *http.Request, tier string) (int, error) {
	p := enginePriorityForTier(tier)
	return p, rewritePriority(r, func(fields map[string]json.RawMessage) {
		fields["priority"] = json.RawMessage(strconv.Itoa(p))
	})
}

// stripEnginePriority removes a caller's "priority" from an unbound request that may still reach a rendered engine.
//
// Not binding is a judgement that some reachable engine may not schedule by priority, not permission for the
// caller to choose: the head can still be a rendered engine, and a standard tenant's -100 there runs ahead of
// premium's 0. Removed rather than replaced, because an absent priority is what a first-come engine accepts and
// what a priority engine schedules as 0.
// A request that can reach only engines the controller did not render keeps its field, as it did before binding
// existed: the gateway does not know how those engines schedule.
func stripEnginePriority(r *http.Request) error {
	return rewritePriority(r, func(fields map[string]json.RawMessage) { delete(fields, "priority") })
}

// rewritePriority applies edit to the body's top-level fields and replaces the body with the result.
func rewritePriority(r *http.Request, edit func(map[string]json.RawMessage)) error {
	if r.GetBody == nil {
		return fmt.Errorf("the request body cannot be rewound, so its priority cannot be rewritten")
	}
	rc, err := r.GetBody()
	if err != nil {
		return err
	}
	raw, err := io.ReadAll(rc)
	_ = rc.Close()
	if err != nil {
		return err
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		return fmt.Errorf("the request body is not a JSON object: %w", err)
	}
	edit(fields)
	out, err := json.Marshal(fields)
	if err != nil {
		return err
	}
	r.GetBody = func() (io.ReadCloser, error) { return io.NopCloser(bytes.NewReader(out)), nil }
	r.Body, _ = r.GetBody()
	r.ContentLength = int64(len(out))
	return nil
}
