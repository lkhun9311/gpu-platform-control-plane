"""The prospective-admission pilot's measurement report.

    python3 pilot_report.py stage DIR [A|B]      one stage's measurements, as JSON, to stdout; with the stage named,
                                                 its missing cells are listed
    python3 pilot_report.py formulas DIR_A DIR_B  the frozen calibration formulas' outputs, or why they are unavailable
    python3 pilot_report.py gates DIR_A DIR_B     every registered pilot gate, with its value and whether it would fire
    python3 pilot_report.py diagnostic DIR        the admission diagnostic's verdict, validity and lines, per block
    python3 pilot_report.py frontier DIR          v26's verdict: hold-cap against the fixed spacings, with every line

docs/superpowers/specs/2026-10-08-measuring-prospective-admission-design.md, "The measurement pilot". It judges
nothing about P against S: it reports measurements, marks each arm eligible or not for calibration, and computes the
formulas that were frozen before the pilot. It prints no P/S ratio; widths are per arm, and the pooled P/S width is
their sum (design page, "Stage B is not blind").
"""

import csv
import glob
import hashlib
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
    # A stream that ended without [DONE] is not a success, even with status 200 and no error: a clean EOF can cut a
    # response short (v25 review, finding 1).
    return not row.get("errorKind") and row.get("httpStatus") == 200 and row.get("streamTerminated") is True


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


def cell_report(stage_dir, arm, rep, L=L_MS_FLOOR):
    """Everything one cell measured, and whether it is eligible for calibration and why not."""
    tag = "%s-%d" % (arm, rep)
    rows = jsonl(os.path.join(stage_dir, "raw-%s.jsonl" % tag))
    gw = gateway_records(os.path.join(stage_dir, "gateway-record-%s.jsonl" % tag))
    steps = jsonl(os.path.join(stage_dir, "step-log-%s.jsonl" % tag))
    problems = []
    if os.path.exists(os.path.join(stage_dir, "ineligible-%s.txt" % tag)):
        with open(os.path.join(stage_dir, "ineligible-%s.txt" % tag)) as f:
            problems.append("capture: " + f.read().strip())
    # A cell the matrix refused, for an engine or a priority that was not the registered apparatus, measured something
    # else, whatever its files hold (final review, finding 1).
    if os.path.exists(os.path.join(stage_dir, "cell-refused-%s.txt" % tag)):
        with open(os.path.join(stage_dir, "cell-refused-%s.txt" % tag)) as f:
            problems.append("refused by the matrix: " + f.read().strip())

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

    # The sidecar's uploads during this cell, so the lag of requests that met one can be reported apart: classified
    # by the scheduled instant or the scheduled-to-arrival interval, not by the send, which an upload may have held
    # back past its own end (design page, the measurement table's sidecar row).
    uploads = [u for u in (read_tsv(os.path.join(stage_dir, "sidecar-uploads.tsv")) or []) if u["cell"] == tag]
    spans = [(int(u["start_unix_ns"]), int(u["end_unix_ns"])) for u in uploads]
    lag_during_upload = []
    lags, delays, ttft_sched, ttft_arr = [], {"record": [], "decide": [], "handoff": [], "content": []}, [], []
    client_gaps = {"send_to_arrival": [], "flush_to_client_first": []}
    missing, incomplete, no_arrival, no_return, no_flush = 0, 0, 0, 0, 0
    contender_admitted = 0
    premium_lags = []
    premium_gaps = []
    gaps_absent = gaps_short = 0
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
        if r.get("tenant") == PREMIUM:
            premium_lags.append(lag)
            if full_output(r, 64):
                # Every content frame after the first leaves one gap; a success whose gaps are missing or short is
                # missing evidence, not a set of fast gaps (v25 review, finding 1). Rows recorded before gaps were
                # kept carry none at all, and are counted apart.
                g = r.get("contentGapsMicros")
                if g is None:
                    gaps_absent += 1
                elif len(g) != r.get("outputTokens", 0) - 1:
                    gaps_short += 1
                else:
                    premium_gaps.extend(x / 1000.0 for x in g)
        if any(sched_ns <= e and d["arrivedUnixNanos"] >= b for b, e in spans):
            lag_during_upload.append(lag)
        client_gaps["send_to_arrival"].append(ms(d["arrivedUnixNanos"] - r["sendUnixNanos"]))
        for key, a, b in (("record", "arrivedUnixNanos", "recordedUnixNanos"), ("decide", "recordedUnixNanos", "decidedUnixNanos"),
                          ("handoff", "decidedUnixNanos", "handoffUnixNanos"), ("content", "handoffUnixNanos", "firstContentUnixNanos")):
            if d.get(a) and d.get(b):
                delays[key].append(ms(d[b] - d[a]))
        if r.get("tenant") == PREMIUM:
            cap = 64
            # The trusted-lag limit the caller scores under: the pilot's 5 ms, or the diagnostic's 13 ms.
            uncertain = lag > L
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
        if r.get("tenant") == CONTENDER:
            contender_admitted += d.get("decision") == "admit"
    if missing:
        problems.append("%d client row(s) have no gateway record" % missing)
    if incomplete:
        problems.append("%d gateway record(s) lack their arrive or done line" % incomplete)
    if no_arrival:
        problems.append("%d request(s) were refused before their body was read, so their lag is unknown" % no_arrival)
    # A premium success must carry its flushed first-content stamp; one without it is not a failure but missing
    # evidence (design page, eligibility condition 1; review of 97ae105, finding 4).
    if gaps_short:
        problems.append("%d premium success(es) have fewer inter-token gaps than content frames less one" % gaps_short)
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
    # The shared window ends at the block's last scheduled instant, the same for every arm replaying that trace, so
    # a treatment that delays its own last premium request cannot lengthen the time its contender work is counted in
    # (v25 review, finding 3). The arm's own window, to its last premium return, is kept beside it.
    shared_end = max((r.get("replayOriginUnixNanos", 0) + r["scheduledOffsetMs"] * 1_000_000 for r in rows), default=0)
    prefill_shared = decode_shared = 0
    unannounced = set()
    unanchored = sum(1 for s in steps if s.get("ev") == "sched" and not s.get("anchor"))
    if unanchored:
        # Without its anchor a step's monotonic time cannot be put on the wall clock; [0, 0, 0] compared it with Unix
        # time and counted drain work inside the shared window (v26 review, B8).
        problems.append("%d step(s) carry no clock anchor, so their work cannot be placed in the window" % unanchored)
    for s in steps:
        if s.get("ev") != "sched" or not s.get("anchor"):
            continue
        a = s["anchor"]
        wall_t0 = s["t0"] + (a[1] - (a[0] + a[2]) / 2)
        in_own = not (window_end and wall_t0 >= window_end)
        in_shared = bool(shared_end) and wall_t0 < shared_end
        if not in_own and not in_shared:
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
            if in_own:
                prefill += pf
                decode += n - pf
            if in_shared:
                prefill_shared += pf
                decode_shared += n - pf
    if unannounced:
        problems.append("%d contender(s) were scheduled with no add record, so their prefill cannot be split from decode" % len(unannounced))
    exact = sum(r.get("exactInputTokens", 0) for r in offered)
    completed = sum(r.get("exactInputTokens", 0) for r in offered if full_output(r, 16))
    # p and q are within the window, so without its end they are not reported rather than counted to the log's end.
    work = {"offered": len(offered),
            "p": prefill / exact if exact and window_end else None,
            "q": decode / (len(offered) * 16) if offered and window_end else None,
            "c": completed / exact if exact else None,
            "p_shared_window": prefill_shared / exact if exact and shared_end else None,
            "q_shared_window": decode_shared / (len(offered) * 16) if offered and shared_end else None}

    return {"arm": arm, "rep": rep, "eligible": not problems, "problems": problems,
            "rows": len(rows), "lag_ms": summary(lags),
            "lag_over_ms": {str(t): sum(1 for x in lags if x > t) for t in (5, 25, 50)},
            "gateway_delay_ms": {k: summary(v) for k, v in delays.items()},
            "client_gap_ms": {k: summary(v) for k, v in client_gaps.items()},
            "premium": {"uncertain": premium_unc, "failed": premium_fail, "n": len(ttft_sched)},
            "contender_release_gap_ms": summary(release_gap),
            "contender_admitted": contender_admitted,
            "contender_completed": sum(1 for r in rows if r.get("tenant") == CONTENDER and full_output(r, 16)),
            "_release_gaps": release_gap, "_premium_lags": premium_lags, "_premium_gaps": premium_gaps,
            "premium_gap_evidence": {"absent": gaps_absent, "short": gaps_short},
            "sidecar": {"uploads": len(uploads), "failed": sum(1 for u in uploads if u["hook_rc"] != "0"),
                        "upload_ms": summary([ms(e - b) for b, e in spans]),
                        "lag_ms_overlapping_an_upload": summary(lag_during_upload)},
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
    # Both infinite is undefined, not either infinity (design page, "If both p99s are infinite at the same vertex";
    # review of 9b10925).
    if math.isinf(num) and math.isinf(den):
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
                            "lag_ms_pooled": summary(lags),
                            # Each client-visible gap between premium content frames, pooled: a per-request average
                            # would hide one long gap among short ones (v24 review, finding 2).
                            "premium_inter_token_gap_ms": summary([x for c in group for x in c["_premium_gaps"]])}
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
        for k in [k for k in c if k.startswith("_")]:
            c.pop(k)
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


