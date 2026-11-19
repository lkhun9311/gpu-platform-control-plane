#!/usr/bin/env python3
"""Score one or more #2881 runs: client statuses, release-then-reject from the EPP log, and the load at each rejection.

Events are kept per attempt, not per request id.
An attempt starts at each "Flow control outcome" line, so a request that flow control releases twice (a re-queue design)
has two attempts, each with its own filter result, routing and failure lines.
The 36 runs of 2026-11-19 have exactly one attempt per request; the per-attempt form exists so a re-queue arm can be
scored without later events overwriting earlier ones.

An attempt counts as release-then-reject when the EPP log shows, inside it:
  1. "Flow control outcome" with outcome "Dispatched" (admission.go: flow control released it), and
  2. "Filter eliminated all endpoints" with plugin "conc/concurrency-detector" (scheduler_profile.go).
A request counts as release-then-reject when one of its attempts does and its last attempt ends in
"Failed to process request" with "ServiceUnavailable - no endpoints available" (server.go).
The client side of the same request must be a 503 with x-llm-d-request-dropped-reason: rejected-no-endpoints.

The per-endpoint load at a rejection is rebuilt from the same log, the way the inflight-load producer counts it:
a routed attempt adds 1 request and prompt_tokens + max_tokens tokens to its target when its PreRequest hook completes,
and removes both at its endOfStream response chunk.
With addEstimatedOutputTokens and no prefill profile the producer releases nothing earlier (producer.go ResponseBody).
The output estimate is max_tokens because max_tokens never exceeds the 100-token floor of the UNKNOWN estimate.
These token counts are the detector's policy units: an estimate the operator's limit is written in.
They are not KV-cache occupancy, and not GPU work.
The log timestamps bracket the producer's counter updates to within microseconds, not exactly.

Client-side measures:
  - A request is a successful completion when its status is 200, the client saw no transport error, and, for records
    written by a loadgen that records stream completion, the stream ended with "data: [DONE]", carried no error event
    and no unparseable event.
    The 2026-11-19 records predate that field; for them the check falls back to status 200 and no client error, and
    the summary says which rule applied.
  - Successful completion throughput is successful completions over first send to last completion.
    It is not SLO goodput: no latency target is applied.
  - Generated tokens are the server's usage.completion_tokens, summed over successful completions.
    Records without the usage field report None rather than the requested max_tokens.
  - TTFT is measured to the first stream event carrying generated text in records that have content_chunks, and to
    the first "data:" line in older records; ttft_definition names which.
    TTFT and FC queue percentiles are over successful completions only, so an arm that rejects requests drops their
    latency from these percentiles; e2e_ms over every request is reported beside them.
  - Percentiles are nearest-rank: the value at 1-based rank ceil(p/100 * n) of the sorted sample.
"""
import bisect
import collections
import gzip
import json
import math
import re
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
    """Nearest-rank percentile: the smallest sample value with at least p percent of the sample at or below it."""
    if not xs:
        return None
    xs = sorted(xs)
    rank = max(1, math.ceil(p / 100 * len(xs)))
    return xs[rank - 1]


def metric_sum(text, name, **labels):
    total = 0.0
    for line in text.splitlines():
        if not line.startswith(name + "{") and not line.startswith(name + " "):
            continue
        if all(f'{k}="{v}"' in line for k, v in labels.items()):
            total += float(line.rsplit(" ", 1)[1])
    return total


# The log lines the scoring reads; slim() keeps only these, so a committed run can be re-scored without the full log.
# "Request re-queued after saturation" is logged only by the local re-queue prototypes; main never emits it.
SCORED_BODIES = (
    "EPP received request", "Flow control outcome", "Before running filter plugins", "Filter eliminated all endpoints",
    "Completed running picker plugin successfully", "Completed running PreRequest plugin successfully",
    "HandleResponseBody is triggered", "Failed to process request", "Request re-queued after saturation")
ATTEMPT_BODIES = frozenset(SCORED_BODIES) - {"EPP received request", "Flow control outcome"}


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


def new_attempt(release=None, outcome=None):
    return {"release": release, "outcome": outcome, "filter_in": [], "eliminated": [], "pod": None, "prereq": None,
            "eos": None, "fail": None, "error": "", "requeued": None}


