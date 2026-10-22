"""Tests for train.py's backend and device selection, run without torch and without a GPU.

torch is replaced by stub modules before train.py is imported, so these run wherever python3 does, including CI.
They pin the choice the script makes and the record it writes; they do not exercise NCCL or a device, and the
first execution of that path is the paid run, which must treat it as untested code.
"""

from __future__ import annotations

import ctypes
import importlib
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent


class FakeCuda:
    """torch.cuda as the selection reads it, recording every call so a test can say what was touched."""

    def __init__(self, available: bool) -> None:
        self.available = available
        self.calls: list[str] = []
        self.nccl = types.SimpleNamespace(version=lambda: (2, 21, 5))

    def is_available(self) -> bool:
        self.calls.append("is_available")
        return self.available

    def set_device(self, index: int) -> None:
        self.calls.append(f"set_device({index})")

    def get_device_name(self, index: int) -> str:
        self.calls.append(f"get_device_name({index})")
        return "NVIDIA A10G"

    def get_device_properties(self, index: int):
        self.calls.append(f"get_device_properties({index})")
        return types.SimpleNamespace(uuid=uuid.UUID("12345678-1234-5678-1234-567812345678"))


class Stop(Exception):
    """Raised by the stub init_process_group, so main() stops at rendezvous after the backend is recorded."""


def load_train(cuda: FakeCuda, allocated_on: str | None = None):
    """Import train.py against stub torch modules whose cuda is the given fake.

    A tensor lands on the device it names unless allocated_on says otherwise, which is how a test shows the
    record reads the tensor and not the name.
    """
    torch = types.ModuleType("torch")
    torch.cuda = cuda
    torch.version = types.SimpleNamespace(cuda="12.4")
    torch.__version__ = "2.5.1-stub"
    torch.manual_seed = lambda seed: None
    torch.set_num_threads = lambda n: None
    torch.zeros = lambda *shape, device=None, **kw: types.SimpleNamespace(
        device=types.SimpleNamespace(type=allocated_on or str(device).split(":")[0]))
    dist = types.ModuleType("torch.distributed")
    dist.init_calls = []

    def init_process_group(backend, **kwargs):
        dist.init_calls.append(backend)
        raise Stop("stub rendezvous")

    dist.init_process_group = init_process_group
    nn = types.ModuleType("torch.nn")
    nn.Module = object
    parallel = types.ModuleType("torch.nn.parallel")
    parallel.DistributedDataParallel = object
    torch.distributed, torch.nn, nn.parallel = dist, nn, parallel
    for name, module in {"torch": torch, "torch.distributed": dist, "torch.nn": nn,
                         "torch.nn.parallel": parallel}.items():
        sys.modules[name] = module
    sys.path.insert(0, str(HERE))
    try:
        sys.modules.pop("train", None)
        return importlib.import_module("train"), dist
    finally:
        sys.path.remove(str(HERE))


def run_main(backend: str | None, cuda: FakeCuda, allocated_on: str | None = None):
    """Run main() as rank 0 of 2 and return its exit code, its records and the backends rendezvous was asked for."""
    with tempfile.TemporaryDirectory() as out:
        env = {"RANK": "0", "WORLD_SIZE": "2", "DDP_OUT_DIR": out}
        if backend is not None:
            env["DDP_BACKEND"] = backend
        saved = {k: os.environ.get(k) for k in [*env, "DDP_BACKEND"]}
        os.environ.pop("DDP_BACKEND", None)
        os.environ.update(env)
        # main() also writes each record to fd 1; send it to a file so the test output stays readable.
        devnull = os.open(os.devnull, os.O_WRONLY)
        stdout = os.dup(1)
        # main() installs its own SIGTERM handler, which must not outlive the test in the runner's process.
        sigterm = signal.getsignal(signal.SIGTERM)
        try:
            train, dist = load_train(cuda, allocated_on)
            os.dup2(devnull, 1)
            code = train.main()
        finally:
            signal.signal(signal.SIGTERM, sigterm)
            os.dup2(stdout, 1)
            os.close(devnull)
            os.close(stdout)
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        records = [json.loads(line) for line in Path(out, "rank-0.jsonl").read_text().splitlines()]
        return code, records, dist.init_calls