def _gate(name, value, rule, fires, **detail):
    """One gate, with its value, its rule and whether it would have fired; None for fires means not measured."""
    return dict(gate=name, value=value, rule=rule, would_fire=fires, **detail)


def _cells_by_arm(stage_dir):
    out = {}
    for arm, rep in cells(stage_dir):
        out.setdefault(arm, {})[rep] = cell_report(stage_dir, arm, rep)
    return out


def _box(cs):
    """(sched_hi, arr_lo) pooled over the given cells' premium TTFTs."""
    sched = [x for c in cs for x in c["_ttft"]["sched"]]
    arr = [x for c in cs for x in c["_ttft"]["arr"]]
    return pooled_p99(sched, math.inf), pooled_p99(arr, 0.0), pooled_p99(sched, 0.0), pooled_p99(arr, math.inf)


def uncertain_fraction(cs, L):
    """Premium requests with lag above L over the arm's premium requests with a lag, pooled over the given cells.

    Frozen here because the page left it open (v22 review, finding 4): numerator and denominator are both premium
    requests, pooled over the stage's blocks, one arm at a time. The all-request denominator is printed beside it.
    """
    prem = [l for c in cs for l in c["_premium_lags"]]
    allr = sum(len(c["_lags"]) for c in cs)
    n = sum(1 for l in prem if l > L)
    return n, len(prem), allr


