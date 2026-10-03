# Where the latency-sensitive tail crosses each multiple of its isolated baseline — exploratory registration

Date: 2026-10-03 · Registered **before** any card time is bought for it. The registered body is frozen from
the moment the first cell of this page is bought: later changes are **appended as dated amendments** and are
never edited into it. This header is written to be true from the start, because
`2026-09-10-does-splitting-the-card-buy-protection.md` claimed an immutability it stopped honouring and had
to correct its own header on 2026-10-03.

**EXPLORATORY. This page registers no pass mark and no threshold.** It registers what is measured, how it is
aggregated, what is collected while the card exists, when the run stops, and the shape of the report.

---

## 1. Why the question is a curve and not a comparison

Three attempts to ask "does sharing protect the tail" ended in one nearly information-free bit. The bars
(premium TTFT p99 at or below 2x the isolated baseline, TPOT p99 at or below 1.25x) were **carried forward
from an earlier study rather than derived**, the 2026-09-10 page says so itself, and
`2026-09-09-what-would-have-to-change.md:53` permits a successor to set a different bar **only from a stated
service objective that does not read this run's results**.

**No such objective exists in this repository.** `2026-09-21-what-a-violation-would-have-to-mean.md` records
that `docs/02_CONTROL_PLANE_API.md:75` advertises an `slo` surface that is empty, and that the project has no
real users. So a threshold question cannot be posed honestly today — including the goodput-under-SLO form,
which needs a latency budget to divide the outcomes.

What *can* be posed without a threshold is the **curve**: the latency-sensitive tail as a function of the
contending load, reported so that any budget stated later can be read off it. The useful content of the last
run was never the verdict; it was the magnitudes — an isolated tail of 174 ms, one shared engine at 3,998 ms,
two time-sliced engines at 14,351-15,078 ms, with aggregate output throughput unchanged at 589.2 against
589.3 tok/s.

> **At what offered contending load does the latency-sensitive tenant's TTFT p99 reach each multiple of its
> isolated baseline, and does that load depend on the latency-sensitive tenant's own prompt length?**

No prediction is registered. The 2026-09-10 page already stated the honest position for its own question —
*"it is not obvious this helps … that is what makes it worth measuring rather than assuming"* — and there is
less prior information here, not more.

### What the literature says this is and is not

A survey on 2026-10-03 (arXiv, OSDI/NSDI/NeurIPS proceedings, NVIDIA/AWS/vLLM documentation) found the
following. **These are external facts that have not been re-measured here**, and they are marked as such
because every figure this repository publishes from its own evidence is one it re-derived from the rows. They
bound what this study may claim to be new; they are not inputs to any number it will publish.

- **That input length affects shared-engine interference is already established.** A long prefill blocking
  other requests on the same engine is *head-of-line blocking*, and Sarathi-Serve (OSDI 2024) and DistServe
  (OSDI 2024) both treat it as the problem to be engineered around. Asking "does length matter" would be
  asking a settled question.
- **Where the ordering of the sharing mechanisms crosses over is not established.** No public study was found
  that holds one GPU, one model, one shared engine, two independent engines under CUDA time-slicing, and two
  under MPS, and sweeps the latency-critical prompt length.
- **MPS on one card has public measurements, and they bound what this can claim to be new.** Splitwiser
  compared a single vLLM engine against two processes with and without MPS on one A10 (Llama-2-7B) and
  reported MPS 1.42x faster to finish 160 requests, explicitly as *preliminary* and without per-tenant tail
  latencies. Databricks compared one engine against two with MPS on an H100 (Qwen2.5) and reported the
  throughput gain shrinking as model size and context grow — **above 10% below ~3B, regressing around 3B as
  context grows, and no gain above 3B.** This lab serves **Qwen2.5-3B**, which is the boundary they name.
  Independently checking that boundary on a commodity card is the contribution; "nobody has measured MPS" is
  not, and this page does not claim it.
