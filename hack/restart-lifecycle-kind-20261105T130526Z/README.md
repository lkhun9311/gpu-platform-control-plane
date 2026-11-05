# Kind rehearsal of the `retarget` restart stage, 2026-11-05 (commit 78f5b4ba)

This was the sixth rehearsal of `docs/superpowers/specs/2026-11-04-restart-retarget-design.md`, and no longer meets its gate: moving every deadline to the monotonic clock (`f0a07fa5`) changed its runner, and `hack/restart-lifecycle-kind-20261105T141937Z` replaces it.
It replaces `hack/restart-lifecycle-kind-20261105T054801Z`, whose runner the phase supervisor (`docs/superpowers/specs/2026-11-05-paid-phase-supervisor-design.md`) and the scorer's evidence gates changed.
A rehearsal at `7e9ac2a5` between the two also gave every case ACCEPTED and both checks 0 FAIL; the supervisor's fixes after gpt-6-astra's GO review changed its runner, and it is not kept.
The driver, the substitutions and what ran unmodified are as in `hack/restart-lifecycle-kind-20261101T143009Z/README.md`; only run `e` ran here.

The run is from commit `78f5b4ba` on `feat/restart-targeted-stage` with a clean tree (`provenance.txt`, `run-e/provenance.txt`).
It ran that commit's `restart_run` with every step between and within the cases as a paid phase: the GPU deadline's check, the group wait and warm-up, each case within its slot, and each verdict, each in a cgroup killed whole at its deadline.
The driver entered the supervisor itself (`phase_supervisor_enter`), started from a plain shell.
The launcher's own steps before the first case (T6, Z2, T7, R5, R6) are not part of a kind run; `hack/test/check-restart-session.sh` and `hack/test/check-phase-supervisor.sh` pin them.
The trainer's sha256 is `2c5cdbf09fdb4c8149443a806396fdf73f7176ea1adb174f5fe8052cb53f572c`, the one the paid session approves.

## What it showed

- Every case ACCEPTED by `score_eks.py`'s checks through `hack/test/restart-kind/score_kind_shim.py` (`run-e/verdict.txt`), with the scorer of that commit, which requires every save of a completed attempt and each node of attempt 2 probed after its first step.
- `lifecycle-check.txt` and `outcomes-check.txt`: 0 FAIL each, and both replay from this directory with the timelines compressed.
- The unmodified `score_eks.py` voids every case, because the ranks trained with gloo on the CPU (`run-e/verdict-unmodified-scorer.txt`); that is the boundary the shim moves, not a defect.
- H1 through `hack/test/restart-kind/h1_kind_shim.py run-e`: `d` = 1, 0, 1, 1 s for `rank-kill-1`, `rank-kill-2`, `dcgm-1`, `dcgm-2`, each inside the collector's bracket, which is SUPPORTED on kind.

Kind figures are not EKS figures.
The pod deletion here is a container on one host, the network is a bridge, and the GPU is simulated; nothing here predicts the paid `d` or the paid recovery.
On kind every step ends well inside its deadline, so no phase here was killed; the kill is pinned by the tests named above.

The status timelines are committed compressed (`timeline.jsonl.xz`).
The two Kueue manifest dumps (`kueue.yaml`, `kueue-without-flavor.yaml`, 1.7 MB each) are left out, as in the earlier rehearsals.