def gates(dir_a, dir_b, L_formula):
    """Every registered pilot gate (design page, "Pilot, in two stages"), evaluated and reported, never acted on."""
    A, B = _cells_by_arm(dir_a), _cells_by_arm(dir_b)
    out = []
    # Stage A.
    i_hi = _box(A["R1"].values())[0]
    o_hi, o_arr_lo, _, _ = _box(A["off"].values())
    p_hi = _box(A["prospective"].values())[0]
    out.append(_gate("A contention: O's premium p99 >= 1.5 x I's (scheduled, uncertain at +inf)", o_hi / i_hi, ">= 1.5", not o_hi / i_hi >= 1.5))
    for arm, cs in A.items():
        n = sum(c["premium"]["n"] for c in cs.values()); f = sum(c["premium"]["failed"] for c in cs.values())
        out.append(_gate("A loss: %s premium loss < 0.5%%" % arm, f / n, "< 0.005", not f / n < 0.005, failed=f, of=n))
    off_c = sum(c["contender_completed"] for c in A["off"].values()); off_n = sum(c["work"]["offered"] for c in A["off"].values())
    out.append(_gate("A loss: O completes >= 95% of contender requests", off_c / off_n, ">= 0.95", not off_c / off_n >= 0.95, completed=off_c, of=off_n))
    p_adm = sum(c["contender_admitted"] for c in A["prospective"].values()); p_n = sum(c["work"]["offered"] for c in A["prospective"].values())
    refused = 1 - p_adm / p_n
    out.append(_gate("A engagement: P refuses 5% to 30% of contender requests", refused, "0.05..0.30", not 0.05 <= refused <= 0.30, admitted=p_adm, of=p_n))
    po = crossed_log_ratio(p_hi, o_arr_lo)
    out.append(_gate("A P/O: ln(P scheduled p99 hi / O arrival p99 lo) <= ln 0.85", po, "<= %.6f" % math.log(0.85), po is None or not po <= math.log(0.85)))
    gaps = [g for c in A["prospective"].values() for g in c["_release_gaps"]]
    within = sum(1 for g in gaps if g <= 50) / len(gaps) if gaps else None
    out.append(_gate("A release timing: >= 95% of P's admitted contenders within 50 ms of release", within, ">= 0.95", None if within is None else not within >= 0.95, measured=len(gaps)))
    out.append(_gate("A restart: an engine restart under 3 minutes", None, "< 180 s", None, why="no deployment or readiness stamp is recorded per cell"))
    lmax = max(max(c["_lags"]) for cs in A.values() for c in cs.values())
    out.append(_gate("A dispatch fidelity: no request's lag above 25 ms", lmax, "<= 25 ms", not lmax <= 25))
    for L in (L_MS_FLOOR, L_formula):
        for arm, cs in A.items():
            n, d, allr = uncertain_fraction(cs.values(), L)
            out.append(_gate("A dispatch fidelity: %s premium lag above L=%g ms <= 0.05%%" % (arm, L), n / d, "<= 0.0005", not n / d <= 0.0005, uncertain=n, premium=d, all_requests=allr))
    out.append(_gate("A capture: every cell eligible", all(c["eligible"] for cs in A.values() for c in cs.values()), "true",
                     not all(c["eligible"] for cs in A.values() for c in cs.values())))
    # Stage B.
    for arm, cs in B.items():
        n = sum(c["premium"]["n"] for c in cs.values()); f = sum(c["premium"]["failed"] for c in cs.values())
        out.append(_gate("B loss: %s premium loss < 0.5%%" % arm, f / n, "< 0.005", not f / n < 0.005, failed=f, of=n))
    diffs = {k: [] for k in "pqc"}
    for rep in sorted(B["prospective"]):
        P, S_ = B["prospective"][rep], B["static-cap"][rep]
        for k in "pqc":
            diffs[k].append(P["work"][k] - S_["work"][k])
        ph, _, _, _ = _box([P]); _, sa, _, _ = _box([S_])
        # Per block, as the page's width screen reads it: (y_hi - y_lo) / 2 from that block's two boxes.
        wp = width(_box([P])[1], ph); ws = width(sa, _box([S_])[0])
        hw = (wp + ws) / 2 if wp is not None and ws is not None else None
        out.append(_gate("B width: block %d P/S half-width <= 0.043" % rep, hw, "<= 0.043", hw is None or not hw <= 0.043))
    for k in "pqc":
        out.append(_gate("B margin: %s_P - %s_S >= 0.03 in every block" % (k, k), min(diffs[k]), ">= 0.03", not min(diffs[k]) >= 0.03, per_block=diffs[k]))
    mean_p = sum(diffs["p"]) / len(diffs["p"])
    out.append(_gate("B informative bound: mean p_P - p_S <= 0.10", mean_p, "<= 0.10", not mean_p <= 0.10))
    cal = open(os.path.join(dir_b, "calibration.txt")).read() if os.path.exists(os.path.join(dir_b, "calibration.txt")) else ""
    restamp = bool(re.search(r"engine 68 tokens, frozen 68", cal)) and bool(re.search(r"engine 7695 tokens, frozen 7695", cal))
    out.append(_gate("B re-stamp: the engine's counts equal the frozen ones", restamp, "true", not restamp))
    return out


# ---------------------------------------------------------------- the admission diagnostic (design page, "v25")

DIAG_L_MS = 13.0
DIAG_CEILING_MS = 50.0
DIAG_BLOCKS = (1, 2, 3)


def preemptions(stage_dir, tag):
    """The engine's preemption count over the cell, from its before and after scrapes; None when either is missing."""
    vals = []
    for phase in ("before", "after"):
        path = os.path.join(stage_dir, "engine-metrics-%s-%s.prom" % (tag, phase))
        if not os.path.exists(path):
            return None
        found = None
        with open(path) as f:
            for line in f:
                if line.startswith("vllm:num_preemptions_total{"):
                    found = float(line.split()[-1])
        if found is None:
            return None
        vals.append(found)
    return vals[1] - vals[0]


