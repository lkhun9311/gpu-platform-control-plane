"""Splits each accepted restart case's recovery, from a paid session's run directory, into the moments it passed.

    python3 experiments/distributed-restart/phases_eks.py <run directory>

score_eks.py gives one figure per case, from the fault to the first step every rank of attempt 2 took. In full's
termination cases most of it passed before the runner first read EC2's state as terminated
(hack/distributed-restart-eks/2026-11-04-full/README.md), an interval that is not a measurement of the guest's shutdown;
this reads the records again and prints, for each case, the stamp difference from the fault of each recorded milestone:

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
The cluster's stamps are whole seconds from the API server and the controller, whose offset from the runner's clock
nothing here measures, so a milestone on one is marked; the mark names that limitation and is not a one-second error
bound. A difference between two clocks is not a duration either clock saw, and is printed as the difference it is.
The milestones come from different components and need not fall in the order they are printed in.
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
    """Each milestone of an accepted case as its stamp's difference from the fault.

    The nodes' stamps carry the scorer's correction to the runner's clock; the cluster's keep their unmeasured offset.
    """
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
    # The scorer's own refusals: a run it will not score at all has no accepted case to split (codex review of defd5006).
    refusals = score_eks.run_refusals(prov)
    if refusals:
        for r in refusals:
            print(f"REFUSED: {r}")
        return 2
    # By kind and by the class the scorer gave, because a terminate-spare that recovered on a replacement took the
    # replacement's path, which the scorer summarises apart and a pooled median would hide (codex review of defd5006).
    # And by core-limit arm, as the scorer's summary is, since corelimit's treated and untreated rank-kill cases pooled
    # gave a median of neither arm (gpt-6-astra's attack before the corelimit run).
    by_kind: dict[tuple[str, str, str | None], list[dict[str, float]]] = {}
    reference = None
    for name in prov.get("cases", "").split():
        case = score_eks.Case(run, name, reference, int(prov["steps"]), int(prov["case_budget"]))
        # Evidence that cannot be read is that case's, as in the scorer, never the end of the report.
        try:
            case.score()
            if name == "reference":
                reference = case.final_params(1)[0]
                continue
            if len(case.attempts) < 2 or "recovery_s" not in case.figures:
                print(f"{name}: not split, it has no recovery")
                continue
            at = moments(case)
        except score_eks.Verdict as v:
            print(f"{name}: not split, {v.kind}: {v.reason[:120]}")
            continue
        except (ValueError, KeyError, TypeError, IndexError, AttributeError, OSError) as exc:
            print(f"{name}: not split, its evidence could not be read: {type(exc).__name__}: {str(exc)[:100]}")
            continue
        by_kind.setdefault((case.kind, str(case.figures.get("class")), case.spec.get("core_limit")), []).append(at)
        line = "  ".join(f"{m} +{at[m]:.1f}{'*' if m in CLUSTER_CLOCK else ''}" for m in MOMENTS if m in at)
        print(f"{name} ({case.figures.get('class')}): {line}")
    print("medians of stamp differences from the fault, in seconds "
          "(* a whole-second cluster stamp, its offset from the runner unmeasured):")
    for (kind, cls, arm), rows in by_kind.items():
        line = "  ".join(f"{m} +{statistics.median(r[m] for r in rows):.1f}{'*' if m in CLUSTER_CLOCK else ''}"
                         for m in MOMENTS if all(m in r for r in rows))
        # The arm is named where the kind ran two, so a run of one arm reads as it did before corelimit.
        arms = {a for k, _, a in by_kind if k == kind}
        label = f"{cls}, core limit {arm}" if len(arms) > 1 else cls
        print(f"  {kind}/{label} (n={len(rows)}): {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
