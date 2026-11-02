"""Multi-rank DDP, gloo on CPU or NCCL on CUDA, whose checkpoint survives a whole-job restart on a shared volume.

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
import socket
import sys
import threading
import time
import uuid

import torch
import torch.distributed as dist
import torch.nn as nn
from torch.nn.parallel import DistributedDataParallel as DDP
from torch.utils.data import DistributedSampler, TensorDataset

RUN_ID = os.environ.get("CKPT_RUN_ID", "unset")
STEPS = int(os.environ.get("CKPT_STEPS", "40"))
# The job's own directory on the shared volume; the runner gives every job a name of its own, so a recreated job of the
# same name never reads its predecessor's checkpoints.
ROOT = os.path.join(os.environ.get("CKPT_DIR", "/state"), os.environ.get("CKPT_JOB_ID", "job"))
ATTEMPT = int(os.environ.get("TRAINING_ATTEMPT", "0"))
# none | full, or one negative control per saved component: no-optimizer | no-scheduler | no-sampler | no-rng.
# Each control restores everything but its component, so a check that cannot tell it from full has shown that the
# component does not affect the result, or that the check is blind.
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
# How long the ranks wait for each other to join before training, or unset to bound the join by COLLECTIVE_TIMEOUT too.
# A restarted attempt can start one rank on a surviving node minutes before its peer's replacement node exists.
# Bounded by the collective timeout, that rank failed the attempt at 61 s with "1/2 clients joined", the kind rehearsal's
# terminate-wait-1 of 2026-11-01, so a case built to recover on a replacement could not.
# Only the join waits this long: a peer lost after it is still noticed at COLLECTIVE_TIMEOUT.
_RENDEZVOUS = os.environ.get("CKPT_RENDEZVOUS_TIMEOUT", "")
RENDEZVOUS_TIMEOUT = float(_RENDEZVOUS) if _RENDEZVOUS else None
# Seconds between heartbeat writes to the shared volume, 0 for none.
# The kind case cut-writer reads them from the host to show when each attempt's ranks last wrote, which a rank's stdout
# cannot show once its node is cut off from the API server that streams it.
HEARTBEAT = float(os.environ.get("CKPT_HEARTBEAT", "0"))
# When set, a rank whose training loop raises keeps its heartbeat writing until the process is killed, instead of exiting.
# It stands in for a process the platform cannot reach and that does not exit, such as one blocked in a collective under
# torch's 30-minute default while a background writer runs; it is the writer the fencing acknowledgement exists for.
LINGER = os.environ.get("CKPT_LINGER", "") == "1"
# gloo on CPU, which every local and kind check runs, or nccl on one CUDA device per rank, which the paid session runs.
# The default is gloo so that nothing that ran before this setting existed runs differently now.
BACKEND = os.environ.get("CKPT_BACKEND", "gloo")
BACKENDS = ("gloo", "nccl")
# MiB of fixed bytes added to every shard, so the checkpoint cost the paid session measures on EFS is that of a stated
# size rather than of a 4-8-1 MLP's few kilobytes; 0 adds nothing and leaves the shard as it was.
BALLAST_MB = int(os.environ.get("CKPT_BALLAST_MB", "0"))
# Seconds a rank waits after creating a checkpoint's directory before writing its shard, 0 for none.
# The kind visibility cases use it so a prober on another node can look a shard's name up before it exists, which is
# what leaves that node's NFS client caching the name as absent; nothing else sets it.
SHARD_DELAY = float(os.environ.get("CKPT_SHARD_DELAY", "0"))

LOAD_MODES = ("none", "full", "no-optimizer", "no-scheduler", "no-sampler", "no-rng")
# kill-before-fsync: the rank dies with its shard written but not synced or renamed.
# kill-before-manifest: every shard is in place and rank 0 dies before writing the manifest.
# kill-before-latest: the manifest is in place and rank 0 dies before LATEST names it.
# kill-after-latest: LATEST names the new checkpoint and rank 0 dies right after.
# skew: the rank labels its shard one step ahead, as a rank that ran ahead would; the manifest must be refused.
FAULT_POINTS = ("kill-before-fsync", "kill-before-manifest", "kill-before-latest", "kill-after-latest", "skew")
BATCH = 4
# 40 samples over two ranks is five batches an epoch, so the protocol check's resume at step 6 lands one batch into the
# second epoch, where restoring the epoch without the position, or the position without the epoch, feeds other batches.
DATASET_SIZE = 40
# A decay every 4 steps rather than 3: a fresh StepLR resumed at step 6 would decay at step 9 either way if the period
# divided 6, and dropping the scheduler state would then change nothing.
# A step schedule rather than a cosine over CKPT_STEPS, because the skew and torn-shard cases publish step 5 from a
# shorter attempt, and a schedule depending on the total would make that checkpoint differ from the reference's.
LR_STEP, LR_GAMMA = 4, 0.5
TRUE_W = torch.tensor([[1.0], [-2.0], [0.5], [3.0]])
CKPT_DIR_RE = re.compile(r"^(\d{8})-([0-9a-f]{32})$")
# Where the tensors of this rank's collectives live: NCCL moves only CUDA tensors, gloo these CPU ones.
# main sets it once, before the process group exists, and gloo keeps the CPU device every check has always used.
COMM_DEVICE = torch.device("cpu")


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
    size = torch.tensor([len(data)], device=COMM_DEVICE)
    dist.broadcast(size, src=0)
    buf = (torch.tensor(list(data), dtype=torch.uint8, device=COMM_DEVICE) if rank == 0
           else torch.empty(int(size.item()), dtype=torch.uint8, device=COMM_DEVICE))
    dist.broadcast(buf, src=0)
    return json.loads(bytes(buf.tolist()))


def gather_json(obj: object, world: int) -> list:
    """Every rank's obj, in rank order, on every rank."""
    data = json.dumps(obj).encode()
    sizes = [torch.zeros(1, dtype=torch.long, device=COMM_DEVICE) for _ in range(world)]
    dist.all_gather(sizes, torch.tensor([len(data)], device=COMM_DEVICE))
    width = max(int(s.item()) for s in sizes)
    padded = torch.zeros(width, dtype=torch.uint8, device=COMM_DEVICE)
    padded[:len(data)] = torch.tensor(list(data), dtype=torch.uint8, device=COMM_DEVICE)
    bufs = [torch.zeros(width, dtype=torch.uint8, device=COMM_DEVICE) for _ in range(world)]
    dist.all_gather(bufs, padded)
    return [json.loads(bytes(b[:int(s.item())].tolist())) for b, s in zip(bufs, sizes)]


