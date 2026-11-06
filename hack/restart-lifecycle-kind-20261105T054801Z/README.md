# Kind rehearsal of the `retarget` restart stage, 2026-11-05 (commit 1729ad8a)

This was the fifth rehearsal of `docs/superpowers/specs/2026-11-04-restart-retarget-design.md`, and no longer meets its gate: the phase supervisor and the scorer's evidence gates changed the runner and scorer after it, and `hack/restart-lifecycle-kind-20261105T130526Z` replaces it.
Its line below that nothing changed before the launch commit was true when written and is not now.
It replaces `hack/restart-lifecycle-kind-20261105T044327Z`, whose runner the fifth attack's fixes changed.
The driver, the substitutions and what ran unmodified are as in `hack/restart-lifecycle-kind-20261101T143009Z/README.md`; only run `e` ran here.

The run is from commit `1729ad8a` on `feat/restart-targeted-stage` with a clean tree (`provenance.txt`, `run-e/provenance.txt`).
It ran that commit's `restart_run`: the qualification between cases with the deadline-cut kubectl, the probe before a fault under its case's deadline, and that commit's scorer and H1 evaluator.
The launcher's own first qualification (T6, T7) is not part of a kind run; `hack/test/check-restart-session.sh` pins its deadline-cut kubectl instead.
The trainer's sha256 is `2c5cdbf09fdb4c8149443a806396fdf73f7176ea1adb174f5fe8052cb53f572c`, the one the paid session approves.
No runner, scorer, trainer or `h1_retarget.py` line changed between this commit and the launch commit.

## What it showed

- Every case ACCEPTED by `score_eks.py`'s checks through `hack/test/restart-kind/score_kind_shim.py` (`run-e/verdict.txt`).
- `lifecycle-check.txt` and `outcomes-check.txt`: 0 FAIL each, and both replay from this directory with the timelines compressed.
- The unmodified `score_eks.py` voids every case, because the ranks trained with gloo on the CPU (`run-e/verdict-unmodified-scorer.txt`); that is the boundary the shim moves, not a defect.
- H1 through `hack/test/restart-kind/h1_kind_shim.py run-e`: `d` = 0, 1, 1, 1 s for `rank-kill-1`, `rank-kill-2`, `dcgm-1`, `dcgm-2`, each inside the collector's bracket, which is SUPPORTED on kind.

Kind figures are not EKS figures.
The pod deletion here is a container on one host, the network is a bridge, and the GPU is simulated; nothing here predicts the paid `d` or the paid recovery.
On kind every wait ends in seconds, so this rehearsal cannot show that a wait longer than 20 s is not cut; `hack/test/check-restart-session.sh` pins that instead.

The status timelines are committed compressed (`timeline.jsonl.xz`).
The two Kueue manifest dumps (`kueue.yaml`, `kueue-without-flavor.yaml`, 1.7 MB each) are left out, as in the earlier rehearsals.
