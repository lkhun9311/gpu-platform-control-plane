# Shared gateway rate limit on kind, run 2 (2026-11-22)

Run 1: `../2026-11-21-run1/README.md`.
Design: `docs/superpowers/specs/2026-11-21-gateway-shared-ratelimit-design.md`.
Scripts: `hack/gateway-shared-ratelimit/run.sh` (cluster, arms) and `score.py` (counts).

## What was re-measured, and why

Run 1 judged each request by its HTTP status alone.
Its load generator drained the body with `io.Copy`, ignored the read error, and counted every 200 as success, so a stream cut after its 200 would have counted as served.
Run 2 repeats run 1's arms with a fixed judge, for 60 s instead of 30 s, and repeats each event arm three times instead of once.

- **The judge.** `experiments/gateway-replica-limit/loadgen` now sends every request through `internal/bench`'s `HTTPSender` and classifies it with `bench.DispositionOf`, the rule the benchmark harness records.
  Each row records the HTTP status and, apart from it, the outcome: `completed` (200 and `data: [DONE]` with no error), `stream_cut` (200, then a read error, an in-band error or no `[DONE]`), `rate_limited` (429), `http_5xx`, `http_other`, `timeout` (before or after a 200; the status column says which), `cancelled` (the loadgen itself was interrupted), `transport`, `unsent`.
  It also records `done`, the first content time and the whole-response latency.
  The summary line keeps its old first five fields; `ok` now means completed, not 200.
- **Admitted and completed are scored apart.** `score.py` calls a 200 *admitted* (the gateway let it through to the backend) and a 200 with `[DONE]` *completed*, and checks admitted against both `burst + rate x T` and the stub backend's own served count.
- **Trees.** The steady arms ran at `cd57226`, the event arms at `108f311`; the log records 0 uncommitted files under `cmd/` and `internal/` for both.
  Against the PR head before this work, `2a6136d`, those trees change only `internal/bench`, which `cmd/gateway` does not link (`go list -deps ./cmd/gateway` has no `internal/bench`), so the gateway and operator images are `2a6136d`'s code.
  That makes this the first kind run of `b571833` (refill at the old rate across a policy edit, one deadline over the whole Redis call), which run 1 did not measure.
- Everything else is run 1's setup: a throwaway single-node kind cluster `gwshared` with a private kubeconfig, deleted at the end of both runs (checked with `kind get clusters`); Redis `redis:7.4.7-alpine` at the pinned digest, one Pod, no persistence; one tenant at `rateLimit: {requestsPerMinute: 60, burst: 5}`; open loop at 10 requests a second, a new connection per request; 10 idle seconds before each arm.

## The test that shows the judge changed

`experiments/gateway-replica-limit/loadgen/main_test.go` runs the built command against an `httptest` server and reads only its stdout and TSV, so the same file runs against either version of `main.go`.
`TestCutStreamAfter200IsNotSuccess` answers 200, sends one content chunk, then closes the socket without `[DONE]` or the chunked terminator.
Output in `regression-test.txt`:

| | old `main.go` (`2a6136d`) | new `main.go` (`0e9aaa8`) |
|---|---|---|
| two streams cut after 200 | **FAIL: `ok=2`**, want 0 | PASS: `ok=0 status200=2 stream_cut=2` |
| 200, clean EOF, no `[DONE]` | **FAIL: `ok=2`** | PASS: `stream_cut=2` |
| complete stream (control) | `ok=2` as wanted; fails only on the outcome columns it does not write | PASS: `ok=2`, `done=1` |
| one 429, one 503 | fails: no `http5xx` field | PASS |
| deadline after the 200 | fails: no `-timeout` flag | PASS: `timeout=2`, status 200 kept |

The deciding line is the first: the old loadgen reports two cut streams as two successes.

## Steady arms, 60 s x 3 (`score.txt`)

`T` is first to last request write, 59.90 s in every arm, so one bucket admits at most `bound = 5 + 59.90 = 64.90`.

