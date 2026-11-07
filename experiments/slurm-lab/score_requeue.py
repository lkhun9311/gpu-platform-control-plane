"""Scores one Slurm requeue run of train.py against an uninterrupted reference run, and exits 1 if any check fails.

Usage: score_requeue.py [--load-none-control] REF_LOGS CASE_LOGS CASE_SCONTROL STEPS

REF_LOGS and CASE_LOGS are the logs directories train.sbatch writes, one attempt-<A>-rank-<R>.jsonl per rank and attempt.
CASE_SCONTROL is `scontrol show job` for the case job after it ended.

The fault record is never what passes a check: a second attempt must have trained, it must have resumed from a published
checkpoint at a step above zero, and its final parameters must equal the reference's bit for bit.
Equal parameters alone would not do, because this trainer is deterministic and a restart from step 0 ends at the same
parameters; only the resume record tells a resume from a rerun.

Every record must carry the rank its file is named for and the case job's own id, and every rank of every attempt must
have a log, so a set assembled from two jobs or one rank's records copied under the other's name is refused
(astra review r4, 2026-11-07).

With --load-none-control the case is the CKPT_LOAD=none mutation, and one more line reports whether it was caught for
the expected reason only: exactly the five failures that say no rank resumed, while every rank still trained from zero
to the end and matched the reference. A control whose restarted attempt also crashed fails more checks than those
five, and is not counted as caught.
"""

from __future__ import annotations

import json
import os
import re
import sys

WORLD = 2

# The failures a CKPT_LOAD=none control must produce, and no others (evidence/2026-11-04/05c-train-requeue-load-none.txt).
LOAD_NONE_FAILURES = (
    re.compile(r"attempt [1-9][0-9]* rank 0 did not restart from zero \(1 restart_from_zero records\)"),
    re.compile(r"attempt [1-9][0-9]* rank 0 has one resume record with from_step > 0 \(\[\]\)"),
    re.compile(r"attempt [1-9][0-9]* rank 1 did not restart from zero \(1 restart_from_zero records\)"),
    re.compile(r"attempt [1-9][0-9]* rank 1 has one resume record with from_step > 0 \(\[\]\)"),
    re.compile(r"every rank resumed from the same checkpoint \(\[\]\)"),
)


def load_none_caught(failures: list[str]) -> bool:
    """Whether the failures are exactly the five a restart from zero produces, each once."""
    if len(failures) != len(LOAD_NONE_FAILURES):
        return False
    return all(sum(1 for f in failures if pat.fullmatch(f)) == 1 for pat in LOAD_NONE_FAILURES)


def load(logs: str) -> dict[tuple[int, int], list[dict]]:
    """Every rank's records, keyed by (attempt, rank) from the file name."""
    runs = {}
    for name in sorted(os.listdir(logs)):
        match = re.fullmatch(r"attempt-(\d+)-rank-(\d+)\.jsonl", name)
        if not match:
            continue
        with open(os.path.join(logs, name)) as handle:
            records = []
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                # A rank killed mid-write can leave a partial last line; it is reported, not silently skipped.
                try:
                    records.append(json.loads(line))
                except ValueError:
                    records.append({"event": "unparsable", "line": line})
        runs[(int(match.group(1)), int(match.group(2)))] = records
    return runs


def events(records: list[dict], event: str) -> list[dict]:
    return [r for r in records if r.get("event") == event]


