"""Evaluates H1 of the retarget stage: the controller's trigger-to-stop-confirmation interval of the rank-kill and dcgm cases.

    python3 experiments/distributed-restart/h1_retarget.py <run directory>

The registration is docs/superpowers/specs/2026-11-04-restart-retarget-design.md, "H1, registered before the run".
A case counts when score_eks.py's own delivery check finds its fault delivered, whatever the recovery after it did, and
d is then read from the final MLTrainingJob and checked against the collector's timeline.
A case whose d cannot be established is INVALID with its reason, never dropped, and a slow stop is counted against H1
whatever happened to the recovery after it.

Exit 0 when an outcome was reached (any of the four), 2 when the run is refused or is not a retarget run.
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
# The collector's reads bracket each stamp between two of them, on the collector's clock; 2 s beyond that bracket is
# allowed for the truncation and the request latency.
# A d outside it cannot be one clock's interval; a d inside it is only consistent, to the width of the bracket.
CROSS_CHECK_S = 2.0


def attempt_one(status: object) -> dict | None:
    """Attempt 1 of a status, {} when the status has no attempt yet, None when it is not a well-formed read.

    A malformed read once counted as a successful one without either stamp, and a lone one after the trigger set a
    lower bound on a stop no read could have shown (codex review of 083a84cb).
    """
    if not isinstance(status, dict):
        return None
    attempts = status.get("attempts")
    if attempts in (None, []):
        return {}
    if not isinstance(attempts, list) or not all(isinstance(x, dict) for x in attempts):
        return None
    return attempts[0] if attempts[0].get("number") == 1 else None


def reads(rows: list[dict]) -> list[tuple[float, dict, list]]:
    """The collector's successful reads: its time, attempt 1, and every attempt; a failed read shows nothing either way."""
    out = []
    for r in rows:
        status = r.get("status") if isinstance(r, dict) else None
        a = attempt_one(status)
        if a is None:
            continue
        out.append((score_eks.epoch(r["observed"]), a, status.get("attempts") or []))
    return out


def bracket(seen: list[tuple[float, dict, list]], field: str) -> tuple[float, float] | None:
    """The times of the last read without the stamp and the first read with it, or None if not bracketed."""
    before = None
    for t, a, _ in seen:
        if a.get(field):
            return (before, t) if before is not None else None
        before = t
    return None


def measure(case_dir: pathlib.Path) -> dict:
    """d and its evidence for one delivered case, or an INVALID reason, or a never-confirmed stop with its lower bound."""
    final = json.loads((case_dir / "final-mltj.json").read_text())
    a = attempt_one(final.get("status") if isinstance(final, dict) else None)
    if not a:
        return {"invalid": "the final MLTrainingJob has no attempt numbered 1 first"}
    seen = reads(score_eks.jsonl(case_dir / "timeline.jsonl"))
    if not seen:
        return {"invalid": "no timeline read, so d cannot be checked against a second clock"}
    failed, stopped = a.get("failureObservedAt"), a.get("stopConfirmedAt")
    if not failed:
        return {"invalid": "attempt 1 has no failureObservedAt"}
    if not stopped:
        # Only a stop no read ever showed, with no later attempt anywhere, is one that did not happen while observed.
        later = (final.get("status") or {}).get("attempts") or []
        if len(later) > 1 or any(x.get("stopConfirmedAt") or len(all_) > 1 for _, x, all_ in seen):
            return {"invalid": "the final MLTrainingJob lacks a stop that the timeline or a later attempt shows"}
        f = bracket(seen, "failureObservedAt")
        if f is None:
            return {"invalid": "attempt 1 has no stopConfirmedAt, and its trigger is not bracketed by the timeline"}
        return {"censored_at_least_s": seen[-1][0] - f[1]}
    d = score_eks.epoch(stopped) - score_eks.epoch(failed)
    if d < 0:
        return {"invalid": f"stopConfirmedAt is {-d:.0f} s before failureObservedAt"}
    f, s = bracket(seen, "failureObservedAt"), bracket(seen, "stopConfirmedAt")
    if f is None or s is None:
        return {"invalid": "the timeline does not bracket both stamps between two of its reads"}
    lo, hi = s[0] - f[1] - CROSS_CHECK_S, s[1] - f[0] + CROSS_CHECK_S
    if not lo <= d <= hi:
        return {"invalid": f"d {d:.0f} s is outside the collector's {lo:.1f} to {hi:.1f} s, so the stamps are not on one clock"}
    waits = sorted({x.get("waitingFor") or "" for _, x, _ in seen} - {""})
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


def delivered(case: score_eks.Case) -> str:
    """'' when score_eks.py's delivery check passes, else why not; nothing after delivery is consulted."""
    try:
        case.load()
        case.bind()
        case.check_delivered()
    except score_eks.Verdict as v:
        return f"the fault is not shown delivered: {v.reason}"
    except (ValueError, KeyError, TypeError, IndexError, AttributeError, OSError) as exc:
        return f"its delivery evidence could not be read: {type(exc).__name__}: {str(exc)[:120]}"
    return ""


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    run = pathlib.Path(argv[1])
    prov = score_eks.provenance(run)
    # The scorer's run-level refusals are this evaluator's too: a dirty tree or an unapproved trainer is no run.
    refusals = score_eks.run_refusals(prov)
    if refusals:
        for r in refusals:
            print(f"REFUSED: {r}")
        return 2
    cases = prov.get("cases", "").split()
    if not set(H1_CASES) <= set(cases):
        print(f"REFUSED: {run} does not register all of {', '.join(H1_CASES)}")
        return 2
    try:
        steps, budget = int(prov["steps"]), int(prov["case_budget"])
    except (KeyError, ValueError) as exc:
        print(f"REFUSED: the provenance's steps or case_budget cannot be read: {exc}")
        return 2
    reference = None
    results: dict[str, dict] = {}
    for name in cases:
        # The scorer's verdict is reported beside d, and the reference it needs is carried as score_eks.py carries it.
        case = score_eks.Case(run, name, reference, steps, budget)
        try:
            case.score()
            verdict = "ACCEPTED"
        except score_eks.Verdict as v:
            verdict = v.kind
        except (ValueError, KeyError, TypeError, IndexError, AttributeError, OSError):
            verdict = "VOID"
        if name == "reference":
            reference = case.final_params(1)[0] if verdict == "ACCEPTED" else None
        if name not in H1_CASES:
            continue
        why = delivered(score_eks.Case(run, name, reference, steps, budget))
        if why:
            results[name] = {"verdict": verdict, "invalid": why}
            continue
        try:
            results[name] = {"verdict": verdict, **measure(run / name)}
        except (ValueError, KeyError, TypeError, IndexError, AttributeError, OSError) as exc:
            results[name] = {"verdict": verdict, "invalid": f"its evidence could not be read: {type(exc).__name__}: {str(exc)[:120]}"}
    for name in H1_CASES:
        print(f"{name:12} {json.dumps(results.get(name, {'invalid': 'not run'}), sort_keys=True)}")
    result, why = outcome(results)
    print(f"H1 {result}: {why}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
