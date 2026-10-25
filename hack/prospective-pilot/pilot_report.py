"""The prospective-admission pilot's measurement report.

    python3 pilot_report.py stage DIR [A|B]      one stage's measurements, as JSON, to stdout; with the stage named,
                                                 its missing cells are listed
    python3 pilot_report.py formulas DIR_A DIR_B  the frozen calibration formulas' outputs, or why they are unavailable
    python3 pilot_report.py gates DIR_A DIR_B     every registered pilot gate, with its value and whether it would fire
    python3 pilot_report.py diagnostic DIR        the admission diagnostic's verdict, validity and lines, per block
    python3 pilot_report.py frontier DIR          v26's verdict: hold-cap against the fixed spacings, with every line
    python3 pilot_report.py calibration DIR       v27's calibration gate: hold-cap at three lengths, with every line

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
    # A NaN compares false both ways, so a ratio built from one would pass a "fails" line and miss the verdict rule
    # that reads the same line (astra's attack on the C3 page, 1). It is not a ratio, so it is unscorable.
    if math.isnan(num) or math.isnan(den):
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


def provenance(stage_dir, arm, rep, study=None, seed=None, want=None):
    """Why a cell is not the registered one, or None: its manifest's study, arm, seed and trace checksum, and its
    rows against its trace's (v26 review, B6 and B7). The study, seed and checksum default to v26's."""
    tag = "%s-%d" % (arm, rep)
    m = manifest_fields(os.path.join(stage_dir, "manifest-%s.yaml" % tag))
    if m is None:
        return "it has no manifest"
    study = study or FRONTIER_STUDY
    seed = seed or FRONTIER_SEEDS[rep]
    want = want or FRONTIER_CHECKSUMS[seed][1 if arm == "R1" else 0]
    for key, value in (("study", study), ("arm", arm), ("seed", str(seed)), ("traceChecksum", want)):
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
    # Checked before sorting: a missing or non-integer index raised a TypeError past the cell's guard (review of 087cc3b).
    if any(type(r.get("index")) is not int for r in rows):
        return "a row has no integer index"
    if sorted(r.get("index") for r in rows) != sorted(trace):
        return "its rows are not its trace's requests, one each"
    for r in rows:
        t = trace[r["index"]]
        if (r.get("study"), r.get("arm"), r.get("traceChecksum")) != (study, arm, want):
            return "row %s names study %s, arm %s, trace %s" % (r["index"], r.get("study"), r.get("arm"), r.get("traceChecksum"))
        if (r.get("scheduledOffsetMs"), r.get("tenant")) != (t.get("offsetMs"), t.get("tenant")):
            return "row %s is not its trace's request at that index" % r["index"]
        # The payload too: a sender that sent another prompt replayed another workload under the right schedule
        # (review of the v27 calibration, C3). The engine's own count is checked where the engine reported one.
        if (r.get("promptLenChars"), r.get("exactInputTokens")) != (t.get("promptLenChars"), t.get("exactInputTokens")):
            return "row %s sent %s characters for %s tokens, and its trace has %s for %s" % (
                r["index"], r.get("promptLenChars"), r.get("exactInputTokens"), t.get("promptLenChars"), t.get("exactInputTokens"))
        if r.get("engineInputTokens") and r.get("engineInputTokens") != t.get("exactInputTokens"):
            return "row %s: the engine counted %s input tokens, and the trace froze %s" % (
                r["index"], r.get("engineInputTokens"), t.get("exactInputTokens"))
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


def score_cell(stage_dir, c, prov, check, validity, reports, outcomes):
    """One cell's validity lines, shared by v26's and v27's scorers; prov(arm, rep) is the cell's provenance check.
    Fills reports[c] and outcomes[c] when the cell's records are readable."""
    arm, rep = c.rsplit("-", 1)[0], int(c.rsplit("-", 1)[1])
    try:
        reports[c] = cell_report(stage_dir, arm, rep, L=DIAG_L_MS)
        outcomes[c] = contender_outcomes(stage_dir, c)
        # Inside the boundary too: a truncated trace crashed the whole report (review of fde74bb).
        why = prov(arm, rep)
    except (ValueError, KeyError, TypeError, IndexError) as e:
        # A truncated or malformed record makes the cell's evidence untrustworthy, not the scorer's run (B11).
        reports.pop(c, None)
        outcomes.pop(c, None)
        check(validity, "%s records readable" % c, str(e)[:120], "parseable", False)
        return
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
    # Every contender the gateway admitted must have reached this cell's scheduler: a step log from another cell matches
    # none of this cell's requests, and its work then reads as zero on both sides of every comparison (review of the
    # v27 calibration, C2).
    n_adm, n_seen = contenders_in_step_log(stage_dir, c)
    check(validity, "%s admitted contenders the step log scheduled" % c, (n_seen, n_adm), "all",
          True if n_adm == 0 and arm == "R1" else (n_adm > 0 and n_seen == n_adm))
    if arm.startswith("hold-cap") or arm in FRONTIER_FIXED:
        n_dec, n_mode = mode_reasons(stage_dir, c, "serial_prefill_" if arm.startswith("hold-cap") else "fixed_spacing_")
        check(validity, "%s contender decisions by its admission mode" % c, (n_mode, n_dec), "all",
              None if n_dec == 0 else n_mode == n_dec)
    if arm in FRONTIER_FIXED:
        least, p99 = spacing_deviation(stage_dir, c, float(arm.split("-")[1]) * 1000)
        # No held contender leaves nothing to time; the line above already shows the mode ran.
        check(validity, "%s admissions after the spacing" % c, (least, p99), "least >= -1 ms, p99 <= 13 ms",
              None if least == "missing" else (True if least is None else least >= -1.0 and p99 <= DIAG_L_MS))
    if arm == "off" or arm.startswith("off-"):
        loss = cr["premium"]["failed"] / cr["premium"]["n"] if cr["premium"]["n"] else None
        check(validity, "%s premium loss" % c, loss, "< 0.005", None if loss is None else loss < 0.005)
        done, offered = outcomes[c][0], outcomes[c][1]
        check(validity, "%s contender completion" % c, done / offered if offered else None, ">= 0.95",
              (done / offered >= 0.95) if offered else None)


