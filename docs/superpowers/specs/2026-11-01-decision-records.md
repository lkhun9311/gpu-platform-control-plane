# Three decision records: sharing a card, laying out DDP ranks, and admitting GPU batch work

Written 2026-10-31 from the records listed under "Sources", dated 2026-11-01.
Each record says what was decided, what measurement the decision rests on, what would reverse it, and what was never measured.
Every figure is copied from a committed record and cited next to itself as `[KEY:line]`, where KEY names a file in "Sources".
The third record is different in kind from the first two: nothing in it has been measured yet, and it says so.

## ADR 1 — Sharing one GPU between tenants: MPS, time-slicing or MIG

**Status:** decided as far as the measurements reach; MPS undecided; MIG not judgeable on this account.

### Context

The platform's sharing modes are `exclusive`, `timeSlicing`, `mps` and `sharedInstance` [G04:58].
The experiment matrix planned time-slicing (S2) and MPS (S3) as separate scenarios on one card [G04:94-95].
The tenant that matters is a latency-sensitive premium tenant beside a long-context contender [G04:59-70].

### Options

| option | what it divides | what this project could run |
|---|---|---|
| time-slicing | GPU time between Pods, KV caches separate [G04:42] | measured on one A10G |
| MPS | concurrent kernels from separate processes through one control daemon | capability only: does it engage at all |
| MIG | hardware partitions | not runnable: neither card this account may launch supports MIG [W:211-213] |

### Decision, as measured

**Do not offer any card-sharing mode as a substitute for isolation without naming the load it holds at.**
Offer time-slicing only where the premium tail target is shown to hold at the expected request rate.
Leave MPS unoffered until its latency arm is measured.

### Evidence

- The isolated baseline, one shared engine and time-slicing, at the pre-freeze load (68-token premium prompts, two repetitions [W:86] [W:89]): premium TTFT p99 69.5 ms, 1,892.2 ms (27.2x) and 1,007.5 ms (14.5x) [W:97-99].
- The same three arms at the frozen load, fifteen cells, five repetitions: 174.268 ms, 4,000.579 ms and **14,868.019 ms** — time-slicing 3.7x worse than the single shared engine [W:102-104]; the registered answer became INCONCLUSIVE [W:105].
- The pre-freeze and frozen tables are different loads and cannot be combined [W:93].
- At the frozen contract, one competing tenant on a shared engine cost 23.0x [W:158], and that run bought no split-card arm [W:180].
- On a ladder with the contender held byte-identical, time-slicing met the 139 ms premium target at 1.16 req/s (123.7 ms) and 2.31 req/s (130.3 ms), and breached only at 4.61 req/s [W:195-197].
- The mechanism: one contending prompt occupies the engine for about 1.03 s, and the premium tail budget is a tenth of that [W:200-201]; when the target is shorter than one contending request's service time, neither sharing mode measured reached it at the loads measured [W:201-203].
- MPS: a registered capability check passed on run 3, 2026-10-24 [MPS:406] [MPS:408]: one MPS server and two vLLM engine processes of type `M+C`, at 9,776 MiB each [MPS:436-437], and the replay served 249 rows, every one HTTP 200 [MPS:440].
  That pass licenses MPS engaging on that card, AMI, driver and plugin version, not any latency figure [MPS:128-129] [W:556].
- MIG: the control plane's accounting for partition-shaped resources was tested with two simulated profiles, 20 trials [W:329-332]; a job was admitted by quota and then refused by the scheduler with the other profile free [W:342-344].
  Nothing about real MIG, memory or fault isolation [W:348].

### What would flip it

- An MPS latency arm, at the frozen load, that keeps the premium tail inside its target: MPS would then be offered at that load.
- A card that supports MIG, allowed by the account's instance-family policy: MIG would then need its own measurement before any statement [W:213].
- A premium target longer than one contending request's service time, or a load below the 2.31 req/s rung: time-slicing then has a measured operating point [W:196] [W:200-203].

### What was not measured

- MPS latency or throughput under contention: unjudged, not failed [W:556].
- Real MIG, memory isolation or fault isolation [W:211-215] [W:348].
- Larger cards, and other prompt-length distributions [W:214-215].
- Whether the timeout change between the two time-slicing runs explains part of their disagreement: not established [W:107-109].

## ADR 2 — Data-parallel training on one node: one Pod with four GPUs, or four Pods with one

**Status:** decided for one g5.12xlarge, by a registered run with every job valid [NCCL:10].

### Context

