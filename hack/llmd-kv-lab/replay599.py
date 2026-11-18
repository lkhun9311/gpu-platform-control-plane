#!/usr/bin/env python3
"""Summarises a replay599.sh run: per arm, where the shared-942 requests went, what the serving simulator had cached,
what the EPP's prefix scorer believed about the pod it picked, the simulators' queues, and simulator TTFT.

Every figure comes from the run directory alone:
- placement, cached tokens and TTFT from replay.jsonl, which the simulator's own response headers and usage fill;
- the scorer's belief from the EPP's "Calculated score" debug lines, joined by the gateway's x-request-id;
- queues from samples.jsonl, a read of each simulator's gauges every second.
TTFT is measured to the first content chunk from the request's scheduled time, as experiment A measured it, and a
failed request counts as +inf, so a failure can never improve a percentile.
The latencies are a simulator's and describe where requests queued, not how fast any GPU would serve them.
"""
import gzip
import json
import math
import os
import sys
from collections import defaultdict

PREFIX_SCORER = "prefix-cache-scorer"
# Experiment A's post-hoc split of the shared-942 tail: the first 20 s are the cold start, where every prompt misses.
COLD_START_MS = 20_000
WINDOW_MS = 30_000


def nearest_rank(values, q):
    if not values:
        return math.nan
    s = sorted(values)
    return s[max(0, math.ceil(q * len(s)) - 1)]


def pod_of(endpoint):
    name = endpoint.get("name", "") if isinstance(endpoint, dict) else str(endpoint)
    return name.removesuffix("-rank-0")


def load_scores(arm_dir):
    """scores[served_request_id][plugin][pod] = score, from every EPP log of the arm."""
    scores = defaultdict(lambda: defaultdict(dict))
    for name in sorted(os.listdir(arm_dir)):
        if not (name.startswith("epp-") and name.endswith((".log", ".log.gz"))):
            continue
        opener = gzip.open if name.endswith(".gz") else open
        with opener(os.path.join(arm_dir, name), "rt", encoding="utf-8", errors="replace") as f:
            for line in f:
                if "Calculated score" not in line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                rid, plugin = rec.get("x-request-id"), rec.get("plugin", "")
                if rid and "endpoint" in rec:
                    scores[rid][plugin.split("/")[0]][pod_of(rec["endpoint"])] = rec.get("score")
    return scores


def ttft_ms(r):
    ok = r["status"] == 200 and r["done"] and not r.get("error") and r["first_token_unix_nanos"]
    if not ok:
        return math.inf
    return (r["first_token_unix_nanos"] - r["origin_unix_nanos"]) / 1e6 - r["offset_ms"]


