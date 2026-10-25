"""Each archived hold-cap cell's pace in the gate's sense: the replay pace at which the replay's hold-cap prefill
median on that cell's own trace equals the card's measured median (the pace tool's definition of measured d).
Run from the repository root: python3 docs/superpowers/specs/data/2026-10-25-c3-main/card-pace.py"""
import sys, json
sys.path.insert(0, "hack/prospective-pilot")
import simulate as sim, pilot_report as pr

dirs = ["hack/m5c-20261008-235046-pilotA/m5c-run", "hack/m5c-20261009-013656-pilotB/m5c-run"]
fit = [sim.load_cell(d, a, r) for d in dirs for a, r in pr.cells(d)]
coef, _ = sim.fit_step_model(fit)
fwd = sim.offsets(fit)
CARDS = ["hack/m5c-20261009-122503-diagD/m5c-run", "hack/m5c-20261010-024449-frontierE/m5c-run",
         "hack/m5c-20261010-080107-lencalF/m5c-run", "hack/m5c-20261025-040425-headroomG/m5c-run"]
GRID = [round(1.0 + 0.005 * i, 3) for i in range(17)]


def measured_d(steps, adds):
    # The pace tool's: engine add to the end of the step that took the contender's last prompt token.
    ends, done = {}, {s["step"]: s["t2"] for s in steps if s.get("ev") == "done"}
    for s in (s for s in steps if s.get("ev") == "sched"):
        for e, n in s["tokens"].items():
            if e in adds and adds[e]["prompt"] > 1000 and e not in ends and s["computed"].get(e, 0) + n >= adds[e]["prompt"]:
                ends[e] = done[s["step"]]
    return pr.nearest_rank(sorted((ends[e] - adds[e]["mono"]) / 1e6 for e in ends), 0.5)


def replay_d(reqs, pace):
    o = sim.simulate(reqs, coef, sim.RULES["hold-one-prefill"], fwd, 8_000_000, long_prefill=384, step_scale=pace)
    pre = sorted((r["first_token"] - r["engaged"]) / 1e6 for r in o
                 if r["tenant"] == pr.CONTENDER and "first_token" in r and "engaged" in r)
    return pr.nearest_rank(pre, 0.5)


rows = []
for d in CARDS:
    for arm, rep in pr.cells(d):
        if not arm.startswith("hold-cap"):
            continue
        reqs, steps, adds = sim.load_cell(d, arm, rep)
        m = measured_d(steps, adds)
        curve = [(p, replay_d(reqs, p)) for p in GRID]
        pace = None
        for (p0, d0), (p1, d1) in zip(curve, curve[1:]):
            if d0 <= m <= d1 and d1 > d0:
                pace = p0 + (p1 - p0) * (m - d0) / (d1 - d0)
                break
        rows.append({"card": d.split("/")[1], "cell": "%s-%d" % (arm, rep), "measured_d_ms": m,
                     "replay_d_at_1.0_ms": curve[0][1], "replay_d_at_1.08_ms": curve[-1][1],
                     "d_matched_pace": None if pace is None else round(pace, 4)})
        print(json.dumps(rows[-1]), flush=True)
