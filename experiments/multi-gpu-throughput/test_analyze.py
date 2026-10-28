"""Tests for analyze.py: a valid job of every arm passes, and each validity line fails on a fixture that breaks only it.

The fixtures are built here, in the shapes the arm library and the benches write, rather than taken from a run:
no GPU run exists. The first real evidence is the smoke jobs', and the scorer is run on it before any figure is read.
"""

from __future__ import annotations

import contextlib
import io
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import analyze  # noqa: E402

BENCH = "a" * 64
STEP = "b" * 64
NODE = "ip-10-0-1-1"
UUIDS = ["5c1d5a84-0000-0000-0000-00000000000%d" % i for i in range(4)]
# As run 2 of 2026-10-28 captured them: one PCI bus, 00, and the four GPUs at devices 1B to 1E.
DEVICES = [0x1B, 0x1C, 0x1D, 0x1E]


def preamble(name: str, host: str, shm_kb: int = 1048576, extra_env: dict | None = None) -> list[str]:
    env = {"NCCL_DEBUG": "INFO", "NCCL_DEBUG_SUBSYS": "INIT,GRAPH,ENV", **(extra_env or {})}
    return [f"AR_RUN_ID {name} {host}", "AR_NCCL_CONF absent /etc/nccl.conf", "AR_NCCL_CONF absent /root/.nccl.conf",
            *[f"AR_NCCL_ENV {k}={v}" for k, v in env.items()], f"AR_SHM_KB {shm_kb}"]


def start(name: str, rank: int, pid: int, host: str, sha: str, ddp: bool) -> dict:
    record = {"run_id": name, "rank": rank, "event": "start", "world_size": 4, "pid": pid, "hostname": host,
              "device": "cuda", "gpu_uuid": UUIDS[rank], "nccl_version": "2.21.5",
              "nccl_env": {"NCCL_DEBUG": "INFO", "NCCL_DEBUG_SUBSYS": "INIT,GRAPH,ENV"}, "omp_num_threads": "1",
              "script_sha256": sha}
    if ddp:
        record.update({"layers": 4, "width": 4096, "batch": 64, "warmup_pairs": 20, "timed_pairs": 50})
    else:
        record.update({"warmup": 20, "iterations": 100, "sizes": list(analyze.SIZES)})
    return record


def nccl(host: str, pid: int, dev: int, msg: str) -> str:
    return f"{host}:{pid}:{pid + 7} [{dev}] NCCL INFO {msg}"


def channel(rank: int, via: str) -> str:
    """A channel line as NCCL 2.21.5 formats it for each transport, not as a fixture would like it.

    P2P and NET print the connection index after the channel (src/transport/p2p.cc:364, net.cc:195), SHM does not
    (shm.cc:95), and the first fixture here gave SHM the index it never prints, which hid a scorer that read only that form.
    """
    peer = (rank + 1) % 4
    number = "00" if via.startswith("SHM/") else "00/0"
    direction = " [send]" if via.startswith("NET/") else ""
    return f"Channel {number} : {rank}[{rank}] -> {peer}[{peer}]{direction} via {via}"


def rank_lines(name: str, rank: int, pid: int, host: str, ddp: bool, busbw_scale: float, transport: str) -> list[str]:
    lines = [json.dumps(start(name, rank, pid, host, STEP if ddp else BENCH, ddp))]
    lines.append(nccl(host, pid, rank, channel(rank, transport)))
    if ddp:
        lines.append(json.dumps({"run_id": name, "rank": rank, "event": "steps", "verified": True, "synced_steps": 50,
                                 "local_steps": 50, "device": "cuda", "synced_ms_median": 60.0 * busbw_scale,
                                 "local_ms_median": 10.0, "sync_cost_ms": 60.0 * busbw_scale - 10.0}))
    else:
        for size in analyze.SIZES:
            lines.append(json.dumps({"run_id": name, "rank": rank, "event": "size", "size_bytes": size, "verified": True,
                                     "iterations": 100, "busbw_gigabytes_per_s_median": 10.0 * busbw_scale}))
    lines.append(json.dumps({"run_id": name, "rank": rank, "event": "done", "exit_code": 0}))
    return lines


