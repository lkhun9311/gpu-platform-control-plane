#!/usr/bin/env python3
"""Tabulates probes.sh churn runs: one line per run, for issue #599's endpoint delete and restart checks.

Delete under traffic: how many of the four streams' requests succeeded while the pod holding their family was
deleted, how many the deleted pod served, and how many were in flight when the delete was issued.
Restart in place: the prefix score the EPP gave the restarted pod for the family it held before the restart, where the
request went, and what that simulator reported cached.
A score above 0 with 0 cached tokens is a belief the cache no longer backs.
Scores come from the EPP's own "Calculated score" lines joined by the gateway's x-request-id, served pods and cached
tokens from the simulator's response, so belief and outcome are read from different processes.
"""
import gzip
import json
import os
import sys
from collections import defaultdict
from datetime import datetime


def prefix_scores(arm_dir):
    scores = defaultdict(dict)
    for name in sorted(os.listdir(arm_dir)):
        if not (name.startswith("epp-") and name.endswith((".log", ".log.gz"))):
            continue
        opener = gzip.open if name.endswith(".gz") else open
        with opener(os.path.join(arm_dir, name), "rt", encoding="utf-8", errors="replace") as f:
            for line in f:
                if "Calculated score" not in line or "prefix-cache-scorer" not in line:
                    continue
                try:
                    r = json.loads(line)
                except json.JSONDecodeError:
                    continue
                scores[r["x-request-id"]][r["endpoint"]["name"].removesuffix("-rank-0")] = r["score"]
    return scores


def ts(iso):
    """Parses an RFC 3339 UTC time with up to nanosecond digits, which datetime takes only to microseconds."""
    head, _, frac = iso.rstrip("Z").partition(".")
    return datetime.fromisoformat(head + "." + (frac + "000000")[:6] + "+00:00")


def one(run_dir):
    arm = next(a for a in sorted(os.listdir(run_dir)) if os.path.isfile(os.path.join(run_dir, a, "churn2-restart.txt")))
    d = os.path.join(run_dir, arm)
    rows = [json.loads(l) for l in open(os.path.join(d, "requests.jsonl"), encoding="utf-8")]
    scores = prefix_scores(d)
    restarted = open(os.path.join(d, "churn2-restart.txt"), encoding="utf-8").read().split()[0].split("=", 1)[1]
    victim_path = os.path.join(d, "churn1-victim.txt")
    if not os.path.exists(victim_path):
        return f"{os.path.basename(run_dir):32} predates the concurrent-stream delete check; not tabulated"
    victim = open(victim_path, encoding="utf-8").read().strip()
    deleted_at = ts(open(os.path.join(d, "churn1-delete-at.txt"), encoding="utf-8").read().strip()).timestamp()
    stream = [r for r in rows if "churn1-stream" in r["request_id"]]
    ok = sum(r["status"] == 200 and not r.get("error") for r in stream)
    on_victim = [r for r in stream if r["pod"] == victim]
    # In flight at the delete: sent before it and answered after it, wherever it was served or failed.
    in_flight = [r for r in stream if ts(r["sent_at"]).timestamp() <= deleted_at
                 <= ts(r["sent_at"]).timestamp() + r["latency_ms"] / 1000]
    after_restart = next(r for r in rows if "churn2-after" in r["request_id"])
    s2 = scores.get(after_restart["served_request_id"])
    if s2 is None:
        return f"{os.path.basename(run_dir):32} EPP scores missing for the restart check; no line is printed from a guess"
    others = [round(v, 3) for k, v in s2.items() if k != restarted]
    return (f"{os.path.basename(run_dir):32} delete: {ok}/{len(stream)} ok, {len(on_victim)} served by the deleted pod, "
            f"{len(in_flight)} in flight at the delete ({sum(r['pod'] == victim for r in in_flight)} of them on it, "
            f"{sum(bool(r.get('error')) for r in in_flight)} failed) | restart: restarted pod "
            f"{round(s2.get(restarted, float('nan')), 3)}, other {others}, served "
            f"{'restarted' if after_restart['pod'] == restarted else 'other'}, cached {after_restart['cached_tokens']}")


def main(dirs):
    for d in dirs:
        print(one(d))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
