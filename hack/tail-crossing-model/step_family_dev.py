"""Develops a mixed-step family on the seen step-boundary archive, as registered.

docs/superpowers/specs/2026-10-07-a-mixed-step-family-developed-on-the-seen-archive.md.

    python3 step_family_dev.py ARCHIVE/m5c-run
    python3 step_family_dev.py --self-test

Four candidates (A, the registered family; B and C, with mixed-step terms; D, a table) are each tested by
leaving one setting out at a time, on relative error with equal weight per (setting, phase). The archive is
development data: a pass here selects a predictor to confirm on fresh cells, and is not itself a held-out pass.
The archive's gates were run by step_boundary.py at the session's frozen commit and are not repeated here.
"""

import math
import os
import random
import statistics
import sys

import step_boundary as sb  # noqa: E402
import timing_fit  # noqa: E402
from iterlog import Refusal  # noqa: E402

CELLS = sorted([(f"{k}-step", b) for k in ("serial", "stagger") for b in sb.ODD]
               + [("burst-step", b) for b in range(1, 7)])
TOL = 0.10
# The mean |relative error| of an endpoint's own steps, so errors that cancel in the mean cannot pass it.
STEP_TOL = 0.15
# Set by counting the archive's endpoints, not by fitting anything: at 30 steps, 37 of 120 endpoints fell below,
# including all six short late prefills (21 steps each), so the test could neither pass nor judge the failure it is for.
MIN_STEPS = 10
MAX_UNJUDGED = 0.10
MIN_BIN = 5
# The three exclusive phases carry the training weight; late-prefill is a subset of mixed, judged on its own.
EXCLUSIVE = ("prefill-only", "mixed", "decode")
JUDGED = EXCLUSIVE + ("late-prefill",)
P_BINS = (0, 256, 512, 1024, 2048)
N_BINS = (0, 1, 4, 16, 64)
KN_BINS = (0, 1024, 4096)


def composition(setting):
    """The fold a setting is held out in: settings that offer the engine the same composition are held out together.

    A serial request and a one-request burst are the same single prompt, and output caps change only how long the
    decode lasts, so holding out one of them while training on its twin would test a composition already seen.
    """
    kind = setting[0]
    if kind == "serial":
        return ("single", setting[1])
    if kind == "burst":
        return ("single", setting[2]) if setting[1] == 1 else ("burst", setting[1], setting[2])
    return setting


def phase_of(st):
    if st["P"] > 0:
        return "mixed" if st["n"] > 0 else "prefill-only"
    return "decode"


def phases_judged(st):
    return (phase_of(st),) + (("late-prefill",) if st["late"] else ())


# ---------------------------------------------------------------------------------------------------------------
# The parametric candidates' columns


def cols_a():
    return timing_fit.columns(True)


def row_a(st):
    return timing_fit.features(st, True)


def cols_b():
    return timing_fit.columns(False) + ["k_pure", "k_mixed", "u"]


def row_b(st):
    P, n, K = st["P"], st["n"], st["K"]
    return timing_fit.features(st, False) + [float(K) if P == 0 else 0.0, float(K) if P > 0 else 0.0,
                                             1.0 if P > 0 and n > 0 else 0.0]


def cols_c():
    return cols_b() + ["e"]


def row_c(st):
    return row_b(st) + [float(st["n"]) if st["P"] > 0 else 0.0]


PARAMETRIC = {"A": (cols_a, row_a), "B": (cols_b, row_b), "C": (cols_c, row_c)}


# ---------------------------------------------------------------------------------------------------------------
# Data


def load(run):
    """Every measured step of the 12 -step cells as (setting, block, step); the warm-up is in no episode."""
    out = []
    for arm, b in CELLS:
        kind = arm.split("-")[0]
        for e in sb.episodes_of_cell(run, arm, b, kind):
            for st in e["steps"]:
                if st["occ"] <= 0:
                    raise Refusal(f"{arm}-{b}: a step with occupancy {st['occ']} ms cannot carry a relative error")
                out.append((e["setting"], b, st))
    if not out:
        raise Refusal(f"{run}: no measured step in any of the {len(CELLS)} cells")
    return out


