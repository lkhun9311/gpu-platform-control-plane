"""Evaluates H1 of the retarget stage: the controller's trigger-to-stop-confirmation interval of the rank-kill and dcgm cases.

    python3 experiments/distributed-restart/h1_retarget.py <run directory>

The registration is docs/superpowers/specs/2026-11-04-restart-retarget-design.md, "H1, registered before the run".
score_eks.py decides each case's verdict; this reads only whether the fault was delivered (ACCEPTED or FAILED, not VOID)
and then measures d from the final MLTrainingJob, cross-checked against the collector's timeline on another clock.
A case whose d cannot be established is INVALID with its reason, never dropped, and a slow stop is counted against H1
whatever happened to the recovery after it.

Exit 0 when an outcome was reached (any of the four), 2 when the run directory is not a retarget run.
"""

from __future__ import annotations

import json
import pathlib
import sys

import score_eks

H1_CASES = ("rank-kill-1", "rank-kill-2", "dcgm-1", "dcgm-2")
SUPPORT_S = 15
REFUTE_S = 30
# Each stamp is truncated to the whole second, so d carries up to 1 s from truncation.
# The collector's rows bracket each stamp between two of its own reads, on its own clock; 2 s beyond that bracket is
# allowed for the truncation and the request latency, and a d outside it means the controller's clock did not run
# continuously between the stamps (a restart on another host, a step adjustment), so d is not a measurement.
CROSS_CHECK_S = 2.0


def first_attempt(status: dict) -> dict:
    attempts = (status or {}).get("attempts") or []
    return attempts[0] if attempts and attempts[0].get("number") == 1 else {}


def bracket(rows: list[dict], field: str) -> tuple[float, float] | None:
    """The collector times of the last row without the stamp and the first row with it, or None if not bracketed."""
    before = None
    for r in rows:
        if first_attempt(r.get("status")).get(field):
            return (before, score_eks.epoch(r["observed"])) if before is not None else None
        before = score_eks.epoch(r["observed"])
    return None


def measure(case_dir: pathlib.Path) -> dict:
    """d and its evidence for one delivered case, or an INVALID reason, or a censored stop with its lower bound."""
    final = json.loads((case_dir / "final-mltj.json").read_text())
    a = first_attempt(final.get("status"))
    if not a:
        return {"invalid": "the final MLTrainingJob has no attempt numbered 1 first"}
    rows = score_eks.jsonl(case_dir / "timeline.jsonl")
    if not rows:
        return {"invalid": "no timeline, so d cannot be checked against a second clock"}
    failed, stopped = a.get("failureObservedAt"), a.get("stopConfirmedAt")
    if not failed:
        return {"invalid": "attempt 1 has no failureObservedAt"}
    if not stopped:
        # The barrier never confirmed a stop: the time from the trigger to the last row is a lower bound on d.
        seen = bracket(rows, "failureObservedAt")
        if seen is None:
            return {"invalid": "attempt 1 has no stopConfirmedAt, and its trigger is not bracketed by the timeline"}
        return {"censored_at_least_s": score_eks.epoch(rows[-1]["observed"]) - seen[1]}
    d = score_eks.epoch(stopped) - score_eks.epoch(failed)
    if d < 0:
        return {"invalid": f"stopConfirmedAt is {-d:.0f} s before failureObservedAt"}
    f, s = bracket(rows, "failureObservedAt"), bracket(rows, "stopConfirmedAt")
    if f is None or s is None:
        return {"invalid": "the timeline does not bracket both stamps between two of its reads"}
    lo, hi = s[0] - f[1] - CROSS_CHECK_S, s[1] - f[0] + CROSS_CHECK_S
    if not lo <= d <= hi:
        return {"invalid": f"d {d:.0f} s is outside the collector's {lo:.1f} to {hi:.1f} s, so the stamps are not on one clock"}
    waits = sorted({first_attempt(r.get("status")).get("waitingFor") or "" for r in rows} - {""})
    return {"d_s": d, "collector_s": [round(lo, 1), round(hi, 1)], "waitingFor": waits}


def outcome(results: dict[str, dict]) -> tuple[str, str]:
    """The registered outcome; a refutation is read first, because a slow stop is evidence whatever else is missing."""
    slow = [n for n, r in results.items()
            if r.get("d_s", -1) >= REFUTE_S or r.get("censored_at_least_s", -1) >= REFUTE_S]
    if slow:
        return "REFUTED", f"d is at least {REFUTE_S} s in {', '.join(slow)}"
    missing = [n for n in H1_CASES if "d_s" not in results.get(n, {})]
    if missing:
        return "NOT ASSESSED", f"no valid d in {', '.join(missing)}"
    if all(results[n]["d_s"] <= SUPPORT_S for n in H1_CASES):
        return "SUPPORTED", f"every d is at most {SUPPORT_S} s"
    return "INCONCLUSIVE", f"every d is below {REFUTE_S} s and some is above {SUPPORT_S} s"


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    run = pathlib.Path(argv[1])
    prov = score_eks.provenance(run)
    cases = prov.get("cases", "").split()
    if not set(H1_CASES) <= set(cases):
        print(f"REFUSED: {run} does not register all of {', '.join(H1_CASES)}")
        return 2
    steps, budget = int(prov["steps"]), int(prov["case_budget"])
    reference = None
    results: dict[str, dict] = {}
    for name in cases:
        case = score_eks.Case(run, name, reference, steps, budget)
        try:
            case.score()
            kind = "ACCEPTED"
        except score_eks.Verdict as v:
            kind = v.kind
        except (ValueError, KeyError, TypeError, IndexError, AttributeError, OSError):
            kind = "VOID"
        if name == "reference":
            reference = case.final_params(1)[0] if kind == "ACCEPTED" else None
        if name not in H1_CASES:
            continue
        if kind not in ("ACCEPTED", "FAILED"):
            results[name] = {"verdict": kind, "invalid": "the scorer did not find the fault delivered"}
            continue
        try:
            results[name] = {"verdict": kind, **measure(run / name)}
        except (ValueError, KeyError, TypeError, OSError) as exc:
            results[name] = {"verdict": kind, "invalid": f"its evidence could not be read: {type(exc).__name__}: {exc}"}
    for name in H1_CASES:
        print(f"{name:12} {json.dumps(results.get(name, {'invalid': 'not run'}), sort_keys=True)}")
    result, why = outcome(results)
    print(f"H1 {result}: {why}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
