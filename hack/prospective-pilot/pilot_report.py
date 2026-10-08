"""The prospective-admission pilot's measurement report.

    python3 pilot_report.py stage DIR [A|B]      one stage's measurements, as JSON, to stdout; with the stage named,
                                                 its missing cells are listed
    python3 pilot_report.py formulas DIR_A DIR_B  the frozen calibration formulas' outputs, or why they are unavailable

docs/superpowers/specs/2026-10-08-measuring-prospective-admission-design.md, "The measurement pilot". It judges
nothing about P against S: it reports measurements, marks each arm eligible or not for calibration, and computes the
formulas that were frozen before the pilot. It prints no P/S ratio; widths are per arm, and the pooled P/S width is
their sum (design page, "Stage B is not blind").
"""

import csv
import glob
import json
import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pilot_evidence  # noqa: E402

PREMIUM = "premium-1"
# Each stage's registered arms, three blocks each. The formulas need every one of them, so the inventory is
# checked against this rather than read from whatever raw files exist (review of 97ae105, finding 3).
STAGE_ARMS = {"A": ("R1", "off", "prospective"), "B": ("R1", "off", "static-cap", "prospective")}
BLOCKS = 3
CONTENDER = "standard-noisy"
L_MS_FLOOR = 5.0
CEILING_MS_FLOOR = 50.0
OWN_PREFIXES = ("fence-", "calib-")
ITER = re.compile(r"Iteration\((\d+)\): (\d+) context requests, (\d+) context tokens, (\d+) generation requests, "
                  r"(\d+) generation tokens")


def jsonl(path):
    out = []
    if not os.path.exists(path):
        return out
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def nearest_rank(values, q):
    """The repository's nearest-rank quantile (internal/bench/report.go): the ceil(q*n)-th smallest."""
    if not values:
        return None
    v = sorted(values)
    k = max(1, math.ceil(q * len(v)))
    return v[k - 1]


def summary(values):
    if not values:
        return {"n": 0}
    return {"n": len(values), "p50": nearest_rank(values, 0.5), "p99": nearest_rank(values, 0.99),
            "p999": nearest_rank(values, 0.999), "max": max(values)}


def cells(stage_dir):
    """(arm, rep) for every replayed cell of a stage."""
    out = []
    for p in sorted(glob.glob(os.path.join(stage_dir, "raw-*-[0-9]*.jsonl"))):
        m = re.match(r"raw-(.+)-(\d+)\.jsonl$", os.path.basename(p))
        if m:
            out.append((m.group(1), int(m.group(2))))
    return out


def gateway_records(path):
    """requestId -> {"arrive": line|None, "done": line|None, "dup": bool}."""
    recs = {}
    for r in jsonl(path):
        e = recs.setdefault(r["requestId"], {"arrive": None, "done": None, "dup": False})
        if e[r["ev"]] is not None:
            e["dup"] = True
        e[r["ev"]] = r
    return recs


def is_success(row):
    return not row.get("errorKind") and row.get("httpStatus") == 200


def full_output(row, cap):
    return is_success(row) and row.get("engineOutputTokens") == cap


def ms(ns):
    return ns / 1e6


def iteration_totals(engine_log):
    """index -> total tokens, from the engine's own iteration lines."""
    out = {}
    with open(engine_log, errors="replace") as f:
        for line in f:
            m = ITER.search(line)
            if m:
                out[int(m.group(1))] = int(m.group(3)) + int(m.group(5))
    return out


def step_alignment(steps, iters):
    """(ok, why): plugin steps 1..k_f match iterations 0..k_f-1 in token totals, k_f the fence's last step."""
    sched = [r for r in steps if r.get("ev") == "sched"]
    fence = [r for r in sched if any(i.startswith("chatcmpl-fence-") or "fence-" in i for i in r["tokens"])]
    if not fence:
        return False, "the fence never reached the step log"
    k_f = max(r["step"] for r in fence)
    by_step = {r["step"]: sum(r["tokens"].values()) for r in sched}
    if sorted(by_step) != list(range(1, len(by_step) + 1)):
        return False, "plugin steps are not numbered 1..n"
    for k in range(1, k_f + 1):
        if k - 1 not in iters:
            return False, "the engine logged no iteration %d, before the fence's step %d" % (k - 1, k_f)
        if iters[k - 1] != by_step.get(k):
            return False, "plugin step %d holds %s tokens and iteration %d holds %d" % (k, by_step.get(k), k - 1, iters[k - 1])
    return True, ""


