# Copied unchanged below these comment lines from experiments/distributed-restart/train.py at commit
# f7638229ff3c9f96a16ac483f60aad5724ca73ac (branch feat/distributed-restart), so Slurm runs the same trainer Kubernetes does.
# That trainer was being changed while this copy was taken; this file is that commit's version, not whatever the branch holds now.
# steps/05-train-requeue.sh refuses to run unless the lines after these four hash to that commit's file, sha256 abbfa465….
"""Multi-rank gloo DDP whose checkpoint survives a whole-job restart on a shared volume.

experiments/checkpoint-resume/train.py proved one Pod can resume the same training from a node-local volume.
A restartable distributed MLTrainingJob starts every rank again, on other nodes, reading what all ranks wrote to a
ReadWriteMany claim; that adds three ways to load the wrong state, and this trainer exists to refuse each of them:

- a checkpoint some ranks finished and others did not, because the job died between the shards and the manifest;
- shards of different steps, because one rank ran ahead;
- two ranks loading two different checkpoints, because each looked at the directory and saw a different newest one.

The protocol is docs/superpowers/specs/2026-11-01-distributed-restart-design.md, "Checkpoint protocol":
paths are never reused, rank 0 publishes a manifest only after verifying every shard, LATEST names a manifest, and on
resume rank 0 chooses and every rank agrees or all fall back together.

The platform supplies TRAINING_ATTEMPT; everything else arrives as environment variables from the runner, because
MLTrainingJob has no env field.
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import re
import signal
import sys
import time
import uuid

import torch
import torch.distributed as dist
import torch.nn as nn
from torch.nn.parallel import DistributedDataParallel as DDP

RUN_ID = os.environ.get("CKPT_RUN_ID", "unset")
STEPS = int(os.environ.get("CKPT_STEPS", "40"))
# The job's own directory on the shared volume; the runner gives every job a name of its own, so a recreated job of the
# same name never reads its predecessor's checkpoints.
ROOT = os.path.join(os.environ.get("CKPT_DIR", "/state"), os.environ.get("CKPT_JOB_ID", "job"))
ATTEMPT = int(os.environ.get("TRAINING_ATTEMPT", "0"))
# none | full | no-optimizer | no-data-rng, as in experiments/checkpoint-resume; the last two are negative controls.
LOAD_MODE = os.environ.get("CKPT_LOAD", "full")
# A fault to inject, "<point>:<step>[:<rank>]", once per volume; see FAULT_POINTS.
FAULT = os.environ.get("CKPT_FAULT", "")
# How many times a rank looks again for a shard the manifest names before calling it missing.
# NFS gives close-to-open consistency, so a file another client renamed may not be visible on the first look.
VISIBILITY_RETRIES = int(os.environ.get("CKPT_VISIBILITY_RETRIES", "5"))
VISIBILITY_WAIT = float(os.environ.get("CKPT_VISIBILITY_WAIT", "0.2"))
# Seconds each step waits after its checkpoint, so a fault injected from outside lands while training is still running.
STEP_SLEEP = float(os.environ.get("CKPT_STEP_SLEEP", "0"))
# How long a collective waits for a peer before failing; torch's default is 30 minutes, and a rank whose peer's node
# was lost would hold its Pod Running, and the attempt unfailed, for all of it.
COLLECTIVE_TIMEOUT = float(os.environ.get("CKPT_COLLECTIVE_TIMEOUT", "1800"))

LOAD_MODES = ("none", "full", "no-optimizer", "no-data-rng")
# kill-before-fsync: the rank dies with its shard written but not synced or renamed.
# kill-before-manifest: every shard is in place and rank 0 dies before writing the manifest.
# kill-before-latest: the manifest is in place and rank 0 dies before LATEST names it.
# kill-after-latest: LATEST names the new checkpoint and rank 0 dies right after.
# skew: the rank labels its shard one step ahead, as a rank that ran ahead would; the manifest must be refused.
FAULT_POINTS = ("kill-before-fsync", "kill-before-manifest", "kill-before-latest", "kill-after-latest", "skew")
BATCH = 8
TRUE_W = torch.tensor([[1.0], [-2.0], [0.5], [3.0]])
CKPT_DIR_RE = re.compile(r"^(\d{8})-([0-9a-f]{32})$")


def emit(rank: int, event: str, **fields: object) -> None:
    record = {
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "run_id": RUN_ID,
        "attempt": ATTEMPT,
        "rank": rank,
        "event": event,
    }
    record.update(fields)
    # One write per record: every rank shares torchrun's stdout, and a record split across writes can interleave.
    sys.stdout.write(json.dumps(record) + "\n")
    sys.stdout.flush()


def digest(model: nn.Module) -> str:
    hasher = hashlib.sha256()
    for name, tensor in sorted(model.state_dict().items()):
        hasher.update(name.encode())
        # A uint8 view rather than .numpy(): the CPU torch image ships without numpy.
        hasher.update(bytes(tensor.detach().contiguous().flatten().view(torch.uint8).tolist()))
    return hasher.hexdigest()


def params(model: nn.Module) -> list[float]:
    return [float(v) for _, t in sorted(model.state_dict().items()) for v in t.detach().flatten()]


def broadcast_json(obj: object, rank: int) -> object:
    """Rank 0's obj on every rank.

    Spelled with tensors because torch's object collectives decode through numpy, which the CPU torch image lacks.
    """
    data = json.dumps(obj).encode() if rank == 0 else b""
    size = torch.tensor([len(data)])
    dist.broadcast(size, src=0)
    buf = torch.tensor(list(data), dtype=torch.uint8) if rank == 0 else torch.empty(int(size.item()), dtype=torch.uint8)
    dist.broadcast(buf, src=0)
    return json.loads(bytes(buf.tolist()))


def gather_json(obj: object, world: int) -> list:
    """Every rank's obj, in rank order, on every rank."""
    data = json.dumps(obj).encode()
    sizes = [torch.zeros(1, dtype=torch.long) for _ in range(world)]
    dist.all_gather(sizes, torch.tensor([len(data)]))
    width = max(int(s.item()) for s in sizes)
    padded = torch.zeros(width, dtype=torch.uint8)
    padded[:len(data)] = torch.tensor(list(data), dtype=torch.uint8)
    bufs = [torch.zeros(width, dtype=torch.uint8) for _ in range(world)]
    dist.all_gather(bufs, padded)
    return [json.loads(bytes(b[:int(s.item())].tolist())) for b, s in zip(bufs, sizes)]