def parse_epp(run, prefix):
    """Return {request id: {"recv": [times], "attempts": [attempt, ...]}} in log order."""
    reqs = collections.defaultdict(lambda: {"recv": [], "attempts": []})
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
                r["recv"].append(t)
                continue
            if body == "Flow control outcome":
                r["attempts"].append(new_attempt(t, d.get("outcome")))
                continue
            # Only the attempt-level lines below belong to an attempt.
            # Other lines, such as the full log's "LLM request assembled" before admission, must not open one.
            if body not in ATTEMPT_BODIES:
                continue
            # Without flow control there is no release line, so the first routing line opens the only attempt.
            if not r["attempts"]:
                r["attempts"].append(new_attempt())
            a = r["attempts"][-1]
            if body == "Before running filter plugins":
                a["filter_in"].append([
                    {"pod": e["Name"], "running": e.get("RunningRequestsSize"), "waiting": e.get("WaitingQueueSize"),
                     "scraped": e.get("UpdateTime")} for e in d.get("endpoints") or []])
            elif body == "Filter eliminated all endpoints":
                a["eliminated"].append((t, d.get("plugin")))
            elif body == "Completed running picker plugin successfully":
                eps = (d.get("result") or {}).get("TargetEndpoints") or []
                if eps:
                    a["pod"] = eps[0]["Endpoint"]["Name"]
            elif body == "Completed running PreRequest plugin successfully" and "inflight-load" in d.get("plugin", ""):
                a["prereq"] = t
            elif body == "HandleResponseBody is triggered" and d.get("endOfStream"):
                a["eos"] = t
            elif body == "Failed to process request":
                a["fail"], a["error"] = t, d.get("error", "")
            elif body == "Request re-queued after saturation":
                a["requeued"] = t
    return reqs


def conc_rejection(a):
    """The time the concurrency detector emptied this attempt's endpoint set, or None."""
    return next((t for t, plugin in a["eliminated"] if plugin == "conc/concurrency-detector"), None)


def is_rtr_attempt(a):
    return a["outcome"] == "Dispatched" and conc_rejection(a) is not None


def stream_ok(c):
    """A 200 whose stream completed; records without the completion fields can only be held to status and error."""
    if c["status"] != 200 or c.get("err"):
        return False
    if "done" not in c:
        return True
    return c["done"] and not c.get("stream_error") and not c.get("bad_events")


