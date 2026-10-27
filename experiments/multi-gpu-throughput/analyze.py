"""Scores experiment C (docs/superpowers/specs/2026-10-27-four-gpu-nccl-design.md) from a session's evidence.

    analyze.py EVIDENCE --bench-sha256 HEX --step-sha256 HEX
    analyze.py --job JOB_DIR --bench-sha256 HEX --step-sha256 HEX --node NAME

The first form reads the qualification (Q), every job, and prints each job VALID or INVALID with every reason, the
endpoints per arm and the verdicts; it exits 0 only when Q and every registered job are valid.
The second form judges one job, for the session's stop rule after each smoke job, and exits 0 only if it is valid.

Evidence missing is a failure, never a pass. A figure is printed only for a valid job, and an arm reports an endpoint
only when all its registered jobs are valid.
Nothing here imports torch; it reads what the jobs wrote.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import sys
from pathlib import Path

ARMS = ("nccltests-1pod4gpu", "allreduce-1pod4gpu", "allreduce-4pod1gpu", "ddp-1pod4gpu", "ddp-4pod1gpu")
SHAPES = {"nccltests-1pod4gpu": (1, 4), "allreduce-1pod4gpu": (1, 4), "allreduce-4pod1gpu": (4, 1),
          "ddp-1pod4gpu": (1, 4), "ddp-4pod1gpu": (4, 1)}
RANKS = 4
REPS = 5
SIZES = (1 << 20, 1 << 22, 1 << 24, 1 << 26, 1 << 28)
WARMUP, ITERS = 20, 100
STEP_WARMUP, STEP_PAIRS = 20, 50
STEP_MODEL = {"layers": 4, "width": 4096, "batch": 64}
NCCL_VERSION = "2.21.5"
# NVIDIA's stated interconnect figure for the A10, which has no NVLink; a bus bandwidth above it is an instrument error.
CEILING_GBPS = 64.0
# The only NCCL_ variables an arm may start with. NCCL_VERSION is the CUDA base image's package label, which NCCL does
# not read as a parameter; it is allowed by name in the nccl-tests arm only, whose base sets it.
ALLOWED_NCCL_ENV = {"NCCL_DEBUG": "INFO", "NCCL_DEBUG_SUBSYS": "INIT,GRAPH,ENV"}
NCCLTESTS_EXTRA_ENV = {"NCCL_VERSION": "2.21.5-1"}
# The registered nccl-tests flags; -a 3 reports the slowest rank's time, as the torch bench does.
NCCLTESTS_FLAGS = ("-b 1M", "-e 256M", "-f 4", "-g 1", "-c 1", "-n 100", "-w 20", "-a 3")
SHM_MIN_KB = 1 << 20
# The registered per-job budget, a convention (the registration's "Budget").
JOB_BUDGET_SECONDS = 240

NCCL_LINE = re.compile(r"^(?P<host>[^:\s]+):(?P<pid>\d+):(?P<tid>\d+) \[(?P<dev>\d+)\] NCCL INFO (?P<msg>.*)$")
# The bracket after a rank is a device index in some NCCL versions and a hexadecimal bus ID in others.
CHANNEL = re.compile(r"Channel \d+/\d+ : \d+\[[0-9a-fA-F]+\] -> \d+\[[0-9a-fA-F]+\](?: \[\w+\])? via (?P<via>\S+)")
SET_BY_ENV = re.compile(r"^(?P<name>NCCL_[A-Z0-9_]+) set by environment to (?P<value>.*)$")
# NCCL 2.21.5's rank 0 prints this banner with a bare printf, without the host:pid:tid prefix (showVersion in its
# src/init.cc), so it is read from every line, prefixed or not.
NCCL_VERSION_LINE = re.compile(r"(?:^|NCCL INFO )NCCL version (?P<v>[0-9.]+)\+")
NT_RANK = re.compile(r"^#\s+Rank\s+(?P<rank>\d+) Group\s+\d+ Pid\s+(?P<pid>\d+) on\s+(?P<host>\S+) device\s+(?P<dev>\d+) "
                     r"\[0x(?P<bus>[0-9a-f]+)\] (?P<name>.+)$")
NT_HEADER = re.compile(r"^# nThread (?P<threads>\d+) nGpus (?P<gpus>\d+) minBytes (?P<min>\d+) maxBytes (?P<max>\d+) "
                       r"step: (?P<step>\d+)\(factor\) warmup iters: (?P<warmup>\d+) iters: (?P<iters>\d+) "
                       r"agg iters: (?P<agg>\d+) validation: (?P<check>\d+) graph: (?P<graph>\d+)")
NT_ROW = re.compile(r"^\s*(?P<size>\d+)\s+(?P<count>\d+)\s+float\s+sum\s+-?\d+\s+"
                    r"(?P<t1>[\d.]+)\s+(?P<alg1>[\d.]+)\s+(?P<bus1>[\d.]+)\s+(?P<wrong1>\S+)\s+"
                    r"(?P<t2>[\d.]+)\s+(?P<alg2>[\d.]+)\s+(?P<bus2>[\d.]+)\s+(?P<wrong2>\S+)\s*$")
GPU_LINE = re.compile(r"^AR_GPU (?P<index>\d+), GPU-(?P<uuid>[0-9a-f-]+), (?P<bus>[0-9A-Fa-f]+:[0-9A-Fa-f]+):"
                      r"(?P<dev>[0-9A-Fa-f]+)\.(?P<fn>\d), (?P<driver>[\d.]+)$")
ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;]*m")


def transport_of(via: str) -> str:
    """P2P, SHM or NET from NCCL's 'via' token, such as P2P/IPC, P2P/CUMEM/read, SHM/direct/direct, NET/Socket/0."""
    return via.split("/", 1)[0]


