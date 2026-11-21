"""Deterministic schedules and token-ID prompts for the llm-d-router #1598 pilot.

A schedule is a list of requests with an offset in seconds from the cell's origin, a token-ID prompt, a max_tokens and the
prefix it shares (or None).
The same block, seed and rate always give the same schedule, and its hash is recorded so arms can be checked to have run it.
"""

import hashlib
import json
import random

# Qwen2.5's ordinary tokens; ids at 151643 and above are special and would change how the engine treats the prompt.
TOKEN_LO, TOKEN_HI = 256, 151000

# shared-942's 25 arrival offsets in its first 20 s (ms), from gpuaas hack/prefix-route/2026-10-28-run2/.../shared-942-RoundRobin/trace.jsonl.
# Arrival index 18 was a repeat; the other 24 were first sights.
SHARED_942_MS = [1583, 1755, 3184, 3335, 3413, 3702, 3881, 4567, 6582, 7632, 7891, 8109, 8148, 8796, 10536, 10690,
                 11141, 12081, 13148, 14081, 15965, 17787, 17828, 18667, 19278]
SHARED_942_REPEAT_INDEX = 18

BLOCKS = {
    # name: (prefixes, prefix tokens, suffix tokens, total seconds, warm-up seconds, timeout seconds)
    "A": (2, 512, 32, 30.0, 5.0, 20.0),
    "B": (48, 256, 32, 40.0, 10.0, 20.0),
}
K_BURSTS, K_SIZE, K_PROMPT, K_TIMEOUT = 6, 64, 544, 10.0
PRELOAD_TOKENS = 4000
W942 = dict(prompts=48, prefix=7680, suffix=256, out=64, phase2_rate=1.6, phase2_s=100.0, timeout=45.0)


def _ids(rng, n):
    return [rng.randrange(TOKEN_LO, TOKEN_HI) for _ in range(n)]


def _req(rid, offset, prompt, max_tokens, prefix, population="eval"):
    return {"rid": rid, "offset": offset, "prompt": prompt, "max_tokens": max_tokens, "prefix": prefix, "population": population}


def steady(block, seed, rate, tag):
    """A or B: Poisson arrivals at `rate` for the block's total window; the first warm-up seconds are tagged warm-up."""
    n_pre, pre_len, suf_len, total, warm, _ = BLOCKS[block]
    rng = random.Random(f"{block}-{seed}-prompts")
    prefixes = [_ids(rng, pre_len) for _ in range(n_pre)]
    arr = random.Random(f"{block}-{seed}-arrivals-{rate}")
    out, t, i = [], 0.0, 0
    while True:
        t += arr.expovariate(rate)
        if t >= total:
            break
        p = arr.randrange(n_pre)
        pop = "warmup" if t < warm else "eval"
        out.append(_req(f"{tag}-{i}", t, prefixes[p] + _ids(arr, suf_len), arr.randint(1, 32), f"{block}{p}", pop))
        i += 1
    return out


def k_bursts(seed, tag):
    """K's six bursts of 64 cold 544-token prompts, every prompt drawn fresh so no burst warms another."""
    rng = random.Random(f"K-{seed}-prompts")
    return [[_req(f"{tag}-b{b}-{i}", 0.0, _ids(rng, K_PROMPT), rng.randint(1, 32), None) for i in range(K_SIZE)]
            for b in range(K_BURSTS)]


def preloads(seed, tag, burst):
    rng = random.Random(f"K-{seed}-preload-{burst}")
    return [_req(f"{tag}-b{burst}-pre{j}", 0.0, _ids(rng, PRELOAD_TOKENS), 1, None, "preload") for j in range(3)]


def w942_base(seed):
    """W942 at its base pace: shared-942's first-20-s offsets as simultaneous pairs, then Poisson repeats."""
    rng = random.Random(f"W942-{seed}-prompts")
    prompts = [_ids(rng, W942["prefix"]) for _ in range(W942["prompts"])]
    out, seen, nxt = [], [], 0
    for a, ms in enumerate(SHARED_942_MS):
        for _ in range(2):
            if a == SHARED_942_REPEAT_INDEX:
                p = seen[rng.randrange(len(seen))]
            else:
                p, nxt = nxt, nxt + 1
                seen.append(p)
            out.append((ms / 1000.0, p))
    arr = random.Random(f"W942-{seed}-phase2")
    t = SHARED_942_MS[-1] / 1000.0
    end = t + W942["phase2_s"]
    while True:
        t += arr.expovariate(W942["phase2_rate"])
        if t >= end:
            break
        out.append((t, arr.randrange(W942["prompts"])))
    return prompts, out


def w942(seed, rate, tag):
    """W942 time-scaled so its mean rate equals `rate`; the requests, their order and their pairs never change."""
    prompts, base = w942_base(seed)
    base_end = base[-1][0]
    scale = (len(base) / base_end) / rate
    sfx = random.Random(f"W942-{seed}-suffix")
    return [_req(f"{tag}-{i}", off * scale, prompts[p] + _ids(sfx, W942["suffix"]), W942["out"], f"W{p}")
            for i, (off, p) in enumerate(base)]


def cold_probe(tag, n, length, max_tokens, seed=0):
    """Requests each with its own never-seen random prompt, sent one at a time: every one is a cold prefill."""
    rng = random.Random(f"cold-{tag}-{seed}")
    return [_req(f"{tag}-{i}", 0.0, _ids(rng, length), max_tokens, None, "calibration") for i in range(n)]


def warm_probe(tag, n, length, max_tokens, seed=0):
    """One prompt sent n + 1 times; the first fills the cache and is dropped, the rest are warm."""
    rng = random.Random(f"warm-{tag}-{seed}")
    p = _ids(rng, length)
    return [_req(f"{tag}-{i}", 0.0, list(p), max_tokens, "warm", "calibration") for i in range(n + 1)]


def schedule_hash(reqs):
    h = hashlib.sha256()
    for r in reqs:
        h.update(json.dumps([round(r["offset"], 6), r["max_tokens"], r["prefix"], r["population"],
                             hashlib.sha256(json.dumps(r["prompt"]).encode()).hexdigest()]).encode())
    return h.hexdigest()
