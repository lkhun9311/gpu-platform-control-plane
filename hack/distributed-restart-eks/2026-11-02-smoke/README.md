# Paid distributed-restart session, `smoke` stage, 2026-11-02 (UTC)

The first paid run of the apparatus registered in `docs/superpowers/specs/2026-11-01-distributed-restart-design.md`, "The paid session: apparatus", approved by the owner for `smoke` on 2026-11-02.
Three g5.xlarge (one A10G each) in an EKS cluster in ap-northeast-2a, CUDA ranks with NCCL, an EFS volume, `hack/eks-gitops-session.sh` with `TRAIN=restart RESTART_STAGE=smoke`.

It took three launches; the first two bought no case and are kept here as `attempt-1` and `attempt-2`.

| launch | commit | ended at | why |
|---|---|---|---|
| 1, 02:00Z | `4acb66b2` | `terraform apply` | EC2 refused the EFS security group's description, which held an apostrophe (`attempt-1/terraform-error.txt`); no GPU was launched; the partial cluster was destroyed by hand and the kill switch disarmed (`attempt-1/ttl-kill-switch.log`) |
| 2, 04:16Z | `d95a8a01` | R5 | every warm-up Pod got the same name, cut from the tail of EKS node names; GPUs up about 4 minutes; the session destroyed everything itself |
| 3, 22:41Z | `5c78d4cf` | done | this record (`session/`) |

Between launches 2 and 3, a read-only sweep of the runner for kind-only assumptions found two more that would have cost this run: the API server could not reach the exporter on 9400 (R6 would have aborted after the GPUs were bought), and every clock probe's bracket held `aws eks get-token`, measured at 0.30 to 0.32 s against the scorer's 0.5 s (#483).

## Verdicts

From `session/restart/verdict.txt`, rescored from a copy with the committed scorer at `5c78d4cf`: identical, exit 0.
The run's provenance: a clean tree at `5c78d4cf`, the approved `train.py` (`2db31cbd…`), collective timeout 60 s, rendezvous timeout 600 s, case budget 720 s.

| case | verdict | class | resumed from | recovery | lost steps | final parameters vs reference |
|---|---|---|---|---|---|---|
| reference | ACCEPTED | — | — | — | — | — |
| no-rng-control | ACCEPTED | — | step 12 | — | — | differ by 0.106, as the control must |
| dcgm-1 | ACCEPTED | spare | step 25 | 37.3 s | 0 | equal |
| terminate-wait-1 | ACCEPTED | replacement | step 25 | 409.4 s | 0 | equal |

Checkpoint cost: median 0.254 s, max 0.427 s, over 180 saves of two 16 MiB shards to EFS.
One case of each kind: these are one observation each, not a distribution.

## terminate-wait-1, from the raw records

| UTC | event | source |
|---|---|---|
| 23:18:26.857 | `terminate-instances` called (fault-start) | `marks.jsonl` |
| 23:19:44 | the Auto Scaling group launched the replacement, i-0f3bb7c57a17d7e87 | EC2 `LaunchTime` |
| 23:24:01.168 | EC2 first described the terminated instance as `terminated`, 334 s after the call | `marks.jsonl` |
| 23:24:01.619 | fence written | `marks.jsonl` |
| 23:24:05 | attempt 2's rank 0 Pod observed, on the surviving node | `pods.jsonl` |
| 23:25:14 | attempt 2's rank 1 Pod observed, on the replacement | `pods.jsonl` |
| 23:25:15.3 | both ranks resumed from step 25 | rank logs |
| 23:25:16.3 | both ranks' first step, 26 | rank logs |

Most of the 409 s is the old instance's graceful shutdown: the fence waits for EC2's own `terminated`, and the controller waits for the fence.
Rank 0's Pod was observed 69 s before rank 1's, and the ranks' first records are written after the rendezvous, so rank 0 likely waited past the 60 s collective timeout that failed this case on kind before the rendezvous timeout existed; when rank 0's process started is not in these records, so that is not shown.

## Cost

Not read from billing: Cost Explorer had nothing for the session when it ended (`session/billing-after-destroy.txt`).
GPU time from EC2's own launch and termination times: about 66 instance-minutes to the termination requests, plus shutdown; at $1.237 an hour about $1.7 with the shutdowns.
The cluster ran 22:41 to 23:44, about $0.28 at $0.263 an hour; image pulls through the NAT gateway at most about $0.8.
So about $3 for this launch and under $1 for the two before it: an estimate, against the registered ceiling of $19.71.

## What this does not show

- More than one case of a kind, a `full` stage, `rank-kill` or `terminate-spare`.
- How the 409 s divides between the replacement's join, its 3.3 GB image pull and the EFS mount: the replacement was not warmed, by design, and the records here do not separate them.
- That EFS behaves as the NFS-Ganesha rehearsal did beyond these four cases.