def group_weights(steps):
    """1 / (steps in its setting's exclusive phase), so each (setting, phase) carries equal total weight."""
    counts = {}
    for s, _, st in steps:
        counts[(s, phase_of(st))] = counts.get((s, phase_of(st)), 0) + 1
    return counts


# ---------------------------------------------------------------------------------------------------------------
# Fitting


def gram_by_setting(steps, row, p):
    """Each setting's weighted relative-error normal equations, so a fold is the total less one setting."""
    counts = group_weights(steps)
    by = {}
    for s, _, st in steps:
        x = [v / st["occ"] for v in row(st)]
        w = 1.0 / counts[(s, phase_of(st))]
        G, h = by.setdefault(s, ([[0.0] * p for _ in range(p)], [0.0] * p))
        for i in range(p):
            h[i] += w * x[i]
            xi = w * x[i]
            Gi = G[i]
            for j in range(p):
                Gi[j] += xi * x[j]
    return by


def fit_parametric(by, names, leave_out=()):
    p = len(names)
    G, h = [[0.0] * p for _ in range(p)], [0.0] * p
    for s, (Gs, hs) in by.items():
        if s in leave_out:
            continue
        for i in range(p):
            h[i] += hs[i]
            for j in range(p):
                G[i][j] += Gs[i][j]
    return timing_fit.solve_normalised(G, h, names, check=True)


def bin_of(edges, v):
    for i, e in enumerate(edges):
        if v <= e:
            return i
    return len(edges)


def table_key(st):
    n = st["n"]
    return (bin_of(P_BINS, st["P"]), bin_of(N_BINS, n), bin_of(KN_BINS, st["K"] / n if n else 0))


def table_by_setting(steps):
    """Per setting and bin: steps, and the sums the weighted relative-error minimiser needs.

    A bin's value v minimises sum w (v - o)^2 / o^2, the same loss and weights as the parametric fits, so
    v = sum(w / o) / sum(w / o^2). An arithmetic mean would minimise squared milliseconds instead (found in review).
    """
    counts = group_weights(steps)
    by = {}
    for s, _, st in steps:
        w, o = 1.0 / counts[(s, phase_of(st))], st["occ"]
        cell = by.setdefault(s, {}).setdefault(table_key(st), [0, 0.0, 0.0])
        cell[0] += 1
        cell[1] += w / o
        cell[2] += w / (o * o)
    return by


def fit_table(by, leave_out=()):
    total = {}
    for s, bins in by.items():
        if s in leave_out:
            continue
        for k, (c, a, q) in bins.items():
            cell = total.setdefault(k, [0, 0.0, 0.0])
            cell[0] += c
            cell[1] += a
            cell[2] += q
    return {k: a / q for k, (c, a, q) in total.items() if c >= MIN_BIN}


# ---------------------------------------------------------------------------------------------------------------
# The test


def endpoints(mine, predict):
    """One held-out setting's endpoints: per judged phase, steps, mean observed, mean predicted (None: unsupported)."""
    out = {}
    for ph in JUDGED:
        sel = [(b, st) for b, st in mine if ph in phases_judged(st)]
        if not sel:
            continue
        preds = [predict(st) for _, st in sel]
        obs = statistics.fmean(st["occ"] for _, st in sel)
        pred = None if any(x is None for x in preds) else statistics.fmean(preds)
        step_err = None if pred is None else statistics.fmean(abs(q / st["occ"] - 1) for q, (_, st) in zip(preds, sel))
        blocks = {}
        if ph == "late-prefill" and pred is not None:
            for b in sorted({b for b, _ in sel}):
                o = statistics.fmean(st["occ"] for bb, st in sel if bb == b)
                q = statistics.fmean(predict(st) for bb, st in sel if bb == b)
                blocks[b] = q / o - 1
        out[ph] = dict(steps=len(sel), obs=obs, pred=pred, step_err=step_err, blocks=blocks)
    return out


def endpoint_fails(err, step_err):
    """An endpoint fails on its mean or on its steps: a mean can match while every step is wrong."""
    return abs(err) > TOL or step_err > STEP_TOL


