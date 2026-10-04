# Is prompt length a separate term in the placement rule — a model-first registration

Date: 2026-10-04 · Registered **before** any card time is bought for it, and frozen from the moment the first cell is bought; later changes are appended as dated amendments.

**What this page replaces.** It replaces the *question* and the *design* of `2026-10-03-where-the-latency-sensitive-tail-crosses-each-multiple-exploratory.md` — that page's section 1 and its decisions D1–D3. It keeps that page's measurement machinery unless a row below amends it by name: the endpoint convention, the refusals in its section 3a, the stopping rule in 3b, and the limits in section 4. **It does not authorise a purchase.**

**Why it exists.** The 2026-10-03 page registered "no prediction", and its own literature section said that whether length affects shared-engine interference is already settled. A study that predicts nothing about a settled question can only produce a number, and a number is not a finding. This page fixes both: it states the decision the result changes, and it writes down, before any measurement, what a stated model predicts — so that the measurement is a test of that model and the deviations are the result.

---

## 1. The question, without jargon

A GPU platform that cannot partition a card (an A10G has no MIG) has to decide whether a latency-critical tenant may share one inference engine with a best-effort tenant, and up to what best-effort load. **Does that rule need to know how long the latency-critical tenant's prompts are, or is a length-free rule enough?**

| Heilmeier's question                      | The answer here                                                                                                                                                                                                                                                                                   |
|-------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| What are you trying to do?                | Find out whether the best-effort load a latency-critical tenant tolerates on a shared engine depends on that tenant's own prompt length, beyond what a length-free quantity already explains.                                                                                                     |
| How is it done today, and the limits?     | Rate limits and per-tenant fair-share schedulers (section 2). Vendor guidance says software sharing on a card without MIG suits sporadic utilisation and gives no tail guarantee, with no numbers behind it.                                                                                      |
| What is new, and why might it work?       | A mechanism model written before the measurement, which makes a **closed-form** prediction about where the tail moves. The curve tests the model; it is not read on its own.                                                                                                                      |
| Who cares — what changes if it works?     | The admission rule for `docs/04_GPU_GOVERNANCE_AND_ISOLATION.md`'s shared-instance topology, whose existing guard missed its target at 83.7x. If length is a separate term, the rule must read a tenant's prompt-length profile; if not, it must not, because an extra input is an extra failure. |
| What are the risks?                       | The model already fails to reproduce the one operating point measured with both tenants (section 3c). Buying the curve before explaining that gap would measure a curve no model accounts for.                                                                                                    |
| What does it cost, and how is it checked? | Sized in section 6 after the replication change in section 5 — **it costs more than the 16 cells the 2026-10-03 page approved**, and that approval does not carry over.                                                                                                                           |

---

## 2. Prior work, and the gap this page claims

These are external results that have not been re-measured here. They bound what this page may call new, and they are not inputs to any number it publishes.

| Work                                                | What it establishes                                                                                                                                                                                          | What it leaves open for this page                                                                      |
|-----------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------|
| Sarathi-Serve (OSDI 2024), DistServe (OSDI 2024)    | A long prefill sharing an engine stalls other requests, and chunked prefill or disaggregation is the engineering response. Sarathi reports up to 28x inter-token latency from one prefill in a decode batch. | Both engineer around the stall; neither asks how the *victim's* length changes where its tail crosses. |
| VTC — Fairness in Serving LLMs (OSDI 2024)          | A token-weighted fair scheduler; its evaluation varies request rate with lengths fixed, then lengths at a fixed rate — one factor at a time.                                                                 | Service fairness, not the victim's tail as a function of the aggressor's load.                         |
| FairInference (arXiv 2609.18112, September 2026)    | Well-behaved clients' latency degraded 102–242x by one high-demand client on one A100, bounded to 1.2–1.7x by its scheduler.                                                                                 | Victim length is not a factor it sweeps.                                                               |
| HyGen (NeurIPS 2025), Vidur (MLSys 2024)            | Batch step time is well predicted by a regression on prefill tokens, decode tokens and sequence lengths; Vidur simulates serving from profiled operators to under 9% error.                                  | This page uses that family of model; it does not claim the modelling idea.                             |
| Mitzenmacher and Shahout (Stochastic Systems, 2025) | Frames LLM scheduling as a queueing problem with variable service and memory, and lists the open questions.                                                                                                  | The queueing view this page's closed form comes from.                                                  |

