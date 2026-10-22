# Design: more than one GPU per Pod, and the platform's first throughput figure

Written 2026-10-22. Status: **DRAFT, not registered.** Nothing here is approved, nothing has run on a GPU, and no number below is a result.
It becomes a registration only when the owner approves a session, the open decisions at the end are closed, and the sections marked "to build" exist and have been rehearsed.
My reading and codex `gpt-6-astra`'s were made independently and are kept apart in "Two readings"; where they disagree the disagreement is left visible.

## The question

Run 3 of `experiments/multi-pod-ddp/` showed two ranks, one A10G each on two g5.xlarge, completing one synchronised step with NCCL.
It printed no throughput figure, and every Pod held exactly one GPU.
This asks two things the platform can answer and run 3 cannot:

1. Can one `MLTrainingJob` Pod hold four GPUs and run one process per GPU through the platform's admission, quota and placement?
2. On the same four GPUs of one node, what NCCL all-reduce bus bandwidth does each way the platform can lay the ranks out deliver, and which transport did NCCL choose for each?

The second is the platform's own question, not a hardware benchmark.
The platform decides how ranks map to Pods: `spec.distributed` gives each rank its own Pod (`api/v1/mltrainingjob_types.go:82-90`), while a job without it is one Pod that may start several processes.
Ranks in separate Pods are in separate network namespaces with separate hostnames, so NCCL may treat them as separate hosts even when they share a node.
If it does, the platform's one-rank-per-Pod design costs intra-node bandwidth, and nothing in this repository has measured how much.

## Facts this rests on, with where each comes from

- **Instance shapes** (AWS product page, https://aws.amazon.com/ec2/instance-types/g5/, read 2026-10-22): g5.xlarge 1 GPU, 4 vCPU, up to 10 Gbps; g5.2xlarge 1 GPU, 8 vCPU, up to 10 Gbps; g5.12xlarge 4 GPU, 48 vCPU, 40 Gbps.
- **Interconnect.** The same page says nothing about NVLink or GPU-to-GPU links for G5. A10G is a PCIe card, but the topology a g5.12xlarge presents to a container is **not established anywhere in this tree**: no archived session recorded `nvidia-smi topo -m` (searched 2026-10-22). So the registration claims nothing about P2P, PCIe switches or NUMA until the run records it.
- **EFA.** The AWS EFA page (https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html, read 2026-10-22) lists g5.8xlarge and larger, g5.12xlarge included, under Nitro v3 / EFA v1 with no RDMA, and does not list g5.xlarge or g5.2xlarge. This repository attaches no EFA interface and ships no EFA plugin, so every cross-node byte in any arm here goes over TCP on the VPC network.
- **Quota and policy.** The account's "Running On-Demand G and VT instances" quota is 52 vCPU (`infra/aws/cluster/variables.tf:214`, and the session's T5 read 0 of 52 in run 3). One g5.12xlarge is 48, so it fits alone and nothing else in the G family can run beside it; two cannot. The SCP allows t3, g4dn and g5 only (`docs/superpowers/specs/2026-09-05-the-device-was-never-observed.md:70-72`).
- **Prices on record, none read today.**
  - g5.12xlarge On-Demand **$6.97/h** and Spot $3.18 to $3.41/h (`docs/superpowers/specs/2026-09-05-the-device-was-never-observed.md:63` (tabulated, not shown as read from the API) and `:79-80`, `docs/superpowers/specs/2026-09-06-does-reservation-track-use.md:128`), all from September 2026.
  - g5.xlarge On-Demand **$1.237/h**, read by run 3's T4 gate on 2026-10-22 (`experiments/multi-pod-ddp/README.md:138`).
  - g5.2xlarge On-Demand is **not recorded anywhere in the tree**; only Spot readings of about $0.45 to $0.69 are (`docs/superpowers/specs/2026-09-05-the-device-was-never-observed.md:59`, `docs/superpowers/specs/2026-10-06-where-the-late-prefill-waits-step-boundary-session.md:218`).
  - g4dn.12xlarge (4 T4) On-Demand $4.812/h (`docs/09_AWS_INFRA_ARCHITECTURE.md:382`).
  The session's T4 gate reads the live price before anything is bought, as it did in run 3; these are for budgeting only.
