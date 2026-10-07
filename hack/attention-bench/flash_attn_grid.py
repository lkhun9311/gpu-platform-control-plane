"""Times vLLM's own FlashAttention call over a registered grid of mixed-step shapes, on one GPU.

docs/superpowers/specs/2026-10-07-the-attention-kernel-measured-alone.md.

Run inside the pinned vLLM image (`--entrypoint python3`), which carries the kernel the engine called. It calls
vllm.v1.attention.backends.fa_utils.flash_attn_varlen_func with the arguments FlashAttentionImpl.forward passes in
v0.27.1 for a non-cascade step, on Qwen2.5-3B's attention shape, and prints one JSON document.

BENCH_STUB=1 replaces the kernel with a CPU stand-in, so the grid, the inputs and the output can be checked
anywhere; its numbers mean nothing.
"""

import inspect
import itertools
import json
import math
import os
import statistics
import sys
import time

# Qwen2.5-3B-Instruct's attention, and vLLM's KV block size for it.
HEADS, KV_HEADS, HEAD_DIM, BLOCK = 16, 2, 128, 16
LAYERS = 36
# The registered grid. q = 0 is a step with no prefill; n = 0 a step with no decoder.
QS = (0, 4, 16, 64, 128, 256, 512, 1024, 2048)
NS = (0, 1, 2, 4, 5, 8, 16)
KS = (256, 1024, 2048, 4096, 8192)
# vLLM v0.27.1 sets a split bound only with FA3's ahead-of-time scheduling, so on FA2 every step passes 0, and
# the FA2 wrapper raises for anything above 1 (found by review; flash_attn_interface.py, "FA2 does not support
# num_splits > 1"). 0 is the engine's only path here.
SPLITS = (0,)
# Timed in batches of back-to-back calls, so the GPU is never idle waiting for Python between the two events.
# One call per event pair let host-side argument handling and launch latency into a kernel's time (found by review).
WARMUP, BATCHES, PER_BATCH = 10, 10, 20
STUB = os.environ.get("BENCH_STUB") == "1"


# BENCH_GRID selects the registered grid. 1 is the first session's (prefills with no earlier context) and stays
# the default, so its frozen result can be reproduced; 2 adds the prefill's computed tokens c,
# docs/superpowers/specs/2026-10-07-the-prefills-own-context-and-decoder-waves.md.
GRID = os.environ.get("BENCH_GRID", "1")


def grid():
    """(q, n, K, splits, c): a prefill of q tokens after c computed ones, beside n decoders of context K."""
    if GRID == "1":
        for q, n, k, s in itertools.product(QS, NS, KS, SPLITS):
            if q == 0 and n == 0:
                continue
            if n == 0 and k != KS[0]:
                continue  # K is a decoder context; with no decoder only one K is needed
            yield q, n, k, s, 0
    elif GRID == "2":
        # Set A: the hiding law, at a short and a medium chunk, with no context, half, and a last chunk.
        for q, n, k in itertools.product((16, 256), (1, 4, 5, 8, 16), (256, 8192)):
            for c in (0, 4096, 8192 - q):
                yield q, n, k, 0, c
        # Set B: the archive's other small- and large-chunk shapes; its (16, 4, 8176) is already in set A.
        for q, n, c in ((4, 1, 8188), (64, 16, 8128),
                        (2047, 1, 0), (2047, 1, 2047), (2047, 1, 4094), (2047, 1, 6141)):
            for k in (256, 8192):
                yield q, n, k, 0, c
    elif GRID == "3":
        return  # grid 3 is a list of compositions, not (q, n, K, splits, c); see cases()
    else:
        raise SystemExit(f"BENCH_GRID={GRID!r} is not a registered grid")


def cases():
    """(label, query lengths, key lengths) for every shape of the selected grid.

    Grids 1 and 2 are a prefill of q tokens after c computed ones beside n decoders of one context K. Grid 3 is the
    archive's own compositions, read from BENCH_COMPOSITIONS
    (docs/superpowers/specs/2026-10-07-an-operator-model-with-measured-attention.md): each prefilling request's
    (q, c) and each decoder's K, exactly as a step held them.
    """
    if GRID == "3":
        comps = json.load(open(os.environ.get("BENCH_COMPOSITIONS", "/b/compositions.json")))["compositions"]
        for comp in comps:
            pre, dec = comp["prefills"], comp["decoders"]
            yield (dict(id=comp["id"]), [q for q, _ in pre] + [1] * len(dec),
                   [c + q for q, c in pre] + list(dec))
        return
    shapes = list(grid())
    if len(set(shapes)) != len(shapes):
        raise SystemExit("the grid repeats a shape")
    for q, n, k, s_, c in shapes:
        if s_ != 0:
            raise SystemExit("only num_splits 0 is the engine's path on FA2")
        # A prefill after c computed tokens attends to c + q keys, its queries the last q of them.
        yield dict(q=q, n=n, k=k, c=c, splits=s_), ([q] if q else []) + [1] * n, ([c + q] if q else []) + [k] * n


