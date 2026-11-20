"""Summarizes compare.sh output directories.

It exits non-zero when a stream lost a message or errored, when a unary digest differs from the direct call, or when a JSON request failed.
Usage: python3 summarize_cmp.py <dir>...
"""
import json
import statistics
import sys
from collections import defaultdict

EXPECTED = 18


def rows(path):
    try:
        with open(path) as f:
            return [json.loads(line) for line in f if line.strip()]
    except FileNotFoundError:
        return []


def pct(values, q):
    values = sorted(values)
    if not values:
        return float("nan")
    k = (len(values) - 1) * q
    lo = int(k)
    hi = min(lo + 1, len(values) - 1)
    return values[lo] + (values[hi] - values[lo]) * (k - lo)


def main(dirs):
    bad = []
    stream, unary, epp, js = [], [], [], []
    for d in dirs:
        stream += rows(f"{d}/stream.jsonl")
        unary += rows(f"{d}/unary.jsonl")
        epp += rows(f"{d}/epp.jsonl")
        js += rows(f"{d}/json.jsonl")

    cells = defaultdict(list)
    for r in stream:
        if r.get("err") or r["n"] != EXPECTED:
            bad.append(r)
        cells[(r["arm"], r["c"])].append(r)
    print("### Server-streaming gRPC, 18 messages 80 ms apart\n")
    print("| arm | c | calls (runs) | TTFM ms p50 | TTFM ms p95 | gap ms p50 | gap ms p95 | messages before backend done (mean) | lag of msg 1 ms p50 |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for (arm, c), rs in sorted(cells.items()):
        ttfm = [r["ttfm_ms"] for r in rs]
        gaps = [g for r in rs for g in r["gaps_ms"]]
        lag1 = [r["lag_ms"][0] for r in rs if r["lag_ms"]]
        before = [r["before_done"] for r in rs]
        runs = len({r["run"] for r in rs})
        print(
            f"| {arm} | {c} | {len(rs)} ({runs}) | {pct(ttfm, .5):.1f} | {pct(ttfm, .95):.1f} "
            f"| {pct(gaps, .5):.2f} | {pct(gaps, .95):.2f} | {statistics.mean(before):.3f} | {pct(lag1, .5):.1f} |"
        )

    if unary:
        print("\n### Unary gRPC: response message, header and trailer digests\n")
        print("| arm | calls | message bytes | message sha256 | header equals trailer | same as direct |")
        print("|---|---:|---:|---|---|---|")
        ref = {(r["message_sha256"], r["x_backend_header"], r["x_backend_trailer"]) for r in unary if r["arm"].endswith("/direct")}
        by_arm = defaultdict(list)
        for r in unary:
            by_arm[r["arm"]].append(r)
        for arm, rs in sorted(by_arm.items()):
            keys = {(r["message_sha256"], r["x_backend_header"], r["x_backend_trailer"]) for r in rs}
            errs = [r for r in rs if r.get("err")]
            same = bool(ref) and keys == ref and not errs
            if ref and not same:
                bad.append({"arm": arm, "unary": sorted(keys), "errs": errs})
            consistent = all(r["x_backend_header"] == r["x_backend_trailer"] != "" for r in rs)
            print(f"| {arm} | {len(rs)} | {rs[0].get('message_bytes')} | {rs[0].get('message_sha256', '')[:16]}... | {consistent} | {same if ref else 'no direct rows'} |")

    # Each compare.sh pass writes a before and an after sample per phase, in order, so passes are paired by position.
    samples = defaultdict(list)
    for r in epp:
        samples[(r["arm"], r["phase"].split("-")[0])].append(r)
    calls = defaultdict(int)
    for r in stream:
        calls[r["arm"]] += 1
    jpasses = defaultdict(list)
    for r in js:
        if r.get("bad"):
            bad.append(r)
        passes = jpasses[r["arm"]]
        if not passes or len(passes[-1]) == r["c"]:
            passes.append([])
        passes[-1].append(r)
    per_arm = defaultdict(list)
    if samples:
        print("\n### EPP process CPU and memory\n")
        print("| arm | phase | pass | requests | CPU s | CPU ms per request | VmRSS MiB after | VmHWM MiB after | latency ms p50 | latency ms p95 |")
        print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|")
        for (arm, name), rs in sorted(samples.items()):
            for k in range(0, len(rs), 2):
                b, a = rs[k], rs[k + 1] if k + 1 < len(rs) else None
                if not a or b["phase"] != f"{name}-before" or a["phase"] != f"{name}-after":
                    bad.append({"arm": arm, "phase": name, "err": "unpaired EPP samples"})
                    continue
                if a["pid"] != b["pid"]:
                    bad.append({"arm": arm, "phase": name, "err": "EPP restarted during the phase"})
                cpu = (a["cpu_ticks"] - b["cpu_ticks"]) / a["clk_tck"]
                lat = ("", "")
                if name == "stream":
                    n = calls[arm]
                else:
                    lats = [x for r in jpasses[arm][k // 2] for x in r["latency_ms"]]
                    n = len(lats)
                    lat = (f"{pct(lats, .5):.1f}", f"{pct(lats, .95):.1f}")
                if name == "json":
                    per_arm[arm].append((1000 * cpu / n, a["rss_kb"] / 1024, float(lat[0])))
                print(
                    f"| {arm} | {name} | {k // 2 + 1} | {n} | {cpu:.2f} | {1000 * cpu / n:.3f} "
                    f"| {a['rss_kb'] / 1024:.1f} | {a['hwm_kb'] / 1024:.1f} | {lat[0]} | {lat[1]} |"
                )

    if per_arm:
        print("\n### JSON control across passes\n")
        print("| arm | passes | CPU ms per request, median (min-max) | VmRSS MiB after, median (min-max) | latency ms p50, median |")
        print("|---|---:|---|---|---:|")
        for arm, vals in sorted(per_arm.items()):
            cpu = [v[0] for v in vals]
            rss = [v[1] for v in vals]
            p50 = [v[2] for v in vals]
            print(
                f"| {arm} | {len(vals)} | {statistics.median(cpu):.3f} ({min(cpu):.3f}-{max(cpu):.3f}) "
                f"| {statistics.median(rss):.1f} ({min(rss):.1f}-{max(rss):.1f}) | {statistics.median(p50):.1f} |"
            )

    if bad:
        print(f"\nFAIL: {len(bad)} bad rows: {bad[:3]}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
