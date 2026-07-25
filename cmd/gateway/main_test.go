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
	"testing"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/gateway"
)

// TestNewAdmitterOff pins that mode "off" (the default flag value) never errors, so a gateway
// started with no flags at all still comes up.
func TestNewAdmitterOff(t *testing.T) {
	a, err := newAdmitter(gateway.AdmissionOff, 0, 0, 0)
	if err != nil {
		t.Fatalf("newAdmitter(off) returned an error: %v", err)
	}
	if a == nil {
		t.Fatal("newAdmitter(off) returned a nil Admitter")
	}
}

// TestNewAdmitterStaticCap pins that mode "static-cap" builds successfully with real tuning values.
func TestNewAdmitterStaticCap(t *testing.T) {
	a, err := newAdmitter(gateway.AdmissionStaticCap, 2000, 8192, 4096)
	if err != nil {
		t.Fatalf("newAdmitter(static-cap) returned an error: %v", err)
	}
	if a == nil {
		t.Fatal("newAdmitter(static-cap) returned a nil Admitter")
	}
}

// TestNewAdmitterKVAwareNotYetAvailable pins the Task 2 stub: kv-aware must fail startup with a
// clear message rather than silently falling back to another mode, since Task 3 has not
// implemented it yet.
func TestNewAdmitterKVAwareNotYetAvailable(t *testing.T) {
	_, err := newAdmitter(gateway.AdmissionKVAware, 0, 0, 0)
	if err == nil {
		t.Fatal("newAdmitter(kv-aware) unexpectedly succeeded")
	}
	const want = "kv-aware admission mode is not yet available"
	if err.Error() != want {
		t.Fatalf("newAdmitter(kv-aware) error = %q, want %q", err.Error(), want)
	}
}

// TestNewAdmitterUnknownMode pins that a typo or unsupported value in --admission-mode fails
// startup instead of being silently ignored.
func TestNewAdmitterUnknownMode(t *testing.T) {
	_, err := newAdmitter(gateway.AdmissionMode("bogus"), 0, 0, 0)
	if err == nil {
		t.Fatal("newAdmitter(bogus) unexpectedly succeeded")
	}
}
