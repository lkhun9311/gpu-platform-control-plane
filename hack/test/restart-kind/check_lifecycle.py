"""Checks a hack/restart-lifecycle-kind.sh evidence directory against what the runner's own files cannot show.

    python3 hack/test/restart-kind/check_lifecycle.py hack/restart-lifecycle-kind-<UTC>

Three checks, each read from a record the runner did not write, so a runner that wrote the expected marks without
doing what they say is still caught:
  1. consecutive cases: replaying each resource's list-then-watch history (watch_events.py) in resourceVersion order,
     no object of a case existed at the resourceVersion the next case's MLTrainingJob was created at;
  2. the fence: each termination case's fence-request mark is no earlier than the aws stub's first `terminated` answer
     for that instance (state/calls.log), and its target is the instance the stub killed;
  3. the case's own budget: from its MLTrainingJob's ADDED event to the runner's last sample of it, which for a
     censored case must reach RESTART_CASE_BUDGET and not stop short of it.
Prints one line per finding, OK or FAIL, and exits 1 if any FAIL.
"""

from __future__ import annotations

import datetime
import json
import pathlib
import re
import sys

CASE_BUDGET = 720


def ts(s: str) -> float:
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def replay(events: list[dict], res: str, prev: str, sub: int) -> list[str] | None:
    """The names containing PREV that RES held at resourceVersion SUB, or None when its history does not show that.

    It shows it only when a list at or before SUB starts a run of the stream's records, with no GAP in it, that reaches a
    record at or past SUB: a watch delivers in resourceVersion order, so every change before SUB came before that record,
    and a recorder that died or a watch that never caught up is unknown rather than empty (codex review of 6ea63fee).
    """
    mine = [e for e in events if e["res"] == res and "rv" in e]
    known: set[str] | None = None
    for e in mine:
        rv = int(e["rv"])
        if e["type"] == "GAP":
            known = None
        elif e["type"] == "LISTED":
            # A list after the submission follows a GAP, so nothing before it is continuous.
            if rv > sub:
                return None
            known = {n for n in e.get("names") or [] if prev in n}
        elif known is None:
            continue
        elif rv >= sub and e["type"] in ("ADDED", "MODIFIED", "DELETED", "BOOKMARK"):
            return sorted(known)
        elif e["type"] in ("ADDED", "MODIFIED") and prev in (e.get("name") or ""):
            known.add(e["name"])
        elif e["type"] == "DELETED":
            known.discard(e.get("name"))
    return None


def jsonl(path: pathlib.Path) -> list[dict]:
    return [json.loads(l) for l in path.read_text().splitlines() if l.strip().startswith("{")] if path.exists() else []


