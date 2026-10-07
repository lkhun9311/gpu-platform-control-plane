"""Diagnostic tables for the mixed-step misses, as registered: nothing is fitted.

docs/superpowers/specs/2026-10-07-where-the-mixed-step-time-goes-diagnostic-tables.md.

    python3 step_diagnostics.py ARCHIVE/m5c-run
    python3 step_diagnostics.py --self-test

Each table states a reading registered before it was computed; the readings decide only which hypotheses may
enter the next candidate registration.
"""

import statistics
import sys

import step_boundary as sb  # noqa: E402
import step_family_dev as dev  # noqa: E402
from iterlog import Refusal  # noqa: E402

GRAPH_MAX_TOKENS = 128
KMAX_BINS = ((0, 1024, "<=1024"), (1024, 4096, "(1024,4096]"), (4096, 10 ** 9, ">4096"))
MIN_GROUP = 5
# Candidate B's failing endpoints in the development study's output, the compositions T1 and T4 look at.
FAILING = [("serial", 512, 1), ("serial", 512, 16), ("serial", 512, 64),
           ("stagger", 1, 8192, 256), ("stagger", 16, 8192, 256)]
SHORT_LATE = [("stagger", n, k, 256) for n in (1, 4, 16) for k in (256, 8192)]


def kmax_bin(k):
    for lo, hi, name in KMAX_BINS:
        if lo < k <= hi or (lo == 0 and k == 0):
            return name
    raise Refusal(f"a decoder context of {k} fits no K_max bin")


def records(run):
    """Every measured step with its stamps and per-request counts, joined to its setting by its t0."""
    out = []
    for arm, b in dev.CELLS:
        kind = arm.split("-")[0]
        adds, sched, done, _, _ = sb.step_records(run, arm, b)
        by_t0 = {s["t0"]: s for s in sched}
        for e in sb.episodes_of_cell(run, arm, b, kind):
            for st in e["steps"]:
                s = by_t0.get(round(st["t0_ms"] * 1e6))
                if s is None:
                    raise Refusal(f"{arm}-{b}: a measured step's t0 matches no scheduled step")
                d = done[s["step"]]
                prefill = [(rid, q, s["computed"][rid]) for rid, q in s["tokens"].items()
                           if s["computed"][rid] < adds[rid]["prompt"]]
                ctx = [s["computed"][rid] + 1 for rid in s["tokens"] if s["computed"][rid] >= adds[rid]["prompt"]]
                out.append(dict(setting=e["setting"], block=b, phase=dev.phase_of(st), late=st["late"],
                                P=st["P"], n=st["n"], K=st["K"], kmax=max(ctx) if ctx else 0,
                                T=st["P"] + st["n"], prefills=prefill, occ=st["occ"],
                                sched=(s["t1"] - s["t0"]) / 1e6, exec=(d["t2"] - s["t1"]) / 1e6,
                                update=(d["t3"] - d["t2"]) / 1e6))
    if not out:
        raise Refusal("no measured step")
    return out


def mean(xs):
    xs = list(xs)
    return statistics.fmean(xs) if xs else float("nan")


def t1(rows):
    lines = ["T1 -- where the time is (mean ms: occupancy = sched + exec + update)"]
    for ph in dev.EXCLUSIVE:
        r = [x for x in rows if x["phase"] == ph]
        lines.append(f"  {ph}: {len(r)} steps, occ {mean(x['occ'] for x in r):.3f}, sched {mean(x['sched'] for x in r):.3f}, "
                     f"exec {mean(x['exec'] for x in r):.3f}, update {mean(x['update'] for x in r):.3f}")
    worst_cpu = 0.0
    for s in SHORT_LATE + [f for f in FAILING if f[0] == "serial"]:
        r = [x for x in rows if x["setting"] == s and (x["late"] if s[0] == "stagger" else x["phase"] == "prefill-only")]
        cpu = mean(x["sched"] + x["update"] for x in r)
        worst_cpu = max(worst_cpu, cpu)
        lines.append(f"  {s}: {len(r)} steps, occ {mean(x['occ'] for x in r):.3f}, sched+update {cpu:.3f}, "
                     f"exec {mean(x['exec'] for x in r):.3f}")
    lines.append(f"  H-cpu: {'falsified' if worst_cpu < 1.0 else 'standing'} "
                 f"(largest sched+update in a failing endpoint {worst_cpu:.3f} ms; falsified under 1 ms)")
    return lines


