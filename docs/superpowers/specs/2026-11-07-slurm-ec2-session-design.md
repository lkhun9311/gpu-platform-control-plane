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

Three EC2 Spot instances in one zone of `ap-northeast-2`, account `gpu-lab` (007635145730), in the default VPC's default subnet and a security group the session creates, which admits all traffic between its own members and nothing else inbound:

| role | type | AMI | Slurm role |
|---|---|---|---|
| `head` | `t3.medium` | Canonical Ubuntu 24.04 (`ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*`, owner 099720109477), pinned by ID | `slurmctld` (configless server), `slurmdbd` with MariaDB, NFS server of `/shared`, the procedure |
| `gpu1`, `gpu2` | `g5.xlarge` (1 A10G each) | AWS Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04), pinned by ID | `slurmd` under systemd with `Restart=on-failure`, configless from `head`; `/shared` over NFS, mounted `vers=4.1,proto=tcp,hard,timeo=600,retrans=2,lookupcache=positive` |

`/shared` carries data only: the venv, the GPU signal files, the checkpoints and the evidence.
The bring-up and end signals go over the run's S3 prefix (see "The first paid attempt, and what it changed").

The Deep Learning AMI lists only GPU instance families as supported, which is why `head` runs Canonical's image; that image has no AWS CLI, so its user-data installs it from snap.
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
| 5,400 s | the checks end; each check is admitted only with its own worst case left (B1 480 s a repetition, B2 300 s, B3 540 s, B4 1,700 s), otherwise NOTRUN |
| 5,430 s | the procedure is stopped if still running; `collect.sh` ships what exists, then the diagnostics |
| 5,580 s | the evidence deadline: `collect.sh` is stopped at 5,640 s at the latest |
| 5,670 s | the sweeper's `study-deadline` tag |
| 5,700 s | every instance shuts itself down (`instance-initiated-shutdown-behavior=terminate`); the boot-relative backstop, for an instance that never learns T0, is boot + 6,600 s |
| 6,100 s | the runner's termination wait ends |

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
- A worker that cannot read `head`'s NFS token through its mount within 60 s stops before `slurmd` starts, so the bring-up misses its deadline and every check is NOTRUN; a worker token `head` cannot read on its own disk once both nodes are idle makes every check VOID.
- Bring-up not complete by its deadline: every check NOTRUN, and the session records why.
- A check that cannot reach its deadline is NOTRUN, never shortened.
- Every time a rule compares is read on `head`: its own polls and `slurmctld`'s accounting. No worker clock enters a rule, so no clock offset is checked.

## Cost, read by the price gate before anything is bought

| item | cap | hours (to the 6,100 s wait) | upper bound |
|---|---|---|---|
| 2 × `g5.xlarge` Spot | max price $0.80/h each (On-Demand on record $1.237/h) | 1.69 | $2.71 |
| 1 × `t3.medium` Spot | max price $0.06/h | 1.69 | $0.10 |
| EBS gp3, 100 + 100 + 30 GB at $0.0912/GB-month | — | 1.69 | $0.05 |
| 3 public IPv4 at $0.005/h | — | 1.69 | $0.03 |
| S3: the source (about 52 MB) and the evidence, removed at the end, otherwise expired in 30 days | — | — | under $0.01 |
| **total, normal path** | | | **$2.89** |

The worst path is longer: if the runner dies before T0 is handed over and an instance never arms its precise shutdown, the boot backstop (6,600 s) and the sweeper (the launch tag, request + 6,570 s, plus up to one 5-minute sweep) end it, about 6,870 s after the request; and in a zone that cannot hold all three, up to two instances (head and one GPU) are bought and terminated, waited for up to 300 s each, in at most two such zones.
That is $3.25 for the trio over 1.91 h at the caps, plus $0.15 for the failed zones: **the registered cap is $3.50.**
`head` is launched with `CpuCredits=standard`, so a T3 cannot add surplus-credit charges beyond its instance price.