def norm_uuid(text: str) -> str:
    return text.strip().lower().removeprefix("gpu-")


class Job:
    """One job's evidence and what was found wrong with it."""

    def __init__(self, path: Path):
        self.path = path
        self.faults: list[str] = []
        self.arm = read_text(path / "arm")
        self.name = read_text(path / "name")
        self.figures: dict = {}
        self.transports: dict[int, list[str]] = {}
        self.stack_env: dict[str, str] = {}
        self.uuids: dict[int, str] = {}

    def fault(self, text: str) -> None:
        self.faults.append(text)

    @property
    def valid(self) -> bool:
        return not self.faults


def read_text(path: Path) -> str:
    try:
        return path.read_text().strip()
    except OSError:
        return ""


def read_json(path: Path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def last_samples(job: Job) -> dict:
    """The last sample of every Pod the collector ever saw, by UID; an unparsable line fails the job."""
    pods = {}
    try:
        lines = (job.path / "pods.jsonl").read_text().splitlines()
    except OSError:
        job.fault("no pods.jsonl: the Pods were never sampled")
        return pods
    for n, line in enumerate(lines, 1):
        try:
            sample = json.loads(line)
        except ValueError:
            job.fault(f"pods.jsonl line {n} does not parse")
            continue
        pods[sample["uid"]] = sample
    return pods


def check_platform(job: Job, pods: dict, node: str | None) -> None:
    """Validity line 1: one Workload owned by the Job, four GPUs reserved, every Pod on the qualified node."""
    want_pods, _ = SHAPES[job.arm]
    if len(pods) != want_pods:
        job.fault(f"{len(pods)} Pod(s) were ever created, want {want_pods}")
    nodes = {p.get("node") for p in pods.values()}
    if None in nodes or len(nodes) != 1:
        job.fault(f"the Pods ran on {sorted(map(str, nodes))}, want all on one node")
    elif node is not None and nodes != {node}:
        job.fault(f"the Pods ran on {sorted(nodes)}, not on the qualified node {node}")
    if want_pods > 1 and sorted(str(p.get("index")) for p in pods.values()) != [str(i) for i in range(want_pods)]:
        job.fault(f"completion indexes {sorted(str(p.get('index')) for p in pods.values())}, want 0 to {want_pods - 1}")
    final_job = read_json(job.path / "final-job.json")
    wls = read_json(job.path / "final-workloads.json")
    uid = ((final_job or {}).get("metadata") or {}).get("uid")
    if not uid or wls is None:
        job.fault("the Job or the Workloads were not saved, so admission cannot be read")
        return
    owned = [w for w in wls.get("items", []) if any(r.get("uid") == uid for r in w["metadata"].get("ownerReferences", []))]
    if len(owned) != 1:
        job.fault(f"{len(owned)} Workload(s) owned by the Job, want 1")
        return
    assigns = ((owned[0].get("status") or {}).get("admission") or {}).get("podSetAssignments") or []
    reserved = 0
    for a in assigns:
        raw = (a.get("resourceUsage") or {}).get("nvidia.com/gpu")
        if raw is None or not str(raw).isdigit():
            job.fault(f"a pod set's reserved nvidia.com/gpu is {raw!r}")
            return
        reserved += int(raw)
    if reserved != RANKS:
        job.fault(f"the Workload reserved nvidia.com/gpu {reserved}, want {RANKS}")


def read_logs(job: Job, pods: dict) -> dict[str, list[str]]:
    """Each Pod's log lines by Pod UID; a sampled Pod without a log fails the job."""
    logs = {}
    for uid in pods:
        try:
            logs[uid] = (job.path / f"log-{uid}.txt").read_text().splitlines()
        except OSError:
            job.fault(f"Pod {pods[uid].get('name')} has no log")
    return logs


def check_pod_preamble(job: Job, uid: str, lines: list[str], allowed_env: dict) -> None:
    """The run id, the NCCL configuration files, the NCCL_ environment and /dev/shm that every Pod prints first."""
    if not any(line.startswith(f"AR_RUN_ID {job.name} ") for line in lines):
        job.fault(f"Pod {uid}'s log does not carry this job's run id {job.name}")
    for path in ("/etc/nccl.conf",):
        if f"AR_NCCL_CONF absent {path}" not in lines:
            job.fault(f"Pod {uid}: {path} is not reported absent, and NCCL would read it")
    home = [line for line in lines if line.startswith("AR_NCCL_CONF ") and line.endswith("/.nccl.conf")]
    if len(home) != 1 or not home[0].startswith("AR_NCCL_CONF absent "):
        job.fault(f"Pod {uid}: ~/.nccl.conf is not reported absent: {home}")
    env = {}
    for line in lines:
        if line.startswith("AR_NCCL_ENV "):
            key, _, value = line[len("AR_NCCL_ENV "):].partition("=")
            env[key] = value
    if env != allowed_env:
        job.fault(f"Pod {uid} started with NCCL_ variables {env}, want exactly {allowed_env}")
    shm = [line.split()[1] for line in lines if line.startswith("AR_SHM_KB ")]
    want_pods, gpus = SHAPES[job.arm]
    if len(shm) != 1 or not shm[0].isdigit():
        job.fault(f"Pod {uid} did not report /dev/shm's size")
    elif gpus > 1 and int(shm[0]) < SHM_MIN_KB:
        job.fault(f"Pod {uid}'s /dev/shm is {shm[0]} KiB, under the 1 GiB a Pod of several GPUs is rendered with")


def nccl_lines(lines: list[str]) -> list[re.Match]:
    return [m for m in (NCCL_LINE.match(line) for line in lines) if m]


def attribute_transports(job: Job, uid: str, lines: list[str], pid_to_rank: dict[int, int]) -> None:
    """Validity line 4: every rank's own process logged a channel's transport, attributed by Pod and process id.

    The identity is the Pod's log and the pid together: in four Pods of one, every rank can be pid 1 (run 3 showed
    it), so a pid alone across pooled logs could credit one rank with another's line (review, finding 10).
    """
    for m in nccl_lines(lines):
        rank = pid_to_rank.get(int(m["pid"]))
        if rank is None:
            continue
        channel = CHANNEL.search(m["msg"])
        if channel:
            job.transports.setdefault(rank, [])
            kind = transport_of(channel["via"])
            if kind not in job.transports[rank]:
                job.transports[rank].append(kind)
        env = SET_BY_ENV.match(m["msg"])
        if env:
            job.stack_env[env["name"]] = env["value"]


def records_of(job: Job, uid: str, lines: list[str]) -> list[dict]:
    """The JSON records in one Pod's log; a line that looks like a record and does not parse fails the job."""
    out = []
    for n, line in enumerate(lines, 1):
        if not line.startswith("{"):
            continue
        try:
            record = json.loads(line)
        except ValueError:
            job.fault(f"Pod {uid} log line {n} looks like a record and does not parse (an interleaved write?)")
            continue
        if record.get("run_id") != job.name:
            job.fault(f"Pod {uid} carries a record of run {record.get('run_id')!r}, not {job.name}")
            continue
        out.append(record)
    return out


def check_torch_job(job: Job, pods: dict, logs: dict, approved: str) -> None:
    """Validity lines 2 to 8 for the two torch instruments."""
    want_pods, _ = SHAPES[job.arm]
    starts: dict[int, dict] = {}
    by_rank: dict[int, list[dict]] = {}
    for uid, lines in logs.items():
        check_pod_preamble(job, uid, lines, ALLOWED_NCCL_ENV)
        records = records_of(job, uid, lines)
        pid_to_rank = {}
        mine = [r for r in records if r.get("event") == "start"]
        if want_pods > 1:
            index = pods[uid].get("index")
            if len(mine) != 1 or str(mine[0].get("rank")) != str(index):
                job.fault(f"Pod {uid} (index {index}) holds start records of ranks {[r.get('rank') for r in mine]}, "
                          "want exactly its own")
        for record in mine:
            rank = record.get("rank")
            if rank in starts:
                job.fault(f"rank {rank} started twice")
            starts[rank] = record
            pid_to_rank[int(record.get("pid", -1))] = rank
        for record in records:
            by_rank.setdefault(record.get("rank"), []).append(record)
        attribute_transports(job, uid, lines, pid_to_rank)
    if sorted(starts) != list(range(RANKS)):
        job.fault(f"start records from ranks {sorted(map(str, starts))}, want 0 to {RANKS - 1}")
    for rank, start in starts.items():
        if start.get("device") != "cuda":
            job.fault(f"rank {rank} ran on {start.get('device')!r}, not cuda: a rehearsal is not a measurement")
        if start.get("world_size") != RANKS:
            job.fault(f"rank {rank} reports world size {start.get('world_size')}")
        if start.get("script_sha256") != approved:
            job.fault(f"rank {rank} ran script {start.get('script_sha256')}, not the approved {approved}")
        if start.get("nccl_version") != NCCL_VERSION:
            job.fault(f"rank {rank} loaded NCCL {start.get('nccl_version')}, not {NCCL_VERSION}")
        if start.get("nccl_env") != ALLOWED_NCCL_ENV:
            job.fault(f"rank {rank} ran with NCCL_ variables {start.get('nccl_env')}")
        if start.get("omp_num_threads") != "1":
            job.fault(f"rank {rank} ran with OMP_NUM_THREADS {start.get('omp_num_threads')!r}, not 1")
        if start.get("gpu_uuid"):
            job.uuids[rank] = norm_uuid(start["gpu_uuid"])
    if len(job.uuids) != RANKS or len(set(job.uuids.values())) != RANKS:
        job.fault(f"the ranks name {len(set(job.uuids.values()))} distinct GPU UUID(s), want {RANKS}")
    for rank in range(RANKS):
        if not job.transports.get(rank):
            job.fault(f"rank {rank}'s process logged no channel transport")
        done = [r for r in by_rank.get(rank, []) if r.get("event") == "done"]
        if len(done) != 1 or done[0].get("exit_code") != 0:
            job.fault(f"rank {rank} has no done record with exit code 0")
        refused = [r for r in by_rank.get(rank, []) if r.get("event") == "refused"]
        if refused:
            job.fault(f"rank {rank} refused: {refused[0].get('error')}")
    if job.arm.startswith("allreduce-"):
        check_allreduce_records(job, starts, by_rank)
    else:
        check_step_records(job, starts, by_rank)


def check_allreduce_records(job: Job, starts: dict, by_rank: dict) -> None:
    for rank, start in starts.items():
        if start.get("warmup") != WARMUP or start.get("iterations") != ITERS or tuple(start.get("sizes") or ()) != SIZES:
            job.fault(f"rank {rank} ran warm-up {start.get('warmup')}, iterations {start.get('iterations')} and sizes "
                      f"{start.get('sizes')}, not the registered {WARMUP}, {ITERS} and {list(SIZES)}")
    figures = {}
    for rank in range(RANKS):
        sizes = {r.get("size_bytes"): r for r in by_rank.get(rank, []) if r.get("event") == "size"}
        if tuple(sorted(sizes)) != SIZES:
            job.fault(f"rank {rank} recorded sizes {sorted(sizes)}, want {list(SIZES)}")
            continue
        for size, record in sizes.items():
            if record.get("verified") is not True or record.get("iterations") != ITERS:
                job.fault(f"rank {rank} size {size}: verified {record.get('verified')}, {record.get('iterations')} iterations")
            if rank == 0:
                figures[size] = record.get("busbw_gigabytes_per_s_median")
    for size, busbw in figures.items():
        if not isinstance(busbw, (int, float)) or not math.isfinite(busbw) or busbw <= 0:
            job.fault(f"size {size} has no bus bandwidth")
        elif busbw > CEILING_GBPS:
            job.fault(f"size {size} reads {busbw:.2f} GB/s, above the {CEILING_GBPS:g} GB/s the card can move")
    job.figures = {"busbw": figures}


def check_step_records(job: Job, starts: dict, by_rank: dict) -> None:
    for rank, start in starts.items():
        model = {k: start.get(k) for k in STEP_MODEL}
        if model != STEP_MODEL or start.get("warmup_pairs") != STEP_WARMUP or start.get("timed_pairs") != STEP_PAIRS:
            job.fault(f"rank {rank} ran model {model}, {start.get('warmup_pairs')} warm-up and {start.get('timed_pairs')} "
                      f"timed pairs, not the registered {STEP_MODEL}, {STEP_WARMUP} and {STEP_PAIRS}")
    record0 = None
    for rank in range(RANKS):
        steps = [r for r in by_rank.get(rank, []) if r.get("event") == "steps"]
        if len(steps) != 1:
            job.fault(f"rank {rank} has {len(steps)} steps record(s), want 1")
            continue
        s = steps[0]
        if s.get("verified") is not True or s.get("synced_steps") != STEP_PAIRS or s.get("local_steps") != STEP_PAIRS:
            job.fault(f"rank {rank}: verified {s.get('verified')} ({s.get('refused', '')}), {s.get('synced_steps')} synced "
                      f"and {s.get('local_steps')} local steps")
        if s.get("device") != "cuda":
            job.fault(f"rank {rank}'s steps ran on {s.get('device')!r}")
        if rank == 0:
            record0 = s
    if record0 and record0.get("verified") is True:
        job.figures = {k: record0.get(k) for k in ("synced_ms_median", "local_ms_median", "sync_cost_ms")}
        job.figures["ddp_buckets"] = record0.get("ddp_buckets")


def check_nccltests_job(job: Job, pods: dict, logs: dict) -> None:
    """Validity lines 2 to 8 for nccl-tests, one Pod of four processes under mpirun."""
    command = ((read_json(job.path / "mltrainingjob.json") or {}).get("spec") or {}).get("command") or []
    text = " ".join(command)
    for flag in NCCLTESTS_FLAGS:
        if f" {flag} " not in f" {text} ":
            job.fault(f"the command does not carry {flag}")
    if len(logs) != 1:
        return
    uid, lines = next(iter(logs.items()))
    check_pod_preamble(job, uid, lines, {**ALLOWED_NCCL_ENV, **NCCLTESTS_EXTRA_ENV})
    gpus = {}
    for line in lines:
        m = GPU_LINE.match(line)
        if m:
            gpus[int(m["bus"].split(":")[-1], 16)] = norm_uuid(m["uuid"])
    header = next((m for m in (NT_HEADER.match(line) for line in lines) if m), None)
    if not header:
        job.fault("nccl-tests printed no settings header")
    elif (int(header["warmup"]), int(header["iters"]), int(header["min"]), int(header["max"]), int(header["check"]),
          int(header["gpus"]), int(header["threads"])) != (WARMUP, ITERS, SIZES[0], SIZES[-1], 1, 1, 1):
        job.fault(f"nccl-tests ran {header.group(0)!r}, not the registered settings")
    ranks = [m for m in (NT_RANK.match(line) for line in lines) if m]
    if sorted(int(m["rank"]) for m in ranks) != list(range(RANKS)):
        job.fault(f"nccl-tests printed rank lines {sorted(int(m['rank']) for m in ranks)}, want 0 to {RANKS - 1}")
    pid_to_rank = {int(m["pid"]): int(m["rank"]) for m in ranks}
    if len(pid_to_rank) != len(ranks):
        job.fault("two nccl-tests ranks share a process id, so they are not one process per GPU")
    for m in ranks:
        uuid = gpus.get(int(m["bus"], 16))
        if uuid:
            job.uuids[int(m["rank"])] = uuid
    if len(job.uuids) != RANKS or len(set(job.uuids.values())) != RANKS:
        job.fault(f"the ranks' bus IDs map to {len(set(job.uuids.values()))} distinct GPU UUID(s), want {RANKS}")
    versions = {m["v"] for m in (NCCL_VERSION_LINE.search(x) for x in lines) if m}
    if versions != {NCCL_VERSION}:
        job.fault(f"NCCL reported version(s) {sorted(versions)}, want {NCCL_VERSION}")
    attribute_transports(job, uid, lines, pid_to_rank)
    for rank in range(RANKS):
        if not job.transports.get(rank):
            job.fault(f"rank {rank}'s process logged no channel transport")
    rows = {int(m["size"]): m for m in (NT_ROW.match(line) for line in lines) if m}
    if tuple(sorted(rows)) != SIZES:
        job.fault(f"nccl-tests printed sizes {sorted(rows)}, want {list(SIZES)}")
    figures = {}
    for size, m in rows.items():
        if m["wrong1"] != "0" or m["wrong2"] != "0":
            job.fault(f"size {size}: wrong elements {m['wrong1']} out of place and {m['wrong2']} in place")
        busbw = float(m["bus1"])
        if busbw <= 0:
            job.fault(f"size {size} has no bus bandwidth")
        elif busbw > CEILING_GBPS:
            job.fault(f"size {size} reads {busbw:.2f} GB/s, above the {CEILING_GBPS:g} GB/s the card can move")
        figures[size] = busbw
    if "# Out of bounds values : 0 OK" not in lines:
        job.fault("nccl-tests did not report zero out-of-bounds values")
    job.figures = {"busbw": figures}


def judge_job(path: Path, bench_sha: str, step_sha: str, node: str | None) -> Job:
    job = Job(path)
    if (path / "VOID").exists():
        job.fault("void: " + read_text(path / "VOID"))
        return job
    if job.arm not in SHAPES:
        job.fault(f"arm {job.arm!r} is not registered")
        return job
    if (path / "TIMEOUT").exists():
        job.fault(read_text(path / "TIMEOUT"))
    # Judged here as well as by the runner: a terminal answer that arrived after the budget is not within it.
    elapsed = read_text(path / "elapsed-seconds")
    if not elapsed.isdigit():
        job.fault("no elapsed-seconds, so the job cannot be shown to have ended within its budget")
    elif int(elapsed) > JOB_BUDGET_SECONDS:
        job.fault(f"the job took {elapsed} s, over the registered {JOB_BUDGET_SECONDS} s")
    final = read_json(path / "final-mltj.json") or {}
    if (final.get("status") or {}).get("phase") != "Succeeded":
        job.fault(f"the MLTrainingJob ended {(final.get('status') or {}).get('phase')!r}, not Succeeded")
    pods = last_samples(job)
    check_platform(job, pods, node)
    logs = read_logs(job, pods)
    if job.arm.startswith("nccltests-"):
        check_nccltests_job(job, pods, logs)
    else:
        check_torch_job(job, pods, logs, bench_sha if job.arm.startswith("allreduce-") else step_sha)
    return job


def judge_qualification(path: Path) -> list[str]:
    """Q: four distinct UUIDs, a driver version, a 4 x 4 topology among the GPUs, and /dev/shm of 1 GiB."""
    faults = []
    try:
        lines = (path / "qualification.log").read_text().splitlines()
    except OSError:
        return ["no qualification.log"]
    # nvidia-smi underlines the topo -m header with ANSI escapes even when no terminal is attached.
    # Read as written, that header matched nothing, and the paid session of 2026-10-27 was voided over a matrix it had.
    lines = [ANSI_ESCAPE.sub("", x) for x in lines]
    uuids = {norm_uuid(m.group(1)) for m in (re.search(r"\(UUID: (GPU-[0-9a-f-]+)\)", x) for x in lines) if m}
    if len(uuids) != RANKS:
        faults.append(f"nvidia-smi -L listed {len(uuids)} distinct UUID(s), want {RANKS}")
    drivers = {m["driver"] for m in (GPU_LINE.match(x) for x in lines) if m}
    if len(drivers) != 1:
        faults.append(f"driver versions {sorted(drivers)}, want exactly one")
    header = next((x for x in lines if re.match(r"^\s*GPU0\s+GPU1\s+GPU2\s+GPU3\b", x)), None)
    rows = [x for x in lines if re.match(r"^GPU[0-3]\s", x)]
    if header is None or len({x.split()[0] for x in rows}) != RANKS:
        faults.append("nvidia-smi topo -m printed no 4 x 4 GPU matrix")
    shm = [x.split()[1] for x in lines if x.startswith("AR_SHM_KB ")]
    if len(shm) != 1 or not shm[0].isdigit() or int(shm[0]) < SHM_MIN_KB:
        faults.append(f"/dev/shm reported {shm}, want at least {SHM_MIN_KB} KiB")
    return faults


def separation(a: list[float], b: list[float]) -> str:
    """Complete separation of two arms' job figures, either way, or neither."""
    if min(a) > max(b):
        return "first above"
    if max(a) < min(b):
        return "first below"
    return "not distinguished"


def score(evidence: Path, bench_sha: str, step_sha: str) -> int:
    provenance = dict(line.split("=", 1) for line in read_text(evidence / "provenance.txt").splitlines() if "=" in line)
    node = provenance.get("node") or None
    ok = True
    q = judge_qualification(evidence / "qualification")
    print("Q", "VALID" if not q else "INVALID " + "; ".join(q))
    ok = ok and not q
    if node is None:
        print("INVALID provenance names no qualified node")
        ok = False
    stopped = read_text(evidence / "STOPPED")
    if stopped:
        print("STOPPED", stopped)
        ok = False
    jobs = []
    for path in sorted((evidence / "jobs").glob("*")):
        if not path.is_dir():
            continue
        job = judge_job(path, bench_sha, step_sha, node)
        counted = not path.name.startswith("00-smoke-")
        jobs.append((job, counted))
        print(("VALID  " if job.valid else "INVALID"), path.name, ("" if counted else "(smoke, not counted)"),
              "; ".join(job.faults))
        if job.valid and job.transports:
            print("        transports", {r: job.transports[r] for r in sorted(job.transports)},
                  "set by the stack:", job.stack_env or "nothing")
    counted = {arm: [j for j, c in jobs if c and j.arm == arm] for arm in ARMS}
    for arm, arm_jobs in counted.items():
        if len(arm_jobs) != REPS:
            print(f"INVALID {arm}: {len(arm_jobs)} registered job(s), want {REPS}")
            ok = False
        if not all(j.valid for j in arm_jobs):
            ok = False
    complete = {arm: len(js) == REPS and all(j.valid for j in js) for arm, js in counted.items()}

    print("\nE1 bus bandwidth, GB/s (median of five jobs; each job's figure in brackets)")
    for arm in ("nccltests-1pod4gpu", "allreduce-1pod4gpu", "allreduce-4pod1gpu"):
        if not complete[arm]:
            print(f"  {arm}: no figure, not every registered job is valid")
            continue
        for size in SIZES:
            values = [j.figures["busbw"][size] for j in counted[arm]]
            print(f"  {arm} {size >> 20:>4} MiB: {statistics.median(values):.2f} [{', '.join(f'{v:.2f}' for v in values)}]")
    print("\nE4 DDP step, ms (median of five jobs)")
    for arm in ("ddp-1pod4gpu", "ddp-4pod1gpu"):
        if not complete[arm]:
            print(f"  {arm}: no figure, not every registered job is valid")
            continue
        for key in ("synced_ms_median", "local_ms_median", "sync_cost_ms"):
            values = [j.figures[key] for j in counted[arm]]
            print(f"  {arm} {key}: {statistics.median(values):.2f} [{', '.join(f'{v:.2f}' for v in values)}]")

    print("\nVerdicts (complete separation of five against five; either direction)")
    pairs = [("V1", "allreduce-1pod4gpu", "allreduce-4pod1gpu", "busbw", size) for size in SIZES]
    pairs += [("V2", "ddp-1pod4gpu", "ddp-4pod1gpu", "synced_ms_median", None),
              ("V3", "ddp-1pod4gpu", "ddp-4pod1gpu", "sync_cost_ms", None)]
    for rule, a, b, key, size in pairs:
        label = f"{rule} {a} vs {b}" + (f" at {size >> 20} MiB" if size else "")
        if not (complete[a] and complete[b]):
            print(f"  {label}: not scored, an arm has an invalid or missing job")
            continue
        av = [j.figures[key][size] if size else j.figures[key] for j in counted[a]]
        bv = [j.figures[key][size] if size else j.figures[key] for j in counted[b]]
        print(f"  {label}: {separation(av, bv)}")
        ta = sorted({t for j in counted[a] for ts in j.transports.values() for t in ts})
        tb = sorted({t for j in counted[b] for ts in j.transports.values() for t in ts})
        print(f"      transports {a}: {ta}; {b}: {tb}" + ("" if ta != tb else " (the same, so no transport is named)"))
    if complete["nccltests-1pod4gpu"] and complete["allreduce-1pod4gpu"]:
        print("\nE6 nccl-tests / torch bench, one Pod of four (reported, not judged)")
        for size in SIZES:
            n = statistics.median(j.figures["busbw"][size] for j in counted["nccltests-1pod4gpu"])
            t = statistics.median(j.figures["busbw"][size] for j in counted["allreduce-1pod4gpu"])
            print(f"  {size >> 20:>4} MiB: {n / t:.3f}")
    print("\nPASS" if ok else "\nFAIL")
    return 0 if ok else 1


def false_separation_bound(k: int, tests: int) -> float:
    """The chance of at least one complete separation, either way, among `tests` tests of k against k, under a random
    order and no arm effect, by Bonferroni: tests * 2 / C(2k, k)."""
    return tests * 2 / math.comb(2 * k, k)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("evidence", nargs="?")
    parser.add_argument("--job")
    parser.add_argument("--node")
    parser.add_argument("--bench-sha256", required=True)
    parser.add_argument("--step-sha256", required=True)
    args = parser.parse_args(argv)
    for value in (args.bench_sha256, args.step_sha256):
        if not re.fullmatch(r"[0-9a-f]{64}", value):
            parser.error(f"{value!r} is not a sha256")
    if args.job:
        job = judge_job(Path(args.job), args.bench_sha256, args.step_sha256, args.node)
        print(("VALID" if job.valid else "INVALID"), args.job, "; ".join(job.faults))
        return 0 if job.valid else 1
    if not args.evidence:
        parser.error("give an evidence directory or --job")
    return score(Path(args.evidence), args.bench_sha256, args.step_sha256)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
