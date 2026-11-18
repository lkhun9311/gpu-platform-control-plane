#!/usr/bin/env python3
"""Summarises an observe.sh or probes.sh run: per request, the serving pod, its cached tokens, and the EPP's scores.

The served pod and the cached-token count come from the simulator's response (requests.jsonl), so they are what
happened. The scores come from the EPP's own "Calculated score" debug lines joined by x-request-id, so they are what
the EPP believed. A request the log cannot be joined for is printed with no scores rather than dropped, because a
missing join is a fact about the evidence and must stay visible.
"""
import gzip
import json
import os
import sys
from collections import defaultdict


def load_scores(arm_dir):
    scores = defaultdict(dict)
    for name in sorted(os.listdir(arm_dir)):
        # Committed runs keep the EPP logs gzipped, because at --v 4 they are most of a run's size.
        if not (name.startswith("epp-") and (name.endswith(".log") or name.endswith(".log.gz"))):
            continue
        path = os.path.join(arm_dir, name)
        opener = gzip.open if name.endswith(".gz") else open
        for line in opener(path, "rt", encoding="utf-8", errors="replace"):
            if "Calculated score" not in line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            rid = rec.get("x-request-id")
            ep = rec.get("endpoint")
            if not rid or ep is None:
                continue
            if isinstance(ep, dict):
                ep = ep.get("name") or json.dumps(ep, sort_keys=True)
            scores[rid][str(ep)] = rec.get("score")
    return scores


def short(pod):
    # Simulator pods are vllm-d-<replicaset>-<suffix>; the suffix alone tells three pods apart in a table.
    return pod.rsplit("-", 1)[-1] if pod else "-"


def summarise_arm(run, arm):
    arm_dir = os.path.join(run, arm)
    path = os.path.join(arm_dir, "requests.jsonl")
    if not os.path.exists(path):
        return
    scores = load_scores(arm_dir)
    rows = [json.loads(l) for l in open(path, encoding="utf-8")]
    print(f"== arm {arm}: {len(rows)} requests")
    print(f"{'request_id':28} {'family':6} {'target':10} {'pod':6} {'cached/prompt':>13} {'ms':>7}  epp scores")
    for r in rows:
        s = scores.get(r.get("served_request_id") or "", {})
        st = " ".join(f"{short(k.split('/')[-1].removesuffix('-rank-0'))}={v:g}" if isinstance(v, (int, float))
                      else f"{k}={v}" for k, v in sorted(s.items()))
        target = r["target"] if r["target"] == "gateway" else "direct"
        print(f"{r['request_id']:28} {r['family']:6} {target:10} {short(r['pod']):6} "
              f"{r['cached_tokens']:>6}/{r['prompt_tokens']:<6} {r['latency_ms']:7.1f}  {st}"
              + (f"  ERROR {r['error']}" if r.get("error") else ""))
    gw = [r for r in rows if r["target"] == "gateway"]
    print(f"   gateway requests joined to EPP scores: "
          f"{sum(1 for r in gw if r.get('served_request_id') in scores)}/{len(gw)}")
    tally(rows, scores)
    print()


def step_of(request_id):
    # Request ids are <arm>-<step>-<seq>; the step is what a probe varies, so hits are counted per step.
    return request_id.rsplit("-", 1)[0]


def tally(rows, scores):
    """Per step: gateway requests, cache hits, hits the EPP predicted, and requests sent to the warm pod.

    A hit is "predicted" when the EPP scored the serving pod above zero, which separates a hit the scorer found from
    one a tie-break stumbled on. A family is "warmed" when an earlier direct request sent it to a pod; the warm pod is
    the ground truth a cache-aware router should find. Steps with no warm-up report the warm column as "-".
    """
    warm = {}
    steps = {}
    for r in rows:
        if r["target"].startswith("direct:"):
            warm[r["family"]] = r["pod"]
            continue
        s = steps.setdefault(step_of(r["request_id"]),
                             {"n": 0, "hit": 0, "joined": 0, "predicted": 0, "warm_n": 0, "to_warm": 0})
        s["n"] += 1
        hit = r["cached_tokens"] > 0
        s["hit"] += 1 if hit else 0
        sc = scores.get(r.get("served_request_id") or "")
        if sc:
            s["joined"] += 1
            mine = [v for k, v in sc.items() if r["pod"] and r["pod"] in k]
            s["predicted"] += 1 if hit and mine and isinstance(mine[0], (int, float)) and mine[0] > 0 else 0
        if r["family"] in warm:
            s["warm_n"] += 1
            s["to_warm"] += 1 if r["pod"] == warm[r["family"]] else 0
    print(f"   {'step':40} {'gateway':>7} {'hit':>5} {'predicted':>10} {'to warm pod':>12}")
    for name, s in steps.items():
        tw = f"{s['to_warm']}/{s['warm_n']}" if s["warm_n"] else "-"
        pr = f"{s['predicted']}/{s['joined']}" if s["joined"] else "no log"
        print(f"   {name:40} {s['n']:>7} {s['hit']:>5} {pr:>10} {tw:>12}")


def main():
    run = sys.argv[1]
    # Every arm directory is summarised, so an arm added later cannot be silently left out of its own run's summary.
    for arm in sorted(os.listdir(run)):
        if os.path.isfile(os.path.join(run, arm, "requests.jsonl")):
            summarise_arm(run, arm)


if __name__ == "__main__":
    main()
