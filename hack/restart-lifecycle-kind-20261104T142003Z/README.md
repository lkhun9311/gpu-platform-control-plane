# Kind rehearsal of the `retarget` restart stage, 2026-11-04 (commit 5f83e8e2)

This is the free rehearsal that `docs/superpowers/specs/2026-11-04-restart-retarget-design.md` requires before its paid session.
The driver, the substitutions and what ran unmodified are as in `hack/restart-lifecycle-kind-20261101T143009Z/README.md`; only run `e` ran here.
Run `e` is `restart_run` with `RESTART_STAGE=retarget`: `reference`, `no-rng-control`, `rank-kill-1`, `rank-kill-2`, `dcgm-1`, `dcgm-2`.

The run is from commit `5f83e8e2` on `feat/restart-targeted-stage` with a clean tree (`provenance.txt`, `run-e/provenance.txt`).
The trainer's sha256 is `2c5cdbf09fdb4c8149443a806396fdf73f7176ea1adb174f5fe8052cb53f572c`, the one the paid session approves.
The launch commit adds `experiments/distributed-restart/h1_retarget.py` and its kind shim, and changes no runner, scorer or trainer line.

## What it showed

- Every case ACCEPTED by `score_eks.py`'s checks through `hack/test/restart-kind/score_kind_shim.py` (`run-e/verdict.txt`).
- `lifecycle-check.txt` and `outcomes-check.txt`: 0 FAIL each.
- The unmodified `score_eks.py` voids every case, because the ranks trained with gloo on the CPU (`run-e/verdict-unmodified-scorer.txt`); that is the boundary the shim moves, not a defect.
- H1, evaluated after the paid registration's bars were written (`hack/test/restart-kind/h1_kind_shim.py run-e`): `d` = 1, 0, 1, 1 s for `rank-kill-1`, `rank-kill-2`, `dcgm-1`, `dcgm-2`, each inside the collector's bracket, which is SUPPORTED on kind.

Kind figures are not EKS figures.
The pod deletion here is a container on one host, the network is a bridge, and the GPU is simulated; nothing here predicts the paid `d` or the paid recovery.

The status timelines are committed compressed (`timeline.jsonl.xz`), which `score_eks.py` and `h1_retarget.py` read directly.
The two Kueue manifest dumps (`kueue.yaml`, `kueue-without-flavor.yaml`, 1.7 MB each) are left out, as in the earlier rehearsal; they are the rendered upstream install.