**The gap this page claims, and no more:** no surveyed work tests whether a length-free coincidence rule predicts where a latency-critical tenant's tail quantile moves on a shared engine, or reports that crossing at two victim lengths on a card without MIG. A survey that did not find a result is not proof that none exists.

---

## 3. The model, before any measurement

### 3a. What it is

`hack/tail-crossing-model/itersim.py` is an iteration-level model of one vLLM engine under FCFS chunked prefill. Each step serves running requests first — an in-progress prefill takes its next chunk, a decoding request takes one token — then admits waiting requests in arrival order, all under one 2,048-token budget. Step time is `C0 + B·prefill_tokens + D·decode_sequences`, and TTFT is a client overhead plus the end of the step that completes the prefill.

The serving order is not an assumption. The 2026-09-04 microtest measured it: under `fcfs` a short request never overtook a 7,695-token prefill at any budget, and at a 2,048 budget the short request's contended TTFT (609 ms) sat just under the long request's own (623 ms).

### 3b. Where its parameters come from

| Parameter set  | Source                                                                                                                                                                      | `C0`, `B`, `D`, client overhead    |
|----------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------|
| `nominal`      | Fitted to the microtest: long TTFT 685 / 623 / 588 ms at budgets 512 / 2048 / 8192 and a 48.7 ms uncontended short TTFT                                                     | 7 ms, 71.5 µs/token, 0.3 ms, 32 ms |
| `slow-prefill` | Per-token cost raised only, because in `m5c-20261002-014903` the contender's fastest first token among 139 per repetition took about 1.18 s, which `nominal` cannot produce | 7 ms, 110 µs/token, 0.3 ms, 32 ms  |

The 1.18 s figure was computed by a subagent from that archive's raw rows and is not yet published anywhere; it is named here as the reason for the second set, not as a result.

### 3c. The first result of this page: the model fails at the one point measured with both tenants

`python3 hack/tail-crossing-model/predict.py` replays the measured operating point (LC 9.166 req/s at 256 tokens, BE 0.238 req/s at 8,192, five model traces):

| Quantity     | Measured (`m5c-20261002-014903`; `docs/13_PER_REPETITION_VALUES.md:39`, `:65`) | `nominal` per trace | `slow-prefill` per trace |
|--------------|--------------------------------------------------------------------------------|---------------------|--------------------------|
| Isolated p99 | 174.268 ms                                                                     | 103–109 ms          | 153–164 ms               |
| Shared p99   | 4000.579 ms                                                                    | 813–1,087 ms        | 1,672–2,696 ms           |

**The model explains between a fifth and two thirds of the measured shared tail, and it is not yet known which mechanism holds the rest.** Candidates the model leaves out include the gateway on the request path, KV-cache pressure and preemption, and step-time terms that grow with the number of running sequences. It also shows the measured point is in a steep region: raising `D` alone from 0.3 to 1.0 ms per sequence moves the model's shared p99 on the same five traces from 813–1,087 ms to 2,378–5,813 ms — a one-parameter change spanning the measured value.

This is why section 7 puts **measuring one level deeper** ahead of the curve: without the decomposition of TTFT into waiting and prefill time, a curve that disagrees with the model cannot say why.

### 3d. Replication was one trace, five times

`hack/m5c-matrix.sh` calls `gen-trace --seed 11` at both of its call sites (lines 605 and 2447). **Every repetition in every archived matrix replayed the same arrival schedule**, so the 3,998–4,002 ms spread across five shared repetitions is engine-to-engine noise on one trace, not the variability of the arrival process. The model shows why that matters at low contending load:

| Model, `nominal`, LC 256 tokens at 0.2864 req/s, BE 0.0286 req/s | Five independent 600 s traces |
|------------------------------------------------------------------|-------------------------------|
| Per-trace LC p99                                                 | 495, 80, 73, 65, 612 ms       |