Expected at the Spot prices of 2026-11-07 ($0.574–0.593/h for `g5.xlarge`, $0.015–0.018/h for `t3.medium`) and about 1.2 h: **about $1.5**.
This is far under the $25–40 the plan estimated for a four-day Slurm-on-EC2 effort; the plan priced longer sessions and more nodes, and this design keeps only what the four questions need.
The runner refuses a launch when no zone offers both types under their caps, and when the G and VT Spot quota is below 8 vCPU.

## Before anything is bought (refusals)

A dirty tree; `SESSION_CONFIRM` not `yes`; `SLURMEC2_REHEARSAL` set; either AMI ID not pinned or not the named image; credentials not for `gpu-lab`, or expiring within 135 minutes (read again after the uploads, when at least 111 minutes must remain); the termination sweeper not `Active` with its rule `ENABLED rate(5 minutes)` and at least 4 runs and no error summed over every 5-minute datapoint of the last 30 minutes; an earlier instance of this purpose still live; a caller-set override of any registered constant.
The nightly EKS destroy workflow does not touch these instances (they are not in any Terraform state), so its window does not apply.

## Termination chain

1. The runner's EXIT, INT and TERM traps terminate every instance it launched and reconcile any launch whose answer was lost by its client token (`hack/lib/spot-run.sh`), and say `TERMINATION UNCONFIRMED` per instance otherwise.
2. Each instance shuts itself down at T0 + 5,700 s, and, before T0 is known, at its own boot + 5,700 s; shutdown terminates (one-time Spot, `instance-initiated-shutdown-behavior=terminate`).
3. The termination sweeper terminates any instance past its `study-deadline` tag.

## What it licenses, and what it does not

It licenses statements about Slurm 23.11.4 as Ubuntu 24.04 packages it, on two A10G nodes and a CPU head, under cgroup v2: what confinement, limits, drain and requeue did there.
Not: Slurm 24.x or a source build, scale, fair-share or backfill under load, `slurmctld` failover, multi-node NCCL jobs, a real hardware fault (the signal is written), or how long a real fleet takes to drain.

## The free rehearsal

`hack/slurm-ec2-rehearsal.sh` runs the same user-data, rendered by the same function (`hack/lib/slurm-ec2.sh`), in three local systemd containers named `head`, `gpu1` and `gpu2`, against an S3 stub, and scores what comes back with the same scorer; `hack/slurm-ec2/check_rehearsal.py` states what it must show.
What differs is set only by `SLURMEC2_REHEARSAL=1` in the instance side's environment: no GPU (a device node with no driver and an `nvidia-smi` stand-in, so B1a cannot hold and B1b is INVALID, and the trainer runs on the CPU), no NFS (`/shared` is one Docker volume, because the workstation has no `nfsd` module), no shutdown, and S3 is a directory.
So the rehearsal shows the packages, the configuration, accounting, configless `slurmd`, cgroup v2 memory and device confinement, the health check, the drain and the requeue, and the S3 signal protocol against the stub; it does not show the NFS export, the GPU, or EC2.
It stays the fast gate: a change to the instance side is rehearsed here first.
`hack/test/check-slurm-ec2-session.sh` runs the paid runner against a stub `aws` for every refusal, the purchase, the zone fallback and the end; `hack/test/check-slurm-ec2-signals.sh` runs the signal protocol, the bounded retry and the mount options against a fake CLI.

## The t3 real-NFS rehearsal

