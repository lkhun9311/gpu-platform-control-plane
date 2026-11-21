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
	"errors"
	"fmt"
	"strconv"
	"sync/atomic"
	"time"

	"github.com/redis/go-redis/v9"
	"sigs.k8s.io/controller-runtime/pkg/log"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// RedisFailurePolicy is what the shared limiter does with a request while Redis cannot answer.
type RedisFailurePolicy string

const (
	// RedisFailureLocal decides by this replica's own in-memory bucket, so an outage costs at most N times the limit across N replicas.
	RedisFailureLocal RedisFailurePolicy = "local"
	// RedisFailureClosed refuses with 503, for a deployment where over-admission costs more than refusal.
	RedisFailureClosed RedisFailurePolicy = "closed"
)

const (
	// DefaultRedisKeyPrefix carries a layout version, so a later hash layout takes a new prefix rather than misreading this one.
	DefaultRedisKeyPrefix = "gpuaas:gateway:ratelimit:v1:"
	// DefaultRedisTimeout bounds one call; a same-cluster Redis answers in well under a millisecond, and the limiter sits in front of requests that take seconds.
	DefaultRedisTimeout = 100 * time.Millisecond
	// redisBreakerCooldown is how long a replica stops calling Redis after a failure, so an outage does not add the timeout to every request.
	redisBreakerCooldown = time.Second
)

// ErrRateLimitUnavailable is the closed policy's answer while Redis cannot decide.
var ErrRateLimitUnavailable = errors.New("shared rate limit store unavailable")

// RedisRateLimitConfig is everything the shared limiter is built from.
type RedisRateLimitConfig struct {
	Addr          string
	Password      string
	KeyPrefix     string
	Timeout       time.Duration
	FailurePolicy RedisFailurePolicy
}

// Validate refuses a configuration that could not mean what it says.
// An empty address is refused rather than defaulted, because a gateway pointed at no Redis would run degraded forever and look configured.
func (c RedisRateLimitConfig) Validate() error {
	if c.Addr == "" {
		return errors.New("the redis rate limit store needs an address")
	}
	if c.KeyPrefix == "" {
		return errors.New("the redis rate limit store needs a key prefix")
	}
	if c.Timeout <= 0 {
		return fmt.Errorf("the redis rate limit timeout must be above zero, got %s", c.Timeout)
	}
	switch c.FailurePolicy {
	case RedisFailureLocal, RedisFailureClosed:
		return nil
	}
	return fmt.Errorf("unknown redis failure policy %q: want local or closed", c.FailurePolicy)
}

// tokenBucketScript is the whole limiter: refill, spend and write in one step Redis runs to completion before any other command.
// That is what makes N replicas share one budget: no replica can read the last token between another's read and write.
//
// Time comes from Redis TIME, so every replica refills on one clock; since Redis 5 a script's writes replicate as
// effects, which is what allows a non-deterministic TIME before a write.
// ts never moves backwards, so a Redis clock that steps back stalls refill instead of granting tokens.
// rate and burst arrive on every call, so a policy edit keeps the tokens already accumulated, as SetLimit and SetBurst do
// in the memory store.
// The key expires once the bucket would be full again, and a missing key reads as full, so expiry discards nothing.
// Numbers are written with %.17g because Redis would otherwise format them with fewer digits, and ts in microseconds
// has sixteen.
//
// KEYS[1] is the tenant's hash; ARGV[1] is requestsPerMinute and ARGV[2] is burst.
// It returns {1, 0} when admitted and {0, microseconds until one token} when refused, the wait 0 when there is none.
var tokenBucketScript = redis.NewScript(`
local t = redis.call('TIME')
local now = tonumber(t[1]) * 1000000 + tonumber(t[2])
local per_us = tonumber(ARGV[1]) / 60000000
local burst = tonumber(ARGV[2])
local s = redis.call('HMGET', KEYS[1], 'tokens', 'ts')
local tokens = tonumber(s[1])
local ts = tonumber(s[2])
if tokens == nil or ts == nil then
  tokens = burst
  ts = now
end
if now > ts then
  if per_us > 0 then
    tokens = tokens + (now - ts) * per_us
  end
  ts = now
end
if tokens > burst then
  tokens = burst
end
local allowed = 0
local wait = 0
if tokens >= 1 then
  tokens = tokens - 1
  allowed = 1
elseif per_us > 0 then
  wait = math.ceil((1 - tokens) / per_us)
end
redis.call('HSET', KEYS[1], 'tokens', string.format('%.17g', tokens), 'ts', string.format('%.17g', ts))
if per_us > 0 then
  redis.call('PEXPIRE', KEYS[1], math.ceil(burst / per_us / 1000) + 1000)
else
  redis.call('PEXPIRE', KEYS[1], 86400000)
end
return {allowed, wait}
`)