| arm | replicas | store | admitted rep 1 / 2 / 3 | completed | stub served | admitted / bound |
|---|---:|---|---|---|---|---:|
| `memory-1` (control) | 1 | memory | 64 / 64 / 64 | = admitted | = admitted | 0.99 |
| `memory-3` | 3 | memory | **192 / 192 / 192** | = admitted | = admitted | **2.96** |
| `redis-3` | 3 | redis | **64 / 64 / 64** | = admitted | = admitted | **0.99** |

- Range is zero in every arm: the count is deterministic at this load, as in run 1 (34, 102, 34 over 30 s).
- **Admitted equals the backend's served count in every arm**, and every admitted stream completed: no `stream_cut`, timeout or transport error in 5,400 requests.
- Three replicas on the memory store admitted three buckets' worth, 3 x 64; on the Redis store, one bucket's worth.
- Traffic reached all three Pods in the Redis arms: per-Pod 200 counts 20/22/22, 19/24/21 and 25/16/23 (`arms.tsv`), with `degraded_decisions_total` and `redis_errors_total` at 0.

### Latency, client side, milliseconds

Nearest-rank percentiles, p99 first; `max` means the sample is under 100, so p99 is the largest value.
Each request opens a new TCP connection to a NodePort on the same host, and the stub streams 4 tokens with a 5 ms first-token delay and 2 ms between tokens.
So these numbers describe this loopback setup, not a gateway's cost in a real network.

| arm | completed, end to end: p99 / p50 (n) | completed, first token: p99 / p50 (n) | 429: p99 / p50 (n) |
|---|---|---|---|
| `memory-1` | max 13.2 to 14.2 / 12.3 (64 each) | max 6.9 to 7.8 / 5.9 (64 each) | 0.8 to 0.9 / 0.5 (536 each) |
| `memory-3` | 13.2 to 13.6 / 12.3 (192 each) | 6.8 to 7.1 / 5.9 to 6.0 (192 each) | 0.7 to 0.8 / 0.5 (408 each) |
| `redis-3` | max 14.1 to 15.6 / 12.5 (64 each) | max 7.7 to 8.4 / 6.1 (64 each) | 0.9 to 1.0 / 0.7 (536 each) |

- At n = 192 the p99 is the second-largest value, so it is not much more than a maximum either.
- The Redis store's p50 is 0.2 ms above the memory store's for both 200s and 429s, in all three repetitions; three repetitions of one cluster do not establish that difference beyond this setup.

## Event arms, 60 s x 3 each (`events/score.txt`)

For the event arms only, the stub streams 16 tokens 250 ms apart (`stub://profile?tokens=16&ttft-ms=5&itl-ms=250`, about 3.8 s a stream), so three or four admitted streams are open when the event happens.
Run 1's 11 ms streams almost never were.

| arm | admitted rep 1 / 2 / 3 | completed | cut after 200 | 503 | stub served |
|---|---|---|---|---|---|
| Redis stopped, `local` | 104 / 105 / 102 | = admitted | 0 | 0 | = admitted |
| Redis stopped, `closed` | 57 / 56 / 57 | = admitted | 0 | 118 / 125 / 123 | = admitted |
| one gateway Pod killed | 64 / 64 / 64 | **63 / 63 / 63** | **1 / 1 / 1** | 0 | 64 / 64 / 64 |

### Redis stopped (`local`, the default failure policy)

Redis scaled to 0 at 10.01 s and was ready again at 20.82, 21.69 and 20.78 s.

- No request failed; during the outage 43, 47 and 43 were admitted against `3 x (5 + outage)` = 47.4, 50.0 and 47.3 for three independent buckets, as in run 1.
- **Streams in flight: 3, 4 and 4 were open when Redis stopped, and all completed with `[DONE]`.** The limiter decides before the proxy starts, so a stream already admitted does not touch Redis again.
- In rep 1 two requests sent at 10.6 and 10.7 s had a first token at 107 and 106 ms instead of about 6 ms: the Redis call waited out its deadline before falling back to the local bucket. Reps 2 and 3 show no such request.