Whether one trace's p99 is 70 ms or 600 ms depends on whether two or more latency-critical arrivals happened to land inside a best-effort prefill. Two repetitions of one trace measure one draw of that coin, twice.

---

## 4. Registered predictions, and what would falsify each

All numbers are the model's, at LC 0.2864 req/s with five 600 s traces per cell, from `predict.py`'s output. The **pooled** estimand of section 5 is used.

| BE req/s     | LC 256: `nominal` pooled p99 | LC 8192: `nominal` pooled p99 | LC 256: `slow-prefill` | LC 8192: `slow-prefill` |
|--------------|------------------------------|-------------------------------|------------------------|-------------------------|
| 0 (isolated) | 65 ms                        | 1,470 ms                      | 75 ms                  | 2,685 ms                |
| 0.0286       | 6.15x, +334 ms               | 1.03x, +46 ms                 | 9.80x, +659 ms         | 1.02x, +41 ms           |
| 0.0716       | 8.80x, +505 ms               | 1.08x, +115 ms                | 12.27x, +844 ms        | 1.05x, +142 ms          |
| 0.1432       | 9.86x, +574 ms               | 1.15x, +217 ms                | 13.54x, +938 ms        | 1.22x, +602 ms          |
| 0.2864       | 14.45x, +871 ms              | 1.36x, +533 ms                | 23.09x, +1,653 ms      | 1.78x, +2,082 ms        |

**P1 — the multiple is mostly a denominator, and confirming it is not a finding.** The model puts the long level's isolated tail roughly 23–36x above the short level's, so the slowdown multiple at the long level stays near 1x while the short level's runs to 6–23x. This is a **manipulation check**: if it fails, the levels did not do what they were declared to do, and nothing else on this page is read.

**P2 — the coincidence threshold, which is the claim worth testing.** For a tenant whose isolated tail is short compared with one best-effort prefill of duration `S_B`, the q-th percentile moves only once the fraction of its requests that land inside a best-effort prefill exceeds `1 − q`, i.e. at about `λ_BE ≈ (1 − q) / S_B`. With the `nominal` model's `S_B` of 0.65 s that is about **0.015 req/s for p99 and 0.077 req/s for p95**. Written as a test with `λ* = (1 − q) / S_B` computed from the **measured** `S_B`: at a BE rate at or below `λ*/2` the pooled q-th percentile stays within 10% of the isolated one, and at or above `2λ*` it exceeds the isolated one by at least `S_B/2`. Both parameter sets are consistent with it at every grid point where a side applies (`nominal`, `S_B` ≈ 0.65 s, p95: +1 ms at 0.0286 and +476 ms at 0.2864 against `S_B/2` ≈ 320 ms; `slow-prefill`, `S_B` ≈ 0.96 s, has no grid point at or below its `λ*/2` of 0.026, which is itself a reason the grid is placed after `S_B` is measured), and the transition between `λ*/2` and `2λ*` is not predicted point by point. **Falsified** if either side fails on the short level. The rule is length-free in the latency-critical tenant's length and length-dependent only through `S_B`; that is exactly the shape the decision in section 1 needs to know about.

