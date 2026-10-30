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
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// newSchemeForTest builds a scheme with both the client-go and platform types registered.
func newSchemeForTest() *runtime.Scheme {
	scheme := runtime.NewScheme()
	Expect(clientgoscheme.AddToScheme(scheme)).To(Succeed())
	Expect(platformv1.AddToScheme(scheme)).To(Succeed())
	return scheme
}

var _ = Describe("policyForTenant", func() {
	It("returns ErrNoPolicy when no policy matches the tenant", func() {
		c := fake.NewClientBuilder().WithScheme(newSchemeForTest()).Build()
		s := &Server{Client: c}
		_, err := s.policyForTenant(context.Background(), "team-vision")
		Expect(err).To(MatchError(ErrNoPolicy))
	})

	It("returns the oldest policy when more than one matches the tenant", func() {
		older := &platformv1.GPUQuotaPolicy{
			Name:              "team-vision-old",
			CreationTimestamp: metav1.NewTime(time.Now().Add(-time.Hour)),
			Spec:              platformv1.GPUQuotaPolicySpec{Tenant: "team-vision"},
		}
		newer := &platformv1.GPUQuotaPolicy{
			Name:              "team-vision-new",
			CreationTimestamp: metav1.NewTime(time.Now()),
			Spec:              platformv1.GPUQuotaPolicySpec{Tenant: "team-vision"},
		}
		c := fake.NewClientBuilder().WithScheme(newSchemeForTest()).WithObjects(newer, older).Build()
		s := &Server{Client: c}
		got, err := s.policyForTenant(context.Background(), "team-vision")
		Expect(err).NotTo(HaveOccurred())
		Expect(got.Name).To(Equal("team-vision-old"))
	})
})

var _ = Describe("bucketRegistry", func() {
	It("limits per the rate and refreshes on change", func() {
		b := newBucketRegistry()
		rl := &platformv1.GPUQuotaRateLimit{RequestsPerMinute: 60, Burst: 1}
		Expect(b.Allow("t", rl)).To(BeTrue())
		Expect(b.Allow("t", rl)).To(BeFalse())
	})

	// A refusal reports how long until a token is available, and does not spend the token it was refused.
	// Mutation that turns this red: report the wait without the refusal, or spend a token on it.
	It("reports the wait for the next token and keeps a refusal from consuming it", func() {
		b := newBucketRegistry()
		rl := &platformv1.GPUQuotaRateLimit{RequestsPerMinute: 6, Burst: 1}
		ok, wait := b.Reserve("t", rl)
		Expect(ok).To(BeTrue())
		Expect(wait).To(BeZero())
		for range 3 {
			ok, wait = b.Reserve("t", rl)
			Expect(ok).To(BeFalse())
			Expect(wait).To(BeNumerically("~", 10*time.Second, time.Second))
		}
	})

	// Refusals that overlap must leave the bucket where one refusal would: none of them is admitted, so none may spend.
	// Reserve then Cancel did not: a reservation cancelled after a later one had been taken restores nothing, so
	// overlapping refusals put the bucket in debt and a request after the refill was refused (codex review of the branch).
	// Mutation that turns this red: compute the hint by reserving and cancelling.
	It("does not let overlapping refusals spend the next token", func() {
		b := newBucketRegistry()
		// 6000 per minute is one token every 10 ms, so the refill is quick and the debt, if any, is many tokens deep.
		rl := &platformv1.GPUQuotaRateLimit{RequestsPerMinute: 6000, Burst: 1}
		Expect(b.Allow("t", rl)).To(BeTrue())
		var wg sync.WaitGroup
		for range 64 {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for range 50 {
					b.Reserve("t", rl)
				}
			}()
		}
		wg.Wait()
		time.Sleep(30 * time.Millisecond)
		ok, _ := b.Reserve("t", rl)
		Expect(ok).To(BeTrue(), "a request after the refill was refused, so the refusals before it had spent tokens")
	})

	// The endpoint-level check cannot see a floor: 59.99 s floored is 59, and the random second makes it 60 half the
	// time, which the check accepts. Many draws see both the bottom of the range and that nothing falls below it.
	// Mutation that turns this red: floor the wait instead of rounding it up.
	It("rounds the hint up and adds at most one second", func() {
		seen := map[int]bool{}
		for range 200 {
			seen[retryAfterSeconds(10200*time.Millisecond)] = true
		}
		Expect(seen).To(Equal(map[int]bool{11: true, 12: true}))
	})

	It("returns true for an unlimited (nil) rate limit", func() {
		b := newBucketRegistry()
		Expect(b.Allow("t", nil)).To(BeTrue())
	})
})

// A Server whose rate limiter was never installed used to PANIC on the first request carrying a policy with a
// rate limit: Allow handled a nil policy and then dereferenced the nil registry. The comment on
// InitRateLimiter claimed the gateway guarded that case, and nothing did.
//
// It refuses rather than allows, because a limiter that cannot function must not answer "within budget" —
// that serves unlimited traffic under a configuration saying otherwise, with nothing anywhere to say so.
//
// Mutation that turns this red: drop the nil check from Allow, or make it return true.
var _ = Describe("a rate limiter that was never installed", func() {
	It("refuses instead of panicking or serving unlimited", func() {
		var registry *bucketRegistry
		rl := &platformv1.GPUQuotaRateLimit{RequestsPerMinute: 60, Burst: 1}

		var allowed bool
		Expect(func() { allowed = registry.Allow("t1", rl) }).NotTo(Panic())
		Expect(allowed).To(BeFalse(), "an unfinished gateway served a request under a limit it was not applying")
		Expect(registry.configured()).To(BeFalse())
	})

	// The control: an installed registry still allows a tenant within budget, so the guard has not turned into
	// a blanket refusal.
	It("does not refuse a tenant under an installed registry", func() {
		registry := newBucketRegistry()
		Expect(registry.configured()).To(BeTrue())
		Expect(registry.Allow("t1", &platformv1.GPUQuotaRateLimit{RequestsPerMinute: 600, Burst: 10})).To(BeTrue())
	})
})