def contenders_in_step_log(stage_dir, tag):
    """(contenders the gateway admitted, those of them with an add record in this cell's step log)."""
    rows = {r.get("requestId"): r.get("tenant") for r in jsonl(os.path.join(stage_dir, "raw-%s.jsonl" % tag))}
    admitted = [rid for rid, e in gateway_records(os.path.join(stage_dir, "gateway-record-%s.jsonl" % tag)).items()
                if rows.get(rid) == CONTENDER and (e.get("done") or {}).get("decision") == "admit"]
    added = set()
    for st in jsonl(os.path.join(stage_dir, "step-log-%s.jsonl" % tag)):
        if st.get("ev") == "add":
            m = match_client(st.get("id", ""), admitted)
            if m:
                added.add(m)
    return len(admitted), len(added)


def admissibility_lines(stage_dir, c, off, reports, outcomes):
    """[(name, value, rule, ok)]: the owner's four contender limits and the three safeguards for treatment cell c
    against its reference off cell, shared by v26's and v27's scorers."""
    o_done, o_off, o_lat, _, _ = outcomes[off]
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
    return res


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
        score_cell(stage_dir, c, lambda arm, rep: provenance(stage_dir, arm, rep), check, validity, reports, outcomes)

    # Admissibility, per treatment arm and block, against that block's off (v26 review, M14).
    first_fail = {a: None for a in FRONTIER_ARMS[1:]}
    for b in (1, 2, 3):
        off = "off-%d" % b
        if off not in reports:
            continue
        for arm in FRONTIER_ARMS[1:]:
            c = "%s-%d" % (arm, b)
            if c not in reports:
                continue
            res = admissibility_lines(stage_dir, c, off, reports, outcomes)
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


# ---------------------------------------------------------------- v27's calibration stage
#
# docs/superpowers/specs/2026-10-08-measuring-prospective-admission-design.md, "v27": off and hold-cap at three
# contender lengths, one block, to establish whether the robustness study is a feasible test before it is bought.

LENCAL_STUDY = "admission-length-calibration-2026-10-10"
LENCAL_SEED = 871
LENCAL_LENGTHS = (("short", 6144), ("ref", 7695), ("long", 8192))
# The frozen trace checksums, by length; R1's under "R1". The same table is in hack/lib/prospective-pilot.sh.
LENCAL_CHECKSUMS = {
    "R1": "a5b3aec4ecd11a0e697e3d65e1078560621b8907c6337a7dea6749910d9b256e",
    "short": "659b495a0617ccde5cb4181f191cfbec730ad28d2bd73d71f43ab59ecca924d1",
    "ref": "6893b01697f8b74a3cc6f1eafb9fd5c5b72a4899beede49393bc4e1c0276b63e",
    "long": "7adef562cc0912646bdb1035e77162ff6cd6e14364558d96fb79f8fc105b39b3",
}
LENCAL_CELLS = ["R1-1"] + ["%s-%s-1" % (a, l) for l, _ in LENCAL_LENGTHS for a in ("off", "hold-cap")]
# v26's fixed spacing, which the long level must outlast for the robustness study to test anything.
V26_SPACING_MS = 1740.0

# C3's calibration (docs/superpowers/specs/2026-10-24-c3-headroom-calibration.md): v27's cells at 0.375 contenders a
# second on seed 891. The same table is in hack/lib/prospective-pilot.sh.
HEADROOM_STUDY = "admission-headroom-calibration-2026-10-24"
HEADROOM_SEED = 891
HEADROOM_CHECKSUMS = {
    "R1": "5d1eed22b672a279b5bff76e1163e290ac811890359fcab55c2888b79842abc5",
    "short": "bf07e81165efe07a38362e8f2ed8e9bc24ef2dc58f17eef7fb65014d1406cb9a",
    "ref": "04f00759c75855845bd4431ac80721e04a5a95a8e33e139a275b82c3fafd5e8c",
    "long": "78a4b8f4f2ae02d1d93e207a75926bb87de0bc1792852258feac3af3bfc75cf4",
}
# The literal ratio of v26's selected 1,740 ms to v27's measured 1,652 ms at the reference (1.05327), frozen as
# registered: C3's fixed spacing is d(ref) times this, carried from the old load rather than tuned at the new one.
HEADROOM_SPACING_RATIO = 1.0533


def admission_to_content(stage_dir, tag):
    """(durations, untimed): each admitted contender's gateway decision to its first content, in ms, under
    serial-prefill the capped prefill as the gateway sees it; and how many contender successes lack either stamp,
    which would otherwise drop out of the median silently (review of 25f989a)."""
    rows = {r.get("requestId"): r for r in jsonl(os.path.join(stage_dir, "raw-%s.jsonl" % tag))}
    out, untimed = [], 0
    for rid, e in gateway_records(os.path.join(stage_dir, "gateway-record-%s.jsonl" % tag)).items():
        d, r = e.get("done") or {}, rows.get(rid) or {}
        if r.get("tenant") != CONTENDER or d.get("decision") != "admit":
            continue
        if d.get("decidedUnixNanos") and d.get("firstContentUnixNanos"):
            out.append(ms(d["firstContentUnixNanos"] - d["decidedUnixNanos"]))
        elif full_output(r, 16):
            untimed += 1
    return sorted(out), untimed


