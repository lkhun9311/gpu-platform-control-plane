"""Split each cell's TTFT into what the engine saw and what happened outside it.

Run: python3 hack/tail-crossing-model/decompose.py <archive>/m5c-run

For every cell with an engine-metrics pair, the engine's histograms are differenced across the replay
(after minus before), so the counts and sums are this cell's requests only. Beside them, the client-side
TTFT of the latency-critical tenant from the cell's raw rows.

What this cannot do, and says so in its output:
- The engine's histograms carry no tenant label. Their means mix the latency-critical and best-effort
  requests of a contended cell; only an R1 cell, which serves one tenant, is a single population.
- A percentile read from histogram buckets is bounded by the bucket edges. It is printed as the upper edge
  of the bucket the quantile falls in, labelled as such, never as a value.
"""
import glob
import json
import math
import os
import re
import sys

SERIES = re.compile(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?\s+(\S+)')
LE = re.compile(r'le="([^"]+)"')


def read_prom(path):
    """Sum every sample of a series name across its label sets, keeping histogram buckets by `le`."""
    out = {}
    with open(path) as f:
        for line in f:
            if line.startswith("#"):
                continue
            m = SERIES.match(line)
            if not m:
                continue
            name, labels, value = m.group(1), m.group(2) or "", m.group(3)
            try:
                v = float(value)
            except ValueError:
                continue
            key = name
            if name.endswith("_bucket"):
                le = LE.search(labels)
                if not le:
                    continue
                key = (name, float(le.group(1)))
            out[key] = out.get(key, 0.0) + v
    return out


def delta(before, after, name):
    """count, sum and cumulative buckets of one histogram across the replay."""
    c = after.get(name + "_count", 0.0) - before.get(name + "_count", 0.0)
    s = after.get(name + "_sum", 0.0) - before.get(name + "_sum", 0.0)
    buckets = sorted(
        (le, after.get((name + "_bucket", le), 0.0) - before.get((name + "_bucket", le), 0.0))
        for (n, le) in [k for k in after if isinstance(k, tuple)] if n == name + "_bucket"
    )
    return c, s, buckets


def bucket_quantile(buckets, count, q):
    """The upper edge of the bucket holding the q-th quantile, or None."""
    if count <= 0:
        return None
    target = q * count
    for le, cum in buckets:
        if cum >= target:
            return le
    return None


def nearest_rank(xs, q):
    xs = sorted(xs)
    return xs[max(0, math.ceil(q * len(xs)) - 1)] if xs else None


def client_ttft(raw_path):
    lc = []
    with open(raw_path) as f:
        for line in f:
            r = json.loads(line)
            if r.get("tenant") != "premium-1" or r.get("errorKind") or not r.get("firstTokenUnixNanos"):
                continue
            lc.append((r["firstTokenUnixNanos"] - r["sendUnixNanos"]) / 1e6)
    return lc


def fmt(v, unit="ms", scale=1000.0):
    return "-" if v is None else f"{v * scale:.1f}{unit}"


def main(run_dir):
    print(f"# decomposition of {run_dir}")
    print("# engine histograms are differenced across each replay; they carry no tenant label")
    hdr = ("cell", "LC n", "LC p50", "LC p99", "eng TTFT n", "eng TTFT mean", "eng TTFT p99<=",
           "queue mean", "queue p99<=", "prefill mean", "prefill p99<=")
    print("\t".join(hdr))
    for before in sorted(glob.glob(os.path.join(run_dir, "engine-metrics-*-before.prom"))):
        cell = os.path.basename(before)[len("engine-metrics-"):-len("-before.prom")]
        after = before.replace("-before.prom", "-after.prom")
        raw = os.path.join(run_dir, f"raw-{cell}.jsonl")
        if not os.path.exists(after) or not os.path.exists(raw):
            print(f"{cell}\tskipped: missing {'after .prom' if not os.path.exists(after) else 'raw rows'}")
            continue
        b, a = read_prom(before), read_prom(after)
        lc = client_ttft(raw)
        row = [cell, str(len(lc)), fmt(nearest_rank(lc, .5), "ms", 1), fmt(nearest_rank(lc, .99), "ms", 1)]
        for name in ("vllm:time_to_first_token_seconds", "vllm:request_queue_time_seconds",
                     "vllm:request_prefill_time_seconds"):
            c, s, bk = delta(b, a, name)
            mean = s / c if c > 0 else None
            if name == "vllm:time_to_first_token_seconds":
                row.append(str(int(c)))
            row += [fmt(mean), fmt(bucket_quantile(bk, c, .99))]
        print("\t".join(row))
    for err in sorted(glob.glob(os.path.join(run_dir, "engine-metrics-*.err"))):
        with open(err) as f:
            print(f"# {os.path.basename(err)}: {f.readline().strip()}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: decompose.py <archive>/m5c-run")
    main(sys.argv[1])