def match_client(engine_id, ids):
    hits = []
    for c in ids:
        at = engine_id.find(c)
        while at >= 0:
            end = at + len(c)
            if end == len(engine_id) or not engine_id[end].isdigit():
                hits.append(c)
                break
            at = engine_id.find(c, at + 1)
    return hits[0] if len(hits) == 1 else None


def cell_report(stage_dir, arm, rep):
    """Everything one cell measured, and whether it is eligible for calibration and why not."""
    tag = "%s-%d" % (arm, rep)
    rows = jsonl(os.path.join(stage_dir, "raw-%s.jsonl" % tag))
    gw = gateway_records(os.path.join(stage_dir, "gateway-record-%s.jsonl" % tag))
    steps = jsonl(os.path.join(stage_dir, "step-log-%s.jsonl" % tag))
    problems = []
    if os.path.exists(os.path.join(stage_dir, "ineligible-%s.txt" % tag)):
        problems.append("capture: " + open(os.path.join(stage_dir, "ineligible-%s.txt" % tag)).read().strip())

    ids = [r.get("requestId") for r in rows]
    if any(not i for i in ids) or len(set(ids)) != len(ids):
        problems.append("a client row has no request ID, or two share one")
    client_ids = set(i for i in ids if i)
    for rid, e in gw.items():
        if rid not in client_ids:
            problems.append("the gateway recorded %s, which no client row sent" % rid)
            break
        if e["dup"]:
            problems.append("the gateway recorded %s twice" % rid)
            break

    lags, delays, ttft_sched, ttft_arr = [], {"record": [], "decide": [], "handoff": [], "content": []}, [], []
    client_gaps = {"send_to_arrival": [], "flush_to_client_first": []}
    missing, incomplete, no_arrival, no_return, no_flush = 0, 0, 0, 0, 0
    premium_unc, premium_fail = 0, 0
    release_gap = []
    window_end = 0
    for r in rows:
        e = gw.get(r.get("requestId"))
        sched_ns = r.get("replayOriginUnixNanos", 0) + r["scheduledOffsetMs"] * 1_000_000
        if r.get("tenant") == PREMIUM:
            if r.get("returnedUnixNanos"):
                window_end = max(window_end, r["returnedUnixNanos"])
            else:
                no_return += 1
        if e is None:
            missing += 1
            continue
        if e["arrive"] is None or e["done"] is None:
            incomplete += 1
            continue
        d = e["done"]
        if not d.get("arrivedUnixNanos"):
            no_arrival += 1
            continue
        lag = ms(d["arrivedUnixNanos"] - sched_ns)
        lags.append(lag)
        client_gaps["send_to_arrival"].append(ms(d["arrivedUnixNanos"] - r["sendUnixNanos"]))
        for key, a, b in (("record", "arrivedUnixNanos", "recordedUnixNanos"), ("decide", "recordedUnixNanos", "decidedUnixNanos"),
                          ("handoff", "decidedUnixNanos", "handoffUnixNanos"), ("content", "handoffUnixNanos", "firstContentUnixNanos")):
            if d.get(a) and d.get(b):
                delays[key].append(ms(d[b] - d[a]))
        if r.get("tenant") == PREMIUM:
            cap = 64
            uncertain = lag > L_MS_FLOOR
            premium_unc += uncertain
            if full_output(r, cap) and not d.get("firstContentUnixNanos"):
                no_flush += 1
            if full_output(r, cap) and d.get("firstContentUnixNanos"):
                s, a = ms(d["firstContentUnixNanos"] - sched_ns), ms(d["firstContentUnixNanos"] - d["arrivedUnixNanos"])
                if r.get("firstTokenUnixNanos"):
                    client_gaps["flush_to_client_first"].append(ms(r["firstTokenUnixNanos"] - d["firstContentUnixNanos"]))
                ttft_sched.append((s, uncertain))
                ttft_arr.append((a, uncertain))
            else:
                premium_fail += 1
                ttft_sched.append((math.inf, uncertain))
                ttft_arr.append((math.inf, uncertain))
        elif r.get("tenant") == CONTENDER and d.get("releasedUnixNanos") and d.get("firstContentUnixNanos"):
            release_gap.append(ms(d["firstContentUnixNanos"] - d["releasedUnixNanos"]))
    if missing:
        problems.append("%d client row(s) have no gateway record" % missing)
    if incomplete:
        problems.append("%d gateway record(s) lack their arrive or done line" % incomplete)
    if no_arrival:
        problems.append("%d request(s) were refused before their body was read, so their lag is unknown" % no_arrival)
    # A premium success must carry its flushed first-content stamp; one without it is not a failure but missing
    # evidence (design page, eligibility condition 1; review of 97ae105, finding 4).
    if no_flush:
        problems.append("%d premium success(es) have no flushed first-content stamp" % no_flush)
    # The window ends at the last premium return, so every premium row must carry one: a missing one could be the
    # last, and the window would end early (review of 97ae105, finding 6).
    if no_return:
        problems.append("%d premium row(s) have no return stamp, so the window's end is unknown" % no_return)
        window_end = 0

    # Step-log completeness and its alignment with the engine's own iterations, up to the fence.
    # The capture's own completeness check, with its sequence, count and overflow rules, rather than a terminal
    # record's declaration alone (review of 97ae105, finding 5).
    complete, why = pilot_evidence.terminal(os.path.join(stage_dir, "step-log-%s.jsonl" % tag)) if steps else (None, "there is no step log")
    if not complete:
        problems.append("the step log is not complete: " + why)
    fence_add = any(r.get("ev") == "add" and "fence-" in r.get("id", "") for r in steps)
    if steps and not fence_add:
        problems.append("the fence's add record is not in the step log")
    elog = os.path.join(stage_dir, "engine-log-%s.txt" % tag)
    if not os.path.exists(elog):
        problems.append("there is no engine log to align the step log against")
    elif steps:
        ok, why = step_alignment(steps, iteration_totals(elog))
        if not ok:
            problems.append("step log against the engine's iterations: " + why)

    # Contender processing within the window: prefill and decode tokens split per step, and completion.
    adds = {r["id"]: r for r in steps if r.get("ev") == "add"}
    offered = [r for r in rows if r.get("tenant") == CONTENDER]
    tenant_of = {r["requestId"]: r["tenant"] for r in rows}
    prefill = decode = 0
    unannounced = set()
    for s in steps:
        if s.get("ev") != "sched":
            continue
        a = s.get("anchor") or [0, 0, 0]
        wall_t0 = s["t0"] + (a[1] - (a[0] + a[2]) / 2)
        if window_end and wall_t0 >= window_end:
            continue
        for rid, n in s["tokens"].items():
            client = match_client(rid, client_ids)
            if client is None or tenant_of.get(client) != CONTENDER:
                continue
            if rid not in adds:
                # Without its add record the prompt length is unknown, and its prefill would be counted as decode.
                unannounced.add(rid)
                continue
            prompt = adds[rid].get("prompt", 0)
            before = s["computed"].get(rid, 0)
            pf = min(n, max(prompt - before, 0))
            prefill += pf
            decode += n - pf
    if unannounced:
        problems.append("%d contender(s) were scheduled with no add record, so their prefill cannot be split from decode" % len(unannounced))
    exact = sum(r.get("exactInputTokens", 0) for r in offered)
    completed = sum(r.get("exactInputTokens", 0) for r in offered if full_output(r, 16))
    # p and q are within the window, so without its end they are not reported rather than counted to the log's end.
    work = {"offered": len(offered),
            "p": prefill / exact if exact and window_end else None,
            "q": decode / (len(offered) * 16) if offered and window_end else None,
            "c": completed / exact if exact else None}

    return {"arm": arm, "rep": rep, "eligible": not problems, "problems": problems,
            "rows": len(rows), "lag_ms": summary(lags),
            "lag_over_ms": {str(t): sum(1 for x in lags if x > t) for t in (5, 25, 50)},
            "gateway_delay_ms": {k: summary(v) for k, v in delays.items()},
            "client_gap_ms": {k: summary(v) for k, v in client_gaps.items()},
            "premium": {"uncertain": premium_unc, "failed": premium_fail, "n": len(ttft_sched)},
            "contender_release_gap_ms": summary(release_gap),
            "work": work,
            "_ttft": {"sched": ttft_sched, "arr": ttft_arr}, "_lags": lags}


