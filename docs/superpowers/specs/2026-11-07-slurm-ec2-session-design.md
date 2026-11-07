# Plain Slurm on EC2 with a real GPU: confinement, limits, drain and requeue (paid session B)

Written 2026-11-07, before any run.
Status: **registration; not yet run.**
The owner approved the purchase on 2026-11-07 ("유료 승인하는데 권장안대로 진행"), conditional on gpt-6-astra's pre-purchase review; the record of that decision and of why this session exists is storage `career/resume/personal/gpu-control-plane-42dot-2026-11-07-jd-gap.md` (rank 1 of astra's list, item 4 of the 2026-10-31 plan's §7).

## The question

The container Slurm lab (`experiments/slurm-lab/README.md`) asked the Kueue policy questions of Slurm with fake GPUs, `proctrack/linuxproc`, `task/none` and no cgroup at all: it showed scheduling, accounting, drain and requeue, and nothing about confinement.
What a GPU cluster operator relies on Slurm for, and the lab could not show, is that a job gets the devices and memory it was allocated and nothing more, on a real driver, with daemons under systemd.
This session asks four things of plain Slurm, as Ubuntu 24.04 packages it, on EC2 with an A10G:

- **B1** a job allocated no GPU cannot use the GPU, even after it unsets `CUDA_VISIBLE_DEVICES`, while a job allocated one can;
- **B2** a job that exceeds its `--mem` is killed by the cgroup OOM killer, and `slurmd` is not;
- **B3** account and QoS limits hold jobs back, with the pending reason Slurm names;
- **B4** a GPU fault signal drains the node, and a checkpointed GPU training job is requeued onto the other GPU node and resumes from its last checkpoint.

## Apparatus

Three EC2 Spot instances in one zone of `ap-northeast-2`, account `gpu-lab` (007635145730), in the default VPC's default subnet and default security group (which admits all traffic between its own members and nothing else inbound):

| role | type | AMI | Slurm role |
|---|---|---|---|
| `head` | `t3.medium` | Canonical Ubuntu 24.04 (gp3), pinned by ID | `slurmctld` (configless server), `slurmdbd` with MariaDB, NFS server of `/shared`, the procedure |
| `gpu1`, `gpu2` | `g5.xlarge` (1 A10G each) | AWS Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04), pinned by ID | `slurmd`, configless from `head`, `/shared` over NFS |

Every Slurm package is installed from the Ubuntu 24.04 archive at its exact version (`slurmctld`, `slurmd`, `slurmdbd`, `slurm-client` `23.11.4-1.2ubuntu5`, `munge` `0.5.15-4ubuntu0.1`, `mariadb-server` `1:10.11.14-0ubuntu0.24.04.1`), so a rebuild either reproduces this or fails at install.
All daemons are the packages' systemd units.
`cgroup.conf`: `CgroupPlugin=cgroup/v2`, `ConstrainCores`, `ConstrainDevices`, `ConstrainRAMSpace`, `ConstrainSwapSpace` all `yes`; `slurm.conf`: `ProctrackType=proctrack/cgroup`, `TaskPlugin=task/cgroup,task/affinity`, `JobAcctGatherType=jobacct_gather/cgroup`, `SelectType=select/cons_tres` with `CR_Core_Memory`, accounting enforced (`associations,limits,qos`).
`gres.conf` names the device by file, `Name=gpu File=/dev/nvidia0`, rather than `AutoDetect=nvml`: whether the Ubuntu build carries the NVML plugin is recorded (`/usr/lib/x86_64-linux-gnu/slurm-wlm/gpu_nvml.so` present or not) but nothing depends on it.
Each worker's `NodeName` line is built from that worker's own `slurmd -C`, with `RealMemory` lowered by 1,024 MiB, so a declared node never exceeds the machine.
The GPU fault signal is the lab's `experiments/slurm-lab/etc/gpuhc.py`, unchanged, run by `slurmd` as `HealthCheckProgram` every 5 s on every node state, reading a per-node file on `/shared` in dcgm-exporter's shape with the card's real UUID and its real device glob `/dev/nvidia[0-9]*`.
The fault is written into that file by the procedure: **the signal is simulated, the drain, the requeue and the resume are Slurm's own.** DCGM injection on a real A10G was the subject of the GPU fault study (`hack/gpu-fault/`); repeating it here would add a dependency and nothing Slurm does.
The trainer for B4 is `hack/slurm-ec2/train_gpu.py`: a two-layer MLP on CUDA, seeded, deterministic algorithms on, one batch generated from the step number, a checkpoint every 5 steps written to a temporary name, `fsync`ed and renamed, and `LATEST` renamed over last; on start it resumes from `LATEST`.
PyTorch `2.5.1` (the PyPI wheel, CUDA 12.4 runtime) is installed once by `head` into `/shared/venv`.