- **The current research axes are elsewhere** — prefill/decode disaggregation, length-aware chunked prefill,
  SLO-goodput scheduling, KV-cache routing. A bare MIG/MPS/time-slicing comparison is a niche. The curve is
  what connects this lab's evidence to the goodput literature without a threshold.
- **NVIDIA and AWS both say, in documentation, that these mechanisms are for consolidating low utilisation
  and not for strict tail-latency guarantees.** AWS names A10G/G5 as a GPU without MIG where time-slicing
  suits low or sporadic utilisation, and states the compute share is best-effort. Public *numbers* behind
  that advice are scarce, and a curve is exactly the missing artefact.

---

## 2. Terminology, in the words the literature uses

This page had an earlier draft written in the repository's internal names. They are kept in the code, where
they are identifiers, and not used here.

| This page says | The code says | Why |
|---|---|---|
| **latency-critical (LC) tenant** | `premium-1` (`PremiumTenant`) | The workload on it is sensitive to response latency. `latency-critical`/`latency-sensitive`/`online` is the usual term; HyGen uses "latency-sensitive online". "premium" is a tenant name, not a property of the input |
| **best-effort (BE) tenant** | `standard-noisy` (`NoisyTenant`) | Throughput matters more than latency for it. BROS uses "best-effort (BE)"; the code's comment calls it "the contending tenant whose work the positive readings require to survive" |
| **isolated baseline** | `R1` (`ArmR1`) | It is the control, not a treatment: the same trace replayed with the BE tenant filtered out. Systems papers write `isolated baseline` or `dedicated-GPU baseline`, not `arm` |
| **experimental configuration** | `shared`, `timeSlicing`, `mps` | Papers name the mechanism (`shared-engine configuration`, `two-engine MPS configuration`) rather than numbering arms |
| **TTFT** | `TTFTNanos` | Time to first token: queueing plus prefill plus the first token's return. Computed from client-side timestamps only (`replay.go:32`) |
| **TPOT / ITL** | `TPOTMsP99` | Time per output token — the stream rate a first-token metric cannot see |
| **the tail** | `TTFTMsP99` | The upper percentiles of the latency distribution. **The primary endpoint is TTFT p99**; p50 and p95 are secondary and published beside it |
| **isolation slowdown** | (not yet computed) | `shared TTFT p99 ÷ isolated TTFT p99`. The quantity the curve is drawn in, so the prefill cost of a longer prompt does not masquerade as interference |
| **goodput** | (not yet computed) | Output tokens per second that meet a stated budget. **Not computable here**, because no budget is stated; the curve is what makes it computable later |

---

## 3. Fixed in advance: the resolution, not the answer

Each of these is a choice the implementation would otherwise make silently. That is not hypothetical: reading
4's aggregation was left open in 2026-07-25, the implementation filled it in **two different ways** — a
pooled point estimate beside a per-repetition interval — and the published 23.0x came from the pooled one
under the name of a pre-registered reading.

