# Paid distributed-restart session, `retarget` stage, 2026-11-05 (UTC)

The third paid run of the distributed-restart apparatus, the one registered in `docs/superpowers/specs/2026-11-04-restart-retarget-design.md`, approved by the owner at launch on 2026-11-05.
Three g5.xlarge (one A10G each) in an EKS cluster in ap-northeast-2a, CUDA ranks with NCCL, an EFS volume, `hack/eks-gitops-session.sh` with `TRAIN=restart RESTART_STAGE=retarget`, every paid step under the phase supervisor.
One launch, 15:44Z to 16:39Z; the session's own checks reported no FAIL, the destroy returned zero and every residue query was empty.

## Verdicts

From `session/restart/verdict.txt`, rescored from a clean checkout of `76129fc6` with the committed scorer: identical, exit 0.
The run's provenance: a clean tree at `ddf5ce5c`, the approved `train.py` (`2c5cdbf0…`), collective timeout 60 s, rendezvous timeout 600 s, case budget 720 s (`session/restart/provenance.txt`).
The operator was the registered one: `session/session.log` R2 reads revision `44bd5e74…` running digest `sha256:12d60cfc…`.
That nothing was promoted afterwards is not in the archive: it rests on `origin/main` still being `44bd5e74` when this record was written on 2026-11-06.

| case | verdict | class | resumed from | recovery | lost steps | final parameters vs reference |
|---|---|---|---|---|---|---|
| reference | ACCEPTED | — | — | — | — | — |
| no-rng-control | ACCEPTED | — | step 12 | — | — | differ by 0.106, as the control must |
| rank-kill-1 | ACCEPTED | same-nodes | step 11 | 46.503 s | 1 | equal |
| rank-kill-2 | ACCEPTED | same-nodes | step 11 | 47.460 s | 1 | equal |
| dcgm-1 | ACCEPTED | spare | step 11 | 8.799 s | 1 | equal |
| dcgm-2 | ACCEPTED | spare | step 12 | 7.842 s | 0 | equal |

The per-kind figures, as the scorer's summary prints them:
- rank-kill: same-nodes, median 47.0 s, range 46.5 to 47.5 s, lost steps [1, 1].
- dcgm: spare, median 8.3 s, range 7.8 to 8.8 s, lost steps [0, 1].
- Checkpoint cost: median 0.265 s, max 0.386 s, over 300 per-rank save records to EFS; no-rng-control is not in the aggregate.

Beside `full` (`hack/distributed-restart-eks/2026-11-04-full`), never pooled with it: rank-kill recovered in 46.9 and 47.5 s there and 46.5 and 47.5 s here; dcgm in 37.4 and 37.9 s there and 7.8 and 8.8 s here.
The trainer, the rank command and the operator all changed between the two runs, and nothing here attributes the difference to any one of them.

## H1

`experiments/distributed-restart/h1_retarget.py session/restart`, from the same clean checkout:

| case | trigger | `failureObservedAt` | `stopConfirmedAt` | `d` | collector bracket | `full`'s `d` |
|---|---|---|---|---|---|---|
| rank-kill-1 | RankFailed | 16:13:36Z | 16:14:14Z | 38 s | 34.4 to 42.3 s | 39 s |
| rank-kill-2 | RankFailed | 16:15:57Z | 16:16:36Z | 39 s | 34.3 to 42.2 s | 39 s |
| dcgm-1 | NodeFault | 16:18:17Z | 16:18:19Z | 2 s | −2.0 to 28.9 s | 31 s |
| dcgm-2 | NodeFault | 16:20:03Z | 16:20:05Z | 2 s | −2.0 to 30.4 s | 31 s |

**H1 is REFUTED**, by the registered rule that any `d` of 30 s or more refutes: both `rank-kill` cases are at 38 and 39 s, as in `full`.
Both `dcgm` cases fell to 2 s, which on its own would be below the 15 s bar; the rule is read in order and does not wait on them.
Each `d` lies inside its bracket; the `dcgm` brackets are about 31 s wide because the injection holds the collector's loop, so they show consistency only to that width.

What the barrier waited on, from each case's `timeline.jsonl.xz` (`status.attempts[0].waitingFor`, the reads between the two stamps):
- rank-kill-1: `job rst-rank-kill-1-161302 to be deleted` in all 20 reads, 16:13:37.9 to 16:14:14.3.
- rank-kill-2: `job rst-rank-kill-2-161523 to be deleted` in all 20 reads, 16:15:59.8 to 16:16:36.1.
- dcgm-1 and dcgm-2: `job … to be deleted` in the one read each between the stamps.

So in this run the `rank-kill` stop still waited about 38 s on the old Job's deletion, as in `full`, and the `dcgm` stop did not.
These records do not say why: they keep no Pod deletion or container exit times, and the registration does not let a difference be attributed to TERM forwarding, the trainer change or the operator change alone.

`phases_eks.py session/restart` gives the milestones from the fault (medians of two; `*` a whole-second cluster stamp whose offset from the runner is unmeasured):
- rank-kill/same-nodes: trigger +2.5*, stopped +41.0*, created +41.5*, pods seen +45.0, ready +44.5*, resumed +45.9, stepped +47.0.
- dcgm/spare: trigger +0.8*, stopped +2.8*, created +2.8*, pods seen +6.3, ready +5.8*, resumed +7.2, stepped +8.3.

In `full` the same medians were stopped +41.8* for rank-kill and +32.3* for dcgm; from the stop to the first resumed step the medians were 5.4 to 6.0 s in both runs.

## The session

- Gates T1 to T7, R1 to R7, K1, Z1 and Z2 each logged `ok`; `session.log` holds no `FAIL`.
- The `terraform output` of the bootstrap root failed for want of `terraform init` (`session.log` lines 50 to 70), and the TTL role was read from IAM instead, as `hack/lib/gpu-ttl.sh` provides; the same error is in the `smoke` and `full` logs. The GPU deadline was armed (`gpu-ttl-gpu-platform-gpu-20261105160346`) before any node was bought.
- The nightly destroy workflow was disabled by hand for the session, as the registration requires (`session.log` line 11 reads it `disabled_manually`), and re-enabled after the teardown was confirmed; the re-enabling is not in the archive, and GitHub's API gives the workflow `active`, updated at 16:46:13Z, seven minutes after the session's last line.

## Cost

Not read from billing.
GPU time from CloudTrail's `RunInstances` and `TerminateInstances` events for the three instances: launched 16:04:01Z, termination requested at 16:22:31Z for one and 16:23:31Z for two, so 57.5 instance-minutes plus each one's shutdown; at $1.237 an hour about $1.19.
The cluster ran about 55 minutes, about $0.24 at $0.263 an hour; data, EFS and IPv4 at most about $0.71 by the registration's estimate.
So about $2.1, an estimate, against the registration's conditional estimate of $22.99.

## What this does not show

- Why the `rank-kill` stop still waits on the old Job's deletion: nothing collected times the Pods' termination.
- Which change shortened the `dcgm` stop.
- A rate or a tail: two cases per kind.
- Termination, fencing, replacement or an EFS outage, none of which this stage runs.

The status timelines are committed compressed (`timeline.jsonl.xz`); `runbook-verify/*.out` are not committed, as in the earlier sessions.
