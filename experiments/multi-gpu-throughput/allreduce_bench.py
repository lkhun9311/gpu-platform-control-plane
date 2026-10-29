"""An all-reduce timing loop that refuses to report a bandwidth it did not verify.

The torch instrument of docs/superpowers/specs/2026-10-27-four-gpu-nccl-design.md, first drafted for
docs/superpowers/specs/2026-10-22-multi-gpu-per-pod-throughput-design.md.
It has never run on a GPU; its first execution is the registration's smoke block, and nothing it prints before that
block passes is a measurement.

Each rank fills its buffer with rank + 1 before every timed all-reduce, so every element of a correct SUM is
n(n+1)/2 exactly, and a reduction that did not happen, or happened over the wrong group, leaves a different number.
A size whose buffer does not hold that value on every rank gets no bandwidth at all, only the refusal.

The figure is NCCL's own convention, as nccl-tests defines it, so the two can be compared on the same message size:
algorithm bandwidth is bytes over time, and bus bandwidth multiplies it by 2(n-1)/n for an all-reduce.
The time of an iteration is the slowest rank's, because an all-reduce is not finished until every rank has it.

Settings arrive as environment variables, as in experiments/cpu-ddp/train.py, because MLTrainingJob has no env field.
torch is imported inside main, so the arithmetic below is tested without it.
"""

from __future__ import annotations

import datetime
import hashlib
import json
import math
import os
import socket
import statistics
import sys

# The default message sizes, in bytes: 1 MiB to 256 MiB by factors of four.
#
# Small sizes are latency, not bandwidth, so the ladder starts where a bandwidth reading means something.
# 256 MiB on four ranks is 1 GiB of device memory in all, far inside an A10G's 24 GB or a T4's 16 GB.
DEFAULT_SIZES = tuple(1 << s for s in (20, 22, 24, 26, 28))

# float32, so a buffer of B bytes holds B / 4 elements and the expected sum is exact for any world size up to 8.
ELEMENT_BYTES = 4

RUN_ID = os.environ.get("BENCH_RUN_ID", "unset")


class SettingRefused(Exception):
    """A setting the bench cannot run as asked; raised before rendezvous, so no peer waits on this rank."""


def bus_factor(world_size: int) -> float:
    """nccl-tests' bus bandwidth factor for all-reduce, 2(n-1)/n.

    One rank has nothing to reduce with, and a factor of 0 would report a bandwidth of 0 that nothing measured.
    """
    if world_size < 2:
        raise SettingRefused(f"an all-reduce over {world_size} rank moves nothing between GPUs")
    return 2.0 * (world_size - 1) / world_size


def expected_sum(world_size: int) -> float:
    """The value of every element after a SUM over ranks that each filled their buffer with rank + 1."""
    return world_size * (world_size + 1) / 2.0


def parse_sizes(text: str) -> tuple[int, ...]:
    """Message sizes in bytes from a comma-separated list; empty means the default ladder.

    A size that is not a whole positive multiple of the element size is refused rather than rounded, because the
    record would otherwise name a size that did not move.
    """
    if not text.strip():
        return DEFAULT_SIZES
    sizes = []
    for part in text.split(","):
        part = part.strip()
        if not part.isdigit():
            raise SettingRefused(f"BENCH_SIZES entry {part!r} is not a whole number of bytes")
        size = int(part)
        if size <= 0 or size % ELEMENT_BYTES:
            raise SettingRefused(f"BENCH_SIZES entry {size} is not a positive multiple of {ELEMENT_BYTES} bytes")
        sizes.append(size)
    if len(set(sizes)) != len(sizes):
        raise SettingRefused("BENCH_SIZES names a size twice, which would read as two repetitions")
    return tuple(sizes)


def parse_count(name: str, text: str, minimum: int) -> int:
    """A whole-number setting at least `minimum`, refused otherwise rather than defaulted."""
    if not text.strip().isdigit() or int(text) < minimum:
        raise SettingRefused(f"{name}={text!r} is not a whole number of at least {minimum}")
    return int(text)


def local_device_index(environ: dict, visible: int) -> int:
    """The CUDA device this process drives.

    LOCAL_RANK when a launcher set it, which is how several processes in one Pod divide its GPUs; otherwise 0, the
    one-GPU-per-Pod case.
    An index the Pod cannot see is refused: two processes silently sharing device 0 would each report a bandwidth,
    and the pair would read as two GPUs.
    """
    raw = environ.get("LOCAL_RANK", "0")
    if not raw.isdigit():
        raise SettingRefused(f"LOCAL_RANK={raw!r} is not a device index")
    index = int(raw)
    if index >= visible:
        raise SettingRefused(f"LOCAL_RANK {index} names a device, and this Pod sees {visible}")
    return index


