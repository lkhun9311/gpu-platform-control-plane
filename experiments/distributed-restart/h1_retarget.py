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
# How far the controller's observed failure may lie from the fault it is to be the trigger of, in raw seconds.
# On both paid archives and the kind rehearsal it came 0.5 to 3.0 s after the fault; up to 2 s before allows a whole-second stamp and a node clock
# the probes keep within that of the controller's, and 60 s after is a bound no stop barrier of this stage came near.
CHRONOLOGY_AFTER_S = 2.0
CHRONOLOGY_BEFORE_S = 60.0
# The attempt state the controller writes with stopConfirmedAt, in internal/controller/mltrainingjob_restart.go.
STOPPED = "Stopped"


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


def reads(path: pathlib.Path) -> list[tuple[float, dict, list]]:
    """The collector's successful reads: its time, attempt 1, and every attempt; a failed read shows nothing either way.

    The rows are those score_eks.timeline_reads keeps, row by row, so this and the scorer skip the same failed and
    malformed reads, a row that is not JSON and one whose time cannot be read among them.
    """
    return [(seen, (status.get("attempts") or [{}])[0], status.get("attempts") or [])
            for seen, status in score_eks.timeline_reads(path)]


def contradicted(seen: list[tuple[float, dict, list]], final: dict, field: str) -> str:
    """Why the reads contradict the final object's stamp, or ''.

    A stamp is set once: every read that shows it shows the final object's value, and none after it shows it gone.
    Only whether a read showed the stamp was compared, so a final stop moved to 20 s after the trigger, the reads
    showing it at 1 s, gave d = 20 inside the bracket (codex gpt-6-astra attack of the retarget registration).
    """
    values = [(t, a.get(field)) for t, a, _ in seen]
    shown = [v for _, v in values if v]
    if any(v != final.get(field) for v in shown):
        return f"the timeline shows {field} as {sorted(set(shown))}, the final object as {final.get(field)!r}"
    first = next((i for i, (_, v) in enumerate(values) if v), None)
    if first is not None and not all(v for _, v in values[first:]):
        return f"the timeline shows {field} and then a read without it"
    return ""


def bracket(seen: list[tuple[float, dict, list]], field: str) -> tuple[float, float] | None:
    """The times of the last read without the stamp and the first read with it, or None if not bracketed."""
    before = None
    for t, a, _ in seen:
        if a.get(field):
            return (before, t) if before is not None else None
        before = t
    return None


def measure(case_dir: pathlib.Path, later_ran: bool = False) -> dict:
    """d and its evidence for one delivered case, or an INVALID reason, or a never-confirmed stop with its observed span.

    later_ran says the case's own logs or Pods show an attempt after the first, which only a confirmed stop allows.
    """
    final = json.loads((case_dir / "final-mltj.json").read_text())
    a = attempt_one(final.get("status") if isinstance(final, dict) else None)
    if not a:
        return {"invalid": "the final MLTrainingJob has no attempt numbered 1 first"}
    seen = reads(case_dir / "timeline.jsonl")
    if not seen:
        return {"invalid": "no timeline read, so d cannot be checked against a second clock"}
    failed, stopped = a.get("failureObservedAt"), a.get("stopConfirmedAt")
    if not failed:
        return {"invalid": "attempt 1 has no failureObservedAt"}
    # The trigger is checked against the reads before either branch: the missing-stop branch once returned its bound
    # first, so a trigger that changed value or vanished still gave a 60 s refutation (fifth attack).
    why = contradicted(seen, a, "failureObservedAt")
    if why:
        return {"invalid": why}
    if not stopped:
        # Only a stop no read ever showed, with no later attempt anywhere, is one that did not happen while observed.
        later = (final.get("status") or {}).get("attempts") or []
        if len(later) > 1 or any(x.get("stopConfirmedAt") or len(all_) > 1 for _, x, all_ in seen):
            return {"invalid": "the final MLTrainingJob lacks a stop that the timeline or a later attempt shows"}
        if later_ran:
            return {"invalid": "the final MLTrainingJob lacks a stop, and the case's logs or Pods show a later attempt ran"}
        # The controller writes the state and the stamp in one update, so a Stopped attempt without the stamp is a
        # contradiction, not a stop that never came (sixth attack, 3).
        if a.get("state") == STOPPED or any(x.get("state") == STOPPED for _, x, _ in seen):
            return {"invalid": "attempt 1 is shown Stopped without a stopConfirmedAt"}
        f = bracket(seen, "failureObservedAt")
        if f is None:
            return {"invalid": "attempt 1 has no stopConfirmedAt, and its trigger is not bracketed by the timeline"}
        # Described, never a bound: the span is two readings of the collector's wall clock, which a jump moves while the
        # controller's evidence stays the same (sixth attack, 4).
        return {"unpublished_stop_observed_s": round(seen[-1][0] - f[1], 1)}
    d = score_eks.epoch(stopped) - score_eks.epoch(failed)
    if d < 0:
        return {"invalid": f"stopConfirmedAt is {-d:.0f} s before failureObservedAt"}
    for field in ("failureObservedAt", "stopConfirmedAt"):
        why = contradicted(seen, a, field)
        if why:
            return {"invalid": why}
    f, s = bracket(seen, "failureObservedAt"), bracket(seen, "stopConfirmedAt")
    if f is None or s is None:
        return {"invalid": "the timeline does not bracket both stamps between two of its reads"}
    lo, hi = s[0] - f[1] - CROSS_CHECK_S, s[1] - f[0] + CROSS_CHECK_S
    if not lo <= d <= hi:
        return {"invalid": f"d {d:.0f} s is outside the collector's {lo:.1f} to {hi:.1f} s, so the stamps are not on one clock"}
    waits = sorted({x.get("waitingFor") or "" for _, x, _ in seen} - {""})
    return {"d_s": d, "collector_s": [round(lo, 1), round(hi, 1)], "waitingFor": waits}