| # | Fixed | Value |
|---|---|---|
| 1 | **Primary endpoint** | LC tenant TTFT p99, nearest-rank, index `ceil(0.99n)-1` |
| 2 | **Aggregation across repetitions** | The **median of the per-repetition p99s** (`RegisteredEstimandFor`, `internal/bench/estimand.go`). The median of an even count is the **mean of the two central order statistics** |
| 3 | **Reported quantity** | **Isolation slowdown**: the LC tail divided by the isolated baseline's LC tail at the same prompt length. Raw milliseconds are published beside it, never instead of it |
| 4 | **Population** | Completed LC requests, published **with** `offered` and the non-overlapping exclusion classes (`timed_out`, `rejected`, `failed`) per repetition, which `hack/test/check-published-spreads.sh` now requires and recomputes from the raw rows |
| 5 | **Secondary endpoints** | LC TTFT p50/p95, LC TPOT p99, BE completed output tokens per second, BE completion count, total output tokens per second |
| 6 | **Collected while the card exists** | Driver version, GPU UUID, resident compute processes at every cell boundary (`nvidia-smi --query-compute-apps`), and each engine's own `non-default args` line |
| 7 | **Report shape** | Magnitudes and ordering per load point and per prompt length. **No verdict word.** "The planned comparison could not be obtained" is a registered outcome, not a gap |
| 8 | **Request-termination policy** | **Both levels inherit `TimeoutMs: 60000`**, and the reason is not that 60 s is sufficient — it is that the two lengths are compared **under one request-termination policy**. If the registered censoring or sample conditions refuse the estimand at either level, that comparison is reported as **not estimable**, with the per-repetition `offered / completed / timed_out / rejected / failed` counts and the refusal's own reason beside it, and it is **not** read as evidence that a multiple was or was not crossed. Four measured facts are part of this choice and bound how it may be described: ⑴ `TimeoutMs` bounds the **whole request**, not TTFT — `internal/bench/httpsender_test.go` pins that a response which starts in time and then stalls also expires, *with a first token already stamped* — so censoring may never be read as "TTFT ≥ 60 s"; ⑵ the censoring threshold is **1% or more** (`report.go`'s `>= 0.01`) and `censored()` is `Censored \|\| AnyRepetitionCensored`, so **one censored repetition refuses the estimand** even when the pool is clean; ⑶ raising the harness timeout would not widen the observable range on its own, because the gateway bounds the wait for upstream response headers separately at `defaultResponseHeaderTimeout = 30 * time.Second` and deliberately sets no overall timeout; ⑷ the timeout is **not inert** at the level that never reaches it — `PoolSizeForTrace` sizes the idle connection pool as `ceil(rate × timeout_seconds)`, so two different timeouts mean two different clients. A longer **common** timeout for both levels remains a defensible design, but it is a candidate this page does not take, and the reason is a measured cost rather than a preference: the gateway's header bound is **not configurable**. `newTransport` takes a `responseHeaderTimeout` and falls back to the 30-second constant when it is zero, `internal/gateway/server.go` holds the field — and **nothing anywhere assigns it**, so it is always zero and the constant always applies. Raising the observable range therefore means changing gateway code, not a setting, and the idle pool would move for both levels at once |

### 3a. The refusals that come with the estimand, registered rather than discovered

`RegisteredEstimandFor` does not always return a number, and the conditions are part of the registration
because otherwise the choice between "report the conditional statistic" and "exclude it, the function
refused" is available **after** seeing the result:

| Condition | What the code does | Why |
|---|---|---|
| Either configuration's tail is **censored** | refuses, naming the arm | A censored tail makes every statistic of that arm a lower bound, including the per-repetition counts a sample floor would read |
| `TailSampleSize < 100` | refuses, naming the count | Below 100 completions the nearest-rank index lands on the maximum, so the "p99" is the slowest surviving request. 100 is the smallest integer for which `ceil(0.99n)-1 < n-1` |
| Any single repetition's LC completions `< 100` | refuses | The pooled floor passes while one repetition is thin, and the per-repetition medians are exactly where that repetition lands |
| The two configurations have **different repetition counts** | refuses rather than truncating | A median over five repetitions against one over four is a ratio of two different repetition sets |

A refusal is a registered outcome of this study. It is **not** a reason to fall back to a pooled statistic.

### 3b. Stopping, with the loophole named

The deadline is **wall clock from the first billable second to teardown**, and two things about the current
runner are recorded here because they are where an extension would enter:

- `hack/m5c-matrix.sh` stops on a cell boundary when the projected remaining time exceeds the deadline, and
  the comment beside that message **names the knob that extends it**.
- `hack/m5c-gpu-session.sh` computes `DEADLINE_EPOCH` from `date +%s` **inside the instance**, i.e. from when
  user-data runs, not from launch.

**Registered: the budget is for this exploration as a whole, not per instance.** A run that stops incomplete
and is relaunched spends the same budget twice, and each launch would individually respect the limit. A dated
amendment may not retroactively widen the budget or the population of a run whose results have been seen.

---