def t2(rows):
    lines = ["T2 -- mixed steps with one prefilling request, by its q, n and K_max bin (mean exec ms)"]
    groups = {}
    for x in rows:
        if x["phase"] == "mixed" and len(x["prefills"]) == 1:
            groups.setdefault((x["prefills"][0][1], x["n"], kmax_bin(x["kmax"])), []).append(x)
    for key in sorted(groups):
        g = groups[key]
        tag = "" if len(g) >= MIN_GROUP else "  (under 5 steps, not read)"
        lines.append(f"  q {key[0]}, n {key[1]}, K_max {key[2]}: {len(g)} steps, exec {mean(x['exec'] for x in g):.3f}, "
                     f"sum K {mean(x['K'] for x in g):.0f}, K_max {mean(x['kmax'] for x in g):.0f}{tag}")

    def delta(q, n):
        hi, lo = groups.get((q, n, ">4096"), []), groups.get((q, n, "<=1024"), [])
        if len(hi) < MIN_GROUP or len(lo) < MIN_GROUP:
            return None
        return mean(x["exec"] for x in hi) - mean(x["exec"] for x in lo)
    d1, d16 = delta(256, 1), delta(256, 16)
    if d1 is None or d16 is None or d1 <= 0:
        lines.append("  ratio: not readable at q 256 (a group under 5 steps or a non-positive increment at n 1)")
        return lines
    ratio = d16 / d1
    d4 = delta(256, 4)
    lines.append(f"  q 256: increment n 1 {d1:.3f} ms" + (f", n 4 {d4:.3f} ms" if d4 is not None else "")
                 + f", n 16 {d16:.3f} ms; ratio n 16 / n 1 = {ratio:.2f}")
    lines.append(f"  H-sum (about 16): {'falsified' if ratio < 8 else 'standing'}; "
                 f"H-max (about 1): {'falsified' if ratio > 2 else 'standing'}; "
                 f"H-wave: the ratio is ceil(16/w) for w about {16 / ratio:.1f}")
    return lines


def t3(rows):
    lines = [f"T3 -- graph sizes (captured up to {GRAPH_MAX_TOKENS} scheduled tokens, FULL_AND_PIECEWISE)"]
    for n in sorted({x["n"] for x in rows if x["phase"] == "decode"}):
        r = [x for x in rows if x["phase"] == "decode" and x["n"] == n]
        if len(r) >= MIN_GROUP:
            lines.append(f"  decode n {n}: {len(r)} steps, occ {mean(x['occ'] for x in r):.3f}, K/n {mean(x['K'] / n for x in r):.0f}")
    small = [x for x in rows if x["phase"] == "mixed" and x["T"] <= GRAPH_MAX_TOKENS]
    big = [x for x in rows if x["phase"] == "mixed" and x["T"] > GRAPH_MAX_TOKENS]
    lines.append(f"  mixed steps with T <= {GRAPH_MAX_TOKENS}: {len(small)}; above: {len(big)}")
    if not small:
        lines.append("  H-graph: not read -- no mixed step ran inside the captured sizes")
    else:
        lines.append(f"  mixed T <= {GRAPH_MAX_TOKENS}: occ {mean(x['occ'] for x in small):.3f} at T {mean(x['T'] for x in small):.0f}; "
                     f"above: occ {mean(x['occ'] for x in big):.3f} at T {mean(x['T'] for x in big):.0f} (read against T5)")
    return lines


