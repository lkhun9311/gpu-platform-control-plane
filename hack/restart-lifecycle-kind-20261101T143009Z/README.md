# Kind rehearsal of the restart runner, 2026-11-01 (commit 66757add)

This is the free end-to-end rehearsal of the paid distributed-restart session.
`restart_run` from `hack/lib/restart-session.sh` ran unmodified against the kind cluster `rstlife`.
The ranks trained on the CPU with gloo and shared an NFS volume.
Only what has no kind equivalent was substituted.
The driver is `hack/restart-lifecycle-kind.sh`.
The substitutions are in `hack/lib/restart-kind-shims.sh` and `hack/test/restart-kind/`.

The run is from commit `66757add` on `feat/restart-kind-lifecycle`, rebased onto `origin/dev` 8aa95a9c, with a clean tree (`provenance.txt`).
The lifecycle check in `lifecycle-check.txt` ran from the checker at `43bce4f9`, the next commit.
That commit changes only the checker, and only to count a relist that still holds a leftover, which it never found here.

## What ran for real

- `restart_run` in the smoke stage and in three scenario runs.
  That covers its slot deadlines (the registered constants, none shortened), `restart_wait_group`, `restart_prepare_nodes`, `restart_run_case` and `restart_collect`.
  It also covers the fault window and its last read, `restart_terminate_and_fence`, `restart_dcgm_fault` and `restart_dcgm_reset`, `restart_retire`, `restart_void_case`, the per-case verdict and the stop rules.
