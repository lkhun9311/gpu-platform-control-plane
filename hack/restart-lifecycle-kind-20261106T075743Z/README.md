# Kind rehearsal of the `corelimit` launch runner, 2026-11-06 (commit 17c56105)

The rehearsal `docs/superpowers/specs/2026-11-06-restart-corelimit-design.md` requires of the runner the paid session launches with, after three rounds of pre-launch review changed it ("Revisions before the run").
The driver, the substitutions and what ran unmodified are as in `hack/restart-lifecycle-kind-20261101T143009Z/README.md`; only run `f` ran here, `RESTART_STAGE=corelimit` as registered.
The earlier rehearsals of this stage are `hack/restart-lifecycle-kind-20261106T013822Z` (`8aa8f43d`) and `hack/restart-lifecycle-kind-20261106T071657Z` (`cb98ae98`); one more, at `377bd054`, passed every check and was not kept, its runner having changed again before it could be the launch runner.

The run is from commit `17c56105` on `fix/corelimit-prelaunch` with a clean tree (`provenance.txt`).
The commits after it to the launch commit change tests and records, not the runner, `hack/eks-gitops-session.sh` or the evaluators.
The trainer's sha256 is `2c5cdbf09fdb4c8149443a806396fdf73f7176ea1adb174f5fe8052cb53f572c`, the one the paid session approves.

## What it showed

- Every case ACCEPTED by `score_eks.py`'s checks through `hack/test/restart-kind/score_kind_shim.py` (`run-f/verdict.txt`), with the two `rank-kill` arms summarised apart.
  `run-f/verdict-unmodified-scorer.txt` exits 1 with every case VOID, as in every kind rehearsal: the unmodified scorer voids gloo ranks.
- `lifecycle-check.txt` and `outcomes-check.txt`: 0 FAIL each, and both replay from this directory with the timelines and Pod watches compressed.
- Every attempt-1 rank of every `rank-kill` case logged its arm's limit before the trainer: `0` in cases 2, 4 and 6, `unlimited` in 1, 3 and 5, with this host's `core_pattern=core` (`h2-kind-shim.txt`).
- Each case's Pod watch (`pod-watch.json.xz`) carries one `WATCH-OPENED` mark: no watch was reopened during a case.
- How each `rank-kill` case's surviving rank ended, and when its deletion was asked for, is read in all six: `terminated`, exit 1 (gloo raises on the peer's death), grace 0 s because the Pod had finished before its deletion.
- `rank-kill-4` repeated the race the first review found: its survivor's stream records end `running`, `running`, `gone`, with no exit code, and `h2_corelimit.py` read the end from the Pod watch instead (`"read_from": "pod watch"`).
  That is the fix doing on a cluster what it was added for.
- H2 through `hack/test/restart-kind/h2_kind_shim.py`: every arm read and accepted, `d` 0 to 1 s in both arms, so **INCONCLUSIVE**: the slow stop does not recur on kind, as the registration says it cannot.

Kind figures are not EKS figures.
Kind cannot show a core dump's cost: the ranks run on CPU with gloo, which raises an error on a peer's death rather than aborting, and this host's `ulimit -c` is 0 with `core_pattern` writing a file.
`finished_after_fault_s` is within a second of 0 either side here, because a container's `finishedAt` is a whole-second stamp and the fault's time is not.

The status timelines and the Pod watches are committed compressed (`timeline.jsonl.xz`, `pod-watch.json.xz`); `h2-kind-shim.txt` from the compressed files is identical to its output before compression.
The two Kueue manifest dumps, the stub state, `train-a-at-end.txt` and `volume.yaml` are left out, as in the earlier rehearsals.