def main():
    import torch
    if STUB:
        def kernel(**kw):
            kw["out"].copy_(kw["q"])
        fa_version, signature = "stub", "stub"
        device = "cpu"
        sync = lambda: None  # noqa: E731
    else:
        from vllm.v1.attention.backends.fa_utils import flash_attn_varlen_func, get_flash_attn_version
        # The version FlashAttentionImpl asks for with this head size; on an A10G (sm86) it should be 2.
        fa_version = get_flash_attn_version(head_size=HEAD_DIM)
        if fa_version is None:
            raise SystemExit("no FlashAttention version is available for head size 128 on this GPU")
        signature = str(inspect.signature(flash_attn_varlen_func))
        accepted = set(inspect.signature(flash_attn_varlen_func).parameters)

        def kernel(**kw):
            missing = {"q", "k", "v", "cu_seqlens_q", "max_seqlen_q", "seqused_k", "max_seqlen_k", "block_table",
                       "num_splits"} - accepted
            if missing:
                raise SystemExit(f"flash_attn_varlen_func does not take {sorted(missing)}: {signature}")
            return flash_attn_varlen_func(**{k: v for k, v in kw.items() if k in accepted})
        device = "cuda"
        sync = torch.cuda.synchronize
    torch.manual_seed(0)
    out = {"grid": GRID, "fa_version": fa_version, "signature": signature, "device": None if STUB else torch.cuda.get_device_name(0),
           "torch": torch.__version__, "layers": LAYERS, "rows": []}
    for label, qlens, klens in cases():
        blocks = [math.ceil(x / BLOCK) for x in klens]
        nblocks = sum(blocks) + 1
        dt = torch.float16 if not STUB else torch.float32
        # The backend's own layout: K and V packed in the last dimension of one NHD buffer, and the kernel given
        # views of its halves, as FlashAttentionImpl.forward takes them with transpose(1, 2).split(head_size).
        # Separate contiguous K and V planes would hand the kernel other strides (found by review).
        packed = torch.randn(nblocks, BLOCK, KV_HEADS, 2 * HEAD_DIM, dtype=dt, device=device)
        key_view, value_view = packed.split(HEAD_DIM, dim=-1)
        # Blocks scattered, as a running engine's allocator leaves them.
        perm = torch.randperm(nblocks - 1, device="cpu") + 1
        table = torch.zeros(len(qlens), max(blocks), dtype=torch.int32)
        at = 0
        for i, b in enumerate(blocks):
            table[i, :b] = perm[at:at + b].to(torch.int32)
            at += b
        query = torch.randn(sum(qlens), HEADS, HEAD_DIM, dtype=dt, device=device)
        output = torch.empty_like(query)
        cu = torch.tensor([0] + list(itertools.accumulate(qlens)), dtype=torch.int32, device=device)
        kw = dict(q=query, k=key_view, v=value_view, out=output, cu_seqlens_q=cu, max_seqlen_q=max(qlens),
                  seqused_k=torch.tensor(klens, dtype=torch.int32, device=device), max_seqlen_k=max(klens),
                  softmax_scale=HEAD_DIM ** -0.5, causal=True, alibi_slopes=None, window_size=None,
                  block_table=table.to(device), softcap=0.0, scheduler_metadata=None, fa_version=fa_version,
                  num_splits=0)
        for _ in range(WARMUP):
            kernel(**kw)
        sync()
        # A batch is captured once as a CUDA graph and replayed, so no Python runs between its kernels and the
        # events time the GPU alone; batching eager calls still let a fast kernel wait on the next submission
        # (found by review). If capture fails, eager batches are timed and the row says so.
        method = "eager"
        run_batch = lambda: [kernel(**kw) for _ in range(PER_BATCH)]  # noqa: E731
        if not STUB:
            try:
                side = torch.cuda.Stream()
                side.wait_stream(torch.cuda.current_stream())
                with torch.cuda.stream(side):
                    kernel(**kw)
                torch.cuda.current_stream().wait_stream(side)
                graph = torch.cuda.CUDAGraph()
                with torch.cuda.graph(graph):
                    for _ in range(PER_BATCH):
                        kernel(**kw)
                graph.replay()
                sync()
                run_batch, method = graph.replay, "graph"
            except Exception as e:  # noqa: BLE001
                method = f"eager ({type(e).__name__})"
        times = []
        for _ in range(BATCHES):
            if STUB:
                t0 = time.perf_counter()
                run_batch()
                times.append((time.perf_counter() - t0) * 1e6 / PER_BATCH)
            else:
                a, b = torch.cuda.Event(enable_timing=True), torch.cuda.Event(enable_timing=True)
                a.record()
                run_batch()
                b.record()
                b.synchronize()
                times.append(a.elapsed_time(b) * 1e3 / PER_BATCH)
        out["rows"].append(dict(label, T=sum(qlens), timing=method, us_median=statistics.median(times),
                                us_p10=sorted(times)[len(times) // 10], us_p90=sorted(times)[len(times) * 9 // 10]))
    json.dump(out, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
