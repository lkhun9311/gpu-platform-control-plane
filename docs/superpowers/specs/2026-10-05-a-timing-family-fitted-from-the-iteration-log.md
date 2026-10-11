# A timing family fitted from the iteration log — a registration

Date: 2026-10-05 · Registered **while the instrument-validation session hack/m5c-20261005-085339 is still running and before any fitted number exists**; frozen from the moment `hack/tail-crossing-model/timing_fit.py` is first run on that archive, and changed after that only by dated amendments. **No card is bought by this page.**

**Why it exists.** `2026-10-05-can-the-stock-engine-time-an-iteration-instrument-validation.md` says that if its gates I1, I2, I3 and I5 pass, the next registration fits a timing family on held-out episodes. The fit runs on the same archive the gates judge, so every choice that could move its verdict is fixed here, before that archive is complete. The design was made by me and, independently, by codex `gpt-6-astra`, from the fit code's author's six open questions; section 5 records who decided what.

## 1. Prerequisite

`timing_fit.py` calls `instrument_gates.evaluate` on the same directory and refuses unless it passes. A fit on an instrument that failed would be a fit of a quantity nobody established.

## 2. The family

Each logged step's duration is its `elapsed_ms` plus the omitted time the instrument page's section 3 measures:

```
step_ms = c + f(P) + d1·n + d2·n² + m·P·n + h·Σ pᵢ·Cᵢ  [+ k·K_d]
```

- `P`: context tokens scheduled in the step; `n`: generation requests.
- `f`: piecewise linear, knots 0, 256, 512, 1,024 and 2,048, `f(0) = 0`.
- `h·Σ pᵢ·Cᵢ`: a prompt chunk attending over its own earlier chunks — `pᵢ` is request `i`'s prompt tokens in this step and `Cᵢ` its prompt tokens processed before it. **Added before the data, at astra's proposal:** equal `P` cannot tell a prompt's first 2,048-token chunk from its fourth, and adding the term after seeing a failure would be choosing a family by its result.
- `k·K_d`: decoder context, the sum of running decoders' context lengths. **Included if and only if I4 exceeds 5%** for any reported decoder count, computed by `instrument_gates.context_effect` on the same archive. The held-out bound cannot make this choice: in the fit code's self-test a true `k` adding 6.5 ms to a 16 × 8,192 step hid inside an 8.3% held-out error while `d1` doubled.
- All coefficients nonnegative; weighted least squares with equal total weight per setting.

## 3. What is trained on and what is predicted

- **Training:** serial episodes, as homogeneous bursts of one, and burst episodes.
- **Never trained on:** every staggered episode, in both context modes. They are the out-of-sample test of mixing two kinds of work in one step — the thing the queue predictor failed at — and their reconstructed contexts make them conditional on the send-order replay, which the output says.
- **Held out:** in every training setting, one episode per block, the held-out cycle rotating across the three blocks by a permutation drawn per setting from seed 20261005. Six episodes train and three are held out, and every cycle position is on both sides. Exactly nine episodes per setting are required.
- **The clock** — `b` for context steps, `b'` for decode-only steps — is fitted from the serial **training** episodes only, so no held-out client time reaches a training target.

## 4. The verdict

**The family passes** when, in every held-out setting and in every staggered setting, the predicted mean step time is within 10% of the observed, **separately for steps carrying context tokens and for pure-decode steps** — a pooled mean would let opposite errors cancel and let hundreds of decode steps dilute a few prefill steps — and the design is identified: full column rank and a column-normalised condition number of at most 100.

- **Mixed steps** carry `b` by convention. The fit is always run a second time with `b'` on mixed steps, and both verdicts are published. **If they differ, the verdict is "unresolved"**, not whichever passed: neither clock measures a mixed step, and both were measured at one request per step.
- Per-episode and per-block errors are published and gate nothing.
- Coefficients are published with episode-bootstrap 95% intervals (200 resamples of whole episodes within setting, fixed seed) and the list of those pinned at zero. **No coefficient is interpreted on its own.** A pass establishes a predictor of step time for this engine and these settings, not measured physical costs; `m` in particular was poorly recovered in the self-test at 1% noise.

**Pass:** the simulator study is redesigned around this family and calibrated computationally before any shared cell is bought. **Fail or unresolved:** the stock records do not support a step-time model of this engine at 10%; no simulator study is bought on them, and a replacement family is a new registration.

## 5. Who decided what

| Question | Me, before astra | astra | Fixed |
|---|---|---|---|
| Context term | I4 decides | I4 decides, automatically, recorded | I4, automatic |
| Mixed steps | `b` | `b` nominal, `b'` mandatory sensitivity | astra's |
| Hold-out | rotate the held-out cycle by block | the same, with the rotation permuted per setting | astra's |
| Staggered episodes | predicted only, both modes | the same | agreed |
| Earlier-chunk term | none; a failure would be the answer | add `h·Σ pᵢ·Cᵢ` now | **astra's**, for the reason in section 2 |
| Coefficients | report zeros; bootstrap intervals | the same, and require the full nine-episode matrix | astra's |

astra also found three defects in the fit code as written, each adopted: the clock used held-out serial episodes; the check compared pooled means only; and the fit did not require the instrument's verdict. The first two open questions were raised by the fit code's author, a Claude subagent, including the measured case in which the held-out bound misses a context term.

## Amendment, 2026-10-05, before the fit is run — the intervals understate uncertainty

The fit code's self-test at 1% step noise produced a `d1` interval of 0.141 to 0.148 around a true 0.15: six near-identical training episodes per setting make whole-episode resampling too narrow. The intervals are published as episode-resampling intervals, not as calibrated confidence intervals, and nothing in section 4's verdict rests on them. The self-test's real-gate case, which had pinned I1 failing on bursts, now runs the whole path through the real gates to a passing fit.

## Amendment, 2026-10-05 — the fit on session 2, fixed before its data is read

Session 2 (`2026-10-05-instrument-validation-session-2.md`) changes what the fit reads. Decided by me and, independently, by codex `gpt-6-astra`, before any session-2 cell is opened:

- **Hold-out.** A serial setting has six episodes per block in session 2. In block `b` the `b`-th third of a seeded per-setting order is held out — two per block, six of eighteen in all — which is section 3's rule exactly when there are three per block. Every cycle position trains twice and is held out once. Seed, setting representation and permutation are those of `heldout_cycles` in `timing_fit.py` at this amendment.
- **Clock.** A context-bearing step's omitted time is session 2's frozen `b + c·P` (`instrument_gates.CLOCK_B`, `CLOCK_C`); `a` is per request and added to no step; a decode-only step keeps `b'` from the serial training episodes. A refusal for a negative fitted value depends only on the clock actually used.
- **Mixed steps.** The rule stands: the fit runs with the frozen context clock and with `b'` on mixed steps, and a disagreement is UNRESOLVED. The gap between the two conventions is `17.776531 + 0.002620206·P − b'` ms per mixed step — about 17.1 ms at `P` = 256 and 21.8 ms at 2,048 with `b'` near 1.3 — so a disagreement is likely wherever mixed steps carry weight, and that is the honest answer while no clock measures a mixed step. Replacing the rule needs a mixed-step clock established on data the fit is not validated on, registered first.
- **The late prefill is judged on its own.** In a staggered setting the steps that schedule the staggered prefill's own context tokens are gated separately, within 10% under both conventions, besides the per-phase gates; pooled with the decoders' start-up a doubled late-prefill step moved the error by only 0.35%.