def evaluate_candidate(name, steps):
    """Leave-one-setting-out for one candidate: (passed, lines, refusals, judged endpoint count, full-fit model)."""
    settings = sorted({s for s, _, _ in steps}, key=str)
    folds = {}
    for s in settings:
        folds.setdefault(composition(s), []).append(s)
    by_setting = {}
    for s, b, st in steps:
        by_setting.setdefault(s, []).append((b, st))
    if name in PARAMETRIC:
        cols, row = PARAMETRIC[name]
        names = cols()
        by = gram_by_setting(steps, row, len(names))

        def fold(held):
            beta, _ = fit_parametric(by, names, leave_out=held)
            return lambda st: sum(c * x for c, x in zip(beta, row(st)))
        # The predictor a selection freezes is this all-data fit, by the same rules; a refusal here fails the candidate.
        try:
            beta, cond = fit_parametric(by, names)
        except Refusal as e:
            return False, [f"candidate {name}: the all-data fit refuses -- {e}", f"  candidate {name}: FAIL"], len(names), None
        model = dict(zip(names, beta))
        size = len(names)
        head = f"candidate {name}: {size} columns, all-data condition {cond:.1f}"
    else:
        by = table_by_setting(steps)

        def fold(held):
            table = fit_table(by, leave_out=held)
            return lambda st: table.get(table_key(st))
        model = fit_table(by)
        size = len(model)
        head = f"candidate {name}: a table of {size} supported bins"
    refusals, failures, judged, unjudged, worst = [], [], 0, 0, {}
    late_blocks = []
    for key in sorted(folds, key=str):
        held = folds[key]
        try:
            predict = fold(held)
        except Refusal as e:
            refusals.append(f"fold {key}: {e}")
            continue
        for s in held:
            for ph, ep in endpoints(by_setting[s], predict).items():
                # An unsupported bin fails the endpoint whatever its size: the floor decides judging, not support.
                if ep["pred"] is None:
                    failures.append(f"{s} {ph}: a step falls in a bin with fewer than {MIN_BIN} training steps")
                    continue
                err = ep["pred"] / ep["obs"] - 1
                if ep["steps"] < MIN_STEPS:
                    unjudged += 1
                    continue
                judged += 1
                if endpoint_fails(err, ep["step_err"]):
                    failures.append(f"{s} {ph}: predicted {ep['pred']:.3f} ms against {ep['obs']:.3f} ms, {err:+.1%}; "
                                    f"mean |step error| {ep['step_err']:.1%}; {ep['steps']} steps")
                # Per judged endpoint, inside the loop: placed after it, only a setting's last phase counted, and a
                # setting whose every endpoint was unsupported read an unset error (found by review).
                if ph not in worst or abs(err) > abs(worst[ph][1]):
                    worst[ph] = (s, err)
                if ep["blocks"]:
                    late_blocks.append(f"{s}: " + ", ".join(f"block {b} {v:+.1%}" for b, v in ep["blocks"].items()))
    total = judged + unjudged
    too_thin = total == 0 or unjudged / total > MAX_UNJUDGED
    passed = not refusals and not failures and not too_thin
    lines = [head, f"  {len(folds)} folds over {len(settings)} settings; {judged} endpoints judged, {unjudged} below {MIN_STEPS} steps "
                   f"({(unjudged / total if total else 1):.1%}); {len(failures)} failing (mean beyond {TOL:.0%} or step error beyond {STEP_TOL:.0%}); "
                   f"{len(refusals)} refused"]
    lines += [f"  worst {ph}: {s} {err:+.1%}" for ph, (s, err) in sorted(worst.items())]
    lines += [f"  outside: {f}" for f in failures]
    lines += [f"  refused: {r}" for r in refusals]
    lines += [f"  late-prefill by block (published, not judged): {x}" for x in late_blocks]
    if too_thin:
        lines.append(f"  the test cannot speak: more than {MAX_UNJUDGED:.0%} of endpoints are below {MIN_STEPS} steps")
    lines.append(f"  candidate {name}: {'PASS' if passed else 'FAIL'}")
    return passed, lines, size, model