def pooled_p99(values, uncertain_at):
    """Nearest-rank p99 with each uncertain value set to uncertain_at (0 or +inf)."""
    return nearest_rank([uncertain_at if unc else v for v, unc in values], 0.99)


def width(lo, hi):
    """ln(hi/lo): infinite when hi is, which is what an uncertain set at least 1% of the arm makes it; None only
    when there is nothing to measure."""
    if lo is None or hi is None or lo <= 0:
        return None
    if math.isinf(hi) or math.isinf(lo):
        return math.inf
    return math.log(hi / lo)


def crossed_log_ratio(num, den):
    """ln(num/den) for a crossed bound, keeping its infinities: an infinite numerator is +inf and an infinite
    denominator -inf, which is what a failure-heavy arm makes them (review of 97ae105, finding 8)."""
    if num is None or den is None or den <= 0 and not math.isinf(den):
        return None
    if math.isinf(num):
        return math.inf
    if math.isinf(den):
        return -math.inf
    if num <= 0:
        return None
    return math.log(num / den)


def missing_cells(stage_dir, stage):
    """The registered (arm, block) pairs of a stage with no raw rows."""
    have = set(cells(stage_dir))
    return [(a, r) for a in STAGE_ARMS[stage] for r in range(1, BLOCKS + 1) if (a, r) not in have]


