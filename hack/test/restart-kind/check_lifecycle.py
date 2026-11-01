"""Checks a hack/restart-lifecycle-kind.sh evidence directory against what the runner's own files cannot show.

    python3 hack/test/restart-kind/check_lifecycle.py hack/restart-lifecycle-kind-<UTC>

Three checks, each read from a record the runner did not write, so a runner that wrote the expected marks without
doing what they say is still caught:
  1. consecutive cases: replaying the watch events (watch_events.py), every object of a case was DELETED before the
     next case's MLTrainingJob was ADDED;
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

        # 1. consecutive cases
        for (pcase, prev), (case, cur) in zip(started, started[1:]):
            added = [e for e in events if e["res"].startswith("mltrainingjob") and e["type"] == "ADDED" and e["name"] == cur]
            if not added:
                report(False, f"{run.name}: no ADDED event of {case}'s MLTrainingJob {cur}, so its submission is not placed")
                continue
            t = ts(added[0]["received"])
            live: dict[tuple[str, str], float] = {}
            # A resource is unknown before its first list, from a GAP to the list after it, and while its watch is down:
            # a resumed watch delivers what happened meanwhile only after it starts again (codex review of b6051665).
            unknown: set[str] = set(streams)
            resumed_at: dict[str, float] = {}
            for e in events:
                if ts(e["received"]) >= t:
                    break
                if e["type"] in ("WATCH-END", "GAP"):
                    unknown.add(e["res"])
                elif e["type"] == "WATCH-START" and e["res"] in resumed_at:
                    resumed_at[e["res"]] = ts(e["received"])
                    unknown.discard(e["res"])
                elif e["type"] == "LISTED":
                    resumed_at[e["res"]] = ts(e["received"])
                    unknown.discard(e["res"])
                    for key in [k for k in live if k[0] == e["res"]]:
                        del live[key]
                    for n in e.get("names") or []:
                        if prev in n:
                            live[(e["res"], n)] = ts(e["received"])
                elif e["type"] in ("ADDED", "MODIFIED") and prev in (e.get("name") or ""):
                    live[(e["res"], e["name"])] = ts(e["received"])
                elif e["type"] == "DELETED":
                    live.pop((e["res"], e.get("name")), None)
            gone = [ts(e["received"]) for e in events if e["type"] == "DELETED" and prev in (e.get("name") or "")]
            # A watch resumed within two seconds of the submission may not yet have delivered what it missed.
            unknown |= {r for r, at in resumed_at.items() if t - at < 2}
            # What was left is then unknown, which is a failure and never an absence.
            if unknown:
                report(False, f"{run.name}: the history of {sorted(unknown)} was not continuous up to {case}'s submission "
                              f"(no list yet, a gap, or a watch down or just resumed), so what was left is unknown")
            elif live:
                report(False, f"{run.name}: {case} was submitted at {added[0]['received']} while {pcase}'s {sorted(live)} still existed")
            else:
                last = max(gone) if gone else None
                report(True, f"{run.name}: nothing of {pcase} existed when {case} was submitted; its last object was deleted "
                             + (f"{t - last:.1f} s before" if last else "with no DELETED event recorded"))
            # Any sight of the previous case's objects after the submission is a leftover, a relist's included.
            late = [e for e in events if ts(e["received"]) > t and (
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
