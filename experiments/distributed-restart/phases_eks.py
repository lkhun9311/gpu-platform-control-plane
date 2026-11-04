"""Splits each accepted restart case's recovery, from a paid session's run directory, into the moments it passed.

    python3 experiments/distributed-restart/phases_eks.py <run directory>

score_eks.py gives one figure per case, from the fault to the first step every rank of attempt 2 took. Most of a
termination's figure was EC2's own shutdown (hack/distributed-restart-eks/2026-11-04-full/README.md), and the rest
could not be told apart without reading the records again; this reads them again and prints, for each case, when each
of these moments came after the fault:

    trigger      the controller saw what ended attempt 1          status.attempts[0].failureObservedAt   cluster clock
    terminated   EC2 first described the instance as terminated   marks.jsonl terminated-read            runner clock
    fenced       the runner wrote the fence                       marks.jsonl fenced                     runner clock
    stopped      the stop barrier was satisfied                   status.attempts[0].stopConfirmedAt     cluster clock
    created      attempt 2's Job was created                      status.attempts[1].createdAt           cluster clock
    pods seen    the last of attempt 2's rank Pods was seen        pods.jsonl, attempt token 2           runner clock
    ready        every rank of attempt 2 was Ready                 status.attempts[1].allRanksReadyAt    cluster clock
    resumed      the last rank wrote its resume record             the ranks' logs                       node clocks, corrected
    stepped      the last rank's first step, the scored recovery   score_eks.py's recovery_s             node clocks, corrected

Only cases score_eks.py ACCEPTED are split, with its own clock correction and fault time, so a phase is never read
from records the scorer refused.
The cluster's stamps are whole seconds from the API server and the controller, which nothing here measures against
the runner's clock, so a phase that ends or starts on one is known to about a second, and is marked so; a phase
measured between two clocks is not a duration either clock saw, and is printed as the difference it is.
"""

from __future__ import annotations

import importlib.util
import pathlib
import statistics
import sys

HERE = pathlib.Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("score_eks", HERE / "score_eks.py")
score_eks = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(score_eks)

# The order a recovery passes them in; one a case does not have (no termination, no fence) is left out of it.
MOMENTS = ("trigger", "terminated", "fenced", "stopped", "created", "pods seen", "ready", "resumed", "stepped")
# Whole-second stamps from the cluster: a moment on one is marked, because its error is the truncation and an
# unmeasured clock offset, not the runner's.
CLUSTER_CLOCK = {"trigger", "stopped", "created", "ready"}


def moments(case) -> dict[str, float]:
    """Each moment of an accepted case as seconds after its fault, on the runner's clock."""
    fault, _ = case.fault_time()
    first, second = case.attempts[0], case.attempts[1]
    out: dict[str, float] = {}
    for name, stamp in (("trigger", first.get("failureObservedAt")), ("stopped", first.get("stopConfirmedAt")),
                        ("created", second.get("createdAt")), ("ready", second.get("allRanksReadyAt"))):
        if stamp:
            out[name] = score_eks.epoch(stamp) - fault
    for name, mark in (("terminated", "terminated-read"), ("fenced", "fenced")):
        if mark in case.marks:
            out[name] = score_eks.epoch(case.marks[mark]) - fault
    seen = [score_eks.epoch(p["observed"]) for p in case.pods.values() if str(p.get("attempt_token")) == "2"]
    if seen:
        out["pods seen"] = max(seen) - fault
    resumes = case.rec("resume", 2)
    if resumes:
        out["resumed"] = max(case.runner_time(r) for r in resumes) - fault
    out["stepped"] = case.figures["recovery_s"]
    return out


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    run = pathlib.Path(argv[1])
    prov = score_eks.provenance(run)
    if not prov.get("steps", "").isdigit() or not prov.get("case_budget", "").isdigit():
        print("REFUSED: the run's provenance names no step count or case budget", file=sys.stderr)
        return 2
    by_kind: dict[str, list[dict[str, float]]] = {}
    reference = None
    for name in prov.get("cases", "").split():
        case = score_eks.Case(run, name, reference, int(prov["steps"]), int(prov["case_budget"]))
        try:
            case.score()
        except score_eks.Verdict as v:
            print(f"{name}: not split, {v.kind}: {v.reason[:120]}")
            continue
        if name == "reference":
            reference = case.final_params(1)[0]
            continue
        if len(case.attempts) < 2 or "recovery_s" not in case.figures:
            print(f"{name}: not split, it has no recovery")
            continue
        at = moments(case)
        by_kind.setdefault(case.kind, []).append(at)
        line = "  ".join(f"{m} +{at[m]:.1f}{'*' if m in CLUSTER_CLOCK else ''}" for m in MOMENTS if m in at)
        print(f"{name} ({case.figures.get('class')}): {line}")
    print("medians, seconds after the fault (* a whole-second cluster stamp):")
    for kind, rows in by_kind.items():
        line = "  ".join(f"{m} +{statistics.median(r[m] for r in rows):.1f}{'*' if m in CLUSTER_CLOCK else ''}"
                         for m in MOMENTS if all(m in r for r in rows))
        print(f"  {kind} (n={len(rows)}): {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
