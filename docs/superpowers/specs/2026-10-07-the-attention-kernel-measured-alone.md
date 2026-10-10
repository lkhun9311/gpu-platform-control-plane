# The attention kernel, measured alone

*Registered 2026-10-07, before the purchase. The owner approved the session on 2026-10-07. The script is `hack/attention-bench/flash_attn_grid.py` and the runner is `hack/attention-microbench.sh`.*

## Why

The step-boundary archive has been used by three development registrations. The last one (`2026-10-07-decoder-waves-in-a-mixed-step.md`) left one shape standing: decoders in a mixed step run in waves of about four. Its cost per wave depends on the prefill chunk beside it:

| q | Per wave-token |
|---:|---:|
| 4 | 0.01 µs |
| 16 | 0.04 µs |
| 64 | 1.24 µs |
| 256 | 1.61–1.65 µs |
| 2,032 | 1.56 µs |
| 2,047, one decoder | 0.70 µs |

A fourth family fitted to that table would test nothing. This session measures the attention kernel alone, on fresh data, over a grid fixed here.

## What runs

**Where:** one g5.xlarge Spot instance, an A10G like the archive's g5.2xlarge, in a default public subnet. Lifecycle is `m5b-scheduler-microtest.sh`'s, a 60-minute backstop, and no model is served.

**What it calls:** inside the engine image pinned in `config/vllm/deployment.yaml` (`vllm/vllm-openai@sha256:0a51ea5b…`, v0.27.1), the script calls `vllm.v1.attention.backends.fa_utils.flash_attn_varlen_func`.
- Its arguments are those `FlashAttentionImpl.forward` passes in v0.27.1 for a non-cascade step.
- The version is the one `get_flash_attn_version(head_size=128)` returns.
- The tensors have Qwen2.5-3B's attention shape: 16 query heads, 2 KV heads, head size 128, fp16, KV blocks of 16 scattered at random.

**The grid,** 278 shapes. A step holds one prefill of q tokens with no earlier context, beside n decoders of context K each:
- q ∈ {0, 4, 16, 64, 128, 256, 512, 1,024, 2,048};
- n ∈ {0, 1, 2, 4, 5, 8, 16};
- K ∈ {256, 1,024, 2,048, 4,096, 8,192};
- `num_splits` 0, the engine's only value on this GPU:
  - v0.27.1 sets a split bound only with FA3's ahead-of-time scheduling;
  - its FA2 wrapper raises for `num_splits` above 1.

  The first draft also timed 32, which would have stopped the session at its first such shape (found by review).

Each shape gets 10 warm-up calls. Then 20 calls are captured once as a CUDA graph and the graph is timed between two CUDA events, 10 times. The median per-call time is published with p10 and p90, and so is the timing method:
- `graph`, or `eager` with the reason, if capture failed;
- earlier drafts timed one call per event pair, then batches of eager calls, and both let host submission into the interval (found by review).

The KV cache is the backend's own NHD layout. K and V are packed in the last dimension of one buffer and passed as views of its halves, as `FlashAttentionImpl.forward` takes them (found by review).

## Readings, registered before the data

A step's attention time is the kernel time × 36 layers. Each reading compares that with the archive's increment, which is exec time minus a short-context step at the same q and n.

- **R1, waves.** At q = 256 with `num_splits` 0, define δ(n) as 36 × (median at K = 8,192 − median at K = 256).
  - R1 holds if δ(1), δ(4) and δ(16) are each within ±25% of the archive's 13.27, 13.64 and 55.03 ms.
  - Also report δ(16) / δ(1); the archive's ratio was 4.15.
- **R2, the small chunks.** The same δ at q = 4 with n = 1, and at q = 16 with n = 4, the archive's two small-chunk shapes.
  - R2 holds if both are under 2 ms, as the archive's 0.09 and 0.37 ms were.
  - The first draft explained them by split-KV, which this GPU's path never takes. That explanation is withdrawn, and R2 now asks only whether the kernel reproduces them.
- **R3, the large chunk.** δ at q = 2,048, n = 1, `num_splits` 0.
  - R3 holds if it is within ±25% of the archive's 5.70 ms.
  - Also report it beside δ at q = 256, n = 1: the archive halved it (0.70 against 1.61 µs per wave-token).
