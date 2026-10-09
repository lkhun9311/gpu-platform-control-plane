# Does a tenant's rate limit survive a second gateway replica?

`config/gateway/deployment.yaml` pins `replicas: 1` and says why: each Pod keeps its own token buckets
(`internal/gateway/ratelimit.go`, an in-memory `map[tenant]*rate.Limiter`), so two Pods would multiply a
tenant's effective limit by two. That is a claim in a comment. Nothing has sent a request to check it.

It matters because "what would you change to run this as a shared internal service?" is the first follow-up
to the gateway, and the honest answer starts with this limit. This experiment turns the comment into a
measurement on kind, for free, with no GPU.

## Registered before the first run (2026-10-09)

Everything in this section was written before `hack/gateway-replica-limit.sh` was run.

### Setup

- A throwaway single-node kind cluster named `gwlimit` (not `platform`, which other work uses).
- The operator and the gateway as built from this tree; the gateway image is set to the local build because
  `config/gateway` pins an ECR digest a kind node cannot pull.
- One tenant, `tenant-a`, with `rateLimit: {requestsPerMinute: 60, burst: 5}` — 1 token per second, bucket 5.
- One fast stub backend (`benchharness stub-serve`), which counts the requests it actually served.
- Load from `loadgen/`: open loop, **10 requests per second for 30 s**, ten times the limit, so the limiter
  is saturated throughout and the admitted count is set by the limiter alone.

### Arms

| arm | gateway replicas | client connections | what it asks |
|---|---:|---|---|
| `R1-fresh` | 1 | new connection per request | **control** — the limit as designed |
| `R2-fresh` | 2 | new connection per request | does kube-proxy spreading requests over two Pods double the limit? |
| `R2-pinned` | 2 | one kept-alive connection | does a client pinned to one Pod hide the problem? |
| `R1-restart` | 1 | new connection per request | does a Pod restart hand the tenant a fresh burst? (Pod deleted at 15 s) |

Three repetitions of each, in the order above, with 10 s idle between arms so every bucket starts full.

### Quantities

- `T` — seconds from the first to the last request the client sent.
- `admitted` — requests the client saw answered `200`.
- `bound` — what one bucket can admit in `T`: `burst + rate × T` = `5 + T`.

### Validity checks (a failure voids the run rather than being reported as a result)

1. **The control saturates and holds.** In every `R1-fresh` repetition, `bound − 2 ≤ admitted ≤ bound + 1`.
   Below the floor means the limiter was not the thing deciding; above the ceiling means the instrument is
   wrong, because the control is the design working.
2. **Two counters agree.** In every arm, the stub's served count equals the client's `200` count. The client
   cannot be the only witness of what got through.
3. **Every non-429 refusal is accounted for.** Any status other than `200` and `429` is reported with its
   count; in arms other than `R1-restart` the registered tolerance is zero.

### Readings

| arm | reading | registered expectation |
|---|---|---|
| `R2-fresh` | `admitted / bound` | **breach**: above `bound + 1` in all three repetitions, near 2x |
| `R2-pinned` | `admitted` against `bound`, and which Pod served | within `bound + 1`, all on one Pod |
| `R1-restart` | the most `200`s in any 1.0 s window after the deletion | **≥ 4** (`burst − 1`): the new Pod's bucket starts full, where a continuing bucket would allow about 1. The same statistic over the second half of each `R1-fresh` run is the contrast, expected **≤ 2** |

The client cannot tell which Pod answered, so the restart reading is a window over send times rather than
"after the new Pod's first answer"; that wording was replaced before the first run for that reason.

The expectations are what the code predicts. If a reading comes out the other way it is reported as it came
out, and the code is what gets re-read.

### Amendment 1 (2026-10-09, after the first complete run and before the second)

The first complete run, `hack/gateway-replica-limit-20261009T004928Z`, is **VOID** by check 2: in `R1-restart`
repetition 2 the stub served 28 requests while the client saw 26 answered `200`. Its readings are not results.

What the per-request rows show about the restart arm, as observation and not as a reading:
- Deleting the only gateway Pod at 15.0 s left no answer until about 19.6 s in all three repetitions:
  41 to 52 requests failed per run, 11 of them `connection reset` and 41 client timeouts in repetition 2.
- The registered restart reading came out **2 in all three**, against an expectation of at least 4.
  After about 20 s the first send of every second fails and the `200` moves to the seventh slot, which looks like
  admitted requests losing their answers while the old and new Pods overlap. The client cannot see which Pod
  answered, so this run cannot tell a missing burst from a burst spent on requests whose answers were lost.
- Requests that were admitted and served but lost on the way back are also the most likely reason the stub
  counted two more than the client. That is a hypothesis; no Pod log was kept to check it.

So the restart arm asked a question this instrument cannot answer. It is **removed** from this registration
rather than re-scored, and goes back to design until a response can name the Pod that answered it.
Nothing else changes: the remaining three arms, their checks and their readings are re-run exactly as
registered above, in a new run directory.

## Result (2026-10-09): VALID, and two replicas admit 1.95x

Run `hack/gateway-replica-limit-20261009T010205Z`, scored by `score.py`, which printed `VALID`.
The tree was `1240e34` plus this experiment's own files, uncommitted at run time and committed unchanged with
this record; the gateway, operator and stub code were `1240e34`'s.

| arm | rep 1 | rep 2 | rep 3 | `bound` | which Pods served |
|---|---:|---:|---:|---:|---|
| `R1-fresh` (control) | 34 | 34 | 34 | 34.90 | the one Pod |
| `R2-fresh` | **68** | **68** | **68** | 34.90 | **both, 34 each**, every repetition |
| `R2-pinned` | 34 | 34 | 34 | 34.90 | one Pod only, every repetition |

300 requests per arm at 10 per second over `T` = 29.90 s; every refusal was a `429`, no transport errors, and
the stub's count matched the client's in all nine arms.

- **Two replicas admitted 68 against a bound of 34.90 — 1.95x — in all three repetitions.** The registered
  expectation (above `bound + 1`, near 2x) held. Each Pod ran its own full bucket: 5 + 29 = 34 apiece.
- **A client pinned to one connection saw the designed limit** with two replicas behind it, because kube-proxy
  chose a Pod once per connection. So a check made with one keep-alive client would have passed while the
  tenant's real limit, under clients that spread, was double.
- The ratio is fixed by the configuration, not by noise: the three repetitions of each arm are identical. They
  show that the arithmetic is deterministic, not that it is precise to two decimals for every load.

What this licenses in one sentence: **the gateway's per-tenant limit is per Pod, so N replicas multiply it by up
to N, and whether that shows depends on how clients hold connections.** The ways out are moving the
bucket to shared state (Redis, or a token service), dividing each Pod's budget by the replica count, or keeping
`replicas: 1` and accepting the restart outage below; this experiment measured the problem and chose none.

From the void first run (Amendment 1), as observation only: deleting the single replica cost about 4.5 s with
no answer and 41 to 52 failed requests at 10 per second.

### What this cannot show

- Anything about real GPUs, latency or throughput. The backend is a stub and the numbers are counts.
- How a shared limiter (Redis, a sidecar, or a consistent-hash front) would behave. This measures the
  problem, not a fix.
- Multi-node behaviour. kube-proxy's spreading on one node is the only routing tested.
