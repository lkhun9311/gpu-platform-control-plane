"""Scores hack/distributed-restart-kind.sh evidence: one verdict per check, and a non-zero exit if any check fails.

    python3 experiments/distributed-restart/score_kind.py hack/distributed-restart-kind-<UTC>

Every check reads what the run recorded: the MLTrainingJob's final status, the once-a-second samples of it and of every
Job, Workload and Node, the marks the script wrote when it acted, and every rank's own records.
A case whose directory is missing or holds VOID is a failed check, never a skipped one.
"""

from __future__ import annotations

import json
import pathlib
import sys

FAILED: list[str] = []


def check(name: str, ok: bool, detail: str) -> None:
    print(f"{'ok  ' if ok else 'FAIL'} {name}: {detail}")
    if not ok:
        FAILED.append(name)


def lines(path: pathlib.Path) -> list[dict]:
    if not path.exists():
        return []
    out = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    return out


class Case:
    def __init__(self, root: pathlib.Path, name: str) -> None:
        self.name, self.dir = name, root / name
        self.ok = self.dir.is_dir() and not (self.dir / "VOID").exists() and (self.dir / "final-mltj.json").exists()
        if not self.ok:
            return
        self.final = json.loads((self.dir / "final-mltj.json").read_text())
        self.status = self.final.get("status") or {}
        self.attempts = self.status.get("attempts") or []
        self.timeline = lines(self.dir / "timeline.jsonl")
        self.marks = lines(self.dir / "marks.jsonl")
        self.records = [r for f in sorted(self.dir.glob("log-*.txt")) for r in lines(f)]

    def mark(self, prefix: str) -> str | None:
        return next((m["at"] for m in self.marks if m["mark"].startswith(prefix)), None)

    def window(self, start: str, end: str) -> list[dict]:
        a, b = self.mark(start), self.mark(end)
        if a is None or b is None:
            return []
        return [s for s in self.timeline if a <= s["observed"] <= b]

    def final_params(self, attempt: int) -> list[float] | None:
        last = [r for r in self.records if r.get("event") == "step" and r.get("rank") == 0 and r.get("attempt") == attempt
                and r.get("params") is not None]
        return last[-1]["params"] if last else None

    def resume_from(self, attempt: int) -> int | None:
        found = [r["from_step"] for r in self.records if r.get("event") == "resume" and r.get("attempt") == attempt
                 and r.get("rank") == 0]
        return found[0] if found else None


def present(case: Case) -> bool:
    check(f"{case.name} recorded", case.ok, "evidence present" if case.ok else f"missing or VOID under {case.dir}")
    return case.ok


def no_second_attempt(samples: list[dict]) -> bool:
    return all(len((s.get("status") or {}).get("attempts") or []) == 1 and all(j["attempt"] != "2" for j in s["jobs"])
               for s in samples)


def restarted(case: Case, reference: list[float] | None, want_from: int | None) -> None:
    a = case.attempts
    check(f"{case.name} succeeded on attempt 2", case.status.get("phase") == "Succeeded" and len(a) == 2,
          f"phase {case.status.get('phase')}, attempts {len(a)}")
    if len(a) < 2:
        return
    check(f"{case.name} attempt 1 stopped by a failed rank", a[0].get("state") == "Stopped" and a[0].get("trigger") == "RankFailed",
          f"state {a[0].get('state')}, trigger {a[0].get('trigger')}")
    got = case.resume_from(2)
    if want_from is not None:
        check(f"{case.name} resumed from step {want_from}", got == want_from, f"attempt 2 resumed from {got}")
    else:
        check(f"{case.name} resumed from a checkpoint", got is not None, f"attempt 2 resumed from {got}")
    params = case.final_params(2)
    check(f"{case.name} same training as the reference", reference is not None and params == reference,
          "final parameters equal the uninterrupted run's" if params == reference else "final parameters differ or are missing")
    job = json.loads((case.dir / "final-job.json").read_text()) if (case.dir / "final-job.json").exists() else {}
    env = {e["name"]: e.get("value") for e in (((job.get("spec") or {}).get("template") or {}).get("spec") or {}).get("containers", [{}])[0].get("env", [])}
    check(f"{case.name} attempt 2 rendezvous is a name attempt 1 never had", "-ddp-a2." in (env.get("MASTER_ADDR") or ""),
          f"MASTER_ADDR {env.get('MASTER_ADDR')}")


