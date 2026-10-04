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

| Quantity     | Measured (`m5c-20261002-014903`, `readings.txt:11-13`) | `nominal` per trace | `slow-prefill` per trace |
|--------------|--------------------------------------------------------|---------------------|--------------------------|
| Isolated p99 | 174.268 ms                                             | 103–109 ms          | 153–164 ms               |
| Shared p99   | 4000.579 ms                                            | 813–1,087 ms        | 1,672–2,696 ms           |

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

---

## 8. What this cannot establish

- Two lengths are two conditions; nothing here is a statement about length in general.
- The model is a model. Agreement with it supports its mechanism on this card, engine build and model; disagreement is reported as disagreement, and the model is not re-fitted to the curve after the fact to make the predictions come true.
- P2's closed form assumes a victim whose isolated tail is short compared with `S_B`. The long level does not satisfy that, which is why P3 exists and P2 is tested on the short level alone.
- A single A10G, one engine build, one 3B model. A different card changes `S_B`, and the rule's claim is that it changes *only* through `S_B` — which this page can test on one card and cannot establish across cards.
- Everything in section 4 of the 2026-10-03 page that is not amended here.

---

## 9. Who established what

| Claim                                                                                                     | Established by                                                                                     |
|-----------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------|
| Engine flags, the absence of a metrics scrape, the fixed seed, the fixed cell order, the weighted default | A subagent's read of the scripts; the seed and the cell order re-read by me at the cited lines     |
| The measured tails and the microtest figures                                                              | Tracked files: `hack/m5c-20261002-014903/readings.txt`, `2026-09-04-scheduler-microtest-result.md` |
| The model, its fit, its failure at the measured point, and every prediction                               | Me, `hack/tail-crossing-model/`, reproducible by running `predict.py`                              |
| The contender's 1.18 s fastest first token                                                                | A subagent's computation from raw rows, **not yet re-derived by me**                               |
| The literature                                                                                            | Web reading on 2026-10-04; not re-measured                                                         |

**A correction this page carries.** In the conversation that led to it, an isolated TTFT of "3,558 ms" at 8,192 tokens was quoted as if it were measured. A search of every tracked document and archive found no such figure. It was not a measurement, and nothing here uses it.
