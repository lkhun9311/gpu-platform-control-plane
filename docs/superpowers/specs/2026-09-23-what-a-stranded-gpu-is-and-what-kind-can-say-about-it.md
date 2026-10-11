# What a stranded GPU is, and what kind can say about it — pre-registered

**Written 2026-09-23, before any code for this study exists and before any node is created for it.** The
measurement is free — it runs on a local kind cluster with fake devices and rents nothing — so the usual
reason for pre-registering (a card is about to be billed) does not apply. It is registered anyway, for the
other reason: **the arms and the reading are chosen before the numbers are visible**, and a study whose
policy comparison is decided after seeing which policy won is not a comparison.

## The gap this closes, and the one it does not

`2026-08-02-queuelab-latency-decomposition-design.md:216` lists **"fragmentation beyond a two-unit pool"**
among the things that design deliberately did not address. That was the right call then: the lab had two
workers with one device each, where fragmentation cannot occur. This page reopens it on a cluster shaped so
that it can.

What exists today measures the **time** axis of waste — `report.go` publishes discarded GPU-seconds split
into attributable, lower-bound and censored. Nothing measures the **space** axis. The code says so itself:

> `AllocatableGPU` is what the node advertises, which is **the total rather than the free amount**.
>
> — `cmd/queuelabrun/qualify.go:98`

## Definition

A GPU is **stranded** when it is unreserved and no pending workload can use it, because every pending
workload needs more contiguous devices on one node than any single node still has free.

Three things this definition deliberately is not:

- **Not idle.** A reserved device running nothing is a duty-cycle question, which the `D-full`/`D-quarter`
  arms already ask. Stranding is about what the scheduler *cannot place*, not about what the placed work
  does.
- **Not per-device utilisation.** Free is computed as `allocatable − sum(requests of admitted pods)` — a
  **reservation-based** figure. Physical occupancy is invisible to a fake device and would be a different
  claim.
- **Not VRAM fragmentation.** Splitting one card's memory between processes is the sharing study
  (`time-slicing` / `MPS` / whole-card), already measured on real A10Gs. This is about whole devices across
  nodes.

## The instrument

`cmd/gpu-simulator` already speaks the kubelet device-plugin v1beta1 gRPC API and registers a fixed number
of always-healthy fake devices (`cmd/gpu-simulator/main.go:141`). Two changes are needed and both are
plumbing rather than new mechanism:

1. **Per-node device counts.** The DaemonSet hardcodes `FAKE_GPU_COUNT: "1"`
   (`config/device-plugin/daemonset.yaml:59`) and runs everywhere, so every node advertises the same
   capacity. A cluster where every node is identical cannot strand anything that a smaller uniform cluster
   would not also strand. The count becomes per-node, selected by node label.
2. **More than two workers.** `hack/kind-config.yaml:6-7` declares two. This study needs enough nodes for a
   free-capacity vector to have interesting shapes.

**Nothing in `internal/queuelab` is extended for this.** An `Arm` there must answer `PolicyVariant`,
`StateFor`, `ContractFor`, `DutyFor` and `AssertCardinality`; a placement study has no victim, no
termination contract and no duty, so four of those five would be filled with values that mean nothing and
would then flow through the record schema and its refusals. This study gets its own tool.

## Arms

Three, and the axis is **the scheduler's scoring strategy** with the submission sequence held fixed:

| arm | what it is |
|---|---|
| `S-least` | `NodeResourcesFit` with `LeastAllocated` scoring — the Kubernetes default, which spreads |
| `S-most` | `NodeResourcesFit` with `MostAllocated` scoring — packs, which is the usual fragmentation remedy |
| `S-tas` | Kueue Topology-Aware Scheduling, whose API exists in the pinned 0.18.3 (`topologyName`, `PodSetTopologyRequest`) |

`S-least` is the reference rather than a treatment: it is what an unconfigured cluster does, so a difference
against it is the difference an operator would actually buy by changing something.

**The submission sequence is fixed before any arm runs** and is identical across arms. A sequence chosen per
arm would let the study report whichever policy the sequence happened to favour.

## What is measured

| figure | how |
|---|---|
| **stranded devices** | at each step, `Σ_nodes (allocatable − reserved)` restricted to nodes whose free count is below every pending pod's request |
| **placement refusals** | count of `FailedScheduling` events, attributed by reason — insufficient `nvidia.com/gpu`, taint, quota — because "did not schedule" has several causes and only one of them is stranding |
| **peak reserved** | the maximum devices reserved at once, as the control: an arm that stranded nothing by admitting less has not won |

The third is the one that makes the first honest. Any policy can drive stranding to zero by refusing to
admit work, and without peak reserved beside it the table would reward exactly that.

## Stopping rule and validity

**One submission sequence, three arms, three repetitions each — nine runs.** Free, so the limit is not cost;
it is that a fourth repetition on a deterministic scheduler measures the harness, not the scheduler.

- **A run is invalid** if any pod is pending for a reason other than GPU capacity at the moment the census
  is taken, because the census would then count a node as unusable for something this study is not about.
- **The comparison is published only if all nine runs are valid.** An invalidated run is retaken **at most
  once**, and a second invalidation of the same cell ends the campaign with the attempt history published
  instead — the same shape registered for the resume arms, for the same reason: retaking until the numbers
  agree selects on the outcome.
- **No threshold is chosen here.** What difference in stranded devices would be worth reporting is decided
  after the instrument is shown to work and before the arms are compared, on a separate page. Choosing it
  now, knowing which policy the literature favours, is what pre-registration exists to prevent.

## What this study cannot say

Stated plainly, because a kind result presented without these limits would be a stronger claim than the
evidence supports:

- **Nothing about real GPU utilisation, throughput, or cost.** The devices are fake and run nothing.
- **Nothing about VRAM or NCCL.** No memory is allocated and no interconnect is exercised.
- **Nothing about whether the workloads would have finished.** Placement is the entire subject.

What it *can* say is the thing that matters for the question: **the scheduler does not know the devices are
fake.** Placement decisions are made from `allocatable` and pod requests, which are identical in shape to a
real cluster's, so a difference between scoring strategies here is a difference in the scheduler's
behaviour and not an artefact of the simulation. A real card adds no information to this particular
question — which is also why buying one for it would be waste.

## What must exist before the first run

1. A kind cluster under **its own name**. `platform` is 41 days old and carries Argo CD, cert-manager,
   KServe and Kueue that other work depends on; this study must not reuse or recreate it.
2. Per-node `FAKE_GPU_COUNT`, verified by reading `allocatable` back from each node rather than by trusting
   the manifest.
3. A scheduler configuration path that is confirmed to take effect. `kubeadmConfigPatches` and
   `KubeSchedulerConfiguration` have **no precedent in this repository**, so the first thing built is the
   check that the requested scoring strategy is the one the cluster is actually running — a study whose
   treatment silently did not apply would report three identical arms and call it a null result.
