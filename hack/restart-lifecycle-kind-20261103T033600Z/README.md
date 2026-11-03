# Kind rehearsal of the restart runner before the paid full stage, 2026-11-03 (commit d27e5e96)

This is the free end-to-end rehearsal of the paid distributed-restart session, run again on the runner and scorer changes made for the full stage.
It is the same driver, the same four runs and the same registered budgets as `hack/restart-lifecycle-kind-20261102T000232Z`.
That README and the first rehearsal's (`hack/restart-lifecycle-kind-20261101T143009Z`) describe the apparatus, the substitutions and what a kind run cannot show.
All of it applies here unchanged.

The run is from commit `d27e5e96` on `fix/restart-full-robustness`, which sits on dev `d7496f5b`, with a clean tree (`provenance.txt`, `dirty_files=0`).
Every run records the same `train.py` sha256 (`2db31cbd…6bec8`), `rendezvous_timeout=600` and `case_budget=720`.
Run a's replacement again joins 150 s after the termination.

No kind shim needed changing.
`rstk_install` asserts each substituted text before applying it, and every one still matched at this commit:
`train_qualify_nodes`' device-plugin selector, `restart_verdict`'s scorer path, and the `CKPT_BACKEND=nccl` in the rendered command.

## What changed since the last rehearsal

In `hack/lib/restart-session.sh`:

- `restart_case_files` deletes a case's files only after reading them succeeded.
- The collector follows a log again after a failed status read, and pauses after a stream that fails at once.
- `restart_stop_collector` replaced the single kill and wait at both stop sites: it sends TERM again each second, and after 10 it KILLs the collector's whole tree.
- `gfk` carries a timeout, and LATEST is read through `rkt`.
- `restart_scale_group` retries the scale-in.
- `restart_probe_all` requires a non-terminating exporter on every current GPU node.
- `restart_wait_group` waits again when qualification sees too many nodes.
- `restart_ranks_stepped` counts distinct ranks.

In the scorer: spare preparation is keyed by Node UID, and new VOID conditions were added.

## Runs and verdicts

The verdicts are from `run-*/verdict.txt`.
Each recovery was also re-derived from the raw logs without the scorer, and agreed within the clocks' 0.016 s offsets.

| Run | Case | Verdict | Detail | Last rehearsal |
|---|---|---|---|---|
| a | reference | ACCEPTED | | same |
| a | no-rng-control | ACCEPTED | resumed from step 12; params 0.074 from the reference | same |
| a | dcgm-1 | ACCEPTED | spare, 33.4 s | spare, 32.9 s |
| a | terminate-wait-1 | ACCEPTED | replacement, 165.2 s | replacement, 165.1 s |
| b | reference | ACCEPTED | | same |
| b | rank-kill-1 | FAILED, censored | quota held 03:48:24 to 04:00:23 | same |
| b | rank-kill-2 | ACCEPTED | **same-nodes**, 4.2 s | spare, 4.0 s |
| b | terminate-wait-1 | ACCEPTED | replacement, 74.3 s | replacement, 71.8 s |
| c | reference | ACCEPTED | | same |
| c | rank-kill-1 | ACCEPTED | spare, 4.2 s; retirement held by the stuck finalizer | same |
| c | rank-kill-2 | NOTRUN | "rank-kill-1 could not be retired" | same |
| d | reference | ACCEPTED | | same |
| d | rank-kill-1, rank-kill-2 | VOID | VOID before the fault | same |
| d | dcgm-1 | NOTRUN | "two cases in a row were VOID" | same |

Every verdict and every case's outcome is the same as in the last rehearsal.
Only run b's rank-kill-2 recovery class differs.
Its attempt 2 was placed on the same two nodes as attempt 1, where last time it was placed on a spare.
That placement is the scheduler's choice after a rank kill, and the outcome check allows either.

The unmodified `score_eks.py` voided the shim's accepted cases for gloo on cpu, and kept the rest.

`lifecycle-check.txt` has 0 FAILs, after its 8 fixtures came out as they must.
`outcomes-check.txt` has 0 FAILs.
Rescoring a copy with the timelines decompressed reproduced every `verdict.txt` byte for byte, and both checks again found 0 FAILs.

## The collectors and helpers

No case's `case.log` holds the line `restart_stop_collector` writes when a collector outlives its 10 TERMs.
That covers all 13 started cases.
So every collector stopped before the KILL fallback, within 10 TERMs sent a second apart.
The runner does not record the stop's exact duration.

`processes.txt` sampled, every 5 s from outside the driver, how many `kubectl ... logs -f` follows of the training namespace ran.

- The last sample before each of the 13 submissions shows 0 follows, so no case's follows outlived it into the next.
- At most 3 ran at once, while one case's attempt-1 and attempt-2 streams overlapped.
- After the driver exited, the count was 0 follows, 0 `kubectl --context kind-rstlife` processes and 0 `watch_events.py` recorders.

## Cleanup

`directory_delegations` read Y before the run.
The driver set it to N for the run, as `hack/distributed-restart-kind.sh` does, and it was back to Y after.
The host had 0 NFS mounts at the start and at the end.
`rstlife` was deleted, and `kind get clusters` lists ckad, m6clean and platform.
The aws stub logged 0 unimplemented calls, and no injection failed.
Each `timeline.jsonl` is compressed as `.xz`; uncompressed, this directory was 74 MB.
