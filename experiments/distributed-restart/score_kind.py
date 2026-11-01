"""Scores hack/distributed-restart-kind.sh evidence: one verdict per check, and a non-zero exit if any check fails.

    python3 experiments/distributed-restart/score_kind.py hack/distributed-restart-kind-<UTC>

Every check reads what the run recorded: the MLTrainingJob's final status, the once-a-second samples of it and of every
Job, Workload and Node, the marks the script wrote when it acted, and every rank's own records.
A case whose directory is missing or holds VOID is a failed check, never a skipped one.
"""

from __future__ import annotations

import datetime
import json
import math
import pathlib
import sys

FAILED: list[str] = []
CASES = ("reference", "rank-failed", "stale-workload", "deactivated", "node-lost", "cut-writer", "cut-writer-early")
# What a provenance without a cases= line ran: every recorded run before the field existed ran these five.
DEFAULT_CASES = ("reference", "rank-failed", "stale-workload", "deactivated", "node-lost")
FENCE_ANNOTATION = "platform.lkhun9311.github.io/fenced-nodes"
# The longest stretch a window may go unobserved; the harness samples about once a second in the foreground and again in
# the background through the cut cases.
MAX_SAMPLE_GAP = 3.0
# The longest pause between two heartbeat records of a rank that writes every 0.5 s and is said to be writing throughout.
MAX_HEARTBEAT_GAP = 2.0


def ts(value: object) -> float | None:
    """Seconds since the epoch of an ISO 8601 time with a zone, or None.

    Times are compared as numbers, never as strings: the trainer writes "+00:00" with microseconds and the API server "Z"
    with whole seconds, and "...00.900000+00:00" sorts before "...00Z" as text although it is later.
    """
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed.timestamp() if parsed.tzinfo is not None else None


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
        # The foreground's samples and, in the cut cases, the background sampler's, in the order they were observed.
        self.timeline = sorted((s for f in sorted(self.dir.glob("timeline*.jsonl")) for s in lines(f)
                                if ts(s.get("observed")) is not None), key=lambda s: ts(s["observed"]))
        self.marks = lines(self.dir / "marks.jsonl")
        self.records = [r for f in sorted(self.dir.glob("log-*.txt")) for r in lines(f)]

    def mark(self, prefix: str) -> str | None:
        return next((m["at"] for m in self.marks if m["mark"].startswith(prefix)), None)

    def at(self, word: str) -> float | None:
        """The time of the first mark whose first word is exactly word; "cut" is not "cut-start"."""
        return next((ts(m["at"]) for m in self.marks if m["mark"].split()[0] == word), None)

    def window(self, start: str, end: str) -> list[dict]:
        a, b = ts(self.mark(start)), ts(self.mark(end))
        if a is None or b is None:
            return []
        return [s for s in self.timeline if a <= ts(s["observed"]) <= b]

    def world(self) -> int:
        return int(((self.final.get("spec") or {}).get("distributed") or {}).get("worldSize") or 0)

    def rank_params(self, attempt: int) -> dict[int, list[float]]:
        """Every rank's last recorded parameters in the attempt, by rank."""
        out: dict[int, list[float]] = {}
        for r in self.records:
            if r.get("event") == "step" and r.get("attempt") == attempt and r.get("params") is not None:
                out[r.get("rank")] = r["params"]
        return out

    def final_params(self, attempt: int) -> list[float] | None:
        """The attempt's final parameters, only if every rank recorded them and they agree.

        Reading rank 0 alone let a run pass whose other ranks never finished, or finished with something else.
        """
        got = self.rank_params(attempt)
        if self.world() < 1 or sorted(got) != list(range(self.world())):
            return None
        first = got[0]
        return first if all(p == first for p in got.values()) else None

    def rank_resumes(self, attempt: int) -> dict[int, tuple[str, int]]:
        """Every rank's first resume record in the attempt, as (checkpoint directory, step), by rank."""
        out: dict[int, tuple[str, int]] = {}
        for r in self.records:
            if r.get("event") == "resume" and r.get("attempt") == attempt and r.get("rank") not in out:
                out[r.get("rank")] = (r.get("from_dir"), r.get("from_step"))
        return out

    def resume_from(self, attempt: int) -> int | None:
        """The step the attempt resumed from, only if every rank resumed and all from the same checkpoint."""
        got = self.rank_resumes(attempt)
        if self.world() < 1 or sorted(got) != list(range(self.world())) or len(set(got.values())) != 1:
            return None
        return got[0][1]


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
    resumes = f"attempt 2 resumed from {got}; by rank {case.rank_resumes(2)} of world size {case.world()}"
    if want_from is not None:
        check(f"{case.name} every rank resumed from step {want_from}", got == want_from, resumes)
    else:
        check(f"{case.name} every rank resumed from one checkpoint", got is not None, resumes)
    params = case.rank_params(2)
    same = (reference is not None and sorted(params) == list(range(case.world()))
            and all(p == reference for p in params.values()))
    check(f"{case.name} same training as the reference on every rank", same,
          f"ranks {sorted(params)} of world size {case.world()} recorded final parameters; "
          + ("each equals the uninterrupted run's" if same else "some differ, are missing, or there is no reference"))
    job = json.loads((case.dir / "final-job.json").read_text()) if (case.dir / "final-job.json").exists() else {}
    env = {e["name"]: e.get("value") for e in (((job.get("spec") or {}).get("template") or {}).get("spec") or {}).get("containers", [{}])[0].get("env", [])}
    check(f"{case.name} attempt 2 rendezvous is a name attempt 1 never had", "-ddp-a2." in (env.get("MASTER_ADDR") or ""),
          f"MASTER_ADDR {env.get('MASTER_ADDR')}")


