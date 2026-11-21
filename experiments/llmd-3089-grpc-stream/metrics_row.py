"""Turns an EPP /metrics scrape on stdin into one JSON row for fault.sh.

Series are summed over their labels, except outcomes, which are kept per outcome and reason.
in_flight is requests minus recorded outcomes: every routed request records exactly one outcome when it ends.
Rejected outcomes are left out of it, because a request rejected before routing (for example with no ready endpoint) is never counted in requests.
The EPP's running-requests gauge is not used because it only counts requests with a model name, and passthrough sets none.
Usage: python3 metrics_row.py <arm> <phase> <VmRSS kB>
"""
import json
import re
import sys
from collections import defaultdict

WANTED = {
    "go_goroutines": "goroutines",
    "llm_d_epp_request_total": "requests",
    "llm_d_epp_response_size_bytes_count": "response_size_count",
    "llm_d_epp_request_error_total": "errors",
    "go_memstats_heap_inuse_bytes": "heap_inuse_bytes",
}


def main(arm, phase, rss_kb):
    row = {"arm": arm, "phase": phase, "rss_kb": int(rss_kb)}
    outcomes = defaultdict(float)
    sums = defaultdict(float)
    for line in sys.stdin:
        if line.startswith("#") or not line.strip():
            continue
        m = re.match(r"([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?\s+(\S+)", line)
        if not m:
            continue
        name, labels, value = m.group(1), m.group(2) or "", float(m.group(3))
        if name in WANTED:
            sums[WANTED[name]] += value
        elif name == "llm_d_epp_request_outcome_total":
            outcome = re.search(r'outcome="([^"]*)"', labels)
            reason = re.search(r'reason="([^"]*)"', labels)
            outcomes[f"{outcome.group(1) if outcome else ''}/{reason.group(1) if reason else ''}"] += value
    missing = [v for v in WANTED.values() if v not in sums and v not in ("errors",)]
    if missing:
        sys.exit(f"metrics_row: series missing from the scrape: {missing}")
    row.update(sums)
    row["outcomes"] = dict(outcomes)
    row["in_flight"] = row["requests"] - sum(v for k, v in outcomes.items() if not k.startswith("rejected/"))
    print(json.dumps(row))


if __name__ == "__main__":
    main(*sys.argv[1:])
