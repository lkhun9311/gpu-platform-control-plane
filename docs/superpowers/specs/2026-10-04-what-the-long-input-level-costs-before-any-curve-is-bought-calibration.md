# What the long input level costs, before any curve is bought — calibration registration

**Registered 2026-10-04.** This page is frozen from the moment the first cell of this calibration is
purchased. Changes after that are appended as dated amendments and never edited in place.

**This page does not authorise a purchase.** It describes one, in enough detail that buying it is a decision
someone can refuse. The run starts only on an explicit approval given at the time it is started.

## 1. Why a calibration exists at all

The exploratory registration of 2026-10-03 asks where the latency-critical tail crosses each multiple of its
isolated baseline, at two input levels. It cannot be sized, because three of its own numbers are unmeasured:

| Unknown | Why the curve cannot be designed without it |
|---|---|
| The **isolated TTFT p99 at 8,192 LC input tokens** | Every multiple in the question is a multiple OF this number. Without it there is no denominator and no way to say which contending loads to sweep |
| Whether the inherited **60,000 ms timeout censors that tail** | `RegisteredEstimandFor`'s first condition is a censored arm. If the long level censors, the estimand is refused and the whole curve is unreportable — which is a thing to discover for one cell, not sixteen |
| How long a cell **takes at 42,579 characters** | The budget rests on 11.61 min/cell, measured entirely at 1,174 characters. A 32x longer prompt is not promised to cost the same |

So this calibration is not a smaller version of that experiment. It is the measurement that decides whether
that experiment is buyable and at what size.

## 2. What is bought

**One input level, two arms, two repetitions. Four cells.**

| | |
|---|---|
| Study | `tail-crossing-lc8192-2026-10-04` |
| Arms | `R1` and `shared` |
| Repetitions | 2, per `Study.MinRepetitions` for this study |
| Level | LC and BE both at 8,192 input tokens (42,579 characters), the study's frozen tuple |
| Timeout | 60,000 ms, inherited — **this calibration exists partly to test that inheritance** |
| Output caps | 64 premium, 16 contender, frozen |

**Why `shared` is bought and not only `R1`.** The honest reason first: `MatrixPlanArmSetRefusal` requires
both arms and refuses a plan without them — measured 2026-10-04, `ARMS=R1` is rejected with "the planned
arms (R1) do not include shared … the readings call a run without it INVALID". That is a **constraint of the
tool, not a requirement of this design**, and astra's standing correction applies: the harness demanding R1
is not evidence that R1 is experimentally necessary. The decision recorded here is to pay the constraint
rather than relax it, for two reasons that are about this run and not about the tool:

- Relaxing a pre-purchase guard immediately before a purchase, to make that purchase possible, is the shape
  this project has been burned by. A calibration-only exception would need its own proof that it cannot leak
  into the measurement run, and that proof costs more than the two cells.
- The `shared` cells are **not waste**. At this level they are the contended condition at one load, which is
  the first point of the very curve the next run is for.

## 3. The load, and the arithmetic that chose it

This is the decision most likely to waste the run, so the reasoning is written out rather than asserted.

**The failure to avoid:** keeping the LC arrival rate the sharing matrix used (9.166 req/s) would offer, at
8,192 tokens, **32x the prefill token rate** the card has ever sustained. The isolated baseline would be
saturated from the first second, and the number it produced would describe a queue rather than a baseline.

**The one prefill rate this card is measured to sustain** comes from the fifteen-cell run
`m5c-20261002-014903`: 9.166179 LC req/s at 256 input tokens, which is **2,347 prefill tokens/s**, with an
isolated TTFT p99 of 174.268 ms. That is the anchor — not a model of the card, but the single operating
point where it is known to have kept a tail.

Holding that token rate and changing only the length gives **λ_LC = 2347 / 8192 = 0.2864 req/s**.

| Registered | Value |
|---|---|
| `RATE` (total) | **0.2939** = λ_LC × 1.026 |
| `PREMIUM_WEIGHT` / `NOISY_WEIGHT` / `PROBE_WEIGHT` | 1 / 0.026 / 0 — the registered weighted mix, unchanged |
| `DURATION_MS` | **600000** |
| Offers per cell | **176 LC**, measured by the planner, against a floor of 100 |

⚠️ **What this choice is NOT.** Equal prefill token rate is an assumption of linearity that this project has
not measured and this page does not claim. It is chosen because it is the only extrapolation anchored to an
operating point the card demonstrably held, and because being wrong in the conservative direction costs an
under-loaded baseline — a readable number — while being wrong the other way costs a saturated one. **If the
isolated tail comes back censored or far above 174 ms, that is a result of this calibration, not a failure
of it.**

