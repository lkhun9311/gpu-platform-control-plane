# A real-GPU A/B for llm-d-router #1598, bursty request distribution

Date: 2026-11-21. Status: **design, reviewed once (codex `gpt-6-astra`, "Review" at the end); nothing bought, nothing posted upstream.**
Approval: the owner approved the experiment and its budget on 2026-11-21 (pilot about $3, main run about $20 to $24).
This page fixes the arms, workloads, apparatus, measurements, pre-registered criteria and cost before any harness code is written.
The harness is built in a follow-up, from this page.

## Why this experiment, and what it adds to the thread

- llm-d/llm-d-router#1598 (opened 2026-06-11 by elevran, assigned to elevran and ezrasilvera) asks for better distribution when many requests are scheduled concurrently against the same observed state.
  elevran wrote on 2026-10-12: "Need to confirm if still an issue - will close if not reproduced".
- Everything posted since is unit-level or simulator-only:
  ishwar170695 (picker simulation, 10-14; #1599 probes, 11-08), ptimizeroracle (in-process bench with llm-d-inference-sim, 10-14, 11-11, 11-14, gist 11-16), kuluruvineeth (4 simulated endpoints behind Envoy, 10-27), lilong555 (simulator, 11-13 and 11-20).
  ptimizeroracle's own caveat (11-14): "the sim does not slow prefill under batching".
- **No one has posted a run on real vLLM with real prefix caching on GPUs.** That is the contribution: data and analysis on the thread's own workloads, not a scheduler change and not taking over the issue.
- gpuaas has its own reason to run it. Experiment A's prefix-routing tail (`shared-942`) came from front-loaded first-sight prompts placed on one least-loaded backend (`docs/superpowers/specs/2026-11-21-routing-l3-notmet-rootcause.md` on branch `feat/routing-l3`, commit `1d781e96`).
  The L3 strategy review (`storage/open-source/policy/inference-strategy-review-2026-11-21.md`) adopts the "A table" criteria used below.
- Correction carried into the design: `shared-942`'s first sights were **not** a concurrent burst.
  Its 25 arrivals in the first 20 s were 39 ms apart at the closest and 648 ms at the median (recomputed from `hack/prefix-route/2026-10-28-run2/.../shared-942-RoundRobin/trace.jsonl`), far outside the few-millisecond window ptimizeroracle measured (10-14: 20 ms spacing removes the effect, 5 ms does not).
  So the gpuaas tail and #1598 share a symptom (cold work piled on one backend) and not necessarily a mechanism; the workloads below separate the two, and a staggered control (K-stagger) tests whether any concentration is the concurrent-snapshot mechanism.

**What this is and is not.** It is a measurement of the router's current default approximate profile, a spreading picker and round-robin on real engines, using the thread's workload shapes.
It is **not** a replication of the simulator experiments: the scorer set, router version, backend and scale differ (see "Comparability"), so the post compares directions and mechanisms, and says where they agree or disagree, without calling either result a replication.

## Related open items checked (2026-11-21)

| item | what it is | bearing here |
|---|---|---|
| #3245 (open) | `prefix-cache-affinity-filter`'s TTFT gate cannot release a decode hotspot: 96 of 96 requests to one endpoint | affinity against load in the guide profile; not an arm here (see "Arms") |
| #4042 (open) | `load_override` cascading overload; sohom-cs is taking bounded spillover | ptimizeroracle (11-14): "a spill rule that charges the re-prefill (the #3514 / #4042 direction) looks like a better place for that than randomizing in the picker"; workload B is where that trade-off shows |
| #3421 (open PR) | queue-wait term in the affinity filter's TTFT estimate; stacked on #3514 (merged 11-11) | lilong555 proposed it as a separate comparison and did not run it; it needs the filter profile, out of scope |
| #3503, #3574, #4328, #4040 (open), PRs #3504, #3588, #4400 | stale or wrong residency in the precise index | the approximate producer used here has its own staleness (it never sees engine evictions); measured below as credited prefix with no realized reuse, not claimed as a defect |
| #4354 (open, assigned), #4331 (open, assigned) | KV event lag; speculative indexing past the engine block | precise-producer issues; this design uses the approximate producer |
| #1727 (merged 2026-07-06) | `burst-prefix-cache-producer`: a windowed joint assignment for prompt-sharing bursts (RL group samples) | not mentioned in the #1598 thread; it groups **identical** prompts only (with `minColocateBlocks: 0`), and a request that overlaps no other "receives no affinity", so it does nothing for a burst of distinct first sights. Recorded, not an arm |

## Arms (three)

All arms run the same EPP binary, built from **llm-d-router `main` at `733d0e4ee18082d2e252fc887db7701c037b8034`** (2026-11-20T22:52Z), in file-discovery mode behind Envoy (`docs/discovery.md` "Running EPP with file discovery (no Kubernetes)").
Only the `EndpointPickerConfig` changes between arms.

| arm | config | why |
|---|---|---|
| **A1 default** | the router's own `test/perf/config/router-configs/optimized-baseline.yaml` profile at the pinned SHA: `approx-prefix-cache-producer` (`maxPrefixTokensToMatch: 100000`), `prefix-cache-scorer` 3, `queue-scorer` 2, `kv-cache-utilization-scorer` 2, `no-hit-lru-scorer` 2, default `max-score-picker` | the router's approximate prefix profile with load scorers, as the owner specified; it differs from the gist's scorer set (no `running-requests` scorer; adds `no-hit-lru-scorer`, which ranks endpoints for cold requests and updates that rank in `PreRequest`, so concurrent cold picks can share one preferred endpoint) |
| **A2 weighted** | A1 with `weighted-random-picker` in place of the default picker; nothing else changes | the candidate (below) |
| **A3 round-robin** | `max-score-picker` with no scorers and no producer | every score ties, and `RotateScoredEndpoints` with a mutex-guarded per-pool counter (`picker/common.go` `NextCounter`) gives strict rotation even under concurrent picks; it shares the transport (Envoy, `ext_proc`, the EPP process) but not the producer and scorer work, so its routing overhead is lower and is reported, not assumed equal |

**The reservation/cost prototype is not an arm.**
lilong555's prototype is public, but as a source overlay inside an evidence repository (`lilong555/scheduler-feedback-evidence-20261112`, `sources/llmd/{performance,lifecycle}/.../picker/reservations/`, commits `6a8cc65d` and `8ead7cb9`), not as a router branch; lilong555 has no llm-d-router fork.
Its own write-up says "production YAML registration and discovery/eviction integration remain implementation work": the adapter is instantiated by the author's harness, so running it in a real EPP means writing that integration ourselves.
Its service model assumes a fixed worker slot from prefill to decode ("matching the queue structure used by the cost estimate"), which vLLM's continuous batching does not have.
And its author measured it regressing on every seed of workloads A and B on 2026-11-20: TTFT p95 2,939 ms (A) and 1,849 ms (B) against MaxScore's 40 and 40 ms, because "an occupied slot's predicted completion can expire".
A GPU run of a prototype its author has withdrawn on these workloads would add little, and would make gpuaas the author of its integration.

**So A2 is the closest upstream candidate in the thread: `weighted-random-picker`.**
It is the only burst-spreading candidate in the thread that exists on upstream `main` with no code change (p2c, the in-flight-count-only profile and "#1599 with a wall-clock window and no capacity factor" are bench ports or patches of a closed PR).
It is in every simulator table (ptimizeroracle 10-14, 11-11, 11-14; lilong555 11-13, 11-20).
In the simulator it spread bursts (k=128: 23.5 against MaxScore's 58.7, even 16) and paid in affinity under cache pressure (B p95 298 ms against 44 ms; 6.6 prefix copies against 1.1); those numbers are the simulator's, under its scorer set, and are what the GPU directions are compared with, not predictions of this experiment's values.
Its random source is seeded from wall-clock time (`picker/common.go` `newLockedRand`), so its picks are not reproducible from the arrival seed; each A2 cell records every pick.
"#1599 with the window fix and no capacity factor" was the only simulator row reasonable in all three columns; it is the fourth arm this budget drops, because it is not upstream code.

**Profiles not run, and why.**
The llm-d guide's current `optimized-baseline` (llm-d `d83e85c37c0d`: `approx-prefix-cache-producer`, `inflight-load-producer`, `prefix-cache-affinity-filter`, `token-load-scorer`) is the profile kuluruvineeth measured (12 of 16 first turns on one endpoint) and the one #3245, #4042 and #3421 change.
It is a different question (filter-first affinity with a TTFT gate) that needs its `peakPrefillThroughput` calibrated for this hardware.
The gist's own scorer set (prefix 3, queue 2, running 2, KV 2) would make the burst and steady columns closer to the simulator's; it is not a router default, and the owner asked for the default.
The precise profile needs a tokenizer sidecar and KV events; the thread's numbers all use the approximate producer.
Each would be a fourth arm.

**If cost forces two arms, A3 goes.**
The thread's question is A1 against A2; A3 is the null for burst shares (exactly even by construction) and the load-oblivious reference.
Without it the rate grid is anchored on A1 in the pilot, and C1 compares against the even share 16 instead of A3's measured shares.

## Workloads (five blocks)

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
| **K** | the thread's burst column | 64 distinct cold prompts of 544 tokens (no shared prefix), released at once; 6 bursts per cell | before each burst, engines 1 to 3 each hold exactly one long-running request sent directly to the engine, engine 0 holds none (ptimizeroracle's "every pod but pod0 holding one running request") | as A | each burst |
| **K-stagger** | control for K | K's prompts, the same preloads | each burst's 64 requests released **20 ms apart** (ptimizeroracle 10-14: 20 ms spacing removed the concentration in the simulator) | as A | each burst |
| **W942** | gpuaas `shared-942` | one of **48** system prompts of 7,680 tokens + a 256-token unique suffix, 64 output tokens | phase 1: `shared-942`'s 25 arrival offsets in its first 20 s, each arrival released as **two** simultaneous distinct requests (48 first sights + 2 repeats); phase 2: Poisson repeats of those 48 prompts at 1.6/s for 100 s; seeds 941, 942, 943 draw the prompt texts and phase 2 | vLLM's default sizing (about 393k tokens each, from experiment A's `cache_config_info`; read back per cell) | the whole trace, no warm-up |

**Scaling from 8 simulated pods to 4 engines.**
- A keeps the prefix-to-endpoint ratio that produced the thread's in-flight-count result ("4 hot prefixes on 8 pods": "never spills: 1 copy each, 4 pods idle"): 2 prefixes on 4 engines.
- B keeps the thread's 48 prefixes and its 400 blocks per endpoint, so the shared working set sprayed over every engine is 48 × 16 = 768 blocks per engine against 400, the simulator's own ratio of 1.92; with affinity each engine holds 12 prefixes, 192 blocks (0.48 of capacity, against the simulator's 96 blocks, 0.24), leaving room for running requests' private blocks (at most 16 × 4 = 64).
  The pilot checks the regime before C3 is interpreted: A3 at the lowest grid rate must show a reused-prefix fraction below A1's (spraying loses hits), or C3 is reported as not testable at this geometry.
- K's k=64 on 4 engines is the thread's k=128 on 8 in requests per endpoint (even share 16); the distribution of the largest share differs with endpoint count, so K is compared with A3 and with K-stagger measured here, never with the thread's numbers directly.
- W942 doubles `shared-942`'s per-engine first-sight count (24 over 2 engines becomes 48 over 4), keeps its prompt and output shape, and releases each arrival as a pair.
  Time-scaling to a grid rate (below) shrinks or stretches the gaps between pairs, never within one.

These are deviations from the gist, and the post says so.

**Engine slots.** `--max-num-seqs 16` on every engine: 4 × 16 = 64 slots, the thread's 8 × 8.
With vLLM's default (256 or more on this card) the queue scorer would read `num_requests_waiting = 0` at every rate this design reaches, which is not the regime the thread measured.
The default is the first sensitivity cell to add if the owner wants one; it is not in the budget.

## Apparatus

- **Instance:** one **g5.12xlarge Spot** (4 × A10G 24 GB, 48 vCPU, 192 GiB) in ap-northeast-2, through `hack/gpu-kit-session.sh` as extended for g5.12xlarge and four-GPU preflight in commit `c85a2901` (branch `feat/sglang-51980`, not on `dev` yet; the harness PR depends on it reaching `dev` or carries that commit).
  The account's Spot G and VT quota is **48 vCPU, exactly one g5.12xlarge**, so every session runs alone: the pilot's termination must be confirmed before the first main session is requested, and no two sessions overlap.
- **Session clock** (fixed by the runner, a caller cannot move it): bring-up 300 s, the kit's `run.sh` 3,300 s, evidence upload 60 s, self-shutdown at 3,720 s, termination confirmed by 4,020 s after `LaunchTime`.
  While the kit runs, the runner archives and uploads its records, then sleeps 60 s, so the newest checkpoint can be about two minutes old (upload of up to 60 s plus the sleep), not 60 s.
- **Layout: plain processes on the host, no kind.**
  Four vLLM servers, one per GPU (`CUDA_VISIBLE_DEVICES=i`), ports 8000 to 8003; one EPP (file discovery, endpoints file listing the four); one Envoy with `ext_proc` to the EPP, as the router's discovery doc describes; the sender.
  CPU is pinned with `taskset`: each engine on its own 8 cores, the EPP and Envoy on 4 cores, the sender on 4 cores, so the router is never starved by the sender at the top rate; each group's CPU use is sampled at 1 Hz.
- **vLLM 0.34.0** (PyPI wheel, uploaded 2026-11-16; sha256 pinned in the kit) in a uv venv on the runner's Python 3.12.15.
  Flags fixed for all arms: `--enable-prefix-caching`, `--block-size 16`, `--max-num-seqs 16`, `--enable-prompt-tokens-details` (so each response carries `usage.prompt_tokens_details.cached_tokens`), `VLLM_SERVER_DEV_MODE=1` for `POST /reset_prefix_cache` (present at `v0.34.0`, `vllm/entrypoints/serve/dev/cache/api_router.py`); for A, B and K `--max-model-len 2048` and `--num-gpu-blocks-override` 4,096 or 400; for W942 `--max-model-len 8192` and default sizing.
- **Model:** `Qwen/Qwen2.5-3B-Instruct` at revision `aa8e72537993ba99e69dfaafa59ed015b17504d1`, experiment A's model, downloaded once per session into the local HF cache (about 6 GB; a 15.8 GiB download took 47 s on this runner, `gptq-marlin-moe-copies-r8`).
- **EPP** built on the instance from the pinned router SHA with a sha256-pinned Go toolchain matching its `go.mod`; **Envoy** pinned by image digest or release binary sha256 (chosen in the harness PR). The EPP's metrics refresh interval and every flag are recorded; nothing but `--config-file` differs between arms.
- **Per cell:** drain (no running or waiting request on any engine); `POST /reset_prefix_cache` on all four and require `success: true`; restart the EPP process (fresh approximate index, LRU and counters); scrape every engine's and the EPP's `/metrics` (before); replay; wait for the last response or its timeout; scrape (after); export.
  Engines restart only when the block changes their flags (A, K and K-stagger share one config; B and W942 each have their own).
- **K's preloads.** Each is a 32-token prompt with `max_tokens = min_tokens = 1,984` (32 + 1,984 ≤ 2,048, so vLLM neither clamps nor rejects it), sent directly to engines 1, 2 and 3, outside Envoy and the EPP, and tagged as preload traffic.
  Before each burst the sender starts fresh preloads, waits until each engine's `/metrics` shows `num_requests_running` = 1 on engines 1 to 3 and 0 on engine 0, then waits two EPP metric-refresh intervals so the EPP has scraped that state, and only then releases the burst; it cancels the preloads once the burst's last response ends.
  A burst whose precondition is not met within 10 s is not released and is recorded as not run.
- **Sender:** open loop on a precomputed absolute schedule (dispatch lag recorded per request), HTTP keep-alive connections opened and warmed before the first scheduled request so a burst is not serialized by connection setup; each request tagged with its own `x-request-id`.
  Whole-request timeouts: 30 s for A and B, 10 s for K, 45 s for W942; a timeout or error is an outcome (TTFT = ∞), not an instrumentation failure.
  Built on the instance from the kit's committed source; its offline tests run first.

## Measurement

**Seeds:** three per block (A, B, K, K-stagger: arrival seeds 1, 2, 3, the gist's; W942: 941, 942, 943).
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
- TTFT = first non-empty text delta − scheduled send time (client), plus the gist's convention (from the backend request, after routing) from the Envoy access log's timings for the same `x-request-id`;
- tokens from `usage` (`prompt_tokens`, `completion_tokens`, `prompt_tokens_details.cached_tokens`), never from counted stream events (llm-inference-lab E29 to E31: client stream events are not tokens, and chunks can merge);
- TPOT = (last token time − first token time) / (completion_tokens − 1), from usage counts; ITL percentiles from each engine's `vllm:inter_token_latency_seconds` histogram delta;
- the chosen endpoint (Envoy `%UPSTREAM_HOST%` keyed by `x-request-id`), the routing path's time (Envoy, from receiving the downstream request to sending it upstream), and the EPP's per-endpoint scores, including the prefix score, from its `-v=4` "Calculated score" lines with their timestamps;
- the joined pair: what the router credited the chosen endpoint (matched 64-token router blocks) against what the engine served from cache (`cached_tokens`), split into **in-flight credit** (the endpoint's earliest request with that prefix had not yet produced its first token when this one was scheduled, since `PreRequest` inserts index entries optimistically, `approximateprefix/plugin.go`) and **completed credit** (it had).

**Per cell, an accounting ledger with three populations** (evaluation, warm-up, K's preloads), reconciled against the engines (the client is not trusted alone):
- for each engine, the rows routed to it that completed with a usage record sum exactly to its `vllm:prompt_tokens`, `vllm:generation_tokens`, `vllm:prompt_tokens_cached` and `vllm:request_success` counter deltas **when no request to that engine failed, timed out or was cancelled** (preloads are cancelled by design);
- when some did, the engine's deltas must be at least the completed rows' sums, and the excess is recorded as work done for requests that did not complete;
- completion = evaluation rows with HTTP 200, a terminal `[DONE]` and `completion_tokens = max_tokens`, over offered evaluation requests; failures stay in every comparison;
- `vllm:num_preemptions` delta, reported.

**Load imbalance over time:** each engine's `num_requests_running`, `num_requests_waiting` and `kv_cache_usage_perc` sampled at 4 Hz; per 1 s window the coefficient of variation of outstanding requests (running + waiting) across the four engines, and its time average; each engine's share of each block's requests; for K, K-stagger and W942's phase 1, the largest share any one engine got of each simultaneous release (the thread's "max share"), with all six of K's burst shares published, not only the mean.
The 4 Hz samples describe load; they cannot resolve the few-millisecond scheduling window, which is read from the EPP's timestamps (below).

**Concurrent-snapshot evidence (K and K-stagger).** From the EPP's `-v=4` timestamps: for each burst, how many of its 64 requests were scored before the first pick's `PreRequest` was logged, and the score vectors they saw.
Concentration in K is attributed to #1598's mechanism only if most of the burst was scored on the same state and K-stagger's largest share is lower; otherwise it is reported as concentration without a mechanism.

**Prefix copies:** for A and B, how many engines each prefix was sent to (the thread's "copies"), and the engines' own reused-prefix fraction Σ `cached_tokens` / Σ `prompt_tokens`.

**Percentiles** are nearest-rank over every offered request of the measured window. With 25 s of A at a low rate, p99 is decided by a handful of rows (experiment A's lesson: "five rows decided rule 4"), so the criteria use p95 and report p99 beside it.

## Pre-registered criteria

From the strategy review's A table. Each is reported on its own; there is no single MET verdict, because the deliverable is data for #1598, not a pass for a gpuaas change.
"Paired" means the two arms in the same session at the same rate and seed; "2 of 3" means at least two of the three seeds.
The 2-of-3 rule is a **descriptive** acceptance rule over three runs, not a statistical test; every paired effect, its sample count and every seed's value are published beside the outcome word.

| # | A table row | criterion | outcome words |
|---|---|---|---|
| C1 | reproduced counter-example for the current policy | In K, A1's mean largest share per burst is **≥ 24 of 64** (1.5 × the even 16; A3 is measured beside it) in 2 of 3 seeds. For scale: the simulator's MaxScore at k=128 was 58.7 of 128, 45.9%, which is 29.4 of 64 | CONCENTRATION AT OR ABOVE / BELOW THE REGISTERED THRESHOLD; and, separately, ATTRIBUTED / NOT ATTRIBUTED to concurrent scheduling by the evidence above |
| C2 | TTFT p95 / p99 | In W942 at 0.9 × and at 1.2 ×, A2's TTFT p95 over the whole trace is **≤ 0.85 ×** A1's, paired, in 2 of 3 seeds at each rate; first sights and repeats are reported separately beside it | A2 LOWERS THE TAIL / DOES NOT |
| C3 | reused-prefix tokens; victim of spreading | In B at 0.6 ×, A2's reused-prefix fraction is **≤ A1's − 0.10** and A2's TTFT p95 is **≥ 1.5 ×** A1's, paired, in 2 of 3 seeds; decided only if the pilot's geometry check passed | both: SAME DIRECTION AS THE SIMULATOR; one: PARTIAL; neither: NOT THE SIMULATOR'S DIRECTION; or NOT TESTABLE |
| C4 | SLO goodput against the best existing policy | Per block A, B, W942: A2's highest passing tested rate is **at least one grid step above** (or below) A1's in 2 of 3 seeds; censored values compare only where the order is still known | HIGHER / LOWER / NO DIFFERENCE AT THIS GRID; A3 reported as the third column |
| C5 | victim tail | In W942 at 0.9 ×, phase-2 repeats' TTFT p95 under A2 is **≤ 1.20 ×** A1's, paired, in 2 of 3 seeds | HOLDS / VIOLATED |
| C6 | no-prefix regression | In W942 at 0.6 ×, first sights' TTFT p50 under A2 is **≤ 1.10 ×** A1's, paired, in 2 of 3 seeds | HOLDS / VIOLATED |
| C7 | routing overhead against prefill saved | For every arm and cell, the EPP's own scheduling-duration p99 (its histogram times `Scheduler.Schedule` only) is **≤ 5 ms**; the full routing path's p99 from Envoy is reported beside it with no threshold. Prefill saved is an **estimate**, `cached_tokens` ÷ the pilot's isolated prefill rate, labelled as such: under batching the real saving is not linear, which is part of what GPUs show; it is reported, not gated | HOLDS / VIOLATED (scheduling part only) |
| C8 | zero false residency hits | Among requests credited **completed** prefix of ≥ 1 router block (64 tokens) on their chosen endpoint, the share with `cached_tokens = 0` is **≤ 0.5%** under A1 and A2 in A; W942 and B reported with no threshold (W942's 48 prompts of 7,680 tokens fill most of an engine if copied everywhere, and B's 400 blocks evict by design, so eviction is possible there); in-flight credit is reported separately and never counted as false. Named "credited prefix with no realized reuse", not a residency diagnosis | HOLDS / VIOLATED in A; descriptive elsewhere |
| C9 | failure cases | Every arm completes **every** offered request at 0.6 × in A, B and W942; any failure or timeout at any rate is listed with its cause | HOLDS / VIOLATED |

**Instrumentation validity, per cell** (separate from outcomes: an arm that fails, times out or overloads is a result and stays in every comparison; a cell is invalid only when the apparatus did not do what it says):
the ledger above holds; caching on and the configured `num_gpu_blocks` read back from `vllm:cache_config_info`; the arm's config hash and the EPP binary's sha256 equal the registered ones; every `/reset_prefix_cache` returned `success: true`; no engine had a running or waiting request when the cell started; dispatch lag p99 ≤ 10 ms; the schedule's hash equals the other arms' for that block, seed and rate; ≥ 99.5% of evaluation rows joined to an Envoy line, and, when the EPP runs at `-v=4`, to an EPP decision; K's burst preconditions met.
An invalid cell is reported with its cause and excluded, never rerun inside the budget; a criterion that loses a seed is decided on the remaining two only if they agree, and the outcome says it rests on two runs.

**What none of this can show:** anything about the guide's filter profile, the precise producer, multiple EPP replicas, larger models, other GPUs, or more than four engines; and the simulator-to-GPU difference is not a single cause, since prefill cost under batching, the scorer set, tokenization, the router version and the TTFT clock all differ (next section).

## Comparability with the simulator results

| | thread (ptimizeroracle gist; lilong555 11-20) | here |
|---|---|---|
| router | `3871ad02` (gist), `3d0b21d5` (lilong555 11-20) | `733d0e4e`, 114 commits after `3871ad02`, including approximate-producer changes (#3938, #4360) |
| scheduling path | in-process: `Produce`, `profile.Run`, `PreRequest` called by the bench | the real EPP behind Envoy over `ext_proc`, file discovery, its own metrics refresh |
| backends | 8 llm-d-inference-sim, 8 slots, prefill 1 ms/token, ITL 60 ms, no batching slowdown | 4 vLLM 0.34.0 on A10G, 16 slots, real chunked prefill and continuous batching |
| scorers | burst: queue, running, KV; steady: prefix 3, queue 2, running 2, KV 2 | prefix 3, queue 2, KV 2, no-hit-lru 2 (the router's perf baseline) in every block |
| tokens | FNV hashes of words passed as token IDs | Qwen2.5 token IDs passed as the prompt, counted by the engine |
| windows | A 30 s total, 25 s measured; B 40 s total, 30 s measured (the executable; the README says 30 and 40 measured) | the same as the executable |
| TTFT clock | ptimizeroracle: from the backend POST, after routing; lilong555: from request entry, before routing | from the scheduled send, before routing, and the after-routing figure from Envoy |
| rates | 20 req/s fixed (about 2.5 per pod) | a grid around A3's SLO knee; the thread's per-engine 2.5/s is reported if it falls in the grid |

The post compares **directions and mechanisms** (does the burst concentrate, does spreading cost affinity under pressure), not milliseconds, and does not call either result a replication.

## Pilot (one session, about $3; worst case $3.96)

One g5.12xlarge Spot session, the same kit in a pilot mode. It decides nothing about the arms; its time plan, with the same per-cell bounds as the main run:

| step | bound |
|---|---:|
| setup: venv and vLLM, Go and EPP build, Envoy, model download | 550 s (estimated; measured here) |
| engine starts, three configs | 3 × 120 = 360 s |
| isolated TTFT per block (A3, 20 cold with fresh prefixes and 20 warm): `SLO_A`, `SLO_B`, `SLO_W942` and C7's prefill rate | 150 s |
| A3 ramp, A: up to 5 rates, ×1.5 steps from the thread's per-engine 2.5/s (10/s), stopping one rate after the first failure | 5 × 75 = 375 s |
| A3 ramp, B: the same ladder | 5 × 85 = 425 s |
| A3 ramp, W942: 3 rates (1.75, 2.9 and 4.4/s), the full trace at each | 3 × 180 = 540 s |
| logging perturbation: A1 at `-v=2` and `-v=4` on A (one rate) and on K | 2 × 75 + 2 × 105 = 360 s |
| arm switching, joins and the ledger on real engines: A2 and A3 on A at one rate | 2 × 75 = 150 s |
| B geometry check: A1 and A3 at the lowest B rate, reused-prefix fraction | 2 × 85 = 170 s |
| total | 3,080 s of the kit's 3,300 s |

**Logging.** If `-v=4` raises the EPP's scheduling-duration p99 by more than 1 ms, or changes K's mean largest share by more than 4 of 64, on either block, the main run keeps `-v=2` in every cell; then C8, the per-request prefix-score join and the concurrent-snapshot evidence are **unavailable** in the evaluated cells, and the post says so rather than borrowing them from other runs.

**Go / no-go for the main run:** every instrumentation check passes on real engines; `r_w` was bracketed for A, B and W942 (A3 failed at one tested rate and passed at a lower one); the measured setup plus each main session's cells at their bounds ends at least 120 s before the kit deadline.
If the knee is not bracketed, a second pilot is needed ($3.96 worst case) and needs the owner's approval.
If the setup is too long for the sessions below, the registered reduction is A3's removal (one third of every session's cells), not a shorter trace: W942's composition is the same at every rate and in every run.
The pilot's `SLO_w`, `r_w`, timings and the geometry check are committed in a registration amendment before the first main session.

## Cells, time and cost

**Cell count, main run: 120.**
A: 3 arms × 4 rates × 3 seeds = 36; B: 36; W942: 36; K: 3 arms × 3 seeds = 9; K-stagger: A1 × 3 seeds = 3.
Pilot: 21 cells, none in the criteria.

**Why cells are minutes, not run 2's 14.**
Experiment A's run 2 ran 12 cells in 2 h 49 min, about 14 min a cell (`2026-10-27-prefix-aware-routing-design.md` "Run 2"): two fresh engine Pods per cell on EKS (about 4 min) and a 600 s replay.
Here engines are not restarted between cells (a prefix-cache reset and a fresh EPP process take seconds), and the thread's own windows are 30 s (A) and 40 s (B).

**Per-cell bounds** (used for every cell, at every rate, not only the top one): 15 s of drain check, resets, EPP restart and scrapes, the replay, and the whole-request timeout as the drain bound.

| block | bound |
|---|---:|
| A | 15 + 30 + 30 = 75 s |
| B | 15 + 40 + 30 = 85 s |
| K, K-stagger | 15 + 6 bursts × (5 s preload setup + 10 s timeout) = 105 s |
| W942 | 15 + 120 + 45 = 180 s (replay at most 120 s, at 0.6 × r_W942 if `r_W942 ≥ 2.9/s`) |

**Six main sessions, each one seed and one group, so every comparison is paired inside one instance:**

| session | contents | cells | bound (setup 550 s + engine starts + cells) |
|---|---|---:|---:|
| X1, X2, X3 (seeds 1, 2, 3) | A, K and K-stagger (one engine config), then B (restart) | 12 + 3 + 1 + 12 = 28 | 550 + 120 + 900 + 315 + 105 + 120 + 1,020 = **3,130 s** |
| Y1, Y2, Y3 (seeds 941, 942, 943) | W942 | 12 | 550 + 120 + 2,160 = **2,830 s** |

Both end at least 120 s before the kit's 3,300 s with every cell at its bound, so no cell is skipped for time unless the setup overruns; if it does, the runner skips whole rate groups (all arms at one rate), never one arm, so a missing comparison never depends on an earlier arm's performance, and each skip is reported.
If `r_W942 < 2.9/s`, the W942 replay at 0.6 × exceeds 120 s and Y no longer fits; the amendment then drops the 0.6 × rate for W942 (and C6 moves to 0.9 ×) rather than changing the trace.
**Order inside a session:** the four rates in a fixed shuffled order registered per session, and at each rate the three arms in rotated order (A1 A2 A3, A2 A3 A1, A3 A1 A2, A1 A2 A3), the rotation offset by one per seed, so across the three seeds each arm takes each position four times per block.
K-stagger runs immediately after K's three arms.
Arms within a seed share an instance, so instance-to-instance speed differences cancel in every paired ratio.

**Cost.** The runner's own constants for g5.12xlarge: Spot cap $3.48/h, plus $0.0683/h for 120 GB gp3 at 500 MiB/s and 6,000 IOPS and a public IPv4, so $3.5483/h all in, billed at worst to the termination deadline of 4,020 s: **$3.9623 per session**, under the runner's $4.00 per-session cap, which it enforces before buying.

| | sessions | worst case | expected |
|---|---:|---:|---:|
| pilot | 1 | **$3.96** | about $3.0 (Spot was $3.27 to $3.48/h in ap-northeast-2 on 2026-11-19 to 21; about 3,250 s from launch to termination) |
| main run | 6 | **$23.77** | about $16 to $18 (about 2,800 to 3,300 s each) |
| total | 7 | **$27.74** | about $19 to $21 |

The worst case assumes EC2 confirms each termination by its deadline, as the runner states; one that does not is reported, and its billing past the deadline is not bounded by this design.
S3 for evidence and the Hugging Face download are not billed meaningfully; there is no EKS cluster and no NAT gateway.
A Spot reclaim keeps the records already checkpointed; rerunning a reclaimed session is a seventh main session ($3.96 more, $31.70 in all) and needs the owner's approval; nothing reruns automatically.
**If the budget must shrink:** drop A3 first (one third of every session's cells), then the 1.5 × rate.

## Offline rehearsal before the pilot

The whole kit runs on this machine first with llm-d-inference-sim in place of vLLM (same EPP binary, Envoy, sender, ledger and scorer), with injected faults that must each fail visibly: a dropped request, a token count off by one, a missing EPP line, a reset that returns `success: false`, a schedule hash mismatch, a K burst released before its preconditions.
That rehearsal checks the apparatus only; no simulator number from it is reported as a result.

## What would be posted to #1598 afterwards

The shape, not the text; the text is drafted in Korean for the owner first, then posted in English only after the owner's review, following llm-d-router's AI-assistance practice as read at that time (the thread's contributors add a short "ai-assisted, checked by me" line).

1. One sentence of setup: 4 × A10G, vLLM 0.34.0 with prefix caching, Qwen2.5-3B, router `733d0e4e` EPP behind Envoy, the router's approximate optimized-baseline profile, three seeds.
2. A table in ptimizeroracle's column layout, three rows (max-score, weighted-random, round-robin): K largest share (even 16) with the six burst shares and K-stagger; A p95 / p99 and copies; B p50 / p95 and copies; so it lines up with the 11-14 table.
3. GPU-only columns the simulator cannot give: highest passing tested rate at the SLO, goodput, the engines' reused-prefix fraction, credited prefix with no realized reuse, TTFT of first sights against repeats in W942.
4. "Reading" bullets: where the GPU direction agrees with the simulator's and where it does not, and anything only GPUs show (prefill slowing under batching, decode interference); no "replicated" wording.
5. Caveats: the scorer set differs from the gist's, the scaling from 8 pods to 4 engines, the 16-slot cap, the router version gap, three seeds.
6. A link to the raw rows, configs, schedule hashes and the kit in the gpuaas repository.
7. No PR, no `/assign`, no claim on the issue; an offer to run a specific maintainer-requested config (for example the gist's scorer set or the guide profile) through the same kit.

## Review

codex `gpt-6-astra`, reasoning high, read-only sandbox, on the first draft, with the thread, the gist, the router at the pinned SHA and the runner at `c85a2901` as inputs (log outside the repository, header checked: `model: gpt-6-astra`, `reasoning effort: high`, `sandbox: read-only`).
It found 2 blockers, 10 major and 3 minor findings. I checked each against the cited source; the code-level ones (tokenizer backend, 64-token minimum block, optimistic `PreRequest`, the gist's total window, the runner's checkpoint loop, the vLLM clamp) all held.

| # | finding | checked | change |
|---|---|---|---|
| 1 | K's 2,048-token preload cannot run under `--max-model-len 2048` with `min_tokens = max_tokens` | yes | 32 + 1,984 preload; per-burst preconditions, cancellation and refusal specified |
| 2 | the X sessions' "worst case" bounded only one rate's drain; all-bound cells give 3,880 s | yes | every cell at its bound, timeouts per block, X re-planned to 3,130 s; skipping is by whole rate group only |
| 3 | A1's scorer set is not the gist's, so simulator results are not predictions | yes | A1 kept as the owner's specified default; "replication" language removed; the scorer difference is in the comparability table; the gist set is offered as a follow-up config. **Not adopted:** making the gist set the primary arm, because the owner asked for the router default and a fourth arm does not fit the budget |
| 4 | B with 24 prefixes fits when sprayed (384 < 400 blocks) | yes, my arithmetic was wrong | 48 prefixes on 4 engines: sprayed 768 against 400 (the simulator's 1.92), affinity 192; pilot checks the regime before C3 |
| 5 | nothing verifies the concurrent-snapshot mechanism | yes | warmed connections, EPP-side overlap evidence, K-stagger control; C1 split into a threshold and an attribution |
| 6 | text prompts get the router's byte-packing estimate, and router blocks are at least 64 tokens | yes | token-ID prompts; router credit in 64-token blocks, engine reuse in tokens |
| 7 | exact reconciliation plus exclusion would remove failing cells | yes | outcomes separated from instrumentation; a three-population ledger; exact identity only where no request failed |
| 8 | the `-v=2` fallback makes C8 unobservable in evaluated cells | yes | C8 and the joins declared unavailable under the fallback; logging perturbation also measured on K |
| 9 | "no eviction by construction" is unestablished, and optimistic entries can show zero reuse with no eviction | yes | in-flight and completed credit split; C8 gated in A only, renamed |
| 10 | cold calibration samples may be warm; "maximum sustainable" is not what a finite trace shows; W942's composition changed with the fallback | yes | fresh prefix per calibration sample; "highest passing tested rate", censored; the ramp ladder specified; W942's composition fixed, the fallback is A3's removal or dropping a rate |
| 11 | C7's histogram is `Scheduler.Schedule` only, the saved-prefill figure assumes linearity, and A3's overhead is not equal | yes | scheduling and full routing path reported separately; saved prefill labelled an estimate and not gated; A3's overhead described as lower. **Not adopted:** measuring cold and warm prefill under batching, which needs its own cells |
| 12 | C1's 50% threshold would reject the simulator's own 45.9% | yes | threshold 24 of 64 (1.5 × even) with A3 measured beside it; all six burst shares published |
| 13 | the gist's windows are 30 and 40 s total, not measured | yes | the executable's windows adopted |
| 14 | 2 of 3 is a voting rule; the weighted picker's randomness is not seeded | yes | stated as descriptive; every paired effect published; picks recorded |
| 15 | checkpoints are about two minutes apart, not 60 s | yes, runner lines 178 to 184 | corrected; the cost arithmetic it rechecked ($3.962268 a session, $27.735878 for seven) is unchanged |
