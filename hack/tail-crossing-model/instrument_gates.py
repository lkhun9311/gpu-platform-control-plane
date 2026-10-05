"""Gates I1-I5 of the instrument-validation registration, read from one archive.

docs/superpowers/specs/2026-10-05-can-the-stock-engine-time-an-iteration-instrument-validation.md, with its
amendment of 2026-10-05. Blocks are repetitions 1-3; a cell is raw-<arm>-<rep>.jsonl beside trace-<arm>-<rep>.jsonl,
engine-log-<arm>-<rep>.txt and, for preemptions, engine-metrics-<arm>-<rep>-{before,after}.prom.

    python3 instrument_gates.py ARCHIVE/m5c-run
    python3 instrument_gates.py --self-test
"""

import json
import math
import os
import random
import statistics
import sys

import iterlog
from iterlog import Refusal

BLOCKS = (1, 2, 3)
TYPES = ("serial", "burst", "stagger")
BOOT = 2000
POOLED, PER_SETTING, COMPLETENESS, STABILITY = 0.02, 0.05, 0.05, 0.05


def load_cell(run, arm, rep):
    """A cell's requests joined to their trace rows, one dict per request, refusing anything that does not join."""
    trace = {r["index"]: r for r in map(json.loads, open(os.path.join(run, f"trace-{arm}-{rep}.jsonl")))}
    raw = [json.loads(l) for l in open(os.path.join(run, f"raw-{arm}-{rep}.jsonl"))]
    if len(raw) != len(trace) or {r["index"] for r in raw} != set(trace):
        raise Refusal(f"{arm}-{rep}: {len(raw)} raw rows against {len(trace)} trace rows -- a request was lost or added")
    failed = [r["index"] for r in raw if r.get("errorKind")]
    if failed:
        raise Refusal(f"{arm}-{rep}: {len(failed)} failed request(s), first index {failed[0]} (gate I2)")
    out = []
    for r in raw:
        t = trace[r["index"]]
        out.append(dict(index=r["index"], offset=t["offsetMs"], cap=t["maxOutputTokens"],
                        input_tokens=r["engineInputTokens"], output_tokens=r["engineOutputTokens"],
                        ttft_ms=(r["firstTokenUnixNanos"] - r["sendUnixNanos"]) / 1e6, send_ms=r["sendUnixNanos"] / 1e6,
                        first_ms=r["firstTokenUnixNanos"] / 1e6, end_ms=r["endUnixNanos"] / 1e6))
    out.sort(key=lambda q: (q["offset"], q["index"]))
    return out


def settings(kind, reqs):
    """Each request's setting: the episode's parameters and the request's role in it.

    Episodes are recovered from the trace's offsets, because that is what the generator controls: a serial episode
    is one row, a burst is the rows sharing an offset, and a staggered episode is a set of decoders sharing an offset
    followed by one prefill row with a smaller output cap.
    """
    groups = []
    for q in reqs:
        if groups and groups[-1][0]["offset"] == q["offset"]:
            groups[-1].append(q)
        else:
            groups.append([q])
    keyed = []
    if kind in ("serial", "burst"):
        for g in groups:
            for q in g:
                keyed.append(((len(g), q["input_tokens"], q["cap"]), q))
        return keyed
    i = 0
    while i < len(groups):
        dec = groups[i]
        if i + 1 >= len(groups) or len(groups[i + 1]) != 1 or groups[i + 1][0]["cap"] >= dec[0]["cap"]:
            raise Refusal(f"staggered trace: the decoders at offset {dec[0]['offset']} ms have no prefill after them")
        pre = groups[i + 1][0]
        ep = (len(dec), dec[0]["input_tokens"], pre["input_tokens"])
        keyed.extend(((ep + ("decoder",), q) for q in dec))
        keyed.append((ep + ("prefill",), pre))
        i += 2
    return keyed


def itl(q):
    return (q["end_ms"] - q["first_ms"]) / (q["output_tokens"] - 1) if q["output_tokens"] >= 2 else None