- **The `gpu` node group already takes a four-GPU type.** Its default is g4dn.12xlarge for queuelab (`infra/aws/cluster/variables.tf:92-126`), it is On-Demand (`infra/aws/cluster/vpc.tf:40`), and `TRAIN=ddp` overrides the type and count with `-var` (`hack/eks-gitops-session.sh:200`).

## What must change, and what already works

### Already works, and needs only to be shown

- **One Pod with four GPUs, no `distributed`.** `gpuCount` is per Pod and has no maximum (`api/v1/mltrainingjob_types.go:56-61`); `BuildJob` renders it as the container's `nvidia.com/gpu` limit (`internal/controller/mltrainingjob_controller.go:220`); `gpu-workload-static` only requires a class when `gpuCount > 0` (`config/policy/gpu-workload-static.yaml:46`). A job without `distributed` may start a launcher, because the one-process-per-Pod contract is stated on `distributed` alone (`api/v1/mltrainingjob_types.go:85-87`). So `torchrun --standalone --nproc-per-node=4` in one Pod needs no API change.
- **Four ranks in four Pods on one node.** `distributed.worldSize` allows 2 to 8 (`api/v1/mltrainingjob_types.go:100-101`); with one g5.12xlarge as the only node in the `gpu` group, four one-GPU Pods can only land on it. The placement is forced by construction, as run 3's cross-node placement was.

### Must change (to build; none is built)