class SelectDevice(unittest.TestCase):
    def test_gloo_is_cpu_and_does_not_touch_cuda(self):
        cuda = FakeCuda(available=True)
        train, _ = load_train(cuda)
        device, fields = train.select_device("gloo", cuda, "12.4")
        self.assertEqual(device, "cpu")
        self.assertEqual(fields, {"device_type": "cpu"})
        # A CPU arm on a GPU node must not claim or initialise the card.
        self.assertEqual(cuda.calls, [])

    def test_nccl_without_cuda_is_refused_by_name(self):
        cuda = FakeCuda(available=False)
        train, _ = load_train(cuda)
        with self.assertRaises(train.DeviceRefused) as ctx:
            train.select_device("nccl", cuda, None)
        self.assertIn("DDP_BACKEND=nccl", str(ctx.exception))
        self.assertIn("CUDA is not available", str(ctx.exception))

    def test_nccl_with_cuda_uses_device_zero_and_records_it(self):
        cuda = FakeCuda(available=True)
        train, _ = load_train(cuda)
        device, fields = train.select_device("nccl", cuda, "12.4")
        self.assertEqual(device, "cuda:0")
        self.assertIn("set_device(0)", cuda.calls)
        self.assertEqual(fields, {
            "device_type": "cuda",
            "device_name": "NVIDIA A10G",
            "gpu_uuid": "12345678-1234-5678-1234-567812345678",
            "cuda_version": "12.4",
            "nccl_version": "2.21.5",
        })

    def test_an_unknown_backend_is_refused_not_defaulted(self):
        cuda = FakeCuda(available=True)
        train, _ = load_train(cuda)
        with self.assertRaises(train.DeviceRefused) as ctx:
            train.select_device("NCCL", cuda, "12.4")
        self.assertIn("'NCCL'", str(ctx.exception))


class Main(unittest.TestCase):
    def test_unset_backend_rendezvous_with_gloo(self):
        code, records, calls = run_main(None, FakeCuda(available=True))
        self.assertEqual(calls, ["gloo"])
        start = [r for r in records if r["event"] == "rendezvous_start"][0]
        self.assertEqual(start["backend_requested"], "gloo")
        self.assertEqual(start["device_type"], "cpu")
        self.assertEqual(code, 1)  # the stub rendezvous fails, and the rank says so

    def test_nccl_rendezvous_with_nccl_and_records_the_device(self):
        code, records, calls = run_main("nccl", FakeCuda(available=True))
        self.assertEqual(calls, ["nccl"])
        start = [r for r in records if r["event"] == "rendezvous_start"][0]
        self.assertEqual(start["backend_requested"], "nccl")
        self.assertEqual(start["device_type"], "cuda")
        self.assertEqual(start["tensor_device_type"], "cuda")
        self.assertEqual(start["gpu_uuid"], "12345678-1234-5678-1234-567812345678")

    def test_the_tensor_device_is_read_off_a_tensor_not_the_name(self):
        # If an allocation ever landed elsewhere than it was asked, the record must say where it landed.
        _, records, _ = run_main("nccl", FakeCuda(available=True), allocated_on="cpu")
        start = [r for r in records if r["event"] == "rendezvous_start"][0]
        self.assertEqual(start["device_type"], "cuda")
        self.assertEqual(start["tensor_device_type"], "cpu")

    def test_a_refused_device_stops_before_rendezvous(self):
        code, records, calls = run_main("nccl", FakeCuda(available=False))
        self.assertEqual(code, 1)
        # Refused before init_process_group: a rank that cannot run must not hold its peer at the rendezvous.
        self.assertEqual(calls, [])
        refused = [r for r in records if r["event"] == "device_refused"]
        self.assertEqual(len(refused), 1)
        self.assertIn("CUDA is not available", refused[0]["error"])