def engine_prefill(stage_dir, tag):
    """Each admitted contender's prefill as the engine ran it, in ms: from the scheduler's add to the end of the step
    that took its last prompt token, the time a fixed spacing must outlast at the engine. A contender the scheduler
    received and never finished prefilling counts as +inf, so the median is over every forwarded contender (review of
    the v27 calibration, C1 and C4)."""
    rows = {r.get("requestId"): r.get("tenant") for r in jsonl(os.path.join(stage_dir, "raw-%s.jsonl" % tag))}
    admitted = [rid for rid, e in gateway_records(os.path.join(stage_dir, "gateway-record-%s.jsonl" % tag)).items()
                if rows.get(rid) == CONTENDER and (e.get("done") or {}).get("decision") == "admit"]
    steps = jsonl(os.path.join(stage_dir, "step-log-%s.jsonl" % tag))
    # A done record without a finite end time cannot end a prefill; it is counted, so the caller can refuse the cell
    # rather than this crash or quietly time the contender as unfinished (astra's attack on the C3 page, 4).
    done, malformed = {}, 0
    for st in steps:
        if st.get("ev") == "done":
            t2 = st.get("t2")
            if isinstance(t2, (int, float)) and math.isfinite(t2):
                done[st.get("step")] = t2
            else:
                malformed += 1
    adds = {st["id"]: st for st in steps if st.get("ev") == "add" and match_client(st.get("id", ""), admitted)}
    ends = {}
    for st in steps:
        if st.get("ev") != "sched":
            continue
        for eid, n in st.get("tokens", {}).items():
            a = adds.get(eid)
            if a and eid not in ends and st.get("computed", {}).get(eid, 0) + n >= a["prompt"] and st["step"] in done:
                ends[eid] = done[st["step"]]
    return sorted(ms(ends[e] - a["mono"]) if e in ends else math.inf for e, a in adds.items()), malformed


def _length_stage(stage_dir, study, seed, checksums):
    """The measurements and the first three verdict rules both length calibrations share, v27's and C3's: every cell
    scored, each length's hold-cap against its off, and the reason, if any, the stage cannot be feasible.

    Returns (reason, validity, lines, measured, first_fail): reason is the inconclusive or not-feasible verdict, or
    None when hold-cap is admissible and protective at every length with a finite median engine prefill at each.
    """
    validity, lines = [], []

    def check(collection, name, value, rule, ok):
        collection.append({"line": name, "value": value, "rule": rule,
                           "state": "unscorable" if ok is None else ("holds" if ok else "fails")})

    def prov(arm, rep):
        key = "R1" if arm == "R1" else arm.rsplit("-", 1)[1]
        return provenance(stage_dir, arm, rep, study=study, seed=seed, want=checksums[key])

    present = {c: os.path.exists(os.path.join(stage_dir, "raw-%s.jsonl" % c)) for c in LENCAL_CELLS}
    missing = [c for c in LENCAL_CELLS if not present[c]]
    extra = sorted(os.path.basename(f)[4:-6] for f in glob.glob(os.path.join(stage_dir, "raw-*.jsonl"))
                   if os.path.basename(f)[4:-6] not in LENCAL_CELLS and not os.path.basename(f).startswith("raw-warmup-"))
    reports, outcomes = {}, {}
    for c in LENCAL_CELLS:
        if present[c]:
            score_cell(stage_dir, c, prov, check, validity, reports, outcomes)

    first_fail, measured = {}, {}
    for length, tokens in LENCAL_LENGTHS:
        h, o = "hold-cap-%s-1" % length, "off-%s-1" % length
        if h not in reports or o not in reports:
            continue
        for name, value, rule, ok in admissibility_lines(stage_dir, h, o, reports, outcomes):
            check(lines, "hold-cap at %s: %s" % (length, name), value, rule, ok)
            if ok is False and length not in first_fail:
                first_fail[length] = name
        h_hi, _, _, _ = _box([reports[h]])
        _, o_lo, _, _ = _box([reports[o]])
        r = crossed_log_ratio(h_hi, o_lo)
        check(lines, "hold-cap at %s: premium p99 crossed against off's" % length, r, "<= %.4f" % LN_085,
              None if r is None else r <= LN_085)
        if r is not None and r > LN_085 and length not in first_fail:
            first_fail[length] = "premium p99 crossed against off's"
        a2c, a2c_untimed = admission_to_content(stage_dir, h)
        check(validity, "hold-cap at %s: contender successes without gateway timing" % length, a2c_untimed, "0", a2c_untimed == 0)
        eng, eng_malformed = engine_prefill(stage_dir, h)
        check(validity, "hold-cap at %s: step-log done records without an end time" % length, eng_malformed, "0", eng_malformed == 0)
        measured[length] = {"tokens": tokens, "engine_prefill_p50_ms": nearest_rank(eng, 0.5),
                            "engine_prefill_p95_ms": nearest_rank(eng, 0.95),
                            "engine_prefill_unfinished": sum(1 for x in eng if math.isinf(x)),
                            "admission_to_content_p50_ms": nearest_rank(a2c, 0.5),
                            "admission_to_content_p95_ms": nearest_rank(a2c, 0.95), "contenders_timed": len(a2c),
                            "premium_p99_sched_hi_ms": h_hi, "off_premium_p99_arr_lo_ms": o_lo, "ln_ratio_to_off": r}

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
    if not inconclusive and len(measured) != len(LENCAL_LENGTHS):
        inconclusive.append("a length has no scored pair")
    # Every admissibility failure, at any length, before any protection failure: the registered order (review of
    # 25f989a). A failed crossed bound does not show the absence of protection, only that it was not established (C9).
    prot = "premium p99 crossed against off's"
    bad_len = ([l for l, _ in LENCAL_LENGTHS if l in first_fail and first_fail[l] != prot]
               + [l for l, _ in LENCAL_LENGTHS if first_fail.get(l) == prot])
    # A missing median matters only once hold-cap is admissible and protective everywhere: a scored admissibility
    # failure is "not feasible" whatever was timed (review of the v27 calibration, C5).
    if not inconclusive and not bad_len and not all(
            0 < (measured[l]["engine_prefill_p50_ms"] or 0) < math.inf for l, _ in LENCAL_LENGTHS):
        inconclusive.append("a length has no finite engine prefill median")

    # Feasible needs every line to hold, not only no rule to have fired: a line that failed or was unscorable without
    # reaching a rule above is a gap in the rules, and it is reported as one (astra's attack on the C3 page, 1).
    if not inconclusive and not bad_len:
        silent = [x["line"] for x in validity + lines if x["state"] != "holds"]
        if silent:
            inconclusive.append("lines that did not hold and reached no rule: " + ", ".join(silent[:5]))
    reason = None
    if inconclusive:
        reason = "inconclusive: " + "; ".join(inconclusive)
    elif bad_len:
        l = bad_len[0]
        reason = ("not feasible: hold-cap's 15%% protection of the premium tail was not established at %s" % l
                  if first_fail[l] == prot else "not feasible: hold-cap was not admissible at %s: %s" % (l, first_fail[l]))
    return reason, validity, lines, measured, first_fail


