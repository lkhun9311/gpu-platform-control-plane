#!/usr/bin/env python3
"""Print the timeline of one released-then-rejected request: client send, EPP receipt, flow-control release, the
routing of other requests in between, the filter's rejection with the rebuilt per-pod load, and the client's 503.

Usage: trace.py RUN_DIR [REQUEST_ID]; without an id it takes the first case whose fitting pod disappeared between
release and rejection, else the first case.
"""
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import analyze  # noqa: E402


def hms(t):
    return datetime.fromtimestamp(t, timezone.utc).strftime("%H:%M:%S.%f")


def main():
    run = Path(sys.argv[1])
    cases = [json.loads(l) for l in analyze.opn(run / "rtr-cases.jsonl")]
    if len(sys.argv) > 2:
        case = next(c for c in cases if c["id"] == sys.argv[2])
    else:
        case = next((c for c in cases if c["fit_pods_at_release"]), cases[0])
    client = {json.loads(l)["id"]: json.loads(l) for l in analyze.opn(run / "requests.jsonl")}
    prefix = case["id"].rsplit("-", 1)[0] + "-"
    epp = analyze.parse_epp(run, prefix)
    tokens = {}
    for l in analyze.opn(run / "tokens.jsonl"):
        t = json.loads(l)
        tokens[t["id"]] = t["prompt_tokens"] + t["max_tokens"]
    # The rejected attempt is the one the case names; the 2026-11-19 runs have one attempt per request.
    req, c = epp[case["id"]], client[case["id"]]
    r = req["attempts"][case["attempt"]]
    eliminated = analyze.conc_rejection(r)
    rows = [(c["sent_unix_ns"] / 1e9, f"client sends {case['id']} (incoming tokens {case['incoming_tokens']})"),
            (req["recv"][0], "EPP receives it"),
            (r["release"], f"flow control releases it: outcome={r['outcome']}; rebuilt load per pod (requests, tokens) "
                           f"{case['load_at_release']}; pool token ratio {case['pool_tok_ratio_at_release']:.3f}, "
                           f"pool request ratio {case['pool_req_ratio_at_release']:.3f}; pods that fit it {case['fit_pods_at_release']}"),
            (eliminated, f"filter conc/concurrency-detector eliminates all endpoints; rebuilt load {case['load_at_reject']}; "
                              f"pods that fit it {case['fit_pods_at_reject']}; engine slot free on {case['slot_free_pods']}"),
            (c["done_unix_ns"] / 1e9, f"client receives {c['status']} {c.get('dropped_reason', '')}")]
    # A re-queued attempt has no failure line, and None cannot be sorted against timestamps.
    if r["fail"] is not None:
        rows.append((r["fail"], f"EPP fails it: {r['error']}"))
    if r["requeued"] is not None:
        rows.append((r["requeued"], "EPP re-queues it"))
    for rid, other in epp.items():
        if rid == case["id"]:
            continue
        for o in other["attempts"]:
            for key, what in (("release", "released"), ("prereq", "PreRequest counted on"), ("eos", "endOfStream on")):
                t = o.get(key)
                if t is None or not r["release"] - 0.05 <= t <= eliminated:
                    continue
                pod = o.get("pod") or ""
                extra = f" {pod} (+1 request, +{tokens.get(rid)} tokens)" if key == "prereq" else (f" {pod}" if key == "eos" else "")
                rows.append((t, f"  other request {rid} {what}{extra}"))
    rows.sort()
    for t, what in rows:
        print(f"{hms(t)}  {what}")
    print("simulator scrape seen by the filter:", json.dumps(case["sim_scrape_at_filter"]))


if __name__ == "__main__":
    main()
