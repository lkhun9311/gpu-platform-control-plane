# Node-level GPU fragmentation: what the control plane sees when the GPUs are there and the job still waits

> **Pre-registration. Written before any trial was run.** Arms, bars, invalidation rules and the stopping
> rule below are fixed. Nothing here is a result.

Two model reviews (`gpt-5.6-sol`, `gpt-6-astra`) were asked to design this independently and agreed on the
shape; where they differed, the narrower option was taken and the reason recorded. Which model answered was
confirmed from the CLI's own rollout records, not from the models' self-reports.

---

## The question

A tenant asks for a 2-GPU job. The cluster has 2 GPUs free and the quota to admit it. The job does not run.

That is not a quota problem and not a capacity problem, and the distinction matters because the three have
different fixes: buy more quota, buy more hardware, or move what is already there. This experiment asks
whether the control plane can tell them apart, and what it says while it cannot.

## What is deliberately not being measured

Real NVIDIA hardware, CUDA, GPU memory, MIG, NVLink or PCIe topology. GPU utilisation, throughput, training
performance or cost. Multi-Pod gang scheduling, multi-node DDP, Kueue topology-aware scheduling. Automatic
detection or automatic repacking — neither exists in this repository. Checkpoint-preserving migration.

The cost claim is exactly one sentence: **no paid GPU time is used.** kind and simulated devices only.

---

## Two premises that were wrong, and are corrected here

Both were reported by me from the live cluster and contradicted by the repository.

**"Every node advertises `FAKE_GPU_COUNT=2`."** The committed DaemonSet sets **1**
(`config/device-plugin/daemonset.yaml:60`). The live value of 2 comes from `hack/m6-kind-e2e.sh:107`
overwriting it with `kubectl set env` after deployment. An experiment built on the live value would not
reproduce from a fresh apply, so this pre-registration records the advertised count as a **fixture to be
set and verified at the start of every trial**, not as an environmental given.

**"The cluster already has a `gpu-premium` ClusterQueue with `nvidia.com/gpu: 2`."** That queue exists live
and is declared nowhere in the repository. It is not reused. Every queue object this experiment needs is
created by the experiment.

## A third premise that shapes the design

The target Pod carries no toleration — `BuildJob` sets none (`internal/controller/mltrainingjob_controller.go:164`)
— and `platform-control-plane` carries `node-role.kubernetes.io/control-plane:NoSchedule`. So the advertised
total of 6 GPUs is not 6 GPUs the target can use: **the eligible set is the two worker nodes, 4 GPUs.**

Rather than inject a toleration through the ResourceFlavor to reach a third node, the experiment is run on
the two workers. Fewer moving parts, and the taint stops being a confound instead of becoming one.

---

## Definitions

Let `R = 2` be the target's GPU request. Let `E` be the set of nodes the target is eligible for — here the
two workers, verified per trial rather than assumed.

For each node `i` in `E`, measured immediately before the target is submitted and again during observation:

| symbol | meaning |
|---|---|
| `C_i` | `status.allocatable["nvidia.com/gpu"]` |
| `U_i` | sum of GPU requests of **non-terminal** Pods bound to node `i`, across all namespaces |
| `F_i` | `C_i - U_i`, the scheduling headroom |
| `ΣF` | `sum(F_i)` over `E` |
| `maxF` | `max(F_i)` over `E` |

`F_i` is headroom by **request**, not utilisation, and `allocatable` alone is not headroom.

### The three states, separated by evidence rather than by the word "Pending"

| state | Workload | Job | target Pod | arithmetic |
|---|---|---|---|---|
| **quota shortage** | `Admitted ≠ True`, message names insufficient quota | `spec.suspend: true` | **does not exist** | — |
| **fragmentation** | `QuotaReserved` and `Admitted` both True | `spec.suspend: false` | exists, `PodScheduled=False`, reason `Unschedulable`, scheduler reports insufficient `nvidia.com/gpu` | **`ΣF ≥ R` and `maxF < R`** |
| **aggregate shortage** | as fragmentation | as fragmentation | as fragmentation | **`ΣF < R`** |

An `Insufficient nvidia.com/gpu` event alone cannot separate the last two — that is the whole point. Any
trial where the Pod is unschedulable for a reason outside this table (taint, affinity, PVC, scheduling gate,
image, webhook) is classified `unknown` and invalidated, not folded into a bucket.

---

## Hypotheses

- **H1 — the gap exists.** With quota reserved and `ΣF ≥ R`, a target with `maxF < R` does not get scheduled.
- **H2 — distribution is the cause.** Holding capacity, holder count, holder size, image and quota
  identical, and changing *only which node each holder sits on*, flips the outcome between scheduled and
  not.
