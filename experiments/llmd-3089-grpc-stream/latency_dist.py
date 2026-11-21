"""Prints the latency distribution of compare.sh stream rows per arm and concurrency.

Time to first message (TTFM) has one sample per call.
A tail percentile is printed only when the cell has enough calls for it to differ from the maximum:
p95 needs at least 20 calls and p99 at least 100; otherwise the cell shows "-" and the maximum stands in.
Inter-message gaps have 17 samples per call, so every gap percentile is printed.
Percentiles interpolate linearly between order statistics, as in summarize_cmp.py.
Calls in one run start together and share the node, so their tails move together; the run count is printed beside the call count.
Calls/s is concurrency over the run's wall time, which includes kubectl exec start-up and the backend's fixed 1.36 s stream, so it is a lower bound set by the stream length.
It exits non-zero when a stream lost a message or errored.
Usage: python3 latency_dist.py <dir>...
"""
import json
import sys
from collections import defaultdict

from summarize_cmp import EXPECTED, pct, rows


def tail(values, q, need):
    return f"{pct(values, q):.1f}" if len(values) >= need else "-"


def main(dirs):
    stream = [r for d in dirs for r in rows(f"{d}/stream.jsonl")]
    bad = [r for r in stream if r.get("err") or r["n"] != EXPECTED]
    cells = defaultdict(list)
    for r in stream:
        cells[(r["arm"], r["c"])].append(r)
    print("| arm | c | calls (runs) | TTFM ms p50 | p95 | p99 | max | total ms p50 | p99 or max | gaps | gap ms p50 | p95 | p99 | max |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for (arm, c), rs in sorted(cells.items(), key=lambda kv: (kv[0][0], kv[0][1])):
        ttfm = [r["ttfm_ms"] for r in rs]
        total = [r["total_ms"] for r in rs]
        gaps = [g for r in rs for g in r["gaps_ms"]]
        print(
            f"| {arm} | {c} | {len(rs)} ({len({r['run'] for r in rs})}) | {pct(ttfm, .5):.1f} | {tail(ttfm, .95, 20)} | {tail(ttfm, .99, 100)} | {max(ttfm):.1f} "
            f"| {pct(total, .5):.1f} | {pct(total, .99) if len(total) >= 100 else max(total):.1f} "
            f"| {len(gaps)} | {pct(gaps, .5):.2f} | {pct(gaps, .95):.2f} | {pct(gaps, .99):.2f} | {max(gaps):.2f} |"
        )
    runs = [r for d in dirs for r in rows(f"{d}/runs.jsonl")]
    if runs:
        walls = defaultdict(list)
        for r in runs:
            walls[(r["arm"], r["c"])].append(r)
        print("\n| arm | c | runs | wall s per run p50 | calls/s p50 | host load1 max |")
        print("|---|---:|---:|---:|---:|---:|")
        for (arm, c), rs in sorted(walls.items()):
            wall = [r["end"] - r["start"] for r in rs]
            print(f"| {arm} | {c} | {len(rs)} | {pct(wall, .5):.2f} | {c / pct(wall, .5):.1f} | {max(float(r['load1']) for r in rs):.1f} |")
    if bad:
        print(f"\nFAIL: {len(bad)} bad rows: {bad[:3]}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
