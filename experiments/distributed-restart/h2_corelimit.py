"""Evaluates H2 of the corelimit stage: whether the rank-kill stop is short when the ranks run with core dumps off.

    python3 experiments/distributed-restart/h2_corelimit.py <run directory>

The registration is docs/superpowers/specs/2026-11-06-restart-corelimit-design.md, "H2, registered before the run".
Each rank-kill case's d is measured by h1_retarget.py's rules, unchanged, so a d here means what it meant there.
A case's arm is its case.json core_limit, and it counts only when the rank's own line in its log shows the same limit:
a limit the shell failed to set would otherwise be read as the treatment.
Beside each d it prints what ended the surviving rank's container, from the collector's stream records, which is the
mechanism H2 is about and not its verdict.
Exit 0 when an outcome was reached, 2 when the run is refused or is not a corelimit run.
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import h1_retarget  # noqa: E402
import score_eks  # noqa: E402

CONTROL = [f"rank-kill-{i}" for i in (1, 3, 5)]
TREATED = [f"rank-kill-{i}" for i in (2, 4, 6)]
SUPPORT_S = h1_retarget.SUPPORT_S
REFUTE_S = h1_retarget.REFUTE_S


def logged_limit(case_dir: pathlib.Path) -> set[str]:
    """Every core limit the case's attempt-1 ranks logged, as the shell read it before the trainer started."""
    first = {p["uid"] for p in score_eks.jsonl(case_dir / "pods.jsonl") if str(p.get("attempt_token")) == "1"}
    seen = set()
    for uid in first:
        for log in sorted(case_dir.glob(f"log-{uid}.*.txt")):
            seen.update(re.findall(r"^rank-env: core_limit=(\S+)", log.read_text(errors="replace"), re.M))
    return seen


def survivor_end(case_dir: pathlib.Path, fault: float) -> dict:
    """How the attempt-1 rank that did not fault ended: its container's exit code and reason, and when it finished."""
    first = {p["uid"]: p for p in score_eks.jsonl(case_dir / "pods.jsonl") if str(p.get("attempt_token")) == "1"}
    _, _, faulted = score_eks.IN_TRAINER_FAULT["rank-kill"]
    survivors = [u for u, p in first.items() if p.get("index") != str(faulted)]
    if len(survivors) != 1:
        return {"survivor": f"{len(survivors)} attempt-1 Pods other than rank {faulted}"}
    last: dict = {}
    for s in score_eks.jsonl(case_dir / "streams.jsonl"):
        if s.get("uid") == survivors[0] and s.get("stream", 0) >= last.get("stream", 0):
            last = s
    end = {k: last.get(k) for k in ("container", "exit_code", "reason")}
    if last.get("finished_at"):
        end["finished_after_fault_s"] = round(score_eks.epoch(last["finished_at"]) - fault, 1)
    return end


def outcome(control: dict[str, dict], treated: dict[str, dict]) -> tuple[str, str]:
    """H2's outcome, read in the registered order."""
    slow = [n for n, r in treated.items() if r.get("d_s") is not None and r["d_s"] >= REFUTE_S]
    if slow:
        return "REFUTED", f"d is at least {REFUTE_S} s with core dumps off in {', '.join(slow)}"
    missing = [n for n, r in {**control, **treated}.items() if r.get("d_s") is None]
    if missing:
        return "NOT ASSESSED", f"no valid d for {', '.join(missing)}"
    quick = [n for n, r in control.items() if r["d_s"] < REFUTE_S]
    if quick:
        return "INCONCLUSIVE", f"the slow stop did not recur with the node's limit in {', '.join(quick)}, so the arms cannot be compared"
    if all(r["d_s"] <= SUPPORT_S for r in treated.values()):
        return "SUPPORTED", f"every d is at most {SUPPORT_S} s with core dumps off and at least {REFUTE_S} s without"
    return "INCONCLUSIVE", f"every d with core dumps off is below {REFUTE_S} s and some is above {SUPPORT_S} s"


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    run = pathlib.Path(argv[1])
    prov = score_eks.provenance(run)
    refusals = score_eks.run_refusals(prov)
    if refusals:
        for r in refusals:
            print(f"REFUSED: {r}")
        return 2
    cases = prov.get("cases", "").split()
    if prov.get("stage") != "corelimit" or not set(CONTROL + TREATED) <= set(cases):
        print(f"REFUSED: {run} is not a corelimit run registering {', '.join(CONTROL + TREATED)}")
        return 2
    try:
        steps, budget = int(prov["steps"]), int(prov["case_budget"])
    except (KeyError, ValueError) as exc:
        print(f"REFUSED: the provenance's steps or case_budget cannot be read: {exc}")
        return 2
    reference = None
    results: dict[str, dict] = {}
    for name in cases:
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
        if name not in CONTROL + TREATED:
            continue
        want = "0" if name in TREATED else "inherited"
        row: dict = {"verdict": verdict, "arm": want}
        try:
            spec = score_eks.load_json(run / name / "case.json")
            logged = logged_limit(run / name)
        except (ValueError, KeyError, TypeError, OSError) as exc:
            results[name] = {**row, "invalid": f"its arm could not be read: {type(exc).__name__}: {str(exc)[:120]}"}
            continue
        row["logged_core_limit"] = sorted(logged)
        if spec.get("core_limit") != want:
            results[name] = {**row, "invalid": f"case.json records core_limit {spec.get('core_limit')!r}, the registration {want!r}"}
            continue
        # The treatment is shown applied by the ranks' own reading; the control's limit is whatever the node gave, but
        # it must have been read, and must not be 0, or the control ran treated.
        if not logged or (want == "0" and logged != {"0"}) or (want == "inherited" and "0" in logged):
            results[name] = {**row, "invalid": f"the ranks logged core_limit {sorted(logged) or 'nothing'} for arm {want!r}"}
            continue
        evidence = score_eks.Case(run, name, reference, steps, budget)
        why = h1_retarget.delivered(evidence)
        if why:
            results[name] = {**row, "invalid": why}
            continue
        try:
            row.update(h1_retarget.measure(run / name, h1_retarget.later_ran(evidence)))
            row["survivor_end"] = survivor_end(run / name, h1_retarget.fault_at(evidence))
        except (ValueError, KeyError, TypeError, IndexError, AttributeError, OSError) as exc:
            row["invalid"] = f"its evidence could not be read: {type(exc).__name__}: {str(exc)[:120]}"
        results[name] = row
    for name in CONTROL + TREATED:
        print(f"{name:12} {json.dumps(results.get(name, {'invalid': 'not run'}), sort_keys=True)}")
    result, why = outcome({n: results.get(n, {}) for n in CONTROL}, {n: results.get(n, {}) for n in TREATED})
    print(f"H2 {result}: {why}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
