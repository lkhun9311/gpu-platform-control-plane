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
# loadgen's offered rate, 10 per second; a request written a whole slot after its dispatch was not offered on time.
SLOT_S = 0.1
# The registration's arms and repetitions; a run missing any of them is incomplete, not a smaller result.
REGISTERED_ARMS = ("R1-fresh", "R2-fresh", "R2-pinned")
REGISTERED_REPS = 3


def read_rows(path):
    # "t" is when the limiter could first see the request: its write time where loadgen recorded one, else its
    # dispatch time, which is all that runs before the write time was recorded carry.
    with open(path, newline="") as f:
        rows = []
        for r in csv.DictReader(f, delimiter="\t"):
            sent = float(r["sent_ms"]) / 1000
            wrote = float(r["wrote_ms"]) / 1000 if "wrote_ms" in r else None
            rows.append({"sent": sent, "wrote": wrote, "t": sent if wrote is None or wrote < 0 else wrote,
                         "status": int(r["status"])})
        return rows


def max_ok_in_window(rows, after, width=1.0):
    # Sliding window over send times, because the client cannot see which Pod answered.
    ok = sorted(r["t"] for r in rows if r["status"] == 200 and r["t"] >= after)
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
    present = {(a["arm"], a["rep"]) for a in arms}
    missing = [f"{arm}-{rep}" for arm in REGISTERED_ARMS for rep in map(str, range(1, REGISTERED_REPS + 1))
               if (arm, rep) not in present]
    if missing:
        print(f"INVALID: the run is missing registered arms {', '.join(missing)}")
        valid = False
    print("arm\trep\tT_s\tadmitted\tbound\tratio\tlimited\tother\tstub_served\tmax_ok_1s\tpods_serving")
    for a in arms:
        rows = read_rows(os.path.join(run, f"{a['arm']}-{a['rep']}.tsv"))
        written = [r["t"] for r in rows]
        t = max(written) - min(written)
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

        if rows[0]["wrote"] is None:
            if a["arm"].endswith("-pinned"):
                # Queued writes can only lengthen the true T, so this bound can be low and a breach false, never hidden.
                print("  note: no write times recorded; T is from dispatch, so a breach read here is not established")
        else:
            unwritten = sum(r["wrote"] < 0 and r["status"] != 0 for r in rows)
            late = max((r["wrote"] - r["sent"] for r in rows if r["wrote"] >= 0), default=0.0)
            if unwritten:
                print(f"  INVALID: {unwritten} answered requests have no write time")
                valid = False
            if late > SLOT_S:
                print(f"  INVALID: a request was written {late:.3f} s after its dispatch, so the offered rate was not 10/s")
                valid = False
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