def main() -> int:
    args = sys.argv[1:]
    control = bool(args) and args[0] == "--load-none-control"
    if control:
        args = args[1:]
    if len(args) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    ref_logs, case_logs, scontrol_path, steps = args[0], args[1], args[2], int(args[3])
    failures: list[str] = []
    passes: list[str] = []

    def check(ok: bool, what: str) -> bool:
        (passes if ok else failures).append(what)
        return ok

    ref = load(ref_logs)
    case = load(case_logs)

    # The reference: one attempt, every step on every rank, and both ranks ending at the same parameters.
    check(sorted(ref) == [(0, r) for r in range(WORLD)], f"reference has exactly attempt 0 for ranks 0..{WORLD - 1}: {sorted(ref)}")
    ref_final = {}
    for rank in range(WORLD):
        recs = ref.get((0, rank), [])
        got = [r["step"] for r in events(recs, "step")]
        check(got == list(range(1, steps + 1)), f"reference rank {rank} ran steps 1..{steps} in order (saw {len(got)} step records)")
        check(not events(recs, "resume"), f"reference rank {rank} did not resume from anything")
        last = [r for r in events(recs, "step") if r["step"] == steps]
        if check(len(last) == 1 and last[0].get("params") is not None, f"reference rank {rank} recorded final parameters"):
            ref_final[rank] = last[0]
    if len(ref_final) == WORLD:
        check(ref_final[0]["params"] == ref_final[1]["params"], "reference ranks 0 and 1 ended with identical parameters")
    ref_digest = {r["step"]: r["digest"] for r in events(ref.get((0, 0), []), "step")}
    ref_ids = {r.get("run_id") for recs in ref.values() for r in recs if r.get("event") != "unparsable"}
    check(len(ref_ids) == 1, f"every reference record carries one job id ({sorted(map(str, ref_ids))})")
    for (attempt, rank), recs in sorted(ref.items()):
        check(all(r.get("rank") == rank for r in recs if r.get("event") != "unparsable"),
              f"reference attempt {attempt} rank {rank}: every record carries rank {rank}")

    # Slurm's own account: the job ended COMPLETED after at least one requeue.
    with open(scontrol_path) as handle:
        scontrol = handle.read()
    state = re.search(r"JobState=(\S+)", scontrol)
    restarts = re.search(r"Restarts=(\d+)", scontrol)
    check(state is not None and state.group(1) == "COMPLETED", f"scontrol JobState is COMPLETED ({state.group(1) if state else 'absent'})")
    n_restarts = int(restarts.group(1)) if restarts else 0
    check(n_restarts >= 1, f"scontrol Restarts is at least 1 ({restarts.group(1) if restarts else 'absent'})")

    job = re.search(r"JobId=(\d+)", scontrol)
    check(job is not None, f"scontrol names the case's JobId ({job.group(1) if job else 'absent'})")
    attempts = sorted({a for a, _ in case})
    check(attempts == list(range(n_restarts + 1)), f"the case has one log per attempt 0..Restarts ({attempts}, Restarts={n_restarts})")
    last_attempt = attempts[-1] if attempts else -1
    check(last_attempt >= 1, f"a second attempt wrote training records (last attempt {last_attempt})")
    expected_files = [(a, r) for a in range(n_restarts + 1) for r in range(WORLD)]
    check(sorted(case) == expected_files, f"the case has a log for every rank of every attempt ({sorted(case)})")
    for (attempt, rank), recs in sorted(case.items()):
        parsed = [r for r in recs if r.get("event") != "unparsable"]
        bad = [r for r in parsed if r.get("attempt") != attempt]
        check(not bad, f"attempt {attempt} rank {rank}: every record carries attempt {attempt} (TRAINING_ATTEMPT from SLURM_RESTART_COUNT)")
        check(all(r.get("rank") == rank for r in parsed), f"attempt {attempt} rank {rank}: every record carries rank {rank}")
        if job is not None:
            check(all(str(r.get("run_id")) == job.group(1) for r in parsed),
                  f"attempt {attempt} rank {rank}: every record carries the case's JobId {job.group(1)}")

    # The interrupted attempt: it trained, published at least one checkpoint, and did not finish.
    first = {rank: case.get((0, rank), []) for rank in range(WORLD)}
    published = [r["step"] for r in events(first[0], "checkpoint")]
    published_dirs = {r["step"]: r.get("dir") for r in events(first[0], "checkpoint")}
    reached = max((r["step"] for rank in range(WORLD) for r in events(first[rank], "step")), default=0)
    check(bool(published), f"attempt 0 published a checkpoint before the fault (last {published[-1] if published else None})")
    check(0 < reached < steps, f"attempt 0 was interrupted mid-training (highest step reached {reached} of {steps})")
    for rank in range(WORLD):
        for r in events(first[rank], "step"):
            if ref_digest.get(r["step"]) != r["digest"]:
                failures.append(f"attempt 0 rank {rank} step {r['step']} digest differs from the reference")
                break

    # The final attempt: every rank resumed from the same published checkpoint above step 0, and trained to the end.
    resumed_from = set()
    for rank in range(WORLD):
        recs = case.get((last_attempt, rank), [])
        resumes = events(recs, "resume")
        zero = events(recs, "restart_from_zero")
        check(not zero, f"attempt {last_attempt} rank {rank} did not restart from zero ({len(zero)} restart_from_zero records)")
        if zero and not resumes:
            # Only the load-none control lands here; that it still trained to the end and matched the reference is what
            # makes its two failures above the whole story rather than the first of several.
            got = [r["step"] for r in events(recs, "step")]
            check(got == list(range(1, steps + 1)), f"attempt {last_attempt} rank {rank} trained steps 1..{steps} in order from zero")
            last = [r for r in events(recs, "step") if r["step"] == steps]
            check(bool(last) and rank in ref_final and last[0]["params"] == ref_final[rank]["params"],
                  f"attempt {last_attempt} rank {rank} restarted from zero and still ended at the reference's parameters")
        if not check(len(resumes) == 1 and resumes[0]["from_step"] > 0,
                     f"attempt {last_attempt} rank {rank} has one resume record with from_step > 0 "
                     f"({[(r['from_step'], r['from_dir']) for r in resumes]})"):
            continue
        res = resumes[0]
        resumed_from.add((res["from_step"], res["from_dir"]))
        got = [r["step"] for r in events(recs, "step")]
        check(got == list(range(res["from_step"] + 1, steps + 1)),
              f"attempt {last_attempt} rank {rank} trained steps {res['from_step'] + 1}..{steps} in order")
        last = [r for r in events(recs, "step") if r["step"] == steps]
        if last and rank in ref_final:
            check(last[0]["params"] == ref_final[rank]["params"],
                  f"attempt {last_attempt} rank {rank} final parameters equal the reference's exactly")
            check(last[0]["digest"] == ref_final[rank]["digest"],
                  f"attempt {last_attempt} rank {rank} final state digest equals the reference's")
        else:
            check(False, f"attempt {last_attempt} rank {rank} recorded final parameters to compare")
    check(len(resumed_from) == 1, f"every rank resumed from the same checkpoint ({sorted(resumed_from)})")
    if len(resumed_from) == 1 and published:
        step, where = next(iter(resumed_from))
        # LATEST can name one step past the last checkpoint record, because rank 0 publishes before the barrier that precedes the record.
        check(published[-1] <= step <= reached,
              f"the resume step {step} ({where}) is the last published checkpoint of attempt 0 (last record {published[-1]}, reached {reached})")
        # The directory, not just the step: a step number matches any run's checkpoint of that step, its directory only
        # this run's. A step one past the last record has no record to name its directory, so only its prefix is checked.
        if step in published_dirs:
            check(where == published_dirs[step], f"the resume directory {where} is the one attempt 0 published for step {step}")
        else:
            check(where.startswith(f"a0/{step:08d}-"), f"the resume directory {where} is attempt 0's for step {step}")

    for line in passes:
        print(f"ok:   {line}")
    for line in failures:
        print(f"FAIL: {line}")
    print(f"{len(passes)} passed, {len(failures)} failed")
    if control:
        print(f"load-none control caught for the expected reason only: {'yes' if load_none_caught(failures) else 'no'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