def contender_outcomes(stage_dir, tag):
    """(completed, offered, latencies in ms with failures at +inf, hold-timeout refusals) for a cell's contenders.

    A contender completes when its stream is whole and terminated and its last token reached the client within the
    30 s timeout of its scheduled instant; anything else, a refusal included, is a failure.
    """
    rows = jsonl(os.path.join(stage_dir, "raw-%s.jsonl" % tag))
    gw = gateway_records(os.path.join(stage_dir, "gateway-record-%s.jsonl" % tag))
    lat, done, offered, hold_timeouts, untimed = [], 0, 0, 0, 0
    for r in rows:
        if r.get("tenant") != CONTENDER:
            continue
        offered += 1
        sched = r.get("replayOriginUnixNanos", 0) + r["scheduledOffsetMs"] * 1_000_000
        # The last content frame's arrival, from the first and every gap after it: the spec's endpoint is the client's
        # last token, not the replay's return, which also waits for [DONE] and the connection's drain (final review,
        # finding 3). A success without its gaps cannot be timed, and is counted apart.
        gaps = r.get("contentGapsMicros")
        # Short gaps are as untimed as absent ones: their sum would end the stream early (v26 review, finding 2). A
        # success with no first-token stamp has no time origin at all, and is untimed too, not a failure (v26 review,
        # A12).
        if full_output(r, 16) and (not r.get("firstTokenUnixNanos") or gaps is None or len(gaps) != r.get("outputTokens", 0) - 1):
            untimed += 1
            continue
        # Each gap was truncated to whole microseconds, so the true end is up to one microsecond per gap later; the
        # limit is judged at that later end, so truncation cannot carry a stream inside it (v26 review, A15).
        end = r["firstTokenUnixNanos"] + (sum(gaps) + len(gaps)) * 1000 if full_output(r, 16) else None
        ok = end is not None and end - sched <= 30_000_000_000
        if ok:
            done += 1
            lat.append(ms(end - sched))
        else:
            lat.append(math.inf)
        d = (gw.get(r.get("requestId")) or {}).get("done") or {}
        hold_timeouts += d.get("reason") == "serial_prefill_hold_timeout"
    return done, offered, sorted(lat), hold_timeouts, untimed


DIAG_CELLS = ["R1-1"] + ["%s-%d" % (a, b) for b in (1, 2, 3) for a in ("off", "hold", "cap", "hold-cap")]
# The lines a single cell observes directly, which an invalid block cannot excuse: a refusal for waiting and a
# preemption happened whatever the comparison's validity. Every other line compares against off, and an invalid
# block leaves it unscored rather than failed (final review, finding 2).
DIAG_DIRECT_LINES = ("hold-timeout refusals", "preemptions in hold-cap")


def diagnostic(stage_dir):
    """The admission diagnostic's verdict, its validity and every acceptance line, per block.

    A line whose evidence is missing is "unscorable", never a failure: only a measured violation can make the verdict
    "not met", and anything unmeasured or invalid makes it "inconclusive" (review of 46de41a).
    """
    blocks, first_fail, inconclusive = [], None, []
    for b in DIAG_BLOCKS:
        tags = {"off": "off-%d" % b, "hold-cap": "hold-cap-%d" % b}
        present = {a: os.path.exists(os.path.join(stage_dir, "raw-%s.jsonl" % t)) for a, t in tags.items()}
        validity, lines = [], []

        def check(collection, name, value, rule, ok):
            state = "unscorable" if ok is None else ("holds" if ok else "fails")
            collection.append({"line": name, "value": value, "rule": rule, "state": state})

        cr = {a: cell_report(stage_dir, *tags[a].rsplit("-", 1)[:1], int(tags[a].rsplit("-", 1)[1]), L=DIAG_L_MS)
              for a in tags if present[a]}
        if not all(present.values()):
            inconclusive.append("block %d is incomplete" % b)
        for a, c in cr.items():
            check(validity, "%s eligible" % a, c["eligible"], "true", c["eligible"])
            loss = c["premium"]["failed"] / c["premium"]["n"] if c["premium"]["n"] else None
            check(validity, "%s premium loss" % a, loss, "< 0.005", None if loss is None else loss < 0.005)
            lmax = c["lag_ms"].get("max")
            check(validity, "%s largest dispatch lag" % a, lmax, "<= %g ms" % DIAG_CEILING_MS, None if lmax is None else lmax <= DIAG_CEILING_MS)
            n, d, _ = uncertain_fraction([c], DIAG_L_MS)
            check(validity, "%s premium lag above L=%g ms" % (a, DIAG_L_MS), n / d if d else None, "<= 0.001", (n / d <= 0.001) if d else None)
            # A premium success with no gaps at all is unobserved, so the gap line cannot be scored on the rest.
            absent = c["premium_gap_evidence"]["absent"]
            check(validity, "%s premium successes without gap evidence" % a, absent, "0", absent == 0)
        if "off" in cr:
            o_done, o_off, o_lat, _, o_untimed = contender_outcomes(stage_dir, tags["off"])
            check(validity, "off contenders completed without timing evidence", o_untimed, "0", o_untimed == 0)
            check(validity, "off contender completion", o_done / o_off if o_off else None, ">= 0.95", (o_done / o_off >= 0.95) if o_off else None)
        if "hold-cap" in cr:
            pre = preemptions(stage_dir, tags["hold-cap"])
            h_done, h_off, h_lat, h_hold, h_untimed = contender_outcomes(stage_dir, tags["hold-cap"])
            check(validity, "hold-cap contenders completed without timing evidence", h_untimed, "0", h_untimed == 0)
            # The lines hold-cap carries alone are scored even when off's cell is missing, so an observed violation
            # in an incomplete block is still reported (review of 46de41a).
            check(lines, "contender completion", h_done / h_off if h_off else None, ">= 0.95", (h_done / h_off >= 0.95) if h_off else None)
            p95h = nearest_rank(h_lat, 0.95)
            check(lines, "contender completion latency p95", p95h, "<= 25,000 ms", None if p95h is None else p95h <= 25_000)
            check(lines, "hold-timeout refusals", h_hold, "0", h_hold == 0)
            check(lines, "preemptions in hold-cap", pre, "0", None if pre is None else pre == 0)
        if len(cr) == 2:
            o_hi, o_arr_lo, _, _ = _box([cr["off"]])
            h_hi, _, _, _ = _box([cr["hold-cap"]])
            finite = o_arr_lo is not None and not math.isinf(o_arr_lo)
            check(validity, "off's crossed denominator finite", o_arr_lo, "finite", finite)
            ratio = crossed_log_ratio(h_hi, o_arr_lo) if finite else None
            check(lines, "premium p99, crossed upper end against off", ratio, "<= %.4f" % math.log(0.85),
                  None if ratio is None else ratio <= math.log(0.85))
            p50o, p50h = nearest_rank(o_lat, 0.5), nearest_rank(h_lat, 0.5)
            scorable = p50o is not None and p50h is not None and not math.isinf(p50o)
            check(lines, "contender completion latency p50 against off's", (p50h, p50o), "<= 1.5 x off's",
                  (p50h <= 1.5 * p50o) if scorable else None)
            for k in ("p_shared_window", "q_shared_window"):
                o_w, h_w = cr["off"]["work"][k], cr["hold-cap"]["work"][k]
                check(lines, "contender work in the shared window (%s) against off's" % k[0], (h_w, o_w), ">= 0.9 x off's",
                      None if o_w is None or h_w is None else h_w >= 0.9 * o_w)
            go = nearest_rank(cr["off"]["_premium_gaps"], 0.99)
            gh = nearest_rank(cr["hold-cap"]["_premium_gaps"], 0.99)
            check(lines, "premium inter-token gap p99 against off's", (gh, go), "<= 1.25 x off's",
                  None if go is None or gh is None else gh <= 1.25 * go)

        bad_validity = [v["line"] for v in validity if v["state"] != "holds"]
        unscorable = [x["line"] for x in lines if x["state"] == "unscorable"]
        if bad_validity or unscorable:
            inconclusive.append("block %d: %s" % (b, ", ".join(bad_validity + ["%s unscorable" % u for u in unscorable])))
        fails = [x["line"] for x in lines if x["state"] == "fails" and (not bad_validity or x["line"] in DIAG_DIRECT_LINES)]
        if fails and first_fail is None:
            first_fail = "block %d: %s" % (b, fails[0])
        blocks.append({"block": b, "complete": all(present.values()), "validity": validity, "lines": lines})
    # The whole acquisition, every one of the thirteen cells, not only the pairs scored: a verdict on six cells is
    # not the registered diagnostic (final review, finding 4). Live snapshots of a cell the final archive lacks are
    # named, because an interrupted replay's rows are there and nowhere else.
    missing = [c for c in DIAG_CELLS if not os.path.exists(os.path.join(stage_dir, "raw-%s.jsonl" % c))]
    if missing:
        live = os.path.join(os.path.dirname(os.path.abspath(stage_dir)), "live")
        snap = [c for c in missing if os.path.exists(os.path.join(live, "live-raw-%s.jsonl" % c))]
        inconclusive.append("cells not acquired: %s%s" % (", ".join(missing),
                            "; live snapshots exist for %s" % ", ".join(snap) if snap else ""))
    # Precedence (v25 review, finding 6): a measured failure is reported whatever else happened; a positive verdict
    # needs all thirteen cells, three valid blocks and every line scored; anything short of that is inconclusive.
    if first_fail:
        verdict = "not met: " + first_fail
    elif inconclusive:
        verdict = "inconclusive: " + "; ".join(inconclusive)
    else:
        verdict = "observed on these traces: hold-cap met every limit in all three blocks"
    return {"verdict": verdict, "blocks": blocks}