## 4. What this cannot establish, written before any result exists

- A crossing load measured at two prompt lengths is a statement about **those two conditions**, not about
  prompt length in general.
- No crossing observed is **not** evidence that none exists, and it is **not** evidence of equivalence
  between the conditions measured.
- The axis is **characters**; the engine's token count is a different quantity. This repository has already
  published a prefill multiple from the estimator that overstated the measured one (5.9x against 3.8x). Both
  the declared characters and the engine-reported tokens are published for every level, and any claim about
  "length" is scoped to the generation rule that produced those prompts.
- **An ordering among completed requests is not an ordering of request experience.** A configuration whose
  slow requests failed more often looks better in a completed-only statistic. Publishing the exclusion
  classes describes that selection; it does not remove it.
- **An observed crossing is not a stable one.** Repetition-to-repetition variation and estimator uncertainty
  remain, and this page registers no interval.
- **A crossing is published as a BAND, never as a point.** If the multiple is below one measured load and
  above the next, what the evidence supports is "between those two loads". Interpolating a crossing value
  would assume monotonicity this design does not test.
- **The slowdown's denominator moves with the level.** A longer LC prompt raises the isolated baseline too,
  so the same absolute added delay yields a *smaller* multiple. Dividing by each length's own baseline is
  necessary and it does not remove the length effect or isolate the interference mechanism. `shared p99
  minus isolated p99` is therefore published beside the multiple — as an arm-level difference of
  statistics, not as any individual request's added wait.
- **Nothing here attributes the effect to prefill blocking.** Every sharing configuration also changes
  KV-cache pressure, batching, concurrent execution slots and raw GPU contention. The engines run with
  `--max-num-batched-tokens=2048`, so an 8,192-token prefill is split across iterations rather than
  occupying one non-preemptively, and a claim that a long prefill blocks a short one would need scheduling,
  queue and preemption instrumentation this page does not register.
- **"No crossing observed" and "the estimate was refused" are different outcomes.** Timeouts and failures
  can make a completed-only p99 look better, so the exclusion classes and the estimand's refusals are
  reported before any statement about where the curve went.
- **Uniformity within a configuration is not agreement between configurations.** Reading 4f reports whether
  one arm's rows were generated at one length; it does not check that the arms agree with each other or with
  the registered length.
- A smaller LC tail is **not** a system-wide improvement: BE completion, output throughput and stream latency
  are the trade, and one endpoint cannot judge it.
- Repetitions on one instance do not establish that a differently allocated GPU, engine build or load would
  order the configurations the same way.
- Anything **not collected** while the card existed is a limit on interpretation, not a gap to be filled
  afterwards. A cell-boundary process list does not recover a process that lived briefly inside a cell.

---

## 5. Not registered yet — what must be finished without spending

This page registers a question. It does not authorise a purchase until all of the following are measured
green, and each is a gate rather than a note.