def sigterm_child(out_dir: str) -> None:
    """Run main() as rank 0 with a rendezvous that blocks the way torch's native wait does, for SigtermDuringRendezvous.

    The stub blocks SIGTERM in the thread that calls it and then sleeps.
    That models what the kind run measured: the thread waiting inside init_process_group does not return to the
    interpreter, so it cannot run the Python handler, and whatever runs it has to be another thread.
    A plain sleep without the mask would not model it, because CPython interrupts a sleeping main thread for a
    signal and runs the handler at once, which would let the defect pass.
    """
    os.environ.update({"RANK": "0", "WORLD_SIZE": "2", "DDP_OUT_DIR": out_dir})
    os.environ.pop("DDP_BACKEND", None)
    train, dist = load_train(FakeCuda(available=False))

    def blocking_init(backend, **kwargs):
        signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM})
        Path(out_dir, "entered").write_text(backend)
        time.sleep(60)
        raise Stop("the stub rendezvous ran to its end without the process being stopped")

    dist.init_process_group = blocking_init

    # A thread that leaves SIGTERM unblocked, as the threads torch starts do, so a signal can be aimed at a
    # thread other than the main one.
    def bystander() -> None:
        while True:
            time.sleep(1)

    thread = threading.Thread(target=bystander, daemon=True)
    thread.start()
    Path(out_dir, "bystander").write_text(str(thread.native_id))
    os.dup2(os.open(os.devnull, os.O_WRONLY), 1)
    sys.exit(train.main())


class SigtermDuringRendezvous(unittest.TestCase):
    """An evicted rank still waiting for its peer must act on SIGTERM well inside the kubelet's 30 s grace period.

    On kind it did not: in all ten evictions of the partial-placement study the rank was blocked in
    init_process_group, its handler never ran, and the kubelet killed it with exit 137 at the grace period,
    28.9 s after Kueue had already counted its device free (Finding 10 in docs/11_WHAT_THIS_MEASURED.md).
    """

    DEADLINE_SECONDS = 5.0

    def run_child(self, aim: str) -> tuple[int, list[dict]]:
        with tempfile.TemporaryDirectory() as out:
            child = subprocess.Popen(
                [sys.executable, str(Path(__file__).resolve()), "--sigterm-child", out],
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            try:
                entered = Path(out, "entered")
                waited = time.monotonic() + 30
                while not entered.exists():
                    if child.poll() is not None:
                        self.fail(f"the child exited {child.returncode} before rendezvous: {child.stderr.read()!r}")
                    if time.monotonic() > waited:
                        self.fail("the child never reached the stub rendezvous")
                    time.sleep(0.05)
                if aim == "process":
                    os.kill(child.pid, signal.SIGTERM)
                else:
                    libc = ctypes.CDLL(None, use_errno=True)
                    if not hasattr(libc, "tgkill"):
                        self.skipTest("this libc has no tgkill, so a signal cannot be aimed at one thread")
                    tid = int(Path(out, "bystander").read_text())
                    if libc.tgkill(child.pid, tid, signal.SIGTERM) != 0:
                        self.fail(f"tgkill failed with errno {ctypes.get_errno()}")
                try:
                    code = child.wait(timeout=self.DEADLINE_SECONDS)
                except subprocess.TimeoutExpired:
                    self.fail(f"the rank was still running {self.DEADLINE_SECONDS} s after SIGTERM "
                              f"(aimed at the {aim}) while blocked in rendezvous")
                path = Path(out, "rank-0.jsonl")
                records = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
                return code, records
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait()
                child.stderr.close()

    def assert_stopped_by_its_handler(self, code: int, records: list[dict]) -> None:
        events = [r["event"] for r in records]
        self.assertEqual(code, 143, f"exit {code}, events {events}")
        self.assertIn("sigterm", events)
        # The rank stopped inside rendezvous, so it must not claim to have finished it or to have failed in it.
        self.assertNotIn("rendezvous", events)
        self.assertNotIn("rendezvous_failed", events)

    def test_a_signal_sent_to_the_process_stops_it(self):
        code, records = self.run_child("process")
        self.assert_stopped_by_its_handler(code, records)

    def test_a_signal_taken_by_another_thread_still_stops_it(self):
        # The kernel may hand a process-directed signal to any thread that does not block it, torch's included.
        # Then nothing interrupts the main thread's wait, and only a wait that wakes by itself lets the handler run.
        code, records = self.run_child("bystander")
        self.assert_stopped_by_its_handler(code, records)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--sigterm-child":
        sigterm_child(sys.argv[2])
    unittest.main()