1. **Quota.** `config/training/gpuquotapolicy.yaml` admits 2 GPUs for `train-a`. It must be 4. Argo syncs `config/training` from `main`, so the change must be merged to `main` before the session, like every other GitOps input of run 3.
2. **Node qualification.** `train_qualify_nodes` requires allocatable `nvidia.com/gpu` to equal `"1"` (`hack/lib/train-session.sh:203`). It must take the expected count as an argument, and its stub test (`hack/test/check-train-session-lib.sh`) must show a node advertising 1 of an expected 4 refused, and 4 of an expected 1 refused.
3. **A session mode.** A `TRAIN=allreduce` beside `TRAIN=ddp` in `hack/eks-gitops-session.sh`, with `TRAIN_INSTANCE_TYPE=g5.12xlarge`, `TRAIN_NODES=1`, its own price ceiling, its own arm list and its own scorer. The quota gate is already generic (`vcpu * TRAIN_NODES`, `hack/eks-gitops-session.sh:617-621`), and 48 of 52 passes only if nothing else in the G family runs, which is what it should require.
4. **The workload.** `experiments/cpu-ddp/train.py` selects device 0 unconditionally (`select_device`, "One GPU per Pod, so the only device a rank can see is index 0"), so under a four-process launcher all four processes would drive one card. It is not changed: its hash is run 3's approved one. The throughput arms use a separate instrument, `experiments/multi-gpu-throughput/allreduce_bench.py` (written with this draft, uncommitted, unit-tested without torch, never run on a GPU), which selects `LOCAL_RANK` and refuses an index the Pod cannot see.
5. **Shared memory.** A container's `/dev/shm` is the runtime's default, commonly 64 MiB (not read on these nodes; the smoke cell's Pod should print `df /dev/shm`), and NCCL's SHM transport, which it uses between processes on one host when P2P is unavailable, allocates its buffers there. `BuildJob` mounts nothing at `/dev/shm`. A memory-backed `emptyDir` there for `gpuCount > 1` is the obvious change, and it has a cost that must be decided rather than discovered: the termination canary fingerprints `templateProbeJob`, whose `GPUCount` is 7 (`cmd/queuelabrun/canary.go:272`), so the mount would move the hash and invalidate every canary taken before it. The alternatives are an opt-in spec field, which leaves the canary's rendering unchanged, or no mount and a smoke cell that would fail loudly if NCCL needed one. Which is an owner decision (D3).
6. **A scorer.** `experiments/multi-gpu-throughput/analyze.py` (to build) refuses a run unless, per job: the number of `start` records equals the arm's rank count; the GPU UUIDs are distinct and their count equals the arm's GPU count; every `size` record of every rank is `verified`; the script hash is the approved one; and the transport NCCL logged (below) is present for every rank. It reports bandwidth only from verified sizes, and a figure only for an arm whose every repetition passed.
7. **Transport evidence.** Every arm sets `NCCL_DEBUG=INFO` and `NCCL_DEBUG_SUBSYS=INIT,GRAPH,ENV` so each rank logs the channels it built and the transport of each (`via P2P/IPC`, `via SHM`, `via NET/Socket`). The figure is attributed to a transport only where these lines name it. No other `NCCL_` variable is set; the bench records every one in force.
8. **Topology evidence.** The four-GPU Pod of arm `pod-4x1` runs `nvidia-smi topo -m` and `nvidia-smi -q` before the bench and saves both. It is the only Pod that sees all four cards.

### What becomes false if this is built

- The comment in `select_device` stays true, because `train.py` is not used here.
- "Nothing here is a throughput figure" in run 3's record stays true of run 3.
- `config/training/gpuquotapolicy.yaml`'s comment says two GPUs; it must be edited with the number.
- `train_qualify_nodes`' comment says "advertising nvidia.com/gpu 1"; it must be edited with the argument.

## The instrument, and why not the others

A throughput figure is only as good as what it is a throughput of.
The options, with what each could get wrong while looking right:

| instrument | measures | cannot say | needs in the image | plausible wrong number |
|---|---|---|---|---|
| timing `train.py`'s step | one synchronised step of a one-weight model | anything about bandwidth: the all-reduce moves 4 bytes | nothing new | a step time that is all launch and Python overhead, read as communication |
| a small real model's samples/s | that model, at that batch, in that dtype | the platform's share of it; a different model gives a different number | a model and data | a figure dominated by compute or input loading, attributed to placement |
| `torch.distributed.all_reduce` timed with CUDA events (`allreduce_bench.py`) | NCCL all-reduce of torch's bundled NCCL at fixed sizes, end to end per collective | anything above the collective; algorithm selection detail | nothing new: the run-3 image's torch and NCCL 2.21.5 | a reduction that did not happen, or ran over the wrong group, timed anyway; one slow rank hidden by averaging; two processes on one card counted as two GPUs |
| NVIDIA nccl-tests' all-reduce test (all_reduce_perf) | the same quantity, the reference implementation of the busbw convention | the NCCL version torch uses, unless built against it | a CUDA devel image to build it, or a third-party image pinned by digest; and MPI or its own launcher for multi-Pod | the same as above, plus a different NCCL from the one the platform's workloads run |

**My choice: the torch bench as the measurement, because it uses the NCCL the platform's training jobs actually load, in the image run 3 already pulled and qualified.**
It is built to fail closed on the three wrong numbers in its row: every iteration's buffer is checked for the exact sum `n(n+1)/2` and a size that fails reports no bandwidth; each iteration's time is the slowest rank's; and each rank records its GPU UUID, so the scorer refuses duplicates.
Its figure is defined exactly as nccl-tests defines bus bandwidth for all-reduce (`algbw * 2(n-1)/n`), so it can be compared with published nccl-tests numbers on the same message size.
nccl-tests is a better reference and a worse instrument here: it would add an image nobody has pinned and an NCCL nobody runs. It is a candidate validation arm, not the measurement (D4).

## Arms

All on one g5.12xlarge, in one session, so every arm shares the node, the driver and the session's time.

| arm | Pods × GPUs per Pod | how it renders | processes | forced by |
|---|---|---|---|---|
| `pod-4x1` | 1 × 4 | no `distributed`, `gpuCount: 4`, `torchrun --standalone --nproc-per-node=4` | 4 in one Pod | the spec |
| `pods-1x4` | 4 × 1 | `distributed.worldSize: 4`, `gpuCount: 1` | 1 per Pod | one node in the group |
| `pod-2x1` | 1 × 2 | no `distributed`, `gpuCount: 2`, `--nproc-per-node=2` | 2 in one Pod | the spec |
| `pods-1x2` | 2 × 1 | `distributed.worldSize: 2`, `gpuCount: 1` | 1 per Pod | one node in the group |

`pod-2x1` and `pods-1x2` are there because two ranks are what run 3 ran, so the two-rank pair is the one a later cross-node run (below) extends.
Two Pods of two GPUs each is **not** an arm: it would need a multi-node launcher inside `distributed`, which the API's contract forbids (`api/v1/mltrainingjob_types.go:85-87`), and changing that contract is a design of its own (D5).

**The smoke cell is the first `pod-4x1` job.** It is the first time any code here runs four processes on four GPUs in one Pod. If it is not PASS under the scorer, the run is reported as a failed smoke cell; the remaining jobs still run and are recorded, and are not results.

**Order and repetitions.** Three jobs per arm, each a fresh `MLTrainingJob`, so each repetition builds its own communicator.
Interleaved by block, `pod-4x1, pods-1x4, pod-2x1, pods-1x2`, three times, so a drift over the session falls on every arm alike rather than on whichever ran last.
In each job: sizes 1, 4, 16, 64 and 256 MiB, 5 warm-up and 20 timed all-reduces per size.
The 20 iterations of one job are not 20 repetitions: they share one communicator and one moment, so the unit of repetition is the job.
In the two-GPU arms the device plugin chooses which two of the four cards a Pod gets; each rank's UUID is mapped to a PCI bus ID through the topology record, so a two-rank figure names its pair.

**A cross-node pair, as a separate session (D2).** `nodes-1x2` on two g5.xlarge, `distributed.worldSize: 2`, the topology run 3 already passed, with the same bench. It cannot share the session: one g5.12xlarge plus two g5.xlarge is 56 vCPU against 52, and the `gpu` group has one instance type. It is what turns `pods-1x2` into a statement about leaving the node.
**Run 3's two nodes were in different availability zones**: `ap-northeast-2a` and `ap-northeast-2c`, read from the `topology.kubernetes.io/zone` labels in `hack/multi-pod-ddp-eks-20261022T004202Z/ddp/pass/nodes.json` (codex raised the possibility; the labels are what established it). The `gpu` group spans every zone offering the type (`infra/aws/cluster/placement.tf:45`). A cross-node figure taken that way is a cross-zone figure, and cross-zone traffic is billed per GB, so `nodes-1x2` must either pin the group to one zone for the session or record the zones and say "across zones" in its claim (D8).
Even in one zone, `nodes-1x2` against `pods-1x2` changes the instance, its CPU and its NIC as well as the link, so the difference is a deployment comparison, not a measured cost of the network alone.

## Estimands

Per arm, per message size: the median over the three jobs of each job's median slowest-rank bus bandwidth, with every job's median printed beside it.
Per arm: the transport each rank's NCCL log names, and the node's `topo -m` matrix.
Per job: whether the platform admitted it as one Workload of the arm's GPU count, and placed every Pod on the node.

**The comparison that may be stated.** "Ranks in separate Pods reached lower bus bandwidth than ranks in one Pod, on this node, at size S" is stated only if every one of the three `pod-` job medians at S exceeds every one of the three `pods-` job medians at S. Otherwise the two are reported as not distinguished at S. Three repetitions support no interval, and this rule needs none.
Its false-positive rate is known without a model: if the two arms were exchangeable, complete separation of three against three in the predicted direction has probability 1/20, and of five against five 1/252. Three is the cheaper choice and the weaker one (D7).
Bandwidth is decimal gigabytes per second of one rank's payload, as nccl-tests prints it; the bench's keys say `gigabytes_per_s` so the figure cannot be read as gigabits.
A difference is attributed to transport only if the two arms' NCCL logs name different transports.

## Predictions, registered before any run

Written so they can be wrong.
- `pods-1x4` and `pods-1x2` log `NET/Socket` for every peer, because each Pod has its own hostname and network namespace.
- `pod-4x1` and `pod-2x1` log `P2P` or `SHM`, not `NET`.
- At 64 and 256 MiB, every `pod-` job median exceeds every `pods-` job median of the same rank count.
No magnitude is predicted, because nothing in the tree measures this node's PCIe or its Pod network.

## What a result would license, and what it would not

It would license: on one g5.12xlarge on EKS, through this platform's rendering, the all-reduce bus bandwidth of torch's NCCL at five sizes for four layouts, which transport NCCL chose in each, and whether the one-rank-per-Pod layout costs bandwidth on one node.
It would not license:
- any training throughput: no model ran;
- NVLink, P2P or any interconnect statement beyond what the node's own `topo -m` and NCCL's log say;
- EFA, RDMA or GPUDirect: none is configured;
- scaling across nodes: only the separate `nodes-1x2` session would add one point, at two ranks;
- another card, instance type, NCCL version or tuning: no `NCCL_` variable is tuned;
- a comparison between NCCL and nccl-tests, unless D4 adds that arm.

## Voids and stop rules

- A gate from T1 to T5 refusing voids the run before anything is bought, and it may be repeated under this registration.
- A node not qualified with allocatable `nvidia.com/gpu` 4 voids the run.
- A job whose ranks report fewer distinct GPU UUIDs than the arm's GPU count is void, never scored.
- A size refused by the bench's own check fails that job; an arm with a failed job reports no figure.
- The watchdog and the AWS deadline are the run-3 machinery, with the budget recomputed for twelve jobs.
- Neither the bench, the scorer nor the session may change between the run and its reading.

## Cost and TTL, for the owner's decision

Estimated from the archived prices above, which T4 must re-read; all figures are estimates, not quotes.
- **GPU time.** Run 3's two nodes were up 9 min 7 s from launch to shutdown for four arms, qualification and an image pull included (`experiments/multi-pod-ddp/README.md:163`). Twelve jobs of five sizes each are perhaps 25 to 40 minutes of one g5.12xlarge: about **$3 to $5** at $6.97/h On-Demand.
- **Cluster.** About $0.26/h for about 2 hours: about $0.5.
- **Image.** The 3.3 GB run-3 image, pulled once on one node through the NAT at $0.059/GB: about $0.2.
- **Expected: about $4 to $6. Bounded at about $10** if the GPU budget is held to 60 minutes and every wait runs to its deadline, with the watchdog destroying the cluster at `TTL_MINUTES`.
- **Spot** at the archived $3.2 to $3.4/h would halve the GPU part, but the `gpu` group is On-Demand for a queuelab reason (`infra/aws/cluster/vpc.tf:36-40`) and flipping it changes queuelab's group too (D1).
- The cross-node `nodes-1x2` session would cost about what run 3 did, about $1.

## Free rehearsal on kind

Simulated devices run no CUDA and no NCCL, so nothing on kind is a bandwidth.
What kind can show before money:
- a worker advertising 4 simulated GPUs (`FAKE_GPU_COUNT=4`, `config/device-plugin/daemonset.yaml:59`), a quota of 4, and each arm admitted as one Workload of the right count with every Pod on that worker;
- `pod-4x1` under `torchrun --nproc-per-node=4` giving four processes distinct `LOCAL_RANK`s, and the bench refusing on kind with its `CUDA is not available` record, which exercises the start-up and the collector;
- the collector and scorer end to end on those refusals, and the scorer red on fixtures: a duplicated UUID, an unverified size, a missing transport line, three ranks of four;
- the session's new mode up to the purchase, with `aws` and `kubectl` stubbed, as `hack/test/rehearse-train-session.sh` does for `TRAIN=ddp`;
- the `/dev/shm` mount, if D3 chooses one, rendered and its size read from inside a Pod.
What kind cannot show: NCCL's transport choice, any bandwidth, the node's topology, the driver, whether the SHM transport needs more than 64 MiB, and the image pull on EKS.
A gloo mode for the bench would let the collector see real `size` records on kind; it is not built, and its numbers would be CPU numbers that must never reach a table.

## Open decisions for the owner

- **D1: On-Demand or Spot.** On-Demand at an archived $6.97/h is the default and keeps queuelab's group as it is. Spot is about half and needs the group's capacity type split from queuelab's.
- **D2: whether to buy the cross-node session** (`nodes-1x2`, about $1), and before or after the g5.12xlarge one.
- **D3: `/dev/shm`.** Always for `gpuCount > 1` (moves the canary hash), opt-in by a spec field (no hash move, an API change), or nothing and let the smoke cell find out (costs a session if it fails).
- **D4: an nccl-tests validation arm.** Needs an image pinned by digest and built against a known NCCL; without it the figure is compared with nccl-tests' convention, not with nccl-tests.
- **D5: Pods with several GPUs inside `distributed`.** Not in this design; it would change the API's launcher contract and the analyzer's one-rank-per-Pod rule.
- **D7: three or five jobs per arm.** Five blocks of four arms is twenty jobs, perhaps 15 more minutes of the node (about $2 at $6.97/h), and lowers the comparison rule's chance of a false separation from 1/20 to 1/252.
- **D8: the cross-node pair's zones.** Pin `nodes-1x2` to one zone for its session, which needs a session-time subnet choice the cluster root does not offer today, or run it across zones as run 3 did and claim only that.
- **D6: the card.** g4dn.12xlarge (4 T4, $4.812/h On-Demand on record) would be cheaper and is already the group's default type, but it changes the card from run 3's; see the T4 section of `docs/superpowers/specs/2026-10-22-future-work-candidates.md`.

## Two readings

### Mine

Recorded above. In short: the first figure should be an all-reduce bus bandwidth, not a training rate, because placement is what the platform controls and a model's samples per second would measure the model; one g5.12xlarge, because it is the only shape in the quota with more than one GPU in a node; and the question worth paying for is the one-rank-per-Pod cost on one node, because it is a property of this platform's design that no published benchmark can answer for it.

### codex `gpt-6-astra` (run independently, 2026-10-22)

Asked the same five questions with no preference stated, read-only, `model_reasoning_effort=high`.
What it said, in short, and what I checked:

- **Instrument: nccl-tests' all_reduce_perf as the primary**, one MPI process per GPU with `-g 1`, and a torch all-reduce as the cross-check through the training launcher. It warned that `-g 4` in one process is not four processes, that independently started tests in separate Pods are separate groups, and that multi-Pod nccl-tests needs an MPI bootstrap across the Indexed Pods that `torchrun` does not provide. (Not checked: nothing in the tree builds nccl-tests or MPI, which is consistent with its point that both would be new.)
- **Arms:** 1 × 4, 2 × 2 and 4 × 1 on one g5.12xlarge as the primary set; four g5.xlarge as a separate phase, with the large node terminated first because the two together would need 64 vCPU; two-rank pairs as optional. For 2 × 2 it proposed `distributed.processesPerPod`, keeping `worldSize` as the Pod count. It said to keep the training group On-Demand.
- **Repetitions:** five randomised blocks of fresh jobs, 20 warm-up and 100 timed operations per size, sizes from 8 bytes to 256 MiB, every repetition published, and "within-allocation repeatability" as the name for what they show.
- **Zones:** cross-node arms should pin a zone or make the zone part of the treatment. I checked it: run 3's nodes were in two zones (above).
- **Wrong numbers, ranked:** four GPUs reserved and one used; several independent groups each reporting a good figure; timing the enqueue rather than the completion; the correctness toy called training throughput; payload multiplied by rank count or GB read as Gb; intended placement taken for observed placement; the scorer generalised by deleting the one-rank-per-Pod check rather than replacing it with a stronger mapping; and selecting favourable sizes or attempts.
- **Four g5.xlarge needs `gpu_max_nodes` above 2**, whose validation stops at 2 (`infra/aws/cluster/variables.tf:224-225`, checked), and so does `train_node_count_refusal` (`hack/lib/train-session.sh:27`, checked).

### Where the two readings meet, and where they do not

Agreed: a correctness gate before any figure (distinct UUIDs, a rank-dependent sum, slowest-rank timing); the instrument is a collective, not `train.py`; one g5.12xlarge as the first purchase; topology and NCCL's transport recorded before any interconnect statement; prices re-read live; kind shows admission, placement, launcher membership and the scorer, and nothing about bandwidth.

Not agreed, and left for the owner:
- **Primary instrument.** codex prefers nccl-tests as the reference implementation; I prefer the torch bench because it runs the NCCL the platform's training image loads, in an image already pulled and qualified, with no MPI to add. D4 is the place to settle it; if nccl-tests is added, its image and MPI bootstrap are free work that must be rehearsed first.
- **2 × 2.** codex includes it via `processesPerPod`; I leave it out of the first run because it changes the API's launcher contract and the scorer's identity rule at once (D5). codex's version is the better long-term API, and the first run does not need it to answer the one-rank-per-Pod question.
- **Four nodes against two.** codex's cross-node phase is four g5.xlarge at four ranks, which makes the comparison with `pods-1x4` the same rank count; mine is two g5.xlarge, which reuses run 3's topology and the existing node-count cap. Four is the better comparison and needs the cap raised in Terraform and the session (D2).
- **Iterations.** codex's 100 timed operations against my 20; 100 costs seconds per size and is adopted if the scorer is built to it.