def nccltests_lines(name: str, host: str, scale: float) -> list[str]:
    lines = preamble(name, host, extra_env={"NCCL_VERSION": "2.21.5-1"})
    lines += [f"AR_GPU {i}, GPU-{UUIDS[i]}, 00000000:00:{DEVICES[i]:02X}.0, 550.127.05" for i in range(4)]
    lines.append("# nThread 1 nGpus 1 minBytes 1048576 maxBytes 268435456 step: 4(factor) warmup iters: 20 iters: 100 "
                 "agg iters: 1 validation: 1 graph: 0")
    lines += [f"#  Rank {i:2d} Group  0 Pid {100 + i:6d} on {host:>10} device {i:2d} [0x00] NVIDIA A10G"
              for i in range(4)]
    lines += [nccl(host, 100 + i, i, f"ncclCommInitRank comm 0x55951b4c62b{i} rank {i} nranks 4 cudaDev {i} nvmlDev {i} "
                                     f"busId {DEVICES[i]:x}0 commId 0x670d080c18c710e0 - Init COMPLETE") for i in range(4)]
    # As NCCL 2.21.5 prints it: a bare printf from rank 0, with no host:pid:tid prefix.
    lines.append("NCCL version 2.21.5+cuda12.4")
    lines += [nccl(host, 100 + i, i, channel(i, "SHM/direct/direct")) for i in range(4)]
    for size in analyze.SIZES:
        bw = 10.0 * scale
        lines.append(f"{size:>12}  {size // 4:>12}     float     sum      -1  1234.5  {bw / 1.5:6.2f}  {bw:6.2f}      0  "
                     f"1234.5  {bw / 1.5:6.2f}  {bw:6.2f}      0")
    lines.append("# Out of bounds values : 0 OK")
    return lines


def write_job(root: Path, dirname: str, arm: str, scale: float = 1.0) -> Path:
    """A valid job of `arm` under root/jobs/dirname; scale multiplies its bandwidth (and its step time)."""
    path = root / "jobs" / dirname
    path.mkdir(parents=True)
    name = "c-" + dirname
    pods, _ = analyze.SHAPES[arm]
    (path / "name").write_text(name + "\n")
    (path / "arm").write_text(arm + "\n")
    (path / "elapsed-seconds").write_text("95\n")
    command = ["sh", "-c", "mpirun ... all_reduce_perf " + " ".join(analyze.NCCLTESTS_FLAGS) + " "]
    (path / "mltrainingjob.json").write_text(json.dumps({"spec": {"command": command}}))
    (path / "final-mltj.json").write_text(json.dumps({"status": {"phase": "Succeeded"}}))
    # Each job is its own execution, as the cluster names them; job "a", which most tests edit, keeps the short names.
    suffix = "" if dirname == "a" else f"-{dirname}"
    (path / "final-job.json").write_text(json.dumps({"metadata": {"uid": "job-uid" + suffix}}))
    usage = [{"count": pods, "resourceUsage": {"nvidia.com/gpu": "4"}}]
    (path / "final-workloads.json").write_text(json.dumps({"items": [
        {"metadata": {"ownerReferences": [{"uid": "job-uid" + suffix}]}, "status": {"admission": {"podSetAssignments": usage}}}]}))
    samples = []
    ddp = arm.startswith("ddp-")
    for p in range(pods):
        uid = f"pod-uid-{p}{suffix}"
        host = f"{name}-{p}" if pods > 1 else name
        samples.append({"uid": uid, "name": host + "-x", "index": str(p) if pods > 1 else None, "node": NODE})
        if arm.startswith("nccltests-"):
            lines = nccltests_lines(name, host, scale)
        elif pods == 1:
            lines = preamble(name, host)
            for rank in range(4):
                lines += rank_lines(name, rank, 200 + rank, host, ddp, scale, "P2P/IPC")
        else:
            # Every rank is pid 1 in its own Pod, as run 3's ranks were.
            lines = preamble(name, host, shm_kb=65536) + rank_lines(name, p, 1, host, ddp, scale, "NET/Socket/0")
        (path / f"log-{uid}.txt").write_text("\n".join(lines) + "\n")
    (path / "pods.jsonl").write_text("\n".join(json.dumps(s) for s in samples) + "\n")
    return path