`spec.distributed` gives every rank its own Pod; a job without it is one Pod that may start a launcher [NCCL:21].
A distributed job's command must start exactly one process per Pod [API:85], so two Pods of two GPUs are not expressible today [NCCL:74].
Ranks in separate Pods have separate hostnames and network namespaces, so NCCL may treat them as separate hosts on one node [NCCL:22].

### Options

| arm | renders as |
|---|---|
| one Pod, four GPUs | `gpuCount: 4`, no `distributed`, `torchrun --standalone --nproc-per-node=4` [NCCL:68] [NCCL:70] |
| four Pods, one GPU each | `gpuCount: 1`, `distributed.worldSize: 4`, one process per Pod [NCCL:69] [NCCL:71] |

### Decision, as measured

**On one node, run data-parallel training as one Pod holding all the node's GPUs.**
Use `distributed` when ranks must span nodes.

### Evidence

Run 5, 2026-10-29 [NCCL:538]: one g5.12xlarge, `i-0b66cbb2a8ab182d6` in ap-northeast-2d [NCCL:542]; four A10Gs, PCIe only [NCCL:28], no NVLink [NCCL:43]; five smoke and 25 registered jobs, every one valid [NCCL:543].

Topology: every pair of cards PHB by `topo -m`, and every pair NS, peer reads not supported, by `topo -p2p r` [NCCL:547].
Transport: every rank in the one-Pod arms logged SHM, every rank in the four-Pod arms logged NET, and the stack set no NCCL variable of its own [NCCL:549].

All-reduce bus bandwidth, GB/s, median of five jobs [NCCL:551]:

| size | one Pod of four | four Pods of one | source |
|---|---:|---:|---|
| 1 MiB | 3.21 | 0.81 | [NCCL:555] |
| 4 MiB | 2.95 | 1.34 | [NCCL:556] |
| 16 MiB | 3.05 | 1.54 | [NCCL:557] |
| 64 MiB | 3.07 | 1.62 | [NCCL:558] |
| 256 MiB | 3.06 | 1.67 | [NCCL:559] |

NVIDIA's nccl-tests in the one-Pod layout reported 3.88, 3.24, 3.32, 3.27 and 3.05 GB/s at the same sizes [NCCL:555-559]; its ratio to torch's figure is reported and not judged [NCCL:571].

DDP step, synthetic model, ms, median of five jobs' medians [NCCL:561]:

| | one Pod of four | four Pods of one | source |
|---|---:|---:|---|
| synced step | 133.87 | 249.00 | [NCCL:565] |
| local step, no synchronisation | 3.85 | 3.98 | [NCCL:566] |
| synchronisation cost | 130.02 | 245.02 | [NCCL:567] |

Verdicts:
- **V1:** one Pod of four reached higher bus bandwidth at every size, 1 to 256 MiB; every one of its five figures exceeded every one of the four-Pod figures [NCCL:574].
  The rule's false-separation bound over the five sizes is at most 3.97% [NCCL:94].
- **V2:** one Pod of four had the shorter synced step, by the same complete-separation rule [NCCL:575].
- **V3:** one Pod of four had the smaller synchronisation cost [NCCL:576].
- **V4:** where the layouts differed, the one-Pod ranks logged SHM and the four-Pod ranks NET; that accompanied the difference and is **not established as its cause**, because the layouts also differ in launcher, namespaces and CPU scheduling [NCCL:188] [NCCL:577].

### What would flip it

- A job larger than one node: one Pod cannot span nodes, so `distributed` is the only layout.
- Four-Pod ranks that NCCL no longer treats as separate hosts, so they log SHM or P2P: the transport difference would then be gone, and the comparison would need to be run again rather than assumed.
- A card or instance where peer-to-peer is supported, or NVLink is present: this run's topology was PHB with peer reads not supported [NCCL:547], so it says nothing about either [NCCL:214].
- A failure model that prefers small Pods: this record weighs throughput only.

### What was not measured

- That the transport caused the difference [NCCL:218].
- NVLink, InfiniBand, RoCE, RDMA, GPUDirect RDMA or EFA [NCCL:214-216].
- More than one node [NCCL:217]; the two-node NCCL run of `experiments/multi-pod-ddp/` has no throughput figure [DDP:168].
- Any real model's training throughput: the DDP model is synthetic, sized for its gradient [NCCL:219].
- Another card, instance type, driver, NCCL version or tuning [NCCL:220]; nccl-tests across Pods [NCCL:221].
- Two Pods of two GPUs, which the distributed contract does not allow [NCCL:74].

## ADR 3 — Admitting GPU batch work: Kueue or Slurm

**Status: a pre-measurement decision. Slurm has not been run in this project.**
Nothing below is a measured comparison, and no sentence here should be read as a verdict on Slurm.

