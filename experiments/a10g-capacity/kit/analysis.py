"""The A10G capacity study's analysis: every rule of experiments/a10g-capacity/CONTRACT.md, on the raw rows.

Commands (each reads the contract the kit ships, never a copy of its numbers):

    analysis.py rung CONTRACT STAGE_DIR           one pilot rung's stability verdict; exit 0 stable, 10 unstable
    analysis.py plan CONTRACT PILOT_DIR           the saturation rule over the rung verdicts; writes cycle-plan.json
    analysis.py cycle CONTRACT STAGE_DIR          the recovery rule on one cycle; exit 0 recovered, 10 not recovered
    analysis.py report CONTRACT RESULTS_DIR       the session's ledgers, quantiles, recovery, restarts and exclusion rules

Any input the rules cannot be applied to is refused with exit 2 and a reason, rather than scored.
It uses only the standard library, because it runs on the instance under the session's bare Python.
"""

import json
import math
import os
import sys

EXIT_STABLE, EXIT_UNSTABLE, EXIT_REFUSED = 0, 10, 2


class Refused(Exception):
    """The evidence does not support applying a rule; the message says why."""


def load_contract(path):
    with open(path) as f:
        return json.load(f)


# ---------------------------------------------------------------- rows and the ledger


def read_stage(stage_dir):
    """Reads one stage's meta and rows, and refuses a recording that does not account for its trace."""
    with open(os.path.join(stage_dir, "meta.json")) as f:
        meta = json.load(f)
    rows = []
    with open(os.path.join(stage_dir, "raw.jsonl")) as f:
        for line in f:
            if line.strip():
                rows.append(json.loads(line))
    if meta.get("reconciled") is not True:
        raise Refused(f"{stage_dir}: the replay did not reconcile its recording: {meta.get('unreconciled', 'no verdict recorded')}")
    planned = sum(s["planned"] for s in meta["segments"])
    indices = sorted(r["index"] for r in rows)
    if planned != meta["rows"] or indices != list(range(planned)):
        raise Refused(f"{stage_dir}: {len(rows)} rows with indices that are not 0..{planned - 1}; the trace planned {planned}")
    for s in meta["segments"]:
        got = sum(1 for r in rows if r["tenant"] == s["name"])
        if got != s["planned"]:
            raise Refused(f"{stage_dir}: segment {s['name']} planned {s['planned']} and recorded {got}")
        for r in rows:
            if r["tenant"] == s["name"] and not (s["startMs"] <= r["scheduledOffsetMs"] < s["endMs"]):
                raise Refused(f"{stage_dir}: row {r['index']} lies outside its segment {s['name']}")
    return meta, rows


def contract_ok(row, contract, output_tokens):
    """The token contract on a stream that ended with [DONE]."""
    return (
        row.get("engineInputTokens") == contract["workload"]["input_tokens"]
        and row.get("engineOutputTokens") == output_tokens
        and row.get("finishReason") == "length"
    )


def classify(row, contract, output_tokens):
    """Returns (outcome, http axis, stream axis) for one row; outcome is unsent, completed, rejected or failed."""
    d = row.get("disposition", "")
    if not d:
        raise Refused(f"row {row['index']} has no disposition, so it cannot be placed in the ledger")
    if d == "unsent":
        return "unsent", "none", "not-sent"
    status = row.get("httpStatus", 0)
    kind = row.get("errorKind", "")
    if status == 200:
        http = "200"
        if d == "completed" and row.get("streamTerminated") and not row.get("streamError"):
            stream = "done" if contract_ok(row, contract, output_tokens) else "contract"
        elif kind == "timeout":
            stream = "timeout"
        elif row.get("streamError"):
            stream = "error"
        elif kind == "cancelled":
            stream = "transport"
        else:
            stream = "truncated"
    elif status == 0:
        http = "none"
        stream = "timeout" if kind == "timeout" else "transport"
    else:
        http = str(status)
        stream = "not-read"
    if http == "200" and stream == "done":
        return "completed", http, stream
    if http not in ("200", "none"):
        return "rejected", http, stream
    return "failed", http, stream