def edit_log(path: Path, uid: str, change) -> None:
    log = path / f"log-{uid}.txt"
    log.write_text("\n".join(change(log.read_text().splitlines())) + "\n")


def edit_records(path: Path, uid: str, change) -> None:
    def apply(lines):
        out = []
        for line in lines:
            if line.startswith("{"):
                record = change(json.loads(line))
                if record is None:
                    continue
                line = json.dumps(record)
            out.append(line)
        return out
    edit_log(path, uid, apply)


class Base(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.root)

    def judge(self, path: Path) -> analyze.Job:
        return analyze.judge_job(path, BENCH, STEP, NODE)

    def assertFault(self, path: Path, needle: str):
        job = self.judge(path)
        self.assertFalse(job.valid, f"passed, it must fail on {needle!r}")
        self.assertTrue(any(needle in f for f in job.faults), f"no fault mentions {needle!r}: {job.faults}")


class ValidJobs(Base):
    def test_every_arm_passes_as_written(self):
        for arm in analyze.ARMS:
            job = self.judge(write_job(self.root, arm, arm))
            self.assertTrue(job.valid, f"{arm}: {job.faults}")
            self.assertEqual(sorted(job.transports), [0, 1, 2, 3])

    def test_transports_are_read_per_rank(self):
        self.assertEqual(self.judge(write_job(self.root, "a", "allreduce-4pod1gpu")).transports[2], ["NET"])
        self.assertEqual(self.judge(write_job(self.root, "b", "allreduce-1pod4gpu")).transports[0], ["P2P"])
        self.assertEqual(self.judge(write_job(self.root, "c", "nccltests-1pod4gpu")).transports[3], ["SHM"])

    def test_a_bus_id_in_the_rank_bracket_is_read(self):
        path = write_job(self.root, "a", "allreduce-1pod4gpu")
        edit_log(path, "pod-uid-0", lambda lines: [x.replace("Channel 00/0 : 0[0] -> 1[1]", "Channel 00/0 : 0[1b0] -> 1[1c0]")
                                                   for x in lines])
        self.assertTrue(self.judge(path).valid)


class Platform(Base):
    def test_a_pod_off_the_qualified_node(self):
        path = write_job(self.root, "a", "allreduce-4pod1gpu")
        (path / "pods.jsonl").write_text((path / "pods.jsonl").read_text().replace(NODE, "ip-other", 1))
        self.assertFault(path, "want all on one node")

    def test_three_pods_of_four(self):
        path = write_job(self.root, "a", "allreduce-4pod1gpu")
        lines = (path / "pods.jsonl").read_text().splitlines()[:3]
        (path / "pods.jsonl").write_text("\n".join(lines) + "\n")
        self.assertFault(path, "3 Pod(s) were ever created, want 4")

    def test_two_gpus_reserved(self):
        path = write_job(self.root, "a", "allreduce-1pod4gpu")
        (path / "final-workloads.json").write_text((path / "final-workloads.json").read_text().replace('"4"', '"2"'))
        self.assertFault(path, "reserved nvidia.com/gpu 2")

    def test_no_workload(self):
        path = write_job(self.root, "a", "ddp-1pod4gpu")
        (path / "final-workloads.json").write_text('{"items": []}')
        self.assertFault(path, "0 Workload(s)")

    def test_a_timeout_and_a_failed_job(self):
        path = write_job(self.root, "a", "ddp-1pod4gpu")
        (path / "TIMEOUT").write_text("not terminal within the 240s budget")
        (path / "final-mltj.json").write_text('{"status": {"phase": "Running"}}')
        self.assertFault(path, "240s budget")
        self.assertFault(path, "not Succeeded")

    def test_a_late_terminal_answer(self):
        path = write_job(self.root, "a", "ddp-1pod4gpu")
        (path / "elapsed-seconds").write_text("251\n")
        self.assertFault(path, "over the registered 240 s")
        (path / "elapsed-seconds").unlink()
        self.assertFault(path, "no elapsed-seconds")

    def test_a_void_job(self):
        path = write_job(self.root, "a", "ddp-1pod4gpu")
        (path / "VOID").write_text("create refused")
        self.assertFault(path, "void: create refused")


