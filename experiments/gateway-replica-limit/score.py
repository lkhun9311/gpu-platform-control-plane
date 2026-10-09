#!/usr/bin/env python3
"""Score one gateway-replica-limit run directory against the readings registered in README.md.

Usage: score.py RUN_DIR

RUN_DIR holds one <arm>-<rep>.tsv per arm and repetition written by loadgen, and arms.tsv written by the
runner with the stub's served count and, for the restart arm, the deletion offset.
Exit status is 0 when every validity check passed, 1 when any failed, so a caller cannot read a voided run
as a result.
"""
import csv
import os
import sys

RATE = 1.0   # tokens per second: requestsPerMinute 60 / 60
BURST = 5


def read_rows(path):
    with open(path, newline="") as f:
        return [{"sent": float(r["sent_ms"]) / 1000, "status": int(r["status"])}
                for r in csv.DictReader(f, delimiter="\t")]


def max_ok_in_window(rows, after, width=1.0):
    # Sliding window over send times, because the client cannot see which Pod answered.
    ok = sorted(r["sent"] for r in rows if r["status"] == 200 and r["sent"] >= after)
    best, j = 0, 0
    for i in range(len(ok)):
        while ok[i] - ok[j] > width:
            j += 1
        best = max(best, i - j + 1)
    return best


def pod_counts(field):
    # "pod=count pod=count " as the runner writes it.
    return {k: int(v) for k, v in (kv.split("=") for kv in field.split())}


def pods_moved(before, after):
    b, a = pod_counts(before), pod_counts(after)
    return ",".join(f"{p}+{a[p] - b.get(p, 0)}" for p in sorted(a) if a[p] - b.get(p, 0) > 0) or "-"


def main():
    run = sys.argv[1]
    with open(os.path.join(run, "arms.tsv"), newline="") as f:
        arms = list(csv.DictReader(f, delimiter="\t"))

    valid = True
    print("arm\trep\tT_s\tadmitted\tbound\tratio\tlimited\tother\tstub_served\tmax_ok_1s\tpods_serving")
    for a in arms:
        rows = read_rows(os.path.join(run, f"{a['arm']}-{a['rep']}.tsv"))
        t = rows[-1]["sent"] - rows[0]["sent"]
        admitted = sum(r["status"] == 200 for r in rows)
        limited = sum(r["status"] == 429 for r in rows)
        other = len(rows) - admitted - limited
        bound = BURST + RATE * t
        # The restart arm reads after the deletion; every other arm reads the second half, as the contrast.
        after = float(a["delete_s"]) if a["delete_s"] else t / 2
        burst_seen = max_ok_in_window(rows, after)
        stub = int(a["stub_served"])
        print(f"{a['arm']}\t{a['rep']}\t{t:.2f}\t{admitted}\t{bound:.2f}\t{admitted / bound:.2f}\t"
              f"{limited}\t{other}\t{stub}\t{burst_seen}\t{pods_moved(a['pods_before'], a['pods_after'])}")

        if stub != admitted:
            print(f"  INVALID: stub served {stub} but the client saw {admitted} answered 200")
            valid = False
        if other and a["arm"] != "R1-restart":
            print(f"  INVALID: {other} answers were neither 200 nor 429")
            valid = False
        if a["arm"] == "R1-fresh" and not (bound - 2 <= admitted <= bound + 1):
            print(f"  INVALID: the control admitted {admitted}, outside [{bound - 2:.2f}, {bound + 1:.2f}]")
            valid = False

    print("VALID" if valid else "VOID: a validity check failed, so no reading above is a result")
    return 0 if valid else 1


if __name__ == "__main__":
    sys.exit(main())
