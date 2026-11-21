"""Summarizes fault.sh output.

It prints the normal consumer's latency per phase, what each fault did to its own calls, and the EPP state after each phase.
It exits non-zero when a normal-consumer call lost a message or errored, when a call ran into the client's 60 s deadline (a hang),
or when, after a phase settled, the EPP still had requests without an outcome.
Usage: python3 fault_summary.py <dir>
"""
import json
import sys
from collections import Counter, defaultdict

from summarize_cmp import EXPECTED, pct, rows

NORMAL = ("alone", "beside-slow", "recovered")
HANG_MS = 59_000


def tail(values, q, need):
    return f"{pct(values, q):.1f}" if len(values) >= need else "-"


def main(d):
    stream = rows(f"{d}/stream.jsonl")
    epp = rows(f"{d}/epp.jsonl")
    bad = []
    by = defaultdict(list)
    for r in stream:
        by[(r["arm"], r["phase"])].append(r)
        if r.get("total_ms", 0) >= HANG_MS:
            bad.append({"hang": r["arm"], "phase": r["phase"]})
        if r["phase"] in NORMAL and (r.get("err") or r["n"] != EXPECTED):
            bad.append({"normal consumer": r["arm"], "phase": r["phase"], "n": r["n"], "err": r.get("err")})
    arms = sorted({r["arm"] for r in stream})

    print("### Normal consumer (4 concurrent calls per run, 18 messages 80 ms apart)\n")
    print("| arm | phase | calls | TTFM ms p50 | p95 | p99 | max | gaps | gap ms p50 | p95 | p99 | max |")
    print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for arm in arms:
        for phase in NORMAL:
            rs = by.get((arm, phase), [])
            if not rs:
                continue
            t = [r["ttfm_ms"] for r in rs]
            g = [x for r in rs for x in r["gaps_ms"]]
            print(
                f"| {arm} | {phase} | {len(rs)} | {pct(t, .5):.1f} | {tail(t, .95, 20)} | {tail(t, .99, 100)} | {max(t):.1f} "
                f"| {len(g)} | {pct(g, .5):.2f} | {pct(g, .95):.2f} | {pct(g, .99):.2f} | {max(g):.2f} |"
            )

    print("\n### Faulted calls\n")
    print("| arm | phase | calls | messages received (count: calls) | errors (code: calls) | total ms max |")
    print("|---|---|---:|---|---|---:|")
    for arm in arms:
        for phase in ("slow-consumer", "disconnect", "kill"):
            rs = by.get((arm, phase), [])
            if not rs:
                continue
            msgs = Counter(r["n"] for r in rs)
            errs = Counter((r.get("err") or "none").split(" desc")[0] for r in rs)
            print(
                f"| {arm} | {phase} | {len(rs)} | {', '.join(f'{k}: {v}' for k, v in sorted(msgs.items()))} "
                f"| {'; '.join(f'{k}: {v}' for k, v in sorted(errs.items()))} | {max(r['total_ms'] for r in rs):.0f} |"
            )

    print("\n### EPP after each phase settled\n")
    print("| arm | phase | goroutines | heap in use MiB | VmRSS MiB | requests | outcomes | in flight | completed response records |")
    print("|---|---|---:|---:|---:|---:|---|---:|---:|")
    for r in epp:
        outcomes = ", ".join(f"{k.rstrip('/')}: {int(v)}" for k, v in sorted(r["outcomes"].items()))
        print(
            f"| {r['arm']} | {r['phase']} | {int(r['goroutines'])} | {r.get('heap_inuse_bytes', float('nan')) / 2**20:.1f} | {r['rss_kb'] / 1024:.1f} | {int(r['requests'])} "
            f"| {outcomes} | {int(r['in_flight'])} | {int(r['response_size_count'])} |"
        )
        if not r["phase"].startswith("slow-") and r["in_flight"] != 0:
            bad.append({"in flight after settle": r["arm"], "phase": r["phase"], "n": r["in_flight"]})

    if bad:
        print(f"\nFAIL: {len(bad)} findings: {bad[:5]}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1])