class Identity(Base):
    def test_two_ranks_on_one_card(self):
        path = write_job(self.root, "a", "allreduce-1pod4gpu")
        edit_records(path, "pod-uid-0", lambda r: {**r, "gpu_uuid": UUIDS[0]} if r["event"] == "start" else r)
        self.assertFault(path, "distinct GPU UUID")

    def test_a_rank_with_no_transport_line(self):
        path = write_job(self.root, "a", "allreduce-1pod4gpu")
        edit_log(path, "pod-uid-0", lambda lines: [x for x in lines if not x.startswith(f"c-a:202:")])
        self.assertFault(path, "rank 2's process logged no channel transport")

    def test_swapped_logs_with_one_pid_are_caught(self):
        # Both Pods' ranks are pid 1; swapping two Pods' logs leaves every pid valid, and only the Pod binding catches it.
        path = write_job(self.root, "a", "allreduce-4pod1gpu")
        a, b = path / "log-pod-uid-0.txt", path / "log-pod-uid-1.txt"
        text_a, text_b = a.read_text(), b.read_text()
        a.write_text(text_b)
        b.write_text(text_a)
        self.assertFault(path, "want exactly its own")

    def test_one_pods_transport_cannot_vouch_for_another(self):
        # Rank 3's Pod lost its NCCL lines; rank 0's Pod has a line from pid 1 too, which must not be credited to rank 3.
        path = write_job(self.root, "a", "allreduce-4pod1gpu")
        edit_log(path, "pod-uid-3", lambda lines: [x for x in lines if "NCCL INFO" not in x])
        self.assertFault(path, "rank 3's process logged no channel transport")

    def test_a_stale_run_id(self):
        path = write_job(self.root, "a", "ddp-4pod1gpu")
        edit_records(path, "pod-uid-1", lambda r: {**r, "run_id": "c-yesterday"})
        self.assertFault(path, "not c-a")

    def test_a_record_cut_in_half(self):
        path = write_job(self.root, "a", "allreduce-1pod4gpu")
        edit_log(path, "pod-uid-0", lambda lines: lines + ['{"run_id": "c-a", "rank": 1, "ev'])
        self.assertFault(path, "does not parse")

    def test_a_rank_missing(self):
        path = write_job(self.root, "a", "allreduce-1pod4gpu")
        edit_records(path, "pod-uid-0", lambda r: None if r["rank"] == 3 else r)
        self.assertFault(path, "start records from ranks")