# ---------------------------------------------------------------- v26: hold-cap against a frontier of fixed spacings
#
# docs/superpowers/specs/2026-10-08-measuring-prospective-admission-design.md, "v26", and the review that froze its
# rules, docs/superpowers/specs/2026-10-10-v26-adversarial-review.md.

FRONTIER_STUDY = "admission-frontier-2026-10-10"
FRONTIER_FIXED = ("fixed-1.62", "fixed-1.66", "fixed-1.70", "fixed-1.74")
FRONTIER_ARMS = ("off", "hold-cap") + FRONTIER_FIXED
FRONTIER_SEEDS = {1: 861, 2: 862, 3: 863}
# The frozen trace checksums, by seed: one for every arm replaying the whole trace and one for R1. The same table is
# in hack/lib/prospective-pilot.sh, and test_pilot_report checks the two agree.
FRONTIER_CHECKSUMS = {
    861: ("ad83bde4313cf3ed6f4a52c7820271ca4689cb3b1d01f0dad0bd47aeeaf0f79a", "e9d7faf0b01e9daf95cdba101c6200fe43dd8cf0bf60c6f1c3903117517572c2"),
    862: ("1ec48cb1c290367902b3665e6837b42582e4e4c8723fb0b8edf2fc71905d46b9", "1f4f471e058d7050b61fcbe8c5d240c9ccc8ef732adfb4d62498ea630e4f207c"),
    863: ("0bff6066f348a6168236be006a232d92a581d73fea81c56e45dbf0eaebc4ca4b", "f7cff96a1d35858b179245a0e470adac222fcc7869be5dbbd766697b8f0304e7"),
}
FRONTIER_CELLS = ["R1-1"] + ["%s-%d" % (a, b) for b in (1, 2, 3) for a in FRONTIER_ARMS]
HOLD_REFUSALS = ("serial_prefill_hold_timeout", "fixed_spacing_hold_timeout")
LN_085 = math.log(0.85)


def manifest_fields(path):
    """The top-level scalar fields of a run manifest, as strings."""
    out = {}
    if not os.path.exists(path):
        return None
    with open(path) as f:
        for line in f:
            m = re.match(r'^([A-Za-z]+):\s*"?([^"]*)"?\s*$', line.rstrip("\n"))
            if m:
                out[m.group(1)] = m.group(2)
    return out


