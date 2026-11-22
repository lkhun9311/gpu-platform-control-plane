#!/usr/bin/env python3
"""Scores a hack/gateway-shared-ratelimit/run.sh run directory.

Usage: score.py <run-dir>

The policy is requestsPerMinute 60, burst 5: one token a second and a bucket of five.
So one bucket admits at most bound = 5 + T in a window of T seconds, and N independent buckets up to N times that.

Two counts are kept apart:
  - admitted: the client got HTTP 200, so the gateway let the request through to the backend;
  - completed: that 200's stream also ended with data: [DONE] and no error.
A row's outcome comes from the loadgen, which judges the stream with internal/bench's HTTPSender.
A run recorded before the loadgen wrote outcomes (run 1) has no outcome column; there completed is printed as "-",
because a 200 alone does not say the stream finished.

Checks that void the run rather than becoming a result (exit 1):
  - every arm sent exactly rate x duration requests;
  - in every arm without an event, the stub served exactly the requests the client saw admitted;
  - the memory-1 control admitted within [bound - 2, bound + 1], the limiter working as designed.
The readings are printed, not judged here; the README states what they mean.
"""
import csv
import math
import sys
from collections import Counter

RUN = sys.argv[1]
BURST, RATE = 5, 1.0


def rows(path):
    with open(path) as f:
        return list(csv.DictReader(f, delimiter="\t"))


def outcome(r):
    """The loadgen's outcome, or a status-only label for a run recorded before outcomes existed."""
    if "outcome" in r:
        return r["outcome"]
    s = int(r["status"])
    return {200: "status200_unjudged", 429: "rate_limited", 0: "transport"}.get(s, "http_5xx" if 500 <= s <= 599 else "http_other")


ORDER = ("completed", "status200_unjudged", "stream_cut", "rate_limited", "http_5xx", "http_other", "timeout",
         "transport", "cancelled", "unsent")


def window(reqs, lo, hi):
    """Counts by outcome for requests sent in [lo, hi) seconds."""
    return Counter(outcome(r) for r in reqs if lo <= float(r["sent_ms"]) / 1000 < hi)


def fmt(c):
    return " ".join(f"{k}={c[k]}" for k in ORDER if c[k])


def tail(values):
    """p50, p99 and max by nearest rank, with n; p99 is reported as max when the sample is too small to differ."""
    if not values:
        return "n=0"
    v = sorted(values)
    n = len(v)
    p = lambda q: v[max(0, math.ceil(q * n) - 1)]
    p99 = f"p99={p(0.99):.1f}" if math.ceil(0.99 * n) < n else "p99=max"
    return f"{p99} p50={p(0.50):.1f} max={v[-1]:.1f} n={n}"


void = []
print("arm\trep\treplicas\tstore\tsent\tadmitted\tcompleted\tcut200\t429\t503\tno_status\tother\tunsent\tT_s\tbound"
      "\tadmitted/bound\tstub")
arms = rows(f"{RUN}/arms.tsv")
if not arms:
    void.append("arms.tsv has no arms")
