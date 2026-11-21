#!/usr/bin/env python3
"""Scores a hack/gateway-shared-ratelimit/run.sh run directory.

Usage: score.py <run-dir>

The policy is requestsPerMinute 60, burst 5: one token a second and a bucket of five.
So one bucket admits at most bound = 5 + T in a window of T seconds, and N independent buckets up to N times that.

Checks that void the run rather than becoming a result (exit 1):
  - every arm sent exactly 300 requests;
  - in every arm without an event, the stub served exactly the requests the client saw answered 200;
  - the memory-1 control admitted within [bound - 2, bound + 1], the limiter working as designed.
The readings are printed, not judged here; the README states what they mean.
"""
import csv
import sys
from collections import Counter

RUN = sys.argv[1]
BURST, RATE, SENT = 5, 1.0, 300


def rows(path):
    with open(path) as f:
        return list(csv.DictReader(f, delimiter="\t"))


def window(reqs, lo, hi):
    """Counts by outcome for requests sent in [lo, hi) seconds."""
    c = Counter()
    for r in reqs:
        t = float(r["sent_ms"]) / 1000
        if lo <= t < hi:
            s = int(r["status"])
            c["ok" if s == 200 else "429" if s == 429 else "503" if s == 503 else "transport" if s == 0 else "other"] += 1
    return c


def fmt(c):
    return " ".join(f"{k}={c[k]}" for k in ("ok", "429", "503", "transport", "other") if c[k])


void = []
print("arm\trep\treplicas\tstore\tsent\tok\t429\t503\ttransport\tother\tT_s\tbound\tok/bound\tstub")
arms = rows(f"{RUN}/arms.tsv")
if not arms:
    void.append("arms.tsv has no arms")
details = []
for a in arms:
    reqs = rows(f"{RUN}/{a['arm']}-{a['rep']}.tsv")
    st = Counter(int(r["status"]) for r in reqs)
    # T from the first to the last write when every request was written, else from dispatch.
    stamps = [float(r["wrote_ms"]) for r in reqs if float(r["wrote_ms"]) >= 0]
    if len(stamps) != len(reqs):
        stamps = [float(r["sent_ms"]) for r in reqs]
    t = (max(stamps) - min(stamps)) / 1000
    bound = BURST + RATE * t
    ok = st[200]
    other = len(reqs) - ok - st[429] - st[503] - st[0]
    stub = int(a["stub_served"])
    print(f"{a['arm']}\t{a['rep']}\t{a['replicas']}\t{a['store']}\t{len(reqs)}\t{ok}\t{st[429]}\t{st[503]}\t{st[0]}\t"
          f"{other}\t{t:.2f}\t{bound:.2f}\t{ok / bound:.2f}\t{stub}")
    if len(reqs) != SENT:
        void.append(f"{a['arm']}-{a['rep']} sent {len(reqs)}, not {SENT}")
    if a["event"] == "none" and stub != ok:
        void.append(f"{a['arm']}-{a['rep']}: stub served {stub}, client saw {ok} answered 200")
    if a["arm"] == "memory-1" and not (bound - 2 <= ok <= bound + 1):
        void.append(f"control memory-1-{a['rep']} admitted {ok}, outside [{bound - 2:.2f}, {bound + 1:.2f}]")
    if a["event"] != "none":
        e1, e2 = float(a["event1_s"]), float(a["event2_s"])
        end = max(float(r["sent_ms"]) for r in reqs) / 1000 + 0.001
        errs = [float(r["sent_ms"]) / 1000 for r in reqs if int(r["status"]) not in (200, 429)]
        per_s = Counter(int(float(r["sent_ms"]) / 1000) for r in reqs if int(r["status"]) == 200)
        details.append(
            f"{a['arm']}: event at {e1:.2f}s, cleared at {e2:.2f}s\n"
            f"  before  [0, {e1:.2f}) {fmt(window(reqs, 0, e1))}  (one bucket: {BURST + RATE * e1:.1f})\n"
            f"  during  [{e1:.2f}, {e2:.2f}) {fmt(window(reqs, e1, e2))}  (one bucket refills {RATE * (e2 - e1):.1f})\n"
            f"  after   [{e2:.2f}, {end:.2f}) {fmt(window(reqs, e2, end))}  (one bucket refills {RATE * (end - e2):.1f})\n"
            f"  errors (not 200 or 429): {len(errs)}"
            + (f", sent from {min(errs):.2f}s to {max(errs):.2f}s" if errs else "") + "\n"
            f"  200s per second: {' '.join(str(per_s[i]) for i in range(30))}\n"
            f"  stub served {stub}, client saw {ok} answered 200")
print()
for d in details:
    print(d)
for a in arms:
    print(f"pods {a['arm']}-{a['rep']}: before [{a['pods_before'].strip()}] after [{a['pods_after'].strip()}]")
if void:
    print("\nVOID:\n  " + "\n  ".join(void))
    sys.exit(1)
print("\nVALID")