## The clock and the deadlines

Every deadline counts from `T0`, the latest of the three instances' EC2 `LaunchTime`, which the runner writes to the run's S3 prefix together with the three private addresses (`cluster.env`); no instance proceeds past fetching its inputs without it.

| from T0 | what |
|---|---|
| 1,500 s | bring-up ends: packages, MariaDB, munge, NFS, `slurmctld`, both `slurmd` registered `IDLE`, the venv |
| 4,200 s | the checks end |
| 4,380 s | evidence uploaded |
| 4,470 s | the sweeper's `study-deadline` tag |
| 4,500 s | every instance shuts itself down (`instance-initiated-shutdown-behavior=terminate`) |
| 4,900 s | the runner's termination wait ends |

## Checks, registered

Each check runs in this order, as the tenant user `tenant` (UID 2001 on every node) unless it says root.
A check whose inputs did not come to exist is **NOTRUN** with the reason; a check whose instrument failed is **INVALID**; otherwise each rule **held** or **did not hold**, and every repetition is reported.

**B1 — device confinement**, 3 repetitions on `gpu1`, 1 on `gpu2`, each a pair of jobs running `hack/slurm-ec2/probe_cuda.py`:
- B1a, `--gres=gpu:1`: holds when `nvidia-smi -L` lists exactly one A10G and a CUDA tensor op returns the expected sum.
- B1b, no `--gres`, the probe unsets `CUDA_VISIBLE_DEVICES` first: holds when `torch.cuda.device_count()` is 0 or CUDA initialisation raises, **and** opening `/dev/nvidia0` for read fails with `EPERM`.
- B1b of a repetition is scored only if B1a of the same repetition held; otherwise that repetition's B1b is INVALID (a card no job can use says nothing about confinement).

**B2 — memory confinement**, 3 repetitions on `gpu2`: a batch job with `--mem=512M` runs `srun python alloc.py`, which touches 2 GiB in 64 MiB pieces; the batch script then reads its job's `memory.events` (the cgroup two levels above its own task cgroup, `.../job_<id>`).
Holds when all of: `sacct` reports the step `<id>.0` `OUT_OF_MEMORY`; the job's `memory.events` `oom_kill` is at least 1; the node's kernel journal for the job's window has a `Memory cgroup out of memory` line whose `task_memcg` contains `job_<id>`; and `slurmd`'s `MainPID` read by a root job after the repetition equals the one read before B2 began, with the node not `DOWN`.

**B3 — limits and the pending reason**, on the GPU nodes, jobs sleeping 60 s:
- B3a: account `acct-a` with `GrpTRES=gres/gpu=1`; two jobs each `--gres=gpu:1` under it. Holds when the second is `PENDING` with reason `AssocGrpGRES` within 30 s of submission, and starts within 60 s of the first ending.
- B3b: QoS `qone` with `MaxJobsPerUser=1`; two CPU-only jobs under it. Holds when the second is `PENDING` with reason `QOSMaxJobsPerUserLimit` within 30 s, and starts within 60 s of the first ending.