def main(argv: list[str]) -> int:
    out = pathlib.Path(argv[1])
    fails = 0

    def report(ok: bool, msg: str) -> None:
        nonlocal fails
        print(("OK   " if ok else "FAIL ") + msg)
        fails += 0 if ok else 1

    # Every one of the four streams is required, because a missing Pods stream would leave only the parent's events to
    # replay, and a Pod that outlived its job would not be seen (codex review of 69ec494f).
    streams = {"mltrainingjobs", "jobs", "pods", "workloads"}
    missing = sorted(r for r in streams if not (out / f"events-{r}.jsonl").exists())
    report(not missing, f"watch streams present: {sorted(streams - set(missing))}, missing {missing}")
    events = sorted((e for p in sorted(out.glob("events-*.jsonl")) for e in jsonl(p)), key=lambda e: ts(e["received"]))
    calls = (out / "state" / "calls.log").read_text().splitlines() if (out / "state" / "calls.log").exists() else []
    answers = [l.split() for l in calls if " answer " in l]

    for run in sorted(out.glob("run-*")):
        prov = dict(l.split("=", 1) for l in (run / "provenance.txt").read_text().splitlines() if "=" in l)
        started = []
        for case in prov.get("cases", "").split():
            spec = run / case / "case.json"
            if spec.exists():
                started.append((case, json.loads(spec.read_text())["name"]))

        # 1. consecutive cases, replayed in resourceVersion order, which etcd makes one order across every resource.
        for (pcase, prev), (case, cur) in zip(started, started[1:]):
            added = [e for e in events if e["res"] == "mltrainingjobs" and e["type"] == "ADDED" and e.get("name") == cur]
            if not added or "rv" not in added[0]:
                report(False, f"{run.name}: no ADDED event with a resourceVersion of {case}'s MLTrainingJob {cur}, so its submission is not placed")
                continue
            sub = int(added[0]["rv"])
            unknown, live = [], []
            for res in sorted(streams):
                state = replay(events, res, prev, sub)
                if state is None:
                    unknown.append(res)
                else:
                    live += [(res, n) for n in state]
            if unknown:
                report(False, f"{run.name}: the history of {unknown} is not shown continuous from a list to past {case}'s submission "
                              f"(resourceVersion {sub}), so what was left is unknown")
            elif live:
                report(False, f"{run.name}: {case} was submitted at resourceVersion {sub} while {pcase}'s {sorted(live)} still existed")
            else:
                last = max((int(e["rv"]) for e in events if e["type"] == "DELETED" and prev in (e.get("name") or "")), default=None)
                report(True, f"{run.name}: nothing of {pcase} existed when {case} was submitted at resourceVersion {sub}; "
                             + (f"its last object was deleted at {last}" if last else "no DELETED event of it was recorded"))
            # Any change to the previous case's objects after the submission is a leftover.
            # A list after the submission that still holds one is a leftover too (codex review of 66757add).
            late = [e for e in events if "rv" in e and int(e["rv"]) > sub and (
                (e["type"] in ("ADDED", "MODIFIED", "DELETED") and prev in (e.get("name") or ""))
                or (e["type"] == "LISTED" and any(prev in n for n in e.get("names") or [])))]
            if late:
                report(False, f"{run.name}: {pcase}'s objects were seen {len(late)} time(s) after {case} was submitted, first {late[0].get('name') or late[0].get('names')}")

        # 2. the fence against the stub's answers
        for case, name in started:
            if not case.startswith("terminate"):
                continue
            spec = json.loads((run / case / "case.json").read_text())
            inst = (spec.get("target") or {}).get("instance")
            marks = {m["mark"]: m["at"] for m in jsonl(run / case / "marks.jsonl")}
            term = [a for a in answers if len(a) >= 4 and a[2] == inst and a[3] == "terminated"]
            killed = any(f"terminate-instances --region ap-northeast-2 --instance-ids {inst}" in l for l in calls)
            if "fence-request" not in marks:
                report(True, f"{run.name}/{case}: no fence was requested (instance {inst}, killed {killed})")
                continue
            if not term:
                report(False, f"{run.name}/{case}: fence requested at {marks['fence-request']}, and the stub never answered terminated for {inst}")
            elif ts(marks["fence-request"]) < ts(term[0][0]):
                report(False, f"{run.name}/{case}: fence requested at {marks['fence-request']}, before the stub's first terminated answer at {term[0][0]}")
            else:
                report(killed, f"{run.name}/{case}: fence requested {ts(marks['fence-request']) - ts(term[0][0]):.2f} s after the stub's "
                               f"first terminated answer for {inst}, which the stub killed: {killed}")

        # 3. the case's own budget
        verdicts = {}
        for line in (run / "verdict.txt").read_text().splitlines() if (run / "verdict.txt").exists() else []:
            m = re.match(r"^(ACCEPTED|FAILED|VOID|NOTRUN)\s+(\S+?):?\s", line + " ")
            if m:
                verdicts[m.group(2)] = (m.group(1), line)
        for case, name in started:
            added = [e for e in events if e["res"].startswith("mltrainingjob") and e["type"] == "ADDED" and e["name"] == name]
            samples = jsonl(run / case / "timeline.jsonl")
            if not added or not samples:
                report(False, f"{run.name}/{case}: no ADDED event or no timeline, so its elapsed time is not shown")
                continue
            elapsed = ts(samples[-1]["observed"]) - ts(added[0]["received"])
            verdict, line = verdicts.get(case, ("?", ""))
            if "censored" in line:
                report(elapsed >= CASE_BUDGET - 5, f"{run.name}/{case}: censored, last sampled {elapsed:.1f} s after its creation was seen "
                                                   f"(budget {CASE_BUDGET} s); final phase {(samples[-1].get('status') or {}).get('phase')!r}")
            else:
                report(elapsed < CASE_BUDGET + 30, f"{run.name}/{case}: {verdict}, last sampled {elapsed:.1f} s after its creation was seen")
    print(f"{fails} FAIL(s)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
