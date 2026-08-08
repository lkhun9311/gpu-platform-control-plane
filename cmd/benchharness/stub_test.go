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

package main

import (
	"context"
	"net/http"
	"testing"
	"time"
)

// TestApplyModelPathStubURI pins that a stub:// storage URI sets the response profile.
//
// This is the only channel through which a stub deployed as an InferenceDeployment can be configured, since
// the controller builds the container with a fixed argument list, so a silent failure here would produce a
// backend that is not the one the evidence run claims to have measured.
func TestApplyModelPathStubURI(t *testing.T) {
	p := stubProfile{tokens: 8, ttft: 5 * time.Millisecond, itl: 2 * time.Millisecond}
	if err := p.applyModelPath("stub://profile?tokens=4&ttft-ms=2000&itl-ms=7"); err != nil {
		t.Fatalf("applyModelPath returned an error: %v", err)
	}
	if p.tokens != 4 {
		t.Errorf("tokens = %d, want 4", p.tokens)
	}
	if p.ttft != 2*time.Second {
		t.Errorf("ttft = %s, want 2s", p.ttft)
	}
	if p.itl != 7*time.Millisecond {
		t.Errorf("itl = %s, want 7ms", p.itl)
	}
}

// TestApplyModelPathPartialKeepsDefaults pins that an absent parameter keeps its current value rather than
// resetting to zero, so a profile only has to name what it changes.
func TestApplyModelPathPartialKeepsDefaults(t *testing.T) {
	p := stubProfile{tokens: 8, ttft: 5 * time.Millisecond, itl: 2 * time.Millisecond}
	if err := p.applyModelPath("stub://profile?ttft-ms=50"); err != nil {
		t.Fatalf("applyModelPath returned an error: %v", err)
	}
	if p.tokens != 8 || p.itl != 2*time.Millisecond {
		t.Errorf("unnamed parameters changed: tokens=%d itl=%s", p.tokens, p.itl)
	}
	if p.ttft != 50*time.Millisecond {
		t.Errorf("ttft = %s, want 50ms", p.ttft)
	}
}

// TestApplyModelPathIgnoresRealStorageURI pins that a genuine storage URI passes through untouched, so the
// profile hook cannot change the behaviour of a stub pointed at a real model path.
func TestApplyModelPathIgnoresRealStorageURI(t *testing.T) {
	for _, path := range []string{"", "s3://bucket/model", "pvc://claim/path"} {
		p := stubProfile{tokens: 8, ttft: 5 * time.Millisecond, itl: 2 * time.Millisecond}
		if err := p.applyModelPath(path); err != nil {
			t.Fatalf("applyModelPath(%q) returned an error: %v", path, err)
		}
		if p.tokens != 8 || p.ttft != 5*time.Millisecond || p.itl != 2*time.Millisecond {
			t.Errorf("applyModelPath(%q) changed the profile to %+v", path, p)
		}
	}
}

// TestApplyModelPathRejectsNonNumeric pins that a malformed profile fails loudly.
//
// Falling back to the default would start a backend whose timing silently differs from the one the run
// intended, which is the failure mode a measurement harness can least afford.
func TestApplyModelPathRejectsNonNumeric(t *testing.T) {
	p := stubProfile{tokens: 8}
	if err := p.applyModelPath("stub://profile?tokens=eight"); err == nil {
		t.Fatal("applyModelPath accepted a non-numeric tokens value")
	}
}

// TestStubStatsAttributesRequestsToConnections is the spec behind the connection-reuse measurement.
//
// The whole claim that the gateway's shared Transport pooled rests on this counter separating "many requests
// on few connections" from "one request per connection", so it is pinned rather than trusted.
func TestStubStatsAttributesRequestsToConnections(t *testing.T) {
	s := newStubStats()
	// Two connections, one carrying three requests and one carrying a single request.
	busy := s.connContext(context.Background(), nil)
	quiet := s.connContext(context.Background(), nil)
	for range 3 {
		s.begin(busy)
		s.end()
	}
	s.begin(quiet)
	s.end()

	snap := s.snapshot()
	if snap.RequestsServed != 4 {
		t.Errorf("requestsServed = %d, want 4", snap.RequestsServed)
	}
	if snap.ChatConnections != 2 {
		t.Errorf("chatConnections = %d, want 2", snap.ChatConnections)
	}
	if snap.MaxRequestsOnOneConnection != 3 {
		t.Errorf("maxRequestsOnOneConnection = %d, want 3", snap.MaxRequestsOnOneConnection)
	}
}

// TestStubStatsPeakInFlight pins that the peak is the high-water mark and not the current value, since the
// concurrency the pool cap has to cover is only ever visible as a peak.
func TestStubStatsPeakInFlight(t *testing.T) {
	s := newStubStats()
	c := s.connContext(context.Background(), nil)
	s.begin(c)
	s.begin(c)
	s.begin(c)
	s.end()
	s.end()
	s.end()

	snap := s.snapshot()
	if snap.PeakInFlight != 3 {
		t.Errorf("peakInFlight = %d, want 3", snap.PeakInFlight)
	}
	if snap.InFlight != 0 {
		t.Errorf("inFlight = %d, want 0", snap.InFlight)
	}
}

// TestStubStatsExcludesNonChatConnections pins that a connection which never carried a chat request is
// counted as accepted but not as a chat connection.
//
// The kubelet opens a fresh connection for every probe, so without this separation the probes would inflate
// exactly the number the reuse measurement reports.
func TestStubStatsExcludesNonChatConnections(t *testing.T) {
	s := newStubStats()
	s.connState(nil, http.StateNew)
	s.connState(nil, http.StateNew)
	c := s.connContext(context.Background(), nil)
	s.begin(c)
	s.end()

	snap := s.snapshot()
	if snap.ConnectionsAccepted != 2 {
		t.Errorf("connectionsAccepted = %d, want 2", snap.ConnectionsAccepted)
	}
	if snap.ChatConnections != 1 {
		t.Errorf("chatConnections = %d, want 1", snap.ChatConnections)
	}
}

// TestStubStatsResetKeepsLiveState pins that starting a new measurement window zeroes the window's counts
// while carrying the present forward.
//
// Zeroing the open-connection count instead would send it negative the moment a connection opened before the
// reset finally closed, and a negative connection count would discredit every other number beside it.
func TestStubStatsResetKeepsLiveState(t *testing.T) {
	s := newStubStats()
	s.connState(nil, http.StateNew)
	c := s.connContext(context.Background(), nil)
	s.begin(c)

	s.reset()
	snap := s.snapshot()
	if snap.RequestsServed != 0 || snap.ChatConnections != 0 {
		t.Errorf("window counts survived the reset: %+v", snap)
	}
	if snap.OpenConnections != 1 {
		t.Errorf("openConnections = %d, want 1 (a still-open connection must carry over)", snap.OpenConnections)
	}
	if snap.InFlight != 1 || snap.PeakInFlight != 1 {
		t.Errorf("in-flight state did not carry over: inFlight=%d peakInFlight=%d", snap.InFlight, snap.PeakInFlight)
	}

	// The still-open connection is counted again the first time it carries a request in the new window,
	// which is the honest reading: it is a connection carrying this window's load.
	s.begin(c)
	if got := s.snapshot().ChatConnections; got != 1 {
		t.Errorf("chatConnections after the new window = %d, want 1", got)
	}
	s.end()
	s.end()
	s.connState(nil, http.StateClosed)
}
