"""C3 main study's purchase gate (gate.txt): the replay of seeds 882, 892 and 893 with every arm, scored per seed.

predict-c3-derived.py's model and arms, unchanged, with what that script did not keep: each seed's limits and
hold-cap prefill median, unrounded pooled p99s, and the conditions G1 to G5.
Run from the repository root:
    python3 predict-main-gate.py <trace-root> <pace> <S ms> <short ms> <long ms>
"""
import sys, math, json
sys.path.insert(0, "hack/prospective-pilot")
import simulate as sim, pilot_report as pr

root, pace = sys.argv[1], float(sys.argv[2])
S, SHORT, LONG = (float(x) for x in sys.argv[3:6])
SEEDS = (882, 892, 893)
LENGTHS = ("short", "ref", "long")
SPACING = {"short": SHORT, "ref": S, "long": LONG}

dirs = ["hack/m5c-20261008-235046-pilotA/m5c-run", "hack/m5c-20261009-013656-pilotB/m5c-run"]
cells = [sim.load_cell(d, a, r) for d in dirs for a, r in pr.cells(d)]
coef, _ = sim.fit_step_model(cells)
fwd, lag = sim.offsets(cells), sim.dispatch_lag(cells)
ARMS = {"off": (sim.RULES["off"], 0), "caponly": (sim.RULES["off"], 384),
        "hold-cap": (sim.RULES["hold-one-prefill"], 384), "fixedS": (None, 384), "sizeaware": (None, 384)}


def rule(arm, length):
    if arm == "fixedS":
        return sim.hold_spacing(S * 1e6)
    if arm == "sizeaware":
        return sim.hold_spacing(SPACING[length] * 1e6)
    return ARMS[arm][0]


out = {"pace": pace, "seeds": list(SEEDS), "fixed_spacing_ms": S, "size_aware_ms": SPACING}
for L in LENGTHS:
    pooled = {a: [] for a in ARMS}
    per_seed = {}
    all_pre = []
    for seed in SEEDS:
        reqs = sim.load_trace("%s/lr/t%d-off-%s.jsonl" % (root, seed, L), lag)
        res, d = {}, None
        for a, (_, cap) in ARMS.items():
            o = sim.simulate(reqs, coef, rule(a, L), fwd, 8_000_000, long_prefill=cap, step_scale=pace)
            pooled[a].extend(o)
            res[a] = sim.summarize(o)
            if a == "hold-cap":
                pre = sorted((r["first_token"] - r["engaged"]) / 1e6 for r in o
                             if r["tenant"] == pr.CONTENDER and "first_token" in r and "engaged" in r)
                d = pr.nearest_rank(pre, 0.5)
                all_pre += pre
        per_seed[seed] = {"hold_cap_prefill_p50_ms": d,
                          "limits_failed": {a: sim.owner_limits(res[a], res["off"]) for a in ARMS if a != "off"},
                          "premium_p99_ms": {a: res[a]["premium_p99_ms"] for a in ARMS},
                          "contender_completion_p95_ms": {a: res[a]["contender_completion_p95_ms"] for a in ARMS}}
    out[L] = {"pooled_premium_p99_ms": {a: sim.summarize(pooled[a])["premium_p99_ms"] for a in ARMS},
              "pooled_hold_cap_prefill_p50_ms": pr.nearest_rank(sorted(all_pre), 0.5), "per_seed": per_seed}


def p99(arm, L):
    return out[L]["pooled_premium_p99_ms"][arm]


def fails(arm, L):
    return [s for s in SEEDS if out[L]["per_seed"][s]["limits_failed"][arm]]


def below(a, b):
    # a at least 15% below b; an infinite a never is, and an infinite b is beaten by any finite a (simulate.beats).
    return sim.beats(a, b)


def log_ratio(a, b):
    # ln(a / b) with an infinite b and finite a at -inf, and an infinite a at +inf.
    if math.isinf(a):
        return math.inf
    if math.isinf(b):
        return -math.inf
    return math.log(a / b)


gate = {}
gate["G1 hold-cap inside the four modelled limits at every length on every seed"] = all(not fails("hold-cap", L) for L in LENGTHS)
gate["G2 hold-cap pooled p99 <= 0.85 x off's at every length"] = all(below(p99("hold-cap", L), p99("off", L)) for L in LENGTHS)
ds = {s: (out["ref"]["per_seed"][s]["hold_cap_prefill_p50_ms"], out["long"]["per_seed"][s]["hold_cap_prefill_p50_ms"]) for s in SEEDS}
gate["G3 on every seed d(ref) <= S, d(long) > S and d(long) > 1.05 d(ref)"] = all(
    r <= S and l > S and l > 1.05 * r for r, l in ds.values())
gate["G4 fixed-S inside the limits at ref, protective there, and neither it nor hold-cap 15% below the other"] = (
    not fails("fixedS", "ref") and below(p99("fixedS", "ref"), p99("off", "ref"))
    and not below(p99("hold-cap", "ref"), p99("fixedS", "ref")) and not below(p99("fixedS", "ref"), p99("hold-cap", "ref")))
interaction = log_ratio(p99("hold-cap", "long"), p99("fixedS", "long")) - log_ratio(p99("hold-cap", "ref"), p99("fixedS", "ref"))
gate["G5 at long fixed-S breaks a limit or hold-cap is 15% below it, and the interaction is at most ln 0.85"] = (
    (bool(fails("fixedS", "long")) or below(p99("hold-cap", "long"), p99("fixedS", "long"))) and interaction <= math.log(0.85))
out["interaction_ln"] = interaction
out["gate"] = gate
out["gate_passes"] = all(gate.values())
print(json.dumps(out, indent=1, default=str))