// redisLimiter is the RateLimiter every gateway replica shares through one Redis.
type redisLimiter struct {
	client  *redis.Client
	prefix  string
	timeout time.Duration
	policy  RedisFailurePolicy
	// local decides under the local policy while Redis cannot, with the memory store's own code.
	local *bucketRegistry
	// openUntil is the UnixNano before which this replica does not call Redis, the breaker after a failure.
	openUntil atomic.Int64
	// down records the last state logged, so an outage logs once on the way in and once on the way out rather than per request.
	down atomic.Bool
	// cooldown is redisBreakerCooldown, a field so a test can prove the breaker without waiting a second per case.
	cooldown time.Duration
}

// newRedisLimiter builds the limiter without contacting Redis, because under the local policy a gateway that starts
// during a Redis outage can still serve.
func newRedisLimiter(cfg RedisRateLimitConfig) (*redisLimiter, error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	client := redis.NewClient(&redis.Options{
		Addr:         cfg.Addr,
		Password:     cfg.Password,
		DialTimeout:  cfg.Timeout,
		ReadTimeout:  cfg.Timeout,
		WriteTimeout: cfg.Timeout,
		// No retries: a script whose reply was lost may already have spent the token, and running it again would spend a second.
		MaxRetries: -1,
		// One dial per call: the client's default redials five times with backoff, which the call's deadline would cut short anyway.
		DialerRetries: 1,
		// The pool's default wait is the read timeout plus a second; an exhausted pool is a failure at the same bound as any other.
		// The call's context bounds it as well, so this states the bound rather than relying on that.
		PoolTimeout: cfg.Timeout,
	})
	redisAvailable.Set(1)
	return &redisLimiter{
		client:   client,
		prefix:   cfg.KeyPrefix,
		timeout:  cfg.Timeout,
		policy:   cfg.FailurePolicy,
		local:    newBucketRegistry(),
		cooldown: redisBreakerCooldown,
	}, nil
}

// Close releases the connection pool.
func (l *redisLimiter) Close() error { return l.client.Close() }

// Decide runs the script for tenant, or decides by the failure policy while Redis cannot answer.
func (l *redisLimiter) Decide(ctx context.Context, tenant string, rl *platformv1.GPUQuotaRateLimit) (bool, time.Duration, error) {
	// An unlimited tenant needs no state, and must not depend on Redis being up.
	if rl == nil {
		return true, 0, nil
	}
	if time.Now().UnixNano() < l.openUntil.Load() {
		return l.degraded(tenant, rl)
	}
	callCtx, cancel := context.WithTimeout(ctx, l.timeout)
	defer cancel()
	start := time.Now()
	res, err := tokenBucketScript.Run(callCtx, l.client, []string{l.prefix + tenant},
		strconv.FormatInt(int64(rl.RequestsPerMinute), 10), strconv.FormatInt(int64(rl.Burst), 10)).Int64Slice()
	redisSeconds.Observe(time.Since(start).Seconds())
	if err != nil {
		// A caller that left is not a Redis failure, and tripping the breaker on it would degrade every other tenant.
		if ctx.Err() != nil {
			return false, 0, ctx.Err()
		}
		redisErrors.Inc()
		l.trip(ctx, err)
		return l.degraded(tenant, rl)
	}
	l.answered(ctx)
	if len(res) != 2 {
		// Only a different script could answer this, so it is a fault in this binary and is treated as Redis failing.
		redisErrors.Inc()
		l.trip(ctx, fmt.Errorf("token bucket script returned %d values, want 2", len(res)))
		return l.degraded(tenant, rl)
	}
	return res[0] == 1, time.Duration(res[1]) * time.Microsecond, nil
}

// degraded decides without Redis, by the failure policy.
func (l *redisLimiter) degraded(tenant string, rl *platformv1.GPUQuotaRateLimit) (bool, time.Duration, error) {
	redisDegraded.WithLabelValues(string(l.policy)).Inc()
	if l.policy == RedisFailureLocal {
		ok, wait := l.local.Reserve(tenant, rl)
		return ok, wait, nil
	}
	return false, 0, ErrRateLimitUnavailable
}

// trip opens the breaker for the cooldown and logs the first failure of an outage.
func (l *redisLimiter) trip(ctx context.Context, err error) {
	l.openUntil.Store(time.Now().Add(l.cooldown).UnixNano())
	redisAvailable.Set(0)
	if !l.down.Swap(true) {
		log.FromContext(ctx).Error(err, "Redis rate limit store failed; deciding by the failure policy",
			"policy", string(l.policy), "cooldown", l.cooldown.String())
	}
}

// answered logs the end of an outage once.
func (l *redisLimiter) answered(ctx context.Context) {
	if l.down.Swap(false) {
		redisAvailable.Set(1)
		log.FromContext(ctx).Info("Redis rate limit store answered again; the shared budget is in force")
	}
}
