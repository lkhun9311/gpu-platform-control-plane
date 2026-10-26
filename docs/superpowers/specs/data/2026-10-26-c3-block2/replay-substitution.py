"""The gate's replay model (data/2026-10-25-c3-main/predict-main-gate.py, unchanged) for fixed-S at long, run two ways:
each seed at its own card's measured pace (card-pace-main.jsonl), and seed 882's contenders with another seed's
premium schedule, at one pace, so the contender queue is held fixed while only the premium arrivals change.
Run from the repository root with the gate's trace root, the directory whose lr/ holds t<seed>-off-long.jsonl:
  python3 docs/superpowers/specs/data/2026-10-26-c3-block2/replay-substitution.py <trace-root>
Those traces are byte-identical to the archived trace-off-long-1.jsonl of each block."""
import sys
sys.path.insert(0, "hack/prospective-pilot")
import simulate as sim, pilot_report as pr

root = sys.argv[1]
S = 1680.4
PACE = {882: 1.0306, 892: 1.0304, 893: 1.0269}
dirs = ["hack/m5c-20261008-235046-pilotA/m5c-run", "hack/m5c-20261009-013656-pilotB/m5c-run"]
cells = [sim.load_cell(d, a, r) for d in dirs for a, r in pr.cells(d)]
coef, _ = sim.fit_step_model(cells)
fwd, lag = sim.offsets(cells), sim.dispatch_lag(cells)
trace = {s: sim.load_trace("%s/lr/t%d-off-long.jsonl" % (root, s), lag) for s in PACE}


def fixed_s(reqs, pace):
    o = sim.simulate(reqs, coef, sim.hold_spacing(S * 1e6), fwd, 8_000_000, long_prefill=384, step_scale=pace)
    return sim.summarize(o)["premium_p99_ms"]


print("case\tpace\tfixedS premium p99 ms")
for s, pace in PACE.items():
    print("seed %d at its card's pace\t%s\t%.1f" % (s, pace, fixed_s(trace[s], pace)))
# Each seed's contenders under every seed's premium schedule, at the contenders' own card's pace; the diagonal is the
# control and must equal the first rows.
for c in PACE:
    contenders = [r for r in trace[c] if r["tenant"] == pr.CONTENDER]
    for s in PACE:
        premium = [r for r in trace[s] if r["tenant"] != pr.CONTENDER]
        reqs = sorted(contenders + premium, key=lambda r: r["sched"])
        print("seed %d's contenders, seed %d's premium\t%s\t%.1f" % (c, s, PACE[c], fixed_s(reqs, PACE[c])))