def select(results):
    """The passing candidate with the fewest columns (D: supported bins), ties to the earlier letter; None if none passes."""
    passing = sorted((size, name) for name, (passed, size, _) in results.items() if passed)
    return passing[0][1] if passing else None


def evaluate(run):
    steps = load(run)
    lines = [f"development data: {len(steps)} measured steps in {len(CELLS)} cells, "
             f"{len({s for s, _, _ in steps})} settings (seen; no result here is a held-out pass)"]
    results = {}
    for name in ("A", "B", "C", "D"):
        passed, more, size, model = evaluate_candidate(name, steps)
        lines += more
        results[name] = (passed, size, model)
    name = select(results)
    if name is None:
        lines.append("SELECTED: none -- no candidate passes; item 2 stays closed and no confirmation is proposed")
        return None, lines
    lines.append(f"SELECTED: {name} ({results[name][1]} {'bins' if name == 'D' else 'columns'}), to be frozen and confirmed "
                 f"on fresh cells; full-fit model: "
                 + (", ".join(f"{k} {v:.6g}" for k, v in results[name][2].items()) if name != "D"
                    else f"{len(results[name][2])} bins"))
    # A selected table is written out whole, as a parametric fit's coefficients are, so a confirmation can freeze it.
    if name == "D":
        lines += [f"  bin P{k[0]} n{k[1]} K/n{k[2]}: {v:.6g} ms" for k, v in sorted(results[name][2].items())]
    return name, lines


# ---------------------------------------------------------------------------------------------------------------


def _synthetic(truth, rng):
    """Steps whose occupancy is truth(st) with 1% noise, over settings shaped like the archive's three types."""
    steps = []
    for b in (1, 3, 5):
        for n in (1, 4, 16):
            for K in (256, 8192):
                for P in (256, 1024, 1800):
                    s = ("stagger", n, K, P)
                    for _ in range(40):
                        st = dict(P=P, n=n, K=n * (K + 100), H=P * rng.choice((0, P)), late=True)
                        steps.append((s, b, dict(st, occ=truth(st) * (1 + rng.gauss(0, 0.01)))))
                    for _ in range(40):
                        st = dict(P=0, n=n, K=n * (K + 100), H=0, late=False)
                        steps.append((s, b, dict(st, occ=truth(st) * (1 + rng.gauss(0, 0.01)))))
        for P in (64, 200, 400, 800, 1500, 2000):
            s = ("serial", P, 16)
            for _ in range(40):
                st = dict(P=P, n=0, K=0, H=P * rng.choice((0, P)), late=False)
                steps.append((s, b, dict(st, occ=truth(st) * (1 + rng.gauss(0, 0.01)))))
    return steps