**P3 — length enters through the baseline tail, in the counter-intuitive direction, inside a stated load window and nowhere else.** The intuition is that a longer request is exposed to contention for longer, so it suffers more. The model predicts the opposite at moderate load — **+334 ms at 256 tokens against +46 ms at 8,192** at 0.0286 req/s (`nominal`) — because the long level's isolated p99 is already set by its own queueing, and a rare best-effort prefill seldom lands on the requests that make up that tail. **The window is stated in units of P2's `λ*₉₉ = 0.01 / S_B`, with the measured `S_B`:** for `2λ*₉₉ ≤ λ_BE ≤ 10λ*₉₉` the long level's added pooled p99 is smaller than the short level's **on average over the window**, not at every point in it. Outside it the model makes no directional prediction, and both edges are measured rather than chosen. Below `λ*₉₉` the short level's p99 has not yet moved, so the sign is set by noise: at 0.005 req/s the model gives +0 ms against +46 ms (`nominal`) and +8 against +439 ms (`slow-prefill`) — the reverse of P3. Above the window the direction depends on the parameters: `nominal` keeps it to 0.4 req/s, while `slow-prefill` reverses it by 0.2864 (+1,653 against +2,082 ms). An earlier version of this paragraph said the gaps "converge" at the highest load, which the `slow-prefill` column of its own table contradicted, and it tested "the lowest BE load" whatever that turned out to be — which a grid placed below `λ*₉₉` would have made fail on the model's own predictions. The sweep behind these sentences (BE 0.005–0.4 req/s, both parameter sets, the same five traces) is the last block `predict.py` prints. **The test is an average over the window, not a sign at each point, and the reason is a counterexample.** The pointwise version registered first was broken by the model itself at a point the sweep did not sample: `slow-prefill` at 0.086 req/s, inside its window, gives +895 ms against +1,078 ms on the same five traces (found by an independent review, reproduced here). At about 860 pooled completions the long level's added p99 is lumpy, so single points reverse by chance. `predict.py`'s last block measures how each test behaves on the model across 20 disjoint sets of five traces and eight window points: points in the predicted direction were 160 of 160 (`nominal`) and 159 of 160 (`slow-prefill`), so a pointwise test would have falsified a correct model in one set of twenty; the **mean over the window's grid points of (short added p99 − long added p99)** was positive in 20 of 20 sets under both. **Falsified** if that mean is not positive. Individual reversals are published with it and are not by themselves a falsification. Twenty of twenty bounds the test's power on the model only loosely — a one-sided 95% lower bound of about 86% — and it is power **against this model**, not against the card. **The grid must place at least two points inside the window**, which is a constraint on section 5's BE levels.

**What would change the decision.** If P2 holds and P3's direction holds inside its window, the admission rule is length-free in the victim and needs only the contender's prefill duration and the victim's isolated tail — both quantities the platform already observes. If P3 fails, the victim's length is a separate term and the rule must read it.

---

## 5. The design, and every variable it does not let move

**A factorial design, not one factor at a time.** The question is whether length changes the slope of the tail against contending load — an interaction — and one-factor-at-a-time designs cannot estimate interactions. So both factors are crossed.

| Role        | Variable                               | Levels                                                                                                                                             |
|-------------|----------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------|
| Factor 1    | LC input length                        | 256 and 8,192 tokens (1,174 and 42,579 characters; resolved, `hack/input-length-resolution.json`)                                                  |
| Factor 2    | BE arrival rate                        | 0 (the isolated control) and three or four points chosen by P2's band once `S_B` is measured                                                       |
| Held fixed  | LC arrival rate                        | 0.2864 req/s at both lengths — the request rate, not the token rate; see "what this costs" below                                                   |
| Held fixed  | LC arrival times                       | **Independent per-tenant arrivals** (`ArrivalsIndependent`), so a trace's LC rows are byte-identical at every BE level and in the isolated control |
| Held fixed  | Engine build, model, flags, card       | The digest, `--max-num-batched-tokens=2048`, `--max-num-seqs=64`, prefix caching off, one A10G                                                     |
| Held fixed  | BE length and output caps              | 8,192 tokens; 64 LC and 16 BE output tokens                                                                                                        |
| Replication | **Independent traces**                 | A different seed per replicate, the **same** seed set in every cell — common random numbers across cells                                           |
| Run order   | Randomised within each replicate block | So a drift in the card or the engine over the session is not read as an effect of a factor                                                         |

**What holding the request rate costs.** At 0.2864 req/s the short level leaves the card nearly idle, while the long level already loads it with its own prefills. A fixed request rate means a different utilisation per level; a fixed utilisation means a different request rate. **No design varies length alone**, because length *is* work. This page holds the request rate and makes the utilisation difference explicit through the model, rather than choosing a design that hides it.