The first paid attempt failed on the one path the free rehearsal never takes, NFS between separate kernels.
`SLURMEC2_MODE=nfs-rehearsal hack/slurm-ec2-session.sh` buys three `t3.medium` Spot instances with the session's own purchase, guards and teardown: `head` on its Ubuntu image, the workers on the session's pinned Deep Learning image (it launches on `t3`; a dry run was accepted on 2026-11-08), so the NFS client is the one that failed.
The mode changes only what the runner sets in one place: no G and VT quota is read, the instances stop at T0 + 2,400 s (boot + 2,700 s at the latest), the termination wait ends at T0 + 2,550 s, the bring-up ends at T0 + 1,200 s, and only B4 runs, with 1,024 MiB jobs on the CPU.
The workers carry the GPU stand-in, and every instance runs `hack/slurm-ec2/nfs-probe.sh` first: the first run's barrier, on its own export with the first run's mount options (`hard,timeo=600`, version negotiated), polled before `head` creates the marker, as an attempt to reproduce the failure.
Its cap is $1: three `t3.medium` at the $0.06 cap and two 100 GB and one 30 GB gp3 volume (at $0.0912 a GB-month) for at most 50 minutes is $0.17; at the Spot prices read on 2026-11-08 ($0.015 to $0.018 an hour) it is about $0.07.
It must show the NFS token head to worker and worker to head, the S3 signals, B4's signal replacement as each worker observed it, the `LATEST` handoff from `gpu1` to `gpu2`, and the shared venv imported on both workers.

## The first paid attempt, and what it changed

`hack/slurm-ec2-20261107T135822Z`, PR #534 at `a7714d2c`, T0 2026-11-07 14:02:16Z: every check NOTRUN, because the bring-up missed its deadline.
`head` reached the line that touched `/shared/control/CONF_READY` about 21 minutes before the deadline, `slurmctld` came up and reported both nodes not responding, and both workers ended at 14:27:16Z with "head did not write CONF_READY", `slurmd` never started.
Worker-to-head NFS worked: `head` read both workers' node lines and GPU signal files.
The cause is not established: the `touch` was not checked, and no errno, effective mount option or stat was recorded on either side.
The default negative-lookup cache (`acdirmax=60`) does not explain 21 minutes, so plain NFS caching is not the leading explanation either.
The analysis, with gpt-6-astra's and gpt-5.6-sol's readings, is in the storage repository under `engineering/2026-11-08-slurm-ec2-nfs-barrier/`.

What changed, so the session no longer depends on that cause:

- **The bring-up and end signals go over S3**, under the run's prefix: `control/CONF_READY` (head, `ready`), `control/CONF_ACK-gpuN` (each worker, `acked`) and `control/END` (head, `end`).
  Each is a JSON payload of schema 1, the run id, T0, the producer and the phase, and the reader refuses one whose any field differs.
  `CONF_READY` also carries a random token head wrote on NFS; each worker must read it through its mount within 60 s and writes it back, and head reads both back on its own disk.
  Every AWS call is bounded (`timeout`, connect 3 s, read 10 s, `AWS_MAX_ATTEMPTS=1`); a missing key is "not yet", any other error, a 403 among them, is an error, and five in a row stop the wait; a file left by an earlier download is never read after a failed one.
- **`slurmd` runs under a systemd drop-in, `Restart=on-failure`**, still configless; `head` still waits for both nodes `IDLE`, so an ACK is a diagnostic, not the bring-up's evidence.
- **Every write is checked:** the shared directories are made, and checked, before the export; `exportfs` is checked; a bounded retry reads its deadline before and after each attempt and bounds each attempt by the time left.
- **The mount** pins `vers=4.1` and adds `lookupcache=positive`, so a cached absence is revalidated on every lookup; the effective options (`findmnt`, `nfsstat -m`, `/proc/self/mountinfo`, `/etc/nfsmount.conf`) are recorded on each worker.
- **B4 is measured as registered:** B4a's 30 s still counts from `head`'s write.
  Each worker now also logs, by its own clock, when it saw its own signal file's generation (`# generation 0` at bring-up, 1 the fault, 2 the healthy value, comment lines `gpuhc.py` skips) and its SHA-256 change; no rule reads that log, as no worker clock enters a rule.
- **Each host ships its own diagnostics to S3**, every 60 s and at its end, without Slurm or NFS: phase times in UTC and monotonic seconds, each command's status and stderr, the mount, export and stat state with errno per path component, and a bounded rotating `tcpdump port 2049` capture during the bring-up.
  The runner downloads them per host; `collect.sh` no longer uses `srun` for them.