def queue_stats(samples, pods):
    """Per pod mean and max of running+waiting, and the mean absolute difference between the two busiest pods' queues
    over seconds where every pod was read."""
    by_sec = defaultdict(dict)
    per_pod = defaultdict(list)
    failed = 0
    for s in samples:
        if s.get("error") or not s.get("values"):
            failed += 1
            continue
        v = s["values"]
        q = v.get("vllm:num_requests_running", 0) + v.get("vllm:num_requests_waiting", 0)
        per_pod[s["pod"]].append(q)
        by_sec[s["unix_nanos"] // 1_000_000_000][s["pod"]] = q
    diffs = [max(d.values()) - min(d.values()) for d in by_sec.values() if len(d) == len(pods) and len(pods) > 1]
    return per_pod, (sum(diffs) / len(diffs) if diffs else math.nan), failed


def summarise_arm(run, arm):
    arm_dir = os.path.join(run, arm)
    path = os.path.join(arm_dir, "replay.jsonl")
    if not os.path.exists(path):
        return None
    rows = sorted((json.loads(l) for l in open(path, encoding="utf-8")), key=lambda r: r["index"])
    samples = [json.loads(l) for l in open(os.path.join(arm_dir, "samples.jsonl"), encoding="utf-8")] \
        if os.path.exists(os.path.join(arm_dir, "samples.jsonl")) else []
    scores = load_scores(arm_dir)
    pods = sorted({r["pod"] for r in rows if r["pod"]})
    n = len(rows)
    ok = [r for r in rows if ttft_ms(r) != math.inf]
    t = [ttft_ms(r) for r in rows]
    out = {"arm": arm, "n": n, "ok": len(ok), "via_epp": sum(r["via_epp"] for r in rows), "pods": pods}
    out["share"] = {p: sum(r["pod"] == p for r in rows) / n for p in pods}
    # The worst 30 s window: how far the busiest pod's share of that window's arrivals went above an even split.
    worst = 0.0
    for w in range(0, max(r["offset_ms"] for r in rows) + 1, WINDOW_MS):
        win = [r for r in rows if w <= r["offset_ms"] < w + WINDOW_MS and r["pod"]]
        if win and len(pods) > 0:
            worst = max(worst, max(sum(r["pod"] == p for r in win) / len(win) for p in pods))
    out["worst_window_share"] = worst
    known = [r for r in ok if r["cached_tokens"] >= 0]
    out["hit_tokens"] = sum(r["cached_tokens"] for r in known) / max(1, sum(r["prompt_tokens"] for r in known))
    out["unknown_cached"] = len(ok) - len(known)
    # The scorer's belief about the pod it picked: its prefix score there, joined by the gateway's request id.
    joined = [r for r in ok if r["served_request_id"] in scores]
    out["joined"] = len(joined)
    has_prefix = [r for r in joined if PREFIX_SCORER in scores[r["served_request_id"]]]
    if has_prefix:
        believed = [scores[r["served_request_id"]][PREFIX_SCORER].get(r["pod"]) or 0 for r in has_prefix]
        hit = [r["cached_tokens"] > 0 for r in has_prefix]
        out["scorer_mean"] = sum(believed) / len(believed)
        out["predicted"] = sum(b > 0 for b in believed)
        out["predicted_hit"] = sum(b > 0 and h for b, h in zip(believed, hit))
        out["predicted_miss"] = sum(b > 0 and not h for b, h in zip(believed, hit))
        out["unpredicted_hit"] = sum(b == 0 and h for b, h in zip(believed, hit))
        out["scored"] = len(has_prefix)
    out["p50"], out["p99"] = nearest_rank(t, 0.50), nearest_rank(t, 0.99)
    out["pod_p99"] = {p: nearest_rank([ttft_ms(r) for r in rows if r["pod"] == p], 0.99) for p in pods}
    late = [ttft_ms(r) for r in rows if r["offset_ms"] >= COLD_START_MS]
    out["p99_after_cold"] = nearest_rank(late, 0.99)
    out["top5"] = [(r["index"], r["offset_ms"], round(ttft_ms(r)), r["pod"][-5:], r["cached_tokens"])
                   for r in sorted(rows, key=ttft_ms, reverse=True)[:5]]
    per_pod, imbalance, failed = queue_stats(samples, pods)
    out["queue"] = {p: (sum(v) / len(v), max(v)) for p, v in per_pod.items() if v}
    out["imbalance"], out["sample_failures"], out["samples"] = imbalance, failed, len(samples)
    out["cold"] = [(r["index"], r["pod"][-5:], round(ttft_ms(r))) for r in rows if r["offset_ms"] < COLD_START_MS]
    return out


def fmt(x, nd=1):
    return "inf" if x == math.inf else ("-" if x is None or (isinstance(x, float) and math.isnan(x)) else f"{x:.{nd}f}")


def main(run):
    arms = [a for a in sorted(os.listdir(run)) if os.path.isfile(os.path.join(run, a, "replay.jsonl"))]
    results = [summarise_arm(run, a) for a in arms]
    print("Simulator latencies: they show where requests queued, not GPU performance.\n")
    print(f"{'arm':13} {'ok/n':>8} {'share by pod':>16} {'worst30s':>8} {'hit(sim)':>8} {'scorer':>7} "
          f"{'pred':>9} {'pred-miss':>9} {'p50':>7} {'p99':>7} {'p99 by pod':>16} {'p99>20s':>7} {'imbal':>5}")
    for o in results:
        share = " / ".join(fmt(o["share"][p], 3) for p in o["pods"])
        pp99 = " / ".join(fmt(o["pod_p99"][p], 0) for p in o["pods"])
        pred = f"{o['predicted']}/{o['scored']}" if "scored" in o else "-"
        print(f"{o['arm']:13} {o['ok']:>4}/{o['n']:<3} {share:>16} {fmt(o['worst_window_share'], 2):>8} "
              f"{fmt(o['hit_tokens'], 3):>8} {fmt(o.get('scorer_mean'), 3):>7} {pred:>9} "
              f"{o.get('predicted_miss', '-'):>9} {fmt(o['p50'], 0):>7} {fmt(o['p99'], 0):>7} {pp99:>16} "
              f"{fmt(o['p99_after_cold'], 0):>7} {fmt(o['imbalance'], 2):>5}")
    print()
    for o in results:
        print(f"== {o['arm']}: pods {', '.join(o['pods'])}; via EPP {o['via_epp']}/{o['n']}; joined to EPP scores "
              f"{o['joined']}/{o['ok']}; cached count missing {o['unknown_cached']}; samples {o['samples']} "
              f"({o['sample_failures']} failed reads)")
        for p, (mean, mx) in sorted(o["queue"].items()):
            print(f"   queue {p}: mean {mean:.2f}, max {mx:.0f} (running+waiting)")
        if "scored" in o:
            print(f"   scorer: picked pod scored above 0 for {o['predicted']}/{o['scored']}; of those, simulator hit "
                  f"{o['predicted_hit']}, missed {o['predicted_miss']}; hits it did not predict {o['unpredicted_hit']}")
        print(f"   five worst TTFT (index, offset ms, ms, pod, cached): {o['top5']}")
        print(f"   first {COLD_START_MS // 1000} s (index, pod, ms): {o['cold']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