def observed_window(case: Case, start: str, end: str) -> tuple[list[dict], str]:
    """The samples between two marks, or none if the window was not observed throughout.

    A sample whose reads failed stands in empty lists for what it could not read, so it cannot vouch that nothing existed;
    and a window observed only at its ends says nothing about its middle.
    """
    a, b = case.at(start), case.at(end)
    if a is None or b is None:
        return [], f"mark {start if a is None else end} missing"
    inside = [s for s in case.timeline if a <= ts(s["observed"]) <= b]
    failed = [s for s in inside if s.get("errors")]
    times = [a] + [ts(s["observed"]) for s in inside] + [b]
    gap = max(y - x for x, y in zip(times, times[1:]))
    detail = f"{len(inside)} samples over {b - a:.1f} s, longest unobserved {gap:.1f} s, {len(failed)} with failed reads"
    if not inside or failed or gap > MAX_SAMPLE_GAP:
        return [], detail
    return inside, detail


def heartbeats(case: Case, attempt: int) -> dict[int, list[dict]]:
    """Every rank's heartbeat records of one attempt, as copied from the shared volume, by rank, in file order."""
    out: dict[int, list[dict]] = {}
    for f in sorted((case.dir / "volume").glob(f"a{attempt}-heartbeat-rank-*.jsonl")):
        for r in lines(f):
            if r.get("attempt") == attempt and ts(r.get("ts")) is not None and f.name.endswith(f"-rank-{r.get('rank')}.jsonl"):
                out.setdefault(r["rank"], []).append(r)
    return out


def listing(case: Case, name: str) -> dict[str, tuple[float, int]]:
    """A host listing the harness wrote, as path to (mtime, size)."""
    out = {}
    path = case.dir / name
    if path.exists():
        for line in path.read_text().splitlines():
            parts = line.split(" ", 2)
            if len(parts) == 3:
                out[parts[2]] = (float(parts[0]), int(parts[1]))
    return out


