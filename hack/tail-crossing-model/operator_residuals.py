"""O1's leave-one-composition-out residuals, tabulated as registered. Nothing new is fitted.

docs/superpowers/specs/2026-10-07-where-o1-misses-residual-tables.md.

    python3 operator_residuals.py ARCHIVE/m5c-run COMPOSITIONS.json KERNEL_TIMES.json
    python3 operator_residuals.py --self-test

Each step is predicted by O1's fit on every other composition, with step_family_operator's own functions, so the
residuals are the ones its verdict was made from.
"""

import json
import statistics
import sys

import step_boundary as sb  # noqa: E402
import step_family_dev as dev  # noqa: E402
import step_family_operator as op  # noqa: E402
from iterlog import Refusal  # noqa: E402

GRAPH_MAX_TOKENS = 128


def intervals(run):
    """{(arm, block, t0 ns): (sched, exec, update) ms} for every scheduled step of the 12 cells."""
    out = {}
    for arm, b in dev.CELLS:
        _, sched, done, _, _ = sb.step_records(run, arm, b)
        for s in sched:
            d = done[s["step"]]
            out[(arm.split("-")[0], b, s["t0"])] = ((s["t1"] - s["t0"]) / 1e6, (d["t2"] - s["t1"]) / 1e6,
                                                    (d["t3"] - d["t2"]) / 1e6)
    return out


def residuals(steps):
    """O1's held-out prediction for every step: (setting, block, step, predicted ms)."""
    cols, row, offset = op.CANDIDATES["O1"]
    names = cols()
    by = op.gram_by_setting(steps, row, len(names), offset)
    folds = {}
    for s in {s for s, _, _ in steps}:
        folds.setdefault(dev.composition(s), []).append(s)
    out = []
    for key, held in folds.items():
        beta, _ = dev.fit_parametric(by, names, leave_out=held)
        for s, b, st in steps:
            if s in held:
                out.append((s, b, st, sum(c * x for c, x in zip(beta, row(st))) + st["attn"]))
    return out


def mean(xs):
    xs = list(xs)
    return statistics.fmean(xs) if xs else float("nan")


def tables(rows):
    """rows: dicts with setting, phase, late, occ, pred, T, sched, update."""
    lines = []
    for r in rows:
        r["res"] = r["occ"] - r["pred"]
        r["pct"] = r["res"] / r["occ"]
    lines.append("R-T1 -- the short late prefills (residual = observed - predicted)")
    ms = []
    worst_cpu = 0.0
    for n in (1, 4, 16):
        sel = [r for r in rows if r["setting"] == ("stagger", n, 256, 256) and r["late"]]
        m = mean(r["res"] for r in sel)
        cpu = mean(r["sched"] + r["update"] for r in sel)
        ms.append(m)
        worst_cpu = max(worst_cpu, cpu)
        lines.append(f"  n {n:2d}: {len(sel)} steps, residual {m:+.3f} ms ({mean(r['pct'] for r in sel):+.1%}), "
                     f"sched+update {cpu:.3f} ms, T {mean(r['T'] for r in sel):.0f}")
    spread = max(ms) - min(ms)
    lines.append(f"  H-shared: {'standing' if spread <= 1.5 else 'falsified'} (residuals within {spread:.3f} ms; standing within 1.5)")
    lines.append(f"  H-cpu: {'falsified' if worst_cpu < 1.0 else 'standing'} (largest sched+update {worst_cpu:.3f} ms)")
    lines.append(f"R-T2 -- mixed steps by graph eligibility (T <= {GRAPH_MAX_TOKENS}) and predicted occupancy")
    mixed = [r for r in rows if r["phase"] == "mixed"]
    small = [r for r in mixed if r["T"] <= GRAPH_MAX_TOKENS]
    lines.append(f"  T <= {GRAPH_MAX_TOKENS}: {len(small)} steps, residual {mean(r['res'] for r in small):+.3f} ms "
                 f"({mean(r['pct'] for r in small):+.1%})")
    bins = (("under 60 ms", 0, 60), ("60 to 150 ms", 60, 150), ("above 150 ms", 150, 1e9))
    pcts = {}
    for name, lo, hi in bins:
        sel = [r for r in mixed if r["T"] > GRAPH_MAX_TOKENS and lo <= r["pred"] < hi]
        pcts[name] = mean(r["pct"] for r in sel)
        lines.append(f"  T > {GRAPH_MAX_TOKENS}, predicted {name}: {len(sel)} steps, residual {mean(r['res'] for r in sel):+.3f} ms "
                     f"({pcts[name]:+.1%})")
    readable = all(p == p for p in pcts.values())
    floor = readable and pcts["under 60 ms"] == max(pcts.values())
    lines.append("  H-floor: " + ("not readable (an empty bin)" if not readable else
                 f"{'standing' if floor else 'falsified'} (the under-60 ms bin is "
                 f"{'the most' if floor else 'not the most'} under-predicted)"))
    lines.append("R-T3 -- residual by exclusive phase")
    for ph in dev.EXCLUSIVE:
        sel = [r for r in rows if r["phase"] == ph]
        lines.append(f"  {ph}: {len(sel)} steps, residual {mean(r['res'] for r in sel):+.3f} ms ({mean(r['pct'] for r in sel):+.1%})")
    return lines


