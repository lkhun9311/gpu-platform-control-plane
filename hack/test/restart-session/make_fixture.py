"""Builds a run directory of the distributed restart paid session, as hack/lib/restart-session.sh would write it, with
one defect at a time, for hack/test/check-restart-session.sh to show score_eks.py refuses each.

    python3 hack/test/restart-session/make_fixture.py OUT [DEFECT CASE]

What is generated and what is copied:
- the NCCL lines are the producer's own, taken verbatim in shape from hack/four-gpu/2026-10-29-run4 (NCCL 2.21.5 on
  g5.xlarge over the VPC network), with only the host, the rank numbers and the address substituted;
- the line on which NCCL output and a trainer record share a line is the shape of
  hack/four-gpu/2026-10-29-run5/c/jobs/03-allreduce-4pod1gpu-5, line 46;
- the trainer records have the fields experiments/distributed-restart/train.py emits, every rank's final parameters
  included, and the MLTrainingJob status the fields api/v1 TrainingAttempt has, with the trigger on the attempt that
  was stopped, as the controller writes it;
- the other files are those hack/lib/restart-session.sh writes, in its shapes: pods.jsonl, marks.jsonl, clock.jsonl,
  timeline.jsonl, shared-files.txt, nodes-before.json and nodes-after.json per case, nodes-prepared.jsonl per run.
Times are synthetic: every node's clock runs a fixed offset from the runner's, and every probe sees it.
"""

from __future__ import annotations

import copy
import datetime
import json
import pathlib
import sys

STEPS = 30
REPS = 5
BASE = datetime.datetime(2026, 11, 2, 1, 0, 0, tzinfo=datetime.timezone.utc).timestamp()
NODES = {"ip-10-0-64-11": ("i-0aaa0000000000001", 0.25), "ip-10-0-64-12": ("i-0aaa0000000000002", -0.4),
         "ip-10-0-64-13": ("i-0aaa0000000000003", 0.1), "ip-10-0-64-14": ("i-0aaa0000000000004", 0.6)}
PARAMS = [0.125 * i - 1.0 for i in range(49)]


def epoch(ts: str) -> float:
    return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()


def iso(t: float) -> str:
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).isoformat()


def nccl_log(host: str, rank: int, world: int, transport: str = "NET/Socket/0", network: str = "Socket") -> str:
    peer = (rank + 1) % world
    return "".join([
        f"{host}:1:1 [0] NCCL INFO NET/Plugin: No plugin found (libnccl-net.so)\n",
        f"{host}:1:1 [0] NCCL INFO NET/Plugin: Using internal network plugin.\n",
        f"{host}:1:72 [0] NCCL INFO NET/Socket : Using [0]eth0:10.0.64.{20 + rank}<0>\n",
        f"{host}:1:72 [0] NCCL INFO Using network {network}\n",
        f"{host}:1:72 [0] NCCL INFO Channel 00/0 : {peer}[0] -> {rank}[0] [receive] via {transport}\n",
        f"{host}:1:72 [0] NCCL INFO Channel 01/0 : {peer}[0] -> {rank}[0] [receive] via {transport}\n",
        f"{host}:1:72 [0] NCCL INFO Channel 00/0 : {rank}[0] -> {peer}[0] [send] via {transport}\n",
    ])


class Rank:
    """One rank of one attempt: its Pod, its node and the records it prints."""

    def __init__(self, run_id: str, attempt: int, rank: int, node: str, uid: str) -> None:
        self.run_id, self.attempt, self.rank, self.node, self.uid = run_id, attempt, rank, node, uid
        self.records: list[dict] = []

    def emit(self, t_runner: float, event: str, **fields) -> None:
        r = {"ts": iso(t_runner + NODES[self.node][1]), "run_id": self.run_id, "attempt": self.attempt, "rank": self.rank,
             "event": event}
        r.update(fields)
        self.records.append(r)


