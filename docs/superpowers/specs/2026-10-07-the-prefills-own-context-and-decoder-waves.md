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