def slowest_per_iteration(times_by_rank: list[list[float]]) -> list[float]:
    """Each iteration's time as the slowest rank saw it.

    Every rank must report the same number of iterations; a ragged set means a rank missed one, and the maximum of
    what is left would be taken over fewer ranks than the record claims.
    """
    if not times_by_rank or not times_by_rank[0]:
        raise ValueError("no timed iteration to summarise")
    lengths = {len(times) for times in times_by_rank}
    if len(lengths) != 1:
        raise ValueError(f"ranks timed different numbers of iterations: {sorted(lengths)}")
    # A NaN is not <= 0, and max() can pass over it, so a rank of NaNs once summarised to a finite time.
    if any(not math.isfinite(t) or t <= 0 for times in times_by_rank for t in times):
        raise ValueError("an iteration timed at zero or less, or not at all, which no transfer takes")
    return [max(column) for column in zip(*times_by_rank)]


def summarise(size_bytes: int, world_size: int, times_by_rank: list[list[float]], verified: bool) -> dict:
    """One size's record: the raw times always, and bandwidth only when the result was verified on every rank.

    The median is the reported figure and the minimum and maximum sit beside it, so a reader sees the spread rather
    than a single number chosen from it.
    """
    record = {
        "size_bytes": size_bytes,
        "world_size": world_size,
        "iterations": len(times_by_rank[0]) if times_by_rank else 0,
        "times_s_by_rank": times_by_rank,
        "verified": verified,
    }
    if not verified:
        record["refused"] = "the reduced buffer did not hold the expected sum on every rank, so no bandwidth is reported"
        return record
    slowest = slowest_per_iteration(times_by_rank)
    median = statistics.median(slowest)
    factor = bus_factor(world_size)
    # Decimal gigabytes (1e9 bytes) per second, as nccl-tests prints them, and spelled out in the key: "gbps"
    # reads as gigabits, which would make every figure look eight times smaller than it is.
    # size_bytes is the payload of ONE rank's buffer, nccl-tests' S, never the sum over ranks.
    record.update(
        {
            "time_s_median": median,
            "time_s_min": min(slowest),
            "time_s_max": max(slowest),
            "algbw_gigabytes_per_s_median": size_bytes / median / 1e9,
            "busbw_gigabytes_per_s_median": size_bytes / median / 1e9 * factor,
            "busbw_gigabytes_per_s_at_min_time": size_bytes / min(slowest) / 1e9 * factor,
            "busbw_gigabytes_per_s_at_max_time": size_bytes / max(slowest) / 1e9 * factor,
            "bus_factor": factor,
        }
    )
    return record


def buffer_matches(lowest: float, highest: float, world_size: int) -> bool:
    """Whether a buffer whose smallest and largest elements are these holds the expected sum everywhere.

    Exact equality, not a tolerance: the operands are small integers in float32, whose sum is exact in any order.
    """
    want = expected_sum(world_size)
    return lowest == want and highest == want


def failing_iterations(extrema: list[tuple[float, float]], world_size: int) -> int:
    """How many iterations' buffers, each given as its (min, max), did not hold the expected sum at both ends.

    Judged per iteration, not over a running minimum and maximum: Python's min and max keep the earlier value against
    a NaN, so a NaN iteration between two correct ones would leave running extrema that look correct.
    """
    if not extrema:
        raise SettingRefused("no iterations were checked, so nothing was verified")
    return sum(1 for lowest, highest in extrema if not buffer_matches(lowest, highest, world_size))


