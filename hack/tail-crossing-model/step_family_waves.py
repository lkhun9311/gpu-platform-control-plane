"""The decoder-waves development tournament, as registered.

docs/superpowers/specs/2026-10-07-decoder-waves-in-a-mixed-step.md.

    python3 step_family_waves.py ARCHIVE/m5c-run
    python3 step_family_waves.py --self-test

Candidate B of the first development study plus one wave column, tested exactly as that study tested its
candidates, with one rule added: an endpoint whose fold leaves no training step of its phase in its f(P) knot
segment is unsupported, published and not judged. step_family_dev.py is not modified, because its result is
recorded against its frozen commit; this file reuses its functions.
"""

import math
import random
import statistics
import sys

import step_boundary as sb  # noqa: E402
import step_family_dev as dev  # noqa: E402
from iterlog import Refusal  # noqa: E402

GATE_Q = 16


def load(run):
    """dev.load's population, each step also carrying K_max and q_max from the instrument's own records."""
    out = []
    for arm, b in dev.CELLS:
        kind = arm.split("-")[0]
        adds, sched, _, _, _ = sb.step_records(run, arm, b)
        by_t0 = {s["t0"]: s for s in sched}
        for e in sb.episodes_of_cell(run, arm, b, kind):
            for st in e["steps"]:
                s = by_t0.get(round(st["t0_ms"] * 1e6))
                if s is None:
                    raise Refusal(f"{arm}-{b}: a measured step's t0 matches no scheduled step")
                if st["occ"] <= 0:
                    raise Refusal(f"{arm}-{b}: a step with occupancy {st['occ']} ms cannot carry a relative error")
                ctx = [s["computed"][r] + 1 for r in s["tokens"] if s["computed"][r] >= adds[r]["prompt"]]
                pre = [q for r, q in s["tokens"].items() if s["computed"][r] < adds[r]["prompt"]]
                out.append((e["setting"], b, dict(st, kmax=max(ctx) if ctx else 0, qmax=max(pre) if pre else 0)))
    if not out:
        raise Refusal(f"{run}: no measured step")
    return out


def wave(w, gated):
    def v(st):
        if st["P"] == 0 or st["n"] == 0 or (gated and st["qmax"] <= GATE_Q):
            return 0.0
        return float(math.ceil(st["n"] / w) * st["kmax"])
    return v


def candidate(w, gated):
    return (lambda: dev.cols_b() + ["v"]), (lambda st, v=wave(w, gated): dev.row_b(st) + [v(st)])


CANDIDATES = {"B": (dev.cols_b, dev.row_b), "W4": candidate(4, False), "W5": candidate(5, False),
              "W4g": candidate(4, True), "W5g": candidate(5, True)}
SELECTABLE = ("W4", "W5", "W4g", "W5g")


def support(steps):
    """Per setting: the set of (exclusive phase, f(P) segment) its steps occupy."""
    out = {}
    for s, _, st in steps:
        out.setdefault(s, set()).add((dev.phase_of(st), dev.bin_of(dev.P_BINS, st["P"])))
    return out


def evaluate_candidate(name, steps):
    """dev.evaluate_candidate's test with the registered support rule; returns (passed, lines, size, model)."""
    cols, row = CANDIDATES[name]
    names = cols()
    settings = sorted({s for s, _, _ in steps}, key=str)
    folds = {}
    for s in settings:
        folds.setdefault(dev.composition(s), []).append(s)
    by_setting = {}
    for s, b, st in steps:
        by_setting.setdefault(s, []).append((b, st))
    occupied = support(steps)
    by = dev.gram_by_setting(steps, row, len(names))
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
            for ph, ep in dev.endpoints(by_setting[s], lambda st: sum(c * x for c, x in zip(fb, row(st)))).items():
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
    lines = [f"candidate {name}: {len(names)} columns, all-data condition {cond:.1f}",
             f"  {len(folds)} folds; {judged} endpoints judged, {unjudged} not ({(unjudged / total if total else 1):.1%}: "
             f"{len(unsupported)} unsupported, {unjudged - len(unsupported)} under {dev.MIN_STEPS} steps); "
             f"{len(failures)} failing; {len(refusals)} refused"]
    lines += [f"  worst {ph}: {s} {err:+.1%}" for ph, (s, err) in sorted(worst.items())]
    lines += [f"  outside: {f}" for f in failures]
    lines += [f"  refused: {r}" for r in refusals]
    lines += [f"  unsupported (not judged): {u}" for u in unsupported]
    if too_thin:
        lines.append(f"  the test cannot speak: more than {dev.MAX_UNJUDGED:.0%} of endpoints are not judged")
    lines.append(f"  all-data model: " + ", ".join(f"{k} {v:.6g}" for k, v in model.items()))
    lines.append(f"  candidate {name}: {'PASS' if passed else 'FAIL'}")
    return passed, lines, len(names), model


