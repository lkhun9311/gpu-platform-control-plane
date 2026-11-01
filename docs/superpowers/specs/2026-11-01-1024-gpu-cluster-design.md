# A 1,024-GPU training cluster across two sites: a design

Written 2026-11-01.
**This is a design, not experience.**
This project never operated a GPU fleet, and says so in its own record: the "I operated a GPU platform" row of "What this project is not entitled to claim" answers "No" (`docs/11_WHAT_THIS_MEASURED.md:487`, `docs/11_WHAT_THIS_MEASURED.md:493`).
The largest thing it measured on real GPUs is one node of four A10Gs, and its account cannot launch the accelerators this design assumes: P-family quotas are 0 (`infra/aws/org/scp/README.md:167`).
So every per-node or per-job number below is either cited to a measurement in this repository, with the file and line, or marked **ASSUMPTION** with its value.
Where a measurement from four GPUs is used to reason about 1,024, the note says why the step does not hold linearly.

The role this is written for operates thousands of GPUs across data centers with Kubernetes and Slurm, diagnoses GPU failures for fast recovery, manages GPU quota, and supports distributed training of autonomous-driving models.
The design is sized at 1,024 GPUs because that is large enough for every one of those duties to have arithmetic, and small enough that the arithmetic can be checked by hand.

## The parameters, and where each comes from

Every later section uses these values and no others.
A row marked ASSUMPTION is a value I chose for the design; changing it changes the arithmetic, not the structure.

| parameter | value | source |
|---|---|---|
| GPUs | 1,024 | the brief |
| nodes | 128 of 8 GPUs | the brief |
| sites | 2, 64 nodes each | ASSUMPTION: an even split |
| GPU and intra-node link | H100-class SXM, 8 GPUs on an NVSwitch | ASSUMPTION; nothing NVLink was measured here, the A10G has none (`docs/superpowers/specs/2026-10-27-four-gpu-nccl-design.md:43`) |
| inter-node fabric per node | 8 × 400 Gb/s RDMA (InfiniBand NDR or EFA-class), one NIC per GPU, rail-optimised | ASSUMPTION; the only multi-GPU node used here supported one EFA interface (`docs/superpowers/specs/2026-10-27-four-gpu-nccl-design.md:42`), and its result licenses nothing about EFA (`docs/superpowers/specs/2026-10-27-four-gpu-nccl-design.md:582`) |
| scalable unit (SU) | 32 nodes, 256 GPUs, under one set of 8 rail leaf switches | ASSUMPTION |
| rack | 4 nodes, one power feed pair, one management switch | ASSUMPTION, set by power density |
| site interconnect (DCI) | 2 × 100 Gb/s, 25 GB/s usable | ASSUMPTION |
| per-GPU interruption rate λ | 5 × 10⁻⁴ per GPU-day, every cause that takes a node out of a job | ASSUMPTION, of the order Meta reports for Llama 3 pre-training (419 unexpected interruptions in 54 days on 16,384 GPUs, about 4.7 × 10⁻⁴); that paper is not re-read for this note |
| repair: soft | 50% of failures, back in 4 h after reset and burn-in | ASSUMPTION |
| repair: hardware | 50% of failures, back in 5 days after part swap and burn-in | ASSUMPTION |
| reference model | 10 × 10⁹ parameters, mixed precision, Adam | ASSUMPTION; a driving world model or a large end-to-end planner, larger than most perception backbones |
| checkpoint bytes per parameter | 14: bf16 weights 2, fp32 master 4, Adam moments 8 | ASSUMPTION, the usual mixed-precision layout |
| reference job | 32 nodes, 256 GPUs, one site | ASSUMPTION: one SU's worth, the largest job the training pool runs routinely |
| synchronous checkpoint stall C | 60 s | ASSUMPTION, a target the storage must meet |
| restart cost R | 10 min, from fault to the job stepping again | ASSUMPTION; its parts are in "Recovery time" |
| training-data read per node | 0.5 GB/s, multi-camera video and lidar | ASSUMPTION |
| fault detect, Xid 79 injected into DCGM's cache, one node | median 1.627 s (1.051 to 1.758), upper ends of truncation intervals over five injections, not point times | measured, `hack/gpu-fault/2026-10-27-run2/verdict.txt:4` |
| fault value to job bound elsewhere, Xid 79 injected | median 2.502 s (1.926 to 2.634), upper ends of truncation intervals over five injections, not point times | measured, `hack/gpu-fault/2026-10-27-run2/verdict.txt:5` |
| DDP synced step, 4 × A10G, one Pod (SHM) vs four Pods (NET), synthetic model, forward and backward only, no optimizer step | 133.87 ms vs 249.00 ms | measured, `docs/superpowers/specs/2026-10-27-four-gpu-nccl-design.md:565` |