def calibration(stage_dir):
    """v27's calibration gate: whether hold-cap is admissible and protective at every length, and whether the long
    length lengthens the capped prefill past v26's fixed spacing, with every measurement it rests on.

    The verdicts, in order: inconclusive; not feasible, hold-cap inadmissible at a length; not feasible, hold-cap's
    protection not established at a length; challenge not achieved; feasible. Beside them it publishes the size-aware
    control's spacings the main study would freeze, s(N) = 1,740 ms x d(N) / d(reference), with d the median engine
    prefill under hold-cap over every forwarded contender; the gateway's admission-to-first-content is published
    beside it (design page, "v27", and its review).
    """
    verdict, validity, lines, measured, first_fail = _length_stage(stage_dir, LENCAL_STUDY, LENCAL_SEED, LENCAL_CHECKSUMS)
    spacings = None
    if verdict is None:
        # Judged on the engine's own prefill, which is what a fixed spacing must outlast; the gateway's view adds the
        # transport and the flush (review of the v27 calibration, C1).
        d_ref, d_long = measured["ref"]["engine_prefill_p50_ms"], measured["long"]["engine_prefill_p50_ms"]
        spacings = {l: round(V26_SPACING_MS * measured[l]["engine_prefill_p50_ms"] / d_ref, 1) for l, _ in LENCAL_LENGTHS}
        if d_ref > V26_SPACING_MS:
            # v26's spacing must still cover the reference's prefill on this card, or a failure at the long length would
            # not be the length's doing (C6).
            verdict = "challenge not achieved: the reference's median engine prefill, %.0f ms, already exceeds 1,740 ms" % d_ref
        elif not (d_long > V26_SPACING_MS and d_long > 1.05 * d_ref):
            verdict = ("challenge not achieved: hold-cap's median engine prefill at the long length, %.0f ms, does not exceed "
                       "both 1,740 ms and 1.05 times the reference's %.0f ms" % (d_long, d_ref))
        else:
            verdict = "feasible: hold-cap admissible and protective at every length, and the long length outlasts 1,740 ms"
    return {"verdict": verdict, "validity": validity, "lines": lines, "measured": measured,
            "size_aware_spacings_ms": spacings, "first_failure": first_fail}


def headroom(stage_dir):
    """C3's calibration gate: v27's first rules, then the challenge judged against S = 1.0533 x d(reference) in place of
    v26's 1,740 ms, so the long length must outlast a spacing derived from this card's reference
    (docs/superpowers/specs/2026-10-24-c3-headroom-calibration.md, "The gate").

    S and the size-aware spacings S x d(N) / d(reference) are published whenever every median is finite and positive and
    S does not round to zero, and are
    frozen for a main study only when the verdict is feasible; otherwise they are labelled provisional.
    """
    verdict, validity, lines, measured, first_fail = _length_stage(stage_dir, HEADROOM_STUDY, HEADROOM_SEED, HEADROOM_CHECKSUMS)
    medians = {l: (measured.get(l) or {}).get("engine_prefill_p50_ms") for l, _ in LENCAL_LENGTHS}
    fixed, spacings = None, None
    if all(m is not None and 0 < m < math.inf for m in medians.values()):
        fixed = round(HEADROOM_SPACING_RATIO * medians["ref"], 1)
        spacings = {l: round(fixed * medians[l] / medians["ref"], 1) for l, _ in LENCAL_LENGTHS}
        # A positive reference under 0.05 ms, kind's stub engine, rounds S to zero, and any long length outlasts that.
        if not fixed > 0:
            fixed, spacings = None, None
            if verdict is None:
                verdict = ("inconclusive: S = 1.0533 x the reference's median rounds to 0.0 ms at 0.1 ms, so there is no "
                           "spacing to challenge (reference median %r ms)" % medians["ref"])
    if verdict is None:
        # The rule v27 also required, 1.05 times the reference, is implied: S is already 1.0533 times it.
        if not medians["long"] > fixed:
            verdict = ("challenge not achieved: hold-cap's median engine prefill at the long length, %.0f ms, does not exceed "
                       "S = %.1f ms, 1.0533 times the reference's %.0f ms" % (medians["long"], fixed, medians["ref"]))
        else:
            verdict = "feasible: hold-cap admissible and protective at every length, and the long length outlasts S = %.1f ms" % fixed
    return {"verdict": verdict, "validity": validity, "lines": lines, "measured": measured,
            "fixed_spacing_ms": fixed, "size_aware_spacings_ms": spacings,
            "spacings_status": "frozen for the main study" if verdict.startswith("feasible") else "provisional, not licensed for a main study",
            "first_failure": first_fail}


# ---------------------------------------------------------------- C3's main study
#
# docs/superpowers/specs/2026-10-25-c3-headroom-main.md: off, cap-only, hold-cap, the frozen S and the frozen
# size-aware spacings at three lengths, one block per session over three sessions, scored together.

