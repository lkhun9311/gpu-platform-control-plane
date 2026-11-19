#!/usr/bin/env python3
"""Score one or more #2881 runs: client statuses, release-then-reject from the EPP log, and the load at each rejection.

A request counts as release-then-reject when the EPP log shows, under its x-request-id:
  1. "Flow control outcome" with outcome "Dispatched" (admission.go: flow control released it), and
  2. "Filter eliminated all endpoints" with plugin "conc/concurrency-detector" (scheduler_profile.go), and
  3. "Failed to process request" with "ServiceUnavailable - no endpoints available" (server.go).
The client side of the same request must be a 503 with x-llm-d-request-dropped-reason: rejected-no-endpoints.

The per-endpoint load at a rejection is rebuilt from the same log, the way the inflight-load producer counts it:
a routed request adds 1 request and prompt_tokens + max_tokens tokens to its target when its PreRequest hook completes,
and removes both at its endOfStream response chunk.
With addEstimatedOutputTokens and no prefill profile the producer releases nothing earlier (producer.go ResponseBody).
The output estimate is max_tokens because max_tokens never exceeds the 100-token floor of the UNKNOWN estimate.
The log timestamps bracket the producer's counter updates to within microseconds, not exactly.
"""
import bisect
import collections
import gzip
import json
import re
import statistics
import sys
from datetime import datetime
from pathlib import Path


def ts(s):
    # Nanosecond RFC 3339 with a Z suffix; Python parses microseconds, which is finer than any gap reported here.
    m = re.match(r"(.*T\d\d:\d\d:\d\d)(?:\.(\d+))?Z", s)
    frac = (m.group(2) or "0")[:6].ljust(6, "0")
    return datetime.fromisoformat(m.group(1) + "." + frac + "+00:00").timestamp()


def limits(cfg_text):
    def grab(key, default):
        m = re.search(rf"^\s*{key}:\s*(\S+)", cfg_text, re.M)
        return m.group(1) if m else default
    mode = grab("concurrencyMode", "requests")
    return mode, int(grab("maxConcurrency", "100")), int(grab("maxTokenConcurrency", "1000000")), float(grab("headroom", "0"))


def pct(xs, p):
    if not xs:
        return None
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1))))]


def metric_sum(text, name, **labels):
    total = 0.0
    for line in text.splitlines():
        if not line.startswith(name + "{") and not line.startswith(name + " "):
            continue
        if all(f'{k}="{v}"' in line for k, v in labels.items()):
            total += float(line.rsplit(" ", 1)[1])
    return total


# The log lines the scoring reads; slim() keeps only these, so a committed run can be re-scored without the full log.
SCORED_BODIES = (
    "EPP received request", "Flow control outcome", "Before running filter plugins", "Filter eliminated all endpoints",
    "Completed running picker plugin successfully", "Completed running PreRequest plugin successfully",
    "HandleResponseBody is triggered", "Failed to process request")


def opn(path):
    """Open a run file, or its gzipped copy once the run has been packed for commit."""
    path = Path(path)
    return open(path) if path.exists() else gzip.open(str(path) + ".gz", "rt")


def open_log(run):
    full = run / "epp.log"
    return open(full) if full.exists() else gzip.open(run / "epp-scored.log.gz", "rt")


def slim(run):
    """Write epp-scored.log.gz: the scored lines of epp.log, dropping chunk lines other than endOfStream."""
    with open(run / "epp.log") as src, gzip.open(run / "epp-scored.log.gz", "wt") as dst:
        for line in src:
            m = re.search(r'"body":"([^"]*)"', line)
            if not m or m.group(1) not in SCORED_BODIES:
                continue
            if m.group(1) == "HandleResponseBody is triggered" and '"endOfStream":true' not in line:
                continue
            dst.write(line)


def parse_epp(run, prefix):
    reqs = collections.defaultdict(dict)
    with open_log(run) as f:
        for line in f:
            if '"x-request-id":"' + prefix not in line:
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            rid = d.get("x-request-id", "")
            if not rid.startswith(prefix):
                continue
            r = reqs[rid]
            body, t = d.get("body"), ts(d["timestamp"])
            if body == "EPP received request":
                r["recv"] = t
            elif body == "Flow control outcome":
                r["release"], r["outcome"] = t, d.get("outcome")
            elif body == "Before running filter plugins":
                r["filter_in"] = [
                    {"pod": e["Name"], "running": e.get("RunningRequestsSize"), "waiting": e.get("WaitingQueueSize"),
                     "scraped": e.get("UpdateTime")} for e in d.get("endpoints") or []]
            elif body == "Filter eliminated all endpoints":
                r["eliminated"], r["eliminated_by"] = t, d.get("plugin")
            elif body == "Completed running picker plugin successfully":
                eps = (d.get("result") or {}).get("TargetEndpoints") or []
                if eps:
                    r["pod"] = eps[0]["Endpoint"]["Name"]
            elif body == "Completed running PreRequest plugin successfully" and "inflight-load" in d.get("plugin", ""):
                r["prereq"] = t
            elif body == "HandleResponseBody is triggered" and d.get("endOfStream"):
                r["eos"] = t
            elif body == "Failed to process request":
                r["fail"], r["error"] = t, d.get("error", "")
    return reqs