def api_time(t: float) -> str:
    """A time as the API server writes a metav1.Time: whole seconds, truncated, with a Z."""
    return datetime.datetime.fromtimestamp(int(t), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def node_uid(node: str, case: str) -> str:
    # The fourth node is the one the group launches after a termination, so it is a new machine, and a new Node, per case.
    return f"uid-{node}-{case}" if node == list(NODES)[3] else f"uid-{node}"


def node_list(names: list[str], case: str) -> dict:
    return {"items": [{"metadata": {"name": n, "uid": node_uid(n, case)},
                       "spec": {"providerID": f"aws:///ap-northeast-2a/{NODES[n][0]}"}} for n in names]}


def train(r: Rank, t: float, first: int, last: int, final: list[float] | None) -> float:
    for step in range(first, last + 1):
        r.emit(t, "step", step=step, loss=0.5, digest="0" * 64, params=final if step == STEPS else None)
        r.emit(t + 0.1, "checkpoint", step=step, dir=f"a{r.attempt}/{step:08d}-{'c' * 32}", save_s=0.08 + 0.001 * step)
        t += 2.3
    return t


def case_dir(out: pathlib.Path, name: str, kind: str, n: int) -> None:
    d = out / name
    (d / "nccl").mkdir(parents=True)
    t0 = BASE + n * 1000
    nodes = list(NODES)
    # The runner names the job rst-<case>-<time> and the trainer's run_id is that name (CKPT_RUN_ID in restart_render_job).
    job = f"rst-{name}-010000"
    a1 = [Rank(job, 1, 0, nodes[0], f"{name}-a1-r0"), Rank(job, 1, 1, nodes[1], f"{name}-a1-r1")]
    case = {"kind": kind, "name": job, "job_id": f"{job}-0a1b2c3d", "target": {}}
    marks, attempts, probes, timeline = [], [], [], []
    annotations: dict[str, str] = {}
    trigger = {"no-rng-control": "RankFailed", "rank-kill": "RankFailed", "dcgm": "NodeFault"}.get(kind, "RankFailed")
    for r in a1:
        r.emit(t0, "start", world_size=2, backend="nccl", device="cuda:0", ballast_mb=16)
    # terminate-wait runs with the group at two, so no node is up before the fault but the two attempt 1 runs on.
    before = nodes[:2] if kind == "terminate-wait" else nodes[:3]
    after = list(before)
    published = []
    if kind == "reference":
        for r in a1:
            train(r, t0 + 1, 1, STEPS, PARAMS)
        attempts = [{"number": 1, "state": "Succeeded", "nodes": nodes[:2], "createdAt": api_time(t0 - 5)}]
        ranks = a1
        t_end = t0 + 1 + STEPS * 2.3
    else:
        stop = {"no-rng-control": 12, "rank-kill": 12}.get(kind, 14)
        resume = {"no-rng-control": 12, "rank-kill": 11}.get(kind, 13)
        for r in a1:
            train(r, t0 + 1, 1, stop - 1, None)
            # The step the fault interrupts is recorded and never checkpointed, which is the step a restart loses.
            r.emit(t0 + 1 + (stop - 1) * 2.3, "step", step=stop, loss=0.5, digest="0" * 64, params=None)
        t_fault = t0 + 1 + (stop - 1) * 2.3 + 0.05
        t_create = t_fault + 20
        if kind == "rank-kill":
            a1[1].emit(t_fault, "fault", point="kill-before-fsync", step=12)
        elif kind == "no-rng-control":
            a1[0].emit(t_fault, "fault", point="kill-after-latest", step=12)
            # kill-after-latest dies after LATEST names step 12 and before the barrier, so its manifest is on the volume
            # and no rank recorded the checkpoint.
            published.append(f"a1/{12:08d}-{'c' * 32}")
        elif kind == "dcgm":
            case["target"] = {"rank": 1, "node": nodes[1], "instance": NODES[nodes[1]][0]}
            json.dump({"node": nodes[1], "injected_at": iso(t_fault + NODES[nodes[1]][1]), "readback": "79", "latched": True,
                       "tainted": True}, open(d / "dcgm.json", "w"))
        else:
            case["target"] = {"rank": 1, "node": nodes[1], "instance": NODES[nodes[1]][0]}
            marks += [{"at": iso(t_fault), "mark": "fault-start"}, {"at": iso(t_fault + 0.4), "mark": "fault-end"},
                      {"at": iso(t_fault + 30), "mark": "terminated-read"}, {"at": iso(t_fault + 31), "mark": "fenced"}]
            annotations["platform.lkhun9311.github.io/fenced-nodes"] = nodes[1]
            # The terminated node's object is gone by the end, and the group has launched one in its place.
            after = [x for x in before if x != nodes[1]] + [nodes[3]]
            t_create = t_fault + 40
        # Where attempt 2 runs decides its class: the spare for terminate-spare and dcgm, a replacement for terminate-wait.
        second = {"terminate-wait": nodes[3], "terminate-spare": nodes[2], "dcgm": nodes[2]}.get(kind, nodes[1])
        a2 = [Rank(job, 2, 0, nodes[0], f"{name}-a2-r0"), Rank(job, 2, 1, second, f"{name}-a2-r1")]
        t2 = t_fault + 70
        final = [p + 0.5 for p in PARAMS] if kind == "no-rng-control" else PARAMS
        for r in a2:
            r.emit(t2, "resume", from_dir=f"a1/{resume:08d}-{'c' * 32}", from_step=resume)
            r.emit(t2 + 0.1, "start", world_size=2, backend="nccl", device="cuda:0", ballast_mb=16)
            train(r, t2 + 1, resume + 1, STEPS, final)
        attempts = [{"number": 1, "state": "Stopped", "trigger": trigger, "nodes": nodes[:2], "createdAt": api_time(t0 - 5)},
                    {"number": 2, "state": "Succeeded", "nodes": sorted({nodes[0], second}), "createdAt": api_time(t_create)}]
        ranks = a1 + a2
        t_end = t2 + 1 + (STEPS - resume) * 2.3
        timeline.append({"observed": iso(t_fault - 1), "status": {"phase": "Running", "attempts": [{**attempts[0], "state": "Active"}]},
                         "annotations": None})
        timeline.append({"observed": iso(t_create + 3), "status": {"phase": "Running", "attempts": [attempts[0], {**attempts[1], "state": "Active"}]},
                         "annotations": dict(annotations) or None})
    first = {k: v for k, v in attempts[0].items() if k != "trigger"}
    timeline.insert(0, {"observed": iso(t0 + 2), "status": {"phase": "Running", "attempts": [{**first, "state": "Active"}]},
                        "annotations": None})
    timeline.append({"observed": iso(t_end + 2), "status": {"phase": "Succeeded", "attempts": attempts},
                     "annotations": dict(annotations) or None})
    for node in nodes:
        when = []
        if node in before:
            when.append("before")
        if node in after:
            when.append("after")
        for w in when:
            t = t0 + (0 if w == "before" else 200)
            probes.append({"node": node, "pod": f"dcgm-{node}", "before": t, "node_time": t + 0.05 + NODES[node][1],
                           "after": t + 0.1, "when": w})
    for r in ranks:
        with open(d / f"log-{r.uid}.1.txt", "w") as f:
            for rec in r.records:
                f.write(json.dumps(rec) + "\n")
        (d / "nccl" / f"a{r.attempt}-r{r.rank}-{name}-{r.rank}.{7 + r.attempt}.log").write_text(
            nccl_log(f"{name}-{r.rank}", r.rank, 2))
    with open(d / "pods.jsonl", "w") as f:
        for i, r in enumerate(ranks):
            f.write(json.dumps({"uid": r.uid, "pod": f"{job}-{r.rank}-{r.attempt}", "node": r.node, "index": str(r.rank),
                                "observed": iso(t0 + i)}) + "\n")
    with open(d / "clock.jsonl", "w") as f:
        for p in probes:
            f.write(json.dumps(p) + "\n")
    with open(d / "marks.jsonl", "w") as f:
        for m in marks:
            f.write(json.dumps(m) + "\n")
    with open(d / "timeline.jsonl", "w") as f:
        for s in timeline:
            f.write(json.dumps(s, sort_keys=True) + "\n")
    # What `find` on the job's directory lists once its writers are retired: every published checkpoint's manifest and
    # shards, LATEST, and the NCCL logs.
    published += sorted({rec["dir"] for r in ranks for rec in r.records if rec["event"] == "checkpoint"})
    root = f"/state/{case['job_id']}"
    listing = [f"{root}/LATEST"] + [f"{root}/{p}/{f}" for p in published for f in ("MANIFEST", "rank-0.pt", "rank-1.pt")]
    listing += [f"{root}/nccl/{f.name}" for f in sorted((d / "nccl").glob("*.log"))]
    (d / "shared-files.txt").write_text("".join(line + "\n" for line in listing))
    json.dump(case, open(d / "case.json", "w"))
    json.dump({"metadata": {"name": job, "annotations": annotations}, "status": {"phase": "Succeeded", "attempts": attempts}},
              open(d / "final-mltj.json", "w"))
    json.dump(node_list(before, name), open(d / "nodes-before.json", "w"))
    json.dump(node_list(after, name), open(d / "nodes-after.json", "w"))


def cases() -> list[tuple[str, str]]:
    out = [("reference", "reference"), ("no-rng-control", "no-rng-control")]
    for kind in ("rank-kill", "dcgm", "terminate-spare", "terminate-wait"):
        out += [(f"{kind}-{i}", kind) for i in range(1, REPS + 1)]
    return out


def edit_json(path: pathlib.Path, change) -> None:
    doc = json.loads(path.read_text())
    change(doc)
    path.write_text(json.dumps(doc))


def edit_records(d: pathlib.Path, keep) -> None:
    """Rewrites every rank log, keeping a record when keep(record) returns it, possibly changed, and dropping it on None."""
    for log in d.glob("log-*.txt"):
        out = []
        for line in log.read_text().splitlines():
            rec = keep(json.loads(line))
            if rec is not None:
                out.append(json.dumps(rec))
        log.write_text("\n".join(out) + ("\n" if out else ""))


def defect(out: pathlib.Path, name: str, case: str) -> None:
    d = out / case
    if name == "missing-rank":
        edit_records(d, lambda r: None if r["attempt"] == 2 and r["rank"] == 1 else r)
    elif name == "restart-from-zero":
        def zero(r):
            if r["attempt"] == 2 and r["event"] == "resume":
                return {**{k: r[k] for k in ("ts", "run_id", "attempt", "rank")}, "event": "restart_from_zero", "load_mode": "full"}
            return r
        edit_records(d, zero)
    elif name == "resume-from-step-zero":
        edit_records(d, lambda r: {**r, "from_step": 0, "from_dir": "a1/00000000-" + "c" * 32} if r["event"] == "resume" else r)
    elif name == "split-resume":
        edit_records(d, lambda r: {**r, "from_dir": "a1/elsewhere"} if r["event"] == "resume" and r["rank"] == 1 else r)
    elif name == "no-fault-record":
        edit_records(d, lambda r: None if r["event"] == "fault" else r)
    elif name == "no-clock-probe":
        (d / "clock.jsonl").write_text("")
    elif name == "skewed-clock":
        edit_json_lines(d / "clock.jsonl", lambda p: {**p, "node_time": p["node_time"] + 5})
    elif name == "clock-disagree":
        # Each probe alone is within the registered offset, and their median is zero, but the clock moved 3.8 s between them.
        edit_json_lines(d / "clock.jsonl", lambda p: {**p, "node_time": (p["before"] + p["after"]) / 2 + (-1.9 if p["when"] == "before" else 1.9)}
                        if p["node"] == "ip-10-0-64-11" else p)
    elif name in ("clock-no-before", "clock-no-after"):
        gone = name.rsplit("-", 1)[1]
        edit_json_lines(d / "clock.jsonl", lambda p: None if p["node"] == "ip-10-0-64-11" and p["when"] == gone else p)
    elif name == "slow-probe":
        edit_json_lines(d / "clock.jsonl", lambda p: {**p, "after": p["before"] + 0.9})
    elif name == "no-nccl-log":
        for f in (d / "nccl").glob("*"):
            f.unlink()
    elif name == "one-nccl-log-missing":
        next((d / "nccl").glob("a2-r1-*.log")).unlink()
    elif name in ("shm-transport", "p2p-transport", "ib-transport"):
        via = {"shm-transport": "SHM/direct/direct", "p2p-transport": "P2P/IPC", "ib-transport": "NET/IB/0"}[name]
        log = next((d / "nccl").glob("a2-r0-*.log"))
        log.write_text(log.read_text() + f"{case}-0:1:72 [0] NCCL INFO Channel 02/0 : 1[0] -> 0[0] [receive] via {via}\n")
    elif name == "ib-network":
        log = next((d / "nccl").glob("a1-r0-*.log"))
        log.write_text(log.read_text().replace("Using network Socket", "Using network IB"))
    elif name == "wrong-trigger":
        edit_json(d / "final-mltj.json", lambda m: m["status"]["attempts"][0].update(trigger="JobDeleted"))
    elif name == "trigger-on-attempt-2":
        def move(m):
            a = m["status"]["attempts"]
            a[1]["trigger"] = a[0].pop("trigger")
        edit_json(d / "final-mltj.json", move)
    elif name == "params-off":
        edit_records(d, lambda r: {**r, "params": [p + 1e-3 for p in r["params"]]} if r.get("params") else r)
    elif name == "params-nan":
        edit_records(d, lambda r: {**r, "params": [float("nan")] * len(r["params"])} if r.get("params") else r)
    elif name in ("rank1-params-nan", "rank1-params-off", "rank1-params-missing"):
        # Only rank 1's last step changes, so a scorer reading rank 0 alone sees a run that ended right.
        change = {"rank1-params-nan": lambda p: [float("nan")] * len(p), "rank1-params-off": lambda p: [v + 1e-3 for v in p],
                  "rank1-params-missing": lambda p: None}[name]
        edit_records(d, lambda r: {**r, "params": change(r["params"])} if r.get("params") and r["rank"] == 1 else r)
    elif name == "foreign-run-id":
        edit_records(d, lambda r: {**r, "run_id": "rst-another-job"})
    elif name == "world-99":
        edit_records(d, lambda r: {**r, "world_size": 99} if r["event"] == "start" else r)
    elif name == "unlisted-pod":
        log = next(d.glob("log-*a2-r1*"))
        log.rename(d / log.name.replace("a2-r1", "a2-r9"))
    elif name == "rank-not-index":
        # Attempt 2's rank-1 records come from a Pod the collector saw as index 0.
        edit_json_lines(d / "pods.jsonl", lambda p: {**p, "index": "0"} if p["uid"].endswith("a2-r1") else p)
    elif name == "pod-off-attempt-nodes":
        edit_json_lines(d / "pods.jsonl", lambda p: {**p, "node": "ip-10-0-64-14"} if p["uid"].endswith("a2-r1") else p)
    elif name == "pod-two-attempts":
        # One Pod's log holds records of both attempts, which no Pod of an Indexed Job recreated per attempt can print.
        a1 = next(d.glob("log-*a1-r1*"))
        a2 = next(d.glob("log-*a2-r1*"))
        a1.write_text(a1.read_text() + a2.read_text())
        a2.unlink()
    elif name == "pods-out-of-order":
        edit_json_lines(d / "pods.jsonl", lambda p: {**p, "observed": "2026-11-01T00:00:00+00:00"} if "-a2-" in p["uid"] else p)
    elif name == "resume-later-attempt":
        edit_records(d, lambda r: {**r, "from_dir": r["from_dir"].replace("a1/", "a2/")} if r["event"] == "resume" else r)
    elif name == "resume-dir-step-mismatch":
        edit_records(d, lambda r: {**r, "from_dir": r["from_dir"].replace("/00000013-", "/00000012-")} if r["event"] == "resume" else r)
    elif name == "manifest-unlisted":
        listing = d / "shared-files.txt"
        listing.write_text("".join(line + "\n" for line in listing.read_text().splitlines() if not line.endswith("/00000013-" + "c" * 32 + "/MANIFEST")))
    elif name == "no-volume-listing":
        (d / "shared-files.txt").unlink()
    elif name == "resume-gap":
        # Steps 14 and 15 of attempt 2 are missing, so its first step is not the one after the checkpoint it names.
        edit_records(d, lambda r: None if r["attempt"] == 2 and r["event"] in ("step", "checkpoint") and r["step"] in (14, 15) else r)
    elif name == "rank1-no-final-step":
        edit_records(d, lambda r: None if r["rank"] == 1 and r["event"] in ("step", "checkpoint") and r["step"] == STEPS else r)
    elif name == "timed-out":
        # What a recovery that never came looks like: no attempt 2 records, the job still Pending at the budget.
        edit_records(d, lambda r: None if r["attempt"] == 2 else r)
        edit_json(d / "final-mltj.json", lambda m: (m["status"].update(phase="Pending"), m["status"]["attempts"][1].update(state="Preparing")))
    elif name == "job-failed":
        # The controller gave up: the job ended Failed within its budget, which is a recovery that did not happen, not a
        # recovery cut off by the budget.
        edit_records(d, lambda r: None if r["attempt"] == 2 else r)
        edit_json(d / "final-mltj.json", lambda m: (m["status"].update(phase="Failed"), m["status"]["attempts"].pop()))
    elif name == "wrong-instance":
        edit_json(d / "case.json", lambda c: c["target"].update(instance="i-0fff0000000000009"))
    elif name == "readback-not-79":
        edit_json(d / "dcgm.json", lambda x: x.update(readback="0"))
    elif name == "not-latched":
        edit_json(d / "dcgm.json", lambda x: x.update(latched=False))
    elif name == "no-terminated-mark":
        edit_json_lines(d / "marks.jsonl", lambda m: None if m["mark"] == "terminated-read" else m)
    elif name == "no-fenced-mark":
        edit_json_lines(d / "marks.jsonl", lambda m: None if m["mark"] == "fenced" else m)
    elif name == "fence-before-terminated":
        # The runner fenced ten seconds after the call, twenty before EC2 said terminated.
        start = next(epoch(m["at"]) for m in map(json.loads, (d / "marks.jsonl").read_text().splitlines()) if m["mark"] == "fault-start")
        edit_json_lines(d / "marks.jsonl", lambda m: {**m, "at": iso(start + 10)} if m["mark"] == "fenced" else m)
    elif name == "no-fence-annotation":
        edit_json(d / "final-mltj.json", lambda m: m["metadata"].update(annotations={}))
    elif name == "created-before-fence":
        # The controller created attempt 2 26 s before the fence, and its status says so in whole seconds.
        fenced = next(epoch(m["at"]) for m in map(json.loads, (d / "marks.jsonl").read_text().splitlines()) if m["mark"] == "fenced")
        edit_json(d / "final-mltj.json", lambda m: m["status"]["attempts"][1].update(createdAt=api_time(fenced - 26)))
    elif name == "seen-before-fence":
        # A sample the runner took before the fence already shows attempt 2.
        fenced = next(epoch(m["at"]) for m in map(json.loads, (d / "marks.jsonl").read_text().splitlines()) if m["mark"] == "fenced")
        rows = [json.loads(line) for line in (d / "timeline.jsonl").read_text().splitlines()]
        rows.insert(1, {**rows[-1], "observed": iso(fenced - 20)})
        (d / "timeline.jsonl").write_text("".join(json.dumps(r, sort_keys=True) + "\n" for r in rows))
    elif name in ("wait-on-spare", "name-reused", "spare-on-replacement", "on-terminated-node"):
        # Attempt 2's rank 1 is moved to another node, in the controller's status and in the collector's Pod list alike.
        spare, target, fourth = "ip-10-0-64-13", "ip-10-0-64-12", "ip-10-0-64-14"
        to = {"wait-on-spare": spare, "spare-on-replacement": fourth}.get(name, target)
        edit_json(d / "final-mltj.json", lambda m: m["status"]["attempts"][1].update(nodes=sorted({"ip-10-0-64-11", to})))
        edit_json_lines(d / "pods.jsonl", lambda p: {**p, "node": to} if p["uid"].endswith("a2-r1") else p)
        probes = [json.loads(line) for line in (d / "clock.jsonl").read_text().splitlines()]
        if name == "wait-on-spare":
            # The group held a third node before the fault, which terminate-wait registers it does not.
            for f in ("nodes-before.json", "nodes-after.json"):
                edit_json(d / f, lambda n: n["items"].append({"metadata": {"name": spare, "uid": node_uid(spare, case)},
                                                              "spec": {"providerID": f"aws:///ap-northeast-2a/{NODES[spare][0]}"}}))
            probes += [{**p, "node": spare, "node_time": p["node_time"] - NODES["ip-10-0-64-11"][1] + NODES[spare][1]}
                       for p in probes if p["node"] == "ip-10-0-64-11"]
        elif name == "name-reused":
            # The machine the group launched took the terminated node's name: same name, another Node.
            edit_json(d / "nodes-after.json", lambda n: n["items"].append({"metadata": {"name": target, "uid": f"uid-{target}-new"},
                                                                           "spec": {"providerID": "aws:///ap-northeast-2a/i-0bbb0000000000009"}}))
            probes += [{**p, "node": target, "node_time": p["node_time"] - NODES["ip-10-0-64-11"][1] + NODES[target][1]}
                       for p in probes if p["node"] == "ip-10-0-64-11" and p["when"] == "after"]
        elif name == "on-terminated-node":
            # The target is still there afterwards, as the same Node, and attempt 2 ran on it.
            edit_json(d / "nodes-after.json", lambda n: n["items"].append({"metadata": {"name": target, "uid": node_uid(target, case)},
                                                                           "spec": {"providerID": f"aws:///ap-northeast-2a/{NODES[target][0]}"}}))
        (d / "clock.jsonl").write_text("".join(json.dumps(p) + "\n" for p in probes))
    elif name == "spare-unprepared":
        edit_json_lines(out / "nodes-prepared.jsonl", lambda p: None if p["node"] == "ip-10-0-64-13" else p)
    elif name in ("drop-node-before", "drop-node-after"):
        which, node = ("nodes-before.json", "ip-10-0-64-11") if name == "drop-node-before" else ("nodes-after.json", "ip-10-0-64-13")
        edit_json(d / which, lambda n: n.update(items=[i for i in n["items"] if i["metadata"]["name"] != node]))
    elif name == "no-nodes-after":
        (d / "nodes-after.json").unlink()
    elif name == "no-created-at":
        edit_json(d / "final-mltj.json", lambda m: m["status"]["attempts"][1].pop("createdAt"))
    elif name == "no-timeline":
        (d / "timeline.jsonl").unlink()
    elif name == "cpu-backend":
        edit_records(d, lambda r: {**r, "backend": "gloo", "device": "cpu"} if r["event"] == "start" else r)
    elif name == "missing-case":
        import shutil
        shutil.rmtree(d)
    elif name == "empty-final":
        # What one failed `kubectl get` leaves: the file exists and holds nothing.
        (d / "final-mltj.json").write_text("")
    elif name == "voided":
        (d / "VOID").write_text("the runner could not deliver the fault")
    elif name == "dirty":
        edit_provenance(out, "dirty_files", "3")
    elif name == "unapproved":
        edit_provenance(out, "approved_train_py_sha256", "f" * 64)
    elif name == "interleaved":
        # The producer's shape: an NCCL line left unfinished, and a trainer record on the same line after it.
        # The record is attempt 2 rank 0's resume, so a scorer that dropped it would refuse the case for a missing rank.
        log = next(d.glob("log-*a2-r0*"))
        lines = log.read_text().splitlines()
        lines[0] = f"{case}-0:1:72 [0] NCCL INFO Channel 01/0 : 1[0] -> 0[0] [send] via NET/Socket" + lines[0]
        log.write_text("\n".join(lines) + "\n")
    elif name == "duplicate-stream":
        log = next(d.glob("log-*a2-r0*"))
        (d / log.name.replace(".1.txt", ".2.txt")).write_text(log.read_text())
    elif name != "none":
        sys.exit(f"unknown defect {name}")


def edit_json_lines(path: pathlib.Path, change) -> None:
    rows = [change(json.loads(line)) for line in path.read_text().splitlines() if line.strip()]
    path.write_text("".join(json.dumps(r) + "\n" for r in rows if r is not None))


def edit_provenance(out: pathlib.Path, key: str, value: str) -> None:
    path = out / "provenance.txt"
    path.write_text("".join(f"{key}={value}\n" if line.startswith(key + "=") else line + "\n"
                            for line in path.read_text().splitlines()))


def main(argv: list[str]) -> int:
    out = pathlib.Path(argv[1])
    out.mkdir(parents=True)
    names = cases()
    (out / "provenance.txt").write_text(
        f"commit={'a' * 40}\ndirty_files=0\ntrain_py_sha256={'b' * 64}\napproved_train_py_sha256={'b' * 64}\n"
        f"steps={STEPS}\ncases={' '.join(n for n, _ in names)}\n")
    for i, (name, kind) in enumerate(names):
        case_dir(out, name, kind, i)
    # The runner prepares the three nodes it bought before the first case; a replacement is prepared after its case.
    with open(out / "nodes-prepared.jsonl", "w") as f:
        for node in list(NODES)[:3]:
            f.write(json.dumps({"node": node, "prepared_at": iso(BASE - 600)}) + "\n")
    if len(argv) == 4:
        defect(out, argv[2], argv[3])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
