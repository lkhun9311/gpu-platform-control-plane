# A real-GPU A/B for llm-d-router #1598, bursty request distribution

Date: 2026-11-21. Status: **design, revised three times ("Revisions" at the end); the pilot ran on 2026-11-21 ($1.95); the main run is not bought; nothing posted upstream.**
Budget: pilot about $3 (spent $1.95), main run about $20 to $24; **the third revision ("Main-run design after the pilot") adds a second pilot and supersedes the main-run load, sessions and cost below where they differ.**
This page fixes the arms, workloads, apparatus, measurements, pre-registered criteria and cost before any harness code is written.
The harness is built in a follow-up, from this page.

## Why this experiment, and what it adds to the thread

- llm-d/llm-d-router#1598 (opened 2026-06-11 by elevran, assigned to elevran and ezrasilvera) asks for better distribution when many requests are scheduled concurrently against the same observed state.
  elevran wrote on 2026-10-12: "Need to confirm if still an issue - will close if not reproduced".
- Everything posted in the thread since is unit-level or simulator-only:
  ishwar170695 (picker simulation, 10-14; #1599 probes, 11-08), ptimizeroracle (in-process bench with llm-d-inference-sim, 10-14, 11-11, 11-14, gist 11-16), kuluruvineeth (4 simulated endpoints behind Envoy, 10-27), lilong555 (simulator, 11-13 and 11-20).
  ptimizeroracle's own caveat (11-14): "the sim does not slow prefill under batching".
- An upstream fix is open: **#4313 "epp: Reserve at pick - close the concurrent-scheduling thundering-herd race"** (DolevAdas, draft, opened 2026-11-17, "Fixes #1598"), linked from the issue's timeline rather than its comments.
  Its evidence is an in-process A/B (64 cycles: 64 of 64 on the least-loaded endpoint without it, 16/16/15/17 with it) and a "4-pod rig, full gateway" with mean top-endpoint share 60% to 50%; the PR does not say what the four pods' backends were.
  Its in-process test releases the 64 goroutines **250 µs apart** (about 16 ms in all), because "a truly simultaneous release makes the 'with' arm depend on goroutine interleaving and flake on many-core hosts", and its baseline arm never calls `PreRequest`, so its load stays frozen; the reservation is made after `Schedule()` returns, not atomically with reading load and picking.
  So #4313 narrows the window between a pick and the next cycle seeing it; whether that closes the effect on a simultaneous burst is what K tests, not something the PR's numbers establish.
- **I found no run on real vLLM with real prefix caching on GPUs in the issue or in the PRs linked from it, for the current default or for #4313.** That is the contribution: data and analysis, not a scheduler change and not taking over the issue or the PR.
- gpuaas has its own reason to run it. Experiment A's prefix-routing tail (`shared-942`) came from front-loaded first-sight prompts placed on one least-loaded backend (`docs/superpowers/specs/2026-11-21-routing-l3-notmet-rootcause.md` on branch `feat/routing-l3`, commit `1d781e96`).
  The L3 strategy review (`storage/open-source/policy/inference-strategy-review-2026-11-21.md`) adopts the "A table" criteria used below.
- Correction carried into the design: `shared-942`'s first sights were **not** a concurrent burst.
  Its 25 arrivals in the first 20 s were 39 ms apart at the closest and 648 ms at the median (recomputed from `hack/prefix-route/2026-10-28-run2/.../shared-942-RoundRobin/trace.jsonl`), far outside the few-millisecond window ptimizeroracle measured (10-14: 20 ms spacing removes the effect, 5 ms does not).
  So the gpuaas tail and #1598 share a symptom (cold work piled on one backend) and not necessarily a mechanism; the workloads below separate the two, and a staggered control (K-stagger) tests whether any concentration is the concurrent-snapshot mechanism.

**What this is and is not.** It measures llm-d's current default approximate profile, the same profile with #4313, and round-robin, on real engines, using the thread's workload shapes.
It is **not** a replication of the simulator experiments: the scorer set, router version, backend and scale differ (see "Comparability"), so the post compares directions and mechanisms and does not call either result a replication.

## Related items checked (2026-11-21)

| item | what it is | bearing here |
|---|---|---|
| #4313 (open draft PR) | reserve the picked endpoints at scheduling time through `inflight-load-producer` | **arm A2** |
| #1599 (closed PR) | load-aware picker; closed for "negative impact on normal operations" | why the criteria include a no-regression check on steady affinity (C3) |
| #3245 (open) | `prefix-cache-affinity-filter`'s TTFT gate cannot release a decode hotspot: 96 of 96 requests to one endpoint | the filter is in A1 and A2; its `sticky` and `load_override` counts are recorded per cell |
| #4042 (open) | `load_override` cascading overload; sohom-cs is taking bounded spillover | workload B is the cache-pressure regime where spill and affinity trade off |
| #3421 (open PR) | queue-wait term in the filter's TTFT estimate; stacked on #3514 (merged 11-11) | not run; changes the gate, not the concurrent-pick race |
| #3503, #3574, #4328, #4040 (open), PRs #3504, #3588, #4400 | stale or wrong residency in the precise index | the approximate producer used here has its own staleness (it never sees engine evictions); measured below as credited prefix with no realized reuse, not claimed as a defect |
| #4354, #4331 (open, assigned) | KV event lag; speculative indexing past the engine block | precise-producer issues; this design uses the approximate producer |
| #1727 (merged 2026-07-06) | `burst-prefix-cache-producer`: a windowed joint assignment for prompt-sharing bursts | groups **identical** prompts only (with `minColocateBlocks: 0`), and a request that overlaps no other "receives no affinity", so it does nothing for a burst of distinct first sights. Recorded, not an arm |

## Arms (three)

All arms run in file-discovery mode behind Envoy (`docs/discovery.md` "Running EPP with file discovery (no Kubernetes)") against the same four engines.

| arm | binary | config | why |
|---|---|---|---|
| **A1 default** | llm-d-router `main` at **`733d0e4ee18082d2e252fc887db7701c037b8034`** (2026-11-20T22:52Z) | llm-d's guide `optimized-baseline` (llm-d `d83e85c37c0d`, `guides/optimized-baseline/router/optimized-baseline.values.yaml`): `approx-prefix-cache-producer`, `inflight-load-producer`, `prefix-cache-affinity-filter`, `token-load-scorer`, default `max-score-picker`; the filter's `peakPrefillThroughput` set to the value measured in the pilot (below) | the current default approximate prefix profile with load scoring, as shipped by llm-d; the profile kuluruvineeth measured on 10-27 (12 of 16 first turns on one endpoint); and the only default profile in which #4313 acts |
| **A2 reserve-at-pick** | `733d0e4e` with #4313's head **`d44cd67633de14940df4868422559db75c4a2985`** merged (8 commits, merge base `247a68ce`; GitHub reports it mergeable; the merged tree's hash is recorded, and a merge conflict at build time stops the session before any purchase-dependent step) | identical to A1 | the closest upstream candidate (below) |
| **A3 round-robin** | A1's binary | `max-score-picker` with no filter, scorer or producer | every score ties, and `RotateScoredEndpoints` with a mutex-guarded per-pool counter (`picker/common.go` `NextCounter`) gives strict rotation even under concurrent picks; it shares the transport (Envoy, `ext_proc`, the EPP process) but not the producer and scorer work, so its routing overhead is lower and is reported, not assumed equal |

**`peakPrefillThroughput`.** The guide ships the plugin default 15,928 tokens/s, calibrated "for Qwen 32B on H100 80 GB (TP=2)", and tells operators on other hardware to measure their own with `guides/recipes/router/calibration`.
That recipe is a Kubernetes Job; the pilot reimplements its method on plain processes (requests of exactly `CHUNK_SIZE` random token IDs, so every one misses the cache; `peakPrefillThroughput = CHUNK_SIZE / median(TTFT)`), with `CHUNK_SIZE` 2,048 under the A and K engine configuration (`--max-model-len 4096`), first in the pilot, recording the engines' effective chunked-prefill and batch-token settings; A1 and A2 use the same measured value.

**The reservation/cost prototype is not an arm.**
lilong555's prototype is public, but as a source overlay inside an evidence repository (`lilong555/scheduler-feedback-evidence-20261112`, `sources/llmd/{performance,lifecycle}/.../picker/reservations/`, commits `6a8cc65d` and `8ead7cb9`), not as a router branch; lilong555 has no llm-d-router fork.
Its own write-up says "production YAML registration and discovery/eviction integration remain implementation work": the adapter is instantiated by the author's harness, so running it in a real EPP means writing that integration ourselves.
Its service model assumes a fixed worker slot from prefill to decode ("matching the queue structure used by the cost estimate"), which vLLM's continuous batching does not have.
And its author reported it regressing on every seed of workloads A and B on 2026-11-20 ([RESULTS.md at `8ead7cb9`](https://github.com/lilong555/scheduler-feedback-evidence-20261112/blob/8ead7cb9942ac15d1d06df712be0f03ce66f46ea/studies/cache-pressure/RESULTS.md)): TTFT p95 2,939 ms (A) and 1,849 ms (B) against MaxScore's 40 and 40 ms, "an occupied slot's predicted completion can expire".

**So A2 is #4313, the closest upstream candidate.**
It is the same idea, a reservation booked right after the pick so later cycles see it sooner, as an open upstream PR that builds into the real EPP with no integration of ours, and it states that it fixes #1598.
It acts only through `inflight-load-producer` (the director calls every configured `EndpointReserver`, and the producer is the one that implements it), so in a profile without that producer it is a no-op; that is why A1 is the guide's profile and not the router's `test/perf` `optimized-baseline.yaml` (queue, KV, prefix and no-hit-lru scorers, no in-flight producer), which an earlier draft of this page used.

**Arms not run, and why.**
- `weighted-random-picker`: the most-measured row in the simulator tables (ptimizeroracle 10-14, 11-11, 11-14; lilong555 11-13, 11-20), on `main` with no code; it is the fourth arm this budget drops, because it is a picker change and the thread's open fix is #4313.
- "#1599 with a wall-clock window and no capacity factor": a patch of a closed PR, not upstream code.
- The router's `test/perf` scorer profile and the gist's own scorer set (prefix 3, queue 2, running 2, KV 2): neither has `inflight-load-producer`, so #4313 would do nothing in them.
- The precise profile: needs a tokenizer sidecar and KV events; the thread's numbers all use the approximate producer.

**If cost forces two arms, A3 goes.**
The question is A1 against A2; A3 is the null for burst shares (exactly even by construction) and the load-oblivious reference.
Without it the rate grid is anchored on A1 in the pilot, and C1 compares against the even share 16 instead of A3's measured shares.

## Workloads (three blocks, and K with two controls)

**Prompts are sent as token-ID arrays.**
Every request goes to `/v1/completions` with `prompt` as a list of Qwen2.5 token IDs, so the router and the engine see the same tokens: the EPP stores client-supplied IDs as its `TokenizedRequest` (`dataproducer/tokenizer/client_tokens.go`) instead of auto-creating the byte-packing `estimate` backend, which a text prompt with no `token-producer` would get (`dataproducer/tokenizer/README.md`, "Backend").
The gist's bench also hands its producer token IDs directly, so this keeps that property.
The approximate producer matches in blocks of at least 64 tokens whatever the engine's block size (`approximateprefix/plugin.go` `GetBlockSize`, #1158); router credit is therefore counted in 64-token router blocks and engine reuse in tokens, and the two units are never mixed.
Each request is streamed with `stream_options.include_usage: true`, `ignore_eos: true` and `min_tokens = max_tokens`.
Output length: the simulator sampled 1 to 32 tokens; here each A, B and K request's `max_tokens` is drawn uniformly from 1 to 32 by the arrival seed, so the lengths are the same in every arm and still variable, which lilong555 (11-20) found mattered.

| block | from | per request | arrivals | engines' KV | window |
|---|---|---|---|---|---|
| **A** | ptimizeroracle's A | one of **2** shared 512-token prefixes + 32 unique suffix tokens | Poisson, arrival seeds 1, 2, 3 | 4,096 blocks of 16 per engine | 30 s in all, the first 5 s warm-up, so 25 s measured (the gist's executable behaviour) |
| **B** | ptimizeroracle's B | one of **48** shared 256-token prefixes + 32 unique suffix tokens | Poisson, arrival seeds 1, 2, 3 | **400** blocks of 16 per engine | 40 s in all, 10 s warm-up, 30 s measured |
| **K** | the thread's burst column; #4313's own test shape ("one uniquely least-loaded endpoint") | 64 cold prompts of 544 tokens released at once; 6 bursts per cell; all 384 prompts of a cell have distinct first router blocks, so no burst is warmed by an earlier one | before each burst, three engines each hold one preload still **in prefill** and one engine holds none, so the scorer sees one strictly least-loaded endpoint (see "K's preloads") | as A | each burst |
| **K-stagger** | control for K | K's prompts and preloads | each burst's 64 requests released **20 ms apart** (ptimizeroracle 10-14: 20 ms spacing removed the concentration in the simulator) | as A | each burst |
| **K-equal** | control for K | K's prompts, **no preloads**, so every endpoint scores the same | released at once, as K | as A | each burst |
| **W942** | gpuaas `shared-942` | one of **48** system prompts of 7,680 tokens + a 256-token unique suffix, 64 output tokens | phase 1: `shared-942`'s 25 arrival offsets in its first 20 s, each arrival released as **two** simultaneous distinct requests (48 first sights + 2 repeats); phase 2: Poisson repeats of those 48 prompts at 1.6/s for 100 s; seeds 941, 942, 943 draw the prompt texts and phase 2 | vLLM's default sizing (about 393k tokens each, from experiment A's `cache_config_info`; read back per cell) | the whole trace, no warm-up |

**Scaling from 8 simulated pods to 4 engines.**
- A keeps the prefix-to-endpoint ratio of the thread's A ("4 hot prefixes on 8 pods"): 2 prefixes on 4 engines.
- B keeps the thread's 48 prefixes and its 400 blocks per endpoint, so the shared working set sprayed over every engine is 48 × 16 = 768 blocks per engine against 400, the simulator's own ratio of 1.92; with affinity each engine holds 12 prefixes, 192 blocks (0.48 of capacity, against the simulator's 96 blocks, 0.24), leaving room for running requests' private blocks (at most 16 × 4 = 64).
  That arithmetic shows potential pressure, not pressure during the measured window: a lower hit fraction under round-robin would also follow from compulsory first fills alone, with any cache size.
  So the rows separate **first fills** (a prefix's first request on an engine) from **lost reuse** (a request whose prefix had already been served on its engine, by a completed request, and which nevertheless got `cached_tokens = 0`), and B counts as a cache-pressure regime only if A1 shows lost reuse on at least 1% of its measured requests in the pilot's B cell; otherwise B is reported as not testing cache pressure at this geometry, and C3's B part is about steady affinity only.
- K's k=64 on 4 engines is the thread's k=128 on 8 in requests per endpoint (even share 16), and #4313's own 64 cycles; the largest share's distribution differs with endpoint count, so K is compared with A3, K-stagger and K-equal measured here, never with the thread's numbers directly.
  The gist's burst sends the prompt `"hello"`; K sends 544-token cold prefills, so each request occupies its engine longer and the load the scorer sees changes over a longer time; that difference is in the comparability table.
- W942 doubles `shared-942`'s per-engine first-sight count (24 over 2 engines becomes 48 over 4), keeps its prompt and output shape, and releases each arrival as a pair.
  Time-scaling to a grid rate (below) shrinks or stretches the gaps between pairs, never within one.

These are deviations from the gist, and the post says so.

**Engine slots.** `--max-num-seqs 16` on every engine is an intentional concurrency cap: 4 × 16 = 64 sequences, the same count as the thread's 8 × 8.
Equal sequence counts do not make the capacity equal (the simulator's 60 ms inter-token latency and fixed prefill timing are not a continuously batched GPU's), so occupancy, waiting, preemptions and the effective batch-token limit are reported per cell, and conclusions are limited to this capped configuration.
Under vLLM's default (256 or more) requests would wait in the engine far less often at these rates; that sensitivity is the first cell to add if wanted, and it is not in the budget.

## Apparatus

- **Instance:** one **g5.12xlarge Spot** (4 × A10G 24 GB, 48 vCPU, 192 GiB) in ap-northeast-2, through `hack/gpu-kit-session.sh` as extended for g5.12xlarge and four-GPU preflight in commit `c85a2901` (branch `feat/sglang-51980`, not on `dev` yet; the harness PR depends on it reaching `dev` or carries that commit).
  The account's Spot G and VT quota is **48 vCPU, exactly one g5.12xlarge**, so every session runs alone: the pilot's termination must be confirmed before the first main session is requested, and no two sessions overlap.
- **Session clock** (fixed by the runner, a caller cannot move it): bring-up 300 s, the kit's `run.sh` 3,300 s, evidence upload 60 s, self-shutdown at 3,720 s, termination confirmed by 4,020 s after `LaunchTime`.
  While the kit runs, the runner archives and uploads its records, then sleeps 60 s (runner lines 178 to 184 at `c85a2901`), so the newest checkpoint can be about two minutes old.
- **Layout: plain processes on the host, no kind.**
  Four vLLM servers, one per GPU (`CUDA_VISIBLE_DEVICES=i`), ports 8000 to 8003; one EPP (file discovery, endpoints file listing the four; the arm's binary); one Envoy with `ext_proc` to the EPP, as the router's discovery doc describes; the sender.
  CPU is pinned with `taskset`: each engine on its own 8 cores, the EPP and Envoy on 4 cores, the sender on 4 cores, so the router is never starved by the sender at the top rate; each group's CPU use is sampled at 1 Hz.
- **vLLM 0.34.0** (PyPI wheel, uploaded 2026-11-16; sha256 pinned in the kit) in a uv venv on the runner's Python 3.12.15.
  Flags fixed for all arms: `--enable-prefix-caching`, `--block-size 16`, `--max-num-seqs 16`, `--enable-prompt-tokens-details` (so each response carries `usage.prompt_tokens_details.cached_tokens`), `VLLM_SERVER_DEV_MODE=1` for `POST /reset_prefix_cache` (present at `v0.34.0`, `vllm/entrypoints/serve/dev/cache/api_router.py`); for A and K `--max-model-len 4096` and `--num-gpu-blocks-override` 4,096; for B `--max-model-len 2048` and 400 blocks; for W942 `--max-model-len 8192` and default sizing.
- **Model:** `Qwen/Qwen2.5-3B-Instruct` at revision `aa8e72537993ba99e69dfaafa59ed015b17504d1`, experiment A's model, downloaded once per session into the local HF cache (about 6 GB; a 15.8 GiB download took 47 s on this runner, `gptq-marlin-moe-copies-r8`).
- **EPP**: two binaries built on the instance (A1's from `733d0e4e`; A2's from that commit with `d44cd676` merged) with a sha256-pinned Go toolchain matching `go.mod`; each binary's sha256 and the merged tree hash are recorded. **Envoy** pinned by image digest or release binary sha256 (chosen in the harness PR). The EPP's metrics refresh interval and every flag are recorded; only the binary (A1 against A2) or `--config-file` (A3) differs between arms.
- **Per cell:** drain (no running or waiting request on any engine); `POST /reset_prefix_cache` on all four and require `success: true`; start the arm's EPP process fresh (fresh approximate index, in-flight counters and reservations); scrape every engine's and the EPP's `/metrics` (before); replay; wait for the last response or its timeout; scrape (after); export.
  Engines restart only when the block changes their flags (A, K, K-stagger and K-equal share one config; B and W942 each have their own).
- **K's preloads: an in-prefill backlog the scorer can see.**
  In A1 and A2 the only load signal is `token-load-scorer`, which reads the EPP's own `InFlightLoad.Tokens` (`scorer/tokenload/token_load.go`), not the engines' metrics; and with the guide's `addEstimatedOutputTokens` left false, `inflight-load-producer` frees a request's tokens when its prefill completes and keeps only its request count (`inflightload/kvevents.go` `onPrefillComplete`).
  A long decoding request is therefore invisible to the scorer, and an engine-side `num_requests_running` of [0, 1, 1, 1] is not the asymmetry K needs.
  So each preload is a **4,000-token prompt of random token IDs with `max_tokens = min_tokens = 1`**, sent through the router like any request: three are sent back to back (the EPP adds each to its in-flight tokens at `PreRequest`, so the second and third go to other engines), and the burst is released as soon as the third has been forwarded, while all three are still in prefill (an isolated 4,000-token prefill on this card is expected to take a few hundred milliseconds; the pilot measures it).
  The burst is valid only if, from the EPP's and Envoy's timestamps, **every one of its 64 requests was scored before any of the three preloads' first token**, and the three preloads went to three distinct engines; otherwise it is recorded as invalid, and never retried within the cell. Which engine was left idle is recorded.
  Preloads have their own 10 s timeout, run under A3 too (where they do not affect the rotation), and are a separate population in the ledger.
  K-equal sends no preloads, so every endpoint scores the same and `max-score-picker`'s tie rotation is what distributes the burst.
- **Sender:** open loop on a precomputed absolute schedule (dispatch lag recorded per request), HTTP keep-alive connections opened and warmed before the first scheduled request so a burst is not serialized by connection setup; each request tagged with its own `x-request-id`.
  Whole-request timeouts: 20 s for A and B, 10 s for K and its controls, 45 s for W942; a timeout or error is an outcome (TTFT = ∞), not an instrumentation failure.
  Built on the instance from the kit's committed source; its offline tests run first.

## Measurement

**Seeds:** three per block (A, B, K and its controls: arrival seeds 1, 2, 3, the gist's; W942: 941, 942, 943).
The seeds are three paired blocks, each run once; they are the independent unit, and requests within a cell are not independent samples.

**Arrival-rate grid, bracketing a TTFT SLO.**
- `SLO_w` for each block w is fixed by a rule registered now: **3 × the p50 TTFT of that block's request shape on one idle engine through Envoy and the EPP (A3), cold, 20 sequential requests each with its own never-seen random prefix (so every sample is a cold prefill), rounded up to the next 10 ms**, measured in the pilot. Expected (not registered): about 200 ms for A and B, about 3 s for W942.
- `r_w`: the highest rate in the pilot's ramp at which A3 serves ≥ 95% of offered requests within `SLO_w` with completion 1.0.
- **Main grid: 0.6, 0.9, 1.2 and 1.5 × r_w** for A, B and W942. K has no rate (it is a burst).
  For W942 the whole base trace (about 210 requests over 120 s, a mean of about 1.75/s) is time-scaled so its mean rate equals the grid rate: every request, its order, its pair partner and its prompt stay the same at every rate, and only the offsets shrink or stretch, so the first-sight and repeat mix is the same at every rate.
- **Highest passing tested rate** of an arm on a seed: the highest grid rate at which it serves ≥ 95% of offered requests within `SLO_w` and completes all of them; reported as "≥ 1.5 ×" or "< 0.6 ×" (censored) when the grid does not bracket it.
  It is not a maximum sustainable rate: each cell is a finite trace followed by a drain, and nothing here tests that queues stay bounded over a longer interval.
- **Goodput** at a grid rate: requests completed with TTFT ≤ `SLO_w`, per second of the measured window. Goodput "at equal SLO" compares arms at the same `SLO_w`.

**Per request** (one row per offered request, offered = the schedule, not what was sent):
- TTFT = arrival of the first SSE event whose text is non-empty − scheduled send time, on the client's monotonic clock in microseconds; the first SSE event of any kind is recorded separately, since a role-only or empty event can precede the first text;
- **after-routing TTFB**, not TTFT: from Envoy's access log for the same `x-request-id`, upstream request sent to first upstream byte, which can be response headers (Envoy's `%COMMON_DURATION(...)%` time points; the exact fields are fixed in the harness PR against the pinned Envoy's documentation); the gist's after-routing TTFT ends at its first SSE `data:` line, a different boundary, so the post names this figure TTFB and does not compare it with the gist's as the same quantity;
- tokens from `usage` (`prompt_tokens`, `completion_tokens`, `prompt_tokens_details.cached_tokens`), never from counted stream events (llm-inference-lab E29 to E31: client stream events are not tokens, and chunks can merge);
- client TPOT = (arrival of the last non-empty text event − arrival of the first) / (completion_tokens − 1), using the usage count, defined only for `completion_tokens ≥ 2` (about 1/32 of A, B and K requests have one output token and are reported as a separate population); event arrival times are not per-token times when events merge, so this is labelled client TPOT, and the engines' `vllm:inter_token_latency_seconds` histogram deltas are reported separately as ITL;
- the chosen endpoint (Envoy `%UPSTREAM_HOST%` keyed by `x-request-id`), the routing path's time (Envoy, from receiving the downstream request to sending it upstream), and from the EPP's log at **`-v=5`** with timestamps: the per-endpoint "Calculated score" lines (DEBUG, level 4, `scheduler_profile.go`) and the approximate producer's matched blocks per endpoint (TRACE, level 5, `approximateprefix/plugin.go`); #4313 logs nothing when it reserves (its diff has no log line in `ReserveResult`), so A2's reservation times are **not available**, and its timing evidence is the pick and `PreRequest` times alone; no instrumentation is added to either binary;
- the joined pair: what the router credited the chosen endpoint (matched 64-token router blocks) against what the engine served from cache (`cached_tokens`), split into **in-flight credit** (the endpoint's earliest request with that prefix had not yet produced its first token when this one was scheduled, since `PreRequest` inserts index entries optimistically, `approximateprefix/plugin.go`) and **completed credit** (it had).

**Per cell, an accounting ledger with three populations** (evaluation, warm-up, K's preloads), reconciled against the engines (the client is not trusted alone):
- for each engine, the rows routed to it that completed with a usage record sum exactly to its `vllm:prompt_tokens`, `vllm:generation_tokens`, `vllm:prompt_tokens_cached` and `vllm:request_success` counter deltas **when no request to that engine failed, timed out or was cancelled** (preloads are cancelled by design);
- when some did, the engine's deltas must be at least the completed rows' sums, and the excess is recorded as work done for requests that did not complete;
- completion = evaluation rows with HTTP 200, a terminal `[DONE]` and `completion_tokens = max_tokens`, over offered evaluation requests; failures stay in every comparison;
- `vllm:num_preemptions` delta, and the filter's `sticky` and `load_override` decision counts (`prefixcacheaffinity/metrics.go`), reported.

**Load imbalance over time:** each engine's `num_requests_running`, `num_requests_waiting` and `kv_cache_usage_perc` sampled at 4 Hz; per 1 s window the coefficient of variation of outstanding requests (running + waiting) across the four engines, and its time average; each engine's share of each block's requests; for K, K-stagger and W942's phase 1, the largest share any one engine got of each simultaneous release (the thread's "max share"), with all six of K's burst shares published, not only the mean.
The 4 Hz samples describe load; they cannot resolve the few-millisecond scheduling window, which is read from the EPP's timestamps (below).

**Concurrent-snapshot evidence (K and its controls).** From the EPP's `-v=5` timestamps: for each burst, how many of its 64 requests were scored before the first pick's `PreRequest` was logged, and the score vectors they saw (for A2 the reservation itself is not logged, see above).
Concentration in K is attributed to #1598's mechanism only if most of the burst was scored on the same state, K-stagger's largest share is lower, and K-equal's is near even; otherwise it is reported as concentration without a mechanism.

**Prefix copies:** for A and B, how many engines each prefix was sent to (the thread's "copies"), and the engines' own reused-prefix fraction Σ `cached_tokens` / Σ `prompt_tokens`.

**Percentiles** are nearest-rank over every offered request of the measured window. With 25 s of A at a low rate, p99 is decided by a handful of rows (experiment A's lesson: "five rows decided rule 4"), so the criteria use p95 and report p99 beside it.

## Pre-registered criteria

From the strategy review's A table. Each is reported on its own; there is no single MET verdict, because the deliverable is data for #1598 and #4313, not a pass for a gpuaas change.
"Paired" means the two arms in the same session at the same rate and seed; "2 of 3" means at least two of the three seeds.
The 2-of-3 rule is a **descriptive** acceptance rule over three runs, not a statistical test; every paired effect, its sample count and every seed's value are published beside the outcome word.

**Infinite and empty cases, for every ratio below.** A failed request has TTFT = ∞, so a percentile can be ∞.
Both arms ∞: no difference is shown, and the seed counts against any "lowers" or "spreads" outcome.
The candidate finite and the baseline ∞: a categorical improvement on that seed, with the percentage undefined and reported as such; the reverse is a categorical regression.
An empty population (for example no first sights in a window) or a missing seed is reported as such and counts as neither.

| # | A table row | criterion | outcome words |
|---|---|---|---|
| C1 | reproduced counter-example for the current policy | In K, A1's mean largest share per burst is **≥ 24 of 64** (1.5 × the even 16; A3 is measured beside it) in 2 of 3 seeds. For scale: the simulator's MaxScore at k=128 was 58.7 of 128, 45.9%, which is 29.4 of 64 | CONCENTRATION AT OR ABOVE / BELOW THE REGISTERED THRESHOLD; and, separately, ATTRIBUTED / NOT ATTRIBUTED to concurrent scheduling by the evidence above |
| C2 | the candidate's effect on the burst | In K, A2's mean largest share is **≤ 0.75 ×** A1's, paired, in 2 of 3 seeds; and in W942 at 0.9 × and at 1.2 ×, A2's TTFT p95 over the whole trace is **≤ 0.90 ×** A1's, paired, in 2 of 3 seeds at each rate (first sights and repeats reported separately beside it) | each part: A2 SPREADS THE BURST / DOES NOT; A2 LOWERS THE TAIL / DOES NOT |
| C3 | no regression in normal operation (#1599's failure) | In A and in B at 0.6 × and at 0.9 ×, A2's reused-prefix fraction is **≥ A1's − 0.05** and A2's TTFT p95 is **≤ 1.20 ×** A1's, paired, in 2 of 3 seeds at each rate; B's part decided only if the pilot's geometry check passed | HOLDS / VIOLATED, per block and rate |
| C4 | SLO goodput against the best existing policy | Per block A, B, W942: A2's highest passing tested rate is **at least one grid step above** (or below) A1's in 2 of 3 seeds; censored values compare only where the order is still known | HIGHER / LOWER / NO DIFFERENCE AT THIS GRID; A3 reported as the third column |
| C5 | victim tail | In W942 at 0.9 ×, phase-2 repeats' TTFT p95 under A2 is **≤ 1.20 ×** A1's, paired, in 2 of 3 seeds | HOLDS / VIOLATED |
| C6 | no-prefix regression | In W942 at 0.6 ×, first sights' TTFT p50 under A2 is **≤ 1.10 ×** A1's, paired, in 2 of 3 seeds | HOLDS / VIOLATED |
| C7 | routing overhead against prefill saved | For every arm and cell, the EPP's own scheduling-duration p99 (its histogram times `Scheduler.Schedule` only; #4313's reservation runs after it, in the director) is **≤ 5 ms**; the full routing path's p99 from Envoy is reported beside it with no threshold, and is where A2's extra work shows. Prefill saved is an **estimate**, `cached_tokens` ÷ the pilot's isolated prefill rate, labelled as such: under batching the real saving is not linear; it is reported, not gated | HOLDS / VIOLATED (scheduling part only) |
| C8 | zero false residency hits | Among requests credited **completed** prefix of ≥ 1 router block (64 tokens) on their chosen endpoint, the share with `cached_tokens = 0` is **≤ 0.5%** under A1 and A2 in A; W942 and B reported with no threshold (W942's 48 prompts of 7,680 tokens fill most of an engine if copied everywhere, and B's 400 blocks evict by design); in-flight credit is reported separately and never counted as false. Named "credited prefix with no realized reuse", not a residency diagnosis. Unavailable if the EPP does not log per-endpoint matches | HOLDS / VIOLATED in A; descriptive elsewhere |
| C9 | failure cases | Every arm completes **every** offered request at 0.6 × in A, B and W942; any failure or timeout at any rate is listed with its cause | HOLDS / VIOLATED |

**Instrumentation validity, per cell** (separate from outcomes: an arm that fails, times out or overloads is a result and stays in every comparison; a cell is invalid only when the apparatus did not do what it says):
the ledger above holds; caching on and the configured `num_gpu_blocks` read back from `vllm:cache_config_info`; the arm's config hash and EPP binary sha256 equal the registered ones; every `/reset_prefix_cache` returned `success: true`; no engine had a running or waiting request when the cell started; dispatch lag p99 ≤ 10 ms; the schedule's hash equals the other arms' for that block, seed and rate; K's burst preconditions met (an unmet burst is invalid on its own, not the whole cell).
**Joins by lifecycle stage.** Every offered request is placed in the last stage it reached: offered, dispatched by the sender, received by Envoy, scheduled by the EPP, forwarded to an engine, completed. A request is joined to an EPP decision only if it reached the EPP's decision (a request rejected or cancelled before scheduling has none, and that is an outcome); the cell is invalid only if more than 0.5% of requests lack the evidence their own stage requires, that is, an unexplained missing record, never because an arm failed requests.
An invalid cell is reported with its cause and excluded, never rerun inside the budget; a criterion that loses a seed is decided on the remaining two only if they agree, and the outcome says it rests on two runs.

**What none of this can show:** anything about other profiles (the router's `test/perf` scorer set, the gist's, the precise producer), multiple EPP replicas (#4313's reservations are per EPP process), larger models, other GPUs, or more than four engines; and the simulator-to-GPU difference is not a single cause, since prefill cost under batching, the scorer set, tokenization, the router version and the TTFT clock all differ (next section).

## Comparability with the simulator results

| | thread (ptimizeroracle gist; lilong555 11-20; kuluruvineeth 10-27) | here |
|---|---|---|
| router | `3871ad02` (gist), `3d0b21d5` (lilong555 11-20), `b5cb5f8` (kuluruvineeth) | `733d0e4e`, 114 commits after `3871ad02`, including approximate-producer changes (#3938, #4360) |
| scheduling path | gist and lilong555: in-process (`Produce`, `profile.Run`, `PreRequest` called by the bench); kuluruvineeth: EPP behind Envoy | the real EPP behind Envoy over `ext_proc`, file discovery, its own metrics refresh |
| backends | llm-d-inference-sim: 8 pods × 8 slots (gist), 4 endpoints × 2 slots (kuluruvineeth); no batching slowdown | 4 vLLM 0.34.0 on A10G, 16 slots, real chunked prefill and continuous batching |
| profile | gist burst: queue, running, KV; gist steady: prefix 3, queue 2, running 2, KV 2; kuluruvineeth: the guide's optimized-baseline | the guide's optimized-baseline in A1 and A2, as kuluruvineeth |
| tokens | gist: FNV hashes of words passed as token IDs | Qwen2.5 token IDs passed as the prompt, counted by the engine |
| windows | gist A 30 s total, 25 s measured; B 40 s total, 30 s measured (the executable; the README says 30 and 40 measured) | the same as the executable |
| TTFT clock | ptimizeroracle: from the backend POST to the first SSE `data:` line, after routing; lilong555: from request entry, before routing | from the scheduled send to the first non-empty text event, before routing; after routing only a TTFB from Envoy, a different boundary from the gist's |
| burst prompt | gist: `"hello"` | 544-token cold prompts, so each burst request's prefill occupies its engine |
| rates | 20 req/s fixed (about 2.5 per pod) | a grid around A3's SLO knee; the thread's per-engine 2.5/s is reported if it falls in the grid |

The post compares **directions and mechanisms** (does the burst concentrate, does #4313 spread it, does it cost anything in steady affinity), not milliseconds, and does not call either result a replication.

## Pilot (one session, about $3; worst case $3.96)

One g5.12xlarge Spot session, the same kit in a pilot mode. It decides nothing about the arms; its time plan, with the same per-cell bounds as the main run:

| step | bound |
|---|---:|
| setup: venv and vLLM, Go and both EPP builds, Envoy, model download | 640 s (estimated; measured here) |
| engine starts, three configs | 3 × 120 = 360 s |
| `peakPrefillThroughput`: the calibration recipe's method, `CHUNK_SIZE` 2,048, first, under the A and K configuration | 240 s |
| isolated TTFT per block (A3, 20 cold with fresh prefixes and 20 warm): `SLO_A`, `SLO_B`, `SLO_W942`, C7's prefill rate, and the isolated prefill time of a 4,000-token preload | 150 s |
| A3 ramp, A: up to 4 rates, ×2 steps from the thread's per-engine 2.5/s (10, 20, 40, 80/s), stopping at the first failure; ×2 because the kit's offline run showed a ×1.5 ladder (10 to 33.75/s) can end without a failure, leaving the knee unbracketed | 4 × 65 = 260 s |
| A3 ramp, B: the same ladder | 4 × 75 = 300 s |
| A3 ramp, W942: 3 rates (1.75, 2.9 and 4.4/s), the full trace at each | 3 × 180 = 540 s |
| logging perturbation: A1 at `-v=2` and `-v=5` on A (one rate) and on K | 2 × 65 + 2 × 99 = 328 s |
| arm switching, joins and the ledger on real engines: A2 and A3 on A at one rate | 2 × 65 = 130 s |
| B pressure check: A1 at the lowest B rate, lost reuse against first fills | 75 s |
| total | 3,023 s of the kit's 3,300 s |

**Logging.** If `-v=5` raises the EPP's scheduling-duration p99 by more than 1 ms, or changes K's mean largest share by more than 4 of 64, on either block, the main run keeps `-v=2` in every cell; then C8, the per-request decision join and the concurrent-snapshot evidence (including K's burst-validity check, which then rests on Envoy's and the client's timestamps alone) are **unavailable** in the evaluated cells, and the post says so rather than borrowing them from other runs.

**Go / no-go for the main run:** every instrumentation check passes on real engines; both EPP binaries built and the merged tree hash recorded; `r_w` was bracketed for A, B and W942 (A3 failed at one tested rate and passed at a lower one); the measured setup plus each main session's cells at their bounds ends at least 120 s before the kit deadline.
If a knee is not bracketed, a second pilot is needed ($3.96 worst case) and is a separate spending decision.
If the setup is too long for the sessions below, the registered reduction is A3's removal (one third of every session's cells), not a shorter trace: W942's composition is the same at every rate and in every run.
The pilot's `SLO_w`, `r_w`, `peakPrefillThroughput`, timings, available telemetry and the geometry check are committed in a registration amendment before the first main session.
If #4313's head moves before the main run, the registered head `d44cd676` is still the one built, and the post names it.

## Cells, time and cost

The third revision replaces this section's grid anchor, K bursts and spacing, cell bounds, sessions and cost; it is kept as the design that was registered before the pilot.

**Cell count, main run: 123.**
A: 3 arms × 4 rates × 3 seeds = 36; B: 36; W942: 36; K: 3 arms × 3 seeds = 9; K-stagger and K-equal: A1 × 3 seeds = 3 each.
Pilot: 18 cells (ramps 11, logging 4, arm switching 2, B pressure 1), none in the criteria.

**Why cells are minutes, not run 2's 14.**
Experiment A's run 2 ran 12 cells in 2 h 49 min, about 14 min a cell (`2026-10-27-prefix-aware-routing-design.md` "Run 2"): two fresh engine Pods per cell on EKS (about 4 min) and a 600 s replay.
Here engines are not restarted between cells (a prefix-cache reset and a fresh EPP process take seconds), and the thread's own windows are 30 s (A) and 40 s (B).

**Per-cell bounds** (used for every cell, at every rate, not only the top one): 15 s of drain check, resets, EPP start and scrapes, the replay, and the whole-request timeout as the drain bound.

| block | bound |
|---|---:|
| A | 15 + 30 + 20 = 65 s |
| B | 15 + 40 + 20 = 75 s |
| K, K-equal | 15 + 6 bursts × (1 s preloads + 10 s timeout + 3 s preload cancellation and drain) = 99 s |
| K-stagger | 15 + 6 × (1 + 1.26 s release span + 10 + 3) = 107 s |
| W942 | 15 + 120 + 45 = 180 s (replay at most 120 s, at 0.6 × r_W942 if `r_W942 ≥ 2.9/s`) |

**Six main sessions, each one seed and one group, so every comparison is paired inside one instance:**

| session | contents | cells | bound (setup 640 s + engine starts + cells) |
|---|---|---:|---:|
| X1, X2, X3 (seeds 1, 2, 3) | A, K, K-stagger and K-equal (one engine config), then B (restart) | 12 + 3 + 1 + 1 + 12 = 29 | 640 + 120 + 780 + 297 + 107 + 99 + 120 + 900 = **3,063 s** |
| Y1, Y2, Y3 (seeds 941, 942, 943) | W942 | 12 | 640 + 120 + 2,160 = **2,920 s** |

Both end at least 120 s before the kit's 3,300 s with every cell at its bound, so no cell is skipped for time unless the setup overruns; if it does, the runner skips whole rate groups (all arms at one rate), never one arm, so a missing comparison never depends on an earlier arm's performance, and each skip is reported.
If `r_W942 < 2.9/s`, the W942 replay at 0.6 × exceeds 120 s and Y no longer fits; the amendment then drops the 0.6 × rate for W942 (and C6 moves to 0.9 ×) rather than changing the trace.
**Order inside a session:** the four rates in a fixed shuffled order registered per session, and at each rate the three arms in rotated order (A1 A2 A3, A2 A3 A1, A3 A1 A2, A1 A2 A3), the rotation offset by one per seed, so across the three seeds each arm takes each position four times per block.
K-stagger and K-equal run immediately after K's three arms, on the same instance, so the controls are paired with K.
Arms within a seed share an instance, so instance-to-instance speed differences cancel in every paired ratio.

**Cost.** The runner's own constants for g5.12xlarge: Spot cap $3.48/h, plus $0.0683/h for 120 GB gp3 at 500 MiB/s and 6,000 IOPS and a public IPv4, so $3.5483/h all in, billed at worst to the termination deadline of 4,020 s: **$3.9623 per session** (3.5483 × 4,020 / 3,600 = 3.96227), under the runner's $4.00 per-session cap, which it enforces before buying.

| | sessions | worst case | expected |
|---|---:|---:|---:|
| pilot | 1 | **$3.96** | about $3.0 (Spot was $3.27 to $3.48/h in ap-northeast-2 on 2026-11-19 to 21; about 3,300 s from launch to termination) |
| main run | 6 | **$23.77** (6 × 3.96227) | about $16 to $18 (about 3,000 to 3,300 s each) |
| total | 7 | **$27.74** (7 × 3.96227 = 27.736) | about $19 to $21 |

The worst case assumes EC2 confirms each termination by its deadline, as the runner states; one that does not is reported, and its billing past the deadline is not bounded by this design.
S3 for evidence and the Hugging Face download are not billed meaningfully; there is no EKS cluster and no NAT gateway.
A Spot reclaim keeps the records already checkpointed; rerunning a reclaimed session is a seventh main session ($3.96 more, $31.70 in all) and is a separate spending decision; nothing reruns automatically.
**If the budget must shrink:** drop A3 first (one third of every session's cells), then the 1.5 × rate.

## Offline rehearsal before the pilot

The whole kit runs on this machine first with llm-d-inference-sim in place of vLLM (same EPP binaries, Envoy, sender, ledger and scorer), with injected faults that must each fail visibly: a dropped request, a token count off by one, a missing EPP line, a reset that returns `success: false`, a schedule hash mismatch, a K burst released before its preconditions.
It also runs K under A1 and A2 on the simulator, released at once and 20 ms apart, so it is known before the pilot whether #4313 changes a simultaneous burst at all in the real EPP; that result is recorded and does not gate the purchase.
That rehearsal checks the apparatus only; no simulator number from it is reported as a result.

## What would be posted to #1598 afterwards

The shape, not the text; the text follows llm-d-router's contribution practice as read at the time it is posted.

1. One sentence of setup: 4 × A10G, vLLM 0.34.0 with prefix caching, Qwen2.5-3B, router `733d0e4e` EPP behind Envoy, the guide's optimized-baseline profile, three seeds; #4313 at `d44cd676`.
2. A table in the thread's layout, three rows (default, with #4313, round-robin): K largest share (even 16) with the six burst shares and K-stagger; A p95 / p99 and copies; B p50 / p95 and copies; so it lines up with the 11-14 table and with kuluruvineeth's first-turn counts.
3. GPU-only columns the simulator cannot give: highest passing tested rate at the SLO, goodput, the engines' reused-prefix fraction, credited prefix with no realized reuse, TTFT of first sights against repeats in W942.
4. "Reading" bullets: whether the default concentrates on real engines, whether #4313 spreads it and at what cost in steady affinity (the reason #1599 was closed), where the GPU direction agrees with the simulator's and where it does not; no "replicated" wording.
5. Caveats: the profile differs from the gist's, the scaling from 8 pods to 4 engines, the 16-slot cap, the router version gap, one EPP replica, three seeds.
6. A link to the raw rows, configs, schedule hashes and the kit in the gpuaas repository.
7. No PR, no `/assign`, no claim on the issue; the same data offered on #4313 as a short pointer if its author or the maintainers want it; an offer to run a maintainer-requested config through the same kit.

## Revisions

Each row is a defect in an earlier version of this page and what replaced it; the code-level ones were each checked against the cited source.

**First revision** (from `39a9a4bc`):

| was | why it was wrong | now |
|---|---|---|
| K's preload was 2,048 output tokens at `--max-model-len 2048` with `min_tokens = max_tokens` | vLLM clamps output to the remaining context and rejects `min_tokens > max_tokens` | preloads redesigned (see the second revision); per-burst preconditions, cancellation and refusal specified |
| the sessions' worst case gave the long drain to one rate only | with every cell at its bound the X session was 3,880 s, over the kit's 3,300 s | every cell budgeted at its bound with per-block timeouts; X 3,063 s, Y 2,920 s; skipping, if any, by whole rate group |
| simulator numbers were stated as predictions | the profile and scorer set differ from the gist's | "replication" language removed; the difference is in the comparability table; the gist's set is not an arm, because it has no `inflight-load-producer`, so #4313 would do nothing in it |
| B used 24 prefixes | 24 × 16 = 384 blocks fit in 400 when sprayed, so there was no pressure | 48 prefixes: sprayed 768 against 400, the simulator's own ratio of 1.92 |
| no evidence tied any concentration to concurrent scheduling | a client-side dispatch bound does not show overlap at the EPP | warmed connections, EPP-side overlap evidence, the K-stagger control; C1 split into a threshold and an attribution |
| prompts were text built with the model's tokenizer | with no `token-producer` the EPP estimates tokens by byte packing, and the approximate producer matches in blocks of at least 64 tokens | token-ID prompts; router credit in 64-token blocks, engine reuse in tokens |
| exact token reconciliation with exclusion of failing cells | a request cut off before its usage record advances engine counters, so the cells where an arm fails would be excluded | outcomes separated from instrumentation; a three-population ledger; exact identity only where no request failed |
| a low-verbosity fallback borrowed scores from separate diagnostic cells | another replay's scores are not the scores used for these requests | under the fallback C8 and the joins are declared unavailable; logging perturbation measured on K as well |
| A and W942 were "no eviction by construction" | private blocks were not counted, and `PreRequest` inserts optimistic entries, so zero reuse can occur with no eviction | in-flight and completed credit split; C8 gated in A only, renamed "credited prefix with no realized reuse" |
| cold calibration samples, "maximum sustainable rate", a shortened W942 phase 2 as fallback | later samples could be warm; a finite trace does not show stability; shortening changes W942's mix | a fresh prefix per sample; "highest passing tested rate", censored; the ramp ladder specified; W942's composition fixed at every rate |
| C7 compared the scheduler histogram with linear saved prefill, and called A3's overhead equal | the histogram times `Scheduler.Schedule` only; savings under batching are not linear; A3 runs no producer or scorer | scheduling and full routing path separate; saved prefill an estimate, not gated; A3's overhead stated as lower |
| C1 required 50% of a burst on one engine | the simulator's own MaxScore result was 45.9% | 24 of 64 (1.5 × even) with A3 beside it; all six burst shares published |
| A and B measured 30 and 40 s | the gist's executable measures 25 and 30 s (its window is the total) | the executable's windows |
| outcome words implied replication from two seeds of three | three runs are a voting rule, and random pickers are not seeded by the arrival seed | stated as descriptive; every paired effect published; picks recorded |
| checkpoints every 60 s | the runner archives, uploads for up to 60 s, then sleeps 60 s | about two minutes |

**Second revision** (from `8c837521`): the second arm changed.
Upstream #4313 ("Reserve at pick", "Fixes #1598", opened 2026-11-17) is cross-referenced from the issue's timeline and not mentioned in its comments, which the first version had read.
It is the upstream reservation candidate, so it replaced `weighted-random-picker` as A2; because it acts only through `inflight-load-producer`, A1 moved from the router's `test/perf` scorer profile to the guide's `optimized-baseline`, and C2 and C3 were rewritten around #4313's claim and #1599's failure mode.

| was | why it was wrong | now |
|---|---|---|
| K's preloads were long decoding requests | `token-load-scorer` reads in-flight tokens, which `inflight-load-producer` frees at prefill completion (`inflightload/kvevents.go` `onPrefillComplete`), so a decoding request is invisible to it | 4,000-token preloads with one output token, still in prefill when the burst is scored; a burst is valid only if every request was scored before any preload's first token; K-equal added |
| #4313's test was quoted as closing the race | it releases its 64 goroutines 250 µs apart and its baseline never calls `PreRequest` | #4313 described as narrowing the window, closure under test; the offline rehearsal runs both arms on the simulator, recorded, not gating |
| scores and matches at `-v=4`, reservation times from the log | prefix matches log at TRACE (level 5), and #4313 logs nothing when it reserves | `-v=5`, perturbation tested at `-v=5`; reservation timing unavailable; no instrumentation added |
| the gist's after-routing TTFT from Envoy | Envoy's upstream timing ends at the first byte, a different boundary | named TTFB; first event and first non-empty text recorded separately |
| B's pressure inferred from A3's lower hit fraction | compulsory first fills alone give that with any cache size | first fills and lost reuse separated; B counts as cache pressure only if A1 shows ≥ 1% lost reuse |
| K at 105 s | the precondition wait and the stagger span were not budgeted | 99 s and 107 s; X 3,063 s |
| a 99.5% decision join for every row | a request rejected before scheduling has no decision, legitimately | joins by lifecycle stage; only unexplained missing evidence invalidates |
| ratios of percentiles that can be ∞ | ∞ ≤ 0.90 × ∞ would read as an improvement | explicit both-∞, finite-against-∞ and empty cases |
| calibration at 4,096 tokens under `--max-model-len 2048` | vLLM rejects it | `CHUNK_SIZE` 2,048 under the A and K configuration (now 4,096 tokens), first in the pilot |
| K's prompts unqualified against the gist's; prompts possibly reused across bursts | the gist's burst sends `"hello"`; a reused prompt warms a later burst | in the comparability table; all 384 prompts of a cell have distinct first router blocks |
| TPOT over `completion_tokens − 1` for every request | undefined for one-token outputs | defined for ≥ 2 tokens, labelled client TPOT |
| 16 slots as equal capacity | equal sequence counts do not make continuously batched capacity equal | an intentional cap; occupancy and waiting reported |

**Third revision: main-run design after the pilot** (from `b02c9e31`, the pilot's evidence, `hack/gpu-kit-runs/2026-11-21-llmd-1598-pilot`).
It keeps the arms, the workloads' prompt shapes and the hypotheses.
It is not untouched pre-registration: it was written after the pilot's data had been seen, and the anchor rule below changes where C3 and C4 are compared.
Where its first draft proposed changing C2 and C3, the owner's dated amendment that follows it ("Fourth revision") decides instead, and the rows here say so.
Every figure in this revision was recomputed from the pilot's `rows.jsonl`, `samples.jsonl`, `cell.json`, engine logs and the off-tree EPP log of `log-K-A1-v5`.

*What the pilot showed.* The apparatus held (ledger, joins, sampler, credit join, dispatch lag p99 ≤ 7.6 ms in every cell), and none of the effects the main run measures showed:

| signal | measured | why it did not show |
|---|---|---|
| K concentration under A1 | largest shares 21, 21, 22, 21, 22, 22 at `-v=2` (mean 21.5); 19, 29, 26, 30, 20, 18 at `-v=5` (mean 23.7); threshold 24 | The `-v=2` shares sit at two descriptive references: the static fluid allocation, (3 × 4,000 + 64 × 544) / 4 / 544 = **21.51** of 64, and a sequential least-token allocator with no completions, which gives **[22, 14, 14, 14]**. That is consistent with picks seeing each other, but neither number detects a race: a race-free allocator already exceeds the fluid figure, and completions during a burst change the load both assume. The client's thread sends spread each burst over **5.7 to 7.5 ms** (median gap 0.06 ms), the region where the thread's simulator still kept the effect (5 ms). At `-v=5` the picks spread over 31 to 39 ms, 57 to 62 of each burst's 64 picks happened while an earlier pick had not reached `PreRequest` (at most 10 to 16 at once), and the larger shares coincided with that; logging slowed the scheduler there, so `-v=5` is not the default's behaviour |
| B cache pressure under A1 | A1 at 10/s: 6 first fills, **0 lost reuse** of 312; 12 to 14 prefixes an engine, at most 224 of 400 blocks | The working set fits under affinity (48 × 16 / 4 = 192 blocks an engine, 0.48 of the 400) and the check ran at 10/s, below any main grid rate (0.6 × r_B ≥ 48/s), with 0.5 to 0.7 requests running an engine. Pressure itself exists: A3's spray lost reuse on **28.2%** of requests at 10/s and **57.1%** at 80/s |
| A and B knees | A3 passed 10, 20, 40, 80/s on both; at 80/s A's p99 was 64.4 ms against a 230 ms SLO with 5.3 to 5.7 of 16 slots running and nothing waiting; B's p99 136.4 ms against 160 ms with 8.2 to 8.7 running | The ladder stopped at 80/s. A's requests reuse 512 of 544 tokens, so each engine prefills 32 tokens a request; capacity is the decode slots, far above 80/s |
| the grid anchor | **A1 and A2 put all of A's requests on two of the four engines** (869 and 872 evaluation rows of 1,741 at 72/s; the engines' counters show 1,043 and 1,044 requests with warm-up on two engines and none on the others, against 522, 522, 522, 521 under A3), with 10.6 of 16 slots running, up to 12 waiting, and 95.98% within the SLO: A1's knee in A is about 72 to 80/s, an estimate until P2 brackets it | This is the default profile's `prefix-cache-affinity-filter` doing what it is configured to do with a two-prefix workload: in both A1 and A2 the EPP's own counters show 2 `no_match` and **2,085 `sticky`** decisions and **6,255 eliminated candidates, exactly three per sticky decision**, so the filter left one candidate before scoring every time a prefix had been seen. It is not the concurrent-pick race #1598 is about, and nothing here suggests #4313, which acts after the filter, should change it. A3 spreads the same requests over four engines, so its knee is about twice A1's (36/s an engine in both cases), near 150/s. A grid of 0.6 to 1.5 × A3's knee would put every rate above A1's and A2's knee: C3's "normal operation" would compare two overloaded arms and C4 would be censored below for both |
| sender | peak outstanding 44 (A, 80/s) and 65 (B, 80/s) against the 256-worker pool; achieved rate equal to the schedule | Not capped here, but at 1.5 × a knee near 120/s with 20 s timeouts an overloaded arm holds up to about 3,600 requests, and the pool would have delayed sends |
| p99 sample sizes | A 1,741 to 1,993 rows a cell (17 to 20 above the p99 rank); K 384 (3); W942 223 (2) | K's and W942's p99 sit two or three requests from the top. Even A's rows above its p99 are not independent: in A1's and A2's cells, 14 of the 18 rows at or above p99 fell in the same second of the run |
| W942 bound | `223 / (0.6 × 2.9) = 128.2 s` of replay at 0.6 ×; seeds 941 and 943 have 207 and 197 requests | the "at most 120 s" bound was wrong for seed 942 |
| TTFT | 9 completed evaluation rows (≤ 2 output tokens) whose tokens decoded to no text read TTFT = ∞ | the first token's event was not recorded when its text was empty |
| logging | `-v=5` raised K's EPP scheduling p99 bucket from 1 ms to 50 ms (and client p99 from 1.44 to 1.94 s) | the registered rule keeps **`-v=2` in every main cell**: C8, the per-request decision join and EPP-log attribution are unavailable, as already registered |

Measured times: setup 67 s (registered bound 640 s), engine starts 93, 62 and 60 s, A cells 42.5 s (bound 65), B 52 s (75), K 30 to 31 s for six bursts (99), W942 65 to 142 s; launch to confirmed termination 33 min.

*The changes.*

| was | why it was wrong or weak | now |
|---|---|---|
| a main run right after the pilot | A and B were not bracketed, which the go/no-go above already sends to a second pilot | **a second pilot, P2** (STAGE=pilot2, implemented): A1 and A3 each climb 64, 80, 100, 125, 156, 195, 244/s on A and on B, stopping at their first failure; A1 climbs 1.75, 2.9, 4.4/s on W942 (A3's W942 knee, 2.9/s, is the pilot's); K, K-equal and K-stagger under A1 with the release below; all at `-v=2`, on seeds 4 and 944, which the main run does not use. P2's verdict exits 0 only with an anchor for every block and at least one valid K and one valid K-equal burst; otherwise 3 (incomplete), and 4 if an apparatus check failed |
| `r_w` = A3's knee | see "the grid anchor" above | **`r_w` = the lowest bracketed knee among A1 and A3** (P2's ramps; W942 adds the pilot's A3 2.9/s). An arm censored above at a rate at or over the other's bracketed knee cannot be the minimum; an arm that failed its lowest rate, or two censored arms, give no anchor, and the main run is not bought. A3's highest passing rate may then be censored at "≥ 1.5 ×", which still reports how much more round-robin carries in A |
| K's 64 requests sent by 64 threads | 5.7 to 7.5 ms of spread, not "released at once" | **primed release**: each request is written whole except its body's last byte, then the preloads go out, then one thread writes the 64 last bytes; the EPP cannot pick before it has the whole body, so the scheduler receives the burst within that loop (median 0.55 ms over ten 64-request bursts on the loaded development host, 0.42 to 3.48 ms). A burst counts only if its 64 last bytes left within **2 ms** and no request was decided (Envoy forward time, at `-v=2`) before the write of its own last byte began (Envoy can forward during that write, before the client reads its clock); a cell whose primed release fails on more than 10% of bursts, or decides anything early, fails the apparatus |
| 6 bursts a K cell | 384 rows a cell; a p99 three rows deep | **12 bursts** (768 rows a cell, 2,304 an arm over three seeds, 23 rows above the p99 rank; twelve shares a seed for C1 and C2). Sixteen would not fit session X at its bounds |
| C1's 24-of-64 threshold read alone | a race-free picker already gives the idle engine 21.5 to 22 | threshold unchanged; two **descriptive** references are reported beside it, the static fluid allocation (21.51; 16 in K-equal) and the sequential least-token allocation ([22, 14, 14, 14]); neither is a race detector, and at `-v=2` mechanism attribution stays unavailable, as registered |
| C2's K part: A2 ≤ 0.75 × A1 | a first draft of this revision proposed restating it as excess over 21.5 | **kept as registered**; the fourth revision adds paired-burst rules and a burst performance guardrail |
| K-stagger 20 ms apart | 63 × 20 ms = 1.26 s, while the pilot's preloads produced their first event about 0.26 to 0.30 s after the burst's decisions: every request after the first ~15 would see no least-loaded engine, so no K-stagger burst could be valid | **4 ms** spacing (63 × 4 ms = 252 ms), run in P2 as a **feasibility probe** under frozen rules (fourth revision); it is a dynamic spacing intervention, never an oracle for whether a race is present |
| K-equal's bursts held to the preload conditions | K-equal has no preloads, so every one of its bursts would have been invalid | release conditions only |
| B's geometry check at 10/s, once | below every grid rate | geometry unchanged (the thread's 48 prefixes and 400 blocks). P2 reports A1's lost reuse at every rate it climbs, and the main run decides "B tests cache pressure for A1" **per seed at 0.6 × and 0.9 ×** from A1's own cells (≥ 1% lost reuse), the rates where C3 is judged; where it does not, C3's B part is reported as steady affinity, as already registered. A3's lost reuse is reported in every B cell |
| p95 decides C3, p99 beside it | the owner asked for p99 first | **p95 C3 stays the mandatory criterion.** p99 is added as a separate guardrail and every table reports it first, with its row count, its rank, the rows above it, and an **iid-reference interval** (the order statistics [x_(l), x_(u)] with P(l ≤ Binomial(n, 0.99) ≤ u − 1) ≥ 0.95), which would be a 95% interval only for independent rows and is not one here. No p99 is called precise or decided; the paired effect per session is what is read (fourth revision). W942 keeps its registered statistics: p95 for C2 and C5, p50 for C6 |
| one W942 trace per arm, seed and rate | a p99 two rows deep | each Y session may also replay the A1 and A2 traces at 0.9 × and 1.2 × under the balanced replay rule of the fourth revision (same schedule, reset between). The criteria use the first trace only, so a replay can never change an outcome word; replays are reported per seed and per replay and never counted as independent samples |
| fixed 256 sender workers; origin set before the connections opened | an overloaded cell would have been sent late, and the dispatch-lag rule would have voided the very cells that bracket a knee | workers = the most requests scheduled in any (timeout + 5 s) span, refused above 8,192, with the open-file limit raised to its hard limit for them and for Envoy; the origin is set after every connection and worker is ready |
| the socket timeout as the "whole-request timeout" | it bounds each read, so a request still streaming could outlive 20 s and the cell bounds | an absolute deadline per request (20 s A and B, 10 s K, 45 s W942), cut off and recorded as a timeout |
| TTFT finite for a request that failed after its first token; ∞ for a completed request whose tokens decoded to no text | the registered rule is "a failed request has TTFT = ∞"; and the first token's event is the first token | TTFT = ∞ unless the request completed; otherwise the first non-empty text event, or the first event carrying a choice when no text came |
| `peakPrefillThroughput` and the SLOs measured per session | A1's and A2's config bytes, and the SLOs, would differ between sessions | fixed by this amendment: **8,869 tokens/s, SLO_A 230 ms, SLO_B 160 ms, SLO_W942 3.05 s** |
| per-cell bounds from the design's constants | W942 at 0.6 × runs 128 s | each cell's bound is 15 s + its own schedule's span + its timeout (K: 15 + 12 × (14 s + the stagger's 63 gaps)) |

*Rows behind each p99.* The fourth revision's schedule-count table gives the exact evaluation rows per seed and rate; these rows are requests within a cell, not independent samples, and the three seeds remain the independent unit.

| block | rows a cell | how the p99 is reported |
|---|---|---|
| A, B at the grid rates | see the schedule-count table (about 900 to 5,700) | per seed, first, with n, rank, rows above it and the iid-reference interval; paired session effects A2 / A1 |
| K, K-equal, K-stagger | 768 | per seed and per arm; the burst guardrail uses it |
| W942 | 197 to 223 a trace | per seed and per replay; never pooled into a sample size |

*Sessions, in order, one at a time* (the 48-vCPU Spot quota is one g5.12xlarge; each session's termination is confirmed before the next is requested).
Bounds use setup 300 s (measured 67 s), engine starts 120 s (measured 60 to 93 s), every cell at its bound, inside `BUDGET_S` 3,250 less 60 s.

| session | contents | bound | expected kit time |
|---|---|---:|---:|
| P2 | A's ramps, K, K-equal and K-stagger under A1, W942's ramp, then B's ramps (the ladder with the least known knee last) | 3,607 s if no rung ever fails, which leaves no anchor anyway (late cells are skipped and recorded); about 2,980 s when A1 stops at 100/s and A3 at 195/s on A and each stops after five rungs on B | about 1,750 s |
| X1, X2, X3 (seeds 1, 2, 3) | A (12 cells), K (3 arms), K-equal, K-stagger, then B (12 cells) | 300 + 120 + 780 + 549 + 183 + 186 + 120 + 900 = **3,138 s** | about 1,850 s |
| Y1, Y2, Y3 (seeds 941, 942, 943) | W942's 12 cells, then the balanced A1 and A2 replays | 2,852 s (941), **2,957 s** (942), about 2,800 s (943) at r_W942 = 2.9/s with two replays at 0.9 × and one at 1.2 × | about 2,000 s |

If P2's W942 anchor is below 2.9/s, the Y traces stretch: the replays are cut first (the registered criteria do not use them), then the amendment drops W942's 0.6 × rate as already registered.

| | sessions | worst case | expected |
|---|---:|---:|---:|
| P2 | 1 | **$3.96** | about $2.3 (about 38 min launch to termination: 100 s bring-up, the kit, about 7 min of upload and termination as in the pilot) |
| main run | 6 | **$23.77** (6 × $3.9623) | about $15 (X about $2.4 each, Y about $2.5 each) |
| from now | 7 | **$27.74** | about $17 |

Each session's worst case is the runner's $3.9623 (the $3.48/h cap plus $0.0683/h, billed to the 4,020 s termination deadline), under its $4.00 cap; the main run's worst case stays the $23.77 estimated before the pilot, and P2 is the separate spending decision the go/no-go already named.
Spending already made: the pilot, $1.95.

*Rejected alternatives.*

| alternative | why not |
|---|---|
| B with 128 prefixes, so that even perfect affinity overflows 400 blocks (512 blocks an engine) and A1 must show pressure | It makes B a different workload from the thread's B (48 prefixes), which is what B is compared with; B already measures what the thread's B measured (spray under pressure, affinity within capacity). Pressure for A1, if it comes, comes from spill at high rates (#4042), and the per-rate check records it |
| making K show by raising the EPP's verbosity, pinning the EPP to fewer cores or growing the burst and rescaling 24 of 64 | each changes the system or the registered test; in the pilot, larger shares came with `-v=5`'s slower picks, which is not the default's behaviour |
| keeping the A3-only anchor | C3 and C4 would compare two overloaded arms in A, and C4 would be censored below for both |
| an x1.5 A3 ladder to 640/s | about twice as many cells above the predicted knee near 150/s; the x1.25 ladder to 244/s covers 1.6 × that prediction |
| 24 K bursts for A1 and A2 and 6 for the others | unequal sample sizes across arms in the same comparison; K's TTFT is not in any criterion, and 2,304 pooled rows already put 23 rows above its p99 |
| a fourth W942 session with four more traces per seed for A1 and A2 | puts the main run's worst case at $27.74 (from now $31.70), over the $24 estimate, for replays of the same traces, which are not independent; deferred with the default "do not add" (fourth revision) |
| shortening W942's phase 2, or time-scaling K | changes the workload's composition, which the design fixed |

*Kit status.* P2 is implemented (`run.sh` STAGE=pilot2, `pilot.py run_pilot2`, `verdict.py main_pilot2`) with the primed release, the sender and TTFT fixes, the anchor rule, the percentile reporting, the release checks, and the fourth revision's paired-burst, guardrail, stagger and replay rules, each under unit tests and mutants, and P2 runs end to end offline against the real EPP and Envoy with fake engines.
The main sessions X and Y, and the criteria judge, are written after P2, from P2's registered grid; their judge must also check what the pilot's verdict did not: every arm's schedule hash equal for a block, seed and rate, the EPP binary and config hashes against the registered ones, and K-stagger's validity per burst.

**Fourth revision: the owner's prospective amendment, 2026-11-22** (owner's decision recorded as 「권장안대로 진행」, after two independent reviews of the third revision's proposals; made before P2, before any main-run cell).
It amends the registration; it is not pre-registration untouched by data.
Evidence already inspected when it was made: the whole first pilot, including A1 against A2 on A at 72/s (the same schedule: p95 218.8 and 218.1 ms, p99 287.9 and 285.4 ms, `-v=2` against `-v=5`; at matched `-v=5`, p95 217.9 and 218.1 ms and p99 283.6 and 285.4 ms) and K under A1 only, and the primed-release change, which alters K's stimulus after a null result.

| item | registered before | now |
|---|---|---|
| C1 | A1's mean largest share ≥ 24 of 64 in 2 of 3 seeds | unchanged. The fluid (21.51) and sequential ([22, 14, 14, 14]) references are published beside it as description only |
| C2, K part | A2's mean largest share ≤ 0.75 × A1's, paired, 2 of 3 seeds | **unchanged formula**, now read on **identical burst IDs**: a burst leaves both arms only for an apparatus reason (release spread over the registered span, a decision before release, a missing record), with every exclusion and its reason published; a burst invalid for any other reason (preload placement or timing the arm produced) or with a failed request stays in as a **failure of that arm**, and a seed where A2 has more such failures than A1 fails C2. A seed's contrast is read only if at least **75%** of its 12 bursts are usable in both arms (frozen); otherwise it is unavailable. All three seeds' paired contrasts are published, including seeds where A1 is below 24 |
| burst performance guardrail (new) | none: K's latency was in no criterion | before any reading of "A2 spreads the burst better", A2's pooled burst TTFT p95 and its median burst makespan (last byte released to the last response's end, so any reservation work is inside it) must each be ≤ **1.10 ×** A1's on the same paired bursts, with every request completed; otherwise the outcome is reported as "share lower, guardrail failed" |
| K-stagger | 20 ms apart, a mechanism control | **4 ms**, a feasibility probe in P2 only. Frozen before P2: a burst's gaps are acceptable when the smallest is ≥ 0.5 × 4 ms and the median within 3.6 to 4.4 ms; a preload counts as load only until the earlier of Envoy's upstream first byte and the client's first event; K-stagger is usable in the main run only if ≥ 90% of its bursts have acceptable gaps, ≥ 75% are valid, and in ≥ 95% of consecutive pairs Envoy forwarded the earlier request before the later one's last byte began. If usable it is read as a dynamic spacing intervention (load changes while it runs: the pilot's fastest burst request produced text 81 ms after its scheduled release, well inside 252 ms), never as evidence that a race is present or absent |
| C3 | A2's TTFT p95 ≤ 1.20 × A1's and reused fraction ≥ A1's − 0.05, paired, 2 of 3 seeds, in A and B at 0.6 × and 0.9 × | **unchanged and mandatory.** A p99 guardrail is added beside it (A2's p99 ≤ 1.20 × A1's, same pairing), reported first, with each cell's row count and an iid-reference interval; it can flag a tail C3 does not see but never replaces C3: a constructed case of 1,000 rows (A1 980 at 100 ms and 20 at 1 s; A2 940 at 100 ms, 40 at 200 ms and 20 at 1 s) has equal p99s while p95 doubles from 100 to 200 ms |
| C6 | first sights' TTFT **p50** at 0.6 × | unchanged; the third revision's text calling it p95 was wrong |
| W942 fourth session | none | **deferred, default "do not add"**. It is added only if, after P2 fixes the anchor and before any main cell, the owner raises the budget above the main run's $23.77 worst case and the three Y sessions cannot hold the balanced replay set below. Replays are taken in balanced units only (one more A1 and A2 trace at one rate, for every seed), in the order 0.9 ×, 0.9 ×, 1.2 ×, stopping at the first unit that does not fit every seed's session at its bounds; they are reported per seed and per replay, never as an independent sample size |
| P2's seeds | the first pilot used A, B and K seed 1 and W942 seed 942, which the main run also uses | P2 uses seeds 4 and 944, so P2 sees no main schedule; the first pilot's overlap with seed 1 (A, B and K prompts) and seed 942 (the W942 trace) remains and is disclosed |

*Schedule counts.* Evaluation rows per seed (1, 2, 3) at each grid rate, from the kit's own Poisson schedules; the real table is regenerated from P2's anchor and committed before session X1.

| block, anchor | 0.6 × | 0.9 × | 1.2 × | 1.5 × |
|---|---|---|---|---|
| A, r_A = 64/s | 913, 954, 958 | 1,480, 1,426, 1,434 | 1,885, 2,044, 1,895 | 2,339, 2,452, 2,369 |
| A, r_A = 80/s | 1,136, 1,194, 1,250 | 1,741, 1,856, 1,868 | 2,339, 2,452, 2,369 | 3,086, 2,980, 3,065 |
| B, r_B = 100/s | 1,816, 1,806, 1,795 | 2,646, 2,759, 2,745 | 3,588, 3,645, 3,616 | 4,464, 4,557, 4,539 |
| B, r_B = 125/s | 2,250, 2,181, 2,207 | 3,339, 3,373, 3,363 | 4,464, 4,557, 4,539 | 5,685, 5,634, 5,561 |
| W942 (every rate) | 207 (941), 223 (942), 197 (943) a trace | | | |

*What the answer can be.* Four questions are kept apart and answered separately: whether concentration **reproduces** at the registered threshold (C1), whether A2 changes the **distribution** (C2), whether it changes **performance** (the guardrail, C3 to C9), and whether any change is **attributable** to concurrent picks (unavailable at `-v=2`, as registered).
"Not reproduced under this apparatus" is an acceptable final answer, and the post would say so; it is neither proof that no race exists nor evidence that A2 fixed anything.
The issue's RL-cycle and saturation-recovery scenarios are out of scope: K drains before each burst and sends distinct cold prompts, A and B are Poisson, W942 releases pairs and then repeats.
A separately labelled diagnostic with `prefix-cache-affinity-filter` removed could confirm the two-engine placement's cause; it is not in the plan, and the registered default arm is unchanged.

*Rejected in this amendment.* C2 as excess over 21.5 (at A1 = 24 it relaxed the bound from 18 to 23.38, a 0.62-request difference, and gating it on C1 per seed selects on the baseline's own fluctuation); replacing p95 with p99 in C3 (the constructed case above passes it while p95 doubles); calling 10 rows above the p99 rank "decided" (rows in a cell are dependent); a mechanism reading of K-stagger.
