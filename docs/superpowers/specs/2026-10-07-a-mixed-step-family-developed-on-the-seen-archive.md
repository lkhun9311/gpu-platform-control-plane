# A mixed-step family, developed on the seen archive

*Registered 2026-10-07, before any candidate below is fitted. It costs nothing: no card is bought.*
*The evaluator is `hack/tail-crossing-model/step_family_dev.py`; where this page and that file disagree, the page is wrong and is corrected before the run.*

## Why

Item 2 of M5-b's successor ranking, the computational feasibility check, needs a step-time model of mixed steps (`2026-10-06-m5b-stays-closed-and-what-a-successor-needs-first.md`, section 5).

Two attempts failed the same way:
- the logged-engine pilot;
- the step-boundary session's Q3, on measured occupancy.

In both, short late prefills joining running decoders were under-predicted by 21% to 38%, and decode steps beside long-context decoders were over-predicted by up to 55%. The failed family already had an `m·P·n` term and already trained on 1,260 mixed steps, so "add an interaction" is not a diagnosis.

This page develops a replacement on the step-boundary archive. It does not confirm one.

## The data, and its status

- **Archive.** hack/m5c-20261006-133937, the 12 `-step` cells: serial and staggered in blocks 1, 3 and 5, burst in blocks 1 to 6.
- **Population.** It is `step_boundary.episodes_of_cell`'s, as Q3's was:
  - only steps whose requests all belong to one measured episode, so warm-up steps are in none;
  - a step spanning two episodes refuses the cell;
  - a step is late when it schedules a staggered episode's last request.
- **Features and target.** Each step's P, n, K and H are `step_boundary.step_features`' counts. The target is its occupancy, t0 to t3, in ms.
- Counted before anything is fitted: 121,814 steps, 49 settings, 120 (setting, phase) endpoints.
- **The archive is development data.** It has been seen, Q3's held-out status is spent, and no result here is a held-out pass.
- Any predictor this page selects must be frozen and confirmed on data bought after the freeze, without refitting (section 6).

## The candidates, all of them

The family's pieces are as registered before: knots 0/256/512/1,024/2,048 for f(P), nonnegative coefficients, and the column-normalised design with a condition limit of 100.

| | Columns | Why |
|---|---|---|
| A | the registered family: `c + f(P) + d1·n + d2·n² + m·P·n + h·H + k·K` | the reference |
| B | A with `k·K` split into `k_pure·K·[P=0] + k_mixed·K·[P>0]`, plus `u·[P>0, n>0]` | a decoder's context may cost differently when its step also runs a prefill, and a mixed step may carry a fixed surcharge |
| C | B plus `e·n·[P>0]` | the surcharge may grow with the decoders the prefill joins |
| D | a table over bins of (P, n, K/n) | a non-parametric baseline |

D's bins are intervals on the real line, so every step falls in exactly one:
- P: {0}, (0, 256], (256, 512], (512, 1,024], (1,024, 2,048];
- n: {0}, {1}, (1, 4], (4, 16], (16, 64];
- K/n: {0}, (0, 1,024], (1,024, 4,096], above 4,096.

K/n is taken as 0 when n = 0, so every prefill-only step is in the first K/n bin.
- A bin's value is the minimiser of the same loss as B and C (section 4): v = Σ(w/o) / Σ(w/o²) over its training steps.
- A bin with fewer than 5 training steps is unsupported.

No other candidate is fitted. A fifth is a new registration.

## The fit

The loss is squared relative error, with equal total weight per (setting, exclusive phase).

The registered family minimised squared milliseconds with equal weight per setting, so its loss differed from its verdict in two ways (found in review):
- a long step's error counted more than a short one's;
- a setting's many pure-decode steps outvoted its few mixed ones.

The verdict judged relative error per phase.