## Shape

Two sites, each with 64 GPU nodes in two scalable units of 32.
Each site is a self-contained training cluster: its own Kubernetes control plane, its own Slurm controller pair, its own storage for checkpoints and data.
What crosses the DCI is checkpoints, datasets, accounting and telemetry, never a collective.
A job lives in one site, so the largest possible job is sized by a site's training pool, not by the fleet; the reference job of 32 nodes is one SU's worth.

## Failure domains and blast radius

A synchronous data-parallel job stops when any one of its ranks stops, so the blast radius of a fault on a training job is the whole job, whatever the domain.
What changes with the domain is how many jobs, how many spare nodes it consumes, and whether the nodes come back without a person.

| domain | what fails | what is lost | jobs hit | capacity out | recovery |
|---|---|---|---|---|---|
| GPU | Xid 79 (fell off the bus), uncorrectable ECC, row-remap failure, NVLink errors | the node: the job uses all 8 GPUs and the NVSwitch domain, so one bad GPU retires the node from training | every job on the node; for the reference job, all 256 GPUs restart from the last checkpoint | 1 node | quarantine, drain, reset or swap, burn-in, re-admission |
| node | PSU, CPU, memory, NIC, kernel, kubelet or slurmd | the node | as above | 1 node | as above |
| rack | power feed, management switch | 4 nodes (ASSUMPTION) | at most 4 jobs, usually one | 4 nodes, 32 GPUs: this exceeds the spare budget of one SU, see "Spare capacity" | facilities; the nodes come back only through burn-in |
| rail leaf switch | one of 8 leaves in an SU | one rail of 32 nodes: every node keeps 7 of 8 NICs | every multi-node job in the SU slows; NCCL may route the rail's traffic through PXN or fail the communicator, depending on configuration | bandwidth, not nodes | swap the switch; the jobs are not drained unless they fail |
| spine | inter-SU links | cross-SU bandwidth | jobs spanning both SUs of a site | bandwidth | placement keeps a job inside one SU where it fits; a job larger than an SU, or one given a replacement node from the other SU, is the job a spine fault hits |
| site | power, cooling, DCI loss | 64 nodes, 512 GPUs | every job at the site | half the fleet | jobs restart at the other site from the replicated checkpoint, within that site's quota and capacity |

Two consequences shape the rest of the design.
A rail-leaf fault degrades 32 nodes at once rather than removing any, so a health system that only counts dead nodes misses it; step-time per job is the signal that sees it.
A rack is a correlated failure of 4 nodes, so spare nodes for one job must not all sit in one rack.

## Control-plane placement, and what each part depends on

| component | where | depends on | when it is down, what stops | when it is down, what keeps running |
|---|---|---|---|---|
| Kubernetes API and etcd | per site, 3 members on CPU servers in 3 racks on different power feeds | etcd quorum (2 of 3), the site's management network | new Pods, Kueue admission, every taint and eviction this design automates | every running Pod; the kubelet does not need the API to keep a container alive |
| Kueue | per site, in that site's cluster, 2 replicas with leader election | the API server; its admission webhook | admission and preemption on Kubernetes; with the webhook's failure policy set to fail, Job creation is refused rather than created unmanaged | admitted workloads |
| this repository's operator (fault latch, taint, deactivation) | per site, 2 replicas with leader election | the API server, the DCGM exporter on each node | automatic quarantine on Kubernetes nodes | running Pods, including on a faulty node, until the job fails by itself |
| `slurmctld` pair | per site: primary and backup in different racks | shared state directory for both, reachable from both | new scheduling and requeue at that site, until the backup takes over | every running job and step; `slurmd` keeps them alive |
| `slurmdbd` and its database | one, at site A, with a replica at site B | the database; the DCI for site B's controller | new accounts and limit changes; fair-share accounting goes stale | scheduling at both sites: a controller spools accounting records while the daemon is unreachable |
| DCGM exporter, node health checks | every node, as a DaemonSet and as the Slurm node health check | the node, the driver, the host engine | detection on that node | the node's jobs |

**Why one Kubernetes cluster per site and not one stretched across both.**
etcd needs a majority; with two sites, the majority lives in one, and losing that site takes the other site's control plane with it.
A stretched cluster is defensible only with a third, low-latency witness site, and even then it couples one site's admission to the DCI's latency.
Two clusters cost a second control plane and a quota split, and buy a site loss that stops one site's admission rather than both.

