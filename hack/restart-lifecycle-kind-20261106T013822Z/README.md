# Kind rehearsal of the `corelimit` restart stage, 2026-11-06 (commit 8aa8f43d)

The rehearsal `docs/superpowers/specs/2026-11-06-restart-corelimit-design.md` requires before its paid run.
The driver, the substitutions and what ran unmodified are as in `hack/restart-lifecycle-kind-20261101T143009Z/README.md`; only run `f` ran here, `RESTART_STAGE=corelimit` as registered.

The run is from commit `8aa8f43d` on `feat/restart-corelimit` with a clean tree (`provenance.txt`).
The commits after it to the launch commit change the H2 evaluator, the outcome checker and tests, not the runner.
The trainer's sha256 is `2c5cdbf09fdb4c8149443a806396fdf73f7176ea1adb174f5fe8052cb53f572c`, the one the paid session approves.

## What it showed

- Every case ACCEPTED by `score_eks.py`'s checks through `hack/test/restart-kind/score_kind_shim.py` (`run-f/verdict.txt`); its summary gives the two `rank-kill` arms apart.
- `lifecycle-check.txt`: 0 FAIL, and it replays from this directory with the timelines compressed.
- `outcomes-check.txt` ends `FAIL run 'f' has no expected outcome`: the checker at `8aa8f43d` did not know run `f`, as the bare review of `8e2eb73f` and `8aa8f43d` predicted.
  `outcomes-check-replayed.txt` is the same check with run `f` registered (`hack/test/restart-kind/check_outcomes.py` after it), run on this directory: every case ACCEPTED as expected, 0 FAIL.
- Every attempt's rank logged its environment before the trainer, the arm's limit and this host's `core_pattern`: 12 lines `core_limit=0`, from the even `rank-kill` cases, and 12 `core_limit=unlimited`, all with `core_pattern=core`.
- The collector's stream records carry the container's end: the faulted rank `terminated 137`, the surviving gloo rank `terminated 1` (`Error`), the completed ranks `0` (`Completed`).
- `rank-kill-1`'s lost steps are withheld: its rank 0's log streams ended twice while the container ran, and the third follow found the Pod gone (exit 1), so the end of its log is not shown read.
  That is the rule #506 added doing what it was registered to do, on a cluster.
- `h2-kind-shim.txt`, H2 through `hack/test/restart-kind/h2_kind_shim.py`: every arm read and accepted, `d` 0 to 1 s in both arms, so **INCONCLUSIVE**: the slow stop does not recur on kind, as the registration says it cannot.

Kind figures are not EKS figures.
Kind cannot show a core dump's cost: the ranks run on CPU with gloo, which raises an error on a peer's death rather than aborting, and this host's `ulimit -c` is 0 with `core_pattern` writing a file.
What this run shows is that the arms are applied in the rank's own shell, logged, recorded in `case.json`, read by the evaluator, and reported apart; nothing here predicts the paid `d`.
`finished_after_fault_s` is negative by up to 0.7 s here, because a container's `finishedAt` is a whole-second stamp and the fault's time is not.

The status timelines are committed compressed (`timeline.jsonl.xz`).
The two Kueue manifest dumps (`kueue.yaml`, `kueue-without-flavor.yaml`, 1.7 MB each), the stub state, `train-a-at-end.txt` and `volume.yaml` are left out, as in the earlier rehearsals.