def outcome(results: dict[str, dict]) -> tuple[str, str]:
    """The registered outcome, decided over valid d alone.

    A refutation is read first, because a slow stop is evidence whatever else is missing.
    A stop never published gives no d and so cannot refute: the span it was watched for is on the collector's wall
    clock, and a jump of that clock alone once turned a 2 s observation into a 62 s refutation (sixth attack, 4).
    """
    slow = [n for n, r in results.items() if r.get("d_s", -1) >= REFUTE_S]
    if slow:
        return "REFUTED", f"d is at least {REFUTE_S} s in {', '.join(slow)}"
    missing = [n for n in H1_CASES if "d_s" not in results.get(n, {})]
    if missing:
        unpublished = [n for n in missing if "unpublished_stop_observed_s" in results.get(n, {})]
        why = f"no valid d in {', '.join(missing)}"
        return "NOT ASSESSED", why + (f"; no stop was published while observed in {', '.join(unpublished)}" if unpublished else "")
    if all(results[n]["d_s"] <= SUPPORT_S for n in H1_CASES):
        return "SUPPORTED", f"every d is at most {SUPPORT_S} s"
    return "INCONCLUSIVE", f"every d is below {REFUTE_S} s and some is above {SUPPORT_S} s"


def fault_at(case: score_eks.Case) -> float:
    """When the registered fault happened, raw: the trainer's own fault record, or the node time of the injection."""
    if case.kind in score_eks.IN_TRAINER_FAULT:
        return score_eks.epoch(case.rec("fault", 1)[0]["ts"])
    return score_eks.epoch(score_eks.load_json(case.dir / "dcgm.json")["injected_at"])


def later_ran(case: score_eks.Case) -> bool:
    """The case's bound logs or the controller's Pod labels show an attempt after the first."""
    in_logs = any(isinstance(r.get("attempt"), int) and r["attempt"] > 1 for r in case.records)
    in_pods = any(str(p.get("attempt_token", "-")) not in ("1", "-") for p in case.pods.values())
    return in_logs or in_pods


def delivered(case: score_eks.Case) -> str:
    """'' when the registered fault is shown delivered and is what ended attempt 1, else why not.

    The delivery check is score_eks.py's, run on the evidence alone: a VOID the runner wrote is reported beside d and
    does not decide it, because the runner voids a rank-kill whose probe failed after its trainer may have fired.
    Delivery shows a fault happened, not that it ended the attempt measured, so attempt 1's trigger must be the one the
    kind registers: a JobDeleted restart once gave a valid 31 s for a dcgm case (codex gpt-6-astra attack of the
    retarget registration).
    Nothing the scorer checks after these is consulted.
    """
    try:
        case.load(runner_void=False)
        case.bind()
        case.check_delivered()
        first = case.attempts[0] if case.attempts else {}
        trigger = first.get("trigger")
        if trigger != score_eks.TRIGGER[case.kind]:
            return f"attempt 1 ended on {trigger!r}, not {score_eks.TRIGGER[case.kind]}, so the stop measured is not this fault's"
        # A matching trigger name is not a cause: the fault must come before the trigger it is to explain, and not long
        # before it; an injection moved to after the job had ended still passed (fifth attack).
        # Both times are raw, the fault's on its node's clock and the trigger on the controller's, whole seconds.
        # A missing trigger stamp is left to measure, which names it; here there is nothing to place.
        fault = fault_at(case)
        seen_at = score_eks.epoch(first["failureObservedAt"]) if first.get("failureObservedAt") else None
        if seen_at is not None and not (fault - CHRONOLOGY_AFTER_S <= seen_at <= fault + CHRONOLOGY_BEFORE_S):
            return (f"attempt 1's failure was observed {seen_at - fault:+.1f} s from the fault, outside "
                    f"-{CHRONOLOGY_AFTER_S} to +{CHRONOLOGY_BEFORE_S} s, so the stop measured is not shown to be this fault's")
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
        beside = {"verdict": verdict}
        if (run / name / "VOID").exists():
            beside["runner_void"] = (run / name / "VOID").read_text(errors="replace").strip()[:200]
        evidence = score_eks.Case(run, name, reference, steps, budget)
        why = delivered(evidence)
        if why:
            results[name] = {**beside, "invalid": why}
            continue
        try:
            results[name] = {**beside, **measure(run / name, later_ran(evidence))}
        except (ValueError, KeyError, TypeError, IndexError, AttributeError, OSError) as exc:
            results[name] = {**beside, "invalid": f"its evidence could not be read: {type(exc).__name__}: {str(exc)[:120]}"}
    for name in H1_CASES:
        print(f"{name:12} {json.dumps(results.get(name, {'invalid': 'not run'}), sort_keys=True)}")
    result, why = outcome(results)
    print(f"H1 {result}: {why}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
