"""Gateway processing latency on kind: the same stub stages replayed through the gateway and straight at the stub.

    latency.py RECORD_DIR

RECORD_DIR holds one stage directory per arm and rate, named gw-<rate> and direct-<rate>, each as `capacityrun stage` wrote it.
For each rate it prints TTFT and E2E p99 first, then p90 and p50, with n, for both arms, and the gateway arm minus the direct arm.
The difference is between two quantiles of two populations with identical arrivals, not a per-request overhead.
The stub reports no usage, so a completed request here is HTTP 200 with [DONE]; the token contract is the GPU kit's, not this one's.
"""

import json
import math
import os
import sys

MIN_P99 = 100


def quantile(v, q):
    v = sorted(v)
    return v[max(math.ceil(q * len(v)) - 1, 0)] if v else None


def summarize(stage):
    with open(os.path.join(stage, "meta.json")) as f:
        meta = json.load(f)
    if meta.get("reconciled") is not True:
        raise SystemExit(f"{stage}: the recording did not reconcile: {meta.get('unreconciled')}")
    rows = [json.loads(line) for line in open(os.path.join(stage, "raw.jsonl")) if line.strip()]
    sent = [r for r in rows if r.get("disposition") != "unsent"]
    done = [r for r in sent if r.get("disposition") == "completed" and r.get("httpStatus") == 200 and r.get("streamTerminated")]
    out = {"planned": len(rows), "sent": len(sent), "completed": len(done), "rate_rps": meta["segments"][0]["rateRps"]}
    for name, field in (("ttft", "firstContentNanos"), ("e2e", "doneNanos")):
        vals = [(r["clock"][field] - r["clock"]["sendNanos"]) / 1e6 for r in done]
        n = len(vals)
        out[name] = {"n": n, "p99": quantile(vals, 0.99) if n >= MIN_P99 else None, "p90": quantile(vals, 0.9), "p50": quantile(vals, 0.5)}
    return out


def fmt(q):
    p99 = f"{q['p99']:.2f}" if q["p99"] is not None else f"insufficient (n={q['n']})"
    return f"p99 {p99} ms, p90 {q['p90']:.2f} ms, p50 {q['p50']:.2f} ms, n={q['n']}"


def main(record):
    rates = sorted({d.split("-", 1)[1] for d in os.listdir(record) if d.startswith(("gw-", "direct-"))}, key=float)
    result, lines = {}, []
    for rate in rates:
        gw, direct = summarize(os.path.join(record, f"gw-{rate}")), summarize(os.path.join(record, f"direct-{rate}"))
        diff = {}
        for m in ("ttft", "e2e"):
            diff[m] = {q: (gw[m][q] - direct[m][q]) if gw[m][q] is not None and direct[m][q] is not None else None for q in ("p99", "p90", "p50")}
        result[rate] = {"gateway": gw, "direct": direct, "gateway_minus_direct_ms": diff}
        lines.append(f"{rate} req/s: gateway completed {gw['completed']} of {gw['sent']} sent, direct {direct['completed']} of {direct['sent']}")
        for m in ("ttft", "e2e"):
            lines.append(f"  {m.upper()} gateway: {fmt(gw[m])}")
            lines.append(f"  {m.upper()} direct:  {fmt(direct[m])}")
            d = diff[m]
            p99 = f"{d['p99']:.2f}" if d["p99"] is not None else "not reported"
            lines.append(f"  {m.upper()} gateway minus direct: p99 {p99} ms, p90 {d['p90']:.2f} ms, p50 {d['p50']:.2f} ms")
    with open(os.path.join(record, "latency.json"), "w") as f:
        json.dump(result, f, indent=2)
    with open(os.path.join(record, "latency.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main(sys.argv[1])
