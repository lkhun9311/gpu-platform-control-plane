"""Judge the llm-d-router #1598 pilot from what pilot.py recorded.

The pilot answers two questions, and decides nothing about the arms:
1. Does the apparatus work end to end: the token ledger, the lifecycle joins, router credit joined to cached_tokens, the
   4 Hz sampler, and each cell's validity checks?
2. Does K's burst concentrate at all on real engines (A1's mean largest share of 64 at or above 24)?

Exit status: 0 the apparatus holds and K was measured; 3 incomplete (a step was not run or the pilot stopped);
4 the apparatus failed a check, which a main run must not be bought on.
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import analysis  # noqa: E402
import logs  # noqa: E402
import sampler  # noqa: E402

PLAN = ["log-A-A1-v2", "log-A-A1-v5", "log-K-A1-v2", "log-K-A1-v5", "switch-A-A2", "switch-A-A3", "pressure-B-A1"]
K_THRESHOLD = 24
LAG_P99_S = 0.010


def read_rows(cdir):
    with open(os.path.join(cdir, "rows.jsonl")) as f:
        return [json.loads(x) for x in f]


def judge_cell(cdir):
    with open(os.path.join(cdir, "cell.json")) as f:
        meta = json.load(f)
    rows = read_rows(cdir)
    names = {f"default/vllm-{i}": e for i, e in enumerate(meta["engines"])}
    envoy, envoy_bad = logs.read_access(os.path.join(cdir, "access.log"))
    epp = logs.read_epp(os.path.join(cdir, "epp.log"), names)
    v5 = meta["verbosity"] >= 5
    epp_decided = set(epp["picked"]) if v5 else set()
    res = {"cell": meta["cell"], "arm": meta["arm"], "block": meta["block"], "verbosity": meta["verbosity"], "checks": {}}
    c = res["checks"]
    c["idle_at_start"] = bool(meta.get("idle_at_start"))
    c["reset"] = bool(meta.get("reset")) and all(meta["reset"].values())
    ok, led = analysis.ledger(rows, meta.get("deltas") or {})
    c["ledger"] = ok
    res["ledger"] = led
    jok, bad = analysis.join_valid(rows, envoy, epp_decided, v5)
    c["joins"] = jok
    res["unexplained"] = bad[:20]
    lags = [r["lag_s"] for r in rows if r.get("lag_s") is not None and r["population"] != "preload"]
    p99 = analysis.nearest_rank(lags, 99)
    # A probe sends one request after another, with no schedule to lag behind, so the dispatch-lag rule applies only to
    # scheduled cells; there an empty lag list is a failure, not a pass.
    if meta["kind"] != "probe":
        c["dispatch_lag"] = p99 is not None and p99 <= LAG_P99_S
    res["lag_p99_s"] = p99
    samples = sampler.read_samples(os.path.join(cdir, "samples.jsonl"))
    w = meta.get("window") or [0, 0]
    sok, why = analysis.sampler_ok(samples, meta["engines"], w[0], w[1] or w[0])
    c["sampler_4hz"] = sok
    res["sampler"] = why
    res["imbalance_cv"], res["imbalance_windows"] = analysis.imbalance([s for s in samples if w[0] <= s["t"] <= (w[1] or 0)],
                                                                      meta["engines"])
    ev = [r for r in rows if r["population"] == "eval"]
    tt = [analysis.ttft(r) for r in ev]
    res["n_eval"] = len(ev)
    res["completed"] = sum(analysis.completed(r) for r in ev)
    res["ttft_p50_s"], res["ttft_p95_s"], res["ttft_p99_s"] = (analysis.nearest_rank(tt, p) for p in (50, 95, 99))
    res["reused_fraction"] = analysis.reused_fraction(ev)
    try:
        with open(os.path.join(cdir, "epp-metrics.prom")) as f:
            res["epp_sched_p99_s"] = analysis.hist_quantile(f.read(), "scheduler_e2e_duration_seconds", 0.99)
    except FileNotFoundError:
        res["epp_sched_p99_s"] = None
    res["unparsable_epp_lines"] = epp["unparsable"]
    res["unparsable_envoy_lines"] = envoy_bad
    if v5 and meta["arm"] in ("A1", "A2"):
        cr = analysis.credit(ev, epp["match"])
        res["credit"] = {k: v for k, v in cr.items() if k != "rows"}
        res["credit_rows"] = len(cr["rows"])
        joined = sum(1 for r in ev if r.get("endpoint") and r["rid"] in epp["match"])
        fwd = sum(1 for r in ev if r.get("endpoint"))
        res["credit_join_share"] = (joined / fwd) if fwd else None
        c["credit_join"] = fwd > 0 and joined >= 0.995 * fwd
    if meta["block"] == "B":
        res["reuse"] = analysis.reuse(ev)
    if meta["kind"] == "K":
        shares, valid = [], []
        rows_by = {r["rid"]: r for r in rows}
        for b in meta.get("bursts", []):
            br = [rows_by[x] for x in b["rids"]]
            pr = [rows_by[x] for x in b["preloads"]]
            vok, vwhy, basis = analysis.burst_valid(br, pr, epp["picked"] if v5 else {})
            top, counts = analysis.largest_share(br)
            shares.append(top)
            valid.append({"burst": b["burst"], "valid": vok, "why": vwhy, "basis": basis, "largest": top, "counts": counts,
                          "idle_engine": sorted(set(meta["engines"]) - {p.get("endpoint") for p in pr})})
        res["bursts"] = valid
        vs = [v["largest"] for v in valid if v["valid"]]
        res["valid_bursts"] = len(vs)
        res["mean_largest_valid"] = (sum(vs) / len(vs)) if vs else None
    return res


def main(out):
    try:
        with open(os.path.join(out, "pilot.json")) as f:
            state = json.load(f)
    except FileNotFoundError:
        print("INCOMPLETE: no pilot.json")
        return 3
    cells = {}
    for name in state.get("cells", []):
        try:
            cells[name] = judge_cell(os.path.join(out, "cells", name))
        except Exception as e:  # noqa: BLE001 - a cell that cannot be judged is reported, not skipped silently
            cells[name] = {"cell": name, "error": f"{type(e).__name__}: {e}", "checks": {"judged": False}}
    v = {"cells": cells, "calibration": state.get("calibration"), "ramps": state.get("ramps"), "timings": state.get("timings"),
         "skipped": state.get("skipped"), "stopped": state.get("stopped")}
    failed = {n: [k for k, ok in c["checks"].items() if not ok] for n, c in cells.items()}
    failed = {n: f for n, f in failed.items() if f}
    missing = [n for n in PLAN if n not in cells]
    v["apparatus_failures"] = failed
    v["plan_cells_missing"] = missing
    k = [cells[n] for n in ("log-K-A1-v2", "log-K-A1-v5") if n in cells and cells[n].get("mean_largest_valid") is not None]
    if k:
        vals = [x["mean_largest_valid"] for x in k]
        v["k_effect"] = {"mean_largest_by_cell": {x["cell"]: x["mean_largest_valid"] for x in k}, "threshold": K_THRESHOLD,
                         "shows": all(m >= K_THRESHOLD for m in vals), "mixed": len({m >= K_THRESHOLD for m in vals}) > 1}
    lv2, lv5 = cells.get("log-A-A1-v2"), cells.get("log-A-A1-v5")
    kv2, kv5 = cells.get("log-K-A1-v2"), cells.get("log-K-A1-v5")
    if lv2 and lv5 and kv2 and kv5:
        # The registered logging rule: -v=5 stays only if it raises the EPP's scheduling p99 by at most 1 ms on either block
        # and moves K's mean largest share by at most 4 of 64; a value that could not be read keeps -v=2.
        deltas = []
        for lo, hi in ((lv2, lv5), (kv2, kv5)):
            a, b = lo.get("epp_sched_p99_s"), hi.get("epp_sched_p99_s")
            deltas.append(None if a is None or b is None else b - a)
        ka, kb = kv2.get("mean_largest_valid"), kv5.get("mean_largest_valid")
        share = None if ka is None or kb is None else abs(kb - ka)
        keep = all(d is not None and d <= 0.001 for d in deltas) and share is not None and share <= 4
        v["logging"] = {"epp_sched_p99_delta_s": {"A": deltas[0], "K": deltas[1]}, "k_share_delta": share, "keep_v5": keep}
    pr = cells.get("pressure-B-A1", {}).get("reuse")
    if pr:
        v["b_pressure"] = {"lost_share": pr["lost_share"], "is_pressure": (pr["lost_share"] or 0) >= 0.01}
    if failed:
        rc, word = 4, "APPARATUS FAILED"
    elif state.get("stopped") or missing or "k_effect" not in v:
        rc, word = 3, "INCOMPLETE"
    else:
        rc, word = 0, "APPARATUS HOLDS"
    v["verdict"] = word
    with open(os.path.join(out, "verdict.json"), "w") as f:
        json.dump(v, f, indent=1, sort_keys=True, default=str)
    lines = [f"verdict: {word}"]
    if failed:
        lines += [f"  {n}: failed {', '.join(f)}" for n, f in sorted(failed.items())]
    if missing:
        lines.append(f"  plan cells not run: {', '.join(missing)}")
    if state.get("stopped"):
        lines.append(f"  stopped: {state['stopped']}")
    if "k_effect" in v:
        ke = v["k_effect"]
        lines.append(f"K burst under A1: mean largest share {ke['mean_largest_by_cell']} (threshold {K_THRESHOLD} of 64): "
                     + ("shows" if ke["shows"] else ("mixed" if ke["mixed"] else "does not show")))
    for key in ("logging", "b_pressure"):
        if key in v:
            lines.append(f"{key}: {v[key]}")
    lines.append(f"calibration: {state.get('calibration')}")
    lines.append(f"ramps: {state.get('ramps')}")
    print("\n".join(lines))
    with open(os.path.join(out, "verdict.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
