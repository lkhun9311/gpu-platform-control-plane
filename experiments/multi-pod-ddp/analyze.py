"""Scores a multi-Pod DDP run against experiments/multi-pod-ddp/README.md.

Every criterion is evaluated from the evidence directory hack/multi-pod-ddp.sh wrote, and a criterion whose evidence
is missing fails: absence is never read as a pass.

Usage: python3 experiments/multi-pod-ddp/analyze.py <evidence dir>
Exits 0 only if every arm that ran is PASS and none is void.
"""

from __future__ import annotations

import datetime
import glob
import json
import os
import sys

BUDGET = 300
TOLERANCE = 1e-6


def ts(value: str) -> datetime.datetime:
    """Parses both the API server's whole-second times and train.py's fractional ones."""
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def second(value: datetime.datetime) -> datetime.datetime:
    """Truncates to the second, the API server's resolution, before comparing against one of its times."""
    return value.replace(microsecond=0)


def load_json(path: str):
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def records(arm_dir: str) -> dict[str, list[dict]]:
    """The JSON records of every Pod's log, keyed by Pod UID."""
    out: dict[str, list[dict]] = {}
    for path in glob.glob(os.path.join(arm_dir, "log-*.txt")):
        uid = os.path.basename(path)[len("log-"):-len(".txt")]
        rows = []
        with open(path) as handle:
            for line in handle:
                line = line.strip()
                if line.startswith("{"):
                    try:
                        rows.append(json.loads(line))
                    except ValueError:
                        continue
        out[uid] = rows
    return out


def by_rank(recs: dict[str, list[dict]], event: str) -> dict[int, dict]:
    """The first record of an event per rank; a rank with two Pods would show as a duplicate and fail elsewhere."""
    found: dict[int, dict] = {}
    for rows in recs.values():
        for row in rows:
            if row.get("event") == event and row.get("rank") not in found:
                found[row["rank"]] = row
    return found


class Unreadable(Exception):
    """Evidence that exists and cannot be parsed; it fails the criterion that needs it, by name."""


def jsonl(arm_dir: str, name: str) -> list[dict]:
    """Every line of a sample file, refusing the file if any line does not parse.

    The first scorer skipped lines it could not parse, and a harness that split each record across two lines left it
    reading no readyRanks at all -- a refusal that said the platform had not reported something it had.
    """
    path = os.path.join(arm_dir, name)
    try:
        with open(path) as handle:
            lines = handle.read().splitlines()
    except OSError as exc:
        raise Unreadable(f"{name}: {exc}") from exc
    rows = []
    for n, line in enumerate(lines, 1):
        try:
            rows.append(json.loads(line))
        except ValueError as exc:
            raise Unreadable(f"{name} line {n} does not parse: {exc}") from exc
    return rows


def pods_seen(arm_dir: str) -> dict[str, dict]:
    """Every Pod UID ever sampled, with the last sample of each."""
    return {row["uid"]: row for row in jsonl(arm_dir, "pods.jsonl")}


# The records each rank must have left, per arm, beyond the ones a criterion reads.
#
# Without them a log holding only verdict lines passed: the arithmetic was read, and nothing said a rendezvous or
# a step had happened in that Pod.
REQUIRED = {
    "pass": {0: ("rendezvous_start", "rendezvous", "step", "verdict"), 1: ("rendezvous_start", "rendezvous", "step", "verdict")},
    "no-sync": {0: ("rendezvous_start", "rendezvous", "step", "verdict"), 1: ("rendezvous_start", "rendezvous", "step", "verdict")},
    "bad-address": {0: ("rendezvous_start",), 1: ("rendezvous_start",)},
    "one-rank-fails": {0: ("rendezvous", "verdict", "holding", "sigterm"), 1: ("rendezvous", "verdict", "fail_injected")},
}


def ranks_bound_to_pods(arm: str, arm_dir: str, recs: dict[str, list[dict]]) -> tuple[bool, str]:
    """Each sampled Pod has its own log, and that log is one rank: the Pod's completion index, under this run's id.

    Records used to be pooled across logs by the rank they claimed, so both ranks' lines merged under one invented
    Pod UID still passed: nothing tied a rank to the Pod that was supposed to have run it.
    """
    try:
        name = open(os.path.join(arm_dir, "name")).read().strip()
    except OSError:
        return False, "no name file, so no run id to bind records to"
    seen = pods_seen(arm_dir)
    problems = []
    stray = sorted(set(recs) - set(seen))
    if stray:
        problems.append(f"logs for Pods never sampled: {stray}")
    for uid, pod in sorted(seen.items(), key=lambda kv: str(kv[1].get("index"))):
        index = pod.get("index")
        rows = recs.get(uid) or []
        if not rows:
            problems.append(f"index {index}: no log")
            continue
        ranks = {r.get("rank") for r in rows}
        if ranks != {int(index)}:
            problems.append(f"index {index}: log carries ranks {sorted(map(str, ranks))}")
            continue
        runs = {r.get("run_id") for r in rows}
        if runs != {name}:
            problems.append(f"index {index}: run ids {sorted(map(str, runs))}, want {name}")
        hosts = {r.get("hostname") for r in rows if r.get("event") == "rendezvous_start"}
        if hosts and hosts != {f"{name}-{index}"}:
            problems.append(f"index {index}: hostname {sorted(map(str, hosts))}, want {name}-{index}")
        events = {r.get("event") for r in rows}
        missing = [e for e in REQUIRED[arm].get(int(index), ()) if e not in events]
        if missing:
            problems.append(f"index {index}: missing {missing}")
    return not problems, "each Pod's log is its own rank" if not problems else "; ".join(problems)


