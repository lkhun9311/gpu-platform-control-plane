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
	"sync"
)

// AdmissionProspective reserves a standard request's input work and a stream slot before it is forwarded.
//
// It is the mechanism docs/superpowers/specs/2026-10-06-m5b-stays-closed-and-what-a-successor-needs-first.md
// names for M5-b's successor: it acts on work the gateway is about to admit, not on pressure the engine already
// shows, which is the layer M5-b's KV guard turned out to sit on.
const AdmissionProspective AdmissionMode = "prospective"

// The reasons the prospective admitter reports.
const (
	// reasonPrefillReservationFull refuses a standard request whose input does not fit the backend's free
	// prefill reservation; it is transient, because reservations are released as admitted requests start
	// answering.
	reasonPrefillReservationFull = "prefill_reservation_full"
	// reasonStandardStreamsFull refuses a standard request while the backend already runs its cap of standard
	// streams.
	reasonStandardStreamsFull = "standard_streams_full"
	// reasonInputExceedsReservation refuses a request larger than the whole reservation, which no amount of
	// waiting admits; the server answers it 413 like the static cap's permanent refusal.
	reasonInputExceedsReservation = "input_exceeds_reservation"
	// reasonReserved and reasonPremiumUnreserved are the two ways it admits.
	reasonReserved          = "reserved"
	reasonPremiumUnreserved = "premium_unreserved"
)

// reserver is implemented by an admitter whose admission holds something until the request releases it.
//
// The server calls Reserve instead of Admit for such an admitter, so a request is never admitted without the
// reservation that makes the admission mean anything.
type reserver interface {
	Reserve(ctx context.Context, meta RequestMeta, backend *BackendRef, tenant, tier string) (*reservation, bool, string)
}

// reservation is one admitted request's hold on a backend.
//
// PrefillDone and Done may each be called any number of times from any goroutine; each releases at most once.
// Done releases the prefill too, so a request that ends before any byte reached the client -- an error, a
// cancellation, a refused retry -- cannot leave its prefill reserved forever.
type reservation struct {
	prefillOnce, doneOnce sync.Once
	releasePrefill        func()
	releaseStream         func()
	// onContent releases the prefill at the first complete content event rather than the first body byte: an
	// engine may send a frame with no content, such as the role frame, before the prompt is done.
	onContent bool
}

// PrefillDone releases the request's input-work reservation.
func (r *reservation) PrefillDone() {
	if r == nil || r.releasePrefill == nil {
		return
	}
	r.prefillOnce.Do(r.releasePrefill)
}

// Done releases everything the request still holds.
func (r *reservation) Done() {
	if r == nil {
		return
	}
	r.PrefillDone()
	if r.releaseStream != nil {
		r.doneOnce.Do(r.releaseStream)
	}
}

// prospectiveAdmitter holds, per backend, the standard tier's reserved input tokens and running streams.
//
// The input is the gateway's estimate, ceil(characters / 4), not the engine's token count: the gateway has no
// tokenizer, and a ceiling over-reserves rather than under-reserves. A registration that relies on exact work
// must say how it reconciles the two.
type prospectiveAdmitter struct {
	mu            sync.Mutex
	prefillTokens int
	streams       int
	reserved      map[string]int
	running       map[string]int
}

// NewProspectiveAdmitter returns the prospective admitter with its two per-backend caps.
func NewProspectiveAdmitter(prefillTokens, streams int) Admitter {
	return newProspectiveAdmitter(prefillTokens, streams)
}

func newProspectiveAdmitter(prefillTokens, streams int) *prospectiveAdmitter {
	return &prospectiveAdmitter{prefillTokens: prefillTokens, streams: streams,
		reserved: map[string]int{}, running: map[string]int{}}
}

// Admit exists to satisfy Admitter; the server reaches this admitter only through Reserve, and an Admit that
// admitted without reserving would be the guard bypassed, so it refuses.
func (p *prospectiveAdmitter) Admit(context.Context, RequestMeta, *BackendRef, string, string) (bool, string) {
	return false, "reservation_required"
}

// Reserve admits a premium request without holding anything, and a standard one only if both its input and a
// stream slot fit, taking both in one critical section so two requests cannot each see room for one.
func (p *prospectiveAdmitter) Reserve(_ context.Context, meta RequestMeta, backend *BackendRef, _, tier string) (*reservation, bool, string) {
	if tier == tierPremium {
		return nil, true, reasonPremiumUnreserved
	}
	tokens := meta.EstInputTokens
	if tokens > p.prefillTokens {
		return nil, false, reasonInputExceedsReservation
	}
	key := backend.URL.String()
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.running[key] >= p.streams {
		return nil, false, reasonStandardStreamsFull
	}
	if p.reserved[key]+tokens > p.prefillTokens {
		return nil, false, reasonPrefillReservationFull
	}
	p.reserved[key] += tokens
	p.running[key]++
	p.publish(key)
	return &reservation{
		releasePrefill: func() {
			p.mu.Lock()
			p.reserved[key] -= tokens
			p.publish(key)
			p.mu.Unlock()
		},
		releaseStream: func() {
			p.mu.Lock()
			p.running[key]--
			p.publish(key)
			p.mu.Unlock()
		},
	}, true, reasonReserved
}

// publish sets the backend's two gauges from the holds; the caller holds p.mu, so the gauges move in the same
// order as the holds and never show a state the holds were not in.
func (p *prospectiveAdmitter) publish(key string) {
	admissionReservedInputTokens.WithLabelValues(key).Set(float64(p.reserved[key]))
	admissionRunningStandardStreams.WithLabelValues(key).Set(float64(p.running[key]))
}

// held reports a backend's reserved input tokens and running streams, for tests and evidence.
func (p *prospectiveAdmitter) held(backend *BackendRef) (int, int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	key := backend.URL.String()
	return p.reserved[key], p.running[key]
}