def fsync_dir(path: str) -> None:
    # On a local file system a rename is durable only once the directory holding the new name is synced.
    # On NFS the Linux client's directory fsync does nothing, because it sends every directory operation to the server
    # synchronously, so this adds no boundary there.
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


class Heartbeat:
    """Appends one record of this rank's attempt to the shared volume every HEARTBEAT seconds until stopped or killed.

    The records live under the attempt's own directory, which no checkpoint path matches, so a heartbeat never reaches
    what a resume reads.
    """

    def __init__(self, rank: int) -> None:
        self.rank, self.phase, self.seq = rank, "training", 0
        self.path = os.path.join(ROOT, f"a{ATTEMPT}", f"heartbeat-rank-{rank}.jsonl")
        self.stopped = threading.Event()
        # A daemon thread, so a rank exiting for any reason but lingering is never held open by its heartbeat.
        self.thread = threading.Thread(target=self.run, name="heartbeat", daemon=True)

    def start(self) -> None:
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        self.thread.start()

    def run(self) -> None:
        while not self.stopped.is_set():
            self.seq += 1
            record = {"ts": datetime.datetime.now(datetime.timezone.utc).isoformat(), "attempt": ATTEMPT,
                      "rank": self.rank, "seq": self.seq, "phase": self.phase, "host": socket.gethostname(),
                      "pid": os.getpid()}
            # Opened, synced and closed each time, so every record reaches the volume as its own write and the file's
            # mtime on the host moves with it.
            with open(self.path, "a") as handle:
                handle.write(json.dumps(record) + "\n")
                handle.flush()
                os.fsync(handle.fileno())
            self.stopped.wait(HEARTBEAT)

    def stop(self) -> None:
        self.stopped.set()
        self.thread.join()


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
    # Monotonic, so the checkpoint cost the record carries is this rank's own interval and no clock step can move it.
    started = time.monotonic()
    # The ranks agree on the step and on a name nothing has used; rank 0's choice is the one that counts.
    # Rank 0 alone creates the directory, before it names it to the others.
    # When every rank created it, on NFS one rank's client could look the name up absent, lose the mkdir to another
    # node's, and then keep finding it absent from its cache: the first kind run over NFS died that way at step 1.
    name = uuid.uuid4().hex
    if rank == 0:
        os.mkdir(os.path.join(ROOT, f"a{ATTEMPT}", f"{step:08d}-{name}"))
    ident = broadcast_json([step, name], rank)
    if ident[0] != step:
        raise RuntimeError(f"rank {rank} is at step {step}, rank 0 at step {ident[0]}")
    ckpt = os.path.join(ROOT, f"a{ATTEMPT}", f"{step:08d}-{ident[1]}")
    if SHARD_DELAY:
        time.sleep(SHARD_DELAY)

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
    # Through the barrier, so the cost is what training waited for: the slowest rank's write and the publication.
    emit(rank, "checkpoint", step=step, dir=os.path.relpath(ckpt, ROOT), save_s=time.monotonic() - started)


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
    latest, named = os.path.join(ROOT, "LATEST"), None
    if os.path.exists(latest):
        with open(latest) as handle:
            named = handle.read().strip()
        if named in ordered:
            ordered.remove(named)
        ordered.insert(0, named)
    # What rank 0 found, so a checkpoint skipped for a manifest it could not see is on record and not inferred.
    emit(0, "candidates", latest=named, offered=ordered)
    return ordered