class Software(Base):
    def test_unapproved_script(self):
        path = write_job(self.root, "a", "ddp-1pod4gpu")
        edit_records(path, "pod-uid-0", lambda r: {**r, "script_sha256": "c" * 64} if r["event"] == "start" else r)
        self.assertFault(path, "not the approved")

    def test_another_nccl(self):
        path = write_job(self.root, "a", "allreduce-1pod4gpu")
        edit_records(path, "pod-uid-0", lambda r: {**r, "nccl_version": "2.20.5"} if r["event"] == "start" else r)
        self.assertFault(path, "not 2.21.5")

    def test_a_tuned_nccl_in_the_record(self):
        path = write_job(self.root, "a", "allreduce-1pod4gpu")
        edit_records(path, "pod-uid-0", lambda r: {**r, "nccl_env": {**r["nccl_env"], "NCCL_P2P_DISABLE": "1"}}
                     if r["event"] == "start" else r)
        self.assertFault(path, "ran with NCCL_ variables")

    def test_a_tuned_nccl_in_the_pod_environment(self):
        path = write_job(self.root, "a", "allreduce-4pod1gpu")
        edit_log(path, "pod-uid-2", lambda lines: lines + ["AR_NCCL_ENV NCCL_P2P_DISABLE=1"])
        self.assertFault(path, "started with NCCL_ variables")

    def test_a_configuration_file(self):
        path = write_job(self.root, "a", "nccltests-1pod4gpu")
        edit_log(path, "pod-uid-0", lambda lines: [x.replace("absent /etc/nccl.conf", "present /etc/nccl.conf") for x in lines])
        self.assertFault(path, "/etc/nccl.conf is not reported absent")

    def test_a_home_configuration_file(self):
        path = write_job(self.root, "a", "ddp-1pod4gpu")
        edit_log(path, "pod-uid-0", lambda lines: [x.replace("absent /root/.nccl.conf", "present /root/.nccl.conf") for x in lines])
        self.assertFault(path, ".nccl.conf is not reported absent")

    def test_threads_not_pinned(self):
        path = write_job(self.root, "a", "ddp-4pod1gpu")
        edit_records(path, "pod-uid-0", lambda r: {**r, "omp_num_threads": None} if r["event"] == "start" else r)
        self.assertFault(path, "OMP_NUM_THREADS")

    def test_a_cpu_rehearsal_is_not_a_measurement(self):
        path = write_job(self.root, "a", "ddp-1pod4gpu")
        edit_records(path, "pod-uid-0", lambda r: {**r, "device": "cpu"})
        self.assertFault(path, "not cuda")

    def test_small_shared_memory_in_a_four_gpu_pod(self):
        path = write_job(self.root, "a", "allreduce-1pod4gpu")
        edit_log(path, "pod-uid-0", lambda lines: [x.replace("AR_SHM_KB 1048576", "AR_SHM_KB 65536") for x in lines])
        self.assertFault(path, "under the 1 GiB")

    def test_settings_set_by_the_stack_are_recorded_not_refused(self):
        path = write_job(self.root, "a", "allreduce-1pod4gpu")
        edit_log(path, "pod-uid-0", lambda lines: lines + [nccl("c-a", 200, 0, "NCCL_CUMEM_ENABLE set by environment to 0")])
        job = self.judge(path)
        self.assertTrue(job.valid, job.faults)
        self.assertEqual(job.stack_env, {"NCCL_CUMEM_ENABLE": "0"})


class Correctness(Base):
    def test_an_unverified_size(self):
        path = write_job(self.root, "a", "allreduce-1pod4gpu")
        edit_records(path, "pod-uid-0", lambda r: {**r, "verified": False} if r.get("size_bytes") == 1 << 26 and r["rank"] == 1 else r)
        self.assertFault(path, "verified False")

    def test_a_missing_size(self):
        path = write_job(self.root, "a", "allreduce-4pod1gpu")
        edit_records(path, "pod-uid-0", lambda r: None if r.get("size_bytes") == 1 << 28 else r)
        self.assertFault(path, "recorded sizes")

    def test_twenty_iterations(self):
        path = write_job(self.root, "a", "allreduce-1pod4gpu")
        edit_records(path, "pod-uid-0", lambda r: {**r, "iterations": 20} if r["event"] == "start" else r)
        self.assertFault(path, "not the registered")

    def test_above_the_ceiling(self):
        path = write_job(self.root, "a", "allreduce-1pod4gpu", scale=6.5)
        self.assertFault(path, "above the 64 GB/s")

    def test_ddp_unverified(self):
        path = write_job(self.root, "a", "ddp-4pod1gpu")
        edit_records(path, "pod-uid-2", lambda r: {**r, "verified": False} if r["event"] == "steps" else r)
        self.assertFault(path, "verified False")

    def test_ddp_wrong_model(self):
        path = write_job(self.root, "a", "ddp-1pod4gpu")
        edit_records(path, "pod-uid-0", lambda r: {**r, "width": 1024} if r["event"] == "start" else r)
        self.assertFault(path, "not the registered")

    def test_ddp_nan_step_time(self):
        # Python's json reads NaN, and a NaN median would compare false both ways and read "not distinguished".
        path = write_job(self.root, "a", "ddp-1pod4gpu")
        edit_records(path, "pod-uid-0", lambda r: {**r, "synced_ms_median": float("nan")} if r["event"] == "steps" else r)
        self.assertFault(path, "synced_ms_median is nan, not a finite number")

    def test_ddp_negative_step_time(self):
        path = write_job(self.root, "a", "ddp-4pod1gpu")
        edit_records(path, "pod-uid-0", lambda r: {**r, "local_ms_median": -1.0} if r["event"] == "steps" else r)
        self.assertFault(path, "local_ms_median is -1.0, not a positive time")

    def test_a_rank_refused(self):
        path = write_job(self.root, "a", "ddp-4pod1gpu")
        edit_records(path, "pod-uid-1", lambda r: {"run_id": "c-a", "rank": 1, "event": "refused",
                                                   "error": "CUDA is not available"} if r["event"] == "done" else r)
        self.assertFault(path, "CUDA is not available")


