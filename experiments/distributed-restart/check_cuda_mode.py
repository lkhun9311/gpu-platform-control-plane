"""Checks, on CPU, what train.py's NCCL mode and ballast change, without touching check_protocol.py.

The NCCL mode itself needs a GPU, and nothing here has one, so it cannot be run; what can be shown on CPU is that it
refuses rather than falls back, that an unknown backend is refused, that the records the paid session's scorer reads
are there, and that the ballast the session adds to every shard leaves the resumed training exactly as it was.

    python3 experiments/distributed-restart/check_cuda_mode.py [IMAGE]

It runs train.py under torchrun in the CPU image, with check_protocol.py's helpers, so the two checks start ranks the
same way.
"""

from __future__ import annotations

import shutil
import sys

import check_protocol as cp


def main() -> int:
    # A CPU image has no CUDA: the nccl mode must refuse before any process group, on every rank, and train nothing.
    state = cp.fresh()
    try:
        code, records = cp.attempt(state, 1, CKPT_BACKEND="nccl")
        refused = sorted(r["rank"] for r in records if r["event"] == "refused")
        trained = [r for r in records if r["event"] in ("start", "step")]
        cp.expect("nccl without CUDA refuses", code != 0 and refused == [0, 1] and not trained,
                  f"exit {code}, refusals from ranks {refused}, {len(trained)} start or step records")
        cp.expect("nccl without CUDA writes nothing", not (state / "uid-test").exists(),
                  "no checkpoint directory was created")
    finally:
        shutil.rmtree(state, ignore_errors=True)

    # A backend nobody registered, such as a typo of nccl, must not run as gloo.
    state = cp.fresh()
    try:
        code, records = cp.attempt(state, 1, CKPT_BACKEND="nccI")
        cp.expect("unknown backend refuses", code != 0 and not records, f"exit {code}, {len(records)} records")
    finally:
        shutil.rmtree(state, ignore_errors=True)

    state = cp.fresh()
    try:
        code, records = cp.attempt(state, 1, CKPT_BALLAST_MB="-1")
        cp.expect("negative ballast refuses", code != 0 and not records, f"exit {code}, {len(records)} records")
    finally:
        shutil.rmtree(state, ignore_errors=True)

    # The default is unchanged gloo on the CPU, and says so in the record the paid session's scorer reads.
    state = cp.fresh()
    try:
        code, records = cp.attempt(state, 1)
        reference = cp.final(records)
        starts = [(r["backend"], r["device"], r["ballast_mb"]) for r in records if r["event"] == "start"]
        cp.expect("default is gloo on cpu", code == 0 and starts == [("gloo", "cpu", 0)] * 2, f"exit {code}, start {starts}")
        costs = [r.get("save_s") for r in records if r["event"] == "checkpoint"]
        cp.expect("every checkpoint carries its cost",
                  len(costs) == 2 * cp.STEPS and all(isinstance(c, float) and c >= 0 for c in costs),
                  f"{len(costs)} checkpoint records, want {2 * cp.STEPS}, all with a non-negative save_s")
    finally:
        shutil.rmtree(state, ignore_errors=True)
    if reference is None:
        print("no reference parameters; nothing to compare the ballast run with")
        return 1

    # One MiB of ballast in every shard: the shard grows by it and the resumed run still ends on the reference.
    state = cp.fresh()
    try:
        code, first = cp.attempt(state, 1, CKPT_FAULT="kill-after-latest:6", CKPT_BALLAST_MB="1")
        cp.expect("ballast fault fired", code != 0 and len(cp.events(first, "fault")) == 1, f"exit {code}")
        latest = (state / "uid-test" / "LATEST").read_text().strip()
        sizes = sorted((state / "uid-test" / latest / f"rank-{r}.pt").stat().st_size for r in (0, 1))
        cp.expect("ballast in every shard", sizes[0] >= 1 << 20, f"shard sizes {sizes} bytes, want each at least 1 MiB")
        code, second = cp.attempt(state, 2, CKPT_BALLAST_MB="1")
        resume = cp.events(second, "resume")
        got_from = resume[0]["from_step"] if resume else None
        cp.expect("ballast resume point", code == 0 and got_from == 6, f"exit {code}, resumed from {got_from}, want 6")
        cp.expect("ballast same training", cp.final(second) == reference, "final parameters compared with the reference")
    finally:
        shutil.rmtree(state, ignore_errors=True)

    print(f"{len(cp.FAILURES)} failed" if cp.FAILURES else "all cases passed")
    return 1 if cp.FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