def manifest_ok(rel: str, world: int) -> dict | None:
    try:
        with open(os.path.join(ROOT, rel, "MANIFEST")) as handle:
            manifest = json.load(handle)
    except (OSError, ValueError):
        return None
    shards = manifest.get("shards", [])
    # Each shard must be named as the loader names it, so the file a rank hashes is the file it then loads.
    if (manifest.get("world_size") != world or len(shards) != world
            or sorted(s["rank"] for s in shards) != list(range(world))
            or any(s["step"] != manifest.get("step") or s["file"] != f"rank-{s['rank']}.pt" for s in shards)):
        return None
    return manifest


def shard_ok(rel: str, manifest: dict, rank: int) -> bool:
    entry = next(s for s in manifest["shards"] if s["rank"] == rank)
    path = os.path.join(ROOT, rel, entry["file"])
    errors: list[int | None] = []
    listed: list[bool | str] = []
    for attempt in range(VISIBILITY_RETRIES + 1):
        try:
            os.stat(path)
        except OSError as exc:
            # Absent and unreadable are both retried, but recorded apart: ENOENT is what a client's cached absence gives,
            # and any other error is something else.
            errors.append(exc.errno)
            # The directory is listed before the next look, because looking again alone did not help: in the first kind
            # run over NFS, a rank on a node that had looked its shard up before the shard existed refused every
            # checkpoint through all six looks while a listing of the same directory named the shard.
            # With the listing, the next look found it in every kind run since; which change in the client's cache does
            # that is not established, so this is a mitigation measured on Linux 7.0 against ganesha, not a guarantee.
            # Whether the listing names the shard also separates a shard the server lacks from one the client hid.
            try:
                listed.append(entry["file"] in os.listdir(os.path.dirname(path)))
            except OSError as list_exc:
                listed.append(f"error {list_exc.errno}")
        else:
            ok = sha256_file(path) == (entry["sha256"], entry["size"])
            # Every look is counted, so a retry that ran is recorded and one that never ran is not inferred.
            emit(rank, "shard_check", dir=rel, looks=attempt + 1, visible=True, hash_ok=ok, errors=errors, listed=listed)
            return ok
        if attempt < VISIBILITY_RETRIES:
            time.sleep(VISIBILITY_WAIT)
    emit(rank, "shard_check", dir=rel, looks=VISIBILITY_RETRIES + 1, visible=False, hash_ok=False, errors=errors,
         listed=listed)
    return False


def volume() -> dict:
    """The mount holding ROOT, as /proc/self/mountinfo describes it, or {} when none is found.

    Recorded so a run that meant to write through NFS can be refused when a rank wrote to something else, such as a
    hostPath the runner fell back to; the super options are what the client actually uses, not what was asked for.
    """
    best: dict = {}
    try:
        with open("/proc/self/mountinfo") as handle:
            for line in handle:
                fields = line.split()
                # The fields after the separator " - " are the file system type, the source and the super options.
                sep = fields.index("-")
                point = fields[4]
                if (ROOT == point or ROOT.startswith(point.rstrip("/") + "/")) and len(point) >= len(best.get("point", "")):
                    best = {"point": point, "mount_options": fields[5], "fstype": fields[sep + 1],
                            "source": fields[sep + 2], "super_options": fields[sep + 3] if len(fields) > sep + 3 else ""}
        # The device number names the client's cache of that mount: two Pods on one node whose mounts share it see the
        # same cached names, which is what the kind visibility cases rely on and check.
        if best:
            best["dev"] = os.stat(best["point"]).st_dev
    except (OSError, ValueError, IndexError):
        return {}
    return best