def self_test():
    rng = random.Random(7)
    # A mixed step pays its decoders' context at another rate and a fixed surcharge: B's shape, which A cannot fit.
    def mixed_truth(st):
        P, n, K = st["P"], st["n"], st["K"]
        base = 10 + 0.02 * P + 0.3 * n
        return base + (0.0012 * K + 6.0 if P > 0 and n > 0 else 0.0003 * K)
    steps = _synthetic(mixed_truth, rng)
    pa, la, _, _ = evaluate_candidate("A", steps)
    pb, lb, _, _ = evaluate_candidate("B", steps)
    assert not pa, "\n".join(la)
    assert pb, "\n".join(lb)
    print(f"ok: a mixed-step surcharge fails A and passes B -- {la[-1].strip()}; {lb[-1].strip()}")
    # Mutation that turns this red: weight steps instead of (setting, phase) groups, or drop the relative rows.
    counts = group_weights(steps)
    assert all(v == 40 * 3 for v in counts.values()), counts
    # Repeating one group's steps five times changes nothing when each group carries one total weight.
    # Mutation that turns this red: weight every step 1.
    names = cols_b()
    once = fit_parametric(gram_by_setting(steps, row_b, len(names)), names)[0]
    heavy = steps + [x for x in steps if x[0] == ("stagger", 16, 8192, 256) and x[2]["P"] == 0] * 4
    five = fit_parametric(gram_by_setting(heavy, row_b, len(names)), names)[0]
    assert all(abs(a - b) <= 1e-9 * max(1.0, abs(a)) for a, b in zip(once, five)), (once, five)
    print("ok: every (setting, phase) group carries one total weight, so repeating a group's steps moves nothing")
    # A held-out setting whose steps fall in bins no other setting reached: the table refuses, and so fails.
    lone = steps + [(("serial", 4096, 16), 1, dict(P=2048, n=0, K=0, H=0, late=False, occ=50.0))] * 40
    lone = [(s, b, dict(st, P=2000) if s == ("serial", 4096, 16) else st) for s, b, st in lone]
    pd, ld, _, _ = evaluate_candidate("D", lone)
    assert not pd and any("fewer than" in l for l in ld), "\n".join(ld)
    print("ok: a table that has never seen a held-out setting's bin refuses it")
    # Every phase reaches the worst-endpoint lines, not only each setting's last.
    # Mutation that turns this red: update `worst` after the phase loop.
    _, lb2, _, _ = evaluate_candidate("B", steps)
    assert {l.split()[1].rstrip(":") for l in lb2 if l.startswith("  worst ")} == {"decode", "late-prefill", "mixed", "prefill-only"}, lb2
    print("ok: the worst endpoint is reported for every phase")
    # A fold whose every endpoint is unsupported fails the table instead of raising.
    alone = [(s, b, st) for s, b, st in steps if s[0] != "serial"] + [(("serial", 64, 16), 1, dict(P=2048, n=0, K=0, H=0, late=False, occ=9.0))] * 12
    pa2, la2, _, _ = evaluate_candidate("D", alone)
    assert not pa2 and any("fewer than" in l for l in la2), la2
    print("ok: a setting whose only endpoint is unsupported fails the table rather than raising")
    # Too few steps everywhere: the test cannot speak, and the candidate does not pass by silence.
    thin = [(s, b, st) for i, (s, b, st) in enumerate(steps) if i % 40 < 3]
    pt, lt, _, _ = evaluate_candidate("B", thin)
    assert not pt and any("cannot speak" in l for l in lt), "\n".join(lt)
    print("ok: a test whose endpoints are below the step floor refuses rather than passes")
    # Errors that cancel in an endpoint's mean: identical steps alternate between 0.2x and 1.8x the truth, so a
    # model can match every mean and still misplace every step. Mutation that turns this red: drop STEP_TOL.
    # Mutation that turns this red: judge the mean alone.
    assert endpoint_fails(0.0, 0.80) and endpoint_fails(0.11, 0.0) and not endpoint_fails(0.09, 0.14)
    ep = endpoints([(1, dict(occ=10.0, P=0, n=1, late=False)), (1, dict(occ=100.0, P=0, n=1, late=False))],
                   lambda st: 55.0)["decode"]
    assert ep["pred"] == ep["obs"] == 55.0 and abs(ep["step_err"] - 2.475) < 1e-9, ep
    print(f"ok: an endpoint whose step errors cancel in its mean fails on the step-error bound ({ep['step_err']:.1%})")
    # A serial request and a one-request burst are one composition, and caps do not make another.
    assert composition(("serial", 256, 64)) == composition(("burst", 1, 256, 64)) == composition(("serial", 256, 16))
    assert composition(("burst", 4, 256, 64)) != composition(("burst", 1, 256, 64))
    print("ok: settings offering the same composition are held out together")
    # Selection: the fewest columns among passing candidates, and none when none passes.
    assert select({"A": (False, 10, None), "B": (True, 12, None), "C": (True, 13, None), "D": (True, 40, None)}) == "B"
    assert select({"A": (True, 12, None), "B": (True, 12, None)}) == "A"
    assert select({"A": (False, 10, None), "B": (False, 12, None)}) is None
    print("ok: the passing candidate with the fewest columns is selected, ties to the earlier letter, none if none pass")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
        elif len(sys.argv) == 2:
            selected, lines = evaluate(sys.argv[1])
            print("\n".join(lines))
            sys.exit(0 if selected else 3)
        else:
            sys.exit(__doc__)
    except Refusal as e:
        sys.exit(f"REFUSED: {e}")
