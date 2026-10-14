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


def pods_seen(arm_dir: str) -> dict[str, dict]:
    """Every Pod UID ever sampled, with the last sample of each."""
    seen: dict[str, dict] = {}
    try:
        with open(os.path.join(arm_dir, "pods.jsonl")) as handle:
            for line in handle:
                row = json.loads(line)
                seen[row["uid"]] = row
    except (OSError, ValueError):
        pass
    return seen


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
    try:
        with open(os.path.join(arm_dir, "timeline.jsonl")) as handle:
            for line in handle:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                value = (row.get("mltj") or {}).get("readyRanks")
                if value is not None:
                    best = value if best is None else max(best, value)
    except OSError:
        return False, "no timeline"
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
    good = sorted(verdicts) == [0, 1] and all(
        abs(v.get("observed_w_after_one_step", 99) - 0.4) < TOLERANCE and v.get("all_ranks_agree") is True and v.get("exit_code") == 0
        for v in verdicts.values()
    )
    return [
        two_pods_two_nodes(arm_dir),
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
    arms = [a for a in SCORERS if os.path.isdir(os.path.join(root, a))]
    if not arms:
        print("VOID  run: no arm directories")
        return 1
    all_pass = True
    for arm in arms:
        arm_dir = os.path.join(root, arm)
        if os.path.exists(os.path.join(arm_dir, "VOID")):
            print(f"VOID  {arm}: {open(os.path.join(arm_dir, 'VOID')).read().strip()}")
            all_pass = False
            continue
        results = SCORERS[arm](arm_dir, records(arm_dir))
        ok = all(r[0] for r in results)
        all_pass &= ok
        print(f"{'PASS' if ok else 'FAIL'}  {arm}")
        for passed, detail in results:
            print(f"      {'ok ' if passed else 'BAD'} {detail}")
    return 0 if all_pass else 1


if __name__ == "__main__":
    sys.exit(main())
