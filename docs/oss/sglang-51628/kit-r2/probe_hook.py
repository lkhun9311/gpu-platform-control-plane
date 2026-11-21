#!/usr/bin/env python3
"""The positive control for the compile record: two fresh kernels on this GPU, in this image, must each leave one record.

A run whose compile record shows nothing after ready can mean that nothing compiled, or that the hook never fired.
This script tells the two apart before any server starts.
Kernel A compiles with only the hook installed.
Kernel B compiles after SGLang's own watch is installed on top of it, as the scheduler installs it, so the chain is shown to keep the hook.
With SGLANG_TRITON_SLOW_COMPILE_THRESHOLD_SECS=0 here (and only here), SGLang's watch must also log kernel B, which measure.sh checks.

  probe_hook.py <compile log>

Exit 0 when both kernels left a record that is not a cache hit, and 3 otherwise.
"""

import json
import logging
import os
import sys

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")

import torch  # noqa: E402
import triton  # noqa: E402
import triton.language as tl  # noqa: E402

log = sys.argv[1]


@triton.jit
def _sgl51628_probe_a(x_ptr, n, BLOCK: tl.constexpr):
    offs = tl.program_id(0) * BLOCK + tl.arange(0, BLOCK)
    m = offs < n
    tl.store(x_ptr + offs, tl.load(x_ptr + offs, mask=m) + 1, mask=m)


@triton.jit
def _sgl51628_probe_b(x_ptr, n, BLOCK: tl.constexpr):
    offs = tl.program_id(0) * BLOCK + tl.arange(0, BLOCK)
    m = offs < n
    tl.store(x_ptr + offs, tl.load(x_ptr + offs, mask=m) + 2, mask=m)


x = torch.zeros(1024, device="cuda")
_sgl51628_probe_a[(4,)](x, 1024, BLOCK=256)
torch.cuda.synchronize()

from sglang.srt.utils import triton_load_watch as w  # noqa: E402

w.install()
print(f"sglang_watch_installed={w._installed}", flush=True)
w.mark_serving_started()
_sgl51628_probe_b[(4,)](x, 1024, BLOCK=256)
torch.cuda.synchronize()
print(f"probe sum={float(x.sum())}", flush=True)

pid = os.getpid()
records = []
try:
    with open(log) as f:
        records = [json.loads(line) for line in f if line.strip()]
except (OSError, ValueError) as exc:
    print(f"probe: the compile log could not be read: {exc}", flush=True)
mine = [r for r in records if r.get("pid") == pid]
installed = any(r.get("event") == "install" and r.get("installed") is True for r in mine)
fresh = {r.get("name") for r in mine if r.get("event") == "compile" and r.get("cache_hit") is False}
ok = installed and "_sgl51628_probe_a" in fresh and "_sgl51628_probe_b" in fresh and w._installed
print(f"probe_hook_installed={installed}", flush=True)
print(f"probe_a_recorded={'_sgl51628_probe_a' in fresh}", flush=True)
print(f"probe_b_recorded={'_sgl51628_probe_b' in fresh}", flush=True)
print(f"probe_hook={'ok' if ok else 'bad'}", flush=True)
sys.exit(0 if ok else 3)
