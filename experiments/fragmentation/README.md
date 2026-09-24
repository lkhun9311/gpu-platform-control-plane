# Node-level GPU fragmentation: the results

The pre-registration is `docs/superpowers/specs/2026-09-24-node-level-gpu-fragmentation.md`, written before
any trial ran. This page reports what happened against the bars it fixed. Raw evidence is under `ex/`
(gitignored); the curated figures are here.

## The headline

**A 2-GPU job stayed Pending with 2 GPUs free — and the platform reported it as `Running` the whole time.**

That second half is the finding. It is not a fragmentation quirk: the same false `Running` appears whenever
the Pod cannot be placed, including plain capacity shortage.

## The four states, 25 trials, zero invalid

Two worker nodes, 2 simulated GPUs each. Holders are 1-GPU Kueue-admitted sleepers pinned by
`kubernetes.io/hostname`. The target is one `MLTrainingJob` asking for 2 GPUs.

| arm | headroom | `ΣF` | `maxF` | quota | outcome | bar |
|---|---|---:|---:|---:|---|---|
| **P** packed | `(2,0)` | 2 | 2 | 4 | `scheduled` **5/5** | met |
| **F** fragmented | `(1,1)` | 2 | 1 | 4 | `fragmentation` **5/5** | met |
| **Q** quota-short | `(2,0)` | 2 | 2 | 3 | `quota-shortage` **5/5** | met |
| **S** aggregate-short | `(1,0)` | 1 | 1 | 5 | `aggregate-shortage` **5/5** | met |

**P and F differ in one character** — the hostname in one holder's `nodeSelector`. Identical capacity,
quota, holder count, image, lifetime and identical `ΣF = 2`. The outcome still flips. Distribution is the
only variable left, so H1 and H2 hold.

The classifier separated all three states with no cross-assignment (H3). Q never produced a Pod at all. F
and S produced the *same* scheduler message — `0/3 nodes are available: 1 node(s) had untolerated taint …,
2 Insufficient nvidia.com/gpu` — and were told apart only by `ΣF`, which is exactly why the message alone is
not a diagnosis.

## H4: the control plane reports a job it never placed as `Running`

| arm | seconds the Pod was unschedulable | seconds the CR said `Running` |
|---|---:|---:|
| F | 145 | **145** |
| S | 145 | **145** |
| P | 0 | 0 |
| Q | 0 (no Pod) | 0 |

`computeMLTJPhase` returns `Running` when `job.Status.Active > 0`
(`internal/controller/mltrainingjob_controller.go:288`), and Kubernetes' `JobStatus.Active` is documented as
*the number of pending and running Pods*. A Pod that no node will accept is pending, so it counts.

Two consequences, and the second is worse:

- an operator watching the CR — or a dashboard built on it — sees a healthy running job while nothing has
  been placed;
- `admitToRunningSeconds` is recorded from that transition, so the platform's own admission-to-running
  latency metric is measured from a moment that did not happen.

This was predicted from the code before the run and then observed in 10 of 10 unschedulable trials.

## R: repacking fixed it without adding anything

| measurement | result |
|---|---|
| middle state after the replica lands, before the original is deleted | `free = (1,0)`, `ΣF = 1` — **5/5** |
| target scheduled after the original is deleted | **5/5**, at ~74 s |
| same Pod, not a replacement | **5/5**, one distinct `pod_uid` throughout |
| background demand | 2 → 3 → 2 |
| capacity | 4 throughout |

So H5 holds **for a stateless fixture**: moving one holder, without adding a GPU or a unit of quota,
converted an unschedulable job into a running one.

**A limitation in how the middle state was captured.** The 1-second sampler is paused while the intervention
runs, so `ΣF = 1` appears in the runner's own log — measured directly at that moment, 5/5 — and not in
`timeline-R-*.jsonl`, which jumps from `fragmentation` at t≈60 s to `scheduled` at t≈74 s. The evidence is
real but it is a point measurement, not a continuous one.

## R took three attempts, and the first two reported success

Recorded because the failure mode is the interesting part: **both false passes printed `R: 5/5 scheduled`,
and both were only exposed by reading the timeline instead of the summary.**

| attempt | what the summary said | what was actually happening |
|---|---|---|
| 1 | `5/5 scheduled` | the runner's `case` grouped `P \| R)`, so both holders started on one node. There was no fragmentation to repair and the target scheduled at t = 0.3 s |
| 2 | `5/5 scheduled` | at quota 4 the replica could never be admitted (1+1+2 already reserved). `wait_holder_running` timed out for 120 s, `\|\| true` swallowed it, the original was deleted anyway — so the job ran because demand **dropped** from 2 to 1. Capacity reduction, the one thing this arm exists to rule out |
| 3 | `5/5 scheduled` | the middle state is present, `ΣF = 1`, same Pod UID, demand preserved |

The fixes were: R's quota raised 4 → 5 (recorded as a deviation in the pre-registration, with the bar left
unchanged); a replica that never runs now **invalidates** the trial instead of being stepped over; the
middle state is asserted rather than assumed; and `pod_uid` is recorded so "the same Pod" can be checked.

## What this licenses

**Does:** on a Kubernetes cluster with Kueue, a 2-GPU job was held unschedulable with 2 GPUs free in
aggregate; quota shortage, node-level fragmentation and aggregate shortage were separated by pre-registered
controls with no misclassification in 25 trials; demand-preserving repacking recovered the same Pod; and the
platform reported the unplaced job as `Running` in every unschedulable trial, with its latency metric taken
from that false transition.

**Does not:** real NVIDIA hardware, CUDA, GPU memory, MIG, NVLink or PCIe topology; utilisation, throughput
or cost; multi-Pod gang scheduling or multi-node DDP; Kueue topology-aware scheduling; automatic detection
or automatic repacking, neither of which exists here; checkpoint-preserving migration of live training — the
thing moved was a `pause` container.

No paid GPU time was used.
