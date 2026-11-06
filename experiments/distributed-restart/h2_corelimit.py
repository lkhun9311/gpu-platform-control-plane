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


def logged_env(case_dir: pathlib.Path) -> tuple[set[str], set[str], list[str]]:
    """Every core limit and core_pattern the case's attempt-1 ranks logged, as the shell read them before the trainer,
    and the attempt-1 Pods that logged none.

    Each rank must show its own: the union of both let the faulted rank's line stand for a survivor that logged nothing,
    and the survivor is the process whose dump is in question (bare codex review of 8e2eb73f).
    """
    first = sorted(p["uid"] for p in score_eks.jsonl(case_dir / "pods.jsonl") if str(p.get("attempt_token")) == "1")
    limits, patterns, silent = set(), set(), []
    for uid in first:
        found = [m for log in sorted(case_dir.glob(f"log-{uid}.*.txt"))
                 for m in re.findall(r"^rank-env: core_limit=(\S+) core_pattern=(.*?) torch_nccl_async_error_handling=",
                                     log.read_text(errors="replace"), re.M)]
        if not found:
            silent.append(uid)
        for limit, pattern in found:
            limits.add(limit)
            patterns.add(pattern)
    if len(first) != score_eks.WORLD:
        silent.append(f"{len(first)} attempt-1 Pods, not {score_eks.WORLD}")
    return limits, patterns, silent


def limit_stops_dump(pattern: str) -> bool:
    """Whether a core limit of 0 stops a dump under this core_pattern.

    The kernel ignores RLIMIT_CORE when it pipes a core to a program (core(5)), so a 0 stops a piped dump only if the
    program reads the limit and declines: systemd-coredump takes it as %c and returns before reading the core when it is
    under a page (src/coredump/coredump.c, "Resource limits disable core dumping").
    A dump to a file the kernel itself limits.
    Any other program might read the whole core regardless, and a treated arm under it would test nothing.
    """
    if not pattern.startswith("|"):
        return True
    return "systemd-coredump" in pattern and "%c" in pattern.split()


def watched_pods(case_dir: pathlib.Path) -> list[tuple[int, dict]]:
    """Every Pod object the collector's watch recorded, in the order it arrived, each with the number of the watch that
    delivered it: 1 for the first, counted by the collector's WATCH-OPENED marks, and 0 in a file that has none.

    Each watch lists afresh, so a change that fell between two watches is not in the file; only two objects of one
    watch are known to have no change between them unseen.

    The file is kubectl's watch events as concatenated JSON objects; one cut short when the watch was stopped or reopened
    is skipped to the next object kubectl began on a line of its own.
    An archive commits it xz-compressed, as it does the timelines, so its .xz is read when the plain file is absent; a
    damaged one raises ValueError.
    """
    text = score_eks.jsonl_text(case_dir / "pod-watch.json")
    if text is None:
        return []
    decoder, i, pods, watch = json.JSONDecoder(), 0, [], 0
    while True:
        while i < len(text) and text[i].isspace():
            i += 1
        if i >= len(text):
            return pods
        try:
            event, i = decoder.raw_decode(text, i)
        except ValueError:
            i = text.find("\n{", i + 1)
            if i < 0:
                return pods
            continue
        if isinstance(event, dict) and event.get("type") == "WATCH-OPENED":
            watch += 1
        elif isinstance(event, dict) and isinstance(event.get("object"), dict):
            pods.append((watch, event["object"]))


def survivor_end(case_dir: pathlib.Path, fault: float) -> dict:
    """How the attempt-1 rank that did not fault ended: its container's exit code and reason, when it finished, and when
    its deletion was asked for.

    The stream records read the container only when a log stream ended, and a Pod deleted before that read left none
    (kind run f's rank-kill-1), so the Pod watch's last terminated state stands in for it.
    deletionTimestamp is the request plus the grace the API server gave; the first object carrying it is the request's,
    because a later deletion with a shorter grace moves it, and only if the same watch delivered the Pod before it.
    With no terminal state recorded the mechanism is said to be unread rather than left to an absent field
    (gpt-6-astra's attack before the corelimit run).
    """
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
    finished = last.get("finished_at") if last.get("container") == "terminated" else None
    # A watch that cannot be read is said so, beside an end the streams may still give; it is not the case's evidence.
    try:
        watched = [(w, p) for w, p in watched_pods(case_dir) if (p.get("metadata") or {}).get("uid") == survivors[0]]
    except ValueError as exc:
        watched = []
        end["pod_watch"] = f"unreadable: {str(exc)[:120]}"
    if finished is None:
        for _, pod in reversed(watched):
            state = (((pod.get("status") or {}).get("containerStatuses") or [{}])[0].get("state") or {}).get("terminated")
            if state:
                end.update(container="terminated", exit_code=state.get("exitCode"), reason=state.get("reason"), read_from="pod watch")
                finished = state.get("finishedAt")
                break
    if finished:
        end["finished_after_fault_s"] = round(score_eks.epoch(finished) - fault, 1)
    else:
        end["unread"] = "no terminal state of the surviving rank was recorded, so how it ended is not shown"
    # The request is read only where one watch saw the Pod both before its deletion and at it: the first deletion a later
    # watch lists may carry a grace already shortened, a stamp that is not the request's (gpt-6-astra's second attack).
    first = next(((k, w, p) for k, (w, p) in enumerate(watched) if (p.get("metadata") or {}).get("deletionTimestamp")), None)
    if first is not None:
        k, w, pod = first
        meta = pod["metadata"]
        seen_before = any(ow == w for ow, _ in watched[:k])
        if w > 0 and seen_before and meta.get("deletionGracePeriodSeconds") is not None:
            asked = score_eks.epoch(meta["deletionTimestamp"]) - meta["deletionGracePeriodSeconds"]
            end["deletion_asked_after_fault_s"] = round(asked - fault, 1)
            end["deletion_grace_s"] = meta["deletionGracePeriodSeconds"]
        else:
            end["deletion_asked"] = "not shown: no one watch saw the Pod before and at its deletion"
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
            logged, patterns, silent = logged_env(run / name)
        except (ValueError, KeyError, TypeError, OSError) as exc:
            results[name] = {**row, "invalid": f"its arm could not be read: {type(exc).__name__}: {str(exc)[:120]}"}
            continue
        row["logged_core_limit"] = sorted(logged)
        row["logged_core_pattern"] = sorted(patterns)
        if spec.get("core_limit") != want:
            results[name] = {**row, "invalid": f"case.json records core_limit {spec.get('core_limit')!r}, the registration {want!r}"}
            continue
        if silent:
            results[name] = {**row, "invalid": f"not every attempt-1 rank logged its core limit: {', '.join(silent)}"}
            continue
        # The treatment is shown applied by the ranks' own reading; the control's limit is whatever the node gave, but
        # it must have been read, and must not be 0, or the control ran treated.
        if not logged or (want == "0" and logged != {"0"}) or (want == "inherited" and "0" in logged):
            results[name] = {**row, "invalid": f"the ranks logged core_limit {sorted(logged) or 'nothing'} for arm {want!r}"}
            continue
        if want == "0" and not all(limit_stops_dump(pt) for pt in patterns):
            results[name] = {**row, "invalid": f"a core limit of 0 is not shown to stop a dump under core_pattern {sorted(patterns)}"}
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