def condition(obj, kind: str):
    for c in (obj or {}).get("status", {}).get("conditions") or []:
        if c.get("type") == kind and c.get("status") == "True":
            return c
    return None


def terminal_within_budget(mltj, phase: str) -> tuple[bool, str]:
    if not mltj:
        return False, "no final MLTrainingJob"
    status = mltj.get("status", {})
    if status.get("phase") != phase:
        return False, f"phase {status.get('phase')!r}, want {phase}"
    took = (ts(status["lastTransitionTime"]) - ts(mltj["metadata"]["creationTimestamp"])).total_seconds()
    if took > BUDGET:
        return False, f"{phase} after {took:.0f} s, over the {BUDGET} s budget"
    return True, f"{phase} after {took:.0f} s"


def two_pods_two_nodes(arm_dir: str) -> tuple[bool, str]:
    seen = pods_seen(arm_dir)
    indexes = sorted(str(p.get("index")) for p in seen.values())
    nodes = {p.get("node") for p in seen.values()}
    ok = len(seen) == 2 and indexes == ["0", "1"] and None not in nodes and len(nodes) == 2
    return ok, f"{len(seen)} pod(s), indexes {indexes}, nodes {sorted(str(n) for n in nodes)}"


def ready_ranks_seen(arm_dir: str) -> tuple[bool, str]:
    best = None
    for row in jsonl(arm_dir, "timeline.jsonl"):
        value = (row.get("mltj") or {}).get("readyRanks")
        if value is not None:
            best = value if best is None else max(best, value)
    return best is not None and best >= 1, f"highest readyRanks sampled {best}"


def one_workload(arm_dir: str) -> tuple[bool, str]:
    job = load_json(os.path.join(arm_dir, "final-job.json"))
    wls = load_json(os.path.join(arm_dir, "final-workloads.json"))
    if not job or not wls:
        return False, "no final Job or Workload list"
    uid = job["metadata"]["uid"]
    owned = [w for w in wls.get("items", []) if any(r.get("uid") == uid for r in w["metadata"].get("ownerReferences", []))]
    if len(owned) != 1:
        return False, f"{len(owned)} Workloads owned by the Job"
    wl = owned[0]
    podsets = wl["spec"].get("podSets", [])
    assigns = (wl.get("status", {}).get("admission") or {}).get("podSetAssignments", [])
    gpus = assigns[0].get("resourceUsage", {}).get("nvidia.com/gpu") if len(assigns) == 1 else None
    ok = len(podsets) == 1 and podsets[0].get("count") == 2 and str(gpus) == "2"
    return ok, f"pod sets {[p.get('count') for p in podsets]}, admitted nvidia.com/gpu {gpus!r}"


def score_pass(arm_dir: str, recs) -> list[tuple[bool, str]]:
    verdicts = by_rank(recs, "verdict")
    steps = by_rank(recs, "step")
    good = sorted(verdicts) == [0, 1] and all(
        abs(v.get("observed_w_after_one_step", 99) - 0.4) < TOLERANCE and v.get("all_ranks_agree") is True and v.get("exit_code") == 0
        for v in verdicts.values()
    )
    # The all-reduce's future completing in step 1, which is what says the collective ran rather than was requested.
    reduced = sorted(steps) == [0, 1] and all(s.get("step") == 1 and (s.get("futures_completed_this_step") or 0) >= 1 for s in steps.values())
    return [
        two_pods_two_nodes(arm_dir),
        (reduced, "step-1 all-reduce completions by rank " + str([(r, s.get("futures_completed_this_step")) for r, s in sorted(steps.items())])),
        (good, f"verdicts from ranks {sorted(verdicts)}: " + "; ".join(
            f"rank {r} w={v.get('observed_w_after_one_step')} agree={v.get('all_ranks_agree')} exit={v.get('exit_code')}"
            for r, v in sorted(verdicts.items()))),
        one_workload(arm_dir),
        terminal_within_budget(load_json(os.path.join(arm_dir, "final-mltj.json")), "Succeeded"),
        ready_ranks_seen(arm_dir),
    ]