def ledger(rows, contract, output_tokens):
    """The outcome ledger with its two identities checked, and the HTTP-by-stream cross table."""
    led = {"planned": len(rows), "unsent": 0, "sent": 0, "completed": 0, "rejected": 0, "failed": 0, "cross": {}}
    for r in rows:
        outcome, http, stream = classify(r, contract, output_tokens)
        if outcome == "unsent":
            led["unsent"] += 1
            continue
        led["sent"] += 1
        led[outcome] += 1
        key = f"{http}/{stream}"
        led["cross"][key] = led["cross"].get(key, 0) + 1
    if led["planned"] != led["unsent"] + led["sent"]:
        raise Refused(f"planned {led['planned']} != unsent {led['unsent']} + sent {led['sent']}")
    if led["sent"] != led["completed"] + led["rejected"] + led["failed"]:
        raise Refused(f"sent {led['sent']} != completed + rejected + failed")
    return led


def nanos(row, field):
    c = row.get("clock") or {}
    return c.get(field)


def ttft_ms(row):
    s, f = nanos(row, "sendNanos"), nanos(row, "firstContentNanos")
    return None if s is None or f is None else (f - s) / 1e6


def e2e_ms(row):
    s, d = nanos(row, "sendNanos"), nanos(row, "doneNanos")
    return None if s is None or d is None else (d - s) / 1e6


def lag_ms(row):
    s, i = nanos(row, "sendNanos"), nanos(row, "intendedNanos")
    return None if s is None or i is None else (s - i) / 1e6


def quantile(values, q):
    """Nearest rank: the smallest value with at least q of the population at or below it."""
    if not values:
        return None
    v = sorted(values)
    return v[max(math.ceil(q * len(v)) - 1, 0)]


def quantiles(values, min_p99):
    """p99 first, then p90 and p50, each with the count; a p99 under the minimum is refused, not printed."""
    n = len(values)
    return {
        "n": n,
        "p99": quantile(values, 0.99) if n >= min_p99 else None,
        "p90": quantile(values, 0.90),
        "p50": quantile(values, 0.50),
    }


def fmt_q(name, q):
    p99 = f"{q['p99']:.1f}" if q["p99"] is not None else f"insufficient (n={q['n']})"
    p90 = f"{q['p90']:.1f}" if q["p90"] is not None else "-"
    p50 = f"{q['p50']:.1f}" if q["p50"] is not None else "-"
    return f"{name}: p99 {p99} ms, p90 {p90} ms, p50 {p50} ms, n={q['n']}"


def completed_rows(rows, contract, output_tokens):
    return [r for r in rows if classify(r, contract, output_tokens)[0] == "completed"]


def window(rows, start_ms, end_ms):
    return [r for r in rows if start_ms <= r["scheduledOffsetMs"] < end_ms]


# ---------------------------------------------------------------- stability, saturation and the cycle plan


def stability(rows, start_ms, end_ms, contract, output_tokens):
    """S1 to S3 over a measured window [start_ms, end_ms), by intended arrival."""
    st = contract["stability"]
    min_p99 = contract["metrics"]["min_samples_p99"]
    w = window(rows, start_ms, end_ms)
    led = ledger(w, contract, output_tokens)
    done = completed_rows(w, contract, output_tokens)
    ttfts = [ttft_ms(r) for r in done]
    q = quantiles(ttfts, min_p99)
    reasons = []
    frac = led["completed"] / led["sent"] if led["sent"] else 0.0
    if frac < st["min_completed_fraction"]:
        reasons.append(f"S1 completed {led['completed']} of {led['sent']} sent ({frac:.4f} < {st['min_completed_fraction']})")
    if q["p99"] is None:
        reasons.append(f"S2 insufficient samples for p99 (n={q['n']} < {min_p99})")
    elif q["p99"] > st["max_p99_ttft_ms"]:
        reasons.append(f"S2 p99 TTFT {q['p99']:.1f} ms > {st['max_p99_ttft_ms']} ms")
    third = (end_ms - start_ms) / 3
    first = [ttft_ms(r) for r in done if r["scheduledOffsetMs"] < start_ms + third]
    last = [ttft_ms(r) for r in done if r["scheduledOffsetMs"] >= end_ms - third]
    if not first or not last:
        reasons.append("S3 a third of the window has no completed request")
        m1 = m3 = None
    else:
        m1, m3 = quantile(first, 0.5), quantile(last, 0.5)
        if m3 > st["trend_ratio"] * m1 + st["trend_slack_ms"]:
            reasons.append(f"S3 last-third median TTFT {m3:.1f} ms > {st['trend_ratio']} x {m1:.1f} + {st['trend_slack_ms']} ms")
    return {
        "stable": not reasons,
        "reasons": reasons,
        "ledger": led,
        "completed_fraction": frac,
        "ttft": q,
        "first_third_median_ms": m1,
        "last_third_median_ms": m3,
    }