### Context

The platform is Kubernetes-native, and its GPU admission is Kueue v0.18.3, pinned [GF:187].
A `GPUQuotaPolicy` with training quota creates a per-tenant ClusterQueue and LocalQueue [DDP:24] [KQ:60-62].
Every tenant ClusterQueue joins one cohort, `gpu-platform`, so idle quota can be lent and reclaimed by preemption [KQ:39-42] [KQ:71], with `reclaimWithinCohort: Any` and `withinClusterQueue: LowerPriority` [KQ:87-88].

### Options

| option | where it stands in this project |
|---|---|
| Kueue on Kubernetes | built, and measured in the rows below |
| Slurm, standalone or beside Kubernetes | not deployed, not measured |

### Decision, before measurement

**Keep Kueue as the platform's admission layer, and treat this decision as provisional until the comparison below has run.**
The reason is not that Kueue was shown better than Slurm.
It is that the rest of the platform is written against Kueue's objects — the quota policy renders ClusterQueues [KQ:68-89], and the GPU-fault reaction deactivates Workloads [GF:57] — and every admission behaviour this project has measured is Kueue's.

### What has been measured about Kueue here, as input to the comparison

- Reclaim within a cohort is only as correct as the workload's SIGTERM handling, which the queue cannot observe: a victim that ignored SIGTERM ran to completion, and a 40-second job occupied 83 seconds [W:264-266] [TC:52].
- Kueue admits quota, not placement: a two-rank job was admitted with one rank unplaceable and held its 2-GPU quota for 599 s to the end of the window [W:453]; `waitForPodsReady` with a 120 s timeout bounded each attempt to about 121 s [W:455].
- Deactivating a Workload is a fast drain lever for one job: on the GPU-fault path's `xid` arm, Kueue's eviction decision, the Job's suspension and the quota release each came at a median upper end of 0.774 s after the deactivation [V:9] [V:8] [V:11], and re-admission at 1.000 s after the release [V:12].

### What a planned comparison would measure

Each dimension is a question for a run, not a claim about either system.

| dimension | Kueue side, as built | what the run would ask of Slurm |
|---|---|---|
| policy meaning | ClusterQueues with nominal GPU quota in one shared cohort, reclaim by preemption [KQ:71-88] | how accounts, QoS and fair-share express the same tenant quotas, borrowing and reclaim, and whether the same tenant mix produces the same admissions |
| drain and requeue | the node is tainted and the job's Workload deactivated, then reactivated and re-admitted [GF:56-62] | what draining a node does to a running job, whether it is requeued automatically, and the time from the fault signal to the job running elsewhere, measured with the same hop stamps |
| partial placement | quota admission can precede placement; Finding 10 measured the consequence [W:453] [W:461] | whether a multi-node job can start with only part of its allocation, and what the scheduler reports while it waits |
| signal handling under preemption | a workload ignoring SIGTERM holds its device past its reclaim [W:266] | what preemption or requeue sends a job, and how long a job that ignores it holds its GPUs |
| operator burden | CRDs, a controller and Kueue's configuration, deployed through Argo CD | the daemons, configuration and accounting database an operator must run, and what a node fault asks of the operator by hand |

### What would flip it

- If the comparison shows Slurm admits whole multi-node allocations without the partial-placement hold that Finding 10 measured, at a comparable operator cost, the decision should be reopened for multi-node training.
- If the target environment already runs Slurm for training, and Kubernetes only for serving, the platform's job would become integration rather than replacement.

### What was not measured

- Everything about Slurm in this project.
- Kueue at more than two ranks, with other jobs in the cohort, or with `blockAdmission` [W:467].
- Kueue under many tenants or at the scale of thousands of GPUs: every Kueue measurement here is on one or two nodes.

## Sources

| KEY | file |
|---|---|
| W | `docs/11_WHAT_THIS_MEASURED.md` |
| G04 | `docs/04_GPU_GOVERNANCE_AND_ISOLATION.md` |
| MPS | `docs/superpowers/specs/2026-09-25-can-mps-engage-on-this-card-at-all.md` |
| NCCL | `docs/superpowers/specs/2026-10-27-four-gpu-nccl-design.md` |
| API | `api/v1/mltrainingjob_types.go` |
| DDP | `experiments/multi-pod-ddp/README.md` |
| GF | `docs/superpowers/specs/2026-10-27-gpu-fault-reaction-design.md` |
| V | `hack/gpu-fault/2026-10-27-run2/verdict.txt` |
| TC | `docs/superpowers/specs/2026-08-02-queuelab-termination-contract-design.md` |
| KQ | `internal/controller/kueue_quota.go` |
