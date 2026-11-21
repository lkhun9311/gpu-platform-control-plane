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

### Algorithm: a token bucket in one Lua script

Each call runs one script, `EVALSHA` with `EVAL` on `NOSCRIPT`, against one key:

1. read `TIME` from Redis, in microseconds;
2. read the tenant's hash (`tokens`, `ts`); a missing key is a full bucket;
3. refill: `tokens = min(burst, tokens + max(0, now - ts) * rate)`, with `rate = requestsPerMinute / 60` per second;
4. if `tokens >= 1`, spend one and admit; otherwise refuse and compute the wait until one token, `(1 - tokens) / rate`;
5. write `tokens` and `ts = max(ts, now)`, and set the key to expire once the bucket would be full again.

Redis runs a script to completion before any other command, so the read, the refill and the spend are one step for every replica.
That is what makes N replicas share one budget rather than N budgets: there is no read-then-write window for two replicas to both see the last token.

The semantics match the memory store on purpose, so switching stores does not change what a tenant gets:

- `rate` and `burst` arrive as arguments on every call, so an edited policy takes effect on the next request and keeps the tokens already accumulated, as `SetLimit`/`SetBurst` do in memory; a key is never rebuilt on a policy change, which would hand out a fresh burst.
- A refusal spends nothing.
- A nil `rateLimit` is unlimited and never reaches Redis.
- The refusal's wait becomes `Retry-After` through the same `retryAfterSeconds` as today.

The expiry is `ceil(burst / rate)` seconds plus one.
After that long an untouched bucket is full, and a missing key also reads as full, so expiry discards nothing a tenant was owed and idle tenants do not accumulate keys.

### Clock: Redis `TIME`, never the Pod's

Refill is computed from `TIME` read inside the script, so every replica measures elapsed time on one clock.
Pod clocks can disagree by tens of milliseconds on one node and more across nodes, and a replica whose clock ran ahead would refill a bucket another replica had just emptied.
Since Redis 5 a script's writes replicate as effects, not as the script, so calling `TIME` before a write is allowed; Redis 7.4 is pinned (`redis:7.4.7-alpine` by digest).
`ts = max(ts, now)` means a Redis clock that steps backwards stalls refill until it catches up rather than granting tokens.

### Key schema

`<prefix><tenant>`, with `--rate-limit-redis-key-prefix` defaulting to `gpuaas:gateway:ratelimit:v1:`.

- One key per tenant, a hash with fields `tokens` and `ts`.
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
| pool | go-redis default (10 per CPU) | one short script per request |

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

### What stays per-process, and how that is enforced

The rate limit is the only state this change shares.
These keep their state in one gateway process, so at N replicas each replica would apply its own:

| feature | where it is chosen | state | at N replicas |
|---|---|---|---|
| HoldCap | an `InferenceDeployment`'s `admission.mode`, at run time | serial-prefill turn order per backend | N prefills at once where the cap was measured with one |
| `PrefixAffinity` | an `InferenceDeployment`'s `routing.policy`, at run time | the prefix index | each replica learns a third of the prefixes; the measured hit ratio does not apply |
| `static-cap`, `prospective` | `--admission-mode`, at start | per-backend token and stream budgets | budgets multiplied by N |
| `serial-prefill`, `fixed-spacing` | `--admission-mode`, at start | turn order and spacing per backend | N turns at once |

`off` and `kv-aware` hold no budget of their own: kv-aware decides from the engine's own telemetry, which every replica reads the same.
`RoundRobin` and `LeastQueue` keep per-replica counters too, but only as load spreading; at N replicas they spread less evenly and promise nothing they then break, so they are left alone.

Enforcement, in two places, because the features are chosen in two places:

1. **At start.** `--rate-limit-store=redis` with `--admission-mode` other than `off` or `kv-aware` refuses to start (`CheckSharedStoreAdmission`).
2. **Per request.** With the redis store, a request whose head backend is HoldCap, or whose backends select `PrefixAffinity`, is refused with 503 `single_gateway_required` and counted in `single_gateway_refusals_total{feature}`, before routing records anything.

The redis store is the declaration that replicas may be more than one, because a single replica gets nothing from it but a network dependency.
So the gateway takes it to mean "more than one may be running" and refuses what that would silently break.

Why refuse rather than degrade:
HoldCap's protection is the serialisation itself, and `holdCapTargets` already refuses to send a request into a capped engine without its hold; serving it unheld would be the failure HoldCap exists to prevent, under a status that still reports HoldCap.
`PrefixAffinity` degraded to default ordering would serve, but a study registered and read under `PrefixAffinity` would then be measuring something else under its name.
In this repository a configuration that quietly does something other than what it says is the failure worth preventing, so both are loud: a deployment that needs either runs the gateway with the memory store at `replicas: 1`.

The memory store keeps everything as it was, including the known gap that a rolling update briefly runs two Pods.

## Alternatives considered

| alternative | why not |
|---|---|
| GCRA (one theoretical-arrival-time value per tenant) | equivalent admissions for a fixed policy and one field smaller, but a burst or rate edit reinterprets the stored time and does not keep accumulated tokens the way the memory store does; matching that store matters more than one field |
| fixed or sliding window counters (`INCR` + `EXPIRE`) | a fixed window admits up to twice the limit across a boundary, and neither has a burst separate from the rate, which `GPUQuotaRateLimit` requires |
| divide each replica's budget by the replica count | needs the count, which changes during rollouts and autoscaling; a stale count gives a wrong limit with no error, which is the original problem |
| client-side read, compute, `SET` with `WATCH`/`MULTI` | two round trips, and contention between replicas turns into retries under exactly the load the limiter exists for |
| Pod clock passed as a script argument | refill would depend on each replica's clock; `TIME` inside the script is one clock |
| Envoy-style rate-limit service, or a token service | another deployment and protocol for one counter per tenant; the gateway already is the policy point |
| `redis_rate` or another library | the semantics above (policy edits keep tokens, a refusal spends nothing, the wait for `Retry-After`) would be adapted around rather than stated; the script is about 30 lines and tested directly |
| fail-open on Redis failure | strictly weaker than `local`, which is fail-open with a bound |
| Redis Sentinel or Cluster now | one Redis is enough to prove the property; the single-key script runs on Cluster unchanged, and the failure policy covers a Redis outage meanwhile |

## Not covered

- High availability of Redis itself. The kind run uses one Redis Pod with no persistence; a restart empties every bucket, which hands each tenant one burst.
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
