# Kind rehearsal of the `corelimit` restart stage after the pre-launch fixes, 2026-11-06 (commit cb98ae98)

The rehearsal `docs/superpowers/specs/2026-11-06-restart-corelimit-design.md` requires again after its runner changed ("Revisions before the run").
The driver, the substitutions and what ran unmodified are as in `hack/restart-lifecycle-kind-20261101T143009Z/README.md`; only run `f` ran here, `RESTART_STAGE=corelimit` as registered.
The earlier rehearsal of this stage, at `8aa8f43d`, is `hack/restart-lifecycle-kind-20261106T013822Z`.

The run is from commit `cb98ae98` on `fix/corelimit-prelaunch` with a clean tree (`provenance.txt`).
After it, `7bb8efe4` changed the runner once more: the collector now marks each Pod watch it opens, after a second review found a reopened watch could lose the deletion request.
So this rehearsal records the runner at `cb98ae98`, and a later one the launch runner.
The trainer's sha256 is `2c5cdbf09fdb4c8149443a806396fdf73f7176ea1adb174f5fe8052cb53f572c`, the one the paid session approves.

## What it showed

- Every case ACCEPTED by `score_eks.py`'s checks through `hack/test/restart-kind/score_kind_shim.py` (`run-f/verdict.txt`), with the two `rank-kill` arms summarised apart.
- `lifecycle-check.txt` and `outcomes-check.txt`: 0 FAIL each, and both replay from this directory with the timelines and Pod watches compressed.
- Every attempt-1 rank of every `rank-kill` case logged its arm's limit before the trainer: `0` in cases 2, 4 and 6, `unlimited` in 1, 3 and 5, all with this host's `core_pattern=core` (`h2-kind-shim.txt`, `logged_core_limit`).
- The collector's new Pod watch (`pod-watch.json.xz` in each case) was recorded for every case.
- How each `rank-kill` case's surviving rank ended is read in all six: `terminated`, exit 1 (gloo raises on the peer's death), with its finish time.
  In the earlier rehearsal `rank-kill-1`'s survivor was deleted before its stream's end and left only `gone`; that defect is the one the watch and the evaluator's fallback were added for, and here the stream records already held every end, so the fallback was not needed.
- The evaluator at `cb98ae98` read a deletion request in all six, with a grace of 0 s: on kind the survivor had exited, phase `Failed`, before its Pod was deleted, and the API server gives a Pod that has finished no grace.
  `h2-kind-shim.txt` is the evaluator after `7bb8efe4`, which reads a request only where one marked watch saw the Pod before and at its deletion; these watches carry no marks, so it prints the request as not shown, as it should.
- `h2-kind-shim.txt`, H2 through `hack/test/restart-kind/h2_kind_shim.py`: every arm read and accepted, `d` 0 to 1 s in both arms, so **INCONCLUSIVE**: the slow stop does not recur on kind, as the registration says it cannot.

Kind figures are not EKS figures.
Kind cannot show a core dump's cost: the ranks run on CPU with gloo, which raises an error on a peer's death rather than aborting, and this host's `ulimit -c` is 0 with `core_pattern` writing a file.
`finished_after_fault_s` is negative by up to 0.7 s here, because a container's `finishedAt` is a whole-second stamp and the fault's time is not.

The status timelines and the Pod watches are committed compressed (`timeline.jsonl.xz`, `pod-watch.json.xz`); `h2_corelimit.py` and `score_eks.py` read either form, and H2's output from the compressed files is identical to its output before compression.
The two Kueue manifest dumps, the stub state, `train-a-at-end.txt` and `volume.yaml` are left out, as in the earlier rehearsals.