def fsync_dir(path: str) -> None:
    # A rename is durable only once the directory holding the new name is synced.
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def sha256_file(path: str) -> tuple[str, int]:
    hasher = hashlib.sha256()
    size = 0
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            hasher.update(block)
            size += len(block)
    return hasher.hexdigest(), size


def write_new(path: str, data: bytes) -> None:
    """Writes data under a temporary name unique to this write, syncs it and renames it to path."""
    tmp = f"{path}.tmp-{uuid.uuid4().hex}"
    with open(tmp, "wb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, path)
    fsync_dir(os.path.dirname(path))


class Fault:
    """The one fault this run injects, armed until a marker on the volume says it has fired."""

    def __init__(self, spec: str) -> None:
        self.point, self.step, self.rank = "", 0, 0
        if not spec:
            return
        parts = spec.split(":")
        if parts[0] not in FAULT_POINTS or len(parts) not in (2, 3):
            raise SystemExit(f"CKPT_FAULT={spec!r} is not <point>:<step>[:<rank>] with point in {FAULT_POINTS}")
        self.point, self.step = parts[0], int(parts[1])
        self.rank = int(parts[2]) if len(parts) == 3 else 0
        self.marker = os.path.join(ROOT, f"fault-fired-{self.point}-{self.step}-{self.rank}")

    def due(self, point: str, step: int, rank: int) -> bool:
        return (self.point == point and self.step == step and self.rank == rank
                and not os.path.exists(self.marker))

    def fire(self, rank: int, step: int) -> None:
        # The marker is written first and survives the kill, so the next attempt does not die again.
        write_new(self.marker, b"1")
        emit(rank, "fault", point=self.point, step=step)
        if self.point != "skew":
            # The kernel drops a signal PID 1 sends itself, so as a container's first process this kill would do nothing
            # and the rank would train on, which is what the first kind rehearsal did when python was exec'd.
            if os.getpid() == 1:
                raise SystemExit("a kill fault cannot fire in PID 1; start train.py under a shell or torchrun")
            # A hard kill, not an exception: a node loss does not unwind either.
            os.kill(os.getpid(), signal.SIGKILL)


def save(rank: int, world: int, step: int, state: dict, fault: Fault) -> None:
    """Writes one checkpoint of every rank's state and publishes it, or refuses it with every rank knowing."""
    # The ranks agree on the step and on a name nothing has used; rank 0's choice is the one that counts.
    ident = broadcast_json([step, uuid.uuid4().hex], rank)
    if ident[0] != step:
        raise RuntimeError(f"rank {rank} is at step {step}, rank 0 at step {ident[0]}")
    ckpt = os.path.join(ROOT, f"a{ATTEMPT}", f"{step:08d}-{ident[1]}")
    os.makedirs(ckpt, exist_ok=True)

    labelled = dict(state)
    if fault.due("skew", step, rank):
        fault.fire(rank, step)
        labelled["step"] = step + 1
    shard = os.path.join(ckpt, f"rank-{rank}.pt")
    tmp = f"{shard}.tmp-{uuid.uuid4().hex}"
    with open(tmp, "wb") as handle:
        torch.save(labelled, handle)
        handle.flush()
        if fault.due("kill-before-fsync", step, rank):
            fault.fire(rank, step)
        os.fsync(handle.fileno())
    os.replace(tmp, shard)
    fsync_dir(ckpt)
    sha, size = sha256_file(shard)

    reports = gather_json({"rank": rank, "step": labelled["step"], "file": os.path.basename(shard),
                           "sha256": sha, "size": size}, world)
    problems = [f"rank {r} reported {rep}" for r, rep in enumerate(reports)
                if rep["rank"] != r or rep["step"] != step]
    if problems:
        # Every rank has the same reports, so every rank reaches the same verdict and nobody waits on a manifest.
        emit(rank, "checkpoint_refused", step=step, dir=ckpt, problems=problems)
        return

    if rank == 0:
        if fault.due("kill-before-manifest", step, rank):
            fault.fire(rank, step)
        manifest = {"step": step, "world_size": world, "attempt": ATTEMPT, "uuid": ident[1], "shards": reports}
        write_new(os.path.join(ckpt, "MANIFEST"), json.dumps(manifest, sort_keys=True).encode())
        if fault.due("kill-before-latest", step, rank):
            fault.fire(rank, step)
        write_new(os.path.join(ROOT, "LATEST"), os.path.relpath(ckpt, ROOT).encode())
        if fault.due("kill-after-latest", step, rank):
            fault.fire(rank, step)
    # Held until LATEST names this checkpoint, so no rank runs ahead of what a restart would resume from.
    dist.barrier()
    emit(rank, "checkpoint", step=step, dir=os.path.relpath(ckpt, ROOT))


def candidates() -> list[str]:
    """Checkpoints rank 0 may offer, newest first: LATEST's, then every other one that has a manifest."""
    found = []
    for attempt_dir in sorted(os.listdir(ROOT)) if os.path.isdir(ROOT) else []:
        base = os.path.join(ROOT, attempt_dir)
        if not attempt_dir.startswith("a") or not os.path.isdir(base):
            continue
        for name in os.listdir(base):
            match = CKPT_DIR_RE.match(name)
            if match and os.path.exists(os.path.join(base, name, "MANIFEST")):
                found.append((int(match.group(1)), os.path.join(attempt_dir, name)))
    # Newest step first; between two of the same step, which can exist after a rollback, the later attempt's.
    found.sort(key=lambda f: (f[0], int(f[1].split("/")[0][1:])), reverse=True)
    ordered = [rel for _, rel in found]
    latest = os.path.join(ROOT, "LATEST")
    if os.path.exists(latest):
        with open(latest) as handle:
            named = handle.read().strip()
        if named in ordered:
            ordered.remove(named)
        ordered.insert(0, named)
    return ordered


def manifest_ok(rel: str, world: int) -> dict | None:
    try:
        with open(os.path.join(ROOT, rel, "MANIFEST")) as handle:
            manifest = json.load(handle)
    except (OSError, ValueError):
        return None
    shards = manifest.get("shards", [])
    if (manifest.get("world_size") != world or len(shards) != world
            or sorted(s["rank"] for s in shards) != list(range(world))
            or any(s["step"] != manifest.get("step") for s in shards)):
        return None
    return manifest


def shard_ok(rel: str, manifest: dict, rank: int) -> bool:
    entry = next(s for s in manifest["shards"] if s["rank"] == rank)
    path = os.path.join(ROOT, rel, entry["file"])
    for attempt in range(VISIBILITY_RETRIES + 1):
        if os.path.exists(path):
            return sha256_file(path) == (entry["sha256"], entry["size"])
        if attempt < VISIBILITY_RETRIES:
            time.sleep(VISIBILITY_WAIT)
    return False


def choose(rank: int, world: int) -> tuple[str, dict] | None:
    """Rank 0 offers checkpoints newest first; every rank checks its own shard; all load the first all accept."""
    offers = candidates() if rank == 0 else []
    count = broadcast_json(len(offers), rank)
    for i in range(count):
        rel, manifest = broadcast_json([offers[i], manifest_ok(offers[i], world)] if rank == 0 else None, rank)
        ok = manifest is not None and shard_ok(rel, manifest, rank)
        verdict = torch.tensor([1 if ok else 0])
        dist.all_reduce(verdict, op=dist.ReduceOp.MIN)
        if verdict.item() == 1:
            return rel, manifest
        emit(rank, "checkpoint_rejected", dir=rel, own_shard_ok=ok)
    return None


def main() -> int:
    if LOAD_MODE not in LOAD_MODES:
        print(f"CKPT_LOAD={LOAD_MODE!r} is not one of {LOAD_MODES}", file=sys.stderr)
        return 2
    rank = int(os.environ["RANK"])
    world = int(os.environ["WORLD_SIZE"])
    torch.set_num_threads(1)
    torch.manual_seed(0)
    dist.init_process_group(backend="gloo", timeout=datetime.timedelta(seconds=COLLECTIVE_TIMEOUT))
    os.makedirs(ROOT, exist_ok=True)
    fault = Fault(FAULT)

    model = nn.Linear(4, 1)
    data_rng = torch.Generator().manual_seed(1000 + rank)
    start_step = 0
    loaded = None
    chosen = choose(rank, world) if LOAD_MODE != "none" else None
    if chosen is not None:
        rel, manifest = chosen
        loaded = torch.load(os.path.join(ROOT, rel, f"rank-{rank}.pt"), weights_only=True)
        start_step = manifest["step"]
        model.load_state_dict(loaded["model"])
        if LOAD_MODE != "no-data-rng":
            data_rng.set_state(loaded["data_rng"])
        emit(rank, "resume", from_dir=rel, from_step=start_step)
    else:
        # Recorded, so a restart that found nothing is never read as a resume.
        emit(rank, "restart_from_zero", load_mode=LOAD_MODE)

    # Loaded before DDP wraps the model, because DDP broadcasts rank 0's parameters at construction.
    ddp = DDP(model)
    optimiser = torch.optim.SGD(ddp.parameters(), lr=0.05, momentum=0.9)
    if loaded is not None and LOAD_MODE != "no-optimizer":
        optimiser.load_state_dict(loaded["optimizer"])

    emit(rank, "start", world_size=world, load_mode=LOAD_MODE, resumed_from_step=start_step, steps=STEPS,
         fault=FAULT, torch_version=torch.__version__)

    for step in range(start_step + 1, STEPS + 1):
        x = torch.randn(BATCH, 4, generator=data_rng)
        y = x @ TRUE_W + 0.5 + 0.1 * torch.randn(BATCH, 1, generator=data_rng)
        optimiser.zero_grad()
        loss = ((ddp(x) - y) ** 2).mean()
        loss.backward()
        optimiser.step()
        # The first step record of an attempt is what the experiment reads as training resumed, not Pod readiness.
        emit(rank, "step", step=step, loss=float(loss), digest=digest(model),
             params=params(model) if step == STEPS else None)
        save(rank, world, step, {"step": step, "model": model.state_dict(), "optimizer": optimiser.state_dict(),
                                 "data_rng": data_rng.get_state()}, fault)
        if STEP_SLEEP:
            time.sleep(STEP_SLEEP)

    dist.destroy_process_group()
    return 0


if __name__ == "__main__":
    sys.exit(main())