**Why a control-plane outage does not need its own fault path.**
While the API server or `slurmctld` is down, nothing is placed anywhere, so a faulty node that cannot be quarantined also cannot receive new work.
The job already on it fails by itself, through an NCCL timeout or a crashed rank, and is requeued once the controller is back.
The cost of the outage is the requeue delay, not a job placed on a bad card.

## Scheduler split: a design choice, and when it flips

**The choice.** Slurm runs the large synchronous training jobs; Kubernetes with Kueue runs everything else.
Starting split, per site: 48 nodes (384 GPUs) to Slurm, 16 nodes (128 GPUs) to Kubernetes, which is 768 and 256 GPUs across the fleet.
The 75 : 25 ratio is an ASSUMPTION about the workload mix: that three quarters of GPU-hours are multi-node training of 8 nodes or more.

| workload | scheduler | why |
|---|---|---|
| multi-node pre-training and fine-tuning, 8 to 48 nodes | Slurm | gang allocation is the default unit, topology-aware placement (tree or block plugin) keeps a job inside an SU, `srun` with PMIx starts ranks in a known order, and the researchers who write these jobs already use `sbatch` |
| single-node training, hyperparameter sweeps | Kubernetes + Kueue | many short jobs, container images as the unit, quota borrowing between teams |
| evaluation on logged drives, closed-loop simulation, data processing | Kubernetes + Kueue | pipelines, services and retries are Kubernetes' native shape; much of it is CPU-heavy with a GPU per Pod |
| inference for labelling and evaluation services | Kubernetes | long-running services with health checks and rollouts |

A node belongs to exactly one scheduler at a time.
Running `slurmd` and the kubelet with the device plugin on the same GPUs would let both allocate the same card.
Moving a node between pools is a drain on one side and an uncordon on the other, done by a person or a reviewed change, not by either scheduler.

**What would flip it.**
- If Kueue's topology-aware scheduling, with JobSet or this repository's `MLTrainingJob` in its `distributed` form, places a 32-node job with the same measured step time as Slurm's topology placement, and the training code already ships in containers, move the training pool to Kubernetes and run one scheduler.
  The condition is a measured A/B on the fleet's own model, not a feature list; this repository has measured gang behaviour only on two ranks with simulated devices (`docs/11_WHAT_THIS_MEASURED.md:453`, `docs/11_WHAT_THIS_MEASURED.md:455`).
