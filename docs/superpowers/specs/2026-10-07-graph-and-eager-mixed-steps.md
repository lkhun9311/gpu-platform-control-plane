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

## Result, 2026-10-07 — S1 passes

`step_family_operator2.py` at the freezing commit `b57c104` was run once, on a clean tree. It exited 0. Its output is `data/2026-10-07-stage2-graph-and-eager.txt`.

| | Judged | Failing | Refused folds | Worst late-prefill | Worst decode | Worst prefill-only | Verdict |
|---|---:|---:|---:|---:|---:|---:|---|
| S1 | 114 | 0 | 0 | (1, 256, 256) −4.3% | (4, 256, 8,192) −3.7% | (256, 16) +3.6% | **PASS** |
| S2 | 108 | 0 | 2 (condition 125.6 and 104.6) | −4.3% | −3.7% | +3.6% | FAIL |

**SELECTED: S1.** Six endpoints are not judged (5.0%): the three 512-token serial endpoints, which are unsupported, and three under the 10-step floor.

S1's all-data predictor, the one a confirmation would freeze:
- **Fitted non-attention terms:** c 15.4473; f slopes 0.0786395, 0.0897957, 0.0958142 and 0.0937947 ms per token on the four knot segments; d1 0.111382; d2 0; u_graph 1.46159; u_eager 7.28906.
- **Attention:** 36 layers × the measured `flash_attn_varlen_func` time for the step's composition, at coefficient 1.

The two fixed costs came out as stage 1's tables suggested: 1.46 ms for a mixed step replayed within the captured graphs, 7.29 ms for one run eagerly. O1's single 4.32 ms averaged them.

**What this is.** The first step-time model in this project to pass the registered test on every judged endpoint, including the short late prefills and the long-context decoders that every earlier family missed by 15% to 50%.

It is still development:
- this is the archive's fifth use, and the non-attention terms are fitted on it;
- the two fixed costs were chosen after stage 1 read O1's residuals.

It is not a simulator either, because the P → A wait and the inter-step gap are outside it.

**What it licenses.** Stage 3: a registration that freezes S1 as printed above and buys fresh cells, with each cell's compositions timed on the same GPU in the same session. It confirms S1 there without refitting, by the same bounds. That needs the owner's approval.