def provenance(stage_dir, arm, rep):
    """Why a cell is not the registered one, or None: its manifest's study, arm, seed and trace checksum, and its
    rows against its trace's (v26 review, B6 and B7)."""
    tag = "%s-%d" % (arm, rep)
    m = manifest_fields(os.path.join(stage_dir, "manifest-%s.yaml" % tag))
    if m is None:
        return "it has no manifest"
    seed = FRONTIER_SEEDS[rep]
    want = FRONTIER_CHECKSUMS[seed][1 if arm == "R1" else 0]
    for key, value in (("study", FRONTIER_STUDY), ("arm", arm), ("seed", str(seed)), ("traceChecksum", want)):
        if m.get(key) != value:
            return "its manifest says %s %s, registered %s" % (key, m.get(key), value)
    # The trace itself, by its hash, and every row against it: equal counts let another run's rows pass beside the right
    # manifest (review of fde74bb).
    tpath = os.path.join(stage_dir, "trace-%s.jsonl" % tag)
    if not os.path.exists(tpath):
        return "it has no trace"
    with open(tpath, "rb") as f:
        got = hashlib.sha256(f.read()).hexdigest()
    if got != want:
        return "its trace hashes to %s, registered %s" % (got, want)
    trace = {t["index"]: t for t in jsonl(tpath)}
    rows = jsonl(os.path.join(stage_dir, "raw-%s.jsonl" % tag))
    if sorted(r.get("index") for r in rows) != sorted(trace):
        return "its rows are not its trace's requests, one each"
    for r in rows:
        t = trace[r["index"]]
        if (r.get("study"), r.get("arm"), r.get("traceChecksum")) != (FRONTIER_STUDY, arm, want):
            return "row %s names study %s, arm %s, trace %s" % (r["index"], r.get("study"), r.get("arm"), r.get("traceChecksum"))
        if (r.get("scheduledOffsetMs"), r.get("tenant")) != (t.get("offsetMs"), t.get("tenant")):
            return "row %s is not its trace's request at that index" % r["index"]
    return None


def gateway_delay_lines(stage_dir, tag):
    """(record p99, record max, premium decide p99, premium decide max, missing) in ms: the gateway's own delay after its
    arrival stamp. The durable record is written for every request before admission, so arrival to record holds no
    hold; premium requests are never held, so their arrival to decision is the whole decision path (v26 review, A1)."""
    rows = {r.get("requestId"): r.get("tenant") for r in jsonl(os.path.join(stage_dir, "raw-%s.jsonl" % tag))}
    rec, dec, missing = [], [], 0
    for rid, e in gateway_records(os.path.join(stage_dir, "gateway-record-%s.jsonl" % tag)).items():
        d = e.get("done") or {}
        if not (d.get("arrivedUnixNanos") and d.get("recordedUnixNanos")):
            missing += 1
            continue
        rec.append(ms(d["recordedUnixNanos"] - d["arrivedUnixNanos"]))
        if rows.get(rid) == PREMIUM:
            if not d.get("decidedUnixNanos"):
                missing += 1
                continue
            dec.append(ms(d["decidedUnixNanos"] - d["arrivedUnixNanos"]))
    return (nearest_rank(rec, 0.99), max(rec) if rec else None, nearest_rank(dec, 0.99), max(dec) if dec else None, missing)


def spacing_deviation(stage_dir, tag, spacing_ms):
    """(least, p99) in ms of how far each held contender's admission came after the previous admission plus the
    spacing: never sooner, and at the spacing's end within the gateway's timer, as v26 registers (review, A8)."""
    rows = {r.get("requestId"): r.get("tenant") for r in jsonl(os.path.join(stage_dir, "raw-%s.jsonl" % tag))}
    admitted = [d for rid, e in gateway_records(os.path.join(stage_dir, "gateway-record-%s.jsonl" % tag)).items()
                for d in [e.get("done") or {}] if rows.get(rid) == CONTENDER and d.get("decision") == "admit"]
    # An admission without its decision time is missing evidence, not an admission with nothing to time: dropping it
    # let the line hold vacuously (review of fde74bb).
    if any(not d.get("decidedUnixNanos") for d in admitted):
        return "missing", None
    adm = sorted((d["decidedUnixNanos"], d.get("reason")) for d in admitted)
    dev = [ms(b[0] - a[0]) - spacing_ms for a, b in zip(adm, adm[1:]) if b[1] == "fixed_spacing_waited"]
    return (min(dev) if dev else None, nearest_rank(dev, 0.99))


def mode_reasons(stage_dir, tag, prefix):
    """(contender decisions, those whose reason names the arm's admission mode): a cell whose gateway did not run its
    registered mode would otherwise pass every line about holds vacuously."""
    rows = {r.get("requestId"): r.get("tenant") for r in jsonl(os.path.join(stage_dir, "raw-%s.jsonl" % tag))}
    ds = [(e.get("done") or {}).get("reason") or "" for rid, e in gateway_records(
        os.path.join(stage_dir, "gateway-record-%s.jsonl" % tag)).items() if rows.get(rid) == CONTENDER]
    return len(ds), sum(1 for r in ds if r.startswith(prefix))


def hold_refusals(stage_dir, tag):
    return sum(1 for e in gateway_records(os.path.join(stage_dir, "gateway-record-%s.jsonl" % tag)).values()
               if (e.get("done") or {}).get("reason") in HOLD_REFUSALS)