## Revisions before the run

gpt-6-astra (high, read-only) was asked only "can money be spent and the result be void, or can resources outlive the session?", without being told where to look.
Each finding was checked against the code by Claude before it was fixed.

**Round 1 (commit `8066bf99`): NO-GO, ten findings, all confirmed and fixed in `18889ed6`.**

| # | finding | fix |
|---|---|---|
| 1 P1 | `T0` sourced but not exported, so `procedure.sh`, a child process, stopped at once: every paid check VOID | `instance.sh` exports `T0` and the addresses |
| 2 P1 | workers mounted `/shared` onto a directory the Deep Learning AMI does not have | `mkdir -p` before the mount |
| 3 P1 | a failed evidence upload still wrote `DONE`, and the runner then terminated the only copy | `ship` retries and verifies the object's size with `head-object`; `DONE` records `evidence_verified`; the evidence is shipped after every check |
| 4 P1 | collection could hang past the self-shutdown, 120 s per worker, and gpu1 stayed drained after B4 | the procedure ends at T0 + 4,230 s, `collect.sh` ships what exists before any job, each worker job is bounded at 30 s, and B4 returns gpu1 to service |
| 5 P1 | `TERMINATION` set before the final loop made the trap skip instances not yet terminated | the trap terminates every launched instance not confirmed gone, per instance |
| 6 P1 | an accepted AMI could carry a second EBS volume with `DeleteOnTermination=false` | both AMIs' owners are pinned (099720109477, 898082745236) and any EBS mapping other than `/dev/sda1` is refused (both AMIs checked: root plus two instance-store entries) |
| 7 P1 | an existing bucket was trusted to expire its objects | the lifecycle rule (enabled, whole bucket, at most 30 days) and versioning (off) are read on every run, and the run's prefix is removed once the evidence is unpacked locally |
| 8 P2 | a failed `sacct`, journal or PID read was scored as a rule that did not hold | each instrument's exit status is recorded and a failed one makes the repetition INVALID |
| 9 P2 | B3 passed a second job that started before the first ended | the gap must be between 0 and 60 s, and both jobs COMPLETED |
| 10 P2 | VOID, missing evidence and a failed scorer exited 0 | the runner exits 3 for those, 1 for an unconfirmed termination, 0 only for a scored measurement |

**Round 2 (commit `3a648120`): NO-GO, seven findings, all confirmed and fixed.**

| # | finding | fix |
|---|---|---|
| 1 P1 | an interrupted multipart upload (the source is about 52 MB) is not removed by object expiry and bills indefinitely | the session writes its own bucket's lifecycle on every run with `AbortIncompleteMultipartUpload` after 1 day, and its cleanup aborts the run's open uploads |
| 2 P1 | the lifecycle check accepted a rule filtered by tag, size or `And` | only an unfiltered rule (`Filter` `{}` or `{"Prefix": ""}`, or a legacy empty `Prefix`) with both expiry and abort counts |
| 3 P1 | the registration said 120 GB per worker and the runner asked 100; a snapshot larger than the launch's volume would fail only after the head was bought | 100 GB in both places, and each image's root snapshot size is checked against its launch before anything is bought (75 GB and 8 GB on 2026-11-07) |
| 4 P1 | an existing instance profile was trusted | its role must be `slurmec2`, trust `ec2.amazonaws.com` alone and carry no attached policy, and the inline policy is written again on every run |
| 5 P2 | an earlier archive could be reported as the final one, and a run with every check INVALID exited 0 | `DONE` names the SHA-256 of the archive last verified in S3 and the runner checks its download against it; the verdict records `complete`, and the runner exits 0 only when every registered repetition was observed, 4 when some were not |
| 6 P2 | B4's `sacct`, `scontrol show job` and node polls could fail and read as rules that did not hold | their exit statuses are recorded, and a failed one makes B4 INVALID |
| 7 P2 | B4 was admitted with 1,200 s while its own waits add to about 1,570 s, and the checks could be cut by the procedure's timeout | each check is admitted only with its own worst case left, and the checks' window is 3,900 s (the self-shutdown moved from 4,500 to 5,700 s, about $0.6 more at the caps) |