- The session's R3 (`restart_reader`), R5 (`restart_prepare_nodes`) and R6 (`restart_fault_path_ready`), in each run.
- The operator built from this commit, with exactly `RESTART_FAULT_FLAGS`.
  Also its webhook, Kueue from `config/kueue-controller` (the EKS install, with the EKS flavor's train label and GPU toleration), and `config/training`.
- `train.py` as `restart_render_job` renders it: carried in the command, checked by sha256, and started as a child of the shell.
- An NFS-Ganesha server and a static volume with the EFS mount options, so each worker's kernel NFS client was the only path between ranks.
- Nodes that die and arrive.
  A terminated machine is a `docker kill`ed kind node, and its Node is deleted 20 s later.
  A replacement is a new Node object with a new UID and a new providerID.
- `score_eks.py`'s own checks on every case, run through `score_kind_shim.py`.
  The unmodified `score_eks.py` also ran on each run (`verdict-unmodified-scorer.txt`).

## What was substituted

| Boundary | On EKS | Here |
|---|---|---|
| `aws ec2 terminate-instances` / `describe-instances` | EC2 | `stubs/aws`: `docker kill` of the node container. It answers `shutting-down` for 60 s, then `terminated` only once the container is stopped or restarted as another instance. Every answer is logged in `state/calls.log`. |
| `aws eks update-nodegroup-config`, the autoscaler | the ASG | `rstk_asg_loop`: it launches a pool container after a per-run delay, takes back an idle node on a scale-in, and deletes a killed instance's Node after 20 s. |
| `aws scheduler` (GPU deadline) | EventBridge | One schedule at the run's start plus `restart_gpu_budget` plus 3,600 s. |
| `aws cloudwatch` (EFS credits) | CloudWatch | Refused; recorded as unread. |
| GPU, device plugin | g5.xlarge, NVIDIA plugin | The gpu-simulator, one `nvidia.com/gpu` per node. `train_qualify_nodes` reads its Pods where it reads the device plugin's, which also means its no-simulator refusal finds nothing (`rstk_substitute`). |
| DCGM host engine, exporter | dcgm-exporter 3.3.9 | The simulator's fake DCGM, labelled as the exporter. `exporter` and `hostengine` sidecars answer `date` and a `dcgmi` that injects and reads back over the Pod's loopback. |
| Image, backend | pinned CUDA image, NCCL | `distributed-restart:torch251` (CPU torch 2.5.1). `CKPT_BACKEND=gloo` is substituted in the rendered command, once, asserted. |
| Scorer backend and transport checks | nccl on cuda; NCCL logs on NET/Socket | `score_kind_shim.py` requires gloo on cpu, then runs `check_starts` itself. In place of the transport check it requires the runner's per-attempt, per-rank NCCL directory marker and no NCCL log. |
| Volume | EFS CSI static PV | NFS-Ganesha PV with the EFS options; same claim name and binding. |
| `approved_train_py_sha256` | the registration's | The hash of the `train.py` that ran. |
| Cluster size | 3 GPU nodes plus a CPU group | Five kind nodes. The control plane doubles as the CPU node, which leaves three GPU workers and one pool worker. Killed machines rejoin the pool (`rstk_recycle`). |

Not run at all, because they are AWS or Argo only: R1 `restart_render_volume`, R2 `restart_operator_gate` and R4 `restart_enable_fault_path`.
Nor were the credential, TTL and zone refusals, or Terraform, the purchase and the destroy.

## Runs and verdicts

The verdicts are from `run-*/verdict.txt`.
The recoveries were also re-derived from the raw logs without the scorer, giving the same figures within the clocks' 0.015 s offset.

| Run | Case | Verdict | What decided it |
|---|---|---|---|
| a (smoke) | reference | ACCEPTED | 30 steps, 60 saves |
| a | no-rng-control | ACCEPTED | Resumed from step 12; params 0.074 from the reference |
| a | dcgm-1 | ACCEPTED | XID 79 read back, latched and tainted. Spare, recovery 34.1 s, lost steps 0. |
| a | terminate-wait-1 | FAILED, not recovered | See the finding below |
| b | reference | ACCEPTED | |
| b | rank-kill-1 | FAILED, censored | Quota lowered to 1 GPU at 14:41:38, so attempt 2 was never admitted. Last sample 720.0 s after creation, phase Pending. |
| b | rank-kill-2 | ACCEPTED | Still ran after the censored case. Same-nodes, recovery 5.0 s. |
| b | terminate-wait-1 | ACCEPTED | Replacement launched 5 s after the deficit. Class replacement, recovery 66.0 s. |
| c | reference | ACCEPTED | |
| c | rank-kill-1 | ACCEPTED | Its attempt-2 rank-0 Pod held a finalizer nothing removed, and the retirement was not confirmed within 1,482 s. The NCCL logs were still copied read-only. |
| c | rank-kill-2 | NOTRUN | "rank-kill-1 could not be retired" |
| d | reference | ACCEPTED | |
| d | rank-kill-1, rank-kill-2 | VOID | VOID before the fault: every exporter's `date` was made to fail, and `restart_void_case` retired each. |
| d | dcgm-1 | NOTRUN | "two cases in a row were VOID" |

The unmodified `score_eks.py` voided every case the shim accepted, each for gloo on cpu.
It returned the same FAILED, NOTRUN and runner-VOID verdicts as the shim.

`lifecycle-check.txt` reads records the runner did not write, and found 0 FAILs:

- 9 consecutive transitions.
  Replaying the four resources' list-then-watch histories by resourceVersion, nothing of a case existed when the next was created.
- The two fences.
  Each fence-request came 0.09 s and 0.08 s after the stub's first `terminated` answer for the instance it killed.
- Every case's elapsed time.
  The censored case was sampled 720.0 s after its creation was seen.
  Its fixtures (`lifecycle-check-selftest.txt`) show the check failing on a leftover, a gap and a recorder that never caught up.

## Finding: terminate-wait cannot recover as registered when the replacement is slower than about a minute

In run a the replacement joined 150 s after the termination.
The timeline:

1. The termination call came at 14:36:58.15.
2. EC2 said terminated at 14:37:58.18, and the fence was written.
3. The controller created attempt 2 at 14:38:05 with only one schedulable GPU.
   Kueue admits on quota, not node capacity, and the job's quota is 4.
4. Rank 0 started on rstlife-worker2.
   It raised `DistStoreError: Timed out after 61 seconds waiting for clients. 1/2 clients joined.`, because `init_process_group` waits `CKPT_COLLECTIVE_TIMEOUT` = 60 s.
5. The failure was observed at 14:39:10, and `maxRestarts` 1 was spent.
6. The replacement's Node registered at 14:39:30.

In run b the replacement was there before attempt 2 was created, and the case recovered.
On EKS a g5.xlarge from launch to a Ready device plugin takes minutes, so this outcome is what the registered terminate-wait should expect.
It is not a runner or scorer defect.
It is a property of the registered apparatus: the 60 s rendezvous timeout, `BackoffLimit` 0, one restart, and no gang admission on capacity.

## Defects the rehearsal found and fixed

Each was fixed with a test in `hack/test/check-restart-session.sh` that failed first, and a revert of each fix turns the suite red.

- `8bae2fec` The collector followed logs with `rk`, whose `--request-timeout=20s` cut every follow.
  Each Pod's log was re-read from the start every 20 s, and the 20-read cap ended coverage at about 400 s of a Pod's life.
- `f5819f38` With no timeout, stopping the collector left the follows running, a codex review finding on `8bae2fec`.
  Each follow now runs in the background and is killed by a trap.
- `b6c9dd6e` `restart_exporters` listed an exporter Pod still shown Running on a Node the group had just scaled in.
  Its probe failed, and terminate-wait-1 was VOID before its fault in two shakedown runs.
  Exporters are now filtered to the group's current Nodes, and an unreadable list is a failure.
- `d9fa0a3f` An unretired case's NCCL logs were left on the volume.
  The scorer then voided a case that had recovered, naming the transport as unknown.
  They are now copied read-only, as the listing is.
- `3c196663` The runner stamped marks with `%6N`.
  This machine's `date` is uutils 0.8.0, which prints `%6N` as the whole nanosecond count without leading zeros, so a mark at .078 s read .78 s.
  The paid session runs from this machine.
  Marks, pod observations, stream ends and preparation times now use `%N`.

## What this does not show

- A real GPU, NCCL, the NET/Socket transport, EFS, or the pinned CUDA image's 3.3 GB first pull inside a recovery.
  Every image was already on every node.
- A real DCGM host engine or a real XID.
  The fake DCGM's cache is the one the operator scrapes.
- Clock offsets.
  Every kind node shares the host clock, so the offsets read -0.016 to -0.005 s, the probe's own asymmetry, and the correction code was not stressed.
- EC2's and the ASG's real timing.
  The 60 s shutdown, 20 s Node removal and 150 s or 5 s launch delays are the stub's.
- R1, R2 and R4, Argo's sync, the credential and TTL refusals, Terraform, the purchase, the scale-down and the destroy.
- A terminate-spare case, a full-stage run, or the DCGM path's latency on real hardware.

## Files

- `run-a` to `run-d` are each one `RESTART_OUT`.
  Each `timeline.jsonl` is compressed as `timeline.jsonl.xz`, because every sample carries the job's last-applied annotation with the whole `train.py`.
  Uncompressed it held 69 MB, the censored case alone 31 MB.
  `unxz` them before rescoring; rescoring the decompressed copy reproduced every `verdict.txt` byte for byte.
- `events-*.jsonl` are the watch histories.
  `state/` holds the stub's and the autoscaler's state, with `state/calls.log` and `aws-calls.log` showing 0 unimplemented AWS calls.
- `log.txt` is the driver's log.
- The rendered Kueue manifests are not kept; they are `kubectl kustomize config/kueue-controller` at the commit.

## Cleanup

`directory_delegations` was Y before the run, N during it and Y after; the host had 0 NFS mounts at the start and at the end.
`rstlife` was deleted, and `kind get clusters` lists ckad, m6clean and platform.