def frontier(stage_dir):
    """v26's verdict, its validity, every admissibility line per block, and every pooled quantity.

    The verdicts, in the registered order: inconclusive when any evidence cannot be trusted or any line is unscorable;
    not met when hold-cap is not admissible or does not cut the premium tail 15% below off's; observed when hold-cap
    is admissible and no fixed arm is, when it beats every admissible fixed arm, or when a fixed arm beats it; and not
    established otherwise. A directional win needs the winner's contender completion within one point of the loser's
    and its shared-window work at least 0.97 of the loser's (review, A2).
    """
    validity, lines, pooled = [], [], {}

    def check(collection, name, value, rule, ok):
        collection.append({"line": name, "value": value, "rule": rule,
                           "state": "unscorable" if ok is None else ("holds" if ok else "fails")})

    present = {c: os.path.exists(os.path.join(stage_dir, "raw-%s.jsonl" % c)) for c in FRONTIER_CELLS}
    missing = [c for c in FRONTIER_CELLS if not present[c]]
    extra = sorted(os.path.basename(f)[4:-6] for f in glob.glob(os.path.join(stage_dir, "raw-*.jsonl"))
                   if os.path.basename(f)[4:-6] not in FRONTIER_CELLS and not os.path.basename(f).startswith("raw-warmup-"))
    reports, outcomes = {}, {}
    for c in FRONTIER_CELLS:
        if not present[c]:
            continue
        arm, rep = c.rsplit("-", 1)[0], int(c.rsplit("-", 1)[1])
        try:
            reports[c] = cell_report(stage_dir, arm, rep, L=DIAG_L_MS)
            outcomes[c] = contender_outcomes(stage_dir, c)
            # Inside the boundary too: a truncated trace crashed the whole report (review of fde74bb).
            why = provenance(stage_dir, arm, rep)
        except (ValueError, KeyError) as e:
            # A truncated or malformed record makes the cell's evidence untrustworthy, not the scorer's run (B11).
            reports.pop(c, None)
            outcomes.pop(c, None)
            check(validity, "%s records readable" % c, str(e)[:120], "parseable", False)
            continue
        cr = reports[c]
        check(validity, "%s is the registered cell" % c, why, "no difference", why is None)
        check(validity, "%s eligible" % c, cr["problems"][:3], "no problem", cr["eligible"])
        lmax = cr["lag_ms"].get("max")
        check(validity, "%s largest dispatch lag" % c, lmax, "<= 50 ms", None if lmax is None else lmax <= DIAG_CEILING_MS)
        n, d, _ = uncertain_fraction([cr], DIAG_L_MS)
        check(validity, "%s premium lag above 13 ms" % c, n / d if d else None, "<= 0.001", (n / d <= 0.001) if d else None)
        absent = cr["premium_gap_evidence"]["absent"]
        check(validity, "%s premium successes without gap evidence" % c, absent, "0", absent == 0)
        untimed = outcomes[c][4]
        check(validity, "%s contender successes without complete timing" % c, untimed, "0", untimed == 0)
        rp99, rmax, dp99, dmax, gmiss = gateway_delay_lines(stage_dir, c)
        check(validity, "%s gateway arrival to record" % c, (rp99, rmax), "p99 <= 13 ms, max <= 50 ms",
              None if rp99 is None or gmiss else rp99 <= DIAG_L_MS and rmax <= DIAG_CEILING_MS)
        check(validity, "%s gateway premium arrival to decision" % c, (dp99, dmax), "p99 <= 13 ms, max <= 50 ms",
              None if dp99 is None or gmiss else dp99 <= DIAG_L_MS and dmax <= DIAG_CEILING_MS)
        if arm in ("hold-cap",) + FRONTIER_FIXED:
            n_dec, n_mode = mode_reasons(stage_dir, c, "serial_prefill_" if arm == "hold-cap" else "fixed_spacing_")
            check(validity, "%s contender decisions by its admission mode" % c, (n_mode, n_dec), "all",
                  None if n_dec == 0 else n_mode == n_dec)
        if arm in FRONTIER_FIXED:
            least, p99 = spacing_deviation(stage_dir, c, float(arm.split("-")[1]) * 1000)
            # No held contender leaves nothing to time; the line above already shows the mode ran.
            check(validity, "%s admissions after the spacing" % c, (least, p99), "least >= -1 ms, p99 <= 13 ms",
                  None if least == "missing" else (True if least is None else least >= -1.0 and p99 <= DIAG_L_MS))
        if arm == "off":
            loss = cr["premium"]["failed"] / cr["premium"]["n"] if cr["premium"]["n"] else None
            check(validity, "%s premium loss" % c, loss, "< 0.005", None if loss is None else loss < 0.005)
            done, offered = outcomes[c][0], outcomes[c][1]
            check(validity, "%s contender completion" % c, done / offered if offered else None, ">= 0.95",
                  (done / offered >= 0.95) if offered else None)

    # Admissibility, per treatment arm and block, against that block's off (v26 review, M14).
    first_fail = {a: None for a in FRONTIER_ARMS[1:]}
    for b in (1, 2, 3):
        off = "off-%d" % b
        if off not in reports:
            continue
        o_done, o_off, o_lat, _, _ = outcomes[off]
        for arm in FRONTIER_ARMS[1:]:
            c = "%s-%d" % (arm, b)
            if c not in reports:
                continue
            done, offered, lat, _, _ = outcomes[c]
            cr, ocr = reports[c], reports[off]
            res = []
            res.append(("contender completion", done / offered if offered else None, ">= 0.95",
                        (done / offered >= 0.95) if offered else None))
            p50, op50 = nearest_rank(lat, 0.5), nearest_rank(o_lat, 0.5)
            res.append(("contender completion p50 against off's", (p50, op50), "<= 1.5 x off's",
                        None if p50 is None or op50 is None or math.isinf(op50) else p50 <= 1.5 * op50))
            p95 = nearest_rank(lat, 0.95)
            res.append(("contender completion p95", p95, "<= 25,000 ms", None if p95 is None else p95 <= 25_000))
            holds = hold_refusals(stage_dir, c)
            res.append(("hold refusals", holds, "0", holds == 0))
            pre = preemptions(stage_dir, c)
            res.append(("preemptions", pre, "0", None if pre is None else pre == 0))
            for k in ("p_shared_window", "q_shared_window"):
                w, ow = cr["work"][k], ocr["work"][k]
                res.append(("contender work in the shared window (%s) against off's" % k[0], (w, ow), ">= 0.9 x off's",
                            None if w is None or ow is None else w >= 0.9 * ow))
            g, og = nearest_rank(cr["_premium_gaps"], 0.99), nearest_rank(ocr["_premium_gaps"], 0.99)
            # An arm whose every premium stream failed served nobody a stream, and fails this safeguard; one with no
            # gaps for any other reason is unscorable (v26 review, A4).
            all_failed = cr["premium"]["n"] > 0 and cr["premium"]["failed"] == cr["premium"]["n"]
            res.append(("premium inter-token gap p99 against off's", (g, og), "<= 1.25 x off's",
                        False if all_failed else (None if g is None or og is None else g <= 1.25 * og)))
            for name, value, rule, ok in res:
                check(lines, "%s block %d: %s" % (arm, b, name), value, rule, ok)
                if ok is False and first_fail[arm] is None:
                    first_fail[arm] = "block %d: %s" % (b, name)

    # The pooled endpoint and the comparability quantities, per arm over its three cells.
    for arm in FRONTIER_ARMS:
        cs = [reports["%s-%d" % (arm, b)] for b in (1, 2, 3) if "%s-%d" % (arm, b) in reports]
        if len(cs) != 3:
            continue
        sched_hi, arr_lo, sched_lo, arr_hi = _box(cs)
        done = sum(outcomes["%s-%d" % (arm, b)][0] for b in (1, 2, 3))
        offered = sum(outcomes["%s-%d" % (arm, b)][1] for b in (1, 2, 3))
        work = {k: (sum(c["work"][k] for c in cs) / 3 if all(c["work"][k] is not None for c in cs) else None)
                for k in ("p_shared_window", "q_shared_window")}
        pooled[arm] = {"premium_p99_sched_hi": sched_hi, "premium_p99_arr_lo": arr_lo, "premium_p99_sched_lo": sched_lo,
                       "premium_p99_arr_hi": arr_hi, "contender_completion": done / offered if offered else None,
                       "work": work}

    unscorable = [x["line"] for x in validity + lines if x["state"] == "unscorable"]
    bad = [x["line"] for x in validity if x["state"] == "fails"]
    inconclusive = []
    if missing:
        inconclusive.append("cells not acquired: " + ", ".join(missing))
    if extra:
        inconclusive.append("cells the plan did not buy: " + ", ".join(extra))
    if bad:
        inconclusive.append("evidence not trusted: " + ", ".join(bad[:5]))
    if unscorable:
        inconclusive.append("unscorable: " + ", ".join(unscorable[:5]))
    if not inconclusive and len(pooled) != len(FRONTIER_ARMS):
        inconclusive.append("an arm has fewer than three scored cells")

    def ratio(a, b):
        return crossed_log_ratio(pooled[a]["premium_p99_sched_hi"], pooled[b]["premium_p99_arr_lo"])

    def wins(a, b):
        r = ratio(a, b)
        if r is None or r > LN_085:
            return False
        ca, cb = pooled[a]["contender_completion"], pooled[b]["contender_completion"]
        if ca is None or cb is None or ca < cb - 0.01:
            return False
        return all(pooled[a]["work"][k] is not None and pooled[b]["work"][k] is not None
                   and pooled[a]["work"][k] >= 0.97 * pooled[b]["work"][k] for k in ("p_shared_window", "q_shared_window"))

    if inconclusive:
        verdict = "inconclusive: " + "; ".join(inconclusive)
    elif first_fail["hold-cap"] is not None:
        verdict = "not met: hold-cap was not admissible: " + first_fail["hold-cap"]
    elif not (ratio("hold-cap", "off") is not None and ratio("hold-cap", "off") <= LN_085):
        verdict = "not met: hold-cap did not cut the premium tail 15% below off's"
    else:
        fixed = [a for a in FRONTIER_FIXED if first_fail[a] is None]
        if not fixed:
            verdict = "observed on these traces: hold-cap met the limits and no fixed spacing in the grid did"
        elif all(wins("hold-cap", a) for a in fixed):
            verdict = "observed on these traces: hold-cap beat every admissible fixed spacing"
        else:
            # Every admissible fixed arm is tested; the one named is the lowest scheduled upper end, ties to the
            # narrower spacing (review, A6 and A16).
            key = lambda a: (pooled[a]["premium_p99_sched_hi"], a)
            winners = [a for a in fixed if wins(a, "hold-cap")]
            if winners:
                verdict = "observed on these traces: %s beat hold-cap" % min(winners, key=key)
            else:
                verdict = "not established: neither hold-cap nor %s was 15%% below the other" % min(fixed, key=key)
    return {"verdict": verdict, "validity": validity, "lines": lines, "pooled": pooled,
            "admissible": {a: first_fail[a] is None for a in first_fail}, "first_failure": first_fail,
            "ratios_to_hold_cap": {a: (crossed_log_ratio(pooled[a]["premium_p99_sched_hi"], pooled["hold-cap"]["premium_p99_arr_lo"])
                                       if a in pooled and "hold-cap" in pooled else None) for a in FRONTIER_FIXED + ("off",)},
            "hold_cap_ratios": {a: (crossed_log_ratio(pooled["hold-cap"]["premium_p99_sched_hi"], pooled[a]["premium_p99_arr_lo"])
                                    if a in pooled and "hold-cap" in pooled else None) for a in FRONTIER_FIXED + ("off",)}}


def main(argv):
    if len(argv) in (3, 4) and argv[1] == "stage" and (len(argv) == 3 or argv[3] in STAGE_ARMS):
        json.dump(stage_report(argv[2], argv[3] if len(argv) == 4 else None), sys.stdout, indent=1, default=str)
        print()
        return 0
    if len(argv) == 3 and argv[1] == "frontier":
        json.dump(frontier(argv[2]), sys.stdout, indent=1, default=str)
        print()
        return 0
    if len(argv) == 3 and argv[1] == "diagnostic":
        json.dump(diagnostic(argv[2]), sys.stdout, indent=1, default=str)
        print()
        return 0
    if len(argv) == 4 and argv[1] == "gates":
        f = formulas(argv[2], argv[3])
        if not f.get("available"):
            print(json.dumps(f)); return 1
        json.dump({"L_ms": f["L_ms"], "gates": gates(argv[2], argv[3], f["L_ms"])}, sys.stdout, indent=1, default=str)
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