def script_sha256() -> str:
    """The hash of this file, so a record says which code produced it."""
    with open(__file__, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


# Linux's PIPE_BUF: a write to a pipe no larger than this is never split by another writer's, and a larger one can be.
ATOMIC_WRITE_BYTES = 4096


class RecordTooLarge(Exception):
    """A record that could interleave with another rank's on a shared stdout, written while other ranks may write."""


def record_line(record: dict, alone: bool) -> bytes:
    """The record as one JSONL line, refused when it is too large for one atomic write and other ranks may be writing.

    Four ranks' timings at 100 iterations make a size record of over 10 KB, so that record is written only in turn.
    """
    line = (json.dumps(record, sort_keys=True) + "\n").encode()
    if len(line) > ATOMIC_WRITE_BYTES and not alone:
        raise RecordTooLarge(f"a {len(line)}-byte {record.get('event')} record would not be one atomic write")
    return line


def emit(rank: int, event: str, alone: bool = False, **fields: object) -> None:
    """One JSONL record to stdout in one write, so ranks sharing a launcher's stdout interleave between records.

    alone says no other rank writes until this call returns; emit_in_turn is what makes that true.
    """
    record = {
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "run_id": RUN_ID,
        "rank": rank,
        "event": event,
    }
    record.update(fields)
    line = record_line(record, alone)
    # os.write on a blocking pipe may still return short, so the rest is written before another rank's turn.
    while line:
        line = line[os.write(1, line) :]


def emit_in_turn(dist, rank: int, world_size: int, event: str, fields: dict) -> None:
    """Each rank writes its record while every other rank waits at a barrier, so a large record cannot interleave.

    fields is a dict, not keyword arguments, because a size record carries world_size itself and would collide.
    """
    for turn in range(world_size):
        if turn == rank:
            emit(rank, event, alone=True, **fields)
        dist.barrier()


def main() -> int:
    import torch
    import torch.distributed as dist

    rank = int(os.environ["RANK"])
    world_size = int(os.environ["WORLD_SIZE"])
    try:
        sizes = parse_sizes(os.environ.get("BENCH_SIZES", ""))
        warmup = parse_count("BENCH_WARMUP", os.environ.get("BENCH_WARMUP", "5"), 1)
        iterations = parse_count("BENCH_ITERS", os.environ.get("BENCH_ITERS", "20"), 3)
        bus_factor(world_size)
        if not torch.cuda.is_available():
            raise SettingRefused("CUDA is not available, and this bench measures GPUs only")
        device_index = local_device_index(os.environ, torch.cuda.device_count())
    except SettingRefused as exc:
        emit(rank, "refused", error=str(exc))
        return 1

    torch.cuda.set_device(device_index)
    device = torch.device("cuda", device_index)
    emit(
        rank,
        "start",
        world_size=world_size,
        local_rank=device_index,
        visible_devices=torch.cuda.device_count(),
        device_name=torch.cuda.get_device_name(device_index),
        # The card's identity, which the scorer compares across ranks: two ranks on one card is not two GPUs.
        gpu_uuid=str(torch.cuda.get_device_properties(device_index).uuid),
        hostname=socket.gethostname(),
        pid=os.getpid(),
        torch_version=torch.__version__,
        cuda_version=torch.version.cuda,
        nccl_version=".".join(str(part) for part in torch.cuda.nccl.version()),
        # Every NCCL_ variable in force, because each one can change the transport the figure describes.
        nccl_env={k: v for k, v in sorted(os.environ.items()) if k.startswith("NCCL_")},
        # Which cards the container was given, as the device plugin and the runtime said it; nothing here sets them.
        visible_devices_env={k: os.environ.get(k) for k in ("CUDA_VISIBLE_DEVICES", "NVIDIA_VISIBLE_DEVICES")},
        # What the process could run on, which differs by layout: torchrun and a Pod per rank set threads differently.
        cpu_affinity=len(os.sched_getaffinity(0)),
        omp_num_threads=os.environ.get("OMP_NUM_THREADS"),
        torch_threads=torch.get_num_threads(),
        device="cuda",
        script_sha256=script_sha256(),
        sizes=list(sizes),
        warmup=warmup,
        iterations=iterations,
    )

    dist.init_process_group(backend="nccl")
    failed = False
    for size in sizes:
        buffer = torch.empty(size // ELEMENT_BYTES, dtype=torch.float32, device=device)
        for _ in range(warmup):
            buffer.fill_(float(rank + 1))
            dist.all_reduce(buffer, op=dist.ReduceOp.SUM)
        torch.cuda.synchronize()
        dist.barrier()

        times = []
        extrema = []
        for _ in range(iterations):
            # Filled outside the timed span, so the time is the collective's and the check below is per iteration.
            buffer.fill_(float(rank + 1))
            # Every rank starts the iteration together, so a rank that arrives early does not count its wait for a
            # late one as transfer time; the slowest-rank rule below would otherwise publish that wait.
            torch.cuda.synchronize(device)
            dist.barrier()
            start = torch.cuda.Event(enable_timing=True)
            end = torch.cuda.Event(enable_timing=True)
            start.record()
            dist.all_reduce(buffer, op=dist.ReduceOp.SUM)
            end.record()
            end.synchronize()
            times.append(start.elapsed_time(end) / 1000.0)
            extrema.append((float(buffer.min()), float(buffer.max())))

        mismatched = failing_iterations(extrema, world_size)
        mine_ok = mismatched == 0
        # Every rank's times and verdict, gathered, so the record is the same on each rank and a rank that failed
        # its check fails the size for all of them.
        local = torch.tensor(times + [1.0 if mine_ok else 0.0], dtype=torch.float64, device=device)
        slots = [torch.zeros_like(local) for _ in range(world_size)]
        dist.all_gather(slots, local)
        rows = [slot.tolist() for slot in slots]
        verified = all(row[-1] == 1.0 for row in rows)
        record = summarise(size, world_size, [row[:-1] for row in rows], verified)
        emit_in_turn(dist, rank, world_size, "size", {"local_mismatched_iterations": mismatched, **record})
        failed = failed or not verified
        del buffer

    dist.destroy_process_group()
    emit(rank, "done", exit_code=1 if failed else 0)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