def rung_verdict(contract, stage_dir):
    meta, rows = read_stage(stage_dir)
    if len(meta["segments"]) != 1:
        raise Refused(f"{stage_dir}: a pilot rung has one segment, this has {len(meta['segments'])}")
    seg = meta["segments"][0]
    start = seg["startMs"] + contract["pilot"]["rung_warmup_s"] * 1000
    v = stability(rows, start, seg["endMs"], contract, meta["outputTokens"])
    v["rate_rps"] = seg["rateRps"]
    name = os.path.basename(stage_dir.rstrip("/"))
    if not name.startswith("rung-") or not name[5:].isdigit():
        raise Refused(f"{stage_dir}: a pilot rung's directory is rung-NN")
    v["rung"] = int(name[5:])
    return v


def saturation(verdicts, contract):
    """The saturation rule over the rung verdicts in ladder order, which must be a prefix of the contract's ladder."""
    ladder = contract["pilot"]["rungs_rps"]
    rates = [v["rate_rps"] for v in verdicts]
    if not rates or rates != ladder[: len(rates)]:
        raise Refused(f"the pilot's rungs {rates} are not a prefix of the contract's ladder {ladder}")
    for v in verdicts[:-1]:
        if not v["stable"]:
            raise Refused("the pilot continued past an unstable rung")
    last = verdicts[-1]
    if not last["stable"]:
        if len(verdicts) == 1:
            return {"status": "saturation below the ladder", "r_sat": None, "first_unstable": last["rate_rps"]}
        return {"status": "saturated", "r_sat": verdicts[-2]["rate_rps"], "first_unstable": last["rate_rps"]}
    if len(verdicts) == len(ladder):
        return {"status": f"saturation at or above {ladder[-1]} req/s", "r_sat": ladder[-1], "first_unstable": None}
    return {"status": "pilot budget exhausted", "r_sat": last["rate_rps"], "first_unstable": None}


def cycle_plan(sat, contract):
    """The cycle's rates and segments from R_sat, or the reason no cycle runs."""
    c = contract["cycle"]
    if sat["r_sat"] is None:
        return {"run": False, "reason": sat["status"], **sat}
    r_sat = sat["r_sat"]
    r_low = max(c["low_fraction_of_sat"] * r_sat, c["low_min_rps"])
    if r_low > c["low_max_fraction_of_sat"] * r_sat:
        return {"run": False, "reason": f"R_low {r_low:g} exceeds {c['low_max_fraction_of_sat']} x R_sat {r_sat:g}", **sat}
    r_over = c["overload_factor"] * r_sat
    segs = [
        ("baseline", r_low, c["baseline_s"]),
        ("saturation", r_sat, c["saturation_s"]),
        ("overload", r_over, c["overload_s"]),
        ("recovery", r_low, c["recovery_s"]),
    ]
    return {
        "run": True,
        "r_low": r_low,
        "r_sat": r_sat,
        "r_over": r_over,
        "overload_is_overload": sat["status"] == "saturated",
        "segments": ",".join(f"{n}:{r:g}:{d:g}" for n, r, d in segs),
        **{k: v for k, v in sat.items() if k != "r_sat"},
    }


def plan_command(contract, pilot_dir):
    names = sorted(d for d in os.listdir(pilot_dir) if d.startswith("rung-") and d.endswith(".verdict.json"))
    verdicts = []
    for n in names:
        with open(os.path.join(pilot_dir, n)) as f:
            verdicts.append(json.load(f))
    verdicts.sort(key=lambda v: v["rung"])
    return cycle_plan(saturation(verdicts, contract), contract)


# ---------------------------------------------------------------- the cycle's stages and the recovery rule


def stage_summary(rows, seg, measured_start, contract, output_tokens):
    min_p99 = contract["metrics"]["min_samples_p99"]
    w = window(rows, measured_start, seg["endMs"])
    led = ledger(w, contract, output_tokens)
    done = completed_rows(w, contract, output_tokens)
    seconds = (seg["endMs"] - measured_start) / 1000
    return {
        "segment": seg["name"],
        "rate_rps": seg["rateRps"],
        "measured_from_ms": measured_start,
        "ledger": led,
        "completed_fraction": led["completed"] / led["sent"] if led["sent"] else None,
        "ttft": quantiles([ttft_ms(r) for r in done], min_p99),
        "e2e": quantiles([e2e_ms(r) for r in done], min_p99),
        "completed_rps": len(done) / seconds,
        "output_tokens_per_s": sum(r["engineOutputTokens"] for r in done) / seconds,
    }


