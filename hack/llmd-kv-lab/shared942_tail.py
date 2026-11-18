#!/usr/bin/env python3
"""Reads experiment A's run 2 archive for shared-942 and prints which requests set each arm's TTFT p99, where they
were routed, and how the p99 moves when the cold start is left out.

It exists for issue #599, which asks why PrefixAffinity's p99 rose in shared-942 while its hit ratio rose.
The answer has to come from the registered evidence, so this reads the archived raw.jsonl rows and nothing else, and
computes TTFT exactly as experiment A's scorer did: first token minus scheduled send, nearest rank, a failure +inf.
Leaving the first seconds out is an analysis after the result, not a registered rule, and the output says so.
"""
import json
import math
import os
import sys

ARMS = ("RoundRobin", "LeastQueue", "PrefixAffinity")


def ttft(r):
    if r.get("httpStatus") != 200 or not r.get("streamTerminated") or not r.get("firstTokenUnixNanos"):
        return math.inf
    return (r["firstTokenUnixNanos"] - (r["replayOriginUnixNanos"] + r["scheduledOffsetMs"] * 1_000_000)) / 1e6


def p99(values):
    s = sorted(values)
    return s[max(0, math.ceil(0.99 * len(s)) - 1)]


def main(cells):
    rows = {}
    for arm in ARMS:
        with open(os.path.join(cells, f"shared-942-{arm}", "raw.jsonl"), encoding="utf-8") as f:
            rows[arm] = {r["index"]: r for r in map(json.loads, f)}
    n = len(rows["RoundRobin"])
    rank = math.ceil(0.99 * n)
    print(f"shared-942, {n} requests; the p99 is the {rank}th of {n}, so the {n - rank + 1} slowest requests set it.\n")
    for arm in ARMS:
        worst = sorted(rows[arm].values(), key=ttft, reverse=True)[: n - rank + 1]
        print(f"{arm:15} p99 {p99([ttft(r) for r in rows[arm].values()]):7.1f} ms; slowest "
              + ", ".join(f"#{r['index']}@{r['scheduledOffsetMs'] / 1000:.1f}s {ttft(r):.0f}ms {r['routedBackend'][-1]} "
                          f"{r.get('routingReason', '')}" for r in worst))
    same = [i for i in range(n) if rows["LeastQueue"][i]["routedBackend"] == rows["PrefixAffinity"][i]["routedBackend"]]
    first_diff = next((i for i in range(n) if i not in same), None)
    print(f"\nLeastQueue and PrefixAffinity routed requests 0 to {first_diff - 1} identically "
          f"(PrefixAffinity's reasons there: "
          f"{sorted({rows['PrefixAffinity'][i]['routingReason'] for i in range(first_diff)})}); "
          f"first difference at #{first_diff}, scheduled {rows['RoundRobin'][first_diff]['scheduledOffsetMs'] / 1000:.1f} s.")
    print("\nAfter the result, not registered: p99 over the requests scheduled after the first S seconds.")
    print(f"{'S':>4} " + " ".join(f"{a:>15}" for a in ARMS))
    for cut in (0, 10, 15, 20, 30, 60):
        vals = [p99([ttft(r) for r in rows[a].values() if r["scheduledOffsetMs"] >= cut * 1000]) for a in ARMS]
        print(f"{cut:>4} " + " ".join(f"{v:15.1f}" for v in vals))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else
                  "hack/prefix-route/2026-10-28-run2/prefix-route-study/cells"))
