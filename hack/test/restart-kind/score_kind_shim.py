"""score_eks.py, unmodified, with its two GPU-boundary checks moved to the kind rehearsal's gloo ranks.

    python3 hack/test/restart-kind/score_kind_shim.py [--partial] <run directory>

hack/restart-lifecycle-kind.sh runs hack/lib/restart-session.sh on kind, where the ranks train with gloo on the CPU
(hack/lib/restart-kind-shims.sh renders CKPT_BACKEND=gloo), so two of score_eks.py's checks cannot pass by construction:
check_starts requires nccl on cuda, and check_transport requires NCCL logs naming NET/Socket channels.
Only those two are replaced here; every other check, and the output format restart_verdict reads, is score_eks.py's own.
The substitutes still refuse what the originals refuse on kind's side of the boundary:
  - check_starts: every start record must say gloo on cpu (anything else is VOID), and score_eks.py's own check then
    runs on the records with only those two fields mapped to what it requires, so its rank and world-size checks run.
  - check_transport: each attempt's each rank must have reached the runner's NCCL directory line, shown by the
    .a<attempt>-r<rank> marker the rendered command touches, and no NCCL log may exist, because gloo writes none.
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
_spec = importlib.util.spec_from_file_location("score_eks", ROOT / "experiments/distributed-restart/score_eks.py")
score_eks = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(score_eks)

_original_check_starts = score_eks.Case.check_starts


def check_starts(self, attempts: int) -> None:
    for r in self.records:
        if r.get("event") == "start" and (r.get("backend"), r.get("device")) != ("gloo", "cpu"):
            score_eks.void(f"kind: attempt {r.get('attempt')} rank {r.get('rank')} trained with {r.get('backend')!r} on "
                           f"{r.get('device')!r}, not the gloo on cpu the kind rehearsal renders")
    kept = self.records
    self.records = [dict(r, backend="nccl", device="cuda:0") if r.get("event") == "start" else r for r in kept]
    try:
        _original_check_starts(self, attempts)
    finally:
        self.records = kept


def check_transport(self, attempts: int) -> None:
    nccl = self.dir / "nccl"
    for a in range(1, attempts + 1):
        for rank in range(score_eks.WORLD):
            if not (nccl / f".a{a}-r{rank}").exists():
                score_eks.void(f"kind: no NCCL directory marker .a{a}-r{rank}, so attempt {a} rank {rank} is not shown "
                               f"to have reached the runner's NCCL setup")
            if nccl.is_dir() and list(nccl.glob(f"a{a}-r{rank}-*.log")):
                score_eks.void(f"kind: attempt {a} rank {rank} wrote an NCCL log, which gloo never does")


score_eks.Case.check_starts = check_starts
score_eks.Case.check_transport = check_transport

if __name__ == "__main__":
    sys.exit(score_eks.main(sys.argv))
