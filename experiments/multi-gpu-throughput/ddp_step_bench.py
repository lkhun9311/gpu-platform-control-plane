"""A DDP step timer that refuses to report a step time whose gradient reduction it did not verify.

The step-time instrument of docs/superpowers/specs/2026-10-27-four-gpu-nccl-design.md.
It has never run on a GPU; its first execution is the registration's smoke jobs, and nothing it prints before they
pass is a measurement.

The model is synthetic and sized for its gradient, not for realism: STEP_LAYERS Linear(STEP_WIDTH, STEP_WIDTH) layers
with ReLU between them, float32.
At the registered 4 x 4096 its gradient totals 67,125,248 parameters = 268,500,992 bytes.
DDP does not reduce that as one message: it reduces buckets (25 MiB cap by default, and a 64 MiB weight in a bucket of
its own), so the record carries the bucket sizes DDP reports rather than an assumption about them.

Two kinds of step alternate, synced and local.
A synced step is forward and backward under DistributedDataParallel, so the gradient is all-reduced.
A local step is the same forward and backward under no_sync(), so no gradient leaves the GPU.
No optimizer step is taken: the parameters never change, every step does the same arithmetic.
The difference between the two medians is the cost of synchronisation as DDP incurs it, which includes the reducer's
own work as well as any all-reduce the backward did not overlap; it is not the all-reduce's time alone.
Every rank waits at a barrier before each timed step, outside the timed span, so one rank's checksum work cannot be
counted inside another rank's step.

Correctness is checked three ways.
Each rank's inputs come from a seed that depends on its rank, so its local gradient differs from every other rank's,
and the local steps' checksums must all differ.
After a synced step every rank must hold the same gradient checksum.
And the synced gradient must be the average of the ranks' local gradients, parameter by parameter: each rank's
per-parameter sums from its last local and last synced step are gathered, and each synced sum must equal the mean of
the local sums within a tolerance derived from float32 rounding (REDUCTION_RELATIVE_TOLERANCE).

Settings arrive as environment variables, as in allreduce_bench.py; torch is imported inside main, so the arithmetic
below is tested without it.
STEP_REHEARSAL_CPU=1 runs the same code on CPU with gloo, so a free rehearsal can exercise DDP, the oracle and the
records; every record it writes says device "cpu", and the scorer refuses a cpu record as a measurement.
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import socket
import statistics
import sys

RUN_ID = os.environ.get("STEP_RUN_ID", "unset")

# Linux's PIPE_BUF: a write to a pipe no larger than this is never split by another writer's, and a larger one can be.
ATOMIC_WRITE_BYTES = 4096

# The largest relative difference allowed between a synced parameter's gradient sum and the mean of the ranks' local
# sums, relative to the mean of their absolute sums.
# DDP divides each local gradient by the world size (exact for a power of two) and sums the four in float32: three
# additions per element, each rounding by at most float32's unit roundoff 2**-24 (about 5.96e-8) relative to the
# magnitudes added, so at most about 1.8e-7 of the sum of magnitudes; the float64 accumulation adds far less.
# 1e-6 is that bound rounded up, about five times it. A missing or partial reduction moves the sum by a share of the
# gradient itself, orders of magnitude more.
REDUCTION_RELATIVE_TOLERANCE = 1e-6


class SettingRefused(Exception):
    """A setting the bench cannot run as asked; raised before rendezvous, so no peer waits on this rank."""


class RecordTooLarge(Exception):
    """A record that could interleave with another rank's on a shared stdout, written while other ranks may write."""


def parse_count(name: str, text: str, minimum: int) -> int:
    """A whole-number setting at least `minimum`, refused otherwise rather than defaulted."""
    if not text.strip().isdigit() or int(text) < minimum:
        raise SettingRefused(f"{name}={text!r} is not a whole number of at least {minimum}")
    return int(text)


def parameter_count(layers: int, width: int) -> int:
    """Weights and biases of `layers` square Linear layers of `width`."""
    return layers * (width * width + width)


def gradient_bytes(layers: int, width: int) -> int:
    """The float32 gradient DDP all-reduces per synced step, summed over its buckets."""
    return parameter_count(layers, width) * 4


def local_device_index(environ: dict, visible: int) -> int:
    """LOCAL_RANK when a launcher set it, otherwise 0; an index the Pod cannot see is refused.

    The same rule as allreduce_bench.py: two processes silently sharing device 0 would read as two GPUs.
    """
    raw = environ.get("LOCAL_RANK", "0")
    if not raw.isdigit():
        raise SettingRefused(f"LOCAL_RANK={raw!r} is not a device index")
    index = int(raw)
    if index >= visible:
        raise SettingRefused(f"LOCAL_RANK {index} names a device, and this Pod sees {visible}")
    return index