**Round 3 (commit `e81f09a2`): NO-GO, seven findings, all confirmed and fixed in `4c3a4bd6`.**

| # | finding | fix |
|---|---|---|
| 1 P1 | `DONE` was written though no archive was verified, and the runner terminated the only copy | `collect.sh` keeps shipping until the evidence deadline while nothing is verified, and `DONE` says `NO-EVIDENCE` if it never was |
| 2 P1 | the packages create `slurm` with whatever uid is free, which can differ between the two images | `slurm` (1601) and `munge` (1602) are created with fixed ids before any package; an existing one with another id stops the instance; each worker records its uid and the scorer requires 1601 |
| 3 P1 | another inline policy, a condition in the trust document or a permissions boundary could deny what the session's policy allows | the trust document must equal the one-statement EC2 trust, no boundary, and `write-results` must be the only inline policy |
| 4 P2 | a truncated download or a digest mismatch still led to scoring and to the S3 copy being removed | the digest is checked first, the archive unpacked into a staging directory and moved whole, and the prefix removed only after that; otherwise it is kept and expires |
| 5 P2 | B2 admitted with 300 s while its waits add to 480 s, and `left` returned 0, which `timeout` reads as no limit | B2 admitted with 720 s; `left` never returns below 1 |
| 6 P2 | a failed `squeue` ended B3's poll as if both jobs had left, and B2's node read had no status | failed reads are recorded as such and make the check INVALID |
| 7 P2 | B2's journal window was head's clock applied to gpu2's journal | the window is gpu2's own journal cursor before and after the job |

**Round 9 (commit `91ba8fda`), under the narrowed gate: NO-GO, three blocking findings, all confirmed and fixed; one validity finding recorded.**

| # | finding | class | resolution |
|---|---|---|---|
| 1 P1 | the bucket `slurmec2-<account>` and the role `slurmec2` carry fixed names; an existing one owned by another workload would have its lifecycle and policy replaced | blocking | an existing bucket or role is changed only if it carries the tag `purpose=slurm-ec2`, which only this runner writes (on creation); otherwise the session refuses before changing anything |
| 2 P1 | the registered $2.89 did not cover the worst path (runner dead before T0, sweeper after the launch tag) or failed-zone purchases | blocking | the cap is revised to $3.50 from the first purchase, with the arithmetic above |
| 3 P2 | a T3 in Unlimited mode, its default, can bill surplus credits beyond its Spot price | blocking | `head` is launched with `CpuCredits=standard` (a new optional argument of `spot_launch`) |
| 4 P3 | a `gpu1-state.txt` that exists but holds no parseable state would score B4a as did-not-hold rather than INVALID | validity | **known limitation**, not fixed: the poll writes a state or `READ-FAILED` every second for 60 s, so an empty file means the procedure itself was cut, which `run.timeout` or the missing completion records also show; the reader of a B4a failure checks that the file holds 60 polls |