| # | Precondition | Why it is not optional |
|---|---|---|
| 1 | **Per-cell study identity in the runner.** `Study.Frozen` is one `*FrozenTuple` per study, so two prompt lengths are two study ids. Interleaving them inside one instance means the study must travel on the cell spec: **two builders** (`m5c-matrix.sh` matrix and ladder branches), **six parse sites**, plus `refuse_unfrozen_load` and `study-arrivals` which today run once against a global, plus the CR guard and `cmd/benchharness/compileplan.go`'s hard comparison against the 2026-09-10 study | Running the levels as two separate purchases **confounds prompt length with elapsed time and run order** — which is the comparison this page is about. Interleaving within repetition blocks is the only arrangement that separates them |
| 2 | **Mutation runs on that change**, showing that a cell whose declared and measured level disagree is still refused per level | Reading 4e holds the engine's reported counts against one declared tuple. Per-level declarations must keep that check, not widen it |
| 3 | **The new study ids registered**, with the frozen-tuple refusal accepting them and naming the alternatives when it does not | `KnownStudyIDs()` derives from the registry, so one entry covers seven refusal sites — but `cmd/benchharness/compileplan.go` compares against a literal and must be changed too. **That change is blocked on a prior decision, examined on 2026-10-03 and left open deliberately.** The guard's own message says it compiles the weighted arrival model, so the obvious generalisation is to read the registry's arrival model instead of an id. The registry records **no arrival model for the sharing matrix**: `hack/m5c-matrix.sh` hard-codes `ARRIVALS=weighted` on the non-ladder path, and the comment above it says it does so "rather than asking a registry that has no answer for it". `arrivalsOf` refuses an empty one, so the generalisation would refuse the only study the command exists for — and **`TestAStudyWithADifferentArrivalModelIsRefused` would not catch it**, because it asserts only that the error mentions "weighted", which both predicates do. The 2026-09-10 page does not register an arrival model either; its text assumes a weighted mix and its own defect #6 is that no weights were passed. So the order is: decide whether the arrival model is a registered part of the protocol, record it if it is, remove the shell's copy, and only then make the guard read it. A new study id inherits whichever state that decision leaves. **A SECOND thing blocks the entry itself, and it is the timeout.** The two levels differ only in the LC side of the tuple and inherit the other five values, one of which is `TimeoutMs: 60000`. At 8,192 LC input tokens the isolated TTFT is larger by construction, and if that timeout censors the tail at the long level then `RegisteredEstimandFor` **refuses** — its first condition is a censored arm — so the study would be registered with a timeout that makes its own estimand unreportable. Whether 60,000 ms is inherited or raised is therefore a registration decision that the **calibration step's isolated measurement** settles, and until it does, entering the two ids would be writing a value nothing has measured into the registry. What is NOT blocked: `Drift()` compares each side's declared tokens against `resolvedInputLengths`, a code constant that `internal/bench/inputlengths_test.go` holds against `hack/input-length-resolution.json` digit for digit, and both `256 → 1,174` and `8192 → 42,579` are already in it — so neither level will drift when it is entered |
| 4 | **Collection rehearsed on kind**, proving the item-6 fields are actually written | The rehearsal **substitutes the engines and the device plugins**, so it can prove the write path and the failure handling and **cannot** prove that a real driver version or GPU UUID is obtained. A field absent after the instance is gone cannot be added later |
| 5 | **MPS re-tested, or dropped from this page — SATISFIED by the second branch** | D3 sizes this page for `shared` against the isolated baseline alone, so the MPS configuration is **out of scope here** and this precondition is met by exclusion rather than by a test. What must not travel with the exclusion is the wrong sentence about why: MPS's known blocker — the device plugin starting without `--mps-root` — was fixed in `72bfed3` on 2026-09-24, **twelve days after the pilot that hit it**, and has never been retested since. Its state is **"fixed and never retested"**, not "does not engage on this card", and three documents said the second. A later page that wants the MPS configuration inherits that status, not a failure |

## 6. The three decisions this page cannot make for itself

These are not measurements. They are choices about what the exploration is for, and recording them here as
open is the alternative to filling them in and calling the fill a registration.

