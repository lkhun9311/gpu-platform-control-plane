# A timing family for the logged synchronous engine — a registration

Date: 2026-10-06 · **Frozen by the amendment at the end of this page, before the pilot of section 5 was run,** and changed after that only by dated amendments. **No card is bought by this page until section 6's condition is met and the user approves the purchase.**

**Why it exists.** The instrument-validation study (`2026-10-05-can-the-stock-engine-time-an-iteration-instrument-validation.md` and its sessions) asked whether the stock engine's iteration log times an iteration **of the engine that runs without it**. Its I1 gate failed in session 5 and stays failed (`2026-10-06-instrument-validation-session-5.md`). No session 6 is bought, and nothing here re-asks that question.

This page asks a different one: whether a step-time model can be fitted for **the engine with the log on**, treated as the system itself. Then logging is part of what is predicted rather than a confound, and I1 is not a validity gate. That is a change of target, decided after I1 failed, so it is stated as one. It licenses nothing about the engine without the log.

**Removing I1 repairs nothing else.** The fit's target for a step is the log's `elapsed_ms` plus an omitted time the instrument study measured only for one request at a time (`true_ms` in `timing_fit.py`). For batched and mixed steps that correction is an assumption, not a measurement, and session 5's logged cells hold 949 burst and 2,706 staggered mixed steps (codex `gpt-6-astra`'s count). Section 3 adds a check against a clock the log does not set, so that a pass is not only agreement with the correction it was fitted to.

## 1. The system

vLLM v0.27.1 (the pinned digest of the instrument sessions), Qwen2.5-3B-Instruct at the pinned revision, one A10G (g5.2xlarge), `--max-num-batched-tokens=2048`, `--max-num-seqs=64`, **`--no-async-scheduling` and `--enable-logging-iteration-details`**, everything else as in instrument session 5.

**What this configuration is known to cost, descriptively.**
- In session 1's first block, one cell each, the synchronous unlogged engine's inter-token time sat above the async engine's by a median of 8.04, 6.78 and 6.08 log-points across serial, burst and staggered settings. Its TTFT moved by medians of +0.25, +1.46 and +1.12.
- In session 5, turning the log on moved the three-block mean of serial median TTFT by at most 0.44 log-points and of inter-token time by at most 0.57. Single blocks reach 0.73 and 0.93.

These are historical comparisons on single cells or three blocks, not a measured cost for a controller. A controller relying on this model must run its engines in this configuration; whether that is worth it is outside this page.

## 2. The family, unchanged except for one term

The family, the training and held-out split and the two clock conventions are those of `2026-10-05-a-timing-family-fitted-from-the-iteration-log.md` and its 2026-10-05 amendments:

- Step time `c + f(P) + d1·n + d2·n² + m·P·n + h·Σpᵢ·Cᵢ + k·K_d`, nonnegative coefficients, equal weight per setting.
- Trained on serial and burst training episodes. Staggered episodes are never trained on.
- **The context term `k·K_d` is included unconditionally.** The inherited rule included it if I4 exceeded 5%, but I4 is computed over every burst episode, held-out ones included, so held-out outcomes would choose the model's structure (found by astra). Session 5's I4 was +5.0, +15.6 and +55.3% at 1, 4 and 16 decoders, which is prior evidence for the confirmatory session and the reason the term is fixed in rather than dropped.
- The fit is run twice, with mixed steps under the frozen context clock and under `b′`. **The two runs fit two different predictors to two different targets.** Their agreement is required (below) but does not show that either measures a mixed step's real duration.

## 3. The verdict

The family **passes** when all of the following hold under **both** mixed-step conventions. If one convention passes and the other fails, the result is **UNRESOLVED**.

