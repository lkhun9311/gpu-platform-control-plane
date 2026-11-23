# Single-A10G capacity, overload and recovery: results

Issue [#673](https://github.com/lkhun9311/gpu-platform-control-plane/issues/673), contract `a10g-capacity-673-v1` ([`CONTRACT.md`](CONTRACT.md)).
Every number below is read from the two included sessions' own reports, [`runs/s2/run/results/report.txt`](runs/s2/run/results/report.txt) and [`report.json`](runs/s2/run/results/report.json), and [`runs/s3/run/results/report.txt`](runs/s3/run/results/report.txt) and [`report.json`](runs/s3/run/results/report.json), with each rung's rate and stability from its `pilot/rung-NN.verdict.json`.
Session 1 is excluded under X1 (a Spot reclaim before the kit got past its first step) and contributes nothing; see [`attempts.md`](attempts.md).
Sessions 2 and 3 are included, so the contract's minimum of two is met.
**The two sessions are reported side by side and never pooled**: no figure here is an average or a union of the two.

Both sessions: one g5.xlarge (one A10G 24 GB) Spot instance in ap-northeast-2d, `Qwen/Qwen2.5-3B-Instruct` at the pinned revision, the pinned vLLM v0.27.1 image, the `v0.27.1-a10g` profile with prefix caching off, 512 input tokens and exactly 128 output tokens per request, open-loop Poisson arrivals, a 60 s request timeout (CONTRACT.md section 1).
The engine ran without the gateway; nothing here is a latency through the gateway.

Conventions:

- Latency is TTFT in milliseconds, **p99 first**, each percentile with the number of completed requests it is computed over, `(n=...)`, by the nearest-rank method.
- Latency populations are completed requests whose intended arrival lies in the measured window: a pilot rung's last 50 s (its first 10 s excluded), a baseline or saturation stage's last 135 s (its first 15 s excluded), the whole overload (90 s) and recovery (240 s) stages.
- Completed req/s and output tok/s use the same population, divided by the same window length; a request counts toward the stage it arrived in even if it completed later (CONTRACT.md section 2).
- Engine and GPU peaks are the largest of the 1 s samples inside the stage's span, so a spike shorter than a second can be missed; the sample count is given.
- KV usage is the engine's `vllm:kv_cache_usage_perc` gauge, shown as a percentage.

## Pilot ladder

The ladder is 3, 4, 5, 6, 8, 10, ... req/s, 60 s per rung, and stops at the first unstable rung.
A rung is stable when S1 (completed / sent >= 0.99), S2 (p99 TTFT <= 2,000 ms with n >= 100) and S3 (no TTFT growth from the first to the last third of the window) all hold.

| Rung | Rate | Session | Sent = completed | Completion | TTFT p99 | TTFT p90 | TTFT p50 | Completed req/s | Output tok/s | Stable |
|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---|
| 1 | 3 req/s | S2 | 122 | 1.0 | 230.5 (n=122) | 148.5 (n=122) | 98.7 (n=122) | 2.44 | 312.3 | yes |
| 1 | 3 req/s | S3 | 122 | 1.0 | 228.0 (n=122) | 144.9 (n=122) | 99.0 (n=122) | 2.44 | 312.3 | yes |
| 2 | 4 req/s | S2 | 189 | 1.0 | 279.0 (n=189) | 179.1 (n=189) | 124.1 (n=189) | 3.78 | 483.8 | yes |
| 2 | 4 req/s | S3 | 189 | 1.0 | 276.5 (n=189) | 182.6 (n=189) | 125.3 (n=189) | 3.78 | 483.8 | yes |
| 3 | 5 req/s | S2 | 235 | 1.0 | 232.5 (n=235) | 177.1 (n=235) | 119.2 (n=235) | 4.70 | 601.6 | yes |
| 3 | 5 req/s | S3 | 235 | 1.0 | 230.4 (n=235) | 182.1 (n=235) | 116.4 (n=235) | 4.70 | 601.6 | yes |
| 4 | 6 req/s | S2 | 318 | 1.0 | 292.2 (n=318) | 223.9 (n=318) | 150.1 (n=318) | 6.36 | 814.1 | yes |
| 4 | 6 req/s | S3 | 318 | 1.0 | 297.5 (n=318) | 220.8 (n=318) | 150.6 (n=318) | 6.36 | 814.1 | yes |
| 5 | 8 req/s | S2 | 385 | 1.0 | 1,688.9 (n=385) | 947.0 (n=385) | 197.7 (n=385) | 7.70 | 985.6 | yes |
| 5 | 8 req/s | S3 | 385 | 1.0 | 1,643.6 (n=385) | 898.6 (n=385) | 193.3 (n=385) | 7.70 | 985.6 | yes |
| 6 | 10 req/s | S2 | 533 | 1.0 | 15,142.3 (n=533) | 14,510.6 (n=533) | 7,549.2 (n=533) | 10.66 | 1,364.5 | no: S2, S3 |
| 6 | 10 req/s | S3 | 533 | 1.0 | 15,239.9 (n=533) | 14,616.0 (n=533) | 7,572.1 (n=533) | 10.66 | 1,364.5 | no: S2, S3 |

No request was rejected or failed in any rung of either session; every sent request completed.
At 10 req/s S2 failed (p99 TTFT 15,142.3 ms in S2 and 15,239.9 ms in S3, over 2,000 ms) and S3 failed (last-third median TTFT 13,409.1 ms against a limit of 2.0 x 4,629.6 + 100 ms in S2; 13,512.4 ms against 2.0 x 4,647.0 + 100 ms in S3).

**R_sat is 8 req/s in both sessions, and the first unstable rung is 10 req/s in both.**
The cycle that followed ran baseline and recovery at `R_low` 2 req/s, saturation at 8 req/s and overload at `R_over` 12 req/s (`pilot/cycle-plan.json`).

### Engine and GPU peaks per rung (peak of 60 1 s samples each)

| Rung | Rate | Session | Running | Waiting | KV usage | GPU util | GPU memory |
|---:|---:|---|---:|---:|---:|---:|---:|
| 1 | 3 req/s | S2 | 13 | 1 | 2.0% | 95% | 20,367 MiB |
| 1 | 3 req/s | S3 | 13 | 1 | 2.0% | 96% | 20,367 MiB |
| 2 | 4 req/s | S2 | 20 | 1 | 3.1% | 97% | 20,367 MiB |
| 2 | 4 req/s | S3 | 20 | 1 | 3.0% | 97% | 20,367 MiB |
| 3 | 5 req/s | S2 | 27 | 0 | 4.0% | 97% | 20,373 MiB |
| 3 | 5 req/s | S3 | 27 | 0 | 4.0% | 97% | 20,373 MiB |
| 4 | 6 req/s | S2 | 40 | 1 | 6.0% | 97% | 20,373 MiB |
| 4 | 6 req/s | S3 | 40 | 1 | 6.0% | 97% | 20,373 MiB |
| 5 | 8 req/s | S2 | 64 | 13 | 9.7% | 97% | 20,373 MiB |
| 5 | 8 req/s | S3 | 64 | 12 | 9.7% | 97% | 20,373 MiB |
| 6 | 10 req/s | S2 | 64 | 127 | 9.8% | 97% | 20,373 MiB |
| 6 | 10 req/s | S3 | 64 | 127 | 9.8% | 97% | 20,373 MiB |

## The cycle: baseline, saturation, overload, recovery

One replay of one trace (seed 6750), the rate changing at the stage boundaries with no gap.

| Stage | Rate | Session | Planned = sent = completed | Completion | TTFT p99 | TTFT p90 | TTFT p50 | Completed req/s | Output tok/s |
|---|---:|---|---:|---:|---:|---:|---:|---:|---:|
| Baseline | 2 req/s | S2 | 261 | 1.0 | 245.6 (n=261) | 141.1 (n=261) | 96.7 (n=261) | 1.93 | 247.5 |
| Baseline | 2 req/s | S3 | 261 | 1.0 | 235.6 (n=261) | 139.9 (n=261) | 96.7 (n=261) | 1.93 | 247.5 |
| Saturation | 8 req/s | S2 | 1,095 | 1.0 | 3,698.1 (n=1,095) | 3,134.4 (n=1,095) | 541.9 (n=1,095) | 8.11 | 1,038.2 |
| Saturation | 8 req/s | S3 | 1,095 | 1.0 | 3,547.6 (n=1,095) | 2,991.1 (n=1,095) | 499.7 (n=1,095) | 8.11 | 1,038.2 |
| Overload | 12 req/s | S2 | 1,083 | 1.0 | 36,833.2 (n=1,083) | 33,604.2 (n=1,083) | 18,629.4 (n=1,083) | 12.03 | 1,540.3 |
| Overload | 12 req/s | S3 | 1,083 | 1.0 | 36,968.1 (n=1,083) | 33,636.2 (n=1,083) | 18,647.7 (n=1,083) | 12.03 | 1,540.3 |
| Recovery | 2 req/s | S2 | 477 | 1.0 | 30,527.9 (n=477) | 10,071.6 (n=477) | 100.3 (n=477) | 1.99 | 254.4 |
| Recovery | 2 req/s | S3 | 477 | 1.0 | 30,586.7 (n=477) | 10,254.6 (n=477) | 100.2 (n=477) | 1.99 | 254.4 |

No request was rejected or failed in any stage of either session, the overload stage included: every request sent at 12 req/s completed within the 60 s timeout, with the latency shown.
The recovery stage's p99 and p90 include the requests that arrived while the overload's queue was still draining; the recovery rule below reads that stage by 20 s windows instead.

### Engine and GPU peaks per stage

| Stage | Session | 1 s samples | Running | Waiting | KV usage | GPU util | GPU memory |
|---|---|---:|---:|---:|---:|---:|---:|
| Baseline | S2 | 150 | 11 | 0 | 1.7% | 96% | 20,373 MiB |
| Baseline | S3 | 150 | 11 | 0 | 1.7% | 96% | 20,373 MiB |
| Saturation | S2 | 150 | 64 | 36 | 9.8% | 97% | 20,373 MiB |
| Saturation | S3 | 150 | 64 | 35 | 9.9% | 97% | 20,373 MiB |
| Overload | S2 | 90 | 64 | 313 | 9.8% | 97% | 20,373 MiB |
| Overload | S3 | 90 | 64 | 314 | 9.8% | 97% | 20,373 MiB |
| Recovery | S2 | 240 | 64 | 315 | 9.8% | 97% | 20,373 MiB |
| Recovery | S3 | 240 | 64 | 315 | 9.8% | 97% | 20,373 MiB |

### Saturation held: False, in both sessions

The saturation stage re-applies S1 to S3 to its 135 s measured window at R_sat, 8 req/s.

| Session | Saturation held | Reasons |
|---|---|---|
| S2 | False | S2: p99 TTFT 3,698.1 ms (n=1,095) > 2,000 ms. S3: last-third median TTFT 1,108.7 ms > 2.0 x 215.2 + 100 ms |
| S3 | False | S2: p99 TTFT 3,547.6 ms (n=1,095) > 2,000 ms. S3: last-third median TTFT 943.8 ms > 2.0 x 217.3 + 100 ms |

S1 held in both: every sent request completed.

To be exact about what passed and what did not: **the 8 req/s pilot rung passed S1 to S3 over its 50 s measured window** (60 s rung, first 10 s excluded; p99 TTFT 1,688.9 ms in S2 and 1,643.6 ms in S3, n=385 each), **and the 150 s saturation stage at the same 8 req/s did not hold** over its 135 s measured window, in either session.
The two are different traces (seed 6735 for rung 5, seed 6750 for the cycle) and different window lengths, and the saturation stage starts straight after the baseline inside one replay.
These results do not establish which of those differences, if any, decides the outcome; they establish only that 8 req/s passed the 50 s rule and failed the 135 s one, in both sessions.

### Recovery

Windows are 20 s tumbling windows by intended arrival from the end of the overload; a window is recovered when every request sent in it completed and its p90 TTFT is at most 1.5 x the baseline's p90 + 25 ms.

| Session | Window p90 limit | Recovery time | First recovered window's p90 | Engine drain (secondary) |
|---|---:|---:|---:|---:|
| S2 | 236.7 ms | **60 s** after the overload ended | 139.4 ms (n=46) | 47.0 s |
| S3 | 234.8 ms | **60 s** after the overload ended | 132.9 ms (n=46) | 47.0 s |

| Window start | S2 sent = completed | S2 p90 TTFT | S3 sent = completed | S3 p90 TTFT |
|---:|---:|---:|---:|---:|
| 0 s | 22 | 33,112.3 ms, not recovered | 22 | 33,283.0 ms, not recovered |
| 20 s | 45 | 19,064.4 ms, not recovered | 45 | 19,176.4 ms, not recovered |
| 40 s | 38 | 1,810.0 ms, not recovered | 38 | 1,938.5 ms, not recovered |
| 60 s | 46 | 139.4 ms, recovered | 46 | 132.9 ms, recovered |
| 80 s | 42 | 137.9 ms, recovered | 42 | 139.2 ms, recovered |
| 100 s | 40 | 135.7 ms, recovered | 40 | 137.2 ms, recovered |

Every later window up to the last one that ends inside the 240 s stage (start 220 s) was recovered in both sessions (`stages.cycle.recovery.windows` in each `report.json`).
The engine drain is the time from the end of the overload to the first 1 s scrape in which `vllm:num_requests_waiting` read 0, with a resolution of one scrape (CONTRACT.md section 6).

### Restart window

Each restart: `SIGKILL` of the engine container, `docker start` of the same container, timed to the end of the first successful 16-token probe; warm cache state (the container's own compile cache survives, weights in the host's cache, prefix cache off), 10 s idle before each.

| Session | Restart 1 | Restart 2 | Restart 3 |
|---|---:|---:|---:|
| S2 | 45.6 s, serving (89 probes) | 47.2 s, serving (92 probes) | 43.9 s, serving (86 probes) |
| S3 | 53.8 s, serving (101 probes) | 45.2 s, serving (87 probes) | 44.8 s, serving (88 probes) |

Every restart in both sessions was serving well inside the 240 s bound.
During each window the single engine served nothing; with one replica there is no failover.

## What the engine data shows about the limit

In both sessions the engine's `running` gauge peaked at 64 in the 8 and 10 req/s rungs and in the saturation, overload and recovery stages, and at 40 or less in every lower rung and in the baseline; in all of those, KV usage peaked at 9.9% or less and `waiting` grew from 12 or 13 (8 req/s rung) to 127 (10 req/s rung) and to 313 or 314 (overload).
64 is the profile's `--max-num-seqs`: [`internal/engineargs/engineargs.go:36`](../../internal/engineargs/engineargs.go) renders `--max-num-seqs=64` for the reviewed v0.27.1 row, and each session's engine ran with it ([`runs/s2/run/results/engine-args.txt:4`](runs/s2/run/results/engine-args.txt), [`runs/s3/run/results/engine-args.txt:4`](runs/s3/run/results/engine-args.txt)).
So in these sessions the queue formed while the batch was at the sequence cap and the KV cache was about one tenth used: the data are consistent with the sequence cap, not KV capacity, being what bounded concurrency.
They do not show what a higher `--max-num-seqs` would give: no session ran another value, and the per-token decode time also rose (TPOT p50 about 19 ms at 3 req/s against about 58 ms at 10 req/s in both sessions, `report.txt` lines 9 and 44), so lifting the cap is a hypothesis for a new contract, not a result of this one.
The GPU's utilization peaked at 95 to 97% at every rate, including 3 req/s, so that gauge does not distinguish these load levels.

## Cost per 1M completed output tokens

`$ per 1M = hourly price / (completed output tok/s x 3,600) x 1,000,000`, for the baseline stage and the 8 req/s saturation stage.

| Session | Stage | Output tok/s | At the recorded Spot price, $0.5895/h | At the runner's all-in cap, $0.7683/h |
|---|---|---:|---:|---:|
| S2 | Baseline, 2 req/s | 247.47 | $0.6617 | $0.8624 |
| S2 | Saturation, 8 req/s | 1,038.22 | $0.1577 | $0.2056 |
| S3 | Baseline, 2 req/s | 247.47 | $0.6617 | $0.8624 |
| S3 | Saturation, 8 req/s | 1,038.22 | $0.1577 | $0.2056 |

- **Population.** The output tokens are the engine's `completion_tokens` of the completed requests whose intended arrival lies in the stage's 135 s measured window (261 requests in baseline, 1,095 in saturation, 128 tokens each, in both sessions), divided by 135 s.
  A request that arrived in the window and completed after it, during the next stage or the final drain, is attributed to the stage it arrived in, so these are tokens per second of the stage's arrivals, not of the GPU's wall-clock output inside the window (CONTRACT.md section 2).
- **Prices.** $0.5895/h is the ap-northeast-2d g5.xlarge Spot price the runner recorded just before each launch (`runs/s2/spot-prices.txt:3`, `runs/s3/spot-prices.txt:3`; read by `describe-spot-price-history` at [`hack/gpu-kit-session.sh:349`](../../hack/gpu-kit-session.sh)); it is the instance alone and excludes the volume and address.
  $0.7683/h is the runner's all-in rate for g5.xlarge, the $0.70/h Spot cap plus $0.0683/h of storage and address ([`hack/gpu-kit-session.sh:56`](../../hack/gpu-kit-session.sh), also `all_in_rate=0.7683` in each `session-provenance.txt`).
- The figure assumes the GPU is billed only while it serves at that stage's rate; it leaves out the bring-up, the image pull, the engine start and idle time, which the sessions' elapsed times in `attempts.md` include.
- **The 8 req/s row is at a rate that did not hold**: in that stage p99 TTFT was 3,698.1 ms (S2) and 3,547.6 ms (S3), over the contract's 2,000 ms.
  The 2 req/s row is at a quarter of R_sat, where most of the GPU's capacity went unused.
  Neither is a price for a latency target.
- No comparison with any commercial API price is made or implied.

## What these results allow

Under CONTRACT.md section 10, per included session and with its sample counts:

- **Session 2:** on one A10G, with this image, profile, model revision and workload, the highest stable rate of the pilot's ladder was 8 req/s (rung 5, n=385 completed, p99 TTFT 1,688.9 ms); the first unstable rung was 10 req/s.
- **Session 3:** on one A10G, with this image, profile, model revision and workload, the highest stable rate of the pilot's ladder was 8 req/s (rung 5, n=385 completed, p99 TTFT 1,643.6 ms); the first unstable rung was 10 req/s.
- In both sessions the 150 s saturation stage at 8 req/s did not hold (S2 and S3 failed), the 90 s overload at 12 req/s completed every request it was sent with p99 TTFT near 37 s, and the recovery rule found recovery 60 s after the overload ended.
- In both sessions each of the three warm restarts served again within 43.9 to 53.8 s: 45.6, 47.2 and 43.9 s in session 2; 53.8, 45.2 and 44.8 s in session 3.

## Not claimed

- **No universal or maximum capacity of the A10G.** 8 req/s is the highest stable rung of one fixed ladder, for one model, image, profile and workload (512 in, 128 out, prefix caching off), on two sessions in one zone; another workload, profile or `--max-num-seqs` is another measurement.
- **No end-to-end latency through the gateway.** These sessions ran the engine directly; the gateway's share was measured separately on kind ([README](README.md)) and is never added to these figures.
- **No HA or zero-downtime statement.** One replica on one GPU; each restart window above is a full outage of that replica.
- **No large-scale statement**: nothing about more GPUs, more replicas, autoscaling or many tenants.
- **No hardware-variance statement.** Both included sessions ran on a g5.xlarge Spot instance in one zone, each on whichever A10G that launch got; the agreement between them is not a measurement of card-to-card or instance-to-instance spread.
- **No output-quality statement.** The contract checks each completed request's token counts and finish reason (512 prompt tokens, exactly 128 completion tokens under `ignore_eos`, finish reason `length`), not what the model wrote; nothing here says the answers were correct.
- No p99 below 100 completed requests appears above; the smallest population with a p99 is 122.