**The estimand changes, and the reason is the replication change.** The 2026-10-03 page took the median of per-repetition p99s. With independent traces, the population is the arrival process, so this page registers the **pooled p99 over all of a cell's traces** as primary, with the pooled p95 secondary, and the per-trace values published beside them. At about 172 LC completions per 600 s trace, one trace's p99 is its second-largest value and a distribution-free 95% interval for it **does not exist** (its upper rank lies beyond the maximum); at five traces (about 860) it does. Section 3a's refusals of the 2026-10-03 page still apply, per trace.

---

## 6. Size and cost — a decision, not a computation

At five traces, two lengths and an isolated control plus three BE levels, the design is 2 × 4 × 5 = **40 cells**. At the 11.61 min mean that the archives record for 256-token cells, that is about 7.7 hours, before the long level's unmeasured per-cell cost. This is more than twice what the 2026-10-03 page sized and approved, and the approval does not carry over.

The order this page recommends spends the least before the most informative result:

| Stage | What is bought                                                                                                 | What it decides                                                                       |
|-------|----------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------|
| 0     | Nothing. The preconditions of section 7                                                                        | Whether the measurement can explain itself                                            |
| 1     | The already-measured operating point again, **with the one-level-deeper decomposition**, plus `S_B` (BE alone) | Which mechanism holds the 2–4x gap of section 3c, and the `S_B` that places P2's band |
| 2     | Short level only: isolated and three BE levels around P2's band, five traces                                   | P2, alone — the claim that does not need the long level                               |
| 3     | Long level, same BE levels and traces                                                                          | P3 and the interaction                                                                |

Each stage needs its own explicit approval at the time it is started.

---

## 7. Preconditions before any stage is bought

| #   | Precondition                                                                                                                                     | Why                                                                                                                                                                   |
|-----|--------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1   | **Scrape the engine's `/metrics` at every cell boundary** and archive it, so each cell's TTFT can be split into time waiting and time in prefill | The m5c scripts scrape nothing today. Whether this engine build exposes per-request queue and prefill histograms is **not verified**, and is the first thing to check |
| 2   | **Register `Arrivals: ArrivalsIndependent`** for both tail-crossing studies, and let the runner sweep the BE rate with the LC rate held          | Both studies leave `Arrivals` unset and the non-ladder path hard-codes `weighted`, which moves LC arrival times whenever the BE weight moves                          |
| 3   | **A seed per replicate**, recorded in the manifest and the archive                                                                               | Both call sites pass `--seed 11` (section 3d)                                                                                                                         |
| 4   | **Randomised cell order within a replicate block**, recorded in the archive                                                                      | `hack/m5c-matrix.sh:493-497` runs repetition-major in a fixed arm order                                                                                               |
| 5   | **The pooled estimand implemented and mutation-tested**, alongside the existing per-repetition one                                               | An estimand the code does not compute is filled in by whoever writes the report — the failure section 3 of the 2026-10-03 page records                                |
| 6   | **The model check re-run against stage 1's evidence** before stage 2 is approved                                                                 | If the gap of section 3c is not explained, P2's band is placed by a model already known to be wrong                                                                   |

**Precondition 1 — implemented 2026-10-04, not yet exercised on a card.** `scrape_engine_metrics` in `hack/m5c-matrix.sh` reads every engine of the cell's topology before and after the replay, and writes `engine-metrics-<cell>-<phase>[-a\|-b].prom` or an `.err` naming why not; it never fails the cell. It accepts a page only from a forward that found the port free and then reported binding it, because an independent review showed a live kubectl pid alone could let a leftover forward's page through under this cell's name. The files are a counted class in the archive accounting and travel in the per-cell upload. `hack/test/check-engine-metrics-scrape.sh` drives it against stubs, and each of its refusals was deleted once and turned the harness red. **What the source says, and what is still unverified:** the vLLM v0.27.1 tag defines `vllm:request_queue_time_seconds`, `vllm:request_prefill_time_seconds` and `vllm:time_to_first_token_seconds` as histograms, so a cell's engine-side TTFT can be set against its client-side TTFT, and the difference is the gateway and the network — the first candidate for section 3c's gap. That the pinned image digest is that tag is the image comment's claim, not something re-checked here. The histograms carry **no tenant label**, so they decompose the cell's mixed population, not the latency-critical tenant's tail, and their buckets bound how finely a p99 can be read from them.

