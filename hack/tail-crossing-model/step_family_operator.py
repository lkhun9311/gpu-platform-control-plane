"""The operator model with measured attention, as registered.

docs/superpowers/specs/2026-10-07-an-operator-model-with-measured-attention.md.

    python3 step_family_operator.py ARCHIVE/m5c-run COMPOSITIONS.json KERNEL_TIMES.json
    python3 step_family_operator.py --self-test

A step's occupancy is predicted as its non-attention terms, fitted on the archive, plus 36 layers times the attention
kernel time measured on a GPU for that step's exact composition (BENCH_GRID=3). In O1 the attention term enters with
coefficient 1 and is not fitted at all; in O2 its coefficient is fitted. The test is the decoder-waves tournament's:
leave one composition out, squared relative error with equal weight per (setting, exclusive phase), the support rule.
"""

import json
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "attention-bench"))

import archive_compositions as ac  # noqa: E402
import step_family_dev as dev  # noqa: E402
import timing_fit  # noqa: E402
from iterlog import Refusal  # noqa: E402

LAYERS = 36


def cols_nonattn():
    """The failed families' terms without the ones that stood for attention (m·P·n, h·H, k·K)."""
    return ["c"] + [f"f[{a}-{b}]" for a, b in zip(timing_fit.KNOTS, timing_fit.KNOTS[1:])] + ["d1", "d2", "u"]


def row_nonattn(st):
    P, n = st["P"], st["n"]
    if P > timing_fit.BUDGET:
        raise Refusal(f"a step schedules {P} context tokens, above the {timing_fit.BUDGET}-token budget")
    return ([1.0] + [float(min(max(P - a, 0), b - a)) for a, b in zip(timing_fit.KNOTS, timing_fit.KNOTS[1:])]
            + [float(n), float(n * n), 1.0 if P > 0 and n > 0 else 0.0])


# name: (columns, row, attention coefficient fixed at 1?)
CANDIDATES = {
    "O1": (cols_nonattn, row_nonattn, True),
    "O2": ((lambda: cols_nonattn() + ["alpha"]), (lambda st: row_nonattn(st) + [st["attn"]]), False),
}


def load(run, compositions, kernel):
    """step_family_dev.load's population, each step carrying its measured attention in ms (36 layers)."""
    ids = {(tuple(tuple(p) for p in c["prefills"]), tuple(c["decoders"])): c["id"] for c in compositions["compositions"]}
    us = {r["id"]: r["us_median"] for r in kernel["rows"]}
    if kernel.get("grid") != "3" or len(us) != len(ids):
        raise Refusal(f"the kernel times are grid {kernel.get('grid')!r} with {len(us)} rows, not grid 3's {len(ids)} compositions")
    # Only a GPU measurement by graph replay is a measurement: the stub's CPU copies and the eager fallback
    # (host time inside the interval) would enter the fit as attention without a word (found by review).
    if kernel.get("fa_version") == "stub" or not kernel.get("device"):
        raise Refusal(f"the kernel times are not from a GPU (fa_version {kernel.get('fa_version')!r}, device {kernel.get('device')!r})")
    eager = [r["id"] for r in kernel["rows"] if r.get("timing") != "graph"]
    if eager:
        raise Refusal(f"{len(eager)} composition(s) were not timed by graph replay, first id {eager[0]}")
    out = []
    for s, b, st, comp in ac.steps_with_compositions(run):
        if comp not in ids:
            raise Refusal(f"a measured step's composition {comp} is not among the timed ones")
        if st["occ"] <= 0:
            raise Refusal(f"a step with occupancy {st['occ']} ms cannot carry a relative error")
        out.append((s, b, dict(st, attn=LAYERS * us[ids[comp]] / 1000.0)))
    return out


def gram_by_setting(steps, row, p, offset):
    """Weighted relative-error normal equations per setting; with offset, the target is occupancy less attention."""
    counts = dev.group_weights(steps)
    by = {}
    for s, _, st in steps:
        x = [v / st["occ"] for v in row(st)]
        y = (st["occ"] - st["attn"]) / st["occ"] if offset else 1.0
        w = 1.0 / counts[(s, dev.phase_of(st))]
        G, h = by.setdefault(s, ([[0.0] * p for _ in range(p)], [0.0] * p))
        for i in range(p):
            h[i] += w * x[i] * y
            xi = w * x[i]
            for j in range(p):
                G[i][j] += xi * x[j]
    return by