def stage_report(stage_dir, stage=None):
    cs = [cell_report(stage_dir, a, r) for a, r in cells(stage_dir)]
    arms = {}
    for c in cs:
        arms.setdefault(c["arm"], []).append(c)
    out = {"stage_dir": stage_dir, "stage": stage, "cells": [], "arms": {}}
    if stage is not None:
        out["missing_cells"] = missing_cells(stage_dir, stage)
    pooled = {}
    for arm, group in sorted(arms.items()):
        sched = [x for c in group for x in c["_ttft"]["sched"]]
        arr = [x for c in group for x in c["_ttft"]["arr"]]
        lags = [x for c in group for x in c["_lags"]]
        p = {"sched_lo": pooled_p99(sched, 0.0), "sched_hi": pooled_p99(sched, math.inf),
             "arr_lo": pooled_p99(arr, 0.0), "arr_hi": pooled_p99(arr, math.inf)}
        pooled[arm] = p
        # The box an arm contributes to the crossed P/S bounds runs from its arrival p99 with the uncertain at 0 to
        # its scheduled p99 with them at +inf: y_hi - y_lo = ln(P_sched_hi/P_arr_lo) + ln(S_sched_hi/S_arr_lo)
        # (design page, y_hi and y_lo; review of 97ae105, finding 1). The two within-definition widths are kept
        # as diagnostics; neither alone is the box.
        out["arms"][arm] = {"eligible": all(c["eligible"] for c in group),
                            "blocks": len(group),
                            "pooled_p99_ms": p,
                            "width_box": width(p["arr_lo"], p["sched_hi"]),
                            "width_sched": width(p["sched_lo"], p["sched_hi"]),
                            "width_arr": width(p["arr_lo"], p["arr_hi"]),
                            "lag_ms_pooled": summary(lags)}
    # Contention and P/O are about O and P against each other and I, never S.
    if "off" in pooled and "R1" in pooled and pooled["R1"]["sched_hi"]:
        out["contention_o_over_i"] = pooled["off"]["sched_hi"] / pooled["R1"]["sched_hi"] if not math.isinf(pooled["off"]["sched_hi"]) else None
    if "prospective" in pooled and "off" in pooled:
        out["p_over_o_y_hi"] = crossed_log_ratio(pooled["prospective"]["sched_hi"], pooled["off"]["arr_lo"])
    # The pooled P/S half-width, from the two arms' boxes: no ratio of P to S is formed.
    if "prospective" in out["arms"] and "static-cap" in out["arms"]:
        wp, ws = out["arms"]["prospective"]["width_box"], out["arms"]["static-cap"]["width_box"]
        out["ps_half_width"] = (wp + ws) / 2 if wp is not None and ws is not None else None
    for c in cs:
        c = dict(c)
        c.pop("_ttft")
        c.pop("_lags")
        out["cells"].append(c)
    return out


def read_tsv(path):
    if not os.path.exists(path):
        return None
    with open(path, newline="") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def arm_time(stage_dir, stage):
    """(seconds, why): the largest complete cell time of the stage, its preliminary elapsed_s plus its upload hook's
    duration; None with the reason when any registered cell lacks either record (design page, condition 4)."""
    timings, uploads = read_tsv(os.path.join(stage_dir, "cell-timings.tsv")), read_tsv(os.path.join(stage_dir, "cell-uploads.tsv"))
    if timings is None or uploads is None:
        return None, "%s lacks cell-timings.tsv or cell-uploads.tsv" % stage_dir
    worst, why = 0, []
    for a in STAGE_ARMS[stage]:
        for r in range(1, BLOCKS + 1):
            t = [x for x in timings if x["arm"] == a and x["rep"] == str(r)]
            u = [x for x in uploads if x["arm"] == a and x["rep"] == str(r)]
            if len(t) != 1 or t[0]["outcome"] != "completed" or len(u) != 1:
                why.append("%s-%d has %d timing row(s) (%s) and %d upload row(s)" % (a, r, len(t), t[0]["outcome"] if t else "none", len(u)))
                continue
            worst = max(worst, int(t[0]["elapsed_s"]) + int(u[0]["hook_s"]))
    if why:
        return None, "; ".join(why)
    return worst, ""