### Redis stopped (`closed`)

- During the outage every request but one was refused with 503 and none admitted (rep 3 had one 429); the last 503 was sent at 21.9, 22.7 and 22.7 s, 1.1 to 2.0 s after Redis was ready, against 1.4 s in run 1.
- Streams in flight: 3, 3 and 4, all completed.
- One 503 in rep 1, at 10.40 s, took 101.6 ms: the same deadline as above, before the breaker opened.

### One gateway Pod killed (`--grace-period=0 --force`)

Killed at 15.04, 15.05 and 15.03 s; three ready endpoints again at 26.25 s each time.

- **Admitted stayed 64, one per second throughout**, as without the kill: the replacement Pod brings no fresh bucket, because the bucket is in Redis.
- **Streams in flight: 3 each time; 2 completed and 1 was cut.** In every repetition the cut stream was sequence 141, sent at 14.10 s: it got its 200 and its first token at about 6 ms, then the connection broke at about 17.08 s with `error_kind=stream` and no `[DONE]`, about 2 s after the delete was issued.
- **The stub counted that request as served, so admitted = backend served = 64 while completed = 63.** Under run 1's judge this arm would have read 64 of 64 succeeded; it is exactly the case the fix exists to catch.
- No request failed to connect in these three repetitions; run 1's single kill had one connection reset.
- The loadgen does not record which Pod served a request, so the run does not show that the two completed streams were on surviving Pods, only that they completed.

## What these numbers show

- In this configuration (one tenant, 60 requests/min with burst 5, 10 requests a second, one kind node), the Redis store removes the replica multiplication of the limit: three replicas admitted 64, the one-bucket bound, where the memory store admitted 192.
- Admitted counts match the bound and the backend's own count, and, with the judge fixed, every admitted stream in the steady arms completed.
- With the store down, the `local` policy keeps answering and loosens the limit to per-replica buckets, and `closed` refuses with 503; streams already admitted finish either way.
- A gateway Pod killed under load cuts the streams it was carrying, and the client now records that as a cut 200, not a success.

## What they do not show

- **Not large scale.** One tenant, one kind node, ten requests a second, three gateway replicas.
- **Not Redis high availability.** There is one Redis Pod with no persistence and no failover; the outage arms show what the gateway does when it is gone.
- **Not GPU or serving capacity.** The backend is a CPU stub with a fixed token schedule; nothing here measures an engine, a GPU, or end-to-end serving latency.
- Latency through a real network or a remote Redis; the percentiles above are loopback numbers.
- A p99 for completed requests at n = 64: it is the maximum.
- Which Pod a cut stream was on, or the single-instance profile's `Recreate` rollout gap.

## Two separate supported configurations

The shared Redis limiter (W1) is the multi-gateway profile and supports only `--admission-mode=off` with `RoundRobin` or `LeastQueue` backends; the gateway refuses other admission modes at startup and answers 503 `single_gateway_required` for HoldCap and `PrefixAffinity`.
HoldCap admission runs in the single-instance profile: one gateway replica, the memory store, `strategy: Recreate`.
They are different supported deployments, and these results say nothing about HoldCap.

## Files

- `regression-test.txt`: the loadgen tests against the old and the new `main.go`.
- Steady arms: `log.txt`, `arms.tsv`, `<arm>-<rep>.tsv` (one row per request), `<arm>-<rep>.summary`, `score.txt`.
  The run stopped after these nine arms, before the event arms: `run.sh` matched the stub's new profile against kubectl's JSON-printed arguments, where `&` is escaped, and failed (`FAILED at:` in `log.txt`); the cluster was deleted.
  `108f311` fixed the match and `score.txt` was written by `score.py` at that commit afterwards.
- Event arms: `events/`, the same files, from `REPS=0 EVENT_REPS=3 DURATION_S=60` with the profile above; `score.py` ran at the end of that run and printed VALID.