def slowest_per_step(times_by_rank: list[list[float]]) -> list[float]:
    """Each step's time as the slowest rank saw it; a ragged or non-positive set is refused."""
    if not times_by_rank or not times_by_rank[0]:
        raise ValueError("no timed step to summarise")
    lengths = {len(times) for times in times_by_rank}
    if len(lengths) != 1:
        raise ValueError(f"ranks timed different numbers of steps: {sorted(lengths)}")
    if any(t <= 0 for times in times_by_rank for t in times):
        raise ValueError("a step timed at zero or less, which no step takes")
    return [max(column) for column in zip(*times_by_rank)]


def checksums_agree(per_step_by_rank: list[list[float]]) -> int:
    """How many synced steps' checksums were NOT identical on every rank.

    Exact equality: every rank received the same reduced bytes and sums them in the same order.
    A NaN never equals itself, so a NaN checksum fails the step, which is what it should do.
    """
    steps = list(zip(*per_step_by_rank))
    if not steps:
        raise ValueError("no synced step was checked")
    return sum(1 for column in steps if any(value != column[0] for value in column))


def checksums_differ(per_step_by_rank: list[list[float]]) -> int:
    """How many local steps had two ranks with the same checksum, or a NaN.

    Local gradients come from rank-dependent inputs, so any two ranks agreeing means the inputs were not what the
    synced check relies on.
    """
    steps = list(zip(*per_step_by_rank))
    if not steps:
        raise ValueError("no local step was checked")
    bad = 0
    for column in steps:
        finite = [value for value in column if value == value]
        if len(finite) != len(column) or len(set(finite)) != len(finite):
            bad += 1
    return bad


def reduction_mismatches(synced_sums_by_rank: list[list[float]], local_sums_by_rank: list[list[float]],
                         local_abs_by_rank: list[list[float]], tolerance: float = REDUCTION_RELATIVE_TOLERANCE) -> int:
    """How many parameters' synced gradient is not the average of the ranks' local gradients.

    Each argument holds, per rank, one value per parameter tensor: the sum of its gradient's elements (synced and
    local) and the sum of their absolute values (local).
    A parameter whose local gradient is zero on every rank is counted as a mismatch too, because an all-zero gradient
    satisfies any averaging check without showing that one happened.
    """
    ranks = len(local_sums_by_rank)
    if ranks < 2 or len(synced_sums_by_rank) != ranks or len(local_abs_by_rank) != ranks:
        raise ValueError("the oracle needs every rank's synced and local sums, from at least two ranks")
    widths = {len(row) for row in synced_sums_by_rank + local_sums_by_rank + local_abs_by_rank}
    if len(widths) != 1 or widths == {0}:
        raise ValueError(f"ranks reported different or no parameter counts: {sorted(widths)}")
    bad = 0
    for p in range(widths.pop()):
        expected = sum(row[p] for row in local_sums_by_rank) / ranks
        scale = sum(row[p] for row in local_abs_by_rank) / ranks
        if not scale > 0:
            bad += 1
            continue
        if any(not abs(row[p] - expected) <= tolerance * scale for row in synced_sums_by_rank):
            bad += 1
    return bad


def summarise(synced_by_rank: list[list[float]], local_by_rank: list[list[float]], synced_mismatches: int,
              local_collisions: int, reduction_failures: int) -> dict:
    """The phase record: raw times always, and step times only when every correctness check held.

    Times are seconds in the raw lists and milliseconds in the summary, and the keys say so.
    """
    record = {
        "synced_s_by_rank": synced_by_rank,
        "local_s_by_rank": local_by_rank,
        "synced_steps": len(synced_by_rank[0]) if synced_by_rank else 0,
        "local_steps": len(local_by_rank[0]) if local_by_rank else 0,
        "synced_checksum_mismatches": synced_mismatches,
        "local_checksum_collisions": local_collisions,
        "reduction_mismatched_parameters": reduction_failures,
        "verified": synced_mismatches == 0 and local_collisions == 0 and reduction_failures == 0,
    }
    if not record["verified"]:
        record["refused"] = (
            "a synced gradient differed between ranks or from the average of the local ones, or local gradients did "
            "not differ, so no step time is reported"
        )
        return record
    synced = slowest_per_step(synced_by_rank)
    local = slowest_per_step(local_by_rank)
    synced_ms = statistics.median(synced) * 1000.0
    local_ms = statistics.median(local) * 1000.0
    record.update(
        {
            "synced_ms_median": synced_ms,
            "synced_ms_min": min(synced) * 1000.0,
            "synced_ms_max": max(synced) * 1000.0,
            "local_ms_median": local_ms,
            "local_ms_min": min(local) * 1000.0,
            "local_ms_max": max(local) * 1000.0,
            # What synchronisation added to a step as DDP does it, as a difference of medians; not the all-reduce alone.
            "sync_cost_ms": synced_ms - local_ms,
        }
    )
    return record