class NcclTests(Base):
    def test_wrong_elements(self):
        path = write_job(self.root, "a", "nccltests-1pod4gpu")
        edit_log(path, "pod-uid-0", lambda lines: [x[:-1] + "3" if x.lstrip().startswith("16777216") else x for x in lines])
        self.assertFault(path, "wrong elements")

    def test_a_missing_flag(self):
        path = write_job(self.root, "a", "nccltests-1pod4gpu")
        spec = json.loads((path / "mltrainingjob.json").read_text())
        spec["spec"]["command"][2] = spec["spec"]["command"][2].replace("-a 3", "-a 1")
        (path / "mltrainingjob.json").write_text(json.dumps(spec))
        self.assertFault(path, "does not carry -a 3")

    def test_another_warmup(self):
        path = write_job(self.root, "a", "nccltests-1pod4gpu")
        edit_log(path, "pod-uid-0", lambda lines: [x.replace("warmup iters: 20", "warmup iters: 5") for x in lines])
        self.assertFault(path, "not the registered settings")

    def test_two_ranks_on_one_bus(self):
        path = write_job(self.root, "a", "nccltests-1pod4gpu")
        edit_log(path, "pod-uid-0", lambda lines: [x.replace("busId 1c0", "busId 1b0") for x in lines])
        self.assertFault(path, "distinct GPU UUID")

    def test_one_process_for_two_ranks(self):
        path = write_job(self.root, "a", "nccltests-1pod4gpu")
        edit_log(path, "pod-uid-0", lambda lines: [x.replace("Pid    101", "Pid    100") for x in lines])
        self.assertFault(path, "share a process id")

    def test_a_prefixed_banner_is_read_too(self):
        path = write_job(self.root, "a", "nccltests-1pod4gpu")
        edit_log(path, "pod-uid-0", lambda lines: [nccl("c-a", 100, 0, x) if x.startswith("NCCL version") else x
                                                   for x in lines])
        self.assertTrue(self.judge(path).valid)

    def test_no_banner(self):
        path = write_job(self.root, "a", "nccltests-1pod4gpu")
        edit_log(path, "pod-uid-0", lambda lines: [x for x in lines if "NCCL version" not in x])
        self.assertFault(path, "want 2.21.5")

    def test_another_nccl_library(self):
        path = write_job(self.root, "a", "nccltests-1pod4gpu")
        edit_log(path, "pod-uid-0", lambda lines: [x.replace("NCCL version 2.21.5+", "NCCL version 2.23.4+") for x in lines])
        self.assertFault(path, "want 2.21.5")

    def test_out_of_bounds(self):
        path = write_job(self.root, "a", "nccltests-1pod4gpu")
        edit_log(path, "pod-uid-0", lambda lines: [x.replace(": 0 OK", ": 2 FAILED") for x in lines])
        self.assertFault(path, "out-of-bounds")

    def test_the_package_label_is_allowed_only_here(self):
        path = write_job(self.root, "a", "allreduce-1pod4gpu")
        edit_log(path, "pod-uid-0", lambda lines: lines + ["AR_NCCL_ENV NCCL_VERSION=2.21.5-1"])
        self.assertFault(path, "started with NCCL_ variables")


