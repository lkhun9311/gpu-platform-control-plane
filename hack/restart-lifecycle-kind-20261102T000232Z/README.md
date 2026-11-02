# Kind rehearsal of the restart runner with the rendezvous timeout, 2026-11-02 (commit 45c8779a)

This is the free end-to-end rehearsal of the paid distributed-restart session, run again on the D1 fix.
`train.py` now builds its TCPStore with `CKPT_RENDEZVOUS_TIMEOUT`, which the runner renders as 600.
It waits for every rank on an all-ranks store barrier, then sets the store back to the 60 s collective timeout.
The first rehearsal, `hack/restart-lifecycle-kind-20261101T143009Z`, is kept beside this one.
That README describes the apparatus, the substitutions and what a kind run cannot show, and all of it applies here unchanged.

The run is from commit `45c8779a` on `fix/restart-rendezvous-timeout`, with a clean tree (`provenance.txt`, `dirty_files=0`).
That commit is stacked on dev `41bdb758`.
Every case's rendered command carries `train.py` with sha256 `2db31cbd3ea00e76ef91f7c8710af391db40089878a7b30c6df712f16686bec8`.
I checked this by decoding all 13 `mltrainingjob.json` files.
Each one also renders `CKPT_RENDEZVOUS_TIMEOUT=600` and `CKPT_BACKEND=gloo` once.
Every run's `provenance.txt` records `rendezvous_timeout=600` and `case_budget=720`.
The budgets are the registered ones, and run a's replacement again joins 150 s after the termination.

## The change this rehearsal was for

In the first rehearsal, run a's terminate-wait-1 was FAILED, not recovered.
Attempt 2's rank 0 started on the surviving node, and its `init_process_group` gave up after 60 s.
The replacement's Node registered 20 s after that.
Here the same case is ACCEPTED as a replacement recovery.
These times come from the raw records in `run-a/terminate-wait-1/` and `events-pods.jsonl`:

| Event | When (UTC) | Source |
|---|---|---|
| Termination call | 00:09:18.74 | `marks.jsonl` fault-start |
| EC2 says terminated; fence requested | 00:10:19.99 | `marks.jsonl` |
| Attempt 2 created | 00:10:31 | `final-mltj.json` attempts[1].createdAt |
| Rank 0 Pod Running on rstlife-worker2 | 00:10:31.68 | `events-pods.jsonl` |
| Rank 1 Pod Pending; no GPU node free | 00:10:31.24 to 00:12:02.80 | `events-pods.jsonl` |
| Replacement launched (i-0c000000000000004 on rstlife-worker) | 00:11:50 | `state/asg.log` |
| Rank 1 Pod Running on the replacement | 00:12:02.88 | `events-pods.jsonl` |
| Both ranks' `resume` records | 00:12:03.48 | the ranks' logs |
| Both ranks' `start` records; first step at 00:12:03.81 | 00:12:03.81 | the ranks' logs |

Rank 0 therefore waited at least 91.2 s for its peer.
That is 00:10:31.68 to 00:12:02.88, past the 60 s collective timeout that ended the first rehearsal's attempt 2.

The store barrier's completion is not logged by `train.py`.
It lies between rank 1's container running (00:12:02.88) and the first record either rank wrote after the barrier (00:12:03.48).

The scorer gives a recovery of 165.088 s, class replacement, resumed from step 10, with lost steps 0.
Re-derived from the raw logs without the scorer, the recovery is 165.074 s.
The difference is the clock offset the scorer applies, -0.014 s.

## Runs and verdicts

The verdicts are from `run-*/verdict.txt`, and every recovery was re-derived from the logs within the clocks' 0.016 s offsets.

| Run | Case | Verdict | Detail |
|---|---|---|---|
| a (smoke) | reference | ACCEPTED | 30 steps, 60 saves |
| a | no-rng-control | ACCEPTED | resumed from step 12; params 0.074 from the reference |
| a | dcgm-1 | ACCEPTED | spare, recovery 32.9 s, lost steps 0 |
| a | terminate-wait-1 | ACCEPTED | replacement, recovery 165.1 s; it was FAILED in the first rehearsal |
| b | reference | ACCEPTED | |
| b | rank-kill-1 | FAILED, censored | quota held at 1 GPU from 00:14:41 to 00:26:41; last sample 719.5 s after creation, phase Pending |
| b | rank-kill-2 | ACCEPTED | spare, recovery 4.0 s |
| b | terminate-wait-1 | ACCEPTED | replacement after 5 s; recovery 71.8 s |
| c | reference | ACCEPTED | |
| c | rank-kill-1 | ACCEPTED | a finalizer on its attempt-2 Pod meant its retirement was not confirmed within 1,484 s |
| c | rank-kill-2 | NOTRUN | "rank-kill-1 could not be retired" |
| d | reference | ACCEPTED | |
| d | rank-kill-1, rank-kill-2 | VOID | VOID before the fault, every exporter's clock having been made unreadable |
| d | dcgm-1 | NOTRUN | "two cases in a row were VOID" |

The shim scorer exited 0 for run a, because every case was accepted, and 1 for runs b, c and d.

The unmodified `score_eks.py` scored every run, since `case_budget` is in provenance.
It voided each case the shim accepted for gloo on cpu, and kept the same FAILED, NOTRUN and runner-VOID verdicts.

`lifecycle-check.txt` has 0 FAILs, after its 8 fixtures came out as they must:

- nothing of a case existed, by resourceVersion, when the next one was created, across 9 transitions;
- both fences were requested 0.08 s after the stub's first `terminated` answer;
- the censored case was last sampled 719.5 s after its creation was seen.

`outcomes-check.txt` has 0 FAILs.
It now requires both terminate-wait-1 cases to be ACCEPTED as replacement recoveries.
It records no failed injection.

Rescoring a copy with the timelines decompressed reproduced every `verdict.txt` byte for byte, and both checks again found 0 FAILs.

## What this does not show

Everything listed in the first rehearsal's README still applies.

For the rendezvous specifically:

- a replacement slower than the 600 s rendezvous timeout;
- NCCL's own communicator setup after the store barrier, since the ranks here use gloo;
- a real g5's join time.
  The 150 s delay is the stub's.

## Files and cleanup

The layout is as in the first rehearsal, with each `timeline.jsonl` compressed as `timeline.jsonl.xz`.
Uncompressed, this directory was 74 MB.

`directory_delegations` read Y before the run.
The driver set it to N for the run, as `hack/distributed-restart-kind.sh` does, and it was back to Y after.
The host had 0 NFS mounts at the start and at the end.
`rstlife` was deleted, and `kind get clusters` lists ckad, m6clean and platform.
The aws stub logged 0 unimplemented calls.