def choose(rank: int, world: int) -> tuple[str, dict] | None:
    """Rank 0 offers checkpoints newest first; every rank checks its own shard; all load the first all accept."""
    offers = candidates() if rank == 0 else []
    count = broadcast_json(len(offers), rank)
    for i in range(count):
        rel, manifest = broadcast_json([offers[i], manifest_ok(offers[i], world)] if rank == 0 else None, rank)
        ok = manifest is not None and shard_ok(rel, manifest, rank)
        verdict = torch.tensor([1 if ok else 0], device=COMM_DEVICE)
        dist.all_reduce(verdict, op=dist.ReduceOp.MIN)
        if verdict.item() == 1:
            return rel, manifest
        emit(rank, "checkpoint_rejected", dir=rel, own_shard_ok=ok)
    return None


def synthetic_dataset() -> TensorDataset:
    # Its own generator, so every rank and every attempt builds the same samples whatever the global RNG holds.
    gen = torch.Generator().manual_seed(1234)
    x = torch.randn(DATASET_SIZE, 4, generator=gen)
    y = x @ TRUE_W + 0.5 + 0.1 * torch.randn(DATASET_SIZE, 1, generator=gen)
    return TensorDataset(x, y)


def capture(step: int, model: nn.Module, optimiser: torch.optim.Optimizer,
            scheduler: torch.optim.lr_scheduler.LRScheduler, epoch: int, position: int,
            ballast: torch.Tensor | None = None) -> dict:
    """This rank's whole training state after step, which every rank saves even where DDP replicates it."""
    state = {"step": step, "model": model.state_dict(), "optimizer": optimiser.state_dict(),
             "scheduler": scheduler.state_dict(), "sampler": {"epoch": epoch, "position": position},
             "rng": torch.get_rng_state()}
    # Saved whenever CUDA is present, which only the nccl mode's image provides; no CPU check saves or restores it.
    if torch.cuda.is_available():
        state["cuda_rng"] = torch.cuda.get_rng_state_all()
    # Saved and never restored: it is there to give the write its size, and loading it would change nothing.
    if ballast is not None:
        state["ballast"] = ballast
    return state


def select_device(rank: int) -> torch.device | None:
    """The device this rank trains and communicates on, or None, with a refusal recorded, when the backend cannot run.

    Decided before the process group exists, so a rank that refuses leaves its peers a failed rendezvous to report
    rather than a collective that waits the whole COLLECTIVE_TIMEOUT for it.
    """
    if BACKEND == "gloo":
        return torch.device("cpu")
    # A CPU image would otherwise reach init_process_group and fail inside NCCL, or worse, a gloo fallback in some later
    # edit would train on the CPU and be reported as a GPU run.
    if not torch.cuda.is_available():
        emit(rank, "refused", reason="CKPT_BACKEND=nccl and CUDA is not available")
        return None
    local = os.environ.get("LOCAL_RANK", "0")
    # One rank per GPU: a LOCAL_RANK naming a device the Pod cannot see would put two ranks on one card.
    if not local.isdigit() or int(local) >= torch.cuda.device_count():
        emit(rank, "refused", reason=f"LOCAL_RANK={local!r} with {torch.cuda.device_count()} visible device(s)")
        return None
    torch.cuda.set_device(int(local))
    return torch.device("cuda", int(local))


def main() -> int:
    if HEARTBEAT <= 0:
        return train()
    rank = int(os.environ["RANK"])
    # Started before the process group, so an attempt's first write to the volume is as early as its process can make it.
    heartbeat = Heartbeat(rank)
    heartbeat.start()
    try:
        code = train()
    except Exception as exc:
        if not LINGER:
            raise
        heartbeat.phase = "lingering"
        emit(rank, "lingering", error=repr(exc)[:300])
        # Never returns: only a kill from outside ends this process, as only fencing ends a writer the platform cannot reach.
        while True:
            time.sleep(3600)
    heartbeat.stop()
    return code