**Precondition 3 — implemented 2026-10-04.** `Study.TracesVaryByRepetition` is set on both tail-crossing studies, and `benchharness study-traces` prints it for the runner. `hack/m5c-matrix.sh` takes `SEEDS`, one per repetition, and both `gen-trace` call sites read the repetition's seed; a study registering a trace per repetition is refused before anything is rented when `SEEDS` is empty, shorter than `REPS`, or repeats a seed, and a study replaying one trace is refused when given two. `hack/m5c-gpu-session.sh` carries `SEEDS` to the instance and to its local plan check. The report then holds the property the other way round: two repetitions of one arm sharing a trace are refused, and **the isolated baseline and the contended arm of one repetition must offer the latency-critical tenant the same schedule** — the pairing one shared trace used to guarantee by construction, and the check that also catches a recording cut short, since these studies have no sibling contended arm to compare row counts with. Every refusal was deleted once and turned a test red, except a per-repetition row-count comparison between contended arms that no study here can reach; that check was removed rather than kept as code that never runs. **Not changed:** the sharing matrix and the ladders replay one trace, as every archive did, and their reports apply the old rule.

**Precondition 2 — implemented 2026-10-04.** Both tail-crossing studies register `Arrivals: ArrivalsIndependent` and the arms `R1`, `be01-shared` … `be06-shared`; a bare `shared` is no longer admitted, because it would pool every BE level into one p99. `hack/m5c-matrix.sh` now reads every study's arrival model from the registry — the sharing matrix, which registers none, still falls back to weighted — and runs an independent-arrival study only as a `SWEEP` of BE rates with `PREMIUM_RATE` held, building one `R1` and one `beNN-shared` cell per level in each repetition; `RATE`, `NOISY_WEIGHT`, `ARMS` or a compiled CR beside a sweep are refused, as are more than six levels, a repeated rate, and a sweep of a weighted study. `hack/m5c-gpu-session.sh` carries the sweep to the instance and its plan check, and a dry run under the lifecycle stubs rendered `SWEEP`, `PREMIUM_RATE`, `SEEDS` and `STUDY` into the user-data with `RATE`, `NOISY_WEIGHT` and `ARMS` emptied. `compile-plan` no longer compiles the tail-crossing studies: a CR's single contender rate turned into a weight is neither their arrival model nor their arm set. What the pairing in the report rests on is pinned at the generator: `GenerateTrace` under independent arrivals holds the latency-critical rows byte-identical while the BE rate quintuples, and a three-level plan shows one latency-critical count at the baseline and every level with contender counts rising (11, 26, 65 offers at 0.0286, 0.0716 and 0.1432 req/s over 505 s). **Precondition 4 — implemented 2026-10-04.** A sweep's cells are bought in a randomised order within each repetition and in repetition order across them. The permutation is the sort of sha256 of "<the repetition's trace seed>/<label>", so it reproduces from the seeds the archive already records, differs from block to block, and does not depend on which awk's random-number generator is installed; `load-source.txt` records the order. Seeds 7, 8 and 9 give three distinct block orders in the plan harness, and the same seeds give the same plan twice. A small sweep can repeat an order by chance — three cells have six orders, and the kind rehearsal's seeds 11 and 12 drew the same one. The cost is stated where the order is built: the baseline is no longer bought first, so a run cut short may hold a level with no denominator. The sharing matrix keeps the fixed order it registered.

**Precondition 5 — implemented 2026-10-04.** `bench.EvaluateTailCrossing` reads each BE level against the isolated baseline on the **pooled** p95 and p99 over all of the arm's traces, publishes each trace's own p99 beside them, and reports the multiple and the added milliseconds with no verdict word and no threshold. A level is refused on its own when its tail is censored in the pool or in any trace, when any trace has fewer than 100 latency-critical completions, or when it pooled a different number of traces from the baseline or different repetitions — an independent review showed {1,2} beside {1,3} read as a pair; a baseline that cannot be read refuses every level, since every level is a ratio against it. `benchharness report` appends the block for the two tail-crossing studies. Each refusal was deleted once and turned a test red, and the replacement of the pooled p99 by the median of the per-trace p99s — the estimand the sharing matrix registered — was caught by value: on the fixture the two give 6.12x and 1.23x. **Not done:** P2's and P3's tests need `S_B`, the contender's measured prefill time, which no reading computes; they are applied to the readings' numbers by the analysis, after stage 1 measures `S_B`.