**The planner does not check this.** Measured 2026-10-04: five candidate loads from 0.2939 to 9.4045 all
returned `PLAN OK` with 176 to 5,513 offers. The plan check asks whether a cell is scorable, never whether
the card can serve it. Choosing this number is the registration's job and nothing downstream will catch a
bad choice.

## 4. Budget, from the measured decomposition

The 11.61 min/cell mean decomposes against its own run: 505 s of replay plus **191.6 s (3.19 min) of
per-cell overhead** — rollout, device waits, teardown.

| | |
|---|---:|
| Cell at `DURATION_MS=600000` | 791.6 s = **13.19 min** |
| Four cells | **52.77 min** |
| Instance cost at the $0.70/h the measured runs imply | **about $0.62** |
| First cell, cold (weights download) | the archives measure **+4.2 min** over steady |

**The stopping rule is not a formality here.** After cell 1 the runner projects the remaining three at the
observed mean × 1.2 — about 47.5 min — and stops on a boundary if that reaches the deadline. A deadline
below roughly 65 minutes will stop this run short, and that is a parameter to set deliberately rather than
discover.

## 5. The three-way outcome, fixed before the run

Every outcome below is a result. None of them is a reason to re-run at a different load and report the
second attempt.

| Outcome | What it means | What it changes |
|---|---|---|
| **A measurement** — the isolated tail is uncensored, its per-repetition p99s are reported with their sample sizes | The long level is measurable at this load | The curve's denominator is known; the measurement run is sized against the cell time this run measured |
| **Censoring found** — any repetition of either arm is censored at 1% or more | The inherited 60 s timeout cannot express this level's tail | The curve is **not bought** until the timeout is re-registered. Raising it is a registration decision with a measured cost: the gateway's own 30 s response-header bound is not configurable, so the observable range does not widen by a setting alone |
| **Judgment insufficient** — fewer than 100 completed LC requests in any repetition, or the run stops before both arms have two repetitions | This calibration did not answer its question | Nothing about the long level is concluded. The next step is a differently sized calibration, named as such |

**This calibration's evidence is never pooled with the measurement run's.** Different study id, different
load, different purpose. It may be cited as the reason a value was chosen; it may not be cited as a
measurement of the curve.

## 6. What this cannot establish

- **It is one load point.** It says what the isolated tail is at 0.2864 LC req/s and what one contended
  condition did there. It says nothing about the shape of anything.
- **It cannot separate length from rate.** The short level ran at 9.166 req/s and this runs at 0.2864; the
  two differ in both, by construction, because holding the rate is what saturates. Any comparison with the
  256-token baseline is a comparison of two operating points, not of two lengths.
- **A BE arm at one load is not BE capacity**, which astra's review already established for the sweep and
  applies here unchanged.
- **The first cell is cold.** Its elapsed time includes the weight download and must not be read as the
  steady-state cell cost the measurement run would be sized against.
- **Two repetitions support no interval.** `Study.PublishesInterval` is false for this study and this page
  presents none.

## 7. Preconditions — what must be green before the first cell

| # | Precondition | State on 2026-10-04 |
|---|---|---|
| 1 | The runner plans under the study it was asked for, and says which | **MET** — `2c9cc74`, with the allow-list ahead of the load guards and the study named in both the comparison and the verdict |
| 2 | Each completed cell's evidence leaves the instance as the cell completes, not at the end | **MET** — the cell hook now carries the manifest, trace, port-forward log and the run records, and names what failed to go up |
| 3 | A stream that stopped arriving is not counted as a completion | **MET** — `StreamTerminated` and `StreamError` reach the row and survive the file |
| 4 | The session's completion check sees a missing repetition and an arm whose every row expired | **MET** — the check compares against `REPS` and counts completions as rows with no `errorKind` |
| 5 | The kind rehearsal drives the real matrix end to end | **NOT MET** — it has failed at cell 2 since 2026-10-03 and the cause is unidentified. **This calibration is bought anyway, and the reason is written here rather than left implicit:** the failure needs a second cell to appear, this run has four, and the four P1 items above are what protect the evidence if it happens. A measurement run of sixteen cells is NOT bought until the rehearsal passes |

## 8. The approval this page does not carry

The design in this page was approved on 2026-10-04 — one level, two arms, two repetitions, four cells, at
the load in section 3. **That approval is of the design.** The purchase itself needs its own approval at the
time it is started, and nothing in this page, and no engine's recommendation, substitutes for it.
