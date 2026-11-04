# Paid distributed-restart session, `full` stage, 2026-11-04 (UTC)

The second paid run of the apparatus registered in `docs/superpowers/specs/2026-11-01-distributed-restart-design.md`, "The paid session: apparatus", approved by the owner for `full` on 2026-11-03.
Three g5.xlarge (one A10G each) in an EKS cluster in ap-northeast-2a, CUDA ranks with NCCL, an EFS volume, `hack/eks-gitops-session.sh` with `TRAIN=restart RESTART_STAGE=full`.
One launch, 00:17Z to 01:51Z; the session's own checks reported no FAIL, the destroy returned zero and every residue query was empty.

## Verdicts

From `session/restart/verdict.txt`, rescored from a copy with the committed scorer at `f8ae0f94`: identical, exit 0.
The run's provenance: a clean tree at `f8ae0f94`, the approved `train.py` (`2db31cbd…`), collective timeout 60 s, rendezvous timeout 600 s, case budget 720 s.

| case | verdict | class | resumed from | recovery | lost steps | final parameters vs reference |
|---|---|---|---|---|---|---|
| reference | ACCEPTED | — | — | — | — | — |
| no-rng-control | ACCEPTED | — | step 12 | — | — | differ by 0.106, as the control must |
| rank-kill-1 | ACCEPTED | same-nodes | step 11 | 47.519 s | 1 | equal |
| rank-kill-2 | ACCEPTED | same-nodes | step 11 | 46.912 s | 1 | equal |
| dcgm-1 | ACCEPTED | spare | step 25 | 37.909 s | 0 | equal |
| dcgm-2 | ACCEPTED | spare | step 25 | 37.439 s | 0 | equal |
| terminate-spare-1 | ACCEPTED | spare | step 25 | 351.074 s | 0 | equal |
| terminate-spare-2 | ACCEPTED | spare | step 25 | 341.537 s | 0 | equal |
| terminate-wait-1 | ACCEPTED | replacement | step 25 | 410.608 s | 0 | equal |
| terminate-wait-2 | ACCEPTED | replacement | step 24 | 411.693 s | 1 | equal |

The per-kind figures, as the scorer's summary prints them:
- rank-kill: same-nodes, median 47.2 s, range 46.9 to 47.5 s, lost steps [1, 1].
- dcgm: spare, median 37.7 s, range 37.4 to 37.9 s, lost steps [0, 0].
- terminate-spare: spare, median 346.3 s, range 341.5 to 351.1 s, lost steps [0, 0].
- terminate-wait: replacement, median 411.2 s, range 410.6 to 411.7 s, lost steps [0, 1].
- Checkpoint cost: median 0.255 s, max 0.412 s, over 540 per-rank save records to EFS, each shard 16 MiB of ballast plus the training state; no-rng-control is not in the aggregate.

Each kind has two ACCEPTED observations under this run's recorded configuration; that is neither a reliability estimate nor coverage of other failure modes or later revisions.

## What the termination figures are made of

From each case's `marks.jsonl`:

| case | EC2 first described the instance as `terminated` after the call | fence after the call | recovery |
|---|---|---|---|
| terminate-spare-1 | 345.4 s | 346.2 s | 351.1 s |
| terminate-spare-2 | 336.3 s | 336.8 s | 341.5 s |
| terminate-wait-1 | 335.7 s | 336.2 s | 410.6 s |
| terminate-wait-2 | 336.0 s | 336.5 s | 411.7 s |

So 335.7 to 345.4 s passed from each termination call to the runner's first read of EC2's state as `terminated`, which the fence waits for by registration.
Those records do not separate the guest's shutdown, EC2's state transition, API latency and the runner's polling.
From the fence to both ranks' first step took 4.7 to 4.9 s on a spare and 74.4 to 75.2 s on a replacement; that includes the remaining controller, scheduling, node, image, mount, rendezvous, checkpoint-loading and start-up work, which these records do not separate.

## Cost

Not read from billing; Cost Explorer has nothing for the session yet.
GPU time from EC2's own launch and termination-request times: 147.5 instance-minutes over seven instances (three bought, four replacements), plus each terminated instance's shutdown; at $1.237 an hour about $3.7.
The cluster ran 00:17 to 01:51, about $0.41 at $0.263 an hour; image pulls through the NAT gateway at most about $1.4 by the registration's estimate.
So about $5.5, an estimate, against the registered ceiling of $36.09.

## What this does not show

- More than two cases of a kind.
- How a replacement's 75 s after the fence divide among the remaining replacement and trainer start-up work.
- The limits the registration lists as not fixed for `full`: the trainer's manifest and shard-read fallbacks, the rendezvous bound being up to twice 600 s, the controller's ordering of a DCGM handoff after a failed Job, and fencing bound to node names.