def t4(rows):
    lines = ["T4 -- training support each failing fold leaves (steps in other compositions)"]
    standing = None
    for s in FAILING:
        mine = [x for x in rows if x["setting"] == s and (x["late"] if s[0] == "stagger" else x["phase"] == "prefill-only")]
        if not mine:
            lines.append(f"  {s}: no step")
            continue
        comp = dev.composition(s)
        ph, seg = mine[0]["phase"], dev.bin_of(dev.P_BINS, mine[0]["P"])
        nb, kb = dev.bin_of(dev.N_BINS, mine[0]["n"]), kmax_bin(mine[0]["kmax"])
        other = [x for x in rows if dev.composition(x["setting"]) != comp]
        same_seg = [x for x in other if x["phase"] == ph and dev.bin_of(dev.P_BINS, x["P"]) == seg]
        same_shape = [x for x in same_seg if dev.bin_of(dev.N_BINS, x["n"]) == nb and kmax_bin(x["kmax"]) == kb]
        lines.append(f"  {s}: {ph}, P segment {seg}: {len(same_seg)} steps elsewhere in the segment, "
                     f"{len(same_shape)} also with its n and K_max bins")
        if s == ("serial", 512, 1):
            standing = len(same_seg) < 100
    if standing is not None:
        lines.append(f"  H-support: {'standing' if standing else 'falsified'} (standing under 100 prefill-only steps)")
    return lines


def t5(rows):
    lines = ["T5 -- prefill-only by size and chunk position"]
    pre = [x for x in rows if x["phase"] == "prefill-only" and len(x["prefills"]) == 1]
    for P in sorted({x["P"] for x in pre}):
        for pos in ("first", "later"):
            r = [x for x in pre if x["P"] == P and ((x["prefills"][0][2] == 0) == (pos == "first"))]
            if len(r) >= MIN_GROUP:
                lines.append(f"  P {P}, {pos} chunk: {len(r)} steps, occ {mean(x['occ'] for x in r):.3f}, "
                             f"exec {mean(x['exec'] for x in r):.3f}, ms per token {mean(x['occ'] for x in r) / P:.4f}")
    return lines


def evaluate(run):
    rows = records(run)
    lines = [f"{len(rows)} measured steps (development data; nothing is fitted)"]
    for table in (t1, t2, t3, t4, t5):
        lines += table(rows)
    return lines


def self_test():
    rows = []
    for n in (1, 16):
        for kmax, extra in ((300, 0.0), (8000, 10.0)):
            for _ in range(6):
                rows.append(dict(setting=("stagger", n, 256 if kmax < 1000 else 8192, 256), block=1, phase="mixed",
                                 late=True, P=256, n=n, K=n * kmax, kmax=kmax, T=256 + n, prefills=[("r", 256, 0)],
                                 occ=40 + extra, sched=0.1, exec=38 + extra, update=0.1))
    lines = t2(rows)
    assert any("ratio n 16 / n 1 = 1.00" in l for l in lines) and any("H-max (about 1): standing" in l for l in lines), lines
    print("ok: an increment that does not grow with n reads as H-max standing and H-sum falsified")
    rows2 = [dict(r, exec=r["exec"] + (r["n"] - 1) * (10.0 if r["kmax"] > 4096 else 0.0)) for r in rows]
    lines2 = t2(rows2)
    assert any("H-sum (about 16): standing" in l for l in lines2), lines2
    print("ok: an increment proportional to n reads as H-sum standing")
    thin = rows[:4]
    assert any("not readable" in l for l in t2(thin))
    print("ok: groups under 5 steps are not read")
    assert kmax_bin(0) == "<=1024" and kmax_bin(1024) == "<=1024" and kmax_bin(1025) == "(1024,4096]" and kmax_bin(9000) == ">4096"
    print("ok: every context falls in one K_max bin")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
        elif len(sys.argv) == 2:
            print("\n".join(evaluate(sys.argv[1])))
        else:
            sys.exit(__doc__)
    except Refusal as e:
        sys.exit(f"REFUSED: {e}")
