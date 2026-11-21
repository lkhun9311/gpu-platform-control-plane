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
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/gateway"
)

// redisFlags is a valid redis store configuration whose address nothing needs to answer, because building the store contacts nobody.
func redisFlags() rateLimitFlags {
	return rateLimitFlags{
		store: rateLimitStoreRedis,
		redis: gateway.RedisRateLimitConfig{
			Addr:          "127.0.0.1:1",
			KeyPrefix:     gateway.DefaultRedisKeyPrefix,
			Timeout:       gateway.DefaultRedisTimeout,
			FailurePolicy: gateway.RedisFailureLocal,
		},
	}
}

// The default store is the one the gateway always had, so a gateway started with no new flag is unchanged.
func TestInstallRateLimiterMemoryIsTheDefault(t *testing.T) {
	var f rateLimitFlags
	f.store = rateLimitStoreMemory
	closeFn, err := installRateLimiter(&gateway.Server{}, f, gateway.AdmissionSerialPrefill)
	if err != nil {
		t.Fatalf("the memory store refused serial-prefill, which it has always run: %v", err)
	}
	if err := closeFn(); err != nil {
		t.Fatalf("closing the memory store failed: %v", err)
	}
}

// Every holding mode keeps per-process state, so the shared store must refuse each one before anything is built.
// Mutation that turns this red: let CheckSharedStoreAdmission accept every mode.
func TestInstallRateLimiterRedisRefusesPerProcessAdmission(t *testing.T) {
	for _, mode := range []gateway.AdmissionMode{
		gateway.AdmissionStaticCap, gateway.AdmissionProspective,
		gateway.AdmissionSerialPrefill, gateway.AdmissionFixedSpacing,
	} {
		if _, err := installRateLimiter(&gateway.Server{}, redisFlags(), mode); err == nil {
			t.Errorf("the redis store started with --admission-mode=%s, whose state each replica would keep on its own", mode)
		}
	}
	// The control: the two modes that keep nothing per process still start, so the check is not a blanket refusal.
	for _, mode := range []gateway.AdmissionMode{gateway.AdmissionOff, gateway.AdmissionKVAware} {
		closeFn, err := installRateLimiter(&gateway.Server{}, redisFlags(), mode)
		if err != nil {
			t.Errorf("the redis store refused --admission-mode=%s: %v", mode, err)
			continue
		}
		_ = closeFn()
	}
}

// A typo in the store, an empty address and an unknown failure policy each stop the gateway rather than run something else.
func TestInstallRateLimiterRefusesWhatItCannotMean(t *testing.T) {
	unknown := redisFlags()
	unknown.store = "redsi"
	noAddr := redisFlags()
	noAddr.redis.Addr = ""
	badPolicy := redisFlags()
	badPolicy.redis.FailurePolicy = "open"
	noTimeout := redisFlags()
	noTimeout.redis.Timeout = 0
	for name, f := range map[string]rateLimitFlags{
		"unknown store": unknown, "no address": noAddr, "unknown policy": badPolicy, "zero timeout": noTimeout,
	} {
		if _, err := installRateLimiter(&gateway.Server{}, f, gateway.AdmissionOff); err == nil {
			t.Errorf("%s: the gateway would have started", name)
		}
	}
}

// An empty or missing password file stops the gateway: connecting without a password would fail every call,
// and the local policy would serve through it with nothing but a counter to say so.
func TestInstallRateLimiterRefusesAnEmptyPasswordFile(t *testing.T) {
	dir := t.TempDir()
	empty := filepath.Join(dir, "empty")
	if err := os.WriteFile(empty, []byte("\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{empty, filepath.Join(dir, "missing")} {
		f := redisFlags()
		f.passwordFile = path
		if _, err := installRateLimiter(&gateway.Server{}, f, gateway.AdmissionOff); err == nil {
			t.Errorf("password file %s: the gateway would have started", path)
		}
	}
	good := filepath.Join(dir, "good")
	if err := os.WriteFile(good, []byte("s3cret\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	f := redisFlags()
	f.passwordFile = good
	closeFn, err := installRateLimiter(&gateway.Server{}, f, gateway.AdmissionOff)
	if err != nil {
		t.Fatalf("a password file with a password was refused: %v", err)
	}
	_ = closeFn()
}

// The flag defaults are the ones the design page states, so the page and the binary cannot drift apart unnoticed.
func TestRedisDefaultsMatchTheDesign(t *testing.T) {
	if gateway.DefaultRedisTimeout != 100*time.Millisecond {
		t.Errorf("default timeout %s, the design states 100ms", gateway.DefaultRedisTimeout)
	}
	if !strings.HasSuffix(gateway.DefaultRedisKeyPrefix, ":v1:") {
		t.Errorf("default prefix %q carries no layout version", gateway.DefaultRedisKeyPrefix)
	}
}