def evaluate_candidate(name, steps):
    cols, row, offset = CANDIDATES[name]
    names = cols()
    settings = sorted({s for s, _, _ in steps}, key=str)
    folds = {}
    for s in settings:
        folds.setdefault(dev.composition(s), []).append(s)
    by_setting = {}
    for s, b, st in steps:
        by_setting.setdefault(s, []).append((b, st))
    occupied = {}
    for s, _, st in steps:
        occupied.setdefault(s, set()).add((dev.phase_of(st), dev.bin_of(dev.P_BINS, st["P"])))
    by = gram_by_setting(steps, row, len(names), offset)

    def predictor(beta):
        return lambda st: sum(c * x for c, x in zip(beta, row(st))) + (st["attn"] if offset else 0.0)
    try:
        beta, cond = dev.fit_parametric(by, names)
    except Refusal as e:
        return False, [f"candidate {name}: the all-data fit refuses -- {e}", f"  candidate {name}: FAIL"], len(names), None
    refusals, failures, judged, unjudged, unsupported, worst = [], [], 0, 0, [], {}
    for key in sorted(folds, key=str):
        held = folds[key]
        try:
            fb, _ = dev.fit_parametric(by, names, leave_out=held)
        except Refusal as e:
            refusals.append(f"fold {key}: {e}")
            continue
        trained = set().union(*(occupied[s] for s in settings if s not in held))
        for s in held:
            for ph, ep in dev.endpoints(by_setting[s], predictor(fb)).items():
                exclusive = "mixed" if ph == "late-prefill" else ph
                segs = {dev.bin_of(dev.P_BINS, st["P"]) for _, st in by_setting[s] if ph in dev.phases_judged(st)}
                if any((exclusive, g) not in trained for g in segs):
                    unsupported.append(f"{s} {ph}")
                    unjudged += 1
                    continue
                err = ep["pred"] / ep["obs"] - 1
                if ep["steps"] < dev.MIN_STEPS:
                    unjudged += 1
                    continue
                judged += 1
                if dev.endpoint_fails(err, ep["step_err"]):
                    failures.append(f"{s} {ph}: predicted {ep['pred']:.3f} ms against {ep['obs']:.3f} ms, {err:+.1%}; "
                                    f"mean |step error| {ep['step_err']:.1%}; {ep['steps']} steps")
                if ph not in worst or abs(err) > abs(worst[ph][1]):
                    worst[ph] = (s, err)
    total = judged + unjudged
    too_thin = total == 0 or unjudged / total > dev.MAX_UNJUDGED
    passed = not refusals and not failures and not too_thin
    model = dict(zip(names, beta))
    lines = [f"candidate {name}: {len(names)} fitted columns" + (" plus measured attention at coefficient 1" if offset else "")
             + f", all-data condition {cond:.1f}",
             f"  {len(folds)} folds; {judged} endpoints judged, {unjudged} not ({(unjudged / total if total else 1):.1%}: "
             f"{len(unsupported)} unsupported, {unjudged - len(unsupported)} under {dev.MIN_STEPS} steps); "
             f"{len(failures)} failing; {len(refusals)} refused"]
    lines += [f"  worst {ph}: {s} {err:+.1%}" for ph, (s, err) in sorted(worst.items())]
    lines += [f"  outside: {f}" for f in failures]
    lines += [f"  refused: {r}" for r in refusals]
    lines += [f"  unsupported (not judged): {u}" for u in unsupported]
    if too_thin:
        lines.append(f"  the test cannot speak: more than {dev.MAX_UNJUDGED:.0%} of endpoints are not judged")
    lines.append("  all-data model: " + ", ".join(f"{k} {v:.6g}" for k, v in model.items()))
    lines.append(f"  candidate {name}: {'PASS' if passed else 'FAIL'}")
    return passed, lines, len(names), model