details, latencies = [], []
for a in arms:
    reqs = rows(f"{RUN}/{a['arm']}-{a['rep']}.tsv")
    judged = bool(reqs) and "outcome" in reqs[0]
    rate = float(a.get("rate") or 10)
    dur = float(a.get("duration_s") or 30)
    planned = int(rate * dur)
    oc = Counter(outcome(r) for r in reqs)
    st = Counter(int(r["status"]) for r in reqs if outcome(r) != "unsent")
    # T from the first to the last write when every request was written, else from dispatch.
    stamps = [float(r["wrote_ms"]) for r in reqs if float(r["wrote_ms"]) >= 0]
    if len(stamps) != len(reqs):
        stamps = [float(r["sent_ms"]) for r in reqs if float(r["sent_ms"]) >= 0]
    t = (max(stamps) - min(stamps)) / 1000
    bound = BURST + RATE * t
    # The status columns partition the sent rows; completed and cut200 split the 200s.
    admitted = st[200]
    completed = oc["completed"] if judged else "-"
    cut = admitted - oc["completed"] if judged else "-"
    other = sum(n for s, n in st.items() if s not in (0, 200, 429, 503))
    stub = int(a["stub_served"])
    print(f"{a['arm']}\t{a['rep']}\t{a['replicas']}\t{a['store']}\t{len(reqs)}\t{admitted}\t{completed}\t"
          f"{cut}\t{st[429]}\t{st[503]}\t{st[0]}\t{other}\t{oc['unsent']}\t{t:.2f}\t"
          f"{bound:.2f}\t{admitted / bound:.2f}\t{stub}")
    if len(reqs) - oc["unsent"] != planned:
        void.append(f"{a['arm']}-{a['rep']} sent {len(reqs) - oc['unsent']}, not {planned}")
    if a["event"] == "none" and stub != admitted:
        void.append(f"{a['arm']}-{a['rep']}: stub served {stub}, client saw {admitted} admitted")
    if a["arm"] == "memory-1" and not (bound - 2 <= admitted <= bound + 1):
        void.append(f"control memory-1-{a['rep']} admitted {admitted}, outside [{bound - 2:.2f}, {bound + 1:.2f}]")
    if judged:
        lat = lambda o: [float(r["latency_ms"]) for r in reqs if outcome(r) == o]
        ttft = [float(r["ttft_ms"]) for r in reqs if outcome(r) == "completed" and float(r["ttft_ms"]) >= 0]
        latencies.append(f"{a['arm']}-{a['rep']}: completed end-to-end ms {tail(lat('completed'))}; "
                         f"completed TTFT ms {tail(ttft)}; 429 ms {tail(lat('rate_limited'))}")
    if a["event"] != "none":
        e1, e2 = float(a["event1_s"]), float(a["event2_s"])
        end = max(float(r["sent_ms"]) for r in reqs) / 1000 + 0.001
        if e2 >= end:
            void.append(f"{a['arm']}-{a['rep']}: the event cleared at {e2:.2f}s, after the last request at {end:.2f}s")
        errs = [float(r["sent_ms"]) / 1000 for r in reqs if outcome(r) not in ("completed", "status200_unjudged", "rate_limited")]
        per_s = Counter(int(float(r["sent_ms"]) / 1000) for r in reqs if int(r["status"]) == 200)
        d = (f"{a['arm']}-{a['rep']}: event at {e1:.2f}s, cleared at {e2:.2f}s\n"
             f"  before  [0, {e1:.2f}) {fmt(window(reqs, 0, e1))}  (one bucket: {BURST + RATE * e1:.1f})\n"
             f"  during  [{e1:.2f}, {e2:.2f}) {fmt(window(reqs, e1, e2))}  (one bucket refills {RATE * (e2 - e1):.1f})\n"
             f"  after   [{e2:.2f}, {end:.2f}) {fmt(window(reqs, e2, end))}  (one bucket refills {RATE * (end - e2):.1f})\n"
             f"  not completed and not 429: {len(errs)}"
             + (f", sent from {min(errs):.2f}s to {max(errs):.2f}s" if errs else "") + "\n"
             f"  200s per second: {' '.join(str(per_s[i]) for i in range(int(dur)))}\n"
             f"  stub served {stub}, client saw {admitted} admitted")
        if judged:
            # A stream in flight at the event was sent before it and still open when it happened.
            inflight = [r for r in reqs if int(r["status"]) == 200 and float(r["sent_ms"]) / 1000 < e1
                        and (float(r["sent_ms"]) + float(r["latency_ms"])) / 1000 > e1]
            d += (f"\n  admitted streams open at the event ({e1:.2f}s): {len(inflight)}"
                  + (f", ended {fmt(Counter(outcome(r) for r in inflight))}" if inflight else ""))
            for r in inflight:
                d += (f"\n    seq {r['seq']} sent {float(r['sent_ms']) / 1000:.2f}s ended "
                      f"{(float(r['sent_ms']) + float(r['latency_ms'])) / 1000:.2f}s {r['outcome']} done={r['done']}"
                      + (f" {r['error_kind']}: {r['error']}" if r["error_kind"] else ""))
        details.append(d)
print()
for d in details:
    print(d)
if latencies:
    print("\nlatency (nearest rank; p99=max means the sample is under 100 and p99 is its maximum)")
    for line in latencies:
        print("  " + line)
for a in arms:
    print(f"pods {a['arm']}-{a['rep']}: before [{a['pods_before'].strip()}] after [{a['pods_after'].strip()}]")
if void:
    print("\nVOID:\n  " + "\n  ".join(void))
    sys.exit(1)
print("\nVALID")