def formulas(dir_a, dir_b):
    """The frozen formulas, from timing alone, when every registered arm of both stages is present and eligible."""
    reports = [stage_report(dir_a, "A"), stage_report(dir_b, "B")]
    absent = [(r["stage"], m) for r in reports for m in r["missing_cells"]]
    if absent:
        return {"available": False, "why": "registered cells with no evidence: %s" % absent}
    bad = [(r["stage"], c["arm"], c["rep"], c["problems"]) for r in reports for c in r["cells"] if not c["eligible"]]
    if bad:
        return {"available": False, "why": "ineligible cells: %s" % bad}
    # L reads each arm's lags pooled over its stage's blocks, as the endpoint pools them, not the worst single
    # block's: the two differ whenever a block's tail is not the arm's (review of 97ae105, finding 2).
    p999 = max(a["lag_ms_pooled"].get("p999", 0) or 0 for r in reports for a in r["arms"].values())
    lmax = max(a["lag_ms_pooled"].get("max", 0) or 0 for r in reports for a in r["arms"].values())
    out = {"available": True, "L_ms": max(L_MS_FLOOR, math.ceil(2 * p999)), "ceiling_ms": max(CEILING_MS_FLOOR, 2 * lmax),
           "p999_lag_ms_max_pooled_arm": p999, "lag_ms_max": lmax}
    times = [arm_time(dir_a, "A"), arm_time(dir_b, "B")]
    if any(t is None for t, _ in times):
        out["arm_time_s"] = None
        out["arm_time_why"] = "; ".join(w for t, w in times if t is None)
    else:
        out["arm_time_s"] = max(t for t, _ in times)
    # Bring-up and the session tail come from each stage's session stamps (hack/m5c-gpu-session.sh writes
    # session-timing.tsv beside the cells); the larger of the two stages is taken, like the arm time.
    stamps = [session_stamps(dir_a), session_stamps(dir_b)]
    missing = [w for st, w in stamps if st is None]
    if missing or out["arm_time_s"] is None:
        out["main_session_length_s"] = None
        out["main_session_length_why"] = "; ".join(missing + ([out["arm_time_why"]] if out["arm_time_s"] is None else []))
        return out
    bring_up = max(st["bring_up_s"] for st, _ in stamps)
    tail = max(st["tail_s"] for st, _ in stamps)
    length = math.ceil((bring_up + 12 * out["arm_time_s"] + tail) * 1.25)
    out.update({"bring_up_s": bring_up, "session_tail_s": tail, "main_session_length_s": length,
                "hard_stop_s": length, "acquisition_deadline_s": length - 360, "backstop_s": length + 600,
                "study_deadline_s": length + 1200})
    return out


def utc_epoch(text):
    """Seconds since the epoch for an ISO-8601 UTC time as AWS and the matrix print it."""
    from datetime import datetime
    return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()


def session_stamps(stage_dir):
    """({bring_up_s, tail_s}, "") from a stage's session stamps and first cell, or (None, why)."""
    rows = read_tsv(os.path.join(stage_dir, "session-timing.tsv"))
    timings = read_tsv(os.path.join(stage_dir, "cell-timings.tsv"))
    if not rows or not timings:
        return None, "%s lacks session-timing.tsv or cell-timings.tsv" % stage_dir
    st = rows[0]
    empty = [k for k in ("launch_time_utc", "matrix_returned_epoch", "marker_uploaded_utc") if not st.get(k)]
    if empty:
        return None, "%s's session stamps lack %s" % (stage_dir, ", ".join(empty))
    first = min(utc_epoch(t["start_utc"]) for t in timings)
    return {"bring_up_s": first - utc_epoch(st["launch_time_utc"]),
            "tail_s": utc_epoch(st["marker_uploaded_utc"]) - int(st["matrix_returned_epoch"])}, ""


def main(argv):
    if len(argv) in (3, 4) and argv[1] == "stage" and (len(argv) == 3 or argv[3] in STAGE_ARMS):
        json.dump(stage_report(argv[2], argv[3] if len(argv) == 4 else None), sys.stdout, indent=1, default=str)
        print()
        return 0
    if len(argv) == 4 and argv[1] == "formulas":
        json.dump(formulas(argv[2], argv[3]), sys.stdout, indent=1, default=str)
        print()
        return 0
    print(__doc__)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