def main() -> int:
    root = pathlib.Path(sys.argv[1])
    if (root / "VOID").exists():
        print(f"VOID: {(root / 'VOID').read_text().strip()}")
        return 1
    provenance = dict(line.split("=", 1) for line in (root / "provenance.txt").read_text().splitlines() if "=" in line)
    # A run of uncommitted code is a rehearsal: what it shows belongs to no commit anyone can check out.
    check("ran committed code", provenance.get("dirty_files") == "0",
          f"commit {provenance.get('commit', '?')[:8]}, {provenance.get('dirty_files')} uncommitted file(s) in what it runs")
    reference = None

    case = Case(root, "reference")
    if present(case):
        reference = case.final_params(1)
        check("reference succeeded on attempt 1", case.status.get("phase") == "Succeeded" and len(case.attempts) == 1,
              f"phase {case.status.get('phase')}, attempts {len(case.attempts)}")
        check("reference has final parameters", reference is not None, "rank 0's last step record")

    case = Case(root, "rank-failed")
    if present(case):
        restarted(case, reference, 5)

    case = Case(root, "stale-workload")
    if present(case):
        restarted(case, reference, None)
        held = case.window("hold-start", "hold-end")
        check("stale-workload no second attempt while the Workload was held", bool(held) and no_second_attempt(held),
              f"{len(held)} samples in the hold")
        wl = (case.mark("finalizer-added") and next(m for m in case.marks if m["mark"].startswith("finalizer-added"))["mark"].split()[1])
        alive = [s for s in held if any(w["name"] == wl for w in s["workloads"])]
        check("stale-workload the held Workload existed through the hold", bool(held) and len(alive) == len(held),
              f"{len(alive)} of {len(held)} samples show {wl}")
        waits = sorted({((s.get("status") or {}).get("attempts") or [{}])[0].get("waitingFor") or "" for s in held})
        check("stale-workload what attempt 1 waited on", any(w for w in waits), f"{waits}")

    case = Case(root, "deactivated")
    if present(case):
        after = case.window("deactivated", "hold-end")
        check("deactivated no restart after an operator's deactivation", bool(after) and no_second_attempt(after)
              and all(not ((s.get("status") or {}).get("attempts") or [{}])[0].get("trigger") for s in after),
              f"{len(after)} samples over the minute after; attempts at the end {len(case.attempts)}")

    case = Case(root, "node-lost")
    if present(case):
        restarted(case, reference, None)
        victim = next((m["mark"].split()[1] for m in case.marks if m["mark"].startswith("paused")), None)
        if case.attempts:
            check("node-lost the lost node was recorded for attempt 1", victim in (case.attempts[0].get("nodes") or []),
                  f"attempt 1 nodes {case.attempts[0].get('nodes')}, paused {victim}")
        if len(case.attempts) > 1:
            check("node-lost attempt 2 ran without the lost node", victim not in (case.attempts[1].get("nodes") or []),
                  f"attempt 2 nodes {case.attempts[1].get('nodes')}")
        for start, end, what in (("pods-hold-start", "pods-hold-end", "while the lost node's Pods remained"),
                                 ("fence-hold-start", "fence-hold-end", "until the node was fenced")):
            held = case.window(start, end)
            check(f"node-lost no second attempt {what}", bool(held) and no_second_attempt(held), f"{len(held)} samples")
        fenced = case.window("fence-hold-start", "fence-hold-end")
        says = {((s.get("status") or {}).get("attempts") or [{}])[0].get("waitingFor") for s in fenced}
        check("node-lost the barrier named the unfenced node", bool(fenced) and all(victim and victim in (w or "") for w in says),
              f"{sorted(w or '' for w in says)}")

    print(f"{len(FAILED)} failed" if FAILED else "all checks passed")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
