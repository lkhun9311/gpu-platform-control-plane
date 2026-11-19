#!/usr/bin/env python3
"""Runs the reporter's kernel_repro.py, unchanged, with CUDA as torch's default device.

    run_repro.py <kernel_repro.py> <its pinned sha256>

The script builds its tensors without .cuda(), and the Triton kernels it calls need CUDA tensors.
hack/vllm-gdn-68414/state.sh runs it this way only when a plain `python3 kernel_repro.py` printed no result.
It checks the file's sha256 first, so the text executed is the pinned one byte for byte.
It then prints the file this process imported prepare_chunk_indices from, because the result speaks for that file.
"""
import hashlib
import runpy
import sys

import torch

INDEX = "vllm.third_party.flash_linear_attention.ops.index"


def main(path, want_sha):
    with open(path, "rb") as f:
        have_sha = hashlib.sha256(f.read()).hexdigest()
    if have_sha != want_sha:
        print(f"REPRO_SHA_MISMATCH {have_sha}", flush=True)
        return 3
    print(f"REPRO_SHA256={have_sha}", flush=True)
    torch.set_default_device("cuda")
    # run_path executes the file as __main__ without editing it, as `python3 kernel_repro.py` would.
    runpy.run_path(path, run_name="__main__")
    mod = sys.modules.get(INDEX)
    print(f"REPRO_INDEX_FILE={getattr(mod, '__file__', None) or 'not-imported'}", flush=True)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
