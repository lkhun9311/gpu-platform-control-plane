"""Tests for train.py's backend and device selection, run without torch and without a GPU.

torch is replaced by stub modules before train.py is imported, so these run wherever python3 does, including CI.
They pin the choice the script makes and the record it writes; they do not exercise NCCL or a device, and the
first execution of that path is the paid run, which must treat it as untested code.
"""

from __future__ import annotations

import importlib
import json
import os
import signal
import sys
import tempfile
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


def load_train(cuda: FakeCuda):
    """Import train.py against stub torch modules whose cuda is the given fake."""
    torch = types.ModuleType("torch")
    torch.cuda = cuda
    torch.version = types.SimpleNamespace(cuda="12.4")
    torch.__version__ = "2.5.1-stub"
    torch.manual_seed = lambda seed: None
    torch.set_num_threads = lambda n: None
    torch.zeros = lambda *shape, device=None, **kw: types.SimpleNamespace(
        device=types.SimpleNamespace(type=str(device).split(":")[0]))
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


def run_main(backend: str | None, cuda: FakeCuda):
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
            train, dist = load_train(cuda)
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

    def test_a_refused_device_stops_before_rendezvous(self):
        code, records, calls = run_main("nccl", FakeCuda(available=False))
        self.assertEqual(code, 1)
        # Refused before init_process_group: a rank that cannot run must not hold its peer at the rendezvous.
        self.assertEqual(calls, [])
        refused = [r for r in records if r["event"] == "device_refused"]
        self.assertEqual(len(refused), 1)
        self.assertIn("CUDA is not available", refused[0]["error"])


if __name__ == "__main__":
    unittest.main()
