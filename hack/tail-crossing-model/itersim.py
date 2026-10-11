"""An iteration-level model of one vLLM engine under FCFS chunked prefill.

This is a MODEL, written before the curve is bought, so the curve can be read as a test of it.
Nothing it prints is a measurement, and no number from it may be published as one.

Each step schedules running requests first (an in-progress prefill takes its next chunk, a decoding request
takes one token), then admits waiting requests in arrival order, all under one token budget.
That order is the mechanism the 2026-09-04 microtest measured: under fcfs a short request did not overtake a
7,695-token prefill at any budget, because the in-progress prefill is served before the waiting queue.

Step time is C0 + B * prefill_tokens + D * decode_sequences.
TTFT is the client overhead plus the end of the step that completes the prefill, minus the arrival.
"""
import math
import random


def nearest_rank(xs, q):
    """The repository's percentile convention: index ceil(q*n)-1 of the sorted values."""
    xs = sorted(xs)
    return xs[max(0, math.ceil(q * len(xs)) - 1)]


def arrivals(lam, length, out, kind, dur, seed):
    """One Poisson stream per tenant, so changing one tenant's rate leaves the other's times untouched.

    That is the property ArrivalsIndependent gives the real generator, and the reason the model uses it:
    a single weighted stream would move the latency-critical arrivals whenever the contender's load moved.
    """
    rng = random.Random(f"{seed}/{kind}")
    t, rows = 0.0, []
    if lam <= 0:
        return rows
    while True:
        t += rng.expovariate(lam)
        if t >= dur:
            return rows
        rows.append((t, kind, length, out))


def simulate(lam_lc, len_lc, lam_be, len_be=8192, out_lc=64, out_be=16, dur=600.0, seed=11,
             budget=2048, max_seqs=64, C0=0.007, B=0.0000715, D=0.0003, OC=0.032, trace=None):
    """Return the TTFTs in milliseconds, per tenant kind, for one trace.

    trace, when given, is a list of (arrival seconds, "lc" or "be", prompt tokens, output tokens) that
    replaces the generated arrivals -- so a cell's own replayed schedule can be put through the model and
    the model's error separated from the difference between one draw of the arrival process and another.
    """
    if trace is not None:
        arr = sorted(trace)
    else:
        arr = sorted(arrivals(lam_lc, len_lc, out_lc, "lc", dur, seed) +
                     arrivals(lam_be, len_be, out_be, "be", dur, seed))
    waiting, running, done = [], [], []
    t, i = 0.0, 0
    while i < len(arr) or waiting or running:
        while i < len(arr) and arr[i][0] <= t:
            a = arr[i]
            waiting.append(dict(arr=a[0], kind=a[1], pre=a[2], out=a[3], ttft=None))
            i += 1
        if not waiting and not running:
            t = arr[i][0]
            continue
        bud, pre_tok, dec, sched = budget, 0, 0, []
        for r in running:
            if r["pre"] > 0:
                c = min(r["pre"], bud)
                if c > 0:
                    sched.append((r, c))
                    bud -= c
                    pre_tok += c
            elif bud > 0:
                sched.append((r, 0))
                bud -= 1
                dec += 1
        while waiting and bud > 0 and len(running) < max_seqs:
            r = waiting.pop(0)
            running.append(r)
            c = min(r["pre"], bud)
            sched.append((r, c))
            bud -= c
            pre_tok += c
        t += C0 + B * pre_tok + D * dec
        for r, c in sched:
            if c > 0:
                r["pre"] -= c
                if r["pre"] == 0:
                    r["ttft"] = t - r["arr"] + OC
                    r["out"] -= 1
            else:
                r["out"] -= 1
        finished = [r for r in running if r["pre"] == 0 and r["out"] <= 0]
        for r in finished:
            running.remove(r)
            done.append(r)
    out = {"lc": [], "be": []}
    for r in done:
        out[r["kind"]].append(r["ttft"] * 1000)
    return out