def analyze(run):
    run = Path(run)
    cfg = (run / "epp-config.yaml").read_text()
    mode, max_req, max_tok, headroom = limits(cfg)
    req_limit, tok_limit = int(max_req * (1 + headroom)), int(max_tok * (1 + headroom))
    # Engine slots are the simulator's --max-num-seqs, whatever the detector's mode.
    slots = int(re.search(r"--max-num-seqs=(\d+)", (run / "pins.txt").read_text()).group(1))
    client = [json.loads(l) for l in opn(run / "requests.jsonl")]
    prefix = client[0]["id"].rsplit("-", 1)[0] + "-"
    tokens = {}
    if (run / "tokens.jsonl").exists() or (run / "tokens.jsonl.gz").exists():
        for l in opn(run / "tokens.jsonl"):
            t = json.loads(l)
            tokens[t["id"]] = t["prompt_tokens"] + t["max_tokens"]
    epp = parse_epp(run, prefix)

    status = collections.Counter()
    for c in client:
        if c.get("err") and not c.get("status"):
            status["client-error"] += 1
        elif c["status"] in (200, 429, 503):
            status[str(c["status"])] += 1
        else:
            status["other"] += 1
    reasons = collections.Counter(c.get("dropped_reason", "") for c in client if c["status"] == 503)

    rtr = sorted(
        rid for rid, r in epp.items()
        if r.get("outcome") == "Dispatched" and r.get("eliminated_by") == "conc/concurrency-detector"
        and "no endpoints available" in r.get("error", ""))
    rtr_set = set(rtr)
    by_id = {c["id"]: c for c in client}
    rtr_client_503 = sum(1 for rid in rtr if by_id.get(rid, {}).get("status") == 503
                         and by_id[rid].get("dropped_reason") == "rejected-no-endpoints")
    missing_in_log = sum(1 for c in client if c["id"] not in epp or "outcome" not in epp[c["id"]])
    # Lost downstream lines would undercount rejections or misplace load, so each client outcome is held to its lines.
    ok_without_route = sum(1 for c in client if c["status"] == 200 and not all(
        k in epp.get(c["id"], {}) for k in ("prereq", "pod", "eos")))
    rejected_without_lines = sum(1 for c in client if c["status"] == 503 and c["id"] not in rtr_set)

    # Event stream of routed requests: (time, pod, d_requests, d_tokens).
    events = []
    for rid, r in epp.items():
        if "prereq" in r and "pod" in r:
            cost = tokens.get(rid, 0)
            events.append((r["prereq"], r["pod"], 1, cost))
            if "eos" in r:
                events.append((r["eos"], r["pod"], -1, -cost))
    events.sort()
    times = [e[0] for e in events]
    pods = sorted({e[1] for e in events})

    def load_at(t):
        load = {p: [0, 0] for p in pods}
        for e in events[:bisect.bisect_right(times, t)]:
            load[e[1]][0] += e[2]
            load[e[1]][1] += e[3]
        return load

    # A check on the rebuild itself: in tokens mode flow control releases only while the pool token ratio is below 1,
    # so a released request whose rebuilt ratio at release is 1 or more means the rebuild does not match the producer.
    recon_violations = None
    if mode == "tokens" and tokens:
        recon_violations = sum(
            1 for r in epp.values() if r.get("outcome") == "Dispatched" and "release" in r
            and sum(v[1] for v in load_at(r["release"]).values()) >= max_tok * len(pods))

    # Over-admission: each routed request is checked against its target's rebuilt load right after it is counted.
    # Over the detector limit means the pod ended up above the limit the filter enforces.
    # Fail-open does this whenever no pod fits, but fail-closed can too, when concurrent requests pass the filter on the
    # same pod before either is counted, so the fail-closed arms report a small nonzero count of their own.
    # Over the engine slots means the simulator queues it behind --max-num-seqs running requests.
    run_load = {p: [0, 0] for p in pods}
    over_limit = over_slots = 0
    peak_req = peak_tok = 0
    for t, pod, dn, dk in events:
        before_tok = run_load[pod][1]
        run_load[pod][0] += dn
        run_load[pod][1] += dk
        if dn > 0:
            n, k = run_load[pod]
            tok_over = before_tok > 0 and k > tok_limit
            if (mode == "tokens" and tok_over) or (mode == "hybrid" and (tok_over or n > req_limit)) \
                    or (mode == "requests" and n > req_limit):
                over_limit += 1
            if n > slots:
                over_slots += 1
            peak_req, peak_tok = max(peak_req, n), max(peak_tok, k)

    cases = []
    for rid in rtr:
        r = epp[rid]
        at_reject, at_release = load_at(r["eliminated"]), load_at(r["release"])
        inc = tokens.get(rid)
        slot_free = [p for p, (n, _) in at_reject.items() if n < slots]

        # The filter's own test (detector.go admits) applied to the rebuilt load, at release and at rejection.
        def fits(load):
            out = []
            for p, (n, k) in load.items():
                tok_ok = k < tok_limit and (k == 0 or (inc is not None and k + inc <= tok_limit))
                if mode == "tokens":
                    ok = tok_ok
                elif mode == "hybrid":
                    ok = n < req_limit and tok_ok
                else:
                    ok = n < req_limit
                if ok:
                    out.append(p)
            return out
        tok_under = [p for p, (_, k) in at_reject.items() if k < tok_limit]
        fit_release, fit_reject = fits(at_release), fits(at_reject)
        cases.append({
            "id": rid, "release_to_reject_ms": (r["eliminated"] - r["release"]) * 1e3,
            "queue_ms": (r["release"] - r["recv"]) * 1e3 if "recv" in r else None,
            "incoming_tokens": inc, "load_at_release": at_release, "load_at_reject": at_reject,
            "pool_req_ratio_at_release": sum(v[0] for v in at_release.values()) / (max_req * len(pods)),
            "pool_tok_ratio_at_release": sum(v[1] for v in at_release.values()) / (max_tok * len(pods)),
            "slot_free_pods": slot_free, "token_under_limit_pods": tok_under,
            "fit_pods_at_release": fit_release, "fit_pods_at_reject": fit_reject,
            "sim_scrape_at_filter": r.get("filter_in"),
        })

    ok = [c for c in client if c["status"] == 200 and not c.get("err")]
    t_first = min(c["sent_unix_ns"] for c in client) / 1e9
    t_last = max(c["done_unix_ns"] for c in client) / 1e9
    queue = [float(c["fc_queue_ms"]) for c in ok if c.get("fc_queue_ms")]
    m_before, m_after = opn(run / "metrics-before.txt").read(), opn(run / "metrics-after.txt").read()
    delta = lambda name, **kw: metric_sum(m_after, name, **kw) - metric_sum(m_before, name, **kw)
    return {
        "run": run.name, "mode": mode, "requests": len(client), "status": dict(status),
        "503_reasons": dict(reasons), "release_then_reject": len(rtr),
        "release_then_reject_with_client_503": rtr_client_503, "client_ids_missing_from_epp_log": missing_in_log,
        "client_200_without_route_lines": ok_without_route, "client_503_not_counted": rejected_without_lines,
        "metric_fc_dispatched": delta("llm_d_epp_flow_control_requests_total", outcome="Dispatched"),
        "metric_scheduler_failure": delta("llm_d_epp_scheduler_attempts_total", status="failure"),
        "metric_filter_eliminated_conc": delta("llm_d_epp_scheduler_filter_eliminated_total", plugin_name="conc"),
        "goodput_rps": len(ok) / (t_last - t_first),
        "goodput_output_tok_s": sum(c["max_tokens"] for c in ok) / (t_last - t_first),
        "ttft_ms_p50": pct([c["ttft_ms"] for c in ok], 50), "ttft_ms_p99": pct([c["ttft_ms"] for c in ok], 99),
        "fc_queue_ms_p50": pct(queue, 50), "fc_queue_ms_p99": pct(queue, 99),
        "rebuild_violations_tokens_mode": recon_violations,
        "fail_open": "failOpen: true" in cfg, "routed": sum(1 for e in events if e[2] > 0),
        "routed_over_detector_limit": over_limit, "routed_over_engine_slots": over_slots,
        "peak_pod_requests": peak_req, "peak_pod_tokens": peak_tok, "detector_req_limit": req_limit,
        "detector_tok_limit": tok_limit, "engine_slots": slots,
        "rtr_with_slot_free": sum(1 for c in cases if c["slot_free_pods"]),
        "rtr_fit_at_release_gone_at_reject": sum(1 for c in cases if c["fit_pods_at_release"] and not c["fit_pods_at_reject"]),
        "rtr_no_fit_even_at_release": sum(1 for c in cases if not c["fit_pods_at_release"]),
        "rtr_rebuild_says_fit_at_reject": sum(1 for c in cases if c["fit_pods_at_reject"]),
        "rtr_with_some_pod_under_token_limit": sum(1 for c in cases if c["token_under_limit_pods"]),
        "rtr_all_pods_at_token_limit": sum(1 for c in cases if not c["token_under_limit_pods"]),
        "rtr_pool_tok_ratio_at_release_max": max((c["pool_tok_ratio_at_release"] for c in cases), default=None),
        "rtr_release_to_reject_ms_p50": pct([c["release_to_reject_ms"] for c in cases], 50),
        "cases": cases,
    }


if __name__ == "__main__":
    for run in sys.argv[1:]:
        if (Path(run) / "epp.log").exists() and not (Path(run) / "epp-scored.log.gz").exists():
            slim(Path(run))
        o = analyze(run)
        cases = o.pop("cases")
        print(json.dumps(o))
        (Path(run) / "summary.json").write_text(json.dumps(o, indent=1) + "\n")
        with open(Path(run) / "rtr-cases.jsonl", "w") as f:
            for c in cases:
                f.write(json.dumps(c) + "\n")