MAIN_STUDY = "admission-headroom-main-2026-10-25"
MAIN_SEEDS = {1: 882, 2: 892, 3: 893}
# The frozen trace checksums, by seed and length; R1's under "R1". The same table is in hack/lib/prospective-pilot.sh.
MAIN_CHECKSUMS = {
    882: {"R1": "1bd9c8513141261c7b615dbb0f3371a6b82450ecf9c705c45523953d4800bf4f",
          "short": "b7ffc7eec33e8a3166a8a92f51283d4622d68867982f50739e6fc4c12f41392a",
          "ref": "46a5cc47debf87ddc3af8c81faee36c96a8c64a0cf2c9bb3413593d69768f5d6",
          "long": "e8b057853cf5c38df49a7811fa469f39985f0f02d65c280ed2b79c39cb070d53"},
    892: {"R1": "7d269b31213421a781399325f80fea19ea0ba49f2cd0af34e6da5e9577f2e382",
          "short": "888ff4868e99cc18f372b94a24db5c2d8d8cc3a1e3dd68f5d181aae958b836a7",
          "ref": "39826dc699f63440796339920f82035a6a27a25116660d1200ca99d7d1d8a1ad",
          "long": "68727974493694fea6023056ceafd1ee89d72c0f46664ea05382f351820b493d"},
    893: {"R1": "c0a0dde28547b67a9a05ec1b0f78c8d3a2cee0cd0ac183ad6869d8d26092c8b7",
          "short": "56a9dc08d564bb54a55dd2e16079cee6d28296390345a0690d73e2cbca769787",
          "ref": "248faf6a28ba483fffe80e0b48cbf8766eb1b6e378a3af28d436725c0978d326",
          "long": "c5681e8ae15c385e6262fea807317a16fd832b3bbc0661642fae08289cf2a69a"},
}
MAIN_ARMS = ("off", "caponly", "hold-cap", "fixedS", "sizeaware")
MAIN_LENGTHS = ("short", "ref", "long")
MAIN_CELLS = ["R1-1"] + ["%s-%s-1" % (a, l) for l in MAIN_LENGTHS for a in MAIN_ARMS]
# S from the calibration's scored medians, and the size-aware spacing of each length, frozen by its verdict.
MAIN_S_MS = 1680.4
MAIN_SPACING_MS = {"fixedS": {"short": 1680.4, "ref": 1680.4, "long": 1680.4},
                   "sizeaware": {"short": 1176.9, "ref": 1680.4, "long": 1830.8}}
# Each block's registered order after R1; the same table is in hack/lib/prospective-pilot.sh.
MAIN_ORDER = {
    1: "hold-cap-long fixedS-long fixedS-ref hold-cap-ref off-long caponly-short sizeaware-short off-ref fixedS-short "
       "off-short caponly-long hold-cap-short sizeaware-long sizeaware-ref caponly-ref",
    2: "hold-cap-short off-ref hold-cap-long fixedS-long fixedS-short hold-cap-ref sizeaware-ref caponly-ref caponly-short "
       "fixedS-ref off-short sizeaware-short off-long sizeaware-long caponly-long",
    3: "fixedS-long sizeaware-ref off-short caponly-short sizeaware-short caponly-long off-ref sizeaware-long fixedS-short "
       "off-long hold-cap-short hold-cap-ref fixedS-ref hold-cap-long caponly-ref",
}
LN_115 = math.log(1.15)
# The engine's per-step prefill cap of every arm but off and R1, as hack/lib/prospective-pilot.sh renders it.
MAIN_PREFILL_CAP = 384


def engine_cap(stage_dir, tag):
    """The prefill cap the cell's engine reported in its non-default arguments, 0 for none, or None without that line."""
    path = os.path.join(stage_dir, "engine-log-%s.txt" % tag)
    if not os.path.exists(path):
        return None
    with open(path, errors="replace") as f:
        for line in f:
            m = re.search(r"non-default args: (\{.*\})", line)
            if m:
                cap = re.search(r"'long_prefill_token_threshold': (\d+)", m.group(1))
                return int(cap.group(1)) if cap else 0
    return None


def _admitted_contenders(stage_dir, tag):
    rows = {r.get("requestId"): r.get("tenant") for r in jsonl(os.path.join(stage_dir, "raw-%s.jsonl" % tag))}
    return [d for rid, e in gateway_records(os.path.join(stage_dir, "gateway-record-%s.jsonl" % tag)).items()
            for d in [e.get("done") or {}] if rows.get(rid) == CONTENDER and d.get("decision") == "admit"]


def serial_witness(stage_dir, tag):
    """(missing stamps, admissions before the previous admission's release, releases off their first content): what
    hold-cap did in time, not what its reason labels say (astra's attack on the main page, 1).
    A release with first content lies at most 13 ms before it; one without lies at the request's end."""
    adm = _admitted_contenders(stage_dir, tag)
    missing = sum(1 for d in adm if not d.get("decidedUnixNanos") or not d.get("releasedUnixNanos"))
    if missing:
        return missing, None, None
    adm.sort(key=lambda d: d["decidedUnixNanos"])
    early = sum(1 for a, b in zip(adm, adm[1:]) if b["decidedUnixNanos"] < a["releasedUnixNanos"])
    off = 0
    for d in adm:
        fc = d.get("firstContentUnixNanos")
        if fc and not d.get("firstContentAtEnd"):
            off += not (0 <= fc - d["releasedUnixNanos"] <= DIAG_L_MS * 1_000_000)
        else:
            off += not d.get("releasedAtEnd")
    return 0, early, off


def spacing_witness(stage_dir, tag, spacing_ms):
    """(missing stamps, consecutive contender admissions closer than the spacing less 1 ms), whatever their labels."""
    adm = _admitted_contenders(stage_dir, tag)
    missing = sum(1 for d in adm if not d.get("decidedUnixNanos"))
    if missing:
        return missing, None
    t = sorted(d["decidedUnixNanos"] for d in adm)
    return 0, sum(1 for a, b in zip(t, t[1:]) if ms(b - a) < spacing_ms - 1.0)