def recovery(rows, base, rec_seg, contract, output_tokens):
    """The recovery rule: tumbling windows by intended arrival from the end of overload."""
    rc = contract["recovery"]
    if base["ttft"]["p99"] is None:
        raise Refused(f"the baseline has too few completed requests (n={base['ttft']['n']}) to be the recovery reference")
    limit = rc["p90_ratio"] * base["ttft"]["p90"] + rc["p90_slack_ms"]
    w_ms = rc["window_s"] * 1000
    count = int((rec_seg["endMs"] - rec_seg["startMs"]) // w_ms)
    windows = []
    for k in range(count):
        a = rec_seg["startMs"] + k * w_ms
        w = window(rows, a, a + w_ms)
        led = ledger(w, contract, output_tokens)
        done = completed_rows(w, contract, output_tokens)
        p90 = quantile([ttft_ms(r) for r in done], 0.90)
        if led["sent"] < rc["min_window_sent"]:
            state = "insufficient"
        elif led["completed"] == led["sent"] and p90 is not None and p90 <= limit:
            state = "recovered"
        else:
            state = "not recovered"
        windows.append({"start_s": k * rc["window_s"], "sent": led["sent"], "completed": led["completed"], "p90_ttft_ms": p90, "state": state})
    need = rc["consecutive_windows"]
    for k in range(len(windows) - need + 1):
        if all(w["state"] == "recovered" for w in windows[k : k + need]):
            return {"recovered": True, "recovery_s": windows[k]["start_s"], "limit_p90_ms": limit, "windows": windows}
    longest = (len(windows) - need) * rc["window_s"]
    return {"recovered": False, "result": f"not recovered within {longest} s", "limit_p90_ms": limit, "windows": windows}


def read_samples(path):
    out = []
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                if line.strip():
                    out.append(json.loads(line))
    return out


def engine_peaks(samples, origin_s, seg):
    """Peaks of the 1 s scrapes whose time lies in the segment's wall-clock span."""
    a, b = origin_s + seg["startMs"] / 1000, origin_s + seg["endMs"] / 1000
    inside = [s for s in samples if a <= s["t"] < b]
    peak = {"scrapes": len(inside)}
    for key in ("waiting", "running", "kv"):
        vals = [s[key] for s in inside if s.get(key) is not None]
        peak[key] = max(vals) if vals else "not recorded"
    names = sorted({s["kv_name"] for s in inside if s.get("kv_name")})
    peak["kv_name"] = names[0] if len(names) == 1 else (names or "not recorded")
    return peak


def lag_check(rows, contract):
    m = contract["metrics"]
    sent = [r for r in rows if r.get("disposition") != "unsent"]
    lagged = [r for r in sent if (lag_ms(r) or 0) > m["max_dispatch_lag_ms"]]
    frac = len(lagged) / len(sent) if sent else 0.0
    return {"sent": len(sent), "lagged": len(lagged), "fraction": frac, "ok": frac <= m["max_lagged_fraction"]}


def report(contract, results_dir):
    """The whole session: each stage's ledger and quantiles, the saturation, overload and recovery, the restarts, and X3 to X5."""
    rep = {"contract": contract["contract"], "exclusions": [], "stages": {}}
    pilot = os.path.join(results_dir, "pilot")
    rungs = sorted(f"pilot/{d}" for d in os.listdir(pilot)) if os.path.isdir(pilot) else []
    stage_dirs = [d for d in ["warmup", *rungs, "cycle"] if os.path.isfile(os.path.join(results_dir, d, "meta.json"))]
    samples = read_samples(os.path.join(results_dir, "engine-samples.jsonl"))
    for d in stage_dirs:
        path = os.path.join(results_dir, d)
        try:
            meta, rows = read_stage(path)
            ledger(rows, contract, meta["outputTokens"])
        except Refused as e:
            rep["exclusions"].append(f"X4 {e}")
            continue
        out_tokens = meta["outputTokens"]
        bad = [r["index"] for r in rows if classify(r, contract, out_tokens)[2] == "contract"]
        if bad:
            rep["exclusions"].append(f"X3 {d}: {len(bad)} [DONE] stream(s) broke the token contract (rows {bad[:5]})")
        lag = lag_check(rows, contract)
        if not lag["ok"]:
            rep["exclusions"].append(f"X5 {d}: {lag['lagged']} of {lag['sent']} sent requests left more than {contract['metrics']['max_dispatch_lag_ms']} ms late")
        entry = {"lag": lag, "segments": {}}
        origin = next((r["clock"]["originUnixNanos"] / 1e9 for r in rows if r.get("clock")), None)
        cw = contract["cycle"]["stage_warmup_s"] * 1000
        for seg in meta["segments"]:
            if d == "cycle":
                skip = cw if seg["name"] in ("baseline", "saturation") else 0
            elif d.startswith("pilot/rung-"):
                skip = contract["pilot"]["rung_warmup_s"] * 1000
            else:
                skip = seg["endMs"] - seg["startMs"]
            if skip >= seg["endMs"] - seg["startMs"]:
                entry["segments"][seg["name"]] = {"excluded": "warm-up", "ledger": ledger(window(rows, seg["startMs"], seg["endMs"]), contract, out_tokens)}
                continue
            s = stage_summary(rows, seg, seg["startMs"] + skip, contract, out_tokens)
            if origin is not None:
                s["engine"] = engine_peaks(samples, origin, seg)
            entry["segments"][seg["name"]] = s
        if d == "cycle":
            segs = {s["name"]: s for s in meta["segments"]}
            base = entry["segments"]["baseline"]
            sat_seg = segs["saturation"]
            entry["saturation_held"] = stability(rows, sat_seg["startMs"] + cw, sat_seg["endMs"], contract, out_tokens)
            try:
                entry["recovery"] = recovery(rows, base, segs["recovery"], contract, out_tokens)
            except Refused as e:
                entry["recovery"] = {"refused": str(e)}
            if origin is not None:
                end_over = origin + segs["overload"]["endMs"] / 1000
                zero = [s["t"] for s in samples if s["t"] >= end_over and s.get("waiting") == 0]
                entry["engine_drain_s"] = (min(zero) - end_over) if zero else "waiting never read 0"
        rep["stages"][d] = entry
    rep["restarts"] = []
    for name in sorted(n for n in os.listdir(results_dir) if n.startswith("restart-") and n.endswith(".json")):
        with open(os.path.join(results_dir, name)) as f:
            r = json.load(f)
        bad_probe = [p for p in r.get("probes", []) if p.get("httpStatus") == 200 and p.get("streamTerminated") and not p.get("ok")]
        if bad_probe:
            rep["exclusions"].append(f"X3 {name}: {len(bad_probe)} [DONE] probe(s) broke the token contract")
        rep["restarts"].append({"index": r["index"], "outcome": r["outcome"], "window_s": (r["windowMs"] / 1000) if r.get("windowMs") is not None else None, "probes": len(r.get("probes", []))})
    plan_path = os.path.join(results_dir, "pilot", "cycle-plan.json")
    if os.path.exists(plan_path):
        with open(plan_path) as f:
            rep["plan"] = json.load(f)
    rep["included_by_x3_x5"] = not rep["exclusions"]
    return rep


def render(rep):
    out = [f"contract {rep['contract']}"]
    if "plan" in rep:
        p = rep["plan"]
        out.append(f"pilot: {p.get('status')}, R_sat {p.get('r_sat')}, first unstable {p.get('first_unstable')}")
    for d, e in rep["stages"].items():
        out.append(f"[{d}] dispatch lag: {e['lag']['lagged']} of {e['lag']['sent']} over the bound")
        for name, s in e["segments"].items():
            led = s["ledger"]
            out.append(f"  {name}: planned {led['planned']} = unsent {led['unsent']} + sent {led['sent']}; sent = completed {led['completed']} + rejected {led['rejected']} + failed {led['failed']}; http/stream {led['cross']}")
            if "ttft" in s:
                out.append("    " + fmt_q("TTFT", s["ttft"]) + f"; completed fraction {s['completed_fraction']}")
                out.append("    " + fmt_q("E2E", s["e2e"]) + f"; {s['completed_rps']:.2f} completed req/s, {s['output_tokens_per_s']:.1f} output tok/s")
                if "engine" in s:
                    out.append(f"    engine peak of 1 s scrapes: {s['engine']}")
        if "saturation_held" in e:
            out.append(f"  saturation held: {e['saturation_held']['stable']} {e['saturation_held']['reasons']}")
            rec = e["recovery"]
            if rec.get("recovered"):
                out.append(f"  recovery: {rec['recovery_s']} s after overload (p90 limit {rec['limit_p90_ms']:.1f} ms)")
            else:
                out.append(f"  recovery: {rec.get('result', rec.get('refused'))}")
            out.append(f"  engine drain: {e.get('engine_drain_s')}")
    for r in rep["restarts"]:
        out.append(f"restart {r['index']}: {r['outcome']}, window {r['window_s']} s, {r['probes']} probe(s)")
    out.append("exclusions: " + ("; ".join(rep["exclusions"]) if rep["exclusions"] else "none under X3 to X5"))
    return "\n".join(out)


def scaled(contract, s):
    """The contract with time compressed by s, for the CPU rehearsal: durations and latency bounds times s, rates over s.

    Request counts per stage and window stay what the GPU run plans, so every sample-count rule is rehearsed at its real size.
    Integers the Go side reads stay integers.
    """
    c = json.loads(json.dumps(contract))
    c["contract"] += f"-rehearsal-x{s:g}"
    t = lambda v: v * s
    whole = lambda v: max(int(round(v * s)), 1)
    c["workload"]["request_timeout_s"] = whole(c["workload"]["request_timeout_s"])
    c["warmup"]["rate_rps"] = round(c["warmup"]["rate_rps"] / s, 6)
    c["warmup"]["duration_s"] = t(c["warmup"]["duration_s"])
    p = c["pilot"]
    p["rungs_rps"] = [round(r / s, 6) for r in p["rungs_rps"]]
    for k in ("rung_s", "rung_warmup_s", "drain_idle_s", "drain_gauge_timeout_s", "budget_s"):
        p[k] = t(p[k])
    st = c["stability"]
    st["max_p99_ttft_ms"] = t(st["max_p99_ttft_ms"])
    st["trend_slack_ms"] = t(st["trend_slack_ms"])
    cy = c["cycle"]
    cy["low_min_rps"] = round(cy["low_min_rps"] / s, 6)
    for k in ("baseline_s", "saturation_s", "overload_s", "recovery_s", "stage_warmup_s"):
        cy[k] = t(cy[k])
    rc = c["recovery"]
    rc["window_s"] = t(rc["window_s"])
    rc["p90_slack_ms"] = t(rc["p90_slack_ms"])
    rs = c["restart"]
    rs["idle_before_s"] = t(rs["idle_before_s"])
    rs["probe_interval_ms"] = whole(rs["probe_interval_ms"])
    rs["probe_timeout_s"] = whole(rs["probe_timeout_s"])
    rs["bound_s"] = whole(rs["bound_s"])
    c["session"]["budget_s"] = t(c["session"]["budget_s"])
    return c


def main(argv):
    if len(argv) < 4:
        print(__doc__, file=sys.stderr)
        return EXIT_REFUSED
    cmd, contract = argv[1], load_contract(argv[2])
    try:
        if cmd == "scale":
            print(json.dumps(scaled(contract, float(argv[3])), indent=2))
            return 0
        if cmd == "rung":
            v = rung_verdict(contract, argv[3])
            print(json.dumps(v, indent=2))
            return EXIT_STABLE if v["stable"] else EXIT_UNSTABLE
        if cmd == "plan":
            p = plan_command(contract, argv[3])
            with open(os.path.join(argv[3], "cycle-plan.json"), "w") as f:
                json.dump(p, f, indent=2)
            print(json.dumps(p, indent=2))
            return 0
        if cmd == "cycle":
            meta, rows = read_stage(argv[3])
            segs = {s["name"]: s for s in meta["segments"]}
            if list(segs) != ["baseline", "saturation", "overload", "recovery"]:
                raise Refused(f"{argv[3]}: a cycle's segments are baseline, saturation, overload and recovery, not {list(segs)}")
            cw = contract["cycle"]["stage_warmup_s"] * 1000
            base = stage_summary(rows, segs["baseline"], segs["baseline"]["startMs"] + cw, contract, meta["outputTokens"])
            rec = recovery(rows, base, segs["recovery"], contract, meta["outputTokens"])
            print(json.dumps(rec, indent=2))
            return EXIT_STABLE if rec["recovered"] else EXIT_UNSTABLE
        if cmd == "report":
            rep = report(contract, argv[3])
            with open(os.path.join(argv[3], "report.json"), "w") as f:
                json.dump(rep, f, indent=2)
            text = render(rep)
            with open(os.path.join(argv[3], "report.txt"), "w") as f:
                f.write(text + "\n")
            print(text)
            return 0 if rep["included_by_x3_x5"] else 3
    except Refused as e:
        print(f"REFUSED: {e}", file=sys.stderr)
        return EXIT_REFUSED
    print(f"unknown command {cmd}", file=sys.stderr)
    return EXIT_REFUSED


if __name__ == "__main__":
    sys.exit(main(sys.argv))