def overlap(case: Case, job: str) -> tuple[float | None, float | None, str]:
    """Attempt 1's last write and attempt 2's first, from the volume.

    Attempt 1's last write is the latest of its heartbeat records, on every rank, and of the mtime of every path under
    a1/, which also covers a heartbeat record torn by the kill and every checkpoint file.
    Attempt 2's first write is its earliest heartbeat record, taken on both ranks before the process group forms.
    None for either means the evidence for it is incomplete.
    """
    world = case.world()
    a1, a2 = heartbeats(case, 1), heartbeats(case, 2)
    final = listing(case, "listing-final.txt")
    under_a1 = [m for p, (m, _) in final.items() if p == f"{job}/a1" or p.startswith(f"{job}/a1/")]
    last = None
    if sorted(a1) == list(range(world)) and under_a1:
        last = max([ts(r["ts"]) for rs in a1.values() for r in rs] + under_a1)
    first = min(ts(r["ts"]) for rs in a2.values() for r in rs) if sorted(a2) == list(range(world)) else None
    return last, first, (f"attempt 1 heartbeats on ranks {sorted(a1)}, {len(under_a1)} paths under a1/; "
                         f"attempt 2 heartbeats on ranks {sorted(a2)} of world size {world}")


def counters(text: str, chain: str, address: str, port: str) -> list[int]:
    """Packet counts of the DROP rules in one chain of an iptables -L -v -n -x listing that match an address and port."""
    found, current = [], None
    for line in text.splitlines():
        if line.startswith("Chain "):
            current = line.split()[1]
            continue
        fields = line.split()
        if current == chain and len(fields) > 2 and fields[2] == "DROP" and address in fields and f"dpt:{port}" in fields:
            found.append(int(fields[0]))
    return found


def iso(t: float | None) -> str:
    return "none" if t is None else datetime.datetime.fromtimestamp(t, datetime.timezone.utc).isoformat(timespec="milliseconds")