def script_sha256() -> str:
    """The hash of this file, so a record says which code produced it."""
    with open(__file__, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def record_line(record: dict, alone: bool) -> bytes:
    """The record as one JSONL line, refused when too large for one atomic write while other ranks may write."""
    line = (json.dumps(record, sort_keys=True) + "\n").encode()
    if len(line) > ATOMIC_WRITE_BYTES and not alone:
        raise RecordTooLarge(f"a {len(line)}-byte {record.get('event')} record would not be one atomic write")
    return line


def emit(rank: int, event: str, alone: bool = False, **fields: object) -> None:
    """One JSONL record to stdout in one write, so ranks sharing a launcher's stdout interleave between records."""
    record = {
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "run_id": RUN_ID,
        "rank": rank,
        "event": event,
    }
    record.update(fields)
    line = record_line(record, alone)
    while line:
        line = line[os.write(1, line) :]


def emit_in_turn(dist, rank: int, world_size: int, event: str, fields: dict) -> None:
    """Each rank writes its record while every other rank waits at a barrier, so a large record cannot interleave."""
    for turn in range(world_size):
        if turn == rank:
            emit(rank, event, alone=True, **fields)
        dist.barrier()


def ddp_buckets(model) -> dict:
    """The bucket sizes DDP reports for itself, or why they could not be read.

    A private API, read defensively: its absence is recorded, never guessed at.
    """
    try:
        data = model._get_ddp_logging_data()
    except Exception as exc:  # noqa: BLE001 -- any failure is recorded as the answer
        return {"unavailable": f"{type(exc).__name__}: {exc}"}
    return {key: data.get(key) for key in ("bucket_sizes", "bucket_cap_bytes", "num_buckets_reduced",
                                           "has_rebuilt_buckets", "rebuilt_bucket_sizes") if key in data}


def main() -> int:
    import time

    import torch
    import torch.distributed as dist
    from torch.nn.parallel import DistributedDataParallel

    rank = int(os.environ["RANK"])
    world_size = int(os.environ["WORLD_SIZE"])
    rehearsal = os.environ.get("STEP_REHEARSAL_CPU") == "1"
    try:
        layers = parse_count("STEP_LAYERS", os.environ.get("STEP_LAYERS", "4"), 1)
        width = parse_count("STEP_WIDTH", os.environ.get("STEP_WIDTH", "4096"), 1)
        batch = parse_count("STEP_BATCH", os.environ.get("STEP_BATCH", "64"), 1)
        warmup = parse_count("STEP_WARMUP", os.environ.get("STEP_WARMUP", "20"), 1)
        pairs = parse_count("STEP_PAIRS", os.environ.get("STEP_PAIRS", "50"), 3)
        if world_size < 2:
            raise SettingRefused(f"a DDP step over {world_size} rank reduces nothing between GPUs")
        if not rehearsal and not torch.cuda.is_available():
            raise SettingRefused("CUDA is not available, and this bench measures GPUs only")
        device_index = 0 if rehearsal else local_device_index(os.environ, torch.cuda.device_count())
    except SettingRefused as exc:
        emit(rank, "refused", error=str(exc))
        return 1

    if rehearsal:
        device = torch.device("cpu")
        backend = "gloo"
        identity = {"device": "cpu", "gpu_uuid": None, "device_name": "cpu", "visible_devices": 0}

        def sync() -> None:
            return None
    else:
        torch.cuda.set_device(device_index)
        device = torch.device("cuda", device_index)
        backend = "nccl"
        identity = {
            "device": "cuda",
            "gpu_uuid": str(torch.cuda.get_device_properties(device_index).uuid),
            "device_name": torch.cuda.get_device_name(device_index),
            "visible_devices": torch.cuda.device_count(),
        }

        def sync() -> None:
            torch.cuda.synchronize(device)

    emit(
        rank,
        "start",
        world_size=world_size,
        local_rank=device_index,
        # As the launcher set it, or None in a Pod per rank; the CPU rehearsal reads it to show four distinct ranks.
        local_rank_env=os.environ.get("LOCAL_RANK"),
        backend=backend,
        hostname=socket.gethostname(),
        pid=os.getpid(),
        torch_version=torch.__version__,
        cuda_version=torch.version.cuda,
        nccl_version=None if rehearsal else ".".join(str(part) for part in torch.cuda.nccl.version()),
        nccl_env={k: v for k, v in sorted(os.environ.items()) if k.startswith("NCCL_")},
        visible_devices_env={k: os.environ.get(k) for k in ("CUDA_VISIBLE_DEVICES", "NVIDIA_VISIBLE_DEVICES")},
        # What the process could run on, which differs by layout: torchrun and a Pod per rank set threads differently.
        cpu_affinity=len(os.sched_getaffinity(0)),
        omp_num_threads=os.environ.get("OMP_NUM_THREADS"),
        torch_threads=torch.get_num_threads(),
        script_sha256=script_sha256(),
        layers=layers,
        width=width,
        batch=batch,
        parameters=parameter_count(layers, width),
        gradient_bytes=gradient_bytes(layers, width),
        warmup_pairs=warmup,
        timed_pairs=pairs,
        **identity,
    )

    dist.init_process_group(backend=backend)
    # The same weights on every rank, as DDP requires; DDP also broadcasts rank 0's at construction.
    torch.manual_seed(0)
    blocks = []
    for i in range(layers):
        blocks.append(torch.nn.Linear(width, width))
        if i < layers - 1:
            blocks.append(torch.nn.ReLU())
    module = torch.nn.Sequential(*blocks).to(device)
    model = DistributedDataParallel(module, device_ids=None if rehearsal else [device_index])
    # Rank-dependent inputs, drawn once on the device so no host transfer sits inside a timed step.
    generator = torch.Generator(device=device)
    generator.manual_seed(1000 + rank)
    inputs = torch.randn(batch, width, device=device, generator=generator)

    def step(synced: bool) -> tuple[float, float]:
        model.zero_grad(set_to_none=False)
        sync()
        # Outside the timed span: every rank starts the step together.
        dist.barrier()
        start = time.perf_counter()
        if synced:
            model(inputs).square().mean().backward()
        else:
            with model.no_sync():
                model(inputs).square().mean().backward()
        sync()
        elapsed = time.perf_counter() - start
        # Outside the timed span: the float64 sum of every gradient element, in parameter order.
        checksum = float(sum(p.grad.double().sum() for p in model.parameters()))
        return elapsed, checksum

    def per_parameter() -> tuple[list[float], list[float]]:
        sums = [float(p.grad.double().sum()) for p in model.parameters()]
        magnitudes = [float(p.grad.double().abs().sum()) for p in model.parameters()]
        return sums, magnitudes

    for _ in range(warmup):
        step(True)
        step(False)

    synced_times, synced_sums, local_times, local_sums = [], [], [], []
    for _ in range(pairs):
        t, c = step(True)
        synced_times.append(t)
        synced_sums.append(c)
        t, c = step(False)
        local_times.append(t)
        local_sums.append(c)
    # The last step taken was local; its gradient is this rank's own. One more synced step, untimed, for the oracle.
    local_param_sums, local_param_abs = per_parameter()
    step(True)
    synced_param_sums, _ = per_parameter()
    buckets = ddp_buckets(model)

    # Every rank's times and sums, gathered after the timed loop so no extra collective sits inside it.
    params = len(local_param_sums)
    vector = synced_times + synced_sums + local_times + local_sums + local_param_sums + local_param_abs + synced_param_sums
    local = torch.tensor(vector, dtype=torch.float64, device=device)
    slots = [torch.zeros_like(local) for _ in range(world_size)]
    dist.all_gather(slots, local)
    rows = [slot.tolist() for slot in slots]
    n = pairs

    def column(row: list[float], start: int, length: int) -> list[float]:
        return row[start : start + length]

    record = summarise(
        [column(row, 0, n) for row in rows],
        [column(row, 2 * n, n) for row in rows],
        checksums_agree([column(row, n, n) for row in rows]),
        checksums_differ([column(row, 3 * n, n) for row in rows]),
        reduction_mismatches(
            [column(row, 4 * n + 2 * params, params) for row in rows],
            [column(row, 4 * n, params) for row in rows],
            [column(row, 4 * n + params, params) for row in rows],
        ),
    )
    record["ddp_buckets"] = buckets
    record["device"] = identity["device"]
    emit_in_turn(dist, rank, world_size, "steps", record)
    dist.destroy_process_group()
    failed = not record["verified"]
    emit(rank, "done", exit_code=1 if failed else 0)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