**B4 — drain, requeue, resume**, once:
1. A reference run of the trainer, 60 steps, on `gpu2`, records its final parameters' SHA-256.
2. `gpu2` is drained by hand (`b4-hold`) so the run starts on `gpu1`; the run is submitted `--requeue --gres=gpu:1`, 60 steps of 1 s; once its log shows step 20 checkpointed, `gpu2` is resumed and `gpu1`'s signal file is rewritten with `DCGM_FI_DEV_XID_ERRORS` 79.
- B4a: holds when `gpu1` is `DRAIN` with a reason containing `DCGM_FI_DEV_XID_ERRORS=79` within 30 s of the write.
- B4b: holds when the job's `RestartCnt` is 1 and its second attempt ran on `gpu2`.
- B4c: holds when the second attempt's first step is one more than the step of the newest checkpoint whose `LATEST` rename the first attempt logged before the requeue, and the job ends `COMPLETED` with step 60 logged once in that attempt.
- B4d: holds when the final parameters' SHA-256 equals the reference run's. If it does not, the largest absolute difference is reported beside "did not hold"; CUDA on the same model of card with deterministic algorithms should repeat bit for bit, and that expectation is what this tests.

## What makes a check INVALID or the session VOID

- A worker whose `nvidia-smi` does not list exactly one A10G, or Slurm versions that differ between nodes, or `scontrol show config` not showing `CgroupPlugin = cgroup/v2`: every check VOID.
- `/shared` not written and read back from each worker before the checks: every check VOID.
- Bring-up not complete by its deadline: every check NOTRUN, and the session records why.
- A check that cannot reach its deadline is NOTRUN, never shortened.
- Head-to-worker clock offset above 2 s (`chronyc tracking` on each, recorded): the timing rules of B3 and B4a are INVALID, the others stand.

## Cost, read by the price gate before anything is bought

| item | cap | hours (to the 4,900 s wait) | upper bound |
|---|---|---|---|
| 2 × `g5.xlarge` Spot | max price $0.80/h each (On-Demand on record $1.237/h) | 1.36 | $2.18 |
| 1 × `t3.medium` Spot | max price $0.06/h | 1.36 | $0.08 |
| EBS gp3, 120 + 120 + 30 GB at $0.0912/GB-month | — | 1.36 | $0.05 |
| 3 public IPv4 at $0.005/h | — | 1.36 | $0.02 |
| **total** | | | **$2.33** |

Expected at the Spot prices of 2026-11-07 ($0.574–0.593/h for `g5.xlarge`, $0.015–0.018/h for `t3.medium`) and about 1.1 h: **about $1.3**.
This is far under the $25–40 the plan estimated for a four-day Slurm-on-EC2 effort; the plan priced longer sessions and more nodes, and this design keeps only what the four questions need.
The runner refuses a launch when no zone offers both types under their caps, and when the G and VT Spot quota is below 8 vCPU.

## Before anything is bought (refusals)

A dirty tree; `SESSION_CONFIRM` not `yes`; either AMI ID not pinned or not the named image; credentials not for `gpu-lab`, or expiring within 120 minutes; the termination sweeper not `Active` with its rule `ENABLED rate(5 minutes)` and at least 4 clean runs in the last 30 minutes; an earlier instance of this purpose still live; a caller-set override of any registered constant.
The nightly EKS destroy workflow does not touch these instances (they are not in any Terraform state), so its window does not apply.

## Termination chain

1. The runner's EXIT, INT and TERM traps terminate every instance it launched and reconcile any launch whose answer was lost by its client token (`hack/lib/spot-run.sh`), and say `TERMINATION UNCONFIRMED` per instance otherwise.
2. Each instance shuts itself down at T0 + 4,500 s, and, before T0 is known, at its own boot + 4,500 s; shutdown terminates (one-time Spot, `instance-initiated-shutdown-behavior=terminate`).
3. The termination sweeper terminates any instance past its `study-deadline` tag.

## What it licenses, and what it does not

It licenses statements about Slurm 23.11.4 as Ubuntu 24.04 packages it, on two A10G nodes and a CPU head, under cgroup v2: what confinement, limits, drain and requeue did there.
Not: Slurm 24.x or a source build, scale, fair-share or backfill under load, `slurmctld` failover, multi-node NCCL jobs, a real hardware fault (the signal is written), or how long a real fleet takes to drain.

## Revisions before the run

(Each round of the pre-purchase review is recorded here.)