The round-8 fixes to the bring-up path (T0 admission, the worker's `late` paths) are exercised by the rehearsal only as a regression: no local harness slows a bootstrap past its deadline, so their `late` branches have not run.

**Round 8 (commit `4539aa63`): NO-GO, two P1 and two P2, all confirmed and fixed in `b9d860e4`.**

| # | finding | fix |
|---|---|---|
| 1 P1 | the quota gate read the G and VT Spot limit, not what other Spot instances in the Region already use | the vCPUs of every running or pending g* and vt* Spot instance are subtracted, and two `g5.xlarge` must fit in what is left |
| 2 P1 | an instance whose bootstrap reached T0 more than 900 s after it was VOIDed, inside the registered 1,500 s bring-up window | T0 must be a number not in the future; past the bring-up window the instance goes through `late` (NOTRUN) |
| 3 P2 | a worker timing out on the NFS mount or `CONF_READY` died VOID | both go through `late` |
| 4 P2 | B3 submitted the second job though the first was never seen RUNNING | the pair stops there, and the scorer makes it INVALID with that reason |

The owner narrowed the launch gate on 2026-11-07, after round 8: only a finding by which billed resources could outlive the session, the cap could be exceeded, or something outside the session's own resources could be touched blocks the purchase; a finding about the validity of a result is recorded here as a known limitation, and the scorer's VOID or INVALID is its backstop.

**Round 7 (commit `dc1c3d23`): NO-GO, two P1 and three P2, all confirmed and fixed in `5d07c00b`.**

| # | finding | fix |
|---|---|---|
| 1 P1 | the route check fell back to the main table whenever the associated table had no internet route, so an associated local-only table passed | the table that applies is resolved first (the associated one, the main one only when there is none), then its routes are read |
| 2 P1 | the boot backstop's 900 s allowance was also exported as `STOP_S`, so the precise T0 shutdown moved to T0 + 6,600 s | the renderer takes the precise end and the boot backstop separately and exports only the precise one; the test reads both from the rendered user-data |
| 3 P2 | B4's first attempt was not checked to be on gpu1, and the drain of gpu2 was unchecked | a failed drain, or a first attempt that did not start on gpu1, is a setup failure and makes B4 INVALID |
| 4 P2 | an allocated probe that could not import PyTorch, or a B4 with no node polls, read as observed failures | both are INVALID |
| 5 P2 | a package install that ran out of the bring-up time died VOID, on head or on a worker | a timeout (status 124) goes through `late`; a worker reports `LATE:` and head makes the session NOTRUN |

**Round 6 (commit `67452380`): NO-GO, five findings, all confirmed and fixed.**

| # | finding | fix |
|---|---|---|
| 1 P1 | a default subnet maps public addresses whatever its route table says; one with no internet route would buy three instances that cannot fetch anything | before any launch, each candidate zone's subnet must have an active `0.0.0.0/0` route to an `igw-` gateway, in its own route table or the VPC's main one; a zone without one is dropped and no zone left refuses the session (`gpu-lab`'s main table routes to `igw-070a20ca9f2b24dad`, read 2026-11-07) |
| 2 P2 | the boot-relative shutdown could fire on head before the checks ended when the workers launched later, and a failed retag left a deadline counted from the request | the boot backstop is 5,700 s plus a 900 s launch-skew allowance, and the launch tag carries the same allowance; the precise T0 backstop and the rewritten tag are unchanged |
| 3 P2 | an earlier verified upload ended collection's retry loop, so a later archive could be lost in an S3 outage | collection retries until the final archive is verified or the evidence deadline passes |
| 4 P2 | a bring-up that missed its deadline never recorded the configuration, and the scorer read that absence as a failed precondition | with `NOTRUN_ALL`, only head's own `VOID` can void the session |
| 5 P2 | B4 counted as observed when gpu2's resume or the fault write had failed | both are checked and written to `setup-failed`, which makes B4 INVALID |

**Round 5 (commit `a1a48f43`): NO-GO, five findings, all confirmed and fixed in `9da5c32b`.**
Both P1s were latent on 2026-11-07 (the bucket does not exist yet, so it will be created with S3's default AES256, and `gpu-lab` has no Recycle Bin rule for EBS volumes), and both are now refused rather than assumed.

| # | finding | fix |
|---|---|---|
| 1 P1 | a bucket encrypted with a KMS key, or carrying a bucket policy, would let the operator upload and leave the instances unable to read | the bucket must encrypt with AES256 and have no bucket policy, read before any purchase |
| 2 P1 | a Recycle Bin rule would keep the root volumes billed after the instances report terminated | any Recycle Bin rule for EBS volumes refuses the session; each instance's root volume id is recorded at launch, and a volume still present after termination makes the teardown unconfirmed (exit 1) |
| 3 P2 | a resumed run that ended FAILED made B4 INVALID instead of an observed failure | the accounting wait accepts any terminal state, and the B4 rules are scored on it |
| 4 P2 | B3's two pairs were admitted together with less time than both need | each pair is admitted alone with 340 s |
| 5 P2 | a missed bring-up deadline made the session VOID, not every check NOTRUN as registered | head writes `NOTRUN_ALL` for a deadline miss, and the scorer reports every check NOTRUN for it or for a `bringup.env` past T0 + 1,500 s |

**Round 4 (commit `b325dcb2`): NO-GO, five findings, all confirmed and fixed in `a1a48f43`.**

| # | finding | fix |
|---|---|---|
| 1 P1 | an `OUT` with a space made a run id the user-data split into two words, so every instance fetched from the wrong prefix | the run id must be one S3 key segment of `[A-Za-z0-9._-]`, refused before purchase, and the user-data renderer refuses any value that is not one shell word |
| 2 P1 | clean sweeper invocations say nothing about whether it may terminate | the sweeper's role is simulated for `ec2:TerminateInstances` on an instance carrying a `study-deadline` tag, as this session's do, and must be `allowed` (it is, read 2026-11-07; without the tag it is `implicitDeny`, as its policy intends) |
| 3 P2 | the S3 prefix was removed even when head had not verified its final archive, which may lie there unreferenced | the prefix is removed only when `DONE` says `evidence_final=yes` |
| 4 P2 | a failed `squeue` read as an empty queue, and accounting read at once could lack the record | a failed `squeue` is not completion; `sacct` is polled up to 60 s for the terminal record, and a missing record makes the check INVALID |
| 5 P2 | a bring-up finished after its deadline still admitted the checks | head stops if it finishes late, and the scorer reads `bringup.env` and makes the session VOID past T0 + 1,500 s |

**A bare `codex review --base origin/dev` (astra, high) of `921bb39b`: three findings, all confirmed and fixed in `ff8a248e`.**

| finding | fix |
|---|---|
| P2: an archive verified before head died could not be recovered, because its digest lived only on head | each upload goes to its own key, `evidence-N.tgz`, and once S3 reports it at its size, `evidence.latest` (`n=N sha256=...`) is published; the runner downloads what that names, with or without `DONE` |
| P2: an upload whose verification failed had already replaced the last verified archive | the per-upload key means a failed one never replaces a verified one |
| P2: each termination wait restarted the remaining budget, so the waits could add up past T0 + 6,100 s | all three are asked to terminate in one call, then waited for against one absolute deadline; the trap's waits share a 600 s deadline |

**Defects the local rehearsal found** (each a VOID that would have cost a purchase):

| rehearsal | defect | fix |
|---|---|---|
| `rh2` | `sacctmgr` reads `slurm.conf` to find `slurmdbd`, and there was none yet: "Could not establish a configuration source" | the cluster-wide `slurm.conf` is put in place before the accounts are made (`5214b235`) |
| `rh3` | `GrpTRES=gres/gpu=1` was refused, "no TRES known by type gres/gpu": the TRES exists only once `slurmctld` has registered with `slurmdbd` | the GPU limit is set after `slurmctld` starts, retried for 60 s (`b1cf275d`) |
| `rh4` | a worker wrote its GPU signal before head had made the directory, the write failed unnoticed, and `gpuhc.py` drained the node at `slurmd`'s start | the worker makes the directory and stops on a failed write (`921bb39b`) |

`rh2` and `rh3` also exercised the early-stop path end to end: head stopped, shipped its evidence, wrote `DONE` within about three minutes of T0, and the scorer read the session as VOID with the reason.

Found by Claude in round 1: the default security group of `gpu-lab`'s default VPC admits all TCP from `0.0.0.0/0` (read on 2026-11-07), which would have put `slurmctld` and the NFS export on the internet.
The session now creates its own group, admitting only its own members, launches all three into it (a new optional argument of `spot_launch`, `a39c955f`), and deletes it after the instances are gone.
