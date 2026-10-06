# Where the late prefill waits — a step-boundary session, registered

Date: 2026-10-06 · **Draft until the freezing amendment at the end.** Frozen by a commit named in that amendment, before any cell is bought, and changed after it only by dated amendments. **Nothing is bought without the user's approval of the purchase.**

**Why it exists.**
- The logged-engine pilot (`2026-10-06-a-timing-family-for-the-logged-synchronous-engine.md`) failed. Every staggered late prefill's client TTFT exceeded the model's account of its own steps by at least 11.1 ms (11.3 ms under the other convention). The archive could not say why.
- `2026-10-06-step-boundary-instrumentation-built-and-parked.md` built and CPU-validated an instrument that can, and parked it until a decision depended on it. One now does: the owner wants M5-b's successor pursued, and its feasibility check needs a step-time model of mixed prefill and decode.
- This page is that decision's measurement. It was designed by me and, independently, by codex `gpt-6-astra`, and narrowed after astra's review of my reduced design.

**What it is not.** It re-asks nothing that failed. The instrument-validation I1 stays failed, the logged-engine pilot stays failed, and M5-b stays closed. This is a new instrument on a new target.

## 1. The system and the instrument

The engine is instrument session 5's: vLLM v0.27.1 at the pinned digest, Qwen2.5-3B-Instruct at the pinned revision, one A10G (g5.2xlarge), a 2,048-token batch budget, 64 sequences, `--no-async-scheduling`, `--enable-logging-iteration-details`, prefix caching off.

**The instrument** is `hack/vllm-plugins/step_logging_scheduler.py`, loaded with `--scheduler-cls`. It records:
- each request's arrival in the scheduler (A);
- each step's scheduling entry and exit (t0, t1), the requests scheduled with their tokens, and their computed tokens before the step;
- the entry and exit of the scheduler's update (t2, t3);
- its own cost per record.

It does no I/O while the engine is busy. After a drain it hands the records to a writer thread and records that write's start and end. Every request carries `X-Request-Id <cell>-<rep>-<phase>-<nonce>-<index>`, which vLLM makes its engine id, so client and engine rows join on it.

**Target, declared before the data.** The staggered results concern **the instrumented engine**. Whether they transfer to the uninstrumented engine is not tested here, and nothing below may claim it.

## 2. Cells

Six blocks. Arms:
- `serial-log` and `serial-step` in blocks 1–3;
- `burst-log` and `burst-step` in blocks 1–6;
- `stagger-step` in blocks 1–3.

`-step` is `-log` with the instrument. That makes 27 cells: 6 serial, 12 burst and 3 staggered.

The traces are study s4's episode design with fresh seeds. The order inside a block is the sha256 hash order, except that block 1 starts with the staggered cell, as in session 5.

**Expected:** session 5's per-type cell times (755, 592 and 3,017 s) give 4,530 + 7,104 + 9,051 = 20,685 s, 5.75 h, plus bring-up. The deadline, backstop and dollar bound are fixed in the freezing amendment, from the matrix's own projection.

## 3. Gates, in order; each refuses

1. **Archive** (`instrument_gates.check_archive`): every measured and warm-up trace is the registered matrix; provenance holds; and W, S and I2 hold as in session 5.
2. **Instrument** (`check_step_log.py`, per `-step` cell):
   - one-to-one with the engine's Iteration lines, with equal tokens at every step;
   - every request joined by id, and scheduled prompt + output − 1 tokens;
   - no overflow, the log ending on a flush, and every write ending before the next request arrived;
   - the instrument's own cost at most 1% of each step's occupancy (t0 to t3).
3. **Overhead, equivalence where it can be powered:**
   - Serial: each setting's median TTFT and median ITL.
   - Burst: each episode type's mean TTFT, maximum TTFT and mean ITL, as episode means.
   - Each endpoint's paired-block 95% t-interval of log(step / log) must lie inside log(0.95) to log(1.05).
   - Planning power, from session 5's block SDs (astra's estimate, conditional, not guaranteed): above 99% for serial at 3 pairs and burst at 6 pairs.
   - **This gate covers serial and burst only.** A cross-type comparison of the self-timed cost is published, and it gates nothing.

## 4. Questions, with predictions written before the data

For each staggered late prefill:
- S is the client send;
- A is its arrival in the scheduler;
- F is the t0 of the first step that schedules it;
- O is the t3 of the step that completes its prompt;
- C is its first content at the client.

Each is a monotonic or anchored stamp. Client closure must hold: (A − S) + (F − A) + (O − F) + (C − O) equals the client-measured C − S, within the stamps' recorded bracket uncertainty, for every episode. That is a consistency check, not an attribution.

- **Q1, waiting.** Prediction: for the four short-prefill settings (256-token prefill), the mean of F − A is at least half of the mean residual the logged-engine pilot left, on the corresponding settings and convention. Measured in ms with an episode bootstrap. F − A is the wait that happens after the request reaches the scheduler; wait before that sits in A − S and is reported, not attributed.
- **Q2, own steps.** Prediction: for the long-prefill settings (8,192-token prefill), the frozen family's error on the late prefill's own steps stays above 10% once waiting is removed.
- **Q3, the family on measured occupancy.**
  - The family is `c + f(P) + d1·n + d2·n² + m·P·n + h·Σpᵢ·Cᵢ + k·K_d`, with nonnegative coefficients, knots 0/256/512/1,024/2,048, and `k` always in.
  - It is fitted to each `-step` step's measured occupancy, t0 to t3, with no clock correction.
  - It trains on serial and burst `-step` episodes, holds out by the 2026-10-05 rule, and never trains on staggered episodes.
  - It passes if every held-out and staggered setting's mean error is within 10% in each phase (context, decode, late prefill), with full rank and a condition number of at most 100.

Q1 and Q2 are answered whatever Q3 says. Q3's pass is what the M5-b successor's feasibility check would rest on.

## 5. Stopping

- **One session and one analysis at the frozen commit.** There is no extension, and no re-purchase toward a pass.
- If gate 1 or 2 refuses, nothing past it is read.
- If gate 3 fails or is inconclusive, Q1–Q3 are still reported for the instrumented engine, and its overhead stays unestablished.
- An incomplete session is a refusal.

## 6. What a result licenses

**May license:**
- serial and burst equivalence of the instrument on the registered endpoints;
- a measured decomposition of the staggered late prefill's TTFT, for the instrumented engine;
- held-out prediction of measured occupancy at this configuration.

**Must refuse:**
- staggered on/off equivalence;
- a total overhead bound inferred from self-timing;
- a causal attribution of A − S or C − O beyond their coarse definitions;
- anything about async engines, other budgets (512 included), models or cards;
- any protection claim.
