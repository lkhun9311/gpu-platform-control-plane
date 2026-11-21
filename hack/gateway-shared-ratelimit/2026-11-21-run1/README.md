# Shared gateway rate limit on kind, run 1 (2026-11-21)

Design: `docs/superpowers/specs/2026-11-21-gateway-shared-ratelimit-design.md`.
Scripts: `hack/gateway-shared-ratelimit/run.sh` (cluster, arms), `score.py` (counts), `mutate.py` (mutation runs).
Files here: `log.txt` (full run log), `arms.tsv`, one `<arm>-<rep>.tsv` per arm (one row per request), `score.txt`, `mutations.tsv` and `mutations.log`.

## Setup

- Tree `33b6a75`; its `cmd/` and `internal/` are `f951fa8`'s, and the log records 0 uncommitted files under them.
- After this run, `b571833` changed two things: the script refills the gap before a policy edit at the stored old policy, and one context deadline bounds the whole Redis call. Under the constant policy every arm here used, the first change does not alter what is admitted. The second can change an outcome when `EVALSHA` plus `EVAL` exceeds the timeout, because the failure policy then decides. Neither was re-measured on kind. The unit tests and the mutations below ran at `b571833`.
- A throwaway single-node kind cluster `gwshared` with its own kubeconfig in a temporary directory; `~/.kube/config` was not read or written (its checksum matched before and after), and the cluster was deleted at the end (`cluster gwshared deleted: yes` in the log).
- The operator, the gateway and the stub backend (`benchharness stub-serve`) built from that tree; Redis `redis:7.4.7-alpine` (`sha256:02f2cc48…bfcf`, checked against the pulled image) as one Pod with no persistence.
- One tenant, `rateLimit: {requestsPerMinute: 60, burst: 5}`: one token a second, a bucket of five.
- Load from `experiments/gateway-replica-limit/loadgen`: open loop, 10 requests a second for 30 s, a new connection per request, so kube-proxy picks a Pod per request.
- One bucket admits at most `bound = 5 + T` in `T` seconds; every arm had `T` = 29.90 s, so `bound` = 34.90.
- 10 idle seconds before each arm, so every bucket, in Redis and in every Pod, starts full.

`score.py` printed **VALID**: every arm sent 300 requests, the stub's served count equalled the client's 200 count in every arm, events included, and the `memory-1` control admitted within `[bound - 2, bound + 1]`.

## Readings

| arm | replicas | store | rep 1 | rep 2 | rep 3 | admitted / bound |
|---|---:|---|---:|---:|---:|---:|
| `memory-1` (control) | 1 | memory | 34 | 34 | 34 | 0.97 |
| `memory-3` | 3 | memory | **102** | **102** | **102** | **2.92** |
| `redis-3` | 3 | redis | **34** | **34** | **34** | **0.97** |

- **Three replicas on the memory store admitted 102, three buckets of 34.** Every refusal was a 429.
- **Three replicas on the redis store admitted 34, the one-bucket bound**, in all three repetitions.
- The traffic did reach all three Pods in the redis arms: per-Pod 200 counts were 7/16/11, 13/12/9 and 12/11/11 (`arms.tsv`, `pods_after`), and `degraded_decisions_total` and `redis_errors_total` stayed 0 on every Pod.
- The repetitions are identical because the arithmetic is deterministic at this load; they show the count does not drift, not a precision to two decimals.

### Redis stopped under load (`--rate-limit-redis-failure-policy=local`, the default)

Redis scaled to 0 at 10.01 s and back to 1 (ready) at 20.63 s.

| window | 200 | 429 | errors | one bucket |
|---|---:|---:|---:|---:|
| before, 0 to 10.01 s | 15 | 86 | 0 | 15.0 |
| outage, 10.01 to 20.63 s | **44** | 62 | 0 | 10.6 refill |
| after, 20.63 to 29.90 s | 16 | 77 | 0 | 9.3 refill |

- No request failed: the outage cost the limit, not availability.
- During the outage each Pod decided on its own full bucket: 44 admitted, against `3 x (5 + 10.6)` = 46.8 for three independent buckets and 10.6 for the shared one, so 4.1 times the shared refill and within the three-bucket bound the design states.
- After Redis came back, the first second admitted 5 (seconds 20 to 22: 2, 4, 5): the new Redis was empty and a missing key is a full bucket, the documented cost of a Redis without persistence.
- Per Pod, `degraded_decisions_total` rose by 41, 39 and 38 and `redis_errors_total` by 10, 9 and 9: about one failed call per second per Pod, which is the one-second breaker working.