class CapturedJob(unittest.TestCase):
    """A job the paid session of 2026-10-28 ran, read as committed: nothing here is a form imagined for a fixture."""

    JOB = Path(__file__).resolve().parents[2] / "hack/four-gpu/2026-10-27-run2/c/jobs/00-smoke-nccltests-1pod4gpu"

    def test_the_smoke_job_that_was_voided_reads_as_four_gpus(self):
        # Its rank lines all print [0x00], and reading them as the bus that tells GPUs apart voided that session.
        job = analyze.judge_job(self.JOB, BENCH, STEP, None)
        self.assertEqual(job.faults, [])
        self.assertEqual(len(set(job.uuids.values())), 4)


class Qualification(Base):
    def write(self, extra: list[str] | None = None, drop: str | None = None) -> Path:
        path = self.root / "qualification"
        path.mkdir(exist_ok=True)
        lines = [f"GPU {i}: NVIDIA A10G (UUID: GPU-{UUIDS[i]})" for i in range(4)]
        lines += [f"AR_GPU {i}, GPU-{UUIDS[i]}, 00000000:00:{DEVICES[i]:02X}.0, 550.127.05" for i in range(4)]
        lines += ["\tGPU0\tGPU1\tGPU2\tGPU3\tCPU Affinity\tNUMA Affinity",
                  *[f"GPU{i}\t X \tPHB\tPHB\tPHB\t0-47\t0" for i in range(4)], "AR_SHM_KB 1048576"]
        lines = [x for x in lines if not (drop and drop in x)] + (extra or [])
        (path / "qualification.log").write_text("\n".join(lines) + "\n")
        return path

    def test_valid(self):
        self.assertEqual(analyze.judge_qualification(self.write()), [])

    def test_three_cards(self):
        self.assertTrue(analyze.judge_qualification(self.write(drop="GPU 3: NVIDIA")))

    def test_no_topology(self):
        self.assertTrue(analyze.judge_qualification(self.write(drop="GPU3\t X")))

    def test_the_header_nvidia_smi_underlines(self):
        # The header exactly as the paid session of 2026-10-27 captured it: nvidia-smi underlined it with ANSI
        # escapes although no terminal was attached, and a scorer that read only the plain form voided that run.
        path = self.write(drop="\tGPU0\tGPU1")
        log = path / "qualification.log"
        log.write_text("\t\x1b[4mGPU0\tGPU1\tGPU2\tGPU3\tCPU Affinity\tNUMA Affinity\tGPU NUMA ID\x1b[0m\n" + log.read_text())
        self.assertEqual(analyze.judge_qualification(path), [])

    def test_small_shared_memory(self):
        path = self.write(drop="AR_SHM_KB")
        (path / "qualification.log").write_text((path / "qualification.log").read_text() + "AR_SHM_KB 65536\n")
        self.assertTrue(analyze.judge_qualification(path))


