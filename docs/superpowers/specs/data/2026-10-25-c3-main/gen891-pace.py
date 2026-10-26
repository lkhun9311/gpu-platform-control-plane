"""The replay pace at which the generated seed-891 trace's hold-cap median matches a card's, as the gate's nominal was chosen.
Run from the repository root: python3 docs/superpowers/specs/data/2026-10-25-c3-main/gen891-pace.py <trace> <pace>..."""
import sys
sys.path.insert(0, "hack/prospective-pilot")
import simulate as sim, pilot_report as pr
dirs = ["hack/m5c-20261008-235046-pilotA/m5c-run", "hack/m5c-20261009-013656-pilotB/m5c-run"]
cells = [sim.load_cell(d, a, r) for d in dirs for a, r in pr.cells(d)]
coef, _ = sim.fit_step_model(cells)
fwd, lag = sim.offsets(cells), sim.dispatch_lag(cells)
reqs = sim.load_trace(sys.argv[1], lag)
for p in [float(x) for x in sys.argv[2:]]:
    o = sim.simulate(reqs, coef, sim.RULES["hold-one-prefill"], fwd, 8_000_000, long_prefill=384, step_scale=p)
    pre = sorted((r["first_token"] - r["engaged"]) / 1e6 for r in o if r["tenant"] == pr.CONTENDER and "first_token" in r and "engaged" in r)
    print(p, round(pr.nearest_rank(pre, 0.5), 3))
