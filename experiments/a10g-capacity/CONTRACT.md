# Single-A10G capacity, overload and recovery: the measurement contract

Issue: [#673](https://github.com/lkhun9311/gpu-platform-control-plane/issues/673).
Contract id: `a10g-capacity-673-v1`.

This file fixes, before any GPU session, what is sent, what is measured, which requests count, and which sentence each result allows.
The values the kit and the analysis use are in [`kit/contract.json`](kit/contract.json), and the kit's offline gate fails if this file and that one disagree on any threshold.
Nothing here may change after the first GPU session for this issue; a change makes a new contract id, and sessions run under the old one are reported under the old one.

## 1. Workload

| Item | Value | Why |
|---|---|---|
| Model | `Qwen/Qwen2.5-3B-Instruct` at revision `aa8e72537993ba99e69dfaafa59ed015b17504d1`, weights and tokenizer | The revision the CR's `modelRevision` pins in every earlier A10G session |
| Engine image | `vllm/vllm-openai@sha256:0a51ea5b4ae2dc5d81890e5173f54203d2a3ae0cfffe51b8fd2afd4391bfd967` | `VLLMV0271Image` in `api/v1/inferencedeployment_types.go` |
| Engine arguments | The `v0.27.1-a10g` profile, rendered by `internal/engineargs` (`ProfileArgs("v0.27.1", false)` and `Command`), port 8000, served name `qwen2.5-3b-instruct` | The same list the controller renders for a Pod, so the container runs what a CR would |
| Engine settings that follow | `--dtype=half --max-model-len=16384 --max-num-seqs=64 --gpu-memory-utilization=0.90 --no-enable-prefix-caching --max-num-batched-tokens=512 --scheduling-policy=priority --no-async-scheduling` | Not chosen here; read from the renderer |
| Prefix cache | Off at every stage, including the pilot and the restarts | `--no-enable-prefix-caching`; no stage can reuse a prefix, so cache state is not a variable |
| Input | 512 tokens, as 2,506 characters of the bench prompt corpus | `hack/input-length-resolution.json` measured 2,506 characters at exactly 512 tokens with this tokenizer revision, chat template and image |
| Output | Exactly 128 tokens: `max_tokens = min_tokens = 128`, `ignore_eos: true` | The output length is a property of the workload, not of what the model chose to write |
| Generation | `temperature 0`, `top_p 1`, `repetition_penalty 1`, no seed, streaming with `include_usage` | `bench.SamplingPolicy` with the exact-cap length policy and the greedy seed policy |
| Arrivals | Open loop, Poisson (exponential gaps), seeded per stage | The sender dispatches at the scheduled instant and never waits for an earlier response (`bench.Replay`) |
| Rate unit | Requests per second of intended arrivals | A stage's rate is the Poisson rate its trace is drawn at, not the rate that completed |
| Client concurrency cap | None | Every request runs on its own goroutine; the pool is sized by `bench.PoolSizeForTrace` |
| Server concurrency | 64 running sequences (`--max-num-seqs=64`), the rest wait in the engine's queue | Recorded from `/metrics`, not assumed |
| Request timeout | 60 s from send to the end of the stream | A request still open at 60 s is a failed request with kind `timeout` |

The sender is `bench.HTTPSender`, and each row's disposition is the one `bench.Replay` writes through `dispositionOf` (in `internal/bench/disposition.go`).
Every recording is checked with `bench.ReconcileRecording` against the trace it replayed before any number is read from it.

## 2. Metrics

- **TTFT** is the time from the request's dispatch to the first SSE frame carrying non-empty content, on the monotonic clock (`clock.firstContentNanos - clock.sendNanos`).
- **E2E** is the time from dispatch to `data: [DONE]` (`clock.doneNanos - clock.sendNanos`).
- **TPOT** is `(last content - first content) / (engine completion tokens - 1)`, for completed rows only, and is secondary.
- Every latency is reported **p99 first**, then p90 and p50, each with its sample count `n`, by the nearest-rank method.
- A p99 is reported only when its population has at least 100 completed requests; below that the analysis prints `insufficient (n=...)` and no figure.
- Latency populations are completed requests only, and every latency table states its completion ratio beside it, so a tail shortened by failures is visible.
- Output throughput counts the engine's `completion_tokens` of completed requests only.

### The population issue in the existing report

`internal/bench/report.go` computes its primary latency over the premium tenant's completed requests (`Summarize`, around line 594), and its output-token sum can take tokens from streams that did not complete (around line 1510).
This workload has one tenant and the analysis does not call that report; it recomputes from the raw rows, with the populations stated above.

### Dispatch lag

A row's lag is `clock.sendNanos - clock.intendedNanos`.
If more than 1% of a stage's sent requests left more than 100 ms late, the client did not hold the open loop and the session is excluded (rule X5).

## 3. Stages, warm-up, drain and end of run

| Phase | Rate | Length | Excluded from latency |
|---|---|---|---|
| Warm-up | 2 req/s | 60 s | All of it |
| Pilot rung | 3, 4, 5, 6, 8, 10, 12, 14, 16, 18, 20, 24, 28 req/s, ascending | 60 s each | The first 10 s of each rung |
| Cycle: baseline | `R_low` | 150 s | The first 15 s |
| Cycle: saturation | `R_sat` | 150 s | The first 15 s |
| Cycle: overload | `R_over` | 90 s | None |
| Cycle: recovery | `R_low` | 240 s | None; read by windows (section 6) |

- The pilot rungs are separate replays: each rung ends when every sent request has ended, then waits 5 s and for the engine's `running + waiting` gauges to read 0, for at most 30 s.
  A rung whose engine does not drain in 30 s ends the pilot as `not drained`.
- A rung is 60 s so that its 50 s measured window at the lowest rate expects 150 requests, and a Poisson draw falls under the 100 a p99 needs with probability below 0.01%.
- The pilot stops at its first unstable rung, or when it has used 900 s.
- The four cycle stages are **one** replay of one trace whose arrival rate changes at the stage boundaries, with no gap between stages, so the recovery stage begins at the overload stage's last scheduled instant.
  Each row carries its stage in the trace's tenant field, so `ReconcileRecording` checks the stage of every row.
- **End of run.** A replay ends when every sent request has returned, which the 60 s timeout bounds at the last scheduled arrival plus 60 s.
- **Counted as completed** only: HTTP 200, a stream ended by `data: [DONE]` within the timeout, no in-band error, the engine's usage reporting 512 prompt tokens and 128 completion tokens, and finish reason `length`.
- A request that is still open at the timeout is failed (`timeout`), never dropped and never completed.

## 4. The outcome ledger

Each stage has `planned` rows, the trace's rows for that stage.

- `planned = unsent + sent`, where `unsent` is the disposition `unsent`.
- `sent = completed + rejected + failed`.
- `rejected` is a sent request answered with any HTTP status other than 200.
- `failed` is a sent request with no HTTP status (transport error, timeout before headers, cancellation), or with HTTP 200 and a stream that did not complete (timeout after headers, in-band error, no `[DONE]`), or a `[DONE]` stream that broke the token contract.
- The HTTP status (200, another code, none) and the stream outcome (`done`, `error`, `timeout`, `truncated`, `transport`, `contract`, `not-read`) are recorded on separate axes, and the ledger prints their cross-table, so a 200 that timed out stays a 200 that timed out.
- The analysis refuses a stage whose counts do not satisfy both identities, or whose rows do not reconcile with its trace.

## 5. Baseline, saturation and overload

### The pilot's stability rule

A pilot rung at rate `r` is **stable** when all three hold over its measured window (after its first 10 s):

- **S1** `completed / sent >= 0.99`.
- **S2** p99 TTFT `<= 2,000 ms`, with at least 100 completed requests; a rung with fewer is not stable.
- **S3** no queue growth: the median TTFT of the requests in the last third of the window is at most `2.0 x` the median of the first third, plus 100 ms.

### The saturation rule

- `R_sat` is the highest stable rung below the first unstable rung.
- If the first rung (3 req/s) is unstable, the session reports `saturation below the ladder`, runs no cycle and goes to the restarts.
- If every rung is stable, `R_sat` is the top rung (28 req/s), the session reports `saturation at or above 28 req/s`, and the overload stage is reported as a higher-rate stage, not as overload.
- If the pilot runs out of its 900 s first, `R_sat` is the highest stable rung so far and the session reports `pilot budget exhausted`, with the same restriction on the word overload.

### The cycle's rates

- `R_low = max(0.25 x R_sat, 1.5 req/s)`, and the cycle is refused if that exceeds `0.5 x R_sat`.
- `R_over = 1.5 x R_sat`.
- **Baseline** is the first `R_low` stage; its measured window is the reference the recovery rule compares to.
- The **saturation stage** reports whether `R_sat` held: the same S1 to S3 over its measured window.
- The **overload stage** reports the ledger, the completion ratio, the p99 TTFT of what completed with its `n`, and the engine's peak `waiting` and KV usage.

## 6. The recovery rule

- **Window type:** tumbling, by intended arrival time, starting at the end of the overload stage.
- **Window length:** 20 s.
- **Minimum samples:** a window with fewer than 15 sent requests is `insufficient` and is not recovered.
- A window is **recovered** when every request sent in it completed, and its p90 TTFT is at most `1.5 x` the baseline's p90 TTFT plus 25 ms.
- **Recovery time** is the start of the first of 3 consecutive recovered windows, measured from the end of the overload stage.
- Only windows that end inside the 240 s recovery stage count, so the longest recovery time this rule can report is 180 s; otherwise the result is `not recovered within 180 s`.
- The engine's own drain, the time from the end of overload until `vllm:num_requests_waiting` first reads 0, is reported beside it as a secondary figure.

## 7. The restart measurement

- **What is timed:** from just before `docker kill --signal=SIGKILL` of the running engine container to the end of the first successful probe after `docker start` of the same container.
- **Probe:** the workload's request with a 16-token exact output, sent every 500 ms (the next one 500 ms after the previous one was sent, or at once if it took longer), each with a 10 s timeout.
  A successful probe is HTTP 200, `[DONE]`, 512 prompt tokens, 16 completion tokens and finish reason `length`.
- **Count:** 3 restarts, each after 10 s with no load.
- **Bound:** 240 s each; a restart that has no successful probe by then is reported as `not serving within 240 s` and ends the restarts.
- **Cache state:** warm.
  The container is restarted, not recreated, so its own file system, including vLLM's compile cache under `/root/.cache/vllm`, survives; the weights stay in the host's Hugging Face cache, mounted into the container, and in the host's page cache; the prefix cache is off.
  A cold start (first pull, first compile) is recorded once per session as the engine's first readiness time, and is not a restart.

## 8. The attempt ledger and the exclusion rules

Every launched GPU session has a row in `experiments/a10g-capacity/attempts.md`, whether or not it returned evidence: the session directory, instance and zone, LaunchTime, confirmed termination, elapsed seconds, the cost bound, the kit's exit status, the outcome, and `included` or the exclusion rule.
A launch refused before any instance existed (no Spot capacity, a refused check) is listed too, as `not launched`, with cost 0.

A session is **excluded** from every reported number only under one of these rules, and the rule is named in its row:

| Rule | Condition |
|---|---|
| X1 | The evidence did not come back whole (`evidence` is not `returned` in the session's outcome), including a Spot reclaim |
| X2 | The kit stopped before the pilot's first rung (image pull, model download, engine start, or the sender build failed) |
| X3 | Any completed-looking row broke the token contract (prompt tokens other than 512, completion tokens other than 128 or 16 on a probe, or a finish reason other than `length`) |
| X4 | A stage's recording does not reconcile with its trace, or its ledger identities do not hold |
| X5 | More than 1% of a stage's sent requests were dispatched more than 100 ms after their intended arrival |

No other reason excludes a session.
In particular a result that looks wrong, or differs from another session, is reported, not excluded.
A session that reports `saturation below the ladder`, `at or above 28 req/s` or `pilot budget exhausted` is included, and only the sentences section 10 allows for it are written.

At most 3 sessions are launched for this contract, and at least 2 included sessions are needed to report saturation, overload, recovery and the restart window.
If fewer than 2 are included by 2026-11-26 18:00 KST, the results document says so and claims nothing from them.

## 9. Concrete thresholds

| Key in `contract.json` | Value |
|---|---|
| `workload.input_tokens` | 512 |
| `workload.output_tokens` | 128 |
| `workload.request_timeout_s` | 60 |
| `metrics.min_samples_p99` | 100 |
| `metrics.max_dispatch_lag_ms` | 100 |
| `metrics.max_lagged_fraction` | 0.01 |
| `warmup.rate_rps` | 2 |
| `warmup.duration_s` | 60 |
| `pilot.rung_s` | 60 |
| `pilot.rung_warmup_s` | 10 |
| `pilot.drain_idle_s` | 5 |
| `pilot.drain_gauge_timeout_s` | 30 |
| `pilot.budget_s` | 900 |
| `stability.min_completed_fraction` | 0.99 |
| `stability.max_p99_ttft_ms` | 2000 |
| `stability.trend_ratio` | 2.0 |
| `stability.trend_slack_ms` | 100 |
| `cycle.low_fraction_of_sat` | 0.25 |
| `cycle.low_min_rps` | 1.5 |
| `cycle.low_max_fraction_of_sat` | 0.5 |
| `cycle.overload_factor` | 1.5 |
| `cycle.baseline_s` | 150 |
| `cycle.saturation_s` | 150 |
| `cycle.overload_s` | 90 |
| `cycle.recovery_s` | 240 |
| `cycle.stage_warmup_s` | 15 |
| `recovery.window_s` | 20 |
| `recovery.min_window_sent` | 15 |
| `recovery.consecutive_windows` | 3 |
| `recovery.p90_ratio` | 1.5 |
| `recovery.p90_slack_ms` | 25 |
| `restart.count` | 3 |
| `restart.idle_before_s` | 10 |
| `restart.probe_output_tokens` | 16 |
| `restart.probe_interval_ms` | 500 |
| `restart.probe_timeout_s` | 10 |
| `restart.bound_s` | 240 |
| `session.budget_s` | 3200 |
| `session.max_sessions` | 3 |
| `session.min_included_sessions` | 2 |

## 10. What a result allows

Allowed, per included session and with its sample counts: "on one A10G, with this image, profile, model revision and workload, the highest stable rate of the pilot's ladder was `R_sat` req/s", the cycle's per-stage ledgers and quantiles, the recovery time or its censoring, and each restart's window under the cache state above.

Not allowed from this contract: a universal or maximum capacity of the A10G, end-to-end GPU latency through the gateway (the gateway is measured separately on kind, and the two numbers are never added), any HA or zero-downtime statement, and any p99 whose population has fewer than 100 completed requests.