def by_setting(kind, reqs, quantity):
    out = {}
    for s, q in settings(kind, reqs):
        v = q["ttft_ms"] if quantity == "ttft" else itl(q)
        if v is not None:
            out.setdefault(s, []).append(v)
    return out


def gate_i1(cells, kind, quantity, rng):
    """d(s, b) = log(median on / median off) per setting and block; pooled 95% interval within 2%, each setting within 5%."""
    on = {b: by_setting(kind, cells[(f"{kind}-log", b)], quantity) for b in BLOCKS}
    off = {b: by_setting(kind, cells[(f"{kind}-nolog", b)], quantity) for b in BLOCKS}
    keys = sorted(set.intersection(*(set(on[b]) & set(off[b]) for b in BLOCKS)), key=str)
    missing = set().union(*(set(on[b]) ^ set(off[b]) for b in BLOCKS))
    if missing or not keys:
        raise Refusal(f"I1 {kind} {quantity}: settings missing from a paired cell: {sorted(missing, key=str)[:3]}")

    def pooled(pick):
        return statistics.fmean(math.log(statistics.median(pick(on[b][s])) / statistics.median(pick(off[b][s])))
                                for s in keys for b in BLOCKS)

    point = pooled(lambda v: v)
    boot = sorted(pooled(lambda v: rng.choices(v, k=len(v))) for _ in range(BOOT))
    lo, hi = boot[int(0.025 * BOOT)], boot[int(0.975 * BOOT) - 1]
    worst = max(keys, key=lambda s: abs(statistics.fmean(
        math.log(statistics.median(on[b][s]) / statistics.median(off[b][s])) for b in BLOCKS)))
    worst_d = statistics.fmean(math.log(statistics.median(on[b][worst]) / statistics.median(off[b][worst])) for b in BLOCKS)
    ok = -POOLED <= lo and hi <= POOLED and abs(worst_d) <= PER_SETTING
    return ok, f"I1 {kind:7s} {quantity:4s}: mean d {point:+.4f}, 95% [{lo:+.4f}, {hi:+.4f}]; worst setting {worst} {worst_d:+.4f}"


def preemptions(run, arm, rep):
    """The engine's preemption counter across the cell, or a refusal when it cannot be read: unread is not zero."""
    def total(which):
        path = os.path.join(run, f"engine-metrics-{arm}-{rep}-{which}.prom")
        if not os.path.exists(path):
            raise Refusal(f"{arm}-{rep}: {path} is missing, so preemptions cannot be counted (gate I2)")
        return sum(float(l.rsplit(" ", 1)[1]) for l in open(path)
                   if l.startswith("vllm:num_preemptions_total"))
    return total("after") - total("before")


def gate_i2_i3(run, cells):
    """Accounting on every logged cell, and the serial clock fit on the serial ones."""
    lines, fits = [], []
    for (arm, b), reqs in sorted(cells.items()):
        if not arm.endswith("-log"):
            continue
        iters = iterlog.parse(open(os.path.join(run, f"engine-log-{arm}-{b}.txt")))
        iterlog.check_indices(iters)
        p = preemptions(run, arm, b)
        if p:
            raise Refusal(f"{arm}-{b}: {p:g} preemption(s) (gate I2)")
        if arm == "serial-log":
            # The same drained check iterlog.load_requests makes, because this loader does not go through it.
            by_send = sorted(reqs, key=lambda q: q["send_ms"])
            for p, q in zip(by_send, by_send[1:]):
                if q["send_ms"] < p["end_ms"]:
                    raise Refusal(f"{arm}-{b}: request {q['index']} was sent before request {p['index']} ended, so "
                                  f"the serial episode was not drained")
            fits.append(iterlog.fit_clock(iterlog.attribute_serial(iters, reqs)))
    lines.append(f"I2 accounting: every logged cell has contiguous iterations, no failed request, no preemption")
    worst_res = max(f["worst_residual"] for f in fits)
    lines.append(f"I3 clock: a {[round(f['a'], 3) for f in fits]} ms, b {[round(f['b'], 3) for f in fits]} ms per step, "
                 f"worst residual {worst_res:.4f} of TTFT")
    spread = []
    for f in fits:
        v = list(f["b_decode"].values())
        spread.append(max(v) - min(v))
    itl_med = statistics.median(x for (arm, _), rs in cells.items() if arm == "serial-log" for q in rs
                                if (x := itl(q)) is not None)
    lines.append(f"I3 decode: b' by length {[{k: round(v, 3) for k, v in f['b_decode'].items()} for f in fits]}, "
                 f"widest spread {max(spread):.3f} ms against a median inter-token time of {itl_med:.3f} ms")
    ok = worst_res <= COMPLETENESS and max(spread) <= COMPLETENESS * itl_med
    return ok, lines


