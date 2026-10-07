# Where O1 misses: residual tables, registered before they are computed

*Registered 2026-10-07. Stage 1 of a staged approach. Nothing new is fitted and nothing is bought. The script is `hack/tail-crossing-model/operator_residuals.py`.*

## Why

The operator model O1 (`2026-10-07-an-operator-model-with-measured-attention.md`, frozen at `9993d4d`) failed on one setting:
- one 256-token late prefill joining one 256-token decoder;
- under-predicted by 10.7% (45.15 against 40.31 ms).

Every long-context endpoint passed. Before any candidate is added for those 4.8 ms, these tables say where the residual sits. The readings are fixed here.

## What is read

O1's own leave-one-composition-out predictions. Each held-out step is predicted by the fit that never saw its composition, using the frozen code, the kept kernel times and the frozen compositions.

For every measured step:
- its residual, observed minus predicted, in ms and as a fraction of observed;
- its sched, exec and update intervals;
- its total scheduled tokens T, and whether T ≤ 128. 128 tokens is the largest CUDA graph the engine captured. A mixed step above it ran without a graph.

## The tables, and what each reading means

**R-T1. The short late prefills.** The three settings (n, 256, 256) for n ∈ {1, 4, 16}. For each, the late-prefill steps':
- mean residual in ms and in %;
- mean sched + update;
- T.
- *H-shared:* the residual is a mixed-step cost common to all three, and n = 1 failed only because its occupancy is smallest.
  - Standing if the three residuals in ms are within 1.5 ms of one another.
  - Falsified otherwise.
- *H-cpu:* the scheduler's own time. Falsified if sched + update is under 1 ms in all three, as it was before.

**R-T2. Mixed steps by graph eligibility and size.** Mean residual in ms and % for mixed steps:
- with T ≤ 128;
- with T > 128, in bins of predicted occupancy: under 60 ms, 60 to 150 ms, above 150 ms.
- *H-floor:* an eager mixed step pays a fixed host-side cost that the fitted intercept, shared with graph-run steps, under-charges. It shows most where the GPU work is smallest.
  - Standing if the under-60 ms, T > 128 bin has the largest mean residual in % of the three T > 128 bins, that is, it is the most under-predicted. A residual is observed minus predicted, so under-prediction is positive.
  - Falsified otherwise.

**R-T3. Phase summary.** Mean residual in % by exclusive phase, with step counts, so the size of the residual elsewhere is on the record beside the failure.

## What the tables decide

- **Stage 2:** which hypotheses may enter a candidate registration. A falsified one does not.
- **If none stands,** the 4.8 ms is reported as unexplained, and stage 2 is not opened.

Nothing in O1's result changes: it stays FAIL, and the archive stays development data.

**A correction before freezing, and how it was found.** The first draft wrote "the most negative mean residual (that is, under-predicted)". Under this page's own sign convention that contradicts itself. The code tested the stated intent, the largest, that is the most under-predicted.

codex `gpt-6-astra`'s bare review of the draft found the contradiction. To show it, the review ran the script on the archive and reported the three bins' values. So I saw those three numbers before this page was frozen.

The correction only makes the sign match the words "under-predicted" that the draft already had; no threshold or bin moved. That the values were seen is recorded here rather than hidden.

## Result, 2026-10-07 (stage 1)

`operator_residuals.py` at the freezing commit `c57bfe6` was run once. Its output is `data/2026-10-07-o1-residual-tables.txt`.

| Hypothesis | Reading | Verdict |
|---|---|---|
| H-shared | (n, 256, 256) late prefills are under-predicted by +4.846, +4.417 and +4.164 ms at n = 1, 4 and 16 (+10.7%, +9.6%, +8.5%); they lie within 0.681 ms | **standing** |
| H-cpu | sched + update at most 0.365 ms | **falsified** |
| H-floor | mixed steps with T > 128: +8.6% under 60 ms predicted (105 steps), +0.1% at 60–150 ms (119), −1.6% above 150 ms (4,235) | **standing** |

So the 4.8 ms is not a cost peculiar to one decoder. It is a cost every short eager mixed step pays, about 4.2 to 4.8 ms, and n = 1 failed only because its step is the shortest, so the same milliseconds are the largest fraction.

**Outside the registered readings, as an observation for stage 2.** Mixed steps within the captured sizes (T ≤ 128, 138 steps) are over-predicted, by 3.674 ms or 10.8% of their occupancy.

O1 has one mixed-step surcharge, `u`, fitted at 4.32 ms across all mixed steps. The tables read as if two fixed costs were averaged into it:
- a larger one for an eager mixed step (T > 128);
- a smaller one for a mixed step replayed as a piecewise CUDA graph (T ≤ 128).

Which mechanism (graph replay against eager launch) is not established here.

**What stage 2 may register.** H-shared and H-floor stand, so the candidates that may enter are those that give eager and graph-run mixed steps separate fixed costs. H-cpu does not enter. Stage 2 would be the archive's fifth development use. It fits nothing until registered.