1. **Logged step time, held out.** In every held-out setting and every staggered setting, the predicted mean of the convention-corrected step time is within 10% of the observed, separately for context-bearing steps, pure-decode steps and the late prefill's own steps. The design has full rank and a column-normalised condition number of at most 100. (Inherited.)
2. **Whole client TTFT of the late prefill, conditionally.** In every staggered setting and under each convention, the ratio of the arithmetic mean predicted TTFT to the arithmetic mean client-measured TTFT of the late prefill, with the three blocks weighted equally, lies in [0.90, 1.10]. The predicted TTFT is the frozen per-request intercept `a` plus the predicted durations of **the late prompt's own context-bearing steps**. Those steps are chosen by token accounting alone: every initial prompt has finished before the late send, and only one new prompt arrives. Block ratios and per-episode residuals in milliseconds are published, because opposite errors can cancel in a mean.

**What item 2 is not.** I first proposed summing the predicted steps from the prefill's send to its first token, as a test of mixed steps against a clock outside the log. astra showed it is not identifiable from the archive. The log has aggregate counts and elapsed times with second-resolution stamps the parser discards, and no request ids or admission times. So which decode step straddled the send, and how much of it remained, cannot be known.

Item 2 is therefore a **conditional prediction of whole client TTFT using reconstructed service steps**. It tests the family, the reconstruction and the transfer of a serial-calibrated `a` to an arrival during decoding, all at once, and it cannot validate mixed-step durations on its own.
- Choosing the steps to match the observed first-token time, or locating boundaries by accumulating corrected durations, would make it outcome-dependent or assume the clock under test. Both are prohibited.
- The 10% is an engineering requirement, not an established measurement tolerance. For (1, 256, 256) the 21 late-prefill TTFTs average 61.91 ms, so the allowance is 6.19 ms, while a median logged pure-decode step there is 14.75 ms (astra's figure). An unattributed boundary step alone would exceed it, so the bound is not widened to absorb one.
- A test of mixed-step durations against an independent clock would need new instrumentation that records execution boundaries and request associations. That is a new measurement registration, not an implementation detail.

**What a pass means:** a predictor of convention-corrected logged step time within 10%, and a conditional prediction of the staggered late prefill's whole client TTFT within 10%, for this configuration, model, card and these settings, on episodes it was not trained on. Both are conditional on the context reconstruction and the clock assumptions. Of session 5's 3,655 mixed steps in logged burst and staggered cells, 396 are late-prefill steps (astra's count), so item 2 says nothing about burst mixing or the staggered decoders' start-up.

**What it does not mean:** that logging is free; anything about the async or unlogged engine; physical per-step costs, since no coefficient is interpreted on its own; anything about other models, cards, budgets or versions; or that an admission rule built on it protects anyone. The simulator study that would ask the last question is its own registration, calibrated computationally before any shared cell is bought.

## 4. Validity gates, stated as the code implements them

The fit is read only if the archive passes these, through **one mandatory path** that `timing_fit.py` cannot bypass:

| Gate | What it checks |
|---|---|
| Design | every measured **and warm-up** trace is the registered matrix, by the Go `matrix-plan-check`; exactly three logged arms in three blocks |
| Provenance | the engine digest, model revision and the two flags recorded for every cell are the ones in section 1 |
| W | the warm-up's two verification requests are within 231 ms ±5% and within 2% of each other |
| S | every staggered episode, warm-up included, is the registered composition |
| I2 | no failed request and no preemption; every serial step attributed to its request; every episode's context tokens reconciled with its requests. Burst and staggered generation tokens are reconciled by the fit's reconstruction, not by I2 |
| I3 | the median of request-relative errors of the frozen clock's TTFT prediction, per serial setting, within ±5% by a bootstrap within fixed blocks; and the decode clock's spread |
| I5 | `|log(last block / first block)|` of each serial setting's median TTFT, logged arm only, at most 0.05 — an actual increase of up to 5.13% passes |
| I1 | **not a gate**; there is no unlogged system to compare against |

## 5. The pilot — free, on session 5, and never the result

Session 5 (hack/m5c-20261005-222736) holds nine logged cells of this design. The fit's verdict has never been computed on any archive. But the data are not fresh: I3 was read on the same serial cells, and this page's change of target was decided after I1 failed on this archive. A fit on it is therefore a **pilot**, published and labelled as such, never the result of this page.

- It is run once, at the freezing commit, under an explicit pilot policy that names that archive. The archive keeps its own study id and is not relabelled.
- **If the pilot fails, is UNRESOLVED or is refused, nothing is bought and this page ends.** A different family, a mixed-step clock, or a repaired gate is a new registration, not a pilot retry.
- If it passes, section 6 may be bought. The pilot's numbers tune nothing in section 6. Its fitted predictor is also frozen, and section 6 publishes how it does on the new cells, as a secondary result with no verdict.

## 6. The confirmatory session — paid, only after a passing pilot and the user's approval

- **Cells.** The three logged arms in three blocks, nine cells, on fresh traces with new seeds and session 5's episode design. A new study id carries it, so the evaluator applies this page's rules and refuses any other.
- **Primary analysis.** Section 3's verdict, **refitted** on the new cells with the inherited held-out split. One analysis at the frozen commit. No extension and no re-purchase on a failure; an incomplete session is a refusal.
- **Order and deadline.** The first staggered cell runs first, as in session 5.
  - Session 5's nine logged cells took 13,092 s (3.64 h), cell overhead included: serial 755–756 s, burst 592 s, staggered 3,016–3,017 s.
  - They exclude a cold first cell. Session 5's cold staggered first cell took 3,252 s against the 2,924 s the projection charges, an overhead of 328 s.
  - The guard then projects `ceil(1.2 × (3×617 + 3×457 + 2×2,924 + 8×328) / 60) = 234` minutes after the first cell. First cell plus remainder is 288 minutes, before launch overhead.
  - A four-hour stop would refuse. The hard stop, backstop, seeds and order are frozen with the rest, from these figures, before purchase.
- **Cost.** About 5 hours at about $0.69/hour spot, about $3.50. The bound is the frozen backstop times the $1.10/hour cap. An estimate, not a quote.

## 7. Who decided what

- The change of target is the user's proposal, made after I1 failed.
- The free pilot and its stopping rule are mine. So was the first form of section 3's item 2, which astra showed unidentifiable; its replacement, its aggregation and its narrowed claim are astra's.
- The following are astra's, from its triage and its review of the first draft, each re-derived by me where it is a number:
  - what the page must freeze;
  - that removing I1 does not repair the mixed-step clock;
  - the I4 leak and the unconditional `k`;
  - the accurate gate descriptions;
  - the deadline arithmetic;
  - the 13,092 s total;
  - the logged-only I5 drift of 0.28 log-points.

## 8. What must exist before this page is frozen

None of this exists yet; each item lands with a test that fails when the item is reverted.

1. A study id and episode design in `internal/bench` for logged-only cells, admitted by `matrix-plan-check` without unlogged pairs, and the matrix and session scripts' study helpers.
2. An evaluator path in `instrument_gates.py` for this study: the gates of section 4 on three logged arms, I5 on the logged arm, no I1, and an explicit pilot policy for session 5's archive. Every earlier study's verdict is byte-identical.
3. One mandatory validation path, used by both the command line and `timing_fit.run_fit`, that runs Design on measured and warm-up traces and checks provenance.
4. In `timing_fit.py`: `k` included unconditionally for this study, section 3's item 2 with its step selection by token accounting, and the stale `UNREGISTERED_S2` output removed for the adopted amendments.
5. Synthetic tests of every refusal, then a kind rehearsal, then a bare codex review of the diff, before the freezing commit.

## Amendment, 2026-10-06 — frozen, before the pilot is run

This page is frozen at the commit that adds this amendment. The pilot of section 5 is run once at that commit, as
`BENCHHARNESS=<cmd/benchharness built at that commit> python3 hack/tail-crossing-model/timing_fit.py hack/m5c-20261005-222736/m5c-run --logged`.
Its output is recorded below, whatever it says.

What section 8 asked for, and where it stands:

| Item | State |
|---|---|
| 1. A logged-only study in `internal/bench` | **Not built, deliberately.** It is needed only by section 6, which is bought only after a passing pilot. Until then `check_archive` refuses a logged-only archive by name (`31b8eb4`). |
| 2. The evaluator's logged-engine policy | `61261cd`: three logged arms, I5 on the logged serial arm, no I1, admitted only for study s4's design, the one session 5 bought. Earlier verdicts are byte-identical. |
| 3. One mandatory validation path | `7133fb0` and `a6eac7f`: `check_archive` regenerates every warm-up trace with `gen-trace --warmup` and compares bytes, checks every measured trace with `matrix-plan-check`, and checks provenance from the manifests and the engine's applied flags. `timing_fit.run_fit` cannot reach the gates under this policy without it. |
| 4. `timing_fit.py` | `a6eac7f`: `k` always in the family, section 3 item 2 as `late_ttft`, and no `UNREGISTERED_S2` output under this policy. |
| 5. Tests and review | Every new refusal has a self-test, and each was shown to fail when its check is removed. A bare `codex review` of the diff found one defect, which `31b8eb4` fixed, and then none. No kind rehearsal: the pilot buys nothing and reads an existing archive. |

**Already known before freezing, so nothing below can be tuned to it.** On session 5's archive, `check_archive(logged=True)` passes: 18 measured traces, 18 warm-up traces regenerated byte for byte, and 9 logged cells with the registered image, revision and flags. W, S, I2, I3 and I5 were read on this archive by session 5 itself; the logged-only I5 drift is 0.28 log-points. **The fit's verdict, its coefficients and its late-prefill ratios have not been computed on any real archive.**

**The pilot reads all 18 traces in the design check,** because session 5 bought paired cells. Only the nine logged cells are fitted or gated.

## Result of the pilot, 2026-10-06 — FAIL under both conventions; nothing is bought and this page ends

Run once at `9a19c8f`, the freezing commit, as the amendment above says. The harness was built at that commit and the tree was clean.

**The archive passed everything before the fit:**
- 18 measured traces were the registered matrix, and 18 warm-up traces regenerated byte for byte.
- 9 logged cells carried the registered image, revision and flags.
- W, S and I2 passed.
- I3: every serial setting's median error is within ±1.9%; the largest single error of 486 requests is 2.9%.
- I5: worst drift 0.28 log-points.

**The fit fails, and both conventions agree, so the verdict is FAIL, not UNRESOLVED.** The design was identified: full rank, condition number 13.7, 37 settings trained, `k` included.

| | Mixed steps under the context clock | Mixed steps under `b′` |
|---|---|---|
| Failing held-out or staggered settings | 11 of 49 (3 burst, 8 staggered, no serial) | 10 of 49 (3 burst, 7 staggered, no serial) |
| Gate lines failed | 21 | 20 |
| Late-prefill client TTFT, predicted / observed | 0.551 to 0.983; 5 of 12 settings within 10% | 0.453 to 0.972; 5 of 12 within 10% |
| Late-prefill residual, predicted − observed | −159.7 to −11.1 ms, median −27.6 | −251.3 to −11.3 ms, median −33.4 |
| Worst step-time misses | decode steps beside 16 decoders at 8,192 tokens +55.0%; the late prefill's own steps at (16, 8,192, 256) −38.7% | the late prefill's own steps at (16, 8,192, 256) −41.0%; 4-request 256-token burst context steps +14.7% |

**What this shows.** A family trained on serial and burst episodes does not predict the staggered mix of a prefill arriving among running decoders, under either way of charging mixed steps.
- Its decode steps beside many long-context decoders are over-predicted.
- The late prefill's own steps, and its whole client TTFT, are under-predicted.
- Every late-prefill residual is negative: in all 12 staggered settings, the late prefill took at least 11 ms longer at the client than the model's account of its own steps.

Why is not established. It is the interval astra showed cannot be identified from the archive: what the late prompt waited for before its first step, and how much of a step in flight remained. Naming a cause from these rows would be choosing one after the result.

**As registered:**
- The pilot is not the result, and section 6 is not bought.
- A different family, a rule or clock for mixed steps, or instrumentation that records step boundaries and request associations is a new registration.
- Neither this page nor its pilot may be re-run toward a pass.

The full output is kept as `data/2026-10-06-logged-engine-pilot.json`.