| | Open decision | What it changes |
|---|---|---|
| **D1 — DECIDED 2026-10-03** | **The second level is the LC tenant at 8,192 input tokens (42,579 characters)**, beside the registered 256 tokens (1,174 characters) | **The registered purpose of the contrast, stated at the level a mechanism exploration can support and no higher:** *to compare a condition where the two tenants' per-request input lengths differ sharply against one where they are the same.* It does **not** assume that a scheduling mechanism changes at equal length, and this page may not later claim it does. Three things make the pair realisable and the alternative worse: ⑴ `hack/input-length-resolution.json` holds exactly two resolved entries, `256 → 1,174` and `8192 → 42,579`, so **both levels are already resolved and freezable with no new resolution work**; ⑵ at 200 characters the tokenizer calibration measures **68 actual tokens against 50 estimated** — the chat template's fixed overhead of roughly 25 tokens dominates, so a 200-character level would mix a template effect into "length"; ⑶ the earlier 200-vs-1,174 pair cannot serve as precedent at all, because `docs/11_WHAT_THIS_MEASURED.md:175` and `2026-07-04-gpusharingbenchmark-crd-design.md:721` both record that **the prompt length, the repetition count and the timeout all changed between those two runs**. **The rejected rationale is recorded too:** an earlier draft argued that 1:32 → 1:1 crosses a transition in head-of-line blocking. An independent review rejected it and the arithmetic confirms the rejection — the past run offered 4,655 LC and 139 BE requests, so the **total** input tokens were 1,191,680 against 1,138,688, i.e. **1.0465 : 1 already**, while the per-request ratio was 1:32. Equal per-request length is not a transition point in total prefill work, and the engine's `--max-num-batched-tokens=2048` means an 8,192-token prefill does not occupy one iteration anyway |
| **D2** | **The contending-load points to sweep**, and what is held fixed while they move | **CORRECTED 2026-10-03.** An earlier version of this row said "no archive records the value previous runs used", and that was **false**: the ten-cell archive's own `user-data.sh` carries `RATE="9.4045"`, and the tuple is recorded in tracked documents — `docs/12_EVIDENCE_CHECKSUMS.md:251` prints `RATE=9.4045`, weights `1 / 0.0260 / 0`, `DURATION_MS=505000` **and** seed 11; `2026-09-10-does-splitting-the-card-buy-protection.md:518` prints the same four load variables as the command that was run, without the seed. (A paid-session runbook prints it too and says it was read back from that archive rather than retyped from prose, but `.gitignore` keeps that file local, so it is named here as prose and not as a path a reader could open.) What is true is narrower and still binding: **a recorded operating value is not evidence that it is the right load for these two lengths.** The decision is also not "pick a RATE" — the question holds the LC arrival rate fixed and sweeps the BE one, so under the weighted arrival model the three load points are `RATE = λL + λB`, `PREMIUM_WEIGHT = 1`, `NOISY_WEIGHT = λB / λL`, `PROBE_WEIGHT = 0`. Changing `RATE` alone moves both tenants. **Registered limit:** that translation preserves only the *expected* arrival rate — the weighted generator draws from one stream, so changing the BE setting changes the LC arrival times too. Either this page records "same LC rate, different LC trace" as a limitation, or the arrival model is changed and re-registered. **What is fixed before buying is the rule, not the numbers**: a short calibration measures the isolated baseline at both lengths and a BE-only run on the same card, the sweep then steps the BE load until the crossing band and the backlog band are bracketed, and calibration evidence is reported separately from measurement evidence |
| **D3 — DECIDED 2026-10-04** | **Which configurations to include, and the budget** | The sizing below was **approved on 2026-10-04**. What was approved is the **sizing**, not a launch: this page still requires preconditions 1, 2 and 3 to be green, and the paid run needs its own explicit approval at the time it is started. **The axis to cut is the number of sharing configurations, not the load resolution.** The question is whether the contending-load curve depends on the LC prompt length; ranking the sharing mechanisms against each other is a different axis, and `timeSlicing` is already 3.7x worse than `shared` at the one load measured. So this page sizes for **`shared` alone against the isolated baseline**: `shared` 2 lengths × 3 BE loads × 2 repetitions = 12 cells, plus the isolated baseline 2 lengths × 2 repetitions = 4 cells, **16 cells = 185.76 min at the observed 11.61 min/cell mean**, leaving **94.24 min** of the 280-minute window for calibration, preparation, transitions, failure handling and teardown. **An earlier version of this row sized 36 cells and forgot the baseline cells entirely** — with them the same design is 42 cells and 487.62 min. Two caveats that are part of the registration: 11.61 min/cell is a mean from 1,174-character cells and is **not** a bound at 42,579; and **2 repetitions is an exploratory compromise, not a precision claim** — this page registers no interval and may not present one |

Until D1-D3 are decided and preconditions 1-5 are green, this page is a registered question and not a
purchase.