- **H3 — the classifier is exclusive.** The evidence table above assigns each of the four control arms to
  exactly one state, with no cross-assignment.
- **H4 — the control plane reports the wrong thing.** During fragmentation the `MLTrainingJob` reports
  **`Running`**, because `computeMLTJPhase` returns `Running` when `job.Status.Active > 0`
  (`internal/controller/mltrainingjob_controller.go:288`) and Kubernetes' `JobStatus.Active` counts *pending*
  Pods as well as running ones. If so, `admitToRunningSeconds` is recorded from a transition that never
  happened.
- **H5 — repacking is sufficient.** Moving one holder, without adding capacity or quota, converts the
  fragmented state into a scheduled one.

H4 is the hypothesis this experiment exists for. H1 and H2 establish the condition under which H4 can be
observed at all.

---

## Arms

Two eligible worker nodes, each with `C_i = 2`, so 4 GPUs total. Holders are 1-GPU sleepers submitted as
Kueue-managed suspended `batch/v1` Jobs with a `kubernetes.io/hostname` nodeSelector — Kueue-managed so that
no one can object that the fragmentation was caused by Pods the quota system never saw.

| arm | holders | `F` vector | `ΣF` | `maxF` | CQ quota | pre-registered expectation |
|---|---|---|---|---|---|---|
| **P** packed (positive control) | 2 on `worker2` | `(2,0)` | 2 | 2 | 4 | admitted **and scheduled** |
| **F** fragmented (treatment) | 1 on `worker`, 1 on `worker2` | `(1,1)` | 2 | 1 | 4 | admitted, **never scheduled** |
| **Q** quota-short (control) | 2 on `worker2` | `(2,0)` | 2 | 2 | **3** | **not admitted**, no target Pod |
| **S** aggregate-short (control) | 2 on `worker2`, 1 on `worker` | `(1,0)` | 1 | 1 | **5** | admitted, not scheduled, `ΣF < R` |
| **R** repack (intervention) | starts as F | `(1,1)` → `(1,0)` → `(2,0)` | 2 → 1 → 2 | 1 → 1 → 2 | **5** (amended, see below) | pending, **still pending**, then scheduled |

**P and F differ in exactly one character** — the hostname in one holder's nodeSelector. Same capacity, same
quota, same holder count, same image, same lifetime, same `ΣF`. If the outcome differs, distribution is the
only thing it can be.

Q's quota of 3 and S's quota of 5 are deliberate mis-sizings, stated here so they are not later mistaken for
the design's natural parameters.

**R's middle state is the interesting one.** The replica is created on `worker2` *before* the original on
`worker` is deleted, so headroom passes through `(1,0)` — `ΣF = 1`, which is aggregate shortage, and the
target must still be pending there. Only after the original is deleted does headroom become `(2,0)` and the
target schedule. Total headroom goes `2 → 1 → 2`: the intervention never adds capacity. This is a stateless
sleeper being replaced, not a training job being migrated, and the write-up must not blur the two.

---

## Amendment, 2026-09-24, after the first two attempts at R

Recorded here rather than quietly applied, because it changes a number this document fixed in advance.

**R's quota is raised from 4 to 5.** At 4 the intervention is arithmetically impossible: the two holders
reserve 2 and the target reserves 2, so there is no quota left for a replica. The run waited 120 s for a Job
that could never be admitted, the failure was swallowed by a `|| true`, the original holder was deleted
anyway, and the target scheduled — **because background demand had dropped from 2 to 1.** That is capacity
reduction, the one thing this arm exists to rule out, and it was reported as `R: 5/5 scheduled`.

The bar is unchanged and is now checkable rather than assumed:

- the middle state must show `ΣF = 1`, and a trial whose middle state still reads 2 is **invalid**, not a pass;
- a replica that never reaches Running **invalidates** the trial instead of being stepped over;
- the timeline records `pod_uid`, so "the same Pod was scheduled" can be verified rather than asserted.

With quota 5, background demand goes 2 → 3 → 2 while capacity stays at 4, so headroom still goes 2 → 1 → 2
and the intervention adds nothing.

**An earlier defect in the same arm**, fixed before this one: R was grouped with P in the runner's case
statement, so both holders started on the same node and the target scheduled at t = 0.3 s. R was P wearing
R's name for five trials, and the summary said it passed.

Both were found by reading the timeline rather than the summary. The summary said `scheduled` all ten times.

## Trial procedure

1. Delete every object from the previous trial; wait until the ClusterQueue reports zero reserved and no GPU
   Pod exists in any namespace.
2. Verify the fixture: both workers `Ready`, uncordoned, `allocatable["nvidia.com/gpu"] == 2`, and the
   device-plugin DaemonSet's `FAKE_GPU_COUNT` is what this experiment set it to.