def evaluate(run):
    steps = load(run)
    lines = [f"development data, third use: {len(steps)} measured steps, {len({s for s, _, _ in steps})} settings"]
    passing = []
    for name in ("B",) + SELECTABLE:
        passed, more, size, _ = evaluate_candidate(name, steps)
        lines += more
        if passed and name in SELECTABLE:
            passing.append((size, SELECTABLE.index(name), name))
    if not passing:
        lines.append("SELECTED: none -- no wave candidate passes")
        return None, lines
    name = min(passing)[2]
    lines.append(f"SELECTED: {name}, to be frozen and confirmed on fresh cells with the owner's approval")
    return name, lines


def self_test():
    rng = random.Random(11)

    def truth(st):
        P, n, K, km, q = st["P"], st["n"], st["K"], st["kmax"], st["qmax"]
        t = 10 + 0.1 * P + 0.3 * n + 0.0003 * K
        if P > 0 and n > 0:
            t += 6.0 + (0.0016 * math.ceil(n / 4) * km if q > 16 else 0.0)
        return t
    steps = []
    for b in (1, 3, 5):
        for n in (1, 4, 16):
            for kd in (256, 8192):
                for q in (8, 256, 1024):
                    s = ("stagger", n, kd, q)
                    for _ in range(12):
                        for st in (dict(P=q, n=n, K=n * kd, H=0, late=True, kmax=kd, qmax=q),
                                   dict(P=0, n=n, K=n * kd, H=0, late=False, kmax=kd, qmax=0)):
                            st["H"] = st["P"] * rng.choice((0, st["P"]))
                            steps.append((s, b, dict(st, occ=truth(st) * (1 + rng.gauss(0, 0.005)))))
        for P in (64, 200, 400, 800, 1500, 2000):
            for _ in range(12):
                st = dict(P=P, n=0, K=0, H=P * rng.choice((0, P)), late=False, kmax=0, qmax=P)
                steps.append((("serial", P, 16), b, dict(st, occ=truth(st) * (1 + rng.gauss(0, 0.005)))))
    pb, lb, _, _ = evaluate_candidate("B", steps)
    pg, lg, _, _ = evaluate_candidate("W4g", steps)
    assert not pb, "\n".join(lb)
    assert pg, "\n".join(lg)
    print("ok: gated waves of four fail B and pass W4g")
    # The support rule: a held-out setting alone in its knot segment is unsupported, not failed.
    # Mutation that turns this red: judge an endpoint whatever its fold's support.
    # The fixture's 400- and 800-token serial settings are each alone in their knot segment; 200 shares (0, 256] with 64.
    assert any("unsupported (not judged): ('serial', 800, 16) prefill-only" in l for l in lg), "\n".join(lg)
    assert not any("unsupported (not judged): ('serial', 200, 16)" in l for l in lg), "\n".join(lg)
    print("ok: an endpoint with no training step in its knot segment is unsupported, not judged")
    assert wave(4, True)(dict(P=8, n=16, kmax=8192, qmax=8)) == 0.0
    assert wave(4, True)(dict(P=256, n=16, kmax=8192, qmax=256)) == 4 * 8192
    assert wave(5, False)(dict(P=8, n=16, kmax=8192, qmax=8)) == 4 * 8192
    assert wave(4, False)(dict(P=0, n=16, kmax=8192, qmax=0)) == 0.0
    print("ok: the wave column is ceil(n/w)*K_max in mixed steps, and the gate drops chunks of 16 tokens or fewer")


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