def analyze(run):
    run = Path(run)
    cfg = (run / "epp-config.yaml").read_text()
    mode, max_req, max_tok, headroom = limits(cfg)
    req_limit, tok_limit = int(max_req * (1 + headroom)), int(max_tok * (1 + headroom))
    # Engine slots are the simulator's --max-num-seqs, whatever the detector's mode.
    slots = int(re.search(r"--max-num-seqs=(\d+)", (run / "pins.txt").read_text()).group(1))
    client = [json.loads(l) for l in opn(run / "requests.jsonl")]
    ids = collections.Counter(c["id"] for c in client)
    if any(n > 1 for n in ids.values()):
        raise SystemExit(f"{run}: client ids repeat, so their EPP lines cannot be told apart")
    prefix = client[0]["id"].rsplit("-", 1)[0] + "-"
    tokens = {}
    if (run / "tokens.jsonl").exists() or (run / "tokens.jsonl.gz").exists():
        for l in opn(run / "tokens.jsonl"):
            t = json.loads(l)
            tokens[t["id"]] = t["prompt_tokens"] + t["max_tokens"]
    epp = parse_epp(run, prefix)
    # Two receive lines under one id would merge two requests' attempts; refuse rather than score a merged history.
    repeated_recv = [rid for rid, r in epp.items() if len(r["recv"]) > 1]
    if repeated_recv:
        raise SystemExit(f"{run}: {len(repeated_recv)} ids received more than once, e.g. {repeated_recv[0]}")

    status = collections.Counter()
    for c in client:
        if c.get("err") and not c.get("status"):
            status["client-error"] += 1
        elif c["status"] in (200, 429, 503):
            status[str(c["status"])] += 1
        else:
            status["other"] += 1
    reasons = collections.Counter(c.get("dropped_reason", "") for c in client if c["status"] == 503)

    # Attempt-level: every release the concurrency filter then emptied, whatever happened to the request afterwards.
    rtr_attempts = [(rid, i) for rid, r in epp.items() for i, a in enumerate(r["attempts"]) if is_rtr_attempt(a)]
    # Request-level: the request left as a no-endpoints failure after such an attempt.
    rtr = sorted(
        rid for rid, r in epp.items()
        if r["attempts"] and any(is_rtr_attempt(a) for a in r["attempts"])
        and "no endpoints available" in r["attempts"][-1]["error"])
    rtr_set = set(rtr)
    by_id = {c["id"]: c for c in client}
    rtr_client_503 = sum(1 for rid in rtr if by_id.get(rid, {}).get("status") == 503
                         and by_id[rid].get("dropped_reason") == "rejected-no-endpoints")
    missing_in_log = sum(1 for c in client if c["id"] not in epp or not any(
        a["outcome"] for a in epp[c["id"]]["attempts"]))
    # Lost downstream lines would undercount rejections or misplace load, so each client outcome is held to its lines.
    ok_without_route = sum(1 for c in client if c["status"] == 200 and not (
        epp.get(c["id"], {}).get("attempts") and all(
            epp[c["id"]]["attempts"][-1][k] is not None for k in ("prereq", "pod", "eos"))))
    rejected_without_lines = sum(1 for c in client if c["status"] == 503 and c["id"] not in rtr_set)
    attempts_per_request = collections.Counter(len(r["attempts"]) for r in epp.values())

    # Event stream of routed attempts: (time, pod, d_requests, d_tokens).
    events = []
    for rid, r in epp.items():
        for a in r["attempts"]:
            if a["prereq"] is not None and a["pod"]:
                cost = tokens.get(rid, 0)
                events.append((a["prereq"], a["pod"], 1, cost))
                if a["eos"] is not None:
                    events.append((a["eos"], a["pod"], -1, -cost))
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
    # so a released attempt whose rebuilt ratio at release is 1 or more means the rebuild does not match the producer.
    recon_violations = None
    if mode == "tokens" and tokens:
        recon_violations = sum(
            1 for r in epp.values() for a in r["attempts"] if a["outcome"] == "Dispatched" and a["release"] is not None
            and sum(v[1] for v in load_at(a["release"]).values()) >= max_tok * len(pods))

    # Over-admission: each routed attempt is checked against its target's rebuilt load right after it is counted.
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
    for rid, i in sorted(rtr_attempts):
        r, a = epp[rid], epp[rid]["attempts"][i]
        rejected_at = conc_rejection(a)
        at_reject, at_release = load_at(rejected_at), load_at(a["release"])
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
            "id": rid, "attempt": i, "final_attempt": i == len(r["attempts"]) - 1, "in_request_rtr": rid in rtr_set,
            "release_to_reject_ms": (rejected_at - a["release"]) * 1e3,
            "queue_ms": (a["release"] - r["recv"][0]) * 1e3 if r["recv"] else None,
            "incoming_tokens": inc, "load_at_release": at_release, "load_at_reject": at_reject,
            # Pods are known only from routed attempts; a run that routed nothing has no pool to divide by.
            "pool_req_ratio_at_release": sum(v[0] for v in at_release.values()) / (max_req * len(pods)) if pods else None,
            "pool_tok_ratio_at_release": sum(v[1] for v in at_release.values()) / (max_tok * len(pods)) if pods else None,
            "slot_free_pods": slot_free, "token_under_limit_pods": tok_under,
            "fit_pods_at_release": fit_release, "fit_pods_at_reject": fit_reject,
            "sim_scrape_at_filter": a["filter_in"][-1] if a["filter_in"] else None,
        })
    # The request-level fit columns describe each counted request's last attempt the concurrency filter emptied.
    # That need not be its final attempt: a later attempt can fail for another reason after a re-queue.
    last_rtr = {}
    for c in cases:
        if c["in_request_rtr"]:
            last_rtr[c["id"]] = c
    req_cases = list(last_rtr.values())

    completion_recorded = any("done" in c for c in client)
    ok = [c for c in client if stream_ok(c)]
    t_first = min(c["sent_unix_ns"] for c in client) / 1e9
    t_last = max(c["done_unix_ns"] for c in client) / 1e9
    span = t_last - t_first
    queue = [float(c["fc_queue_ms"]) for c in ok if c.get("fc_queue_ms")]
    ttfts = [c["ttft_ms"] for c in ok if c.get("ttft_ms") is not None]
    usage_recorded = bool(ok) and all(c.get("usage_completion_tokens") is not None for c in ok)
    ttft_def = ("first stream event carrying generated text" if any("content_chunks" in c for c in client)
                else "first SSE data: line, whatever it carried (records predate content_chunks)")
    framing = collections.Counter(c.get("chunks", 0) - c["max_tokens"] for c in ok)
    m_before, m_after = opn(run / "metrics-before.txt").read(), opn(run / "metrics-after.txt").read()
    delta = lambda name, **kw: metric_sum(m_after, name, **kw) - metric_sum(m_before, name, **kw)
    return {
        "run": run.name, "mode": mode, "requests": len(client), "status": dict(status),
        "503_reasons": dict(reasons), "release_then_reject": len(rtr),
        "release_then_reject_attempts": len(rtr_attempts),
        "attempts_per_request": {str(k): v for k, v in sorted(attempts_per_request.items())},
        "requeued_attempts": sum(1 for r in epp.values() for a in r["attempts"] if a["requeued"] is not None),
        "release_then_reject_with_client_503": rtr_client_503, "client_ids_missing_from_epp_log": missing_in_log,
        "client_200_without_route_lines": ok_without_route, "client_503_not_counted": rejected_without_lines,
        "metric_fc_dispatched": delta("llm_d_epp_flow_control_requests_total", outcome="Dispatched"),
        "metric_scheduler_failure": delta("llm_d_epp_scheduler_attempts_total", status="failure"),
        "metric_filter_eliminated_conc": delta("llm_d_epp_scheduler_filter_eliminated_total", plugin_name="conc"),
        "success_rule": ("status 200, no client error, [DONE] seen, no error or unparseable event" if completion_recorded
                         else "status 200 and no client error (records predate stream-completion fields)"),
        "successful_completions": len(ok),
        "successful_completion_rps": len(ok) / span,
        "generated_tok_s": sum(c["usage_completion_tokens"] for c in ok) / span if usage_recorded else None,
        "requested_max_tokens_of_successes_per_s": sum(c["max_tokens"] for c in ok) / span,
        "chunks_minus_max_tokens_on_successes": {str(k): v for k, v in sorted(framing.items())},
        "ttft_definition": ttft_def,
        # A stream that completed without any generated text has no TTFT; it is counted here, not dropped silently.
        "successes_without_text": sum(1 for c in ok if c.get("ttft_ms") is None),
        "ttft_ms_p50": pct(ttfts, 50), "ttft_ms_p99": pct(ttfts, 99),
        "e2e_ms_all_requests_p50": pct([c["e2e_ms"] for c in client], 50),
        "e2e_ms_all_requests_p99": pct([c["e2e_ms"] for c in client], 99),
        "fc_queue_ms_p50": pct(queue, 50), "fc_queue_ms_p99": pct(queue, 99),
        "percentile_method": "nearest-rank",
        "rebuild_violations_tokens_mode": recon_violations,
        "fail_open": "failOpen: true" in cfg, "routed": sum(1 for e in events if e[2] > 0),
        "routed_over_detector_limit": over_limit, "routed_over_engine_slots": over_slots,
        "peak_pod_requests": peak_req, "peak_pod_tokens": peak_tok, "detector_req_limit": req_limit,
        "detector_tok_limit": tok_limit, "engine_slots": slots,
        "rtr_with_slot_free": sum(1 for c in req_cases if c["slot_free_pods"]),
        "rtr_fit_at_release_gone_at_reject": sum(1 for c in req_cases if c["fit_pods_at_release"] and not c["fit_pods_at_reject"]),
        "rtr_no_fit_even_at_release": sum(1 for c in req_cases if not c["fit_pods_at_release"]),
        "rtr_rebuild_says_fit_at_reject": sum(1 for c in req_cases if c["fit_pods_at_reject"]),
        "rtr_with_some_pod_under_token_limit": sum(1 for c in req_cases if c["token_under_limit_pods"]),
        "rtr_all_pods_at_token_limit": sum(1 for c in req_cases if not c["token_under_limit_pods"]),
        "rtr_pool_tok_ratio_at_release_max": max((c["pool_tok_ratio_at_release"] for c in req_cases
                                                  if c["pool_tok_ratio_at_release"] is not None), default=None),
        "rtr_release_to_reject_ms_p50": pct([c["release_to_reject_ms"] for c in req_cases], 50),
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