3. Submit holders. Wait until each is **Running on its intended node** and the headroom vector is stable for
   10 s.
4. Submit one `MLTrainingJob`: `gpuCount: 2`, `parallelism: 1`, `completions: 1`, no `stateVolume`, image
   pinned by digest and pre-loaded on both nodes.
5. Watch and snapshot at 1 s until `t0 + 180 s`.
6. For R only: at `tA + 60 s` create the replica, confirm it runs and hold 10 s, then delete the original.

Order is counterbalanced: five blocks, each rotating `P F Q S R` by one position, so every arm appears once
in every position. **n = 5 per arm, 25 trials.** No early stopping on success; all five blocks are completed.

## Recorded evidence

Per trial: node allocatable/taints/conditions; every GPU-requesting Pod in every namespace with its node;
the CR → Job → Workload → Pod UID chain; Workload conditions and reserved quantities; Job `spec.suspend` and
conditions; Pod `PodScheduled` condition, `nodeName`, phase, container states, scheduler messages and events;
ClusterQueue spec and usage; `MLTrainingJob` phase and `admitToRunningSeconds`; image digests; the Kueue
deployment's image, args and ConfigMap.

Derived: `submit → admitted`, `admitted → PodScheduled`, `PodScheduled → container running`, `ΣF`, `maxF`,
the duration of the fragmented state, **GPU-seconds reserved but not placed**, and for H4 the duration for
which the CR said `Running` while no Pod was scheduled.

Times are diagnostic. They are not an SLO and no percentile is reported from n = 5.

## Bars, fixed now

| arm | bar |
|---|---|
| P | 5/5 scheduled within 60 s of admission; classifier says fragmentation **0/5** |
| F | 5/5 admitted within 60 s, then unscheduled for the whole window with `ΣF = 2` and `maxF = 1` throughout; classifier says fragmentation **5/5** |
| Q | 5/5 never admitted, Job stays suspended, no target Pod; classifier says fragmentation **0/5** |
| S | 5/5 admitted then unscheduled with `ΣF = 1`; classifier says fragmentation **0/5** |
| R | 5/5 still pending in the `(1,0)` middle state; then **the same Pod UID** scheduled within 60 s of the original holder's deletion |
| H4 | reported as measured in F and S — whatever the CR says, including if it correctly says `Admitted` |

No bar is relaxed after the fact and no arm is rescued by averaging.

## Invalidation, which is not the same as failure

**Invalid** (re-run once, at the end; a second invalidation of the same arm ends the study as inconclusive):
a node goes NotReady or changes allocatable; the simulator, Kueue or the operator restarts; the ClusterQueue
is not `Active`; a holder lands on the wrong node; an unrelated GPU Pod appears; an image pull, webhook or
watch failure unrelated to placement; a collection gap longer than 5 s.

**A result, recorded as such** (never re-run): F schedules anyway; P fails to schedule; Q produces a Pod; S
is classified as fragmentation; R fails to recover; the CR reports something other than H4 predicts.

A target that never runs inside the window is written as **"not observed running within 180 s"**, not as
"hung" and not as "permanently blocked".

## What each outcome would mean

| if | then |
|---|---|
| P schedules and F does not | H1 and H2 hold: the same free GPUs, differently placed, decide it |
| F schedules | H1/H2 refuted — the gap is not reproducible this way, and the design was wrong about the scheduler |
| P also fails | the cause is not distribution but a hidden constraint; H2 unsupported and the fixture is suspect |
| S classified as fragmentation | the classifier cannot separate aggregate shortage — a defect in the proposed diagnostic |
| Q produces a Pod | the assumed Kueue admission path is wrong, which is a finding about this platform |
| R recovers | repacking sufficed **for a stateless fixture**; nothing is shown about moving live training |
| R fails | "free two GPUs on one node" is not sufficient, and the missing condition becomes the next question |
| H4 confirmed | the platform reports `Running` for a job that has never been placed, and its own latency metric is measured from that moment |

Every branch leaves evidence. None of them leaves "the numbers looked bad".

## The sentence this may license

Before running, the honest claim is about design only:

> Pre-registered a Kubernetes/Kueue experiment separating quota shortage, node-level GPU fragmentation and
> aggregate capacity shortage, with controls that detect misclassification.

If every bar is met:

> Reproduced node-level GPU fragmentation on Kubernetes/Kueue — a 2-GPU job held Pending with 2 GPUs free in
> aggregate — separated it from quota and capacity shortage with controls, recovered it by demand-preserving
> repacking, and showed the control plane reported the job as Running throughout. kind, simulated devices,
> n = 5 per arm.

What it would not license, at any outcome:

> Built a GPU defragmentation scheduler that automatically improves utilisation for distributed training.

There is no automatic detector, no repacking controller, and no real GPU anywhere in this study.