class Score(Base):
    def build(self, one_pod: float = 2.0, four_pods: float = 1.0) -> None:
        (self.root / "provenance.txt").write_text(f"node={NODE}\n")
        Qualification.write(self)
        for arm in analyze.ARMS:
            write_job(self.root, f"00-smoke-{arm}", arm)
        seq = 0
        for rep in range(1, 6):
            for arm in analyze.ARMS:
                seq += 1
                scale = one_pod if "1pod4gpu" in arm else four_pods
                write_job(self.root, f"{seq:02d}-{arm}-{rep}", arm, scale=scale + rep * 0.01)

    def run_score(self) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = analyze.score(self.root, BENCH, STEP)
        return code, out.getvalue()

    def test_a_complete_valid_run(self):
        self.build()
        code, text = self.run_score()
        self.assertEqual(code, 0, text)
        self.assertIn("V1 allreduce-1pod4gpu vs allreduce-4pod1gpu at 256 MiB: first above", text)
        # One Pod's DDP step is longer in this fixture (scale 2 multiplies the step time), so V2 reads "first above".
        self.assertIn("V2 ddp-1pod4gpu vs ddp-4pod1gpu: first above", text)
        self.assertIn("transports allreduce-1pod4gpu: ['P2P']; allreduce-4pod1gpu: ['NET']", text)

    def test_overlap_is_not_distinguished(self):
        self.build(one_pod=1.0, four_pods=1.0)
        code, text = self.run_score()
        self.assertEqual(code, 0, text)
        self.assertIn("at 1 MiB: not distinguished", text)

    def test_one_invalid_job_withholds_the_arm(self):
        self.build()
        bad = next((self.root / "jobs").glob("*-allreduce-4pod1gpu-3"))
        (bad / "VOID").write_text("create refused")
        code, text = self.run_score()
        self.assertEqual(code, 1)
        self.assertIn("allreduce-4pod1gpu: no figure", text)
        self.assertIn("at 256 MiB: not scored", text)

    def test_a_missing_repetition(self):
        self.build()
        shutil.rmtree(next((self.root / "jobs").glob("*-ddp-1pod4gpu-5")))
        code, text = self.run_score()
        self.assertEqual(code, 1)
        self.assertIn("ddp-1pod4gpu: 4 registered job(s), want 5", text)

    def test_smoke_jobs_are_not_counted(self):
        self.build()
        code, text = self.run_score()
        self.assertEqual(code, 0, text)
        self.assertIn("(smoke, not counted)", text)
        # Five values, without the smoke job's 10.00, which a counted smoke would add as a sixth.
        self.assertIn("allreduce-1pod4gpu    1 MiB: 20.30 [20.10, 20.20, 20.30, 20.40, 20.50]", text)

    def test_one_execution_copied_into_five_repetitions_fails(self):
        # codex's case: a valid smoke job copied unchanged over each registered job of its arm read as five repetitions.
        self.build()
        smoke = self.root / "jobs" / "00-smoke-ddp-1pod4gpu"
        for rep in sorted((self.root / "jobs").glob("*-ddp-1pod4gpu-*")):
            shutil.rmtree(rep)
            shutil.copytree(smoke, rep)
        code, text = self.run_score()
        self.assertEqual(code, 1, text)
        self.assertIn("shares its run id c-00-smoke-ddp-1pod4gpu with 00-smoke-ddp-1pod4gpu", text)

    def test_an_invalid_smoke_job_fails_the_run(self):
        # The registration stops the run at the first invalid smoke job, so an archive holding one is not a pass,
        # whether or not the runner's STOPPED marker survived.
        self.build()
        (self.root / "jobs" / "00-smoke-allreduce-1pod4gpu" / "VOID").write_text("x")
        code, text = self.run_score()
        self.assertEqual(code, 1, text)
        self.assertIn("allreduce-1pod4gpu: 1 smoke job(s), 0 valid", text)

    def test_a_missing_smoke_job_fails_the_run(self):
        self.build()
        shutil.rmtree(self.root / "jobs" / "00-smoke-ddp-4pod1gpu")
        code, text = self.run_score()
        self.assertEqual(code, 1, text)
        self.assertIn("ddp-4pod1gpu: 0 smoke job(s)", text)

    def test_a_stopped_run_fails(self):
        self.build()
        (self.root / "STOPPED").write_text("smoke job nccltests-1pod4gpu is not valid")
        self.assertEqual(self.run_score()[0], 1)


class Bounds(unittest.TestCase):
    def test_the_registered_false_separation_bounds(self):
        # Either direction, under a random order and no arm effect: 2 / C(10, 5) per test.
        self.assertAlmostEqual(analyze.false_separation_bound(5, 1), 2 / 252)
        self.assertAlmostEqual(analyze.false_separation_bound(5, 5), 10 / 252)
        self.assertAlmostEqual(analyze.false_separation_bound(5, 2), 4 / 252)
        self.assertAlmostEqual(analyze.false_separation_bound(5, 7), 14 / 252)
        self.assertGreater(analyze.false_separation_bound(4, 5), 0.05)


if __name__ == "__main__":
    unittest.main()
