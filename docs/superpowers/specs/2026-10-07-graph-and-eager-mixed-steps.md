# Graph-run and eager mixed steps: stage 2

*Registered 2026-10-07, before either candidate is fitted. Stage 2 of the staged approach; nothing is bought. The script is `hack/tail-crossing-model/step_family_operator2.py`.*

## Why

Stage 1 (`2026-10-07-where-o1-misses-residual-tables.md`) left two hypotheses standing and falsified a third.

| Hypothesis | Verdict |
|---|---|
| H-shared: the short late prefills' miss is a cost common to them, 4.2 to 4.8 ms | standing |
| H-floor: an eager mixed step (T > 128 tokens, outside the captured CUDA graphs) pays a fixed cost that O1 under-charges where its GPU work is smallest | standing |
| H-cpu | falsified |

Outside its readings, stage 1 also found graph-run mixed steps (T ≤ 128) over-predicted by 10.8%. O1's single mixed surcharge `u` looks like an average of two fixed costs.

## The candidates, both of them

Both are O1 with its measured attention at coefficient 1, its loss, folds, bounds, support rule and selection. They are run through `step_family_operator.evaluate_candidate` unchanged.

| | Change to O1's non-attention terms |
|---|---|
| S1 | `u` split into `u_graph · [mixed, T ≤ 128]` and `u_eager · [mixed, T > 128]` |
| S2 | S1, plus `e_prefill · [prefill-only, P > 128]`: the eager fixed cost on a prefill-only step too |

T is the step's scheduled tokens, P + n, and 128 is the largest graph the engine captured (its log, `FULL_AND_PIECEWISE`).

No other candidate is fitted.

## Stopping, and what a selection licenses

- **Runs:** one, at the freezing commit.
- **Selection:** the passing candidate with fewer columns, so S1 before S2.
- **If none passes:** the staged diagnosis stops here. O1 stays the best development result, and nothing is proposed for purchase on this archive.
- **If one passes:** stage 3 may be registered. It freezes that predictor and its kernel-time method and confirms it on fresh cells, without refitting.
  - The kernel times for the fresh cells' compositions would be measured in the same session.
  - It needs its own registration and the owner's approval.

This is the archive's fifth development use. Nothing it gives is a held-out result.