def evaluate(run, compositions, kernel):
    steps = op.load(run, compositions, kernel)
    ints = intervals(run)
    rows = []
    for s, b, st, pred in residuals(steps):
        key = (s[0], b, round(st["t0_ms"] * 1e6))
        if key not in ints:
            raise Refusal(f"a step of {s} in block {b} has no scheduled record at its t0")
        sch, _, upd = ints[key]
        rows.append(dict(setting=s, phase=dev.phase_of(st), late=st["late"], occ=st["occ"], pred=pred,
                         T=st["P"] + st["n"], sched=sch, update=upd))
    return [f"{len(rows)} steps, O1's held-out predictions (development data; nothing new fitted)"] + tables(rows)


def self_test():
    def row(setting, phase, late, occ, pred, T, cpu=0.2):
        return dict(setting=setting, phase=phase, late=late, occ=occ, pred=pred, T=T, sched=cpu / 2, update=cpu / 2)
    rows = []
    for n, occ in ((1, 45.0), (4, 46.0), (16, 49.0)):
        rows += [row(("stagger", n, 256, 256), "mixed", True, occ, occ - 4.8, 256 + n) for _ in range(5)]
    rows += [row(("burst", 4, 2048, 64), "mixed", False, 250.0, 248.0, 2052) for _ in range(5)]
    rows += [row(("burst", 4, 256, 64), "mixed", False, 100.0, 99.0, 260) for _ in range(5)]
    rows += [row(("stagger", 1, 8192, 4), "mixed", False, 31.0, 31.0, 5) for _ in range(5)]
    rows += [row(("serial", 256, 16), "decode", False, 16.0, 16.1, 1) for _ in range(5)]
    lines = tables(rows)
    assert any("H-shared: standing" in l for l in lines), lines
    assert any("H-floor: standing" in l for l in lines), lines
    assert any("H-cpu: falsified" in l for l in lines), lines
    print("ok: an equal 4.8 ms on the three short settings reads H-shared and, as the smallest bin, H-floor standing")
    for r in rows:
        if r["setting"] == ("stagger", 16, 256, 256):
            r["pred"] = r["occ"]
    lines = tables(rows)
    assert any("H-shared: falsified" in l for l in lines), lines
    print("ok: a residual only at n = 1 and 4 falsifies H-shared")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
        elif len(sys.argv) == 4:
            print("\n".join(evaluate(sys.argv[1], json.load(open(sys.argv[2])), json.load(open(sys.argv[3])))))
        else:
            sys.exit(__doc__)
    except Refusal as e:
        sys.exit(f"REFUSED: {e}")
