# The prefill's own context and decoder waves: a second kernel grid

*Registered 2026-10-07, before the purchase. The owner approved this second session on 2026-10-07, after the first session's result. The script is `hack/attention-bench/flash_attn_grid.py` with `BENCH_GRID=2`, and the runner is `hack/attention-microbench.sh`, unchanged otherwise.*

## Why

The first grid (`2026-10-07-the-attention-kernel-measured-alone.md`) confirmed decoder waves:
- at q = 256 its increments matched the archive within 3% (R1);
- per layer, a prefill beside decoders costs about 375 µs per wave of five long-context decoders.

It failed the small chunks (R2) and the large chunk (R3). Read after the result, the archive's small-chunk steps had a prefill that had already computed 8,128 to 8,188 tokens, and the grid's prefills had computed none.

This grid adds that axis, and states beforehand what it must show.

## The explanation under test

A long-context decoder costs extra only beyond the walk the prefill's own blocks already make in the same wave. A last chunk of an 8,192-token prompt walks about as far as an 8,192-token decoder. So it should absorb one wave of decoders, and the increment should be ⌈n/5⌉ − 1 waves instead of ⌈n/5⌉.

## The grid, 72 shapes

As in the first grid: Qwen2.5-3B's attention shape, the backend's packed NHD KV layout, `num_splits` 0, CUDA-graph replay, 10 batches of 20 calls. A prefill of q tokens after c computed ones attends to c + q keys, its queries the last q.

- **Set A, the law:**
  - q ∈ {16, 256};
  - n ∈ {1, 4, 5, 8, 16};
  - K ∈ {256, 8,192};
  - c ∈ {0, 4,096, 8,192 − q}.
- **Set B, the archive's other shapes:**
  - (q 4, n 1, c 8,188) and (q 64, n 16, c 8,128);
  - (q 2,047, n 1) at c ∈ {0, 2,047, 4,094, 6,141}, the four chunks of an 8,192-token prompt;
  - each at K ∈ {256, 8,192}.

The archive's (q 16, n 4, c 8,176) is in set A.

## Readings, registered before the data

Let:
- Δ(q, n, c) be the per-layer median at K = 8,192 minus at K = 256, in µs;
- w(q) = Δ(q, 1, 0), one wave at that chunk.

- **H1, a last chunk absorbs one wave.** For q ∈ {16, 256}, c = 8,192 − q, and each n:
  - the predicted Δ is (⌈n/5⌉ − 1) · w(q);
  - H1 holds if all ten are within ±0.25 · w(q) of it.
- **H2, half the context.** Δ at c = 4,096 is reported beside c = 0 and the last chunk, and judges nothing.
- **H3, the archive's small and large chunks.** 36 × Δ against the archive's increment:
  - (4, 1, 8,188) against 0.09 ms;
  - (16, 4, 8,176) against 0.37 ms;
  - (64, 16, 8,128) against 41.76 ms.

  H3 holds if each is within 2 ms or 25%, whichever is larger.
- **H4, the large chunk.** The mean over its four c of 36 × Δ(2,047, 1, c), against the archive's 5.70 ms. The archive's steps are the four chunks in equal number. H4 holds within ±25%.

## What the readings decide

**If H1, H3 and H4 hold,** the next registration is the operator model the first grid's page named:
- a step's time is the failed family's non-attention terms plus 36 × the measured kernel time, interpolated in (q, n, K, c);
- it is tested on the archive's steps.

The kernel grids are fresh data, so the archive's attention component is then predicted, not fitted. Even so, the archive is not a held-out test of the whole model, because its non-attention terms are fitted on it.

**If any fails,** the hiding explanation is not established; that is reported and nothing is built on it.

## Stopping and cost

- **Purchase:** one session and one evaluation. Re-buying needs another note and the owner's approval.
- **Expected cost:** the first session took 12 minutes. This grid is about a quarter of its size, so cost is again about $0.1, most of it the image pull.

## Result, 2026-10-07 — the archive's chunks are reproduced; the one-wave law is not

**The session.**
- **Commit and instance:** the frozen commit `f412d13`; i-0823cc311034d629f (g5.xlarge Spot, A10G, FA version 2).
- **Time and cost:** launched 14:02:28 KST, termination requested 14:16:56 and confirmed, about 14.5 minutes; an estimated $0.1 that is not yet in Cost Explorer.
- **Output:** all 72 shapes timed by CUDA-graph replay.
- **Files:** the grid is `data/2026-10-07-attention-kernel-grid-2.json`, and the readings, computed by the definitions above, are `data/2026-10-07-attention-kernel-grid-2-readings.txt`.

| Reading | Result | Verdict |
|---|---|---|
| H1, a last chunk absorbs one wave | 6 of 10 within ±0.25 w. Outside: (q 16, n 5) 387.2 µs against 0; (q 256, n 4) 369.9 against 0; (q 256, n 5) 367.9 against 0; (q 256, n 8) 730.0 against 376.3 | **fails** |
| H3, the archive's small chunks, 36 × Δ | (4, 1, 8,188) −0.060 ms against 0.09; (16, 4, 8,176) 0.206 against 0.37; (64, 16, 8,128) 41.100 against 41.76 | **holds** |
| H4, the large chunk, mean over its four c | 11.586, 8.983, 5.832 and 1.699 ms; mean 7.025 against 5.70, +23.2% | **holds** (bound ±25%) |

**What is established.** Measured on fresh data, the attention kernel alone reproduces the archive's mixed-step increments:
- at a 256-token chunk with no context (the first grid, within 3%);
- at the three small last chunks (this grid, within 0.17 ms of the two near-zero increments and 0.66 ms, 1.6%, of the 41.76 ms one);
- at the large chunk's four positions on average (+23%).

The archive's misses were attention. The families failed because the cost depends on (q, n, K, c) together, not because of anything outside the kernel.

**What is not.** The one-wave law fails.
- A last chunk absorbs every decoder up to n = 4 beside a 16-token chunk, and only one beside a 256-token chunk.
- With c = 4,096 the decoders are partly hidden: 193 µs for one decoder against 376 with no context.

So the hiding is not "one wave", and this page does not establish a law for it.

**Observed after the readings, not registered.** Suppose a prefill of q tokens occupies ⌈q/64⌉ of the five per-wave slots (each slot one sequence's 16 head-blocks). Then every last-chunk row of set A fits ⌈(⌈q/64⌉ + n)/5⌉ − 1 waves: 0, 0, 1, 1 and 3 at q = 16, and 0, 1, 1, 2 and 3 at q = 256. The 64-token query block is an inference from these numbers, not read from the kernel. A law built on it would need a third grid registered with it, and it is not proposed here.

**What follows.** By the rule above, H1 failing means nothing is built on the hiding explanation, and no law is claimed.

The finding that does stand needs no law: a model that reads the measured kernel time directly, interpolated in (q, n, K, c), would predict the archive's attention component from fresh data. Registering that operator model is the next free step. It would not be bought; it needs the grids to cover the archive's shapes, which the two grids cover only in part.
