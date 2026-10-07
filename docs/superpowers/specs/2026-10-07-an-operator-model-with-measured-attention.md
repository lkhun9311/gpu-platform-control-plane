# An operator model with measured attention

*Registered 2026-10-07, before the kernel times it needs are bought and before any candidate is fitted.*

| Part | File |
|---|---|
| Compositions | `hack/attention-bench/archive_compositions.py`, output `data/2026-10-07-archive-attention-compositions.json` |
| Kernel times | `hack/attention-bench/flash_attn_grid.py` with `BENCH_GRID=3`, run by `hack/attention-microbench.sh` |
| Model | `hack/tail-crossing-model/step_family_operator.py` |

## Why

The two kernel grids showed that the archive's mixed-step misses are attention:
- `2026-10-07-the-attention-kernel-measured-alone.md` matched the q = 256 increments to within 3%;
- `2026-10-07-the-prefills-own-context-and-decoder-waves.md` reproduced the small and large chunks.

They also showed that no simple law gives the kernel's time; the one-wave law failed.

So this model does not use a law. It reads the kernel's time for each step's exact composition, measured on a GPU, and fits only what is not attention.

## The compositions, 900 of them

A step's composition is what the kernel sees:
- each prefilling request's scheduled tokens q and computed tokens c;
- each decoder's context K.

c and K are rounded up to the 16-token KV block, the kernel's own granularity. The population is the development studies':
- the 12 `-step` cells;
- steps in exactly one measured episode.

Counted before anything was measured or fitted:
- 121,814 steps hold 900 distinct compositions: 150 mixed, 741 decode-only and 9 prefill-only;
- decoders in a step have nearly equal contexts (max/min median 1.00);
- 1,251 mixed steps have more than one prefilling request.

The two grids could not reach them, which is why the compositions themselves are timed.

## The kernel times (to be bought)

Grid 3 times each composition with the first two grids' method:
- the engine's `flash_attn_varlen_func` call, `num_splits` 0;
- Qwen2.5-3B's attention shape;
- the backend's packed NHD KV layout;
- CUDA-graph replay, 10 batches of 20 calls.

It runs on one g5.xlarge Spot A10G. The compositions are uploaded beside the run's results and fetched by the instance, because they do not fit in user-data.

A step's attention is 36 layers × the median per-call time.

The evaluator refuses kernel times that are not a GPU measurement by graph replay: a stub run, or a composition timed by the eager fallback (found by review).

## The model, two candidates

The non-attention terms are the failed families' terms without the three that stood for attention (m·P·n, h·H, k·K):

`c + f(P) + d1·n + d2·n² + u·[P>0, n>0]`

| | Prediction | Attention coefficient |
|---|---|---|
| O1 | non-attention terms + measured attention | fixed at 1, not fitted |
| O2 | non-attention terms + α · measured attention | α fitted |

In O1 the attention is predicted from the GPU measurement and the archive fits only the rest. O2 reports how far the archive's own fit would move the coefficient from 1.

## The test

It is the decoder-waves tournament's, unchanged:
- squared relative error with equal weight per (setting, exclusive phase);
- leave one composition out;
- an endpoint fails beyond ±10% on its mean or 15% on its mean |step error|;
- a 10-step floor, the support rule, and at most 10% of endpoints not judged;
- condition limit 100;
- the all-data fit is the predictor.

In O1 the training target is occupancy minus measured attention. A prediction is the fitted terms plus the measured attention.

**Selection:** the passing candidate with fewer fitted columns, so O1 before O2.

## What a selection licenses

The non-attention terms are still fitted on this archive, now its fourth use, so a pass is development, not a held-out result. What it would add is that the attention part came from a measurement the archive never saw.

A pass licenses registering a confirmation on fresh cells with the predictor frozen, bought only with the owner's approval. A failure is reported, and the attention grid stays as a measured fact.

## Stopping and cost

- **Purchase:** one session for the kernel times and one evaluation. Re-buying needs another note and the owner's approval.
- **Expected cost:** the second grid's 72 shapes took 14.5 minutes, nearly all of it the image pull. 900 compositions add a few minutes of timing, so about 20 minutes and about $0.15, estimated.

## Result, 2026-10-07 — no candidate passes, by one setting at −10.7%

**The session.**
- **Commit and instance:** the frozen commit `9993d4d`; i-0b2728214c512549b (g5.xlarge Spot, A10G, FA version 2).
- **Time and cost:** launched 15:06:12 KST, termination requested 15:19:42 and confirmed, about 13.5 minutes; an estimated $0.1 that is not yet in Cost Explorer.
- **Output:** all 900 compositions timed by graph replay, kept as `data/2026-10-07-attention-kernel-compositions-times.json`.

`step_family_operator.py` at `9993d4d` was then run once, on a clean tree. It exited 3. Its output is `data/2026-10-07-operator-model-tournament.txt`.

| | Judged | Failing | Worst late-prefill | Attention coefficient | Verdict |
|---|---:|---:|---:|---:|---|
| O1 | 114 | 2 | (1, 256, 256) −10.7% | 1, fixed | FAIL |
| O2 | 114 | 2 | (1, 256, 256) −10.2% | α = 0.954 | FAIL |

**SELECTED: none.** By section 6, no confirmation is proposed on this result, and the bounds are not moved after seeing it.

What the run shows:
- **Both failing endpoints are the same 21 steps.** These are the mixed and the late-prefill phase of one setting: one 256-token late prefill joining one 256-token decoder. O1 under-predicts them by 10.7%, 0.7 points beyond the bound.
- **Every long-context endpoint passes.** Those are the ones every earlier family missed by 15% to 50%, and O1's worst decode endpoint is −3.9%.
- **The data agree with the GPU measurement.** Left free, the archive's own fit puts the attention coefficient at 0.954, against the 1 that O1 takes from the GPU unfitted.
- The three 512-token serial endpoints are unsupported, as before, and 3 endpoints are under the 10-step floor (5.0% not judged).

**What this establishes, within the archive's fourth use.**
- Measured attention, taken as it is, carries the mixed-step cost that no fitted attention term could.
- What remains is a short, one-decoder mixed step about 4.8 ms slower than the non-attention terms and the kernel together predict (45.15 against 40.31 ms).

It is not a held-out result. It is not a simulator-ready model either: the P → A wait and the inter-step gap are still outside it.

**What it does not license.** A confirmation purchase. Section 6 makes that conditional on a pass, and this is a near miss, not a pass.
