"""Hold GPU memory in a separate process so that only a chosen amount stays free.

This stands in for another tenant on a shared GPU: the measured vLLM process sees a
smaller device and fails with a real CUDA out-of-memory error when it needs more.
"""

import argparse
import sys
import time

import torch

GIB = 2**30


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--leave-free-gib", type=float, required=True)
    args = parser.parse_args()

    free, total = torch.cuda.mem_get_info()
    hold = free - int(args.leave_free_gib * GIB)
    if hold <= 0:
        sys.exit(f"cannot leave {args.leave_free_gib} GiB free: only {free / GIB:.3f} GiB is free")
    # Allocate in 256 MiB pieces so the request never exceeds a single free range.
    chunk = 256 * 2**20
    blocks = [torch.empty(chunk, dtype=torch.uint8, device="cuda") for _ in range(hold // chunk)]
    rest = hold - len(blocks) * chunk
    if rest:
        blocks.append(torch.empty(rest, dtype=torch.uint8, device="cuda"))
    torch.cuda.synchronize()
    free_after, _ = torch.cuda.mem_get_info()
    print(f"READY free_gib={free_after / GIB:.3f} total_gib={total / GIB:.3f}", flush=True)
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