def _session_gpu(stage_dir):
    """The GPU UUIDs the session's cells recorded, from cell-environment.tsv; empty without it."""
    path = os.path.join(stage_dir, "cell-environment.tsv")
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return sorted({u for row in csv.DictReader(f, delimiter="\t") if row.get("fact") == "gpu"
                       for u in re.findall(r"GPU-[0-9a-f-]+", row.get("value", ""))})


def _cell_order(stage_dir):
    """The arms in the order cell-timings.tsv lists them, or None without it."""
    path = os.path.join(stage_dir, "cell-timings.tsv")
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return [row.get("arm") for row in csv.DictReader(f, delimiter="\t")]


def headroom_main(dirs):
    """C3's main study over its three sessions, block b's archive at dirs[b - 1]: the primary verdict, the size-aware
    and cap-only verdicts beside it, and every line and pooled quantity they read
    (docs/superpowers/specs/2026-10-25-c3-headroom-main.md, "The verdict, in this order")."""
    validity, lines = [], []

    def check(collection, name, value, rule, ok):
        collection.append({"line": name, "value": value, "rule": rule,
                           "state": "unscorable" if ok is None else ("holds" if ok else "fails")})

    inventory, reports, outcomes, gpus = [], {}, {}, {}
    for b, stage_dir in enumerate(dirs, start=1):
        seed = MAIN_SEEDS[b]
        present = {c: os.path.exists(os.path.join(stage_dir, "raw-%s.jsonl" % c)) for c in MAIN_CELLS}
        inventory += ["block %d: %s not acquired" % (b, c) for c in MAIN_CELLS if not present[c]]
        inventory += ["block %d: %s was not bought" % (b, os.path.basename(f)[4:-6])
                      for f in glob.glob(os.path.join(stage_dir, "raw-*.jsonl"))
                      if os.path.basename(f)[4:-6] not in MAIN_CELLS and not os.path.basename(f).startswith("raw-warmup-")]
        order = _cell_order(stage_dir)
        want = ["R1"] + MAIN_ORDER[b].split()
        check(validity, "block %d's cells ran in its registered order" % b, None if order is None else " ".join(order),
              " ".join(want), None if order is None else order == want)
        gpus[b] = _session_gpu(stage_dir)

        def prov(arm, rep, b=b, seed=seed, stage_dir=stage_dir):
            return provenance(stage_dir, arm, rep, study=MAIN_STUDY, seed=seed,
                              want=MAIN_CHECKSUMS[seed]["R1" if arm == "R1" else arm.rsplit("-", 1)[1]])

        rb, ob = {}, {}
        for c in MAIN_CELLS:
            if not present[c]:
                continue
            score_cell(stage_dir, c, prov, lambda coll, name, value, rule, ok: check(coll, "block %d: %s" % (b, name), value, rule, ok),
                       validity, rb, ob)
            if c in rb:
                reports["%s@%d" % (c, b)], outcomes["%s@%d" % (c, b)] = rb[c], ob[c]
            arm = c.rsplit("-", 1)[0]
            name = "block %d: %s" % (b, c)
            # The block a session ran is named in every request id the matrix gave it: a directory passed as another
            # block's is refused rather than pooled under the wrong seed's name.
            rows = jsonl(os.path.join(stage_dir, "raw-%s.jsonl" % c))
            prefix = "pp-H-%s-%d-" % (arm, b)
            misnamed = sum(1 for r in rows if not str(r.get("requestId", "")).startswith(prefix))
            check(validity, "%s request ids name block %d" % (name, b), misnamed, "0", misnamed == 0)
            cap = engine_cap(stage_dir, c)
            want_cap = 0 if arm == "R1" or arm.startswith("off-") else MAIN_PREFILL_CAP
            check(validity, "%s engine prefill cap" % name, cap, str(want_cap), None if cap is None else cap == want_cap)
            family = arm.rsplit("-", 1)[0]
            if family in ("R1", "off", "caponly"):
                n_dec, n_mode = mode_reasons(stage_dir, c, "admission_off")
                check(validity, "%s contender decisions with admission off" % name, (n_mode, n_dec), "all",
                      True if n_dec == 0 else n_mode == n_dec)
            if family == "hold-cap":
                missing, early, off = serial_witness(stage_dir, c)
                check(validity, "%s admissions after the previous release, releases at first content" % name,
                      (missing, early, off), "no stamp missing, 0 early, 0 off", None if missing else early == 0 and off == 0)
            if family in MAIN_SPACING_MS:
                spacing = MAIN_SPACING_MS[family][arm.rsplit("-", 1)[1]]
                n_dec, n_mode = mode_reasons(stage_dir, c, "fixed_spacing_")
                check(validity, "%s contender decisions by fixed spacing" % name, (n_mode, n_dec), "all",
                      None if n_dec == 0 else n_mode == n_dec)
                least, p99 = spacing_deviation(stage_dir, c, spacing)
                check(validity, "%s admissions after the %.1f ms spacing" % (name, spacing), (least, p99),
                      "least >= -1 ms, p99 <= 13 ms",
                      None if least == "missing" else (True if least is None else least >= -1.0 and p99 <= DIAG_L_MS))
                missing, close = spacing_witness(stage_dir, c, spacing)
                check(validity, "%s consecutive admissions at least %.1f ms less 1 ms apart" % (name, spacing),
                      (missing, close), "no stamp missing, 0 closer", None if missing else close == 0)
        # Admissibility per treatment arm, length and block, against that block's off at the same length.
        for l in MAIN_LENGTHS:
            off = "off-%s-1" % l
            for a in MAIN_ARMS[1:]:
                c = "%s-%s-1" % (a, l)
                if "%s@%d" % (c, b) not in reports or "%s@%d" % (off, b) not in reports:
                    continue
                res = admissibility_lines(stage_dir, c, off, {c: reports["%s@%d" % (c, b)], off: reports["%s@%d" % (off, b)]},
                                          {c: outcomes["%s@%d" % (c, b)], off: outcomes["%s@%d" % (off, b)]})
                for n, value, rule, ok in res:
                    check(lines, "%s at %s, block %d: %s" % (a, l, b, n), value, rule, ok)

    def adm(a, l):
        return not any(x["state"] == "fails" for x in lines if x["line"].startswith("%s at %s, block " % (a, l)))

    pooled = {}
    for a in MAIN_ARMS:
        for l in MAIN_LENGTHS:
            keys = ["%s-%s-1@%d" % (a, l, b) for b in (1, 2, 3)]
            if not all(k in reports for k in keys):
                continue
            cs = [reports[k] for k in keys]
            sched_hi, arr_lo, sched_lo, arr_hi = _box(cs)
            done = sum(outcomes[k][0] for k in keys)
            offered = sum(outcomes[k][1] for k in keys)
            work = {k: (sum(c["work"][k] for c in cs) / 3 if all(c["work"][k] is not None for c in cs) else None)
                    for k in ("p_shared_window", "q_shared_window")}
            pooled[(a, l)] = {"premium_p99_sched_hi": sched_hi, "premium_p99_arr_lo": arr_lo, "premium_p99_sched_lo": sched_lo,
                              "premium_p99_arr_hi": arr_hi, "contender_completion": done / offered if offered else None,
                              "work": work}

    def U(x, y, l):
        if (x, l) not in pooled or (y, l) not in pooled:
            return None
        return crossed_log_ratio(pooled[(x, l)]["premium_p99_sched_hi"], pooled[(y, l)]["premium_p99_arr_lo"])

    def K(x, y, l):
        px, py = pooled.get((x, l)), pooled.get((y, l))
        if px is None or py is None:
            return None
        cx, cy = px["contender_completion"], py["contender_completion"]
        ws = [(px["work"][k], py["work"][k]) for k in ("p_shared_window", "q_shared_window")]
        if cx is None or cy is None or any(w is None or v is None for w, v in ws):
            return None
        return cx >= cy - 0.01 and all(w >= 0.97 * v for w, v in ws)

    def W(x, y, l, bound=LN_085):
        u, k = U(x, y, l), K(x, y, l)
        return u is not None and k is not None and adm(x, l) and k and u <= bound

    # d per block, hold-cap's median engine prefill at each length.
    d, d_bad = {}, []
    for b, stage_dir in enumerate(dirs, start=1):
        for l in MAIN_LENGTHS:
            c = "hold-cap-%s-1" % l
            if "%s@%d" % (c, b) not in reports:
                continue
            eng, malformed = engine_prefill(stage_dir, c)
            check(validity, "block %d: hold-cap at %s: step-log done records without an end time" % (b, l), malformed, "0", malformed == 0)
            d[(l, b)] = nearest_rank(eng, 0.5)

    # Every bound rules 3 to 7 read, and every work comparison, scored before any rule is reached (rule 1).
    needed = {}
    for l in MAIN_LENGTHS:
        needed["U(H, O) at %s" % l] = U("hold-cap", "off", l)
    needed["U(F, O) at ref"] = U("fixedS", "off", "ref")
    for l in ("ref", "long"):
        needed["U(H, F) at %s" % l] = U("hold-cap", "fixedS", l)
        needed["U(F, H) at %s" % l] = U("fixedS", "hold-cap", l)
        needed["K(H, F) at %s" % l] = K("hold-cap", "fixedS", l)
    needed["K(F, H) at ref"] = K("fixedS", "hold-cap", "ref")

    unscorable = [x["line"] for x in validity + lines if x["state"] == "unscorable"]
    bad = [x["line"] for x in validity if x["state"] == "fails"]
    inconclusive = []
    if len(dirs) != 3:
        inconclusive.append("%d session archive(s), and the study registers three blocks" % len(dirs))
    if inventory:
        inconclusive.append("cells: " + ", ".join(inventory[:5]))
    if bad:
        inconclusive.append("evidence not trusted: " + ", ".join(bad[:5]))
    if unscorable:
        inconclusive.append("unscorable: " + ", ".join(unscorable[:5]))
    if not inconclusive and len(pooled) != len(MAIN_ARMS) * len(MAIN_LENGTHS):
        inconclusive.append("an arm has fewer than three scored cells at a length")
    if not inconclusive:
        missing = [k for k, v in needed.items() if v is None]
        if missing:
            inconclusive.append("bounds the verdict reads are unscorable: " + ", ".join(missing))

    h_fail = [x["line"] for x in lines if x["line"].startswith("hold-cap at ") and x["state"] == "fails"]
    verdict, ahead, interaction = None, None, None
    if inconclusive:
        verdict = "inconclusive: " + "; ".join(inconclusive)
    elif h_fail:
        verdict = "hold-cap not operationally robust: " + "; ".join(h_fail)
    elif any(needed["U(H, O) at %s" % l] > LN_085 for l in MAIN_LENGTHS):
        verdict = "hold-cap's protection not established at " + ", ".join(
            l for l in MAIN_LENGTHS if needed["U(H, O) at %s" % l] > LN_085)
    if verdict is None:
        ds = [d.get((l, b)) for l in ("ref", "long") for b in (1, 2, 3)]
        if not all(x is not None and 0 < x < math.inf for x in ds):
            verdict = "inconclusive: a block's hold-cap median engine prefill at ref or long is missing, not positive or infinite"
        else:
            failed = [b for b in (1, 2, 3) if not (d[("ref", b)] <= MAIN_S_MS and d[("long", b)] > MAIN_S_MS
                                                   and d[("long", b)] > 1.05 * d[("ref", b)])]
            if failed:
                verdict = "challenge not reproduced on block " + ", ".join(str(b) for b in failed)
    if verdict is None:
        if not adm("fixedS", "ref"):
            verdict = "reference comparison not established: fixed-S inadmissible at ref"
        elif needed["U(F, O) at ref"] > LN_085:
            verdict = "reference comparison not established: fixed-S not protective at ref"
        elif W("fixedS", "hold-cap", "ref"):
            verdict = "the frozen spacing beat hold-cap at the reference"
        else:
            h_ahead = W("hold-cap", "fixedS", "ref")
            if not h_ahead and (needed["U(H, F) at ref"] <= LN_085 or needed["U(F, H) at ref"] <= LN_085):
                verdict = ("reference comparison not established: a 15%% bound at ref held without its work line (%s)"
                           % ("U(H, F)" if needed["U(H, F) at ref"] <= LN_085 else "U(F, H)"))
            else:
                ahead = h_ahead
    if verdict is None:
        u_long, l_ref = needed["U(H, F) at long"], -needed["U(F, H) at ref"]
        if math.isinf(u_long) and math.isinf(l_ref) and (u_long > 0) == (l_ref > 0):
            interaction = None
        else:
            interaction = u_long - l_ref
        separated = (not adm("fixedS", "long")) or W("hold-cap", "fixedS", "long")
        start = "with hold-cap already ahead at the reference" if ahead else "from a reference with neither ahead"
        if interaction is None:
            verdict = "inconclusive: the interaction is undefined (both of its bounds infinite)"
        elif interaction <= LN_085 and needed["K(H, F) at long"] and separated:
            verdict = "length-dependent advantage over the frozen spacing observed, " + start
        else:
            why = [w for w, bad_ in (("the interaction %.3f exceeds ln 0.85" % interaction, interaction > LN_085),
                                     ("hold-cap's retained work at long fell short of fixed-S's", not needed["K(H, F) at long"]),
                                     ("fixed-S was admissible at long and hold-cap did not beat it by 15%", not separated)) if bad_]
            if W("fixedS", "hold-cap", "long"):
                why.append("fixed-S beat hold-cap at long")
            verdict = "length-dependent advantage not established, %s: %s" % (start, "; ".join(why))

    def secondary(x, name):
        if verdict.startswith("inconclusive"):
            return "%s comparison unavailable: the primary verdict is inconclusive" % name
        us = {l: (U(x, "off", l), U(x, "hold-cap", l), K(x, "hold-cap", l)) for l in MAIN_LENGTHS}
        if any(v is None for t in us.values() for v in t):
            return "%s comparison unresolved: a bound or work line it reads is unscorable" % name
        return None

    sa = secondary("sizeaware", "size-aware")
    if sa is None:
        bad_l = [l for l in MAIN_LENGTHS if not adm("sizeaware", l)]
        if bad_l:
            sa = "the frozen size-aware control broke the limits at " + ", ".join(bad_l)
        elif all(U("sizeaware", "off", l) <= LN_085 and W("sizeaware", "hold-cap", l, LN_115) for l in MAIN_LENGTHS):
            sa = "the frozen size-aware control did as well, within 15%"
            won = [l for l in MAIN_LENGTHS if W("sizeaware", "hold-cap", l)]
            if won:
                sa += "; it beat hold-cap by 15% at " + ", ".join(won)
        elif W("hold-cap", "sizeaware", "long"):
            sa = "hold-cap beat the frozen size-aware control at long"
        else:
            sa = "size-aware comparison unresolved"
    co = secondary("caponly", "cap-only")
    if co is None:
        if all(U("caponly", "off", l) <= LN_085 and W("caponly", "hold-cap", l, LN_115) for l in MAIN_LENGTHS):
            co = "the cap alone protects, within 15% of hold-cap"
        else:
            won = [l for l in MAIN_LENGTHS if W("hold-cap", "caponly", l)]
            co = ("the gateway's signal added to the cap at " + ", ".join(won)) if won else "cap-only comparison unresolved"

    comparisons = {}
    for l in MAIN_LENGTHS:
        for x in MAIN_ARMS:
            for y in MAIN_ARMS:
                if x != y:
                    comparisons["U(%s, %s) at %s" % (x, y, l)] = U(x, y, l)
    uuids = sorted({u for v in gpus.values() for u in v})
    return {"verdict": verdict, "size_aware": sa, "cap_only": co, "hold_cap_ahead_at_ref": ahead,
            "interaction": interaction, "validity": validity, "lines": lines,
            "pooled": {"%s at %s" % k: v for k, v in pooled.items()}, "comparisons": comparisons,
            "admissible": {"%s at %s" % (a, l): adm(a, l) for a in MAIN_ARMS[1:] for l in MAIN_LENGTHS},
            "engine_prefill_p50_ms": {"%s, block %d" % k: v for k, v in d.items()},
            "fixed_s_ref_against_size_aware_ref": (U("fixedS", "sizeaware", "ref"), U("sizeaware", "fixedS", "ref")),
            "gpu_uuids": {str(b): v for b, v in gpus.items()}, "distinct_gpus": len(uuids)}


def main(argv):
    if len(argv) == 5 and argv[1] == "headroom-main":
        json.dump(headroom_main(argv[2:]), sys.stdout, indent=1, default=str)
        print()
        return 0
    if len(argv) in (3, 4) and argv[1] == "stage" and (len(argv) == 3 or argv[3] in STAGE_ARMS):
        json.dump(stage_report(argv[2], argv[3] if len(argv) == 4 else None), sys.stdout, indent=1, default=str)
        print()
        return 0
    if len(argv) == 3 and argv[1] == "calibration":
        json.dump(calibration(argv[2]), sys.stdout, indent=1, default=str)
        print()
        return 0
    if len(argv) == 3 and argv[1] == "headroom":
        json.dump(headroom(argv[2]), sys.stdout, indent=1, default=str)
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
