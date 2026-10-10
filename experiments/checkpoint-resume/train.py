"""Two-rank gloo DDP that checkpoints every step and, when told, resumes from the newest checkpoint.

The question is whether a replacement Pod continues the SAME training or merely a plausible one. A falling loss
cannot tell those apart, so every completed step emits the parameters and a digest of them, and the analysis
compares the end of a resumed run against the end of one that was never interrupted.

Momentum and a per-rank data generator are there on purpose. Without momentum, reloading only the weights would
be a complete resume and the optimizer check could not fail; without generator state, the data order would be
a pure function of the step and the data check could not fail. Each is a piece of state a real trainer carries.

Settings arrive as environment variables because MLTrainingJob has no `env` field; the runner exports them in
the container command.
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import signal
import socket
import sys

import torch
import torch.distributed as dist
import torch.nn as nn
from torch.nn.parallel import DistributedDataParallel as DDP

RUN_ID = os.environ.get("CKPT_RUN_ID", "unset")
STEPS = int(os.environ.get("CKPT_STEPS", "40"))
STATE_DIR = os.environ.get("CKPT_DIR", "/state")
# none | full | no-optimizer | no-data-rng. Anything else is refused rather than read as one of these.
LOAD_MODE = os.environ.get("CKPT_LOAD", "none")
DIE_AT_STEP = int(os.environ.get("CKPT_DIE_AT_STEP", "0"))

LOAD_MODES = ("none", "full", "no-optimizer", "no-data-rng")
BATCH = 8
TRUE_W = torch.tensor([[1.0], [-2.0], [0.5], [3.0]])


def emit(rank: int, event: str, **fields: object) -> None:
    record = {
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "run_id": RUN_ID,
        "attempt": socket.gethostname(),
        "rank": rank,
        "event": event,
    }
    record.update(fields)
    # One write per record: both ranks share torchrun's stdout, and a record split across writes can interleave
    # with the other rank's (experiments/cpu-ddp/train.py hit exactly that).
    os.write(1, (json.dumps(record, sort_keys=True) + "\n").encode())


def params(model: nn.Module) -> list[float]:
    return [float(v) for _, t in sorted(model.state_dict().items()) for v in t.detach().flatten()]


def digest(model: nn.Module) -> str:
    hasher = hashlib.sha256()
    for name, tensor in sorted(model.state_dict().items()):
        hasher.update(name.encode())
        # A uint8 view rather than .numpy(): the CPU torch image ships without numpy.
        hasher.update(bytes(tensor.detach().contiguous().flatten().view(torch.uint8).tolist()))
    return hasher.hexdigest()


def write_atomically(path: str, write) -> None:
    # Written beside the target and renamed, so a reader sees the old file or the new one and never a torn one.
    tmp = path + ".tmp"
    with open(tmp, "wb") as handle:
        write(handle)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, path)


def ckpt_path(rank: int, step: int) -> str:
    return os.path.join(STATE_DIR, f"rank{rank}-step{step}.pt")


def main() -> int:
    if LOAD_MODE not in LOAD_MODES:
        print(f"CKPT_LOAD={LOAD_MODE!r} is not one of {LOAD_MODES}", file=sys.stderr)
        return 2
    rank = int(os.environ["RANK"])
    world_size = int(os.environ["WORLD_SIZE"])
    torch.set_num_threads(1)
    torch.manual_seed(0)
    dist.init_process_group(backend="gloo")

    model = nn.Linear(4, 1)
    data_rng = torch.Generator().manual_seed(1000 + rank)
    start_step = 0
    loaded = None

    latest = os.path.join(STATE_DIR, "LATEST")
    if LOAD_MODE != "none" and os.path.exists(latest):
        with open(latest) as handle:
            start_step = int(handle.read().strip())
        loaded = torch.load(ckpt_path(rank, start_step), weights_only=True)
        if loaded["step"] != start_step:
            raise RuntimeError(f"checkpoint for step {start_step} says it is step {loaded['step']}")
        model.load_state_dict(loaded["model"])
        if LOAD_MODE != "no-data-rng":
            data_rng.set_state(loaded["data_rng"])

    # Loaded before DDP wraps the model, because DDP broadcasts rank 0's parameters at construction.
    ddp = DDP(model)
    optimiser = torch.optim.SGD(ddp.parameters(), lr=0.05, momentum=0.9)
    if loaded is not None and LOAD_MODE != "no-optimizer":
        optimiser.load_state_dict(loaded["optimizer"])

    emit(rank, "start", world_size=world_size, load_mode=LOAD_MODE, resumed_from_step=start_step,
         loaded=loaded is not None, steps=STEPS, die_at_step=DIE_AT_STEP, torch_version=torch.__version__)

    marker = os.path.join(STATE_DIR, "killed-once")
    for step in range(start_step + 1, STEPS + 1):
        if DIE_AT_STEP and step == DIE_AT_STEP and rank == 1 and not os.path.exists(marker):
            # The marker is written before the kill and survives it, so the replacement Pod does not die again.
            write_atomically(marker, lambda h: h.write(b"1"))
            emit(rank, "self_kill", step=step, signal="SIGKILL")
            # A hard kill, not an exception: an OOM or an eviction does not unwind either.
            os.kill(os.getpid(), signal.SIGKILL)

        x = torch.randn(BATCH, 4, generator=data_rng)
        y = x @ TRUE_W + 0.5 + 0.1 * torch.randn(BATCH, 1, generator=data_rng)
        optimiser.zero_grad()
        loss = ((ddp(x) - y) ** 2).mean()
        loss.backward()
        optimiser.step()

        state = {"step": step, "model": model.state_dict(), "optimizer": optimiser.state_dict(),
                 "data_rng": data_rng.get_state()}
        write_atomically(ckpt_path(rank, step), lambda h: torch.save(state, h))
        dist.barrier()
        if rank == 0:
            write_atomically(latest, lambda h: h.write(str(step).encode()))
        # The second barrier holds every rank until LATEST names this step.
        # Without it a rank killed at the next step's start could die before rank 0 published, and the resume
        # would start one step earlier than the evidence says it should.
        dist.barrier()
        stale = ckpt_path(rank, step - 2)
        if os.path.exists(stale):
            os.remove(stale)

        emit(rank, "step", step=step, loss=float(loss), digest=digest(model),
             params=params(model) if step == STEPS else None)

    dist.destroy_process_group()
    return 0


if __name__ == "__main__":
    sys.exit(main())