def gate_i5(cells):
    """The first and last blocks' serial medians, per setting, logging on and off."""
    worst = (0.0, None)
    for arm in ("serial-log", "serial-nolog"):
        first, last = by_setting("serial", cells[(arm, 1)], "ttft"), by_setting("serial", cells[(arm, 3)], "ttft")
        for s in first:
            d = abs(math.log(statistics.median(last[s]) / statistics.median(first[s])))
            worst = max(worst, (d, (arm,) + s), key=lambda w: w[0])
    return worst[0] <= STABILITY, f"I5 stability: worst first-to-last drift {worst[0]:.4f} at {worst[1]}"


def evaluate(run, rng=None):
    rng = rng or random.Random(20261005)
    cells = {}
    for kind in TYPES:
        for suffix in ("log", "nolog"):
            for b in BLOCKS:
                cells[(f"{kind}-{suffix}", b)] = load_cell(run, f"{kind}-{suffix}", b)
    verdicts, lines = {}, []
    for kind in TYPES:
        for quantity in ("ttft", "itl"):
            ok, line = gate_i1(cells, kind, quantity, rng)
            verdicts.setdefault("I1", []).append(ok)
            lines.append(line)
    ok, more = gate_i2_i3(run, cells)
    verdicts["I3"] = [ok]
    lines += more
    ok, line = gate_i5(cells)
    verdicts["I5"] = [ok]
    lines.append(line)
    lines.append("I4 context: not computed by this script; it is published from the burst logs, not gated")
    passed = all(all(v) for v in verdicts.values())
    lines.append("PASS: I1, I2, I3 and I5 hold" if passed else
                 "FAIL: " + ", ".join(k for k, v in verdicts.items() if not all(v)))
    return passed, lines


def _write_cell(run, arm, rep, reqs, log_lines, preempt=0):
    with open(os.path.join(run, f"trace-{arm}-{rep}.jsonl"), "w") as f:
        for q in reqs:
            f.write(json.dumps(dict(index=q["index"], offsetMs=q["offset"], tenant="premium-1",
                                    maxOutputTokens=q["cap"])) + "\n")
    with open(os.path.join(run, f"raw-{arm}-{rep}.jsonl"), "w") as f:
        for q in reqs:
            f.write(json.dumps(dict(index=q["index"], engineInputTokens=q["input_tokens"],
                                    engineOutputTokens=q["output_tokens"], sendUnixNanos=int(q["send"] * 1e6),
                                    firstTokenUnixNanos=int(q["first"] * 1e6), endUnixNanos=int(q["end"] * 1e6))) + "\n")
    with open(os.path.join(run, f"engine-log-{arm}-{rep}.txt"), "w") as f:
        f.write("\n".join(log_lines) + "\n")
    for which, v in (("before", 3), ("after", 3 + preempt)):
        with open(os.path.join(run, f"engine-metrics-{arm}-{rep}-{which}.prom"), "w") as f:
            f.write(f'vllm:num_preemptions_total{{engine="0"}} {v}\n')


