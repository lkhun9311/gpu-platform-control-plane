#!/usr/bin/env python3
"""Score a checkpoint-resume run directory against the readings registered in README.md.

Usage: score.py RUN_DIR

RUN_DIR holds <arm>-<rep>.jsonl (every Pod's records for that run) and <arm>-<rep>.pods (one Pod name per
line), written by hack/checkpoint-resume.sh. Exit 0 only when every validity check passed and every
registered arm and repetition is present, so a caller cannot read a void or partial run as a result.
"""
import datetime
import json
import os
import sys

ARMS = ("uninterrupted", "restart", "resume", "resume-no-optimizer", "resume-no-data-rng")
NEGATIVE = ("resume-no-optimizer", "resume-no-data-rng")
REPS = 3
STEPS = 40
MISMATCH = 1e-4


def records(path):
    # Lenient line reading: a record split by the shared stdout is dropped and counted, not fatal.
    out, bad = [], 0
    for line in open(path):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            out.append(json.loads(line))
        except ValueError:
            bad += 1
    return out, bad


def ts(record):
    return datetime.datetime.fromisoformat(record["ts"])


def main():
    run = sys.argv[1]
    valid, finals, rows = True, {}, []

    def void(msg):
        nonlocal valid
        print(f"  INVALID: {msg}")
        valid = False

    for rep in range(1, REPS + 1):
        for arm in ARMS:
            base = os.path.join(run, f"{arm}-{rep}")
            if not os.path.exists(base + ".jsonl"):
                void(f"{arm}-{rep} is missing")
                continue
            recs, bad = records(base + ".jsonl")
            pods = [p for p in open(base + ".pods").read().split() if p]
            steps0 = [r for r in recs if r["event"] == "step" and r["rank"] == 0]
            kills = [r for r in recs if r["event"] == "self_kill"]
            last = {rank: [r for r in recs if r["event"] == "step" and r["rank"] == rank and r["step"] == STEPS]
                    for rank in (0, 1)}
            if not last[0] or not last[1]:
                void(f"{arm}-{rep} has no step {STEPS} record on both ranks")
                continue
            final = last[0][-1]["params"]
            finals[(arm, rep)] = final

            want_kills, want_pods = (0, 1) if arm == "uninterrupted" else (1, 2)
            if len(kills) != want_kills or len(pods) != want_pods:
                void(f"{arm}-{rep}: {len(kills)} kills and {len(pods)} Pods, registered {want_kills} and {want_pods}")
            if last[0][-1]["digest"] != last[1][-1]["digest"]:
                void(f"{arm}-{rep}: the ranks ended with different parameters")

            recovery = ""
            if kills:
                later = [r for r in recs if r["event"] == "start" and ts(r) > ts(kills[0])]
                if later:
                    recovery = f"{(ts(later[0]) - ts(kills[0])).total_seconds():.1f}"
            resumed = sorted({r["resumed_from_step"] for r in recs if r["event"] == "start"})
            rows.append((arm, rep, len(steps0), resumed, recovery, bad))

    reference = {rep: finals.get(("uninterrupted", rep)) for rep in range(1, REPS + 1)}
    refs = [r for r in reference.values() if r is not None]
    if len(refs) == REPS and any(r != refs[0] for r in refs):
        void("the three uninterrupted runs did not end identically")

    print("arm\trep\tsteps_run\tresumed_from\tdiff\tkill_to_restart_s\tunparsed_lines")
    for arm, rep, steps_run, resumed, recovery, bad in rows:
        ref, mine = reference.get(rep), finals.get((arm, rep))
        diff = max(abs(a - b) for a, b in zip(ref, mine)) if ref and mine else float("nan")
        print(f"{arm}\t{rep}\t{steps_run}\t{resumed}\t{diff:.3g}\t{recovery}\t{bad}")
        if arm in NEGATIVE and not diff > MISMATCH:
            void(f"{arm}-{rep} matched the reference (diff {diff:.3g}), so the test cannot fail")

    print("VALID" if valid else "VOID: a validity check failed, so no reading above is a result")
    return 0 if valid else 1


if __name__ == "__main__":
    sys.exit(main())
