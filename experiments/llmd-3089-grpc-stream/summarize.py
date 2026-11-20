"""Summarizes measure.sh output per arm.

Every row must have received all n messages without error, or the script exits non-zero.
"""
import json
import statistics
import sys
from collections import defaultdict

EXPECTED = 18


def main(path):
    rows = defaultdict(list)
    bad = []
    with open(path) as f:
        for line in f:
            r = json.loads(line)
            if r.get("err") or r["n"] != EXPECTED:
                bad.append(r)
            rows[r["arm"]].append(r)
    if bad:
        print(f"FAIL: {len(bad)} incomplete rows: {bad[:2]}", file=sys.stderr)
        sys.exit(1)
    print("| arm | runs | TTFM ms (median, min-max) | gap ms (median of all gaps) | gap ms max | total ms (median) | lag of msg 1 ms (median) |")
    print("|---|---:|---|---:|---:|---:|---:|")
    for arm, rs in rows.items():
        ttfm = [r["ttfm_ms"] for r in rs]
        gaps = [g for r in rs for g in r["gaps_ms"]]
        total = [r["total_ms"] for r in rs]
        lag1 = [r["lag_ms"][0] for r in rs]
        print(
            f"| {arm} | {len(rs)} | {statistics.median(ttfm):.1f} ({min(ttfm):.1f}-{max(ttfm):.1f}) "
            f"| {statistics.median(gaps):.2f} | {max(gaps):.2f} | {statistics.median(total):.1f} "
            f"| {statistics.median(lag1):.1f} |"
        )


if __name__ == "__main__":
    main(sys.argv[1])