- If jobs of 8 nodes or more fall below half of GPU-hours for a quarter, shift nodes from Slurm to Kubernetes in units of 4 (one rack, so the pools never share a rack's power domain).
- If Kubernetes demand is diurnal, for example evaluation by day, lend a fixed block of nodes to Slurm overnight by scheduled drain and return them by a reservation that ends before the morning.
- If both pools must share nodes dynamically, run Slurm inside Kubernetes (Slinky or Soperator are the two existing projects) so that one owner holds the node and the other is a tenant; I have not run either.

**What the measurement here does and does not say about the split.**
On one g5.12xlarge, the same four A10Gs ran the same synthetic DDP step at 133.87 ms when the four ranks shared a Pod and NCCL used SHM, and 249.00 ms when four Pods of one rank used NET (`docs/superpowers/specs/2026-10-27-four-gpu-nccl-design.md:565`), a factor of 1.86.
What carries over is the direction: how the scheduler lays ranks out decides the step time, so placement is part of the scheduler choice, not an afterthought.
What does not carry over is the factor.
Those cards have no NVLink and no peer reads, every pair is PHB (`docs/superpowers/specs/2026-10-27-four-gpu-nccl-design.md:547`), and the best bus bandwidth was about 3 GB/s (`docs/superpowers/specs/2026-10-27-four-gpu-nccl-design.md:559`); an NVSwitch node is, by its vendor's specification and not by any measurement here, about two orders of magnitude faster inside, and RDMA between nodes is a different path from the NET transport measured, which ran between Pods on one node.
The page itself licenses nothing about NVLink, RDMA, EFA, more than one node or a real model (`docs/superpowers/specs/2026-10-27-four-gpu-nccl-design.md:582`).

## Quota and fairness

**One entitlement, rendered into two schedulers.**
Each team has one GPU entitlement per site, kept in Git; a controller renders it into a Kueue `ClusterQueue` for the Kubernetes pool and a Slurm account limit for the Slurm pool.
This repository already does the first half for one cluster: a `GPUQuotaPolicy` becomes a `ClusterQueue` in the single cohort `gpu-platform`, with `ReclaimWithinCohort` set to any and lower-priority preemption within a queue (`internal/controller/kueue_quota.go:42`, `internal/controller/kueue_quota.go:87-88`).
The Slurm half is design only.

| concept | Kueue (Kubernetes pool) | Slurm (training pool) |
|---|---|---|
| organisation | cohort per organisation, for example perception, planning, simulation | parent account per organisation |
| team | `ClusterQueue` per team, one `LocalQueue` per namespace | child account per team; users are associations under it |
| guaranteed share | nominal quota in `nvidia.com/gpu` | fair-share shares, plus a group GPU limit (GrpTRES) as the hard cap |
| borrowing | borrowing limit; idle nominal quota lent within the cohort | no borrowing as such: an idle team's share lowers others' fair-share penalty, so they run sooner |
| reclaim | `ReclaimWithinCohort`: the owner's submission preempts the borrower | a high-priority QoS preempts a scavenger QoS (preempt/qos), with requeue |
| priority tiers | WorkloadPriorityClass | QoS: `normal`, `high` (capped, for deadlines), `scavenger` (preemptible, runs on spares) |
| decay | none: quota is counted at admission and released at the end | usage decays with a half-life (ASSUMPTION: 7 days), so heavy use last month does not starve a team today |

The two systems do not mean the same thing by "quota", and the design does not pretend they do.
Kueue's is an admission-time ledger: a workload either fits under the queue's nominal plus borrowing or waits.
Slurm's fair share is a priority signal over usage history; only the group limit is a ledger.
So a team's guarantee is stated as two numbers, GPUs on Kubernetes and GPUs on Slurm, and a report sums GPU-hours across both against the entitlement.

**A half-placed gang holds its whole quota.**
Measured here on kind: a two-rank job with one rank unplaceable held its quota of 2 for the whole 600 s window when Kueue's `waitForPodsReady` was off, and for about 121 s per attempt with a 120 s timeout (`docs/11_WHAT_THIS_MEASURED.md:453`, `docs/11_WHAT_THIS_MEASURED.md:455`).
A 16-node job, a whole site's Kubernetes pool under this split, would hold 128 GPUs of quota that way while it cannot start, so the Kubernetes pool runs with `waitForPodsReady` on and a timeout set from the measured image-pull and rendezvous time of the largest job, not from the two-rank figure.
Slurm allocates the gang whole or not at all, so it has no equivalent hold.

## Network

- **Inside a node:** NVLink through NVSwitch carries tensor-parallel and the intra-node part of every collective.
  Tensor parallelism stays inside the node; it is never placed across nodes.
- **Between nodes in a site:** the rail-optimised RDMA fabric carries data-parallel and pipeline collectives.
  NIC *k* of every node in an SU sits on rail leaf *k*, so the ring or tree NCCL builds between same-index GPUs stays on one leaf.
  The scheduler's topology plugin is given the SU and leaf layout, and the reference job is placed in as few SUs as fit.
- **Between sites:** checkpoints, dataset replication, accounting and telemetry only.

**Why collectives never cross the DCI, in arithmetic.**
The reference model's bf16 gradient is 10 × 10⁹ × 2 bytes = 20 GB.
A ring all-reduce moves about 2 × 20 = 40 GB per rank per step; even a hierarchical scheme that reduces inside each site first must still exchange that order of bytes across the DCI.
At 25 GB/s (ASSUMPTION) that is at least 1.6 s of DCI time per step, against one node's 8 × 400 Gb/s = 400 GB/s into its own fabric (ASSUMPTION), sixteen times the whole DCI.
A job that spanned sites would run at the speed of the DCI and share its fate with both sites.

**What measurement here contributes.** Only the direction, as in the scheduler section: on the A10G node, rank layout alone changed the synchronisation cost from 130.02 ms to 245.02 ms (`docs/superpowers/specs/2026-10-27-four-gpu-nccl-design.md:567`).
That a transport difference accompanied it is an observation, not a cause the page established (`docs/superpowers/specs/2026-10-27-four-gpu-nccl-design.md:577`), and nothing measured here is NVLink or RDMA.

## Checkpoint storage

| quantity | arithmetic | value |
|---|---|---|
| checkpoint size, reference model | 10 × 10⁹ parameters × 14 bytes | 140 GB |
| burst write rate for a 60 s stall | 140 GB / 60 s | 2.33 GB/s per job |
| per node, sharded across the job's 32 nodes | 2.33 GB/s / 32 | 73 MB/s per node |
| average write rate at a 30 min interval | 140 GB / 1,800 s | 78 MB/s per job |
| two jobs of this model size per site checkpointing at once (ASSUMPTION) | 2 × 2.33 GB/s | 4.7 GB/s burst per site |
| restore at a 10 GB/s read rate (ASSUMPTION) | 140 GB / 10 GB/s | 14 s |
| retention: last 3 plus one daily, per job | 4 × 140 GB | 560 GB |
| cross-site replication of each checkpoint at 5 GB/s, 20% of the DCI (ASSUMPTION) | 140 GB / 5 GB/s | 28 s |
| training-data read, one site | 64 nodes × 0.5 GB/s (ASSUMPTION) | 32 GB/s sustained |

Two things follow.
The checkpoint is a burst problem, not a bandwidth problem: 78 MB/s on average, 2.33 GB/s for one minute, so the file system is sized for concurrent bursts and metadata rate, and asynchronous checkpointing (copy to host memory, write in the background) cuts the stall C to the copy.
And for autonomous-driving data the sustained read of 32 GB/s per site dwarfs the checkpoint traffic and exceeds the 25 GB/s DCI, so each site holds its own replica of the training data rather than reading across.

**The checkpoint interval, from the failure rate.**
The reference job has 32 nodes at 8 × λ = 4 × 10⁻³ interruptions per node-day, so 0.128 interruptions per day, a mean of 187.5 h between them (all from the ASSUMPTION rows).
Young's approximation, τ = √(2 × C × MTBF), gives √(2 × 60 s × 675,000 s) = 9,000 s, 2.5 h.
The fraction of time lost is about C/τ + (τ/2 + R)/MTBF:

| interval | stall C/τ | lost work and restart (τ/2 + R)/MTBF | total |
|---|---|---|---|
| 30 min | 3.3% | 0.2% | 3.6% |
| 1 h | 1.7% | 0.4% | 2.0% |
| 2.5 h (Young) | 0.7% | 0.8% | 1.4% |

The curve is flat near its minimum, so the interval is set by what a team will tolerate losing, between 1 and 2.5 h, and not tuned to the minute.
Asynchronous checkpointing lowers C and with it τ; the table is for the synchronous stall assumed.
Without a checkpoint the lost work is everything since the job began: the fault study's job kept none, and its lost work was its whole runtime, 15 s at the median (`hack/gpu-fault/2026-10-27-run2/verdict.txt:10`, `docs/superpowers/specs/2026-10-27-gpu-fault-reaction-design.md:120`).
A resume that restores weights, optimiser, step and data order has been verified here on kind and CPU, at difference 0 from an uninterrupted run (`docs/11_WHAT_THIS_MEASURED.md:496`); its checkpoint was bytes, not a model whose write time matters (`experiments/checkpoint-resume/README.md:106`).

## The GPU health pipeline

The stages, and which of them this repository has measured:

| stage | what happens | measured here | at fleet scale |
|---|---|---|---|
| 1. detect | DCGM exporter on each node; the operator scrapes each one every 1 s, and a reading older than 5 s is not fresh (`docs/superpowers/specs/2026-10-27-gpu-fault-reaction-design.md:47`) | Xid 79 injected into DCGM's cache: detect median 1.627 s; uncorrectable ECC: 1.448 s; both upper ends of truncation intervals, five injections each (`hack/gpu-fault/2026-10-27-run2/verdict.txt:4`, `hack/gpu-fault/2026-10-27-run2/verdict.txt:17`) | the same per node; 128 scrapes a second from one operator is not measured |
| 2. quarantine | the node is tainted so nothing new lands on it; Slurm drains it with a reason | latch to taint 0.008 s (`hack/gpu-fault/2026-10-27-run2/verdict.txt:15`) | identical mechanism |
| 3. drain the job | the workload is evicted and its quota released | taint to eviction request 0.093 s, to quota release 0.774 s (`hack/gpu-fault/2026-10-27-run2/verdict.txt:6`, `hack/gpu-fault/2026-10-27-run2/verdict.txt:11`) | a real trainer must stop; before this repository's trainer fix a rank blocked in rendezvous held its device 28.9 s past the quota release (`docs/11_WHAT_THIS_MEASURED.md:461`), and after it, released within the same second (`docs/11_WHAT_THIS_MEASURED.md:476`) |
| 4. requeue from checkpoint | Kueue re-admits; Slurm requeues the job on spare nodes | re-admission 1.000 s (the upper end of an interval between two whole-second times, so anywhere from 0 to 1 s), value-to-placement 2.502 s (an upper end too) (`hack/gpu-fault/2026-10-27-run2/verdict.txt:12`, `hack/gpu-fault/2026-10-27-run2/verdict.txt:5`), for a one-GPU `busybox` job with no checkpoint (`docs/superpowers/specs/2026-10-27-gpu-fault-reaction-design.md:108`) that re-landed on a simulated device (`docs/superpowers/specs/2026-10-27-gpu-fault-reaction-design.md:192`) | dominated by R, 10 min (ASSUMPTION), not by detection |
| 5. repair | reset the GPU or reboot; if the fault recurs, swap the part | not measured | soft 4 h, hardware 5 days (ASSUMPTION) |
| 6. burn-in | DCGM diagnostic at its longest level, a single-node NCCL all-reduce against a floor, a multi-node test beside known-good nodes, a short training-like stress | not measured | the gate for stage 7 |
| 7. re-admission | the node returns to its pool | not measured | by a person, or by a burn-in pass record, never by a reading of zero |

**What the measurement licenses.** Every fault there was a value injected into DCGM's cache on one card, not a hardware fault; one node, one job at a time (`docs/superpowers/specs/2026-10-27-gpu-fault-reaction-design.md:386`).
It says the platform's path from a DCGM value to a moved job takes seconds and stays quiet on a benign single-bit ECC value and on no change, 5 of 5 each (`hack/gpu-fault/2026-10-27-run2/verdict.txt:29-32`); that is a count, not a false-positive rate.
It says nothing about what a real Xid does to NVML or the device plugin, or about many nodes faulting at once (`docs/superpowers/specs/2026-10-27-gpu-fault-reaction-design.md:233-235`).
The design's conclusion from it is narrow: detection latency is not where a 256-GPU job's recovery time goes, so the pipeline is tuned for not draining healthy nodes and for a short restart, not for a faster scrape.

**Recovery time, decomposed.** R = 10 min is an ASSUMPTION whose parts are: detection and drain, seconds (the order measured above); requeue onto spares, seconds if spares are idle or preemptible; image pull and container start on 32 nodes, minutes unless images are pre-pulled to every node; NCCL initialisation at 256 ranks, tens of seconds to minutes (not measured anywhere here); checkpoint load, 14 s at the assumed read rate.

### What must not be automatic

- **Re-admitting a node because the exporter read zero.**
  The Xid field is a gauge of the last Xid seen (`docs/superpowers/specs/2026-10-27-gpu-fault-reaction-design.md:28`), and volatile ECC counters reset with the driver, so after a reset or a reboot a card that is still faulty reads zero.
  A zero says the fault is not being reported now; it does not say the card passed anything.
  This repository's operator does clear its latch on a fresh reading with every fault field at zero (`internal/controller/nodehealth_gpufault.go:149-151`), and the exporter was given the quarantine toleration so that it can return to deliver that reading (`config/dcgm-exporter/daemonset.yaml:50-56`).
  That rule fits the study it was built for, where the zero is the injected reset; in this design it is replaced by a burn-in pass record or an operator's acknowledgement, which the operator already supports (`internal/controller/nodehealth_gpufault.go:61-62`).
- **Clearing or setting a fault on missing data.** A stale signal makes health Unknown, never True, and keeps a latched fault latched; measured here as "stale-healthy PASS" (`hack/gpu-fault/2026-10-27-run2/verdict.txt:33`).
  The latched case failed in that run because the platform's own taint kept the exporter from returning (`hack/gpu-fault/2026-10-27-run2/verdict.txt:34`, `docs/superpowers/specs/2026-10-27-gpu-fault-reaction-design.md:382-383`); the exporter now tolerates the taint, but the device plugin still tolerates only `nvidia.com/gpu` (`config/nvidia-device-plugin/daemonset.yaml:41-44`).
  At fleet scale every diagnostic agent tolerates the quarantine taint, because a quarantined node is exactly where diagnosis has to run.
- **Draining past a rate.** Under the assumed rate a site sees 0.256 node interruptions a day, 0.011 an hour, so three automatic quarantines in one hour at one site has a probability of about 2 × 10⁻⁷ by chance.
  Three in an hour is therefore treated as a common cause (a switch, a firmware or driver rollout, the exporter itself) and stops automatic quarantine at that site and pages a person; a broken exporter must not be able to drain a site.
- **Moving nodes between Slurm and Kubernetes**, retiring a part, or shrinking a job's world size: each is a decision with a cost someone owns.

## Spare capacity

Expected interruptions, from the ASSUMPTION rows:

| scope | GPUs | interruptions per day | one every |
|---|---|---|---|
| fleet | 1,024 | 1,024 × 5 × 10⁻⁴ = 0.512 | 1.95 days |
| site | 512 | 0.256 | 3.9 days |
| reference job | 256 | 0.128 | 7.8 days, 187.5 h |

Nodes out at once: failures arrive at 0.512 per day and each node stays out 0.5 × 4 h + 0.5 × 5 days = 2.58 days on average.
Nodes out of service then follow a Poisson distribution with mean 0.512 × 2.58 = 1.32 for the fleet (an M/G/∞ queue, whose occupancy is Poisson whatever the repair-time distribution).

| pool | mean nodes out | P(out ≤ 1) | P(≤ 2) | P(≤ 3) | P(≤ 4) |
|---|---|---|---|---|---|
| fleet, 128 nodes | 1.32 | 0.619 | 0.852 | 0.955 | 0.989 |
| one site, 64 | 0.66 | 0.858 | 0.970 | 0.995 | 0.999 |
| one site's Slurm pool, 48 | 0.50 | 0.911 | 0.986 | 0.998 | 1.000 |
| one SU, 32 | 0.33 | 0.956 | 0.995 | 1.000 | 1.000 |

**How many spares keep a job's world size.** A job keeps its node count after a failure if its pool holds as many spares as nodes are out.
- Pooled over a site's Slurm pool of 48 nodes, 2 spares cover 98.6% of the time and 3 cover 99.8%, in the Poisson model above with assumed independent failures and assumed repair times, not a measured availability.
  A 32-node job then restarts at full size, but a replacement may sit in the other SU, behind the spine.
- Kept under one SU's leaves, 2 spares per SU cover 99.5% each in the same model; with an SU of 32 nodes, that makes the largest topology-local job 30 nodes, not 32.
  Topology locality therefore costs either two nodes of job size per SU or a step-time penalty after a failure, and which is cheaper is a measurement on the fleet's own model, not something this note can settle.
- Spares are not idle: they run `scavenger` QoS or lowest-priority Kueue work, preempted when a training job needs them, so their cost is a preemption, not dark GPUs.
- A rack failure takes 4 nodes at once, which no per-SU budget of 2 covers; that case is a wait or a shrink, decided by a person, and the design says so rather than sizing spares for it.

Shrinking instead of waiting is allowed only for jobs whose training code changes the data-parallel degree without changing the global batch semantics; it is a per-team opt-in, never a scheduler default.

## Monitoring and alerting

| signal | source | automatic action | person |
|---|---|---|---|
| Xid in the fault set, uncorrectable ECC, row-remap failure | DCGM exporter | quarantine and drain, under the rate breaker | ticket for repair |
| correctable ECC rate rising, retired pages, thermal or power throttling | DCGM exporter | none | ticket; a trend, not an event |
| exporter stale or absent | the scrape | health Unknown; no quarantine, no clear | page if a site's share of Unknown nodes passes 5% (ASSUMPTION) |
| exporter frozen but answering | a collection-timestamp check, not built here: the exporter carries no collection timestamp, so a frozen cache reads fresh (`docs/superpowers/specs/2026-10-27-gpu-fault-reaction-design.md:237`) | Unknown | ticket |
| RDMA port errors, link down, a rail leaf down | fabric counters | none | page: it degrades 32 nodes |
| step time per job above its own rolling median by 10% (ASSUMPTION) | the training loop's metrics | none | the job owner and on-call; one slow rank slows a synchronous job, which no node-level check reports |
| NCCL timeout or communicator abort | job logs | Slurm or Kueue requeues | ticket naming the ranks' nodes for burn-in |
| quarantines per site per hour ≥ 3 | the operator | automation stops | page |
| checkpoint write longer than 2 × C | the training loop | none | ticket for storage |
| etcd fsync latency, API latency, Kueue pending and admission latency, `slurmctld` responsiveness | control plane | none | page on sustained breach |
| quota: GPU-hours per team against entitlement, Kueue borrowing, Slurm fair-share | both schedulers | none | weekly report |

## What this design borrows from measurement here and what it only assumes

**Borrowed from measurement, each with what it cannot carry.**

| figure | file:line | used for | what it cannot carry to 1,024 GPUs |
|---|---|---|---|
| synced step 133.87 ms (one Pod, SHM) vs 249.00 ms (four Pods, NET), 4 × A10G | `docs/superpowers/specs/2026-10-27-four-gpu-nccl-design.md:565` | that rank layout decides step time, so placement belongs to the scheduler | the 1.86 factor: PCIe-only cards, no NVLink, no RDMA, one node, a synthetic model |
| synchronisation cost 130.02 ms vs 245.02 ms | `docs/superpowers/specs/2026-10-27-four-gpu-nccl-design.md:567` | the same direction | the same |
| bus bandwidth about 3.06 GB/s (one Pod) and 1.67 GB/s (four Pods) at 256 MiB | `docs/superpowers/specs/2026-10-27-four-gpu-nccl-design.md:559` | to say what the cards measured were, and why they are not this design's nodes | any bandwidth figure for an NVSwitch node or an RDMA fabric |
| every card pair PHB, no peer reads | `docs/superpowers/specs/2026-10-27-four-gpu-nccl-design.md:547` | the same | the same |
| detect 1.627 s (Xid), 1.448 s (ECC), medians of interval upper ends, faults injected into DCGM's cache | `hack/gpu-fault/2026-10-27-run2/verdict.txt:4`, `hack/gpu-fault/2026-10-27-run2/verdict.txt:17` | that detection is seconds and R is not set by it | a real fault through NVML; 128 nodes scraped by one operator; fault storms |
| value to job placed 2.502 s; taint 0.008 s; eviction request 0.093 s; quota release 0.774 s; re-admission 1.000 s; all medians of interval upper ends, re-admission between whole-second stamps | `hack/gpu-fault/2026-10-27-run2/verdict.txt:5`, `hack/gpu-fault/2026-10-27-run2/verdict.txt:15`, `hack/gpu-fault/2026-10-27-run2/verdict.txt:6`, `hack/gpu-fault/2026-10-27-run2/verdict.txt:11`, `hack/gpu-fault/2026-10-27-run2/verdict.txt:12` | the shape of stages 2 to 4 | a 32-node job's stop, pull, rendezvous and checkpoint load, which are the 10 min |
| lost work 15 s with no checkpoint | `hack/gpu-fault/2026-10-27-run2/verdict.txt:10` | that without a checkpoint the loss is the runtime | anything about a checkpointed job's loss |
| benign and no-change arms quiet, 5 of 5 each | `hack/gpu-fault/2026-10-27-run2/verdict.txt:29-32` | that the latch distinguishes a correctable from an uncorrectable ECC value | a false-positive rate |
| stale-healthy PASS; stale-latched FAIL from the taint toleration | `hack/gpu-fault/2026-10-27-run2/verdict.txt:33-34` | the rule that missing data neither sets nor clears, and that diagnostic agents tolerate the quarantine taint | — |
| a half-placed two-rank job held its quota 599 s without, about 121 s per attempt with, a readiness timeout | `docs/11_WHAT_THIS_MEASURED.md:453`, `docs/11_WHAT_THIS_MEASURED.md:455` | `waitForPodsReady` on in the Kubernetes pool | the right timeout for a 32-node gang; simulated devices, two ranks |
| a rank kept its device 28.9 s past quota release before the trainer fix, and released within the second after | `docs/11_WHAT_THIS_MEASURED.md:461`, `docs/11_WHAT_THIS_MEASURED.md:476` | that the trainer's signal handling is part of drain time | real GPUs or NCCL teardown |
| one cohort with reclaim, lower-priority preemption within a queue | `internal/controller/kueue_quota.go:42`, `internal/controller/kueue_quota.go:87-88` | the Kueue half of the quota mapping | the Slurm half, which is design only |

**Only assumed**, every one a value I chose: H100-class SXM nodes with NVSwitch; 8 × 400 Gb/s RDMA per node, rail-optimised; SUs of 32 nodes; racks of 4; a 25 GB/s DCI; λ = 5 × 10⁻⁴ interruptions per GPU-day; repair 50% in 4 h and 50% in 5 days; a 10 × 10⁹-parameter reference model at 14 bytes per parameter; a 32-node reference job; C = 60 s; R = 10 min; a 10 GB/s restore read; 5 GB/s for checkpoint replication; 0.5 GB/s of training data per node; a 75 : 25 Slurm to Kubernetes split; a 7-day fair-share half-life; alert thresholds of 5% Unknown nodes, 10% step-time regression and 3 quarantines per hour.

**Not claimed:** that this project has run a multi-node GPU job beyond one synchronised step on two single-GPU nodes (`docs/11_WHAT_THIS_MEASURED.md:496`), measured NVLink, RDMA or EFA, run Slurm anywhere but a single-host container lab with fake GPUs (`experiments/slurm-lab/README.md`), operated anything for longer than a session, or observed a real GPU hardware fault.
The arithmetic above is checkable by hand from the parameter table; the operational judgements in it are what I would bring to a fleet, to be corrected by the people who run one.