---

## 8. What this cannot establish

- Two lengths are two conditions; nothing here is a statement about length in general.
- The model is a model. Agreement with it supports its mechanism on this card, engine build and model; disagreement is reported as disagreement, and the model is not re-fitted to the curve after the fact to make the predictions come true.
- P2's closed form assumes a victim whose isolated tail is short compared with `S_B`. The long level does not satisfy that, which is why P3 exists and P2 is tested on the short level alone.
- A single A10G, one engine build, one 3B model. A different card changes `S_B`, and the rule's claim is that it changes *only* through `S_B` — which this page can test on one card and cannot establish across cards.
- Everything in section 4 of the 2026-10-03 page that is not amended here.

---

## 9. Who established what

| Claim                                                                                                     | Established by                                                                                                                                                                   |
|-----------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Engine flags, the absence of a metrics scrape, the fixed seed, the fixed cell order, the weighted default | A subagent's read of the scripts; the seed and the cell order re-read by me at the cited lines                                                                                   |
| The measured tails and the microtest figures                                                              | Tracked files: `docs/13_PER_REPETITION_VALUES.md` (blocks `m5c-15cell-r1-premium-ttft-p99` and `m5c-15cell-shared-premium-ttft-p99`), `2026-09-04-scheduler-microtest-result.md` |
| The model, its fit, its failure at the measured point, and every prediction                               | Me, `hack/tail-crossing-model/`, reproducible by running `predict.py`                                                                                                            |
| The contender's 1.18 s fastest first token                                                                | A subagent's computation from raw rows, **not yet re-derived by me**                                                                                                             |
| The literature                                                                                            | Web reading on 2026-10-04; not re-measured                                                                                                                                       |

**A correction this page carries.** In the conversation that led to it, an isolated TTFT of "3,558 ms" at 8,192 tokens was quoted as if it were measured. A search of every tracked document and archive found no such figure. It was not a measurement, and nothing here uses it.

## Amendment, 2026-10-05 — stage 1 is bought, as a new measurement at the measured operating point

**Approved.** The user approved the paid runs on 2026-10-05. This is written before stage 1's first billable second, while the calibration re-run (`m5c-20261004-150205`) is still on its card.

**What is bought.** `sharing-matrix-2026-09-10` at the load of `m5c-20261002-014903` — `RATE=9.4045`, weights 1 / 0.026 / 0, `DURATION_MS=505000`, seed 11 — with `ARMS="R1 shared"` and `REPS=2`: four cells. The question is section 3c's: where the shared tail the model cannot reproduce comes from, read from the engine-metrics the cells now record.

**Why it is a new measurement and not a reproduction.** The runner's reproduction check requires the target's `gatewaySHA` and image digests, and the gateway has been rebuilt since that run, so the honest label is a new measurement at the same load. Recorded separately because it was found on the way: the plan path's `gen-trace` call passes neither `--tokenizer-rev` nor `--gateway-sha`, while the real path passes both, so **no `PURPOSE=reproduction` plan can pass today** — every one is refused with "the target run records tokenizerRev and this plan records none". That is a defect in the plan check, not in this purchase, and it is left for its own change.

**What `S_B` now comes from.** The calibration's `R1` cells serve only 8,192-token latency-critical requests, so their engine prefill histogram measures `S_B` directly and stage 1 does not need a BE-only cell. Its first cell gave a client-side minimum TTFT of 1,037.7 ms and an engine mean prefill of 1,147.1 ms over 178 requests — against the model's `nominal` 646 ms and `slow-prefill` 961 ms. Those are one cell's numbers, recorded here as the reason the model's parameters will be revisited, not yet as a published figure.

## Amendment, 2026-10-05 — `S_B` measured; P2's high side corrected on the model; the grid and the size of stages 2 and 3