def evaluate(run, compositions, kernel):
    steps = load(run, compositions, kernel)
    lines = [f"{len(steps)} measured steps; attention measured on {kernel.get('device')} (FA {kernel.get('fa_version')}) "
             f"for {len(compositions['compositions'])} compositions; the non-attention terms are fitted on this archive"]
    passing = []
    for i, name in enumerate(CANDIDATES):
        passed, more, size, _ = evaluate_candidate(name, steps)
        lines += more
        if passed:
            passing.append((size, i, name))
    if not passing:
        lines.append("SELECTED: none -- no operator candidate passes")
        return None, lines
    name = min(passing)[2]
    lines.append(f"SELECTED: {name}, to be frozen and confirmed on fresh cells with the owner's approval")
    return name, lines


def self_test():
    rng = random.Random(5)

    def truth_nonattn(st):
        return 12 + 0.1 * st["P"] + 0.3 * st["n"] + (6.0 if st["P"] > 0 and st["n"] > 0 else 0.0)
    steps = []
    for b in (1, 3, 5):
        for n in (1, 4, 16):
            for kd in (256, 8192):
                for q in (16, 256, 1024):
                    s = ("stagger", n, kd, q)
                    # An attention cost no column of the family can express: it depends on q and n jointly, by waves.
                    attn = 0.4 * (-(-(n + (q // 64 + 1)) // 5)) * kd / 1024
                    for _ in range(12):
                        for st in (dict(P=q, n=n, K=n * kd, H=0, late=True, attn=attn),
                                   dict(P=0, n=n, K=n * kd, H=0, late=False, attn=0.05 * n * kd / 1024)):
                            occ = (truth_nonattn(st) + st["attn"]) * (1 + rng.gauss(0, 0.004))
                            steps.append((s, b, dict(st, occ=occ)))
        for P in (64, 200, 300, 600, 1500, 2000):
            for _ in range(12):
                st = dict(P=P, n=0, K=0, H=0, late=False, attn=0.002 * P)
                steps.append((("serial", P, 16), b, dict(st, occ=(truth_nonattn(st) + st["attn"]) * (1 + rng.gauss(0, 0.004)))))
    p1, l1, _, _ = evaluate_candidate("O1", steps)
    assert p1, "\n".join(l1)
    print("ok: with the attention measured, O1 passes a cost no fitted column could express")
    # Mutation that turns this red: drop the measured attention from O1's prediction.
    blind = [(s, b, dict(st, attn=0.0)) for s, b, st in steps]
    pb, lb, _, _ = evaluate_candidate("O1", [(s, b, dict(st, occ=st["occ"])) for s, b, st in blind])
    assert not pb, "\n".join(lb)
    print("ok: without it, the same steps fail")
    p2, l2, _, m2 = evaluate_candidate("O2", steps)
    assert p2 and abs(m2["alpha"] - 1) < 0.05, (m2, "\n".join(l2))
    print(f"ok: O2 fits the attention coefficient near 1 ({m2['alpha']:.3f})")
    # Mutation that turns this red: drop the device or timing checks in load.
    comps = {"compositions": [{"id": 0, "prefills": [], "decoders": [16]}]}
    for what, kernel in (("a stub run", {"grid": "3", "fa_version": "stub", "device": None,
                                         "rows": [{"id": 0, "us_median": 1.0, "timing": "eager"}]}),
                         ("an eager fallback", {"grid": "3", "fa_version": 2, "device": "NVIDIA A10G",
                                                "rows": [{"id": 0, "us_median": 1.0, "timing": "eager (RuntimeError)"}]})):
        try:
            load("unused", comps, kernel)
            raise AssertionError(f"{what} was accepted as measured attention")
        except Refusal as e:
            print(f"ok: refuses {what} -- {e}")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
        elif len(sys.argv) == 4:
            selected, lines = evaluate(sys.argv[1], json.load(open(sys.argv[2])), json.load(open(sys.argv[3])))
            print("\n".join(lines))
            sys.exit(0 if selected else 3)
        else:
            sys.exit(__doc__)
    except Refusal as e:
        sys.exit(f"REFUSED: {e}")
