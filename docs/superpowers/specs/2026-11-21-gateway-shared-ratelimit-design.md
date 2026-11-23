# Gateway shared rate limit: one tenant budget across replicas

Date: 2026-11-21. Status: implemented with this page; kind verification in `hack/gateway-shared-ratelimit/`.

## Problem

The gateway keeps each tenant's token bucket in process memory (`bucketRegistry` in `internal/gateway/ratelimit.go`).
`config/gateway/deployment.yaml` pins `replicas: 1` because a second replica gets a second set of buckets.
That was measured on 2026-10-09 (`experiments/gateway-replica-limit/README.md`): two replicas admitted 68 requests against a one-bucket bound of 34.90, 1.95x, in all three repetitions.

So the gateway cannot scale out, and a gateway Pod restart is a full outage of the serving path (about 4.5 s with no answer in the same experiment's void first run).
This change lets the gateway run at three replicas with each tenant's limit applied once, across all of them.

Scope is deliberately narrow.
Only the per-tenant request limit moves to shared state.
HoldCap admission, the process-wide holding admitters and the routing index stay per-process, and this page says what that requires.

## Decision

A `RateLimiter` interface in the gateway with two implementations:

- `memory`, the existing `bucketRegistry`, unchanged and still the default.
- `redis`, a token bucket evaluated by one Lua script per request in a single Redis.

`--rate-limit-store=memory|redis` selects one.
With no flag the gateway behaves exactly as before, and every existing test runs against the memory store unchanged.

### The two supported profiles

Only two combinations are claimed.
Every other combination makes no multi-replica claim.

| profile | store | replicas | `--admission-mode` | backends | rollout |
|---|---|---|---|---|---|
| **single-instance** (the shipped manifest) | `memory` | 1 | any | any, HoldCap and `PrefixAffinity` included | `Recreate` |
| **shared-limit** | `redis` | 1 or more | `off` only | default ordering, `RoundRobin` or `LeastQueue`; no HoldCap, no `PrefixAffinity` | any |

The shared-limit profile shares the tenant rate limit and nothing else.
How each part is checked, and what is not, is in "What stays per-process" below.

### The limiter interface

```go
type RateLimiter interface {
	Decide(ctx context.Context, tenant string, rl *platformv1.GPUQuotaRateLimit) (allowed bool, wait time.Duration, err error)
}
```

- `allowed == false, err == nil` is budget exhaustion: 429 `rate_limited`, with `Retry-After` from `wait` when there is one.
- `err != nil` is "could not decide": 503 `rate_limit_unavailable` with `Retry-After: 1`. Only the redis store under the `closed` policy returns it. It never becomes a 429, which tells a caller it spent a budget nobody measured.
- `ctx` is the request's; the redis store wraps it in a deadline of `--rate-limit-redis-timeout`. A caller that leaves is returned as its own context error and does not open the breaker.
- Neither store retries. The memory store cannot fail; the redis store sends each script once (below).

### Algorithm: a token bucket in one Lua script

Each call runs one script, `EVALSHA` with `EVAL` on `NOSCRIPT`, against one key:

1. read `TIME` from Redis, in microseconds;
2. read the tenant's hash (`tokens`, `ts`, and the `rpm` and `burst` of the last call); a missing key is a full bucket;
3. refill the time since the last call at the stored rate, capped at the stored burst, then clamp to this call's `burst`: `tokens = min(burst, min(prev_burst, tokens + max(0, now - ts) * prev_rate))`, with rates `requestsPerMinute / 60` per second;
4. if `tokens >= 1`, spend one and admit; otherwise refuse and compute the wait until one token, `(1 - tokens) / rate`;
5. write `tokens`, `ts = max(ts, now)` and this call's `rpm` and `burst`, and set the key to expire once the bucket would be full again.

Redis runs a script to completion before any other command, so the read, the refill and the spend are one step for every replica.
That is what makes N replicas share one budget rather than N budgets: there is no read-then-write window for two replicas to both see the last token.

The semantics match the memory store on purpose, so switching stores does not change what a tenant gets:

- `rate` and `burst` arrive as arguments on every call, so an edited policy takes effect on the next request and keeps the tokens already accumulated, as `SetLimit`/`SetBurst` do in memory; a key is never rebuilt on a policy change, which would hand out a fresh burst.
- The time before an edit is refilled at the policy that was in force over it, as `rate.Limiter.SetLimitAt` advances before it switches. The first version refilled the whole gap at the new rate, so raising a rate granted a burst the tenant never accrued (`fb1de164`, fixed in `b5718338`).
- A refusal spends nothing.
- A nil `rateLimit` is unlimited and never reaches Redis.
- The refusal's wait becomes `Retry-After` through the same `retryAfterSeconds` as today.

The algorithm is the token bucket, not GCRA; Lua is only the vehicle that makes it atomic.
A token bucket was chosen because it is the memory store's own model (`rate.Limiter`), so the full initial burst, the clamp to `burst` and the keep-tokens-on-edit rule carry over unchanged.

The expiry is `ceil(burst / rate)` seconds plus one, recomputed on every call with that call's policy.
After that long an untouched bucket is full, and a missing key also reads as full, so expiry discards nothing a tenant was owed and idle tenants do not accumulate keys.
The expiry is never shorter than the refill: it is the time to refill from empty, plus a second.

#### Cases the script has to get right

| case | what happens | cost |
|---|---|---|
| policy edited | the gap since the last call refills at the stored old policy, then tokens are clamped to the new `burst` and the new `rate` applies from now; no key carries a policy version, so an edit never grants a burst | none |
| replicas see different policy versions (cache lag) | each call refills the gap at the policy the previous caller stored, then applies its own; a smaller `burst` clamps the tokens, a larger one only lets them refill higher; both converge when the caches do | a mix of the two policies for the lag, never a fresh burst |
| a burst raised, then the key idle past the old policy's expiry | the key expired under the old expiry and reads as full under the new `burst` | at most `new burst - old burst` once, the same as a tenant the memory store sees for the first time |
| Redis restarted without persistence, or the key evicted | a missing key reads as full | one burst per tenant; run Redis with `maxmemory-policy noeviction`, under which a full Redis fails the write and the failure policy decides |
| a reply lost after the script ran | the token was spent in Redis, the call is a failure, and the failure policy decides that request | at most one token per lost reply; never two, because nothing retries |
| `NOSCRIPT` (script cache flushed or Redis restarted) | `Run` sends `EVALSHA`, and on `NOSCRIPT` sends `EVAL` with the body, which is not a retry: the first attempt ran nothing | one extra round trip |
| pool exhausted | the wait for a connection is bounded by the same timeout (`PoolTimeout` and the call's context), then the call is a failure | the failure policy, as for any other |
| Redis `TIME` steps backwards | elapsed time is `max(0, now - ts)` and `ts` never decreases, so refill stalls until the clock passes `ts` | a tenant refills late by the step; never early |
| Redis `TIME` steps forwards | the step counts as elapsed time, and refill is clamped at `burst` | at most one burst early |

### Clock: Redis `TIME`, never the Pod's

Refill is computed from `TIME` read inside the script, so every replica measures elapsed time on one clock.
Pod clocks can disagree by tens of milliseconds on one node and more across nodes, and a replica whose clock ran ahead would refill a bucket another replica had just emptied.
Since Redis 5 a script's writes replicate as effects, not as the script, so calling `TIME` before a write is allowed; Redis 7.4 is pinned (`redis:7.4.7-alpine` by digest).
`TIME` is the Redis host's wall clock, not a monotonic one; the two directions it can step are in the table above.

### Key schema

`<prefix><tenant>`, with `--rate-limit-redis-key-prefix` defaulting to `gpuaas:gateway:ratelimit:v1:`.

- One key per tenant, a hash with fields `tokens`, `ts`, `rpm` and `burst`.
- The prefix is fixed per deployment, so the key is injective in the tenant name and two tenants never share a bucket.
- `v1` names the hash layout, so a later layout can take a new prefix rather than misread old state.
- One key per script call, so the script also runs unchanged on Redis Cluster.

### When Redis cannot answer

`--rate-limit-redis-failure-policy=local|closed`, default `local`.

| policy | a request while Redis is unavailable | worst case |
|---|---|---|
| `local` (default) | decided by this replica's own in-memory bucket, the memory store's code | a tenant gets up to N times its limit across N replicas, the pre-change behaviour at N replicas |
| `closed` | refused with 503 `rate_limit_unavailable` and `Retry-After: 1` | every request through the gateway refused for the outage |

Why `local` is the default:

- `closed` makes Redis a single point of failure for all inference: a Redis restart becomes a gateway outage for every tenant.
- Fail-open (admit everything) removes the limit entirely while Redis is down.
  `local` is never weaker than fail-open and is bounded: at most `replicas x (burst + rate x T)`, measured on kind below.
- The degradation is visible, not silent: a counter of degraded decisions, a gauge of the store's state, and a log line on each transition.

`closed` is there for a deployment where over-admission costs more than refusal.
Its refusal is 503, not 429: a 429 tells the caller it exceeded its budget, which nobody measured, and `internal/bench/report.go` reads 429 as the admission guard shedding work.
That is the same reasoning as an uninstalled limiter, which already answers 503.

A failed call opens a one-second breaker: for that second the replica decides by its policy without calling Redis, so an outage does not add the Redis timeout to every request.
The first call after the second tries Redis again, so recovery takes at most a second after Redis is back.

### Connection and timeouts

| setting | value | why |
|---|---|---|
| `--rate-limit-redis-addr` | required with `redis` | a typo must stop the gateway, not degrade it silently |
| `--rate-limit-redis-timeout` | 100 ms | dial, read, write and the call's context; the limiter sits in front of LLM requests that take seconds, and a same-cluster Redis answers in well under a millisecond |
| retries | 0 | a retried script whose reply was lost would spend a second token; a lost reply is a failure handled by the policy |
| `--rate-limit-redis-password-file` | optional | read once at start; an empty or missing named file stops the gateway, as `--metrics-bearer-token-file` does |
| pool | go-redis default size (10 per CPU), `PoolTimeout` = the timeout | one short script per request; waiting for a connection is bounded like everything else |
| context deadline on the socket | on (`ContextTimeoutEnabled`) | go-redis otherwise bounds each read by the read timeout alone, so `EVALSHA`, `NOSCRIPT` and `EVAL` could take twice the timeout and still succeed (`fb1de164`, fixed in `b5718338`) |
| dial attempts | 1 | go-redis redials five times with backoff by default, which the deadline would cut short anyway |

Redis does not gate readiness.
Under `local` a replica without Redis can still serve, and under `closed` a 503 that names the cause is more useful than a Service with no endpoints.

### Metrics

| series | type | meaning |
|---|---|---|
| `gpuaas_gateway_ratelimit_redis_seconds` | histogram | one script call's latency, failures included |
| `gpuaas_gateway_ratelimit_redis_errors_total` | counter | calls that failed (timeout, refused connection, script error) |
| `gpuaas_gateway_ratelimit_degraded_decisions_total{policy}` | counter | requests decided without Redis, by failure policy |
| `gpuaas_gateway_ratelimit_redis_available` | gauge | 1 while this replica uses Redis, 0 while its breaker is open |
| `gpuaas_gateway_single_gateway_refusals_total{feature}` | counter | requests refused because a per-process feature met a shared store (next section) |

`gpuaas_gateway_rate_limited_total{tenant}` keeps counting refusals by budget under either store.

What the existing latency series do not show:
`gpuaas_gateway_time_to_first_byte_seconds` is stamped when the first response byte reaches the client and counts error responses too (`proxy.go`), so it is not TTFT; and `gpuaas_gateway_request_duration_seconds` starts just before admission, after the rate limit, so neither includes the Redis call.
`ratelimit_redis_seconds` is the series that measures what the shared store adds to a request.

### What stays per-process, and how that is enforced

The rate limit is the only state this change shares.
These keep their state in one gateway process, so at N replicas each replica would apply its own:

| feature | where it is chosen | state | at N replicas |
|---|---|---|---|
| HoldCap | an `InferenceDeployment`'s `admission.mode`, at run time | serial-prefill turn order per backend | N prefills at once where the cap was measured with one |
| `PrefixAffinity` | an `InferenceDeployment`'s `routing.policy`, at run time | the prefix index | each replica learns a third of the prefixes; the measured hit ratio does not apply |
| `static-cap`, `prospective` | `--admission-mode`, at start | per-backend token and stream budgets | budgets multiplied by N |
| `serial-prefill`, `fixed-spacing` | `--admission-mode`, at start | turn order and spacing per backend | N turns at once |
| `kv-aware` | `--admission-mode`, at start | engage and release hysteresis per backend, its own scrapers | N replicas engage and release on their own; not shown correct at more than one |
| `LeastQueue` | `routing.policy` | outstanding requests this process sent | each replica balances only its own traffic |
| `RoundRobin` | `routing.policy` | a counter per model | each replica rotates on its own |
| hold budget | `--admission-hold-*` | held requests and bytes | stays per process on purpose: it protects this Pod's memory, and under the shared-limit profile nothing holds, because the only holders are refused |

`LeastQueue` and `RoundRobin` stay allowed: they spread load and promise no bound, so at N replicas they spread less evenly and break nothing they claim.
`LeastQueue` balances on a third of the traffic each at three replicas, which is a weaker signal and has not been measured.

Enforcement, in the three places a profile can be broken:

1. **At start.** `--rate-limit-store=redis` with any `--admission-mode` but `off` refuses to start (`CheckSharedStoreAdmission`).
2. **Per request.** Under the redis store, a request whose head backend is HoldCap, or whose backends select `PrefixAffinity`, is refused with 503 `single_gateway_required` and counted in `single_gateway_refusals_total{feature}`, before routing records anything. This is what holds when an `InferenceDeployment` changes after the gateway started, which a start-time check cannot see.
3. **In the shipped manifest.** `config/gateway/deployment.yaml` is the single-instance profile: memory store, `replicas: 1`, `strategy: Recreate`. `TestGatewayManifestIsTheSingleInstanceProfile` holds the file to that.

What is **not** enforced, and is not called enforced:

- Scaling the memory-store Deployment past one replica. The gateway cannot read Deployments (`config/gateway/rbac.yaml` grants it the two CRDs and its Secret), and no admission policy guards the count. The manifest test checks the file, not the cluster. The cost of breaking it is measured: 1.95x at two replicas, and the kind run below at three.
- Several memory-store gateways started some other way (two Deployments, a manual Pod). Nothing can see them from inside one process without a coordination point, which is what Redis is here.

The redis store is the declaration that replicas may be more than one, because a single replica gets nothing from it but a network dependency.
So the gateway takes it to mean "more than one may be running" and refuses what that would silently break.

Why refuse rather than degrade:
HoldCap's protection is the serialisation itself, and `holdCapTargets` already refuses to send a request into a capped engine without its hold; serving it unheld would be the failure HoldCap exists to prevent, under a status that still reports HoldCap.
`PrefixAffinity` degraded to default ordering would serve, but a study registered and read under `PrefixAffinity` would then be measuring something else under its name.
In this repository a configuration that quietly does something other than what it says is the failure worth preventing, so both are loud: a deployment that needs either runs the single-instance profile.

#### The rollout overlap

The shipped manifest had no `strategy`, so it got RollingUpdate with the default 25% surge, which at one replica starts the new Pod before the old one is gone.
Every rollout therefore ran two gateways for a while, each with its own buckets, serial-prefill turns and prefix index (docs/05 listed this as a known HoldCap gap).
`Recreate` removes that: the new Pod starts only after the old one has terminated, drain included.
The cost is a gap with no serving Pod during each rollout, from the old Pod's readiness turning off to the new one's turning on; that is not measured here.
`maxSurge: 0` was not used, because RollingUpdate counts a terminating Pod as gone and starts the new one during the old one's 25-second drain.

#### An alert that would mislead at several replicas

`GatewayKVGuardNotReporting` (`config/prometheus/gateway_rules.yaml`) joins with `unless on()`, so one Pod reporting fresh telemetry hides another Pod that reports none.
It is correct for one replica.
The shared-limit profile refuses `kv-aware`, so the alert cannot fire wrongly under a supported profile, and it is left unchanged; extending `kv-aware` to several replicas would have to join it per Pod first.

## Alternatives considered

| alternative | why not |
|---|---|
| GCRA (one theoretical-arrival-time value per tenant) | equivalent admissions for a fixed policy and one field smaller, but a burst or rate edit reinterprets the stored time and does not keep accumulated tokens the way the memory store does; matching that store matters more than one field |
| fixed or sliding window counters (Redis INCR with an expiry) | a fixed window admits up to twice the limit across a boundary, and neither has a burst separate from the rate, which `GPUQuotaRateLimit` requires |
| divide each replica's budget by the replica count | needs the count, which changes during rollouts and autoscaling; a stale count gives a wrong limit with no error, which is the original problem |
| client-side read, compute, `SET` with `WATCH`/`MULTI` | two round trips, and contention between replicas turns into retries under exactly the load the limiter exists for |
| Pod clock passed as a script argument | refill would depend on each replica's clock; `TIME` inside the script is one clock |
| Envoy-style rate-limit service, or a token service | another deployment and protocol for one counter per tenant; the gateway already is the policy point |
| `redis_rate` or another library | the semantics above (policy edits keep tokens, a refusal spends nothing, the wait for `Retry-After`) would be adapted around rather than stated; the script is about 30 lines and tested directly |
| fail-open on Redis failure | strictly weaker than `local`, which is fail-open with a bound |
| Redis Sentinel or Cluster now | one Redis is enough to prove the property; the single-key script runs on Cluster unchanged, and the failure policy covers a Redis outage meanwhile |

## Not covered

- Limiter high availability. This is one Redis. Sentinel or a replica failover would not make it HA for this purpose: replication is asynchronous, so a failover can lose acknowledged spends and hand tokens back. The kind run uses one Redis Pod with no persistence; a restart empties every bucket, which hands each tenant one burst.
- TLS to Redis.
- Sharing HoldCap, the holding admitters or the prefix index. Each would need its own design: HoldCap's turn order is a distributed lock with a lease per backend, which is a different problem from a counter.
- Gateway autoscaling. Nothing scales the gateway; the replica count is set by hand.

## Verification

- Unit tests against a real Redis 7.4 started by testcontainers-go (`internal/gateway/ratelimit_redis_test.go`).
  miniredis was not used: it runs scripts on gopher-lua and implements `TIME` itself, so a test passing there says how miniredis behaves, and the property this change rests on is the real server's script atomicity.
  - three limiters with their own clients and one Redis, 600 concurrent attempts, admit exactly the burst;
  - refill and the `Retry-After` wait follow the policy's rate;
  - a policy edit keeps the tokens already spent;
  - two tenants never share a bucket;
  - `local` falls back to an in-memory bucket, `closed` refuses, both within the timeout, the breaker stops calls for its second, and the limiter returns to Redis once it is back.
- Each property test was run against a mutation that breaks it; the mutations and their results are in `hack/gateway-shared-ratelimit/2026-11-21-run1/`.
- Pipeline tests with a fake shared limiter: HoldCap and `PrefixAffinity` refused with 503 under the shared store and served under memory; `closed` answers 503, not 429.
- kind: the gateway at 1 and 3 replicas on the memory store, and at 3 on the redis store, one tenant at 10 requests per second for 30 s against `requestsPerMinute: 60, burst: 5`; a Redis-down arm and a gateway Pod deletion during load. Results in `hack/gateway-shared-ratelimit/2026-11-21-run1/README.md`.