- Each training step's row and target are divided by its observed occupancy.
- The weight w multiplies that step's contribution to the normal equations, as `step_boundary.q3`'s weight did. It is 1 / (the step count of its setting's exclusive phase), so each group's weights sum to one.

The exclusive phases, which carry the training weight:
- **prefill-only**, P > 0 and n = 0;
- **mixed**, P > 0 and n > 0;
- **decode**, P = 0.

**Late-prefill** steps, a staggered episode's late prefill's own steps, are a subset of mixed. They are trained as mixed steps and judged as a fourth endpoint.

## The test: leave one composition out

Holding out blocks would test replication of settings the fit has seen. The question for a simulator is a composition it has not seen.

A fold holds out every setting that offers the engine the same composition:
- a serial request and a one-request burst of the same prompt length are one composition, whatever their output caps;
- a burst of n > 1 is one composition per (n, prompt length), whatever its caps;
- a staggered setting is its own.

This gives the folds `step_family_dev.composition` builds. For each fold:
- fit on every other fold's steps from all blocks;
- predict every held-out setting's steps.

**An endpoint** is one held-out setting's one phase. It fails when either of these holds:
- its mean predicted occupancy is more than ±10% from its mean observed;
- the mean of its steps' |relative error| exceeds 15%.

The second bound exists because a mean can match while every step is wrong: observed 10 and 100 ms, both predicted 55, have an exact mean (found in review).

**Judged:** every endpoint with at least 10 steps.
- The floor was set by counting the archive's endpoints, before any fit.
- At 30 steps, 37 of the 120 were below. That included all six short late prefills, the endpoints this study exists for, at 21 steps each. The test could then neither pass nor judge them.
- At 10 steps, 3 are below, all staggered prefill-only phases of 9 steps.

**Precedence.**
- For D, an endpoint containing a step in an unsupported bin fails, whatever its size.
- For A to C, a fold that refuses (rank, or condition above 100) refuses the candidate.
- Otherwise an endpoint under the floor is published and not judged.

**A candidate passes** when:
- no fold refuses;
- no endpoint fails;
- at most 10% of endpoints are under the floor;
- the all-data fit (section 5) does not refuse.

Published for every candidate, and used by no verdict: the worst endpoint per phase, and the block-wise errors of the late-prefill endpoints.

## Selection and stopping

- Every candidate is fitted and reported, pass or fail.
- **The predictor of a candidate** is its fit on all 49 settings by the same rules, not any fold's fit. A rank or condition refusal of that fit fails the candidate. That fit's coefficients, or for D every supported bin and its value, are printed by the run and are what a confirmation freezes.
- Of the candidates that pass, the one with the fewest columns is selected. D counts as the number of supported bins in its all-data fit. A tie goes to the earlier letter.
- If none passes, this study fails. Item 2 stays closed and no confirmation is proposed on its account.
- One run of the evaluator at the commit that freezes this page. No candidate, threshold, bin, weight or fold rule changes after it runs.

## What a selection licenses, and what it does not

A selected predictor licenses one thing: registering a confirmatory purchase. That registration freezes the predictor and the evaluator, and buys fresh cells.

The smallest purchase that keeps all three regimes and three-block replication is nine cells: `serial-step`, `burst-step` and `stagger-step` × 3 blocks, on fresh registered seeds.
- codex `gpt-6-astra` estimated it at roughly 5–6 instance hours.
- It is bought only with the owner's explicit approval.

It does not license:
- a simulator. Occupancy leaves out the P → A wait and the inter-step gap, and no composed TTFT is tested here;
- any budget, engine build, model or card other than the archive's.

## Who decided what

**From codex `gpt-6-astra`'s independent planning review, 2026-10-07:**
- candidate B;
- the relative loss and the equal weighting;
- the table baseline;
- the nine-cell confirmation shape.

I checked its point about the loss against the code: `step_boundary.q3` weights by `1.0 / len(steps)` per setting.

**From the same model's cold review of this page's first draft.** It found 12 faults. I re-counted the endpoint numbers from the archive (no fit) before changing anything:
- the 30-step floor refused every candidate and exempted the short late prefills;
- the late-prefill phase was in training twice or not at all;
- D's K/n was undefined at n = 0, and the bin mean was not the registered loss;
- the folds left a twin composition in training;
- a mean endpoint passed cancelling errors;
- the frozen predictor and D's size were unspecified;
- the population and the precedence of D's support against the floor were unstated.

**From the same model's bare review of the evaluator before freezing.** I reproduced both in self-tests:
- the worst-endpoint lines were updated outside the phase loop, so only a setting's last phase counted, and a setting with only unsupported endpoints raised instead of failing;
- a selected table was not written out, so it could not have been frozen.

**Mine:**
- candidate C;
- the composition folds;
- the 10-step floor and the 15% step-error bound;
- the 10% unjudged limit;
- the selection rule.

## Result, 2026-10-07 — no candidate passes; item 2 stays closed

`step_family_dev.py` at the freezing commit `d1c66c5` was run once on the archive, on a clean tree, in 4 seconds. It exited 3. Its whole output is kept as `data/2026-10-07-mixed-step-family-development.txt`.

| | Folds refused | Endpoints judged | Failing | Worst late-prefill | Verdict |
|---|---:|---:|---:|---:|---|
| A, the registered family | 0 | 117 | 10 | (16, 8,192, 256) −50.6% | FAIL |
| B, split context cost and a mixed surcharge | 0 | 117 | 6 | (1, 8,192, 256) −20.3% | FAIL |
| C, B and a per-decoder surcharge | 0 | 117 | 6 | (1, 8,192, 256) −20.3% | FAIL |
| D, the table | 0 | 109 | 32 | (1, 8,192, 256) −45.4% | FAIL |

28 folds over 49 settings. 3 endpoints of 120 are under the 10-step floor (2.5%), and none of them decided a verdict.

**SELECTED: none.** By section 5, this study fails, item 2 of the successor ranking stays closed, and no confirmatory purchase is proposed on its account.

What the run shows, without a claim about why:
- **B and C halve the failure, but not to 10%.**
  - B's failures are the three 512-token serial prefills (−13.3%) and three short-late-prefill endpoints: (1, 8,192, 256) mixed and late-prefill at −20.3%, and (16, 8,192, 256) late-prefill at −18.0%.
  - A's ten failures include all six short late prefills, at −17.1% to −50.6%.
- **C's added column changed no printed endpoint.** Its worst lines and failures equal B's to the printed precision.
- **The misses are systematic, not noise.** Every late-prefill endpoint's three block errors agree to within 0.1 percentage points; for example B's (1, 8,192, 256) is −20.3%, −20.3% and −20.4%. More blocks of the same cells would not move these numbers; a different family would have to.
- **D's table fails most:**
  - it cannot reach several held-out compositions at all (unsupported bins in 7 endpoints);
  - it misses others by up to 45%.

What would change this:
- another candidate family, which is a new registration on data this page has now also used;
- or a decision that the successor's feasibility does not need a per-step model, which is a decision for the owner, not a result.