def score_no_sync(arm_dir: str, recs) -> list[tuple[bool, str]]:
    steps = {r: row for r, row in by_rank(recs, "step").items()}
    verdicts = by_rank(recs, "verdict")
    want = {0: 0.2, 1: 0.6}
    diverged = sorted(steps) == [0, 1] and all(abs(steps[r].get("w_after_step", 99) - w) < TOLERANCE for r, w in want.items())
    disagree = sorted(verdicts) == [0, 1] and all(v.get("all_ranks_agree") is False for v in verdicts.values())
    return [
        two_pods_two_nodes(arm_dir),
        (diverged and disagree, f"step-1 w by rank {[(r, s.get('w_after_step')) for r, s in sorted(steps.items())]}, "
                                f"agree {[v.get('all_ranks_agree') for _, v in sorted(verdicts.items())]}"),
        terminal_within_budget(load_json(os.path.join(arm_dir, "final-mltj.json")), "Succeeded"),
        ready_ranks_seen(arm_dir),
    ]


def score_bad_address(arm_dir: str, recs) -> list[tuple[bool, str]]:
    failed_job = condition(load_json(os.path.join(arm_dir, "final-job.json")), "Failed")
    causal = by_rank(recs, "rendezvous_failed")
    return [
        (failed_job is not None, f"Job Failed condition {'present' if failed_job else 'absent'}"),
        terminal_within_budget(load_json(os.path.join(arm_dir, "final-mltj.json")), "Failed"),
        (len(causal) >= 1, f"rendezvous_failed from ranks {sorted(causal)}"
                           + "".join(f"; rank {r}: {v.get('error_type')}" for r, v in sorted(causal.items()))),
    ]


def score_one_rank_fails(arm_dir: str, recs) -> list[tuple[bool, str]]:
    job = load_json(os.path.join(arm_dir, "final-job.json"))
    hold = by_rank(recs, "holding").get(0)
    fail = by_rank(recs, "fail_injected").get(1)
    sig = by_rank(recs, "sigterm").get(0)
    target = condition(job, "FailureTarget")
    failed = condition(job, "Failed")
    missing = [n for n, v in (("rank 0 holding", hold), ("rank 1 fail_injected", fail), ("FailureTarget", target),
                              ("rank 0 sigterm", sig), ("Job Failed", failed)) if v is None]
    if missing:
        order = (False, f"missing: {', '.join(missing)}")
    else:
        t_hold, t_fail, t_sig = ts(hold["ts"]), ts(fail["ts"]), ts(sig["ts"])
        t_target, t_failed = ts(target["lastTransitionTime"]), ts(failed["lastTransitionTime"])
        steps = [
            ("holding before fail_injected", t_hold < t_fail),
            ("fail_injected not after FailureTarget", second(t_fail) <= t_target),
            ("FailureTarget reason BackoffLimitExceeded", target.get("reason") == "BackoffLimitExceeded"),
            ("FailureTarget not after sigterm", t_target <= second(t_sig)),
            ("sigterm not after Failed", second(t_sig) <= t_failed),
        ]
        bad = [n for n, ok in steps if not ok]
        order = (not bad, f"hold {hold['ts']}, fail {fail['ts']}, FailureTarget {target['lastTransitionTime']} "
                          f"({target.get('reason')}), sigterm {sig['ts']}, Failed {failed['lastTransitionTime']}"
                          + (f"; out of order: {bad}" if bad else ""))
    return [order, terminal_within_budget(load_json(os.path.join(arm_dir, "final-mltj.json")), "Failed")]


SCORERS = {
    "pass": score_pass,
    "no-sync": score_no_sync,
    "bad-address": score_bad_address,
    "one-rank-fails": score_one_rank_fails,
}


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    root = sys.argv[1]
    if os.path.exists(os.path.join(root, "VOID")):
        print(f"VOID  run: setup failed at: {open(os.path.join(root, 'VOID')).read().strip()}")
        return 1
    # The arms come from what the run was asked to do, not from the directories it left.
    # Read from the directories, a run stopped between arms scored only the arms it reached and could exit 0.
    requested = None
    try:
        with open(os.path.join(root, "provenance.txt")) as handle:
            for line in handle:
                if line.startswith("arms="):
                    requested = line[len("arms="):].split()
    except OSError:
        pass
    if not requested:
        print("VOID  run: provenance.txt names no requested arms")
        return 1
    unknown = [a for a in requested if a not in SCORERS]
    if unknown:
        print(f"VOID  run: no scorer for requested arms {unknown}")
        return 1
    all_pass = True
    for arm in requested:
        arm_dir = os.path.join(root, arm)
        if not os.path.isdir(arm_dir):
            print(f"VOID  {arm}: requested and never run")
            all_pass = False
            continue
        if os.path.exists(os.path.join(arm_dir, "VOID")):
            print(f"VOID  {arm}: {open(os.path.join(arm_dir, 'VOID')).read().strip()}")
            all_pass = False
            continue
        try:
            recs = records(arm_dir)
            results = [ranks_bound_to_pods(arm, arm_dir, recs)] + SCORERS[arm](arm_dir, recs)
        except Unreadable as exc:
            results = [(False, f"unreadable evidence: {exc}")]
        ok = all(r[0] for r in results)
        all_pass &= ok
        print(f"{'PASS' if ok else 'FAIL'}  {arm}")
        for passed, detail in results:
            print(f"      {'ok ' if passed else 'BAD'} {detail}")
    return 0 if all_pass else 1


if __name__ == "__main__":
    sys.exit(main())