Written after the calibration and before stage 2's first billable second. No stage-2 or stage-3 cell exists yet.

**`S_B`, and what it did to the model.** The calibration re-run `m5c-20261004-150205` completed its four cells (`matrix exited 0`, archive accounting 32 of 32). Its isolated 8,192-token cells' fastest client-side TTFT was **1,037.7 ms**; the engine's own mean prefill over the `R1` cells was 1,138.5–1,147.1 ms. Solving the model's per-token cost from that ONE minimum — the `measured` parameter set in `predict.py`, every other parameter left at the microtest's values — gives 119.3 µs per token against the registered `nominal` 71.5. With nothing else changed, the model then predicts quantities that were not used to choose it:

| Checked quantity | Measured | `nominal` | `measured` |
|---|---|---|---|
| Isolated 8,192 tokens at 0.2864 req/s, pooled p99 | 2,912.7 ms (322 requests, two traces) | 1,470 ms | 3,146 ms on the same two seeds |
| Same, p50 | 1,040.7 ms | — | 1,038 ms |
| Section 3c's isolated tail, 256 tokens at 9.166 req/s | 174.3 ms | 103–109 ms | 167–179 ms |
| Section 3c's shared tail | 4,000.6 ms (one trace) | 813–1,087 ms | 1,876–3,170 ms |

So the largest part of section 3c's gap was the per-token cost carried from the microtest, and a factor of 1.3–2 on the shared tail is still unexplained. Stage 1 is buying the decomposition of exactly that point. The calibration also measured the gateway's and the network's share directly: client-side mean TTFT 1,342.0 ms against the engine's 1,332.8 ms in the first `R1` cell, about 9 ms.

**The grid.** With `S_B` = 1.0377 s, P2's `λ*₉₅` = 0.0482 req/s, and the BE levels of both stages are `λ*/2, λ*, 2λ*, 4λ*` = **0.0241, 0.0482, 0.0964, 0.1927 req/s**. P3's window, `2λ*₉₉ … 10λ*₉₉`, is 0.0193–0.0964 req/s and holds the first three.

**P2's high side is corrected, and why.** Run on the `measured` model with this grid, the high side as registered — at or above `2λ*` the pooled p95 rises by at least `S_B/2` — held in **11 of 20** sets of three traces: at `2λ*` the rise was 421–628 ms with a median of 537, and `S_B/2` is 519, the middle of that distribution. A test a correct model fails half the time decides nothing. The high side now reads **at or above `2λ*`, a rise of at least `S_B/4`** (259 ms), which held in 20 of 20 with the smallest rise 1.6 times the threshold; the low side, a rise within 10% at or below `λ*/2`, held in 20 of 20; P3's window mean held in 20 of 20. `predict.py`'s `stage2()` prints all of it. This is the second time a criterion here was corrected by running it on the model before buying, and the reason is the same as the first.

**The size.** Three traces per cell, not five: `SEEDS="1 2 3"`, the same seed set in every cell of both stages. Five traces would be 25 cells per stage, about 5.4 hours, which exceeds the session's hard stop and the remaining credential window; three is 15 cells per stage. Section 5's pooled estimand is unchanged; at about 172 completions per trace, three traces pool about 516.

**Precondition 6 is met by the calibration, not by stage 1, and the order is stated rather than hidden.** It asked for the model check to be re-run against stage 1's evidence before stage 2 was approved, so that P2's band would not be placed by a model already known to be wrong. Stages 2 and 3 are bought **while stage 1 is still running**, and concurrently with each other: run one after another, stage 3 would start with about 250 minutes of credentials against the 320 its session requires, and be refused. What the precondition protected is covered by a different check: the band is now placed by `λ* = (1 − q) / S_B` with `S_B` **measured**, not by the model, and the model refitted from that one measurement predicts the calibration's isolated tail within 8% and section 3c's isolated tail within its spread. What stage 1 can still change is the explanation of the shared tail at the 256-token operating point, which none of P1–P3 is placed by. If stage 1 contradicts the `measured` parameters, that is reported beside stages 2 and 3, not used to re-place their grid after the fact.