### Redis stopped under load (`closed`)

| window | 200 | 429 | 503 | one bucket |
|---|---:|---:|---:|---:|
| before, 0 to 10.01 s | 14 | 87 | 0 | 15.0 |
| outage, 10.01 to 20.66 s | 1 | 0 | **105** | 10.7 refill |
| after, 20.66 to 29.90 s | 12 | 66 | 15 | 9.2 refill |

- Every request in the outage was refused with 503 `rate_limit_unavailable`, none with 429. The one 200 in the window was sent at 10.10 s, 0.09 s after the scale-down was issued and before the Redis Pod had stopped answering; the first 503 was sent at 10.20 s.
- 503s continued until 22.10 s, 1.4 s after Redis was ready: the Service endpoint update plus up to one second of breaker. Then the empty Redis gave a burst of 5, as above.
- The three Pods' `degraded_decisions_total` summed to 120, the client's 503 count.

### One gateway Pod killed under load (redis store, `--grace-period=0 --force`)

Killed at 15.04 s; three ready endpoints again at 26.27 s, 11.2 s later.

- **One request failed** (connection reset, sent at 15.10 s); the other 299 were answered.
- **Admitted 34, the same as without the kill**, one per second throughout: the replacement Pod did not bring a fresh bucket, because the bucket is in Redis.
- For contrast (observation from a void run, `experiments/gateway-replica-limit/README.md`, Amendment 1): deleting the only Pod of the single-instance gateway left no answer for about 4.5 s and failed 41 to 52 requests at the same load.

## Mutations

`mutate.py`, run in a detached worktree at `b571833`, writes each mutation into the tree, runs the one test that guards its property, and reverts.
A build failure would be INVALID, not a kill, and every focused test first passed unmutated (`baseline` rows).
All **23 of 23** were KILLED. `mutations.tsv` has each failed assertion, with the values it saw where Gomega printed them on the lines the harness keeps; the right column says what the failed assertion checks, and gives a value only where one was recorded.

| mutation | test that failed | failed assertion |
|---|---|---|
| key per limiter instance | admits exactly the burst across three limiters | 300 admitted, want 100 |
| read and write the bucket from Go, not one script | same | 600 admitted, want 100 |
| refill 60x fast / no refill | refills at the policy's rate | the refusal and wait inside one refill period / "refused after the refill period had passed" |
| key versioned by rate and burst | keeps spent tokens across a policy edit | a fresh burst after the edit |
| refill the gap before an edit at the new rate | does not refill the time before a policy edit at the new rate | "the raised rate was applied to the 300 ms before the edit" |
| `ContextTimeoutEnabled` off | bounds an EVALSHA and EVAL pair by one timeout | "two 70 ms round trips finished inside a 100 ms bound" |
| key without the tenant | keeps tenants' buckets apart | `team:x` refused for `team`'s spending |
| no expiry | expires a tenant's key | the key's TTL |
| `closed` admits / `local` admits all / `local` refuses | the two failure-policy specs | "Expected an error, got nil" / the burst-then-refuse sequence / "Unexpected error" |
| no call deadline or read timeout | gives up on a hung Redis | test timed out at 90 s |
| no breaker | stops calling a failed Redis | 20 calls took 1.01 s, want under 50 ms |
| breaker never closes | returns to the shared bucket | still degraded after 3 s |
| `EVALSHA` without the `EVAL` fallback | decides after the script cache is flushed | "Unexpected error": the flushed cache was answered as an outage |
| HoldCap / `PrefixAffinity` not refused | the two pipeline refusal specs | the 503 status |
| an undecided request answered 429 | answers 503 `rate_limit_unavailable` | the 503 status |
| shared store accepts holding modes / `kv-aware` | `TestInstallRateLimiterRedisRefusesPerProcessAdmission` | "the redis store started with --admission-mode=..." |
| manifest RollingUpdate / two replicas | `TestGatewayManifestIsTheSingleInstanceProfile` | "strategy is \"\"" / "replicas is ..." |

## What this cannot show

- The latency the Redis call adds. `gpuaas_gateway_ratelimit_redis_seconds` measures it, and this run did not record it; the arms record counts only.
- Anything about GPUs, multi-node routing, or a Redis farther than one node away.
- Redis failover: there is one Redis, and the design does not claim high availability for the limiter.
- The single-instance profile's `Recreate` rollout gap; the arms switch stores by rollout but do not time it.
- `LeastQueue` or `RoundRobin` behaviour at three replicas; the stub is a single backend.