def _synthetic_run(run, overhead=0.0, seed=7):
    """Nine paired cells whose truth is known: the logging-on cells are slower by the factor (1 + overhead)."""
    rng = random.Random(seed)
    for kind in TYPES:
        for suffix in ("log", "nolog"):
            for b in BLOCKS:
                scale = 1 + overhead if suffix == "log" else 1.0
                reqs, lines, t, idx, it = [], [], 0.0, 0, 100
                for cycle in range(3):
                    if kind == "serial":
                        eps = [[(L, c)] for L in (256, 2048, 8192) for c in (1, 16)]
                    elif kind == "burst":
                        eps = [[(L, 16)] * n for n in (1, 4) for L in (256, 2048)]
                    else:
                        eps = [[(c, 128)] * n + [(p, 16)] for n in (1, 4) for c in (256, 8192) for p in (256, 8192)]
                    for ep in eps:
                        decs, rest = (ep[:-1], ep[-1:]) if kind == "stagger" else (ep, [])
                        for j, group in enumerate((decs, rest)):
                            for L, c in group:
                                k = math.ceil(L / 2048)
                                noise = 1 + rng.gauss(0, 0.002)
                                ctx = [10.0 * scale * noise * min(2048, L - j2 * 2048) / 2048 for j2 in range(k)]
                                for j2, ms in enumerate(ctx):
                                    lines.append(iterlog._line(it, 1, min(2048, L - j2 * 2048), 0, 0, ms)); it += 1
                                for _ in range(c - 1):
                                    lines.append(iterlog._line(it, 0, 0, 1, 1, 13.3 * scale * noise)); it += 1
                                ttft = 6.0 + sum(ctx) + 1.5 * k
                                send = t + (200 if j else 0)
                                reqs.append(dict(index=idx, offset=round(send), cap=c, input_tokens=L, output_tokens=c,
                                                 send=send, first=send + ttft,
                                                 end=send + ttft + (c - 1) * (13.3 * scale * noise + 1.5)))
                                idx += 1
                        t += 10_000
                _write_cell(run, f"{kind}-{suffix}", b, reqs, lines)


def self_test():
    import tempfile
    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run)
        passed, lines = evaluate(run)
        print("\n".join(lines))
        assert passed, "a null overhead failed"
        print("ok: no overhead -> PASS")
    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run, overhead=0.04)
        passed, lines = evaluate(run)
        assert not passed and lines[-1].startswith("FAIL") and "I1" in lines[-1], lines
        print("ok: a 4% logging overhead -> FAIL on I1")
    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run)
        os.remove(os.path.join(run, "engine-metrics-burst-log-2-after.prom"))
        try:
            evaluate(run)
            raise AssertionError("an unreadable preemption counter was read as zero")
        except Refusal as e:
            print(f"ok: refuses an unreadable preemption counter -- {e}")
    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run)
        with open(os.path.join(run, "engine-metrics-stagger-log-3-after.prom"), "w") as f:
            f.write('vllm:num_preemptions_total{engine="0"} 4\n')
        try:
            evaluate(run)
            raise AssertionError("a preemption was accepted")
        except Refusal as e:
            print(f"ok: refuses a preemption -- {e}")
    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run)
        path = os.path.join(run, "raw-serial-log-1.jsonl")
        rows = [json.loads(l) for l in open(path)]
        rows[5]["sendUnixNanos"] = rows[4]["endUnixNanos"] - 1
        with open(path, "w") as f:
            f.writelines(json.dumps(r) + "\n" for r in rows)
        try:
            evaluate(run)
            raise AssertionError("an undrained serial episode was accepted")
        except Refusal as e:
            print(f"ok: refuses an undrained serial episode -- {e}")
    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run)
        _ = [l for l in open(os.path.join(run, "raw-serial-nolog-2.jsonl"))]
        with open(os.path.join(run, "raw-serial-nolog-2.jsonl"), "w") as f:
            f.writelines(_[:-1])
        try:
            evaluate(run)
            raise AssertionError("a lost request was accepted")
        except Refusal as e:
            print(f"ok: refuses a lost request -- {e}")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
        elif len(sys.argv) == 2:
            passed, lines = evaluate(sys.argv[1])
            print("\n".join(lines))
            sys.exit(0 if passed else 1)
        else:
            sys.exit(__doc__)
    except Refusal as e:
        sys.exit(f"REFUSED: {e}")
