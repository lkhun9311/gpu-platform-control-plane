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
	"fmt"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/redis/go-redis/v9"
	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/wait"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// redisTestImage is the Redis the kind verification runs, pinned by digest so a test and the run cannot differ by a tag move.
//
// A real server rather than miniredis: miniredis runs scripts on gopher-lua and implements TIME itself, so a test
// passing there would say how miniredis behaves, and the property this limiter rests on is the real server running
// a script to completion before any other command.
// Without Docker these specs fail rather than skip, because a skipped shared-limit test reads as a passing one.
const redisTestImage = "redis:7.4.7-alpine@sha256:02f2cc4882f8bf87c79a220ac958f58c700bdec0dfb9b9ea61b62fb0e8f1bfcf"

// testPrefixSeq makes every spec's keys its own, so specs share one Redis without sharing a bucket.
var testPrefixSeq atomic.Int64

func uniquePrefix() string {
	return fmt.Sprintf("test:%d:%d:", time.Now().UnixNano(), testPrefixSeq.Add(1))
}

// newTestRedisLimiter builds a limiter on its own client, as a separate replica would have.
func newTestRedisLimiter(addr, prefix string, policy RedisFailurePolicy, timeout time.Duration) *redisLimiter {
	l, err := newRedisLimiter(RedisRateLimitConfig{Addr: addr, KeyPrefix: prefix, Timeout: timeout, FailurePolicy: policy})
	Expect(err).NotTo(HaveOccurred())
	DeferCleanup(l.Close)
	return l
}

// switchProxy forwards TCP to a target until cut, and while cut closes every connection it holds or is offered.
// It stands for Redis going away and coming back at the same address, which stopping a container cannot do
// without a new port.
type switchProxy struct {
	ln     net.Listener
	target string
	cut    atomic.Bool
	mu     sync.Mutex
	conns  map[net.Conn]struct{}
}

func newSwitchProxy(target string) *switchProxy {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	Expect(err).NotTo(HaveOccurred())
	p := &switchProxy{ln: ln, target: target, conns: map[net.Conn]struct{}{}}
	go p.serve()
	DeferCleanup(func() { _ = ln.Close(); p.dropAll() })
	return p
}

func (p *switchProxy) addr() string { return p.ln.Addr().String() }

func (p *switchProxy) serve() {
	for {
		c, err := p.ln.Accept()
		if err != nil {
			return
		}
		if p.cut.Load() {
			_ = c.Close()
			continue
		}
		up, err := net.Dial("tcp", p.target)
		if err != nil {
			_ = c.Close()
			continue
		}
		p.mu.Lock()
		p.conns[c], p.conns[up] = struct{}{}, struct{}{}
		p.mu.Unlock()
		go func() { _, _ = io.Copy(up, c); _ = up.Close() }()
		go func() { _, _ = io.Copy(c, up); _ = c.Close() }()
	}
}

func (p *switchProxy) dropAll() {
	p.mu.Lock()
	defer p.mu.Unlock()
	for c := range p.conns {
		_ = c.Close()
	}
	p.conns = map[net.Conn]struct{}{}
}

func (p *switchProxy) setCut(cut bool) {
	p.cut.Store(cut)
	if cut {
		p.dropAll()
	}
}

// blackHole accepts connections and never answers, which is what a hung Redis or a dropped route looks like to a client.
func blackHole() (string, *atomic.Int32) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	Expect(err).NotTo(HaveOccurred())
	var accepted atomic.Int32
	var held []net.Conn
	var mu sync.Mutex
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			accepted.Add(1)
			mu.Lock()
			held = append(held, c)
			mu.Unlock()
		}
	}()
	DeferCleanup(func() {
		_ = ln.Close()
		mu.Lock()
		defer mu.Unlock()
		for _, c := range held {
			_ = c.Close()
		}
	})
	return ln.Addr().String(), &accepted
}

// deadAddr is an address that refuses connections.
func deadAddr() string {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	Expect(err).NotTo(HaveOccurred())
	addr := ln.Addr().String()
	_ = ln.Close()
	return addr
}