- **R4, q = 64.** Report δ at q = 64, n = 16 beside the archive's 41.76 ms. This reading decides nothing.

## What the readings decide

**If R1 to R3 hold,** the attention kernel accounts for the mixed-step misses. The next registration is an operator model, as Vidur builds one (arXiv 2405.05465):
- a step's time is the failed family's non-attention terms, plus 36 × this grid's kernel time, interpolated;
- It is tested on the archive. Because this grid is fresh, the archive's attention component is then predicted, not fitted, so that test is meaningful in a way a fourth fitted family is not.

**If any of R1 to R3 fails,** the kernel alone does not explain the misses; that is reported and nothing is built on the grid.

## Stopping and cost

- **Purchase:** one session, and one evaluation of what it returns. A failure of the session itself (no `DONE` marker, an exception in the script) is reported. Re-buying it needs a new note saying what changed.
- **Expected cost:** about 30 minutes of a g5.xlarge Spot instance, under $1, most of it the image pull.

## Result, 2026-10-07 — waves confirmed; the small and large chunks are not explained by this grid

**The session.**
- **Commit and instance:** the frozen commit `c160b45`; i-022feff80e3806ccd (g5.xlarge Spot, NVIDIA A10G, driver 595.91.07).
- **Time and cost:** launched 12:55:35 KST, termination requested 13:07:29 and confirmed, about 12 minutes. At these days' Spot rates that is about $0.1, an estimate that is not yet in Cost Explorer.
- **Output:** all 278 shapes, FA version 2, torch 2.13.0+cu130, every row timed by CUDA-graph replay. The grid is kept as `data/2026-10-07-attention-kernel-grid.json`.

| Reading | Kernel × 36 layers | Archive | Verdict |
|---|---:|---:|---|
| R1, q = 256: δ(1), δ(4), δ(16) | 13.653, 13.551, 54.279 ms | 13.27, 13.64, 55.03 ms | **holds**: +2.9%, −0.7%, −1.4%. The ratio δ(16)/δ(1) is 3.98 (archive 4.15) |
| R2: q = 4 with n = 1, q = 16 with n = 4 | 13.437, 13.859 ms | 0.09, 0.37 ms | **fails**: the bound was 2 ms |
| R3: q = 2,048, n = 1 | 11.595 ms | 5.70 ms | **fails**: +103% |
| R4: q = 64, n = 16 (reported only) | 54.105 ms | 41.76 ms | — |

**What the grid shows.** These are the per-layer increments, K = 8,192 minus K = 256, in µs:
- With a prefill beside them (any q from 4 to 2,048), decoders cost about 370 µs at n ≤ 5, 750 at n = 8 and 1,500 at n = 16. That is ⌈n/5⌉ waves, and five decoders per wave is the A10G's 80 SMs over 16 query heads.
- With no prefill (q = 0, a single-token query), the same increment is 28 µs at n = 1 and 264 µs at n = 16: the kernel's decode path.

**Why R2 and R3 fail, found after the readings and so not a registered result.** The grid's prefill has no earlier context, and the archive's does not match that. Read from the archive's step records:
- **The q = 4, 16 and 64 steps:** their prefill had already computed 8,188, 8,176 and 8,128 tokens. It was the last chunk of an 8,192-token prompt, so its own query rows walk about 8,192 keys too.
- **The q = 256 steps:** the prefill had computed 0 tokens, as in the grid. R1 matched them to within 3%.
- **The q = 2,047, n = 1 steps:** the prefill had computed between 0 and 6,141 tokens.

This reads as follows: a decoder's long walk costs extra only beyond the walk the prefill's own blocks already make in the same wave. So it is hidden behind a last chunk with long context, and partly hidden behind a mixture.

That is an explanation of these numbers, not a tested result. The grid did not vary the prefill's context, and this page's rule is that nothing is built on the grid while R2 and R3 fail.

**What would test it.** A second grid that adds the prefill's computed tokens c ∈ {0, 2,048, 4,096, 8,188}, registered with the prediction above before it is bought. This page does not authorise re-buying, so it needs the owner's approval. The same lifecycle would take about 15 minutes.
