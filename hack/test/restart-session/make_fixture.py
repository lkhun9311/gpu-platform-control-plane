"""Builds a run directory of the distributed restart paid session, as hack/lib/restart-session.sh would write it, with
one defect at a time, for hack/test/check-restart-session.sh to show score_eks.py refuses each.

    python3 hack/test/restart-session/make_fixture.py OUT [DEFECT CASE]

What is generated and what is copied:
- the NCCL lines are the producer's own, taken verbatim in shape from hack/four-gpu/2026-10-29-run4 (NCCL 2.21.5 on
  g5.xlarge over the VPC network), with only the host, the rank numbers and the address substituted;
- the line on which NCCL output and a trainer record share a line is the shape of
  hack/four-gpu/2026-10-29-run5/c/jobs/03-allreduce-4pod1gpu-5, line 46;
- the trainer records have the fields experiments/distributed-restart/train.py emits, and the MLTrainingJob status the
  fields api/v1 TrainingAttempt has, with the trigger on the attempt that was stopped, as the controller writes it.
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

    def __init__(self, attempt: int, rank: int, node: str, uid: str) -> None:
        self.attempt, self.rank, self.node, self.uid = attempt, rank, node, uid
        self.records: list[dict] = []

    def emit(self, t_runner: float, event: str, **fields) -> None:
        r = {"ts": iso(t_runner + NODES[self.node][1]), "run_id": "fixture", "attempt": self.attempt, "rank": self.rank,
             "event": event}
        r.update(fields)
        self.records.append(r)


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
    a1 = [Rank(1, 0, nodes[0], f"{name}-a1-r0"), Rank(1, 1, nodes[1], f"{name}-a1-r1")]
    case = {"kind": kind, "name": name, "job_id": f"rst-{name}-x", "target": {}}
    marks, attempts, probes = [], [], []
    trigger = {"no-rng-control": "RankFailed", "rank-kill": "RankFailed", "dcgm": "NodeFault"}.get(kind, "RankFailed")
    for r in a1:
        r.emit(t0, "start", world_size=2, backend="nccl", device="cuda:0", ballast_mb=16)
    if kind == "reference":
        for r in a1:
            train(r, t0 + 1, 1, STEPS, PARAMS if r.rank == 0 else None)
        attempts = [{"number": 1, "state": "Succeeded", "nodes": nodes[:2]}]
        ranks = a1
    else:
        stop = {"no-rng-control": 12, "rank-kill": 12}.get(kind, 14)
        resume = {"no-rng-control": 12, "rank-kill": 11}.get(kind, 13)
        for r in a1:
            train(r, t0 + 1, 1, stop - 1, None)
            # The step the fault interrupts is recorded and never checkpointed, which is the step a restart loses.
            r.emit(t0 + 1 + (stop - 1) * 2.3, "step", step=stop, loss=0.5, digest="0" * 64, params=None)
        t_fault = t0 + 1 + (stop - 1) * 2.3 + 0.05
        if kind == "rank-kill":
            a1[1].emit(t_fault, "fault", point="kill-before-fsync", step=12)
        elif kind == "no-rng-control":
            a1[0].emit(t_fault, "fault", point="kill-after-latest", step=12)
        elif kind == "dcgm":
            case["target"] = {"rank": 1, "node": nodes[1], "instance": NODES[nodes[1]][0]}
            json.dump({"node": nodes[1], "injected_at": iso(t_fault + NODES[nodes[1]][1]), "readback": "79", "latched": True,
                       "tainted": True}, open(d / "dcgm.json", "w"))
        else:
            case["target"] = {"rank": 1, "node": nodes[1], "instance": NODES[nodes[1]][0]}
            marks += [{"at": iso(t_fault), "mark": "fault-start"}, {"at": iso(t_fault + 0.4), "mark": "fault-end"},
                      {"at": iso(t_fault + 30), "mark": "terminated-read"}, {"at": iso(t_fault + 31), "mark": "fenced"}]
        # Where attempt 2 runs decides its class: the spare for terminate-spare and dcgm, a replacement for terminate-wait.
        second = {"terminate-wait": nodes[3], "terminate-spare": nodes[2], "dcgm": nodes[2]}.get(kind, nodes[1])
        a2 = [Rank(2, 0, nodes[0], f"{name}-a2-r0"), Rank(2, 1, second, f"{name}-a2-r1")]
        t2 = t_fault + 70
        final = [p + 0.5 for p in PARAMS] if kind == "no-rng-control" else PARAMS
        for r in a2:
            r.emit(t2, "resume", from_dir=f"a1/{resume:08d}-{'c' * 32}", from_step=resume)
            r.emit(t2 + 0.1, "start", world_size=2, backend="nccl", device="cuda:0", ballast_mb=16)
            train(r, t2 + 1, resume + 1, STEPS, final if r.rank == 0 else None)
        attempts = [{"number": 1, "state": "Stopped", "trigger": trigger, "nodes": nodes[:2]},
                    {"number": 2, "state": "Succeeded", "nodes": sorted({nodes[0], second})}]
        ranks = a1 + a2
    before = [n for n in nodes if n != nodes[3]]
    for node in nodes:
        when = []
        if node in before:
            when.append("before")
        if not (kind.startswith("terminate") and node == nodes[1]):
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
            f.write(json.dumps({"uid": r.uid, "pod": f"{name}-{r.rank}-{r.attempt}", "node": r.node, "index": str(r.rank),
                                "observed": iso(t0 + i)}) + "\n")
    with open(d / "clock.jsonl", "w") as f:
        for p in probes:
            f.write(json.dumps(p) + "\n")
    with open(d / "marks.jsonl", "w") as f:
        for m in marks:
            f.write(json.dumps(m) + "\n")
    json.dump(case, open(d / "case.json", "w"))
    json.dump({"status": {"phase": "Succeeded", "attempts": attempts}}, open(d / "final-mltj.json", "w"))
    json.dump({"items": [{"metadata": {"name": n}, "spec": {"providerID": f"aws:///ap-northeast-2a/{NODES[n][0]}"}}
                         for n in before]}, open(d / "nodes-before.json", "w"))


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
    elif name == "timed-out":
        # What a recovery that never came looks like: no attempt 2 records, the job still Pending at the budget.
        edit_records(d, lambda r: None if r["attempt"] == 2 else r)
        edit_json(d / "final-mltj.json", lambda m: (m["status"].update(phase="Pending"), m["status"]["attempts"][1].update(state="Preparing")))
    elif name == "wrong-instance":
        edit_json(d / "case.json", lambda c: c["target"].update(instance="i-0fff0000000000009"))
    elif name == "readback-not-79":
        edit_json(d / "dcgm.json", lambda x: x.update(readback="0"))
    elif name == "not-latched":
        edit_json(d / "dcgm.json", lambda x: x.update(latched=False))
    elif name == "no-terminated-mark":
        edit_json_lines(d / "marks.jsonl", lambda m: None if m["mark"] == "terminated-read" else m)
    elif name == "cpu-backend":
        edit_records(d, lambda r: {**r, "backend": "gloo", "device": "cpu"} if r["event"] == "start" else r)
    elif name == "missing-case":
        import shutil
        shutil.rmtree(d)
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
    if len(argv) == 4:
        defect(out, argv[2], argv[3])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
