# Kind rehearsal of the restart runner after the full stage's fixes, 2026-11-04 (commit 2265b9ff)

This is the free end-to-end rehearsal of the paid distributed-restart session, run on the changes made after `full`.
It is the same driver, the same four runs and the same registered budgets as `hack/restart-lifecycle-kind-20261103T033600Z`.
That README and the first rehearsal's (`hack/restart-lifecycle-kind-20261101T143009Z`) describe the apparatus, the substitutions and what a kind run cannot show.
All of it applies here unchanged.

The run is from commit `2265b9ff` on `fix/reverify-review`, which sits on dev `59a894f5`, with a clean tree (`provenance.txt`, `dirty_files=0`).
Every run records the new `train.py` sha256 (`2c5cdbf09fdb4c8149443a806396fdf73f7176ea1adb174f5fe8052cb53f572c`), `rendezvous_timeout=600` and `case_budget=720`.
Run a's replacement again joins 150 s after the termination.
Each case's `timeline.jsonl` is committed xz-compressed, which `score_eks.py` reads; every run scored the same from the compressed copy as from the plain files.

## What changed since the last rehearsal

- The trainer: the checkpoint search passes over a malformed manifest, another checkpoint's directory and an unreadable shard, and the rank join has one 600 s deadline (#490).
- The controller: the GPU fault handoff is read before a failed Job, and each rank node's UID is recorded (#489).
- The rendered rank command forwards TERM to the trainer and waits for it to end (#495, `192029bd`).
- The operator gate also requires the node UID commit and the CRD field that keeps it (`2265b9ff`).
- The kill switch kills whatever outlives a destroy attempt in its process group (`d14e41d8`).

## Runs and verdicts

The verdicts are from `run-*/verdict.txt`; the recovery figures are the kind shim scorer's.

| Run | Case | Verdict | Detail | Last rehearsal |
|---|---|---|---|---|
| a | reference | ACCEPTED | | same |
| a | no-rng-control | ACCEPTED | resumed from step 12; params 0.074 from the reference | same |
| a | dcgm-1 | ACCEPTED | spare, 4.2 s | spare, 33.4 s |
| a | terminate-wait-1 | ACCEPTED | replacement, 166.3 s | replacement, 165.2 s |
| b | reference | ACCEPTED | | same |
| b | rank-kill-1 | FAILED, censored | quota held 08:40:03 to 08:52:04 | same |
| b | rank-kill-2 | ACCEPTED | same-nodes, 4.1 s | same-nodes, 4.2 s |
| b | terminate-wait-1 | ACCEPTED | replacement, 75.2 s | replacement, 74.3 s |
| c | reference | ACCEPTED | | same |
| c | rank-kill-1 | ACCEPTED | spare, 4.7 s; retirement held by the stuck finalizer | spare, 4.2 s |
| c | rank-kill-2 | NOTRUN | "rank-kill-1 could not be retired" | same |
| d | reference | ACCEPTED | | same |
| d | rank-kill-1, rank-kill-2 | VOID | VOID before the fault | same |
| d | dcgm-1 | NOTRUN | "two cases in a row were VOID" | same |

Every verdict and every case's outcome is the same as in the last rehearsal.
`outcomes-check.txt` and `lifecycle-check.txt` each end with 0 FAILs.
The unmodified `score_eks.py` voided the shim's accepted cases for gloo on cpu, and kept the rest.

The one figure that moved is `dcgm-1`, from 33.4 s to 4.2 s.
That is consistent with the TERM forwarding: on kind the old command's retired ranks waited out the 30 s grace period.
It is one observation on each side, on kind, with the trainer and operator also changed between them; it says nothing about EKS.
`rank-kill` did not move, because there the killed trainer ends by itself and nothing waits for a TERM.

## What this does not show

Everything the earlier rehearsals' READMEs list, and in particular:
- No GPU, NCCL, EFS or EC2 path ran; the trainer's CUDA RNG path and NCCL are untouched here.
- No case induces the trainer's new checkpoint fallbacks or a peer that uses up the new rendezvous deadline; they ran only on their normal paths.
- No node registers under an old name with a new UID, so the controller's UID check is exercised only as a record, not as a refusal.
- The gate's new CRD and commit checks are not run by this driver; `hack/test/check-restart-session.sh` covers the CRD check against the repository's CRD.