def cut_writer(case: Case, reference: list[float] | None) -> None:
    """Scores cut-writer, or its negative control cut-writer-early, which must show the overlap cut-writer must not."""
    early = case.name == "cut-writer-early"
    c = case.name
    job = (case.final.get("metadata") or {}).get("name") or ""
    victim = next((m["mark"].split()[1] for m in case.marks if m["mark"].split()[0] == "cut-start"), None)
    pods = lines(case.dir / "pods.jsonl")
    restarted(case, reference, None)
    if len(case.attempts) > 1:
        a2nodes = case.attempts[1].get("nodes") or []
        check(f"{c} attempt 2 ran on two nodes, neither the cut one", len(set(a2nodes)) == case.world() and victim not in a2nodes,
              f"attempt 2 nodes {a2nodes}, cut {victim}")

    holder = [p for p in pods if p.get("attempt") == "1" and p.get("rank") == "1"]
    check(f"{c} the cut node held rank 1 of attempt 1", victim is not None and [p["node"] for p in holder] == [victim],
          f"cut {victim}; attempt 1 rank 1 Pods {[(p['pod'], p['node']) for p in holder]}")

    cut = dict(kv.split("=", 1) for kv in (case.dir / "cut.txt").read_text().split()) if (case.dir / "cut.txt").exists() else {}
    text = (case.dir / "cut-counters.txt").read_text() if (case.dir / "cut-counters.txt").exists() else ""
    out4 = counters(text, "OUTPUT", cut.get("control_plane_ipv4", "-"), "6443")
    out6 = counters(text, "OUTPUT", cut.get("control_plane_ipv6", "-"), "6443") if cut.get("control_plane_ipv6") else []
    check(f"{c} the cut dropped the node's traffic to the API server", len(out4) == 1 and sum(out4) + sum(out6) > 0,
          f"OUTPUT DROP to the control plane's 6443: IPv4 packets {out4}, IPv6 packets {out6}")

    t_start, t_cut, t_del = case.at("cut-start"), case.at("cut"), case.at("node-delete-start")
    before = [s for s in case.timeline if t_start is not None and ts(s["observed"]) < t_start and not s.get("errors")]
    during = [s for s in case.timeline if t_cut is not None and t_del is not None and t_cut <= ts(s["observed"]) <= t_del
              and not s.get("errors")]
    # The Node must be present and say so: a sample without it, or one whose read failed, says nothing about readiness.
    was_ready = bool(before) and all(s["nodes"].get(victim) == "True" for s in before)
    went = [s for s in during if s["nodes"].get(victim) in ("False", "Unknown")]
    check(f"{c} the node went not Ready after the cut", was_ready and bool(went),
          f"{len(before)} samples before the cut all Ready: {was_ready}; {len(went)} of {len(during)} samples between the cut "
          f"and the Node's deletion show it {sorted({s['nodes'].get(victim) for s in went})}")

    # The Job controller's verdict, not its outcome: a failure seen before the Node was deleted would have another cause.
    failing = [ts(s["observed"]) for s in case.timeline for j in s.get("jobs", []) if j.get("attempt") == "1"
               and any(x.split(":")[0] in ("Failed", "FailureTarget") for x in j.get("conditions") or [])]
    reasons = sorted({x for s in case.timeline for j in s.get("jobs", []) if j.get("attempt") == "1"
                      for x in j.get("conditions") or []})
    check(f"{c} attempt 1's Job failed only after the Node was deleted", bool(failing) and t_del is not None and min(failing) > t_del,
          f"first seen failing {iso(min(failing) if failing else None)}, Node deletion from {iso(t_del)}; conditions {reasons}")

    final = listing(case, "listing-final.txt")
    published = [m for p, (m, _) in final.items() if p.startswith(f"{job}/a1/") and p.endswith("/MANIFEST")
                 and t_cut is not None and m > t_cut]
    check(f"{c} both ranks went on training across the cut", bool(published),
          f"{len(published)} attempt-1 manifests published after the cut, each needing both ranks' shards")

    t_deleted, t_kill, t_killed = case.at("node-deleted"), case.at("kill-start"), case.at("killed")
    cut_rank = heartbeats(case, 1).get(1, [])
    seqs = [r["seq"] for r in cut_rank]
    span = [ts(r["ts"]) for r in cut_rank if t_deleted is not None and t_kill is not None and t_deleted <= ts(r["ts"]) <= t_kill]
    gaps = [y - x for x, y in zip([t_deleted or 0.0] + span, span + [t_kill or math.inf])]
    held_start, held_end = listing(case, "listing-hold-start.txt"), listing(case, "listing-hold-end.txt")
    hb = f"{job}/a1/heartbeat-rank-1.jsonl"
    grew = hb in held_start and hb in held_end and held_end[hb][1] > held_start[hb][1]
    check(f"{c} the cut rank kept writing from its Node's deletion until its machine was killed",
          bool(span) and seqs == sorted(set(seqs)) and max(gaps) <= MAX_HEARTBEAT_GAP and grew,
          f"{len(span)} records between {iso(t_deleted)} and {iso(t_kill)}, longest pause {max(gaps):.1f} s, "
          f"sequence {'strictly increasing' if seqs == sorted(set(seqs)) else 'repeats or goes back'}; "
          f"on the host the file grew over the fence hold: {grew}")
    lingered = [r for r in cut_rank if r.get("phase") == "lingering" and t_kill is not None and ts(r["ts"]) < t_kill]
    check(f"{c} the cut rank's training had ended and it lingered", bool(lingered),
          f"{len(lingered)} lingering records before the kill")

    state = json.loads((case.dir / "victim-state.json").read_text()) if (case.dir / "victim-state.json").exists() else {}
    last_cut = max((ts(r["ts"]) for r in cut_rank), default=None)
    check(f"{c} the cut rank stopped writing when its machine was killed",
          state.get("Running") is False and last_cut is not None and t_kill is not None and t_killed is not None
          and t_kill - MAX_HEARTBEAT_GAP <= last_cut <= t_killed,
          f"container running {state.get('Running')}; last record {iso(last_cut)}, kill {iso(t_kill)} to {iso(t_killed)}")

    held, detail = observed_window(case, "node-delete-start", "fence-start")
    check(f"{c} no second attempt from the Node's deletion until the fence", bool(held) and no_second_attempt(held), detail)
    fenced, detail = observed_window(case, "fence-hold-start", "fence-hold-end")
    says = sorted({((s.get("status") or {}).get("attempts") or [{}])[0].get("waitingFor") or "" for s in fenced})
    check(f"{c} the barrier named the cut node", bool(fenced) and all(victim in w and "to be fenced" in w for w in says),
          f"{detail}; {says}")
    t_decoy = case.at("decoy-annotated")
    decoyed = [s for s in fenced if t_decoy is not None and ts(s["observed"]) > t_decoy
               and (s.get("annotations") or {}).get(FENCE_ANNOTATION) not in (None, victim)
               and "rst.test/poke" in (s.get("annotations") or {})]
    check(f"{c} a fence naming another node, and an unrelated annotation, did not release it", len(decoyed) >= 5,
          f"{len(decoyed)} samples show the decoys and, by the check above, one attempt")

    last, first, detail = overlap(case, job)
    t_fence = case.at("fence-start")
    a2job = json.loads((case.dir / "final-job.json").read_text()) if (case.dir / "final-job.json").exists() else {}
    created = ts((a2job.get("metadata") or {}).get("creationTimestamp"))
    ours = len(case.attempts) > 1 and (a2job.get("metadata") or {}).get("uid") == case.attempts[1].get("jobUID")
    # The API server keeps whole seconds, so the most this can show is that the Job's second is not before the fence's.
    check(f"{c} attempt 2's Job was created after the fence was written",
          ours and created is not None and t_fence is not None and created >= math.floor(t_fence),
          f"Job of attempt 2: {ours}, created {iso(created)}, fence written from {iso(t_fence)}")

    if not early:
        pre = listing(case, "listing-prefence.txt")
        a1 = lambda lst: {p: v for p, v in lst.items() if p == f"{job}/a1" or p.startswith(f"{job}/a1/")}
        outside = [m for p, (m, _) in pre.items() if p != job and not p.startswith(f"{job}/a1")]
        check(f"{c} attempt 1 had stopped writing before the fence",
              last is not None and t_fence is not None and last < t_fence and bool(a1(pre)) and a1(pre) == a1(final)
              and all(m < t_fence for m in outside),
              f"last attempt-1 write {iso(last)}, fence written from {iso(t_fence)}; a1/ unchanged from the listing taken "
              f"before the fence to the end: {bool(a1(pre)) and a1(pre) == a1(final)}; {len(outside)} other paths, "
              f"all older than the fence: {all(m < t_fence for m in outside)}")
        check(f"{c} no attempt-1 write after attempt 2's first", last is not None and first is not None and last < first,
              f"attempt 1 last {iso(last)}, attempt 2 first {iso(first)}; {detail}")
        return

    # The control: the same comparison must find attempt 1 writing after attempt 2 began, and go on doing so.
    after = sorted(ts(r["ts"]) for r in cut_rank if first is not None and ts(r["ts"]) > first)
    gaps = [y - x for x, y in zip(after, after[1:])]
    check(f"{c} attempt 1 still wrote after attempt 2's first write, as the early fence allowed",
          last is not None and first is not None and last > first and len(after) > 1 and after[-1] - after[0] >= 15
          and max(gaps) <= MAX_HEARTBEAT_GAP,
          f"attempt 1 last {iso(last)}, attempt 2 first {iso(first)}; the cut rank wrote {len(after)} records over "
          f"{(after[-1] - after[0]) if len(after) > 1 else 0:.1f} s after it; {detail}")