def train() -> int:
    if LOAD_MODE not in LOAD_MODES:
        print(f"CKPT_LOAD={LOAD_MODE!r} is not one of {LOAD_MODES}", file=sys.stderr)
        return 2
    if BACKEND not in BACKENDS:
        print(f"CKPT_BACKEND={BACKEND!r} is not one of {BACKENDS}", file=sys.stderr)
        return 2
    if BALLAST_MB < 0:
        print(f"CKPT_BALLAST_MB={BALLAST_MB} is negative", file=sys.stderr)
        return 2
    if RENDEZVOUS_TIMEOUT is not None and RENDEZVOUS_TIMEOUT <= 0:
        print(f"CKPT_RENDEZVOUS_TIMEOUT={RENDEZVOUS_TIMEOUT} is not positive", file=sys.stderr)
        return 2
    # Under torchrun the agent's store already listens on MASTER_PORT, so a second store on rank 0 could not bind it.
    if RENDEZVOUS_TIMEOUT is not None and os.environ.get("TORCHELASTIC_USE_AGENT_STORE"):
        print("CKPT_RENDEZVOUS_TIMEOUT needs train.py started directly, not under torchrun", file=sys.stderr)
        return 2
    rank = int(os.environ["RANK"])
    world = int(os.environ["WORLD_SIZE"])
    device = select_device(rank)
    if device is None:
        return 3
    global COMM_DEVICE
    COMM_DEVICE = device
    torch.set_num_threads(1)
    torch.manual_seed(0)
    collective = datetime.timedelta(seconds=COLLECTIVE_TIMEOUT)
    if RENDEZVOUS_TIMEOUT is None:
        dist.init_process_group(backend=BACKEND, timeout=collective)
    else:
        # The store env:// would build, with its own wait for every rank to connect, from whichever side arrives first.
        # Every later store operation, which the process group's own exchanges wait on, is back at the collective timeout.
        joining = datetime.timedelta(seconds=RENDEZVOUS_TIMEOUT)
        store = dist.TCPStore(os.environ["MASTER_ADDR"], int(os.environ["MASTER_PORT"]), world, rank == 0,
                              timeout=joining, wait_for_workers=True)
        # Only the server waits for every rank to connect; a client returns once it alone has, so with three ranks the
        # second could reach the process group's exchanges, at the collective timeout, while the third was still starting.
        store.set(f"ckpt-rendezvous/{rank}", "1")
        store.wait([f"ckpt-rendezvous/{r}" for r in range(world)], joining)
        store.set_timeout(collective)
        dist.init_process_group(backend=BACKEND, store=store, rank=rank, world_size=world, timeout=collective)
    # Rank 0 alone creates the job's and the attempt's directories, and the others wait for it, for the reason save gives.
    if rank == 0:
        os.makedirs(os.path.join(ROOT, f"a{ATTEMPT}"), exist_ok=True)
    dist.barrier()
    fault = Fault(FAULT)
    # One fixed buffer, made once, so what a save's timing includes is the write and not building the bytes.
    ballast = torch.full((BALLAST_MB << 20,), 7, dtype=torch.uint8, device=device) if BALLAST_MB else None

    # Dropout draws its masks from the global RNG, which is what makes that RNG part of the state a resume must restore.
    # Built on the CPU and then moved, so its initial weights come from the same CPU draws under either backend.
    model = nn.Sequential(nn.Linear(4, 8), nn.ReLU(), nn.Dropout(0.25), nn.Linear(8, 1)).to(device)
    dataset = synthetic_dataset()
    # drop_last, so every rank takes the same number of batches an epoch and no rank waits on a collective alone.
    sampler = DistributedSampler(dataset, num_replicas=world, rank=rank, shuffle=True, seed=0, drop_last=True)
    batches = sampler.num_samples // BATCH
    if batches == 0:
        raise SystemExit(f"{DATASET_SIZE} samples over {world} ranks is not one batch of {BATCH} per rank")
    # Batches already consumed in the current epoch; epoch and position together are the sampler's position.
    epoch, position = 0, 0
    start_step = 0
    loaded = None
    chosen = choose(rank, world) if LOAD_MODE != "none" else None
    if chosen is not None:
        rel, manifest = chosen
        # Mapped to this rank's device, because a shard written on another node's cuda:0 names a device by number only.
        loaded = torch.load(os.path.join(ROOT, rel, f"rank-{rank}.pt"), weights_only=True, map_location=device)
        start_step = manifest["step"]
        # The hash bound the bytes to the manifest when they were checked; the step inside them is checked too, because
        # the file is reopened to load it and a shard that says another step is not the checkpoint the ranks agreed on.
        if loaded.get("step") != start_step:
            emit(rank, "refused", reason=f"{rel} rank-{rank}.pt holds step {loaded.get('step')}, its manifest {start_step}")
            return 3
        model.load_state_dict(loaded["model"])
        if LOAD_MODE != "no-sampler":
            epoch, position = loaded["sampler"]["epoch"], loaded["sampler"]["position"]
        emit(rank, "resume", from_dir=rel, from_step=start_step)
    else:
        # Recorded, so a restart that found nothing is never read as a resume.
        emit(rank, "restart_from_zero", load_mode=LOAD_MODE)

    # Loaded before DDP wraps the model, because DDP broadcasts rank 0's parameters at construction.
    ddp = DDP(model, device_ids=[device.index]) if device.type == "cuda" else DDP(model)
    optimiser = torch.optim.SGD(ddp.parameters(), lr=0.05, momentum=0.9)
    scheduler = torch.optim.lr_scheduler.StepLR(optimiser, step_size=LR_STEP, gamma=LR_GAMMA)
    if loaded is not None and LOAD_MODE != "no-optimizer":
        optimiser.load_state_dict(loaded["optimizer"])
    if loaded is not None and LOAD_MODE != "no-scheduler":
        scheduler.load_state_dict(loaded["scheduler"])
    # Restored last, after building the model, so no draw made while constructing the run moves it off the saved state.
    if loaded is not None and LOAD_MODE != "no-rng":
        # map_location moved every tensor to the device, and the RNG setters take CPU byte tensors only.
        torch.set_rng_state(loaded["rng"].cpu())
        # On a CUDA device the dropout masks come from the CUDA generator, not the global one, so a checkpoint written
        # without its state, by a CPU attempt, is refused rather than resumed with a fresh CUDA RNG.
        # Judged by the device this attempt trains on, not by whether the host has CUDA: gloo on a GPU host trains on
        # the CPU and resumes a CPU checkpoint as it always did (codex review of 7e73d914).
        if device.type == "cuda" and "cuda_rng" not in loaded:
            emit(rank, "refused", reason=f"{rel} holds no CUDA RNG state and this attempt trains on CUDA")
            return 3
        if torch.cuda.is_available() and "cuda_rng" in loaded:
            torch.cuda.set_rng_state_all([s.cpu() for s in loaded["cuda_rng"]])

    cuda = {}
    if device.type == "cuda":
        # Which card and which libraries trained this attempt, read by the paid session's scorer.
        props = torch.cuda.get_device_properties(device)
        cuda = {"device_name": props.name, "gpu_uuid": str(props.uuid), "cuda_version": torch.version.cuda,
                "nccl_version": ".".join(str(p) for p in torch.cuda.nccl.version()),
                "nccl_env": {k: v for k, v in sorted(os.environ.items()) if k.startswith("NCCL_")}}
    emit(rank, "start", world_size=world, load_mode=LOAD_MODE, resumed_from_step=start_step, steps=STEPS,
         fault=FAULT, torch_version=torch.__version__, epoch=epoch, position=position,
         lr=optimiser.param_groups[0]["lr"], backend=BACKEND, device=str(device), ballast_mb=BALLAST_MB,
         volume=volume(), visibility_retries=VISIBILITY_RETRIES, shard_delay=SHARD_DELAY, **cuda)

    ddp.train()
    step = start_step
    while step < STEPS:
        # The sampler's permutation is seeded by seed + epoch, so the same epoch on a new attempt is the same order.
        sampler.set_epoch(epoch)
        # Indexed directly rather than through a DataLoader, whose every new iterator draws a base seed from the global
        # RNG: re-entering an epoch on resume would spend a draw the uninterrupted run never made.
        order = list(sampler)
        while position < batches and step < STEPS:
            x, y = dataset[order[position * BATCH:(position + 1) * BATCH]]
            x, y = x.to(device), y.to(device)
            step += 1
            position += 1
            optimiser.zero_grad()
            loss = ((ddp(x) - y) ** 2).mean()
            loss.backward()
            optimiser.step()
            scheduler.step()
            # The first step record of an attempt is what the experiment reads as training resumed, not Pod readiness.
            emit(rank, "step", step=step, loss=float(loss), digest=digest(model),
                 params=params(model) if step == STEPS else None)
            save(rank, world, step, capture(step, model, optimiser, scheduler, epoch, position, ballast), fault)
            if STEP_SLEEP:
                time.sleep(STEP_SLEEP)
        if position == batches:
            epoch, position = epoch + 1, 0

    dist.destroy_process_group()
    return 0


if __name__ == "__main__":
    sys.exit(main())