var _ = Describe("redisLimiter against a real Redis", Ordered, func() {
	var redisAddr string
	ctx := context.Background()

	BeforeAll(func() {
		c, err := testcontainers.Run(ctx, redisTestImage,
			testcontainers.WithExposedPorts("6379/tcp"),
			testcontainers.WithWaitStrategy(wait.ForListeningPort("6379/tcp").WithStartupTimeout(60*time.Second)))
		Expect(err).NotTo(HaveOccurred(), "these specs need Docker to start Redis; they fail rather than skip without it")
		DeferCleanup(func() { Expect(testcontainers.TerminateContainer(c)).To(Succeed()) })
		redisAddr, err = c.PortEndpoint(ctx, "6379/tcp", "")
		Expect(err).NotTo(HaveOccurred())
	})

	// The property the change exists for: replicas share one budget.
	// Three limiters with their own connection pools stand for three gateway Pods, and 600 attempts race for a burst
	// of 100 at a refill of one a minute, which cannot add a token in the few hundred milliseconds this takes.
	// Mutations that turn this red: key the bucket per limiter instance (each replica its own budget, 300 admitted),
	// or read and write the bucket from Go in two round trips instead of one script (replicas read the same token).
	It("admits exactly the burst across three limiters sharing one Redis", func() {
		prefix := uniquePrefix()
		limiters := []*redisLimiter{
			newTestRedisLimiter(redisAddr, prefix, RedisFailureClosed, time.Second),
			newTestRedisLimiter(redisAddr, prefix, RedisFailureClosed, time.Second),
			newTestRedisLimiter(redisAddr, prefix, RedisFailureClosed, time.Second),
		}
		rl := &platformv1.GPUQuotaRateLimit{RequestsPerMinute: 1, Burst: 100}
		var admitted, failed atomic.Int64
		var wg sync.WaitGroup
		start := make(chan struct{})
		for _, l := range limiters {
			for range 50 {
				wg.Go(func() {
					<-start
					for range 4 {
						ok, _, err := l.Decide(ctx, "tenant-a", rl)
						if err != nil {
							failed.Add(1)
						}
						if ok {
							admitted.Add(1)
						}
					}
				})
			}
		}
		close(start)
		wg.Wait()
		Expect(failed.Load()).To(BeZero(), "a call failed, so the count below is not the shared limiter's")
		Expect(admitted.Load()).To(Equal(int64(100)), "three replicas admitted other than the one budget of 100")
	})

	// Refill follows the policy's rate on Redis's clock, and a refusal reports the wait to the next token.
	// 600 a minute is one token per 100 ms; a second limiter takes the refilled token, so the refill is the shared bucket's.
	// Mutations that turn this red: pass requestsPerMinute as a per-second rate (refill 60x fast, the second call is
	// admitted), or drop the refill (the last call is refused).
	It("refills at the policy's rate and reports the wait", func() {
		prefix := uniquePrefix()
		a := newTestRedisLimiter(redisAddr, prefix, RedisFailureClosed, time.Second)
		b := newTestRedisLimiter(redisAddr, prefix, RedisFailureClosed, time.Second)
		rl := &platformv1.GPUQuotaRateLimit{RequestsPerMinute: 600, Burst: 1}

		ok, _, err := a.Decide(ctx, "t", rl)
		Expect(err).NotTo(HaveOccurred())
		Expect(ok).To(BeTrue())
		ok, wait, err := b.Decide(ctx, "t", rl)
		Expect(err).NotTo(HaveOccurred())
		Expect(ok).To(BeFalse(), "a second request inside one refill period was admitted")
		Expect(wait).To(BeNumerically(">", 50*time.Millisecond))
		Expect(wait).To(BeNumerically("<=", 100*time.Millisecond))

		time.Sleep(wait / 3)
		ok, _, err = b.Decide(ctx, "t", rl)
		Expect(err).NotTo(HaveOccurred())
		Expect(ok).To(BeFalse(), "admitted before the reported wait had passed")

		time.Sleep(wait)
		ok, _, err = b.Decide(ctx, "t", rl)
		Expect(err).NotTo(HaveOccurred())
		Expect(ok).To(BeTrue(), "refused after the refill period had passed")
	})

	// An edited policy keeps the tokens already spent, as the memory store's SetLimit and SetBurst do.
	// Mutation that turns this red: key the bucket by its rate and burst, so an edit starts a fresh, full bucket.
	It("keeps spent tokens across a policy edit", func() {
		l := newTestRedisLimiter(redisAddr, uniquePrefix(), RedisFailureClosed, time.Second)
		before := &platformv1.GPUQuotaRateLimit{RequestsPerMinute: 1, Burst: 3}
		for range 3 {
			ok, _, err := l.Decide(ctx, "t", before)
			Expect(err).NotTo(HaveOccurred())
			Expect(ok).To(BeTrue())
		}
		after := &platformv1.GPUQuotaRateLimit{RequestsPerMinute: 2, Burst: 10}
		ok, _, err := l.Decide(ctx, "t", after)
		Expect(err).NotTo(HaveOccurred())
		Expect(ok).To(BeFalse(), "editing the policy handed the tenant a fresh burst")
	})

	// One tenant's spending never touches another's bucket, including a tenant whose name extends another's.
	// Mutation that turns this red: build the key from the prefix alone.
	It("keeps tenants' buckets apart", func() {
		l := newTestRedisLimiter(redisAddr, uniquePrefix(), RedisFailureClosed, time.Second)
		rl := &platformv1.GPUQuotaRateLimit{RequestsPerMinute: 1, Burst: 2}
		for range 2 {
			ok, _, _ := l.Decide(ctx, "team", rl)
			Expect(ok).To(BeTrue())
		}
		ok, _, _ := l.Decide(ctx, "team", rl)
		Expect(ok).To(BeFalse())
		for _, other := range []string{"team:x", "other"} {
			for range 2 {
				ok, _, err := l.Decide(ctx, other, rl)
				Expect(err).NotTo(HaveOccurred())
				Expect(ok).To(BeTrue(), "tenant %q was refused for spending it never did", other)
			}
		}
	})

	// The key expires once the bucket would be full again, so idle tenants leave nothing behind and nothing owed is lost.
	It("expires a tenant's key after the time to refill", func() {
		prefix := uniquePrefix()
		l := newTestRedisLimiter(redisAddr, prefix, RedisFailureClosed, time.Second)
		_, _, err := l.Decide(ctx, "t", &platformv1.GPUQuotaRateLimit{RequestsPerMinute: 60, Burst: 5})
		Expect(err).NotTo(HaveOccurred())
		c := redis.NewClient(&redis.Options{Addr: redisAddr})
		defer func() { _ = c.Close() }()
		ttl, err := c.PTTL(ctx, prefix+"t").Result()
		Expect(err).NotTo(HaveOccurred())
		Expect(ttl).To(BeNumerically(">", 5*time.Second))
		Expect(ttl).To(BeNumerically("<=", 6*time.Second))
	})

	// A Redis that lost its script cache, after a restart or SCRIPT FLUSH, answers EVALSHA with NOSCRIPT.
	// The limiter must load the script again and decide, not count a lost cache as an outage for every request.
	// Mutation that turns this red: call EvalSha alone, without Run's fallback to EVAL.
	It("decides after the script cache is flushed", func() {
		l := newTestRedisLimiter(redisAddr, uniquePrefix(), RedisFailureClosed, time.Second)
		rl := &platformv1.GPUQuotaRateLimit{RequestsPerMinute: 60, Burst: 5}
		_, _, err := l.Decide(ctx, "t", rl)
		Expect(err).NotTo(HaveOccurred())
		c := redis.NewClient(&redis.Options{Addr: redisAddr})
		defer func() { _ = c.Close() }()
		Expect(c.ScriptFlush(ctx).Err()).To(Succeed())
		ok, _, err := l.Decide(ctx, "t", rl)
		Expect(err).NotTo(HaveOccurred(), "a flushed script cache was treated as Redis failing")
		Expect(ok).To(BeTrue())
	})

	// A Redis that loses its data, by a restart without persistence or by eviction, hands each tenant one full burst.
	// This pins that documented cost, so a change to it is a decision and not an accident: a missing key reads as a
	// full bucket, which is also what lets the expiry discard nothing.
	It("gives a tenant one full burst after its key is lost", func() {
		prefix := uniquePrefix()
		l := newTestRedisLimiter(redisAddr, prefix, RedisFailureClosed, time.Second)
		rl := &platformv1.GPUQuotaRateLimit{RequestsPerMinute: 1, Burst: 3}
		admitted := func() int {
			n := 0
			for range 5 {
				if ok, _, err := l.Decide(ctx, "t", rl); err == nil && ok {
					n++
				}
			}
			return n
		}
		Expect(admitted()).To(Equal(3))
		c := redis.NewClient(&redis.Options{Addr: redisAddr})
		defer func() { _ = c.Close() }()
		Expect(c.Del(ctx, prefix+"t").Err()).To(Succeed())
		Expect(admitted()).To(Equal(3))
	})

	// closed refuses while Redis cannot answer, and the caller turns the error into a 503.
	// Mutation that turns this red: make the closed policy admit.
	It("refuses under the closed policy when Redis refuses connections", func() {
		l := newTestRedisLimiter(deadAddr(), uniquePrefix(), RedisFailureClosed, 100*time.Millisecond)
		start := time.Now()
		ok, _, err := l.Decide(ctx, "t", &platformv1.GPUQuotaRateLimit{RequestsPerMinute: 60, Burst: 5})
		Expect(err).To(MatchError(ErrRateLimitUnavailable))
		Expect(ok).To(BeFalse())
		Expect(time.Since(start)).To(BeNumerically("<", time.Second))
	})

	// local decides by this replica's own bucket: the burst, then refusals, never unlimited and never an outage.
	// Mutations that turn this red: make local admit everything, or refuse like closed.
	It("falls back to a local bucket under the local policy", func() {
		l := newTestRedisLimiter(deadAddr(), uniquePrefix(), RedisFailureLocal, 100*time.Millisecond)
		rl := &platformv1.GPUQuotaRateLimit{RequestsPerMinute: 1, Burst: 2}
		var got []bool
		for range 3 {
			ok, _, err := l.Decide(ctx, "t", rl)
			Expect(err).NotTo(HaveOccurred())
			got = append(got, ok)
		}
		Expect(got).To(Equal([]bool{true, true, false}))
	})

	// A Redis that accepts and never answers costs one timeout, not a hung request.
	// Mutation that turns this red: drop the call's context deadline and the client's read timeout.
	It("gives up on a hung Redis within the timeout", func() {
		addr, _ := blackHole()
		l := newTestRedisLimiter(addr, uniquePrefix(), RedisFailureClosed, 50*time.Millisecond)
		start := time.Now()
		_, _, err := l.Decide(ctx, "t", &platformv1.GPUQuotaRateLimit{RequestsPerMinute: 60, Burst: 5})
		Expect(err).To(MatchError(ErrRateLimitUnavailable))
		Expect(time.Since(start)).To(BeNumerically("<", 500*time.Millisecond))
	})

	// After a failure the replica stops calling Redis for the cooldown, so an outage does not add the timeout to every request.
	// Mutation that turns this red: never open the breaker (each call dials the hung Redis again).
	It("stops calling a failed Redis for the cooldown", func() {
		addr, accepted := blackHole()
		l := newTestRedisLimiter(addr, uniquePrefix(), RedisFailureLocal, 50*time.Millisecond)
		rl := &platformv1.GPUQuotaRateLimit{RequestsPerMinute: 6000, Burst: 100}
		_, _, _ = l.Decide(ctx, "t", rl)
		Eventually(accepted.Load).Should(Equal(int32(1)))
		start := time.Now()
		for range 20 {
			_, _, err := l.Decide(ctx, "t", rl)
			Expect(err).NotTo(HaveOccurred())
		}
		Expect(time.Since(start)).To(BeNumerically("<", 50*time.Millisecond), "the open breaker still paid the timeout")
		Consistently(accepted.Load, "100ms").Should(Equal(int32(1)), "the open breaker still connected to Redis")
	})

	// Recovery: once Redis is back and the cooldown has passed, the shared bucket decides again, spent tokens included.
	// The shared bucket is emptied first, so the local bucket admitting during the cut and the shared one refusing
	// after it tell which store decided each call.
	// Mutation that turns this red: never close the breaker once it has opened.
	It("returns to the shared bucket once Redis is back", func() {
		proxy := newSwitchProxy(redisAddr)
		l := newTestRedisLimiter(proxy.addr(), uniquePrefix(), RedisFailureLocal, 100*time.Millisecond)
		l.cooldown = 100 * time.Millisecond
		rl := &platformv1.GPUQuotaRateLimit{RequestsPerMinute: 1, Burst: 2}

		for range 2 {
			ok, _, err := l.Decide(ctx, "t", rl)
			Expect(err).NotTo(HaveOccurred())
			Expect(ok).To(BeTrue())
		}
		ok, _, _ := l.Decide(ctx, "t", rl)
		Expect(ok).To(BeFalse(), "the shared bucket of two was not emptied")

		proxy.setCut(true)
		ok, _, err := l.Decide(ctx, "t", rl)
		Expect(err).NotTo(HaveOccurred())
		Expect(ok).To(BeTrue(), "during the cut the local bucket, still full, should have decided")
		Expect(l.down.Load()).To(BeTrue())

		// A connection the cut closed may fail the first call after it, so recovery is probed with another tenant,
		// whose calls spend nothing of t's local bucket, which still holds one token.
		proxy.setCut(false)
		probe := &platformv1.GPUQuotaRateLimit{RequestsPerMinute: 6000, Burst: 1000}
		Eventually(func() bool {
			_, _, _ = l.Decide(ctx, "probe", probe)
			return l.down.Load()
		}, "3s", "50ms").Should(BeFalse(), "the limiter never went back to Redis")
		ok, _, err = l.Decide(ctx, "t", rl)
		Expect(err).NotTo(HaveOccurred())
		Expect(ok).To(BeFalse(), "after Redis came back the local bucket, not the empty shared one, decided")
	})

	// The series docs/05 and the design page name are the ones /metrics serves.
	// It runs last, because the degraded counter has a series only once a spec above has decided without Redis.
	It("publishes the documented series", func() {
		names := registeredNames()
		for _, n := range []string{
			"gpuaas_gateway_ratelimit_redis_seconds", "gpuaas_gateway_ratelimit_redis_errors_total",
			"gpuaas_gateway_ratelimit_degraded_decisions_total", "gpuaas_gateway_ratelimit_redis_available",
		} {
			Expect(names).To(HaveKey(n))
		}
	})
})