def main() -> int:
    root = pathlib.Path(sys.argv[1])
    if (root / "VOID").exists():
        print(f"VOID: {(root / 'VOID').read_text().strip()}")
        return 1
    provenance = dict(line.split("=", 1) for line in (root / "provenance.txt").read_text().splitlines() if "=" in line)
    # A run of uncommitted code is a rehearsal: what it shows belongs to no commit anyone can check out.
    check("ran committed code", provenance.get("dirty_files") == "0",
          f"commit {provenance.get('commit', '?')[:8]}, {provenance.get('dirty_files')} uncommitted file(s) in what it runs")
    # The run's own list of cases decides what is scored, so a run of one destructive case on its own cluster is not
    # failed for the cases it never ran; a name the scorer does not know, or none at all, fails rather than shrinking it.
    scope = provenance["cases"].split() if "cases" in provenance else list(DEFAULT_CASES)
    unknown = [n for n in scope if n not in CASES]
    check("the run's cases are known, each once", bool(scope) and not unknown and len(set(scope)) == len(scope),
          f"scoring {scope}; unknown {unknown}")
    if any(n in scope for n in ("rank-failed", "stale-workload", "node-lost", "cut-writer", "cut-writer-early")):
        check("the run has the reference its restarts are compared with", "reference" in scope, f"cases {scope}")
    reference = None

    case = Case(root, "reference")
    if "reference" in scope and present(case):
        reference = case.final_params(1)
        check("reference succeeded on attempt 1", case.status.get("phase") == "Succeeded" and len(case.attempts) == 1,
              f"phase {case.status.get('phase')}, attempts {len(case.attempts)}")
        check("reference has final parameters on every rank, and they agree", reference is not None,
              f"ranks {sorted(case.rank_params(1))} of world size {case.world()} recorded final parameters")

    case = Case(root, "rank-failed")
    if "rank-failed" in scope and present(case):
        restarted(case, reference, 5)

    case = Case(root, "stale-workload")
    if "stale-workload" in scope and present(case):
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
    if "deactivated" in scope and present(case):
        after = case.window("deactivated", "hold-end")
        # The fault itself is checked first: a job never deactivated also shows one attempt and no trigger.
        wl = next((m["mark"].split()[1] for m in case.marks if m["mark"].startswith("deactivated ")), None)
        inactive = [s for s in after if any(w["name"] == wl and w["active"] is False for w in s["workloads"])]
        check("deactivated the Workload was inactive through the minute after", bool(after) and len(inactive) == len(after),
              f"{len(inactive)} of {len(after)} samples show {wl} with active false")
        # Stopped is read from what the cluster reported, not from step records going quiet: a log stream that broke
        # would go quiet too. Kueue evicts by suspending the Job, and the Job controller then reports no active Pod.
        at = case.mark("deactivated")
        before = [r for r in case.records if r.get("event") == "step" and at and (ts(r.get("ts")) or math.inf) < ts(at)]
        name = (case.final.get("metadata") or {}).get("name")
        end = [j for j in (after[-1]["jobs"] if after else []) if j["name"] == name]
        check("deactivated training stopped",
              bool(before) and len(end) == 1 and end[0].get("suspend") is True and end[0].get("active") == 0
              and case.status.get("phase") not in ("Running", "Succeeded"),
              f"{len(before)} step records before deactivation; at the end the Job is {end[0] if end else 'absent'}; "
              f"phase {case.status.get('phase')}")
        check("deactivated no restart after an operator's deactivation", bool(after) and no_second_attempt(after)
              and all(not ((s.get("status") or {}).get("attempts") or [{}])[0].get("trigger") for s in after),
              f"{len(after)} samples over the minute after; attempts at the end {len(case.attempts)}")

    case = Case(root, "node-lost")
    if "node-lost" in scope and present(case):
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

    for name in ("cut-writer", "cut-writer-early"):
        case = Case(root, name)
        if name in scope and present(case):
            cut_writer(case, reference)

    print(f"{len(FAILED)} failed" if FAILED else "all checks passed")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
