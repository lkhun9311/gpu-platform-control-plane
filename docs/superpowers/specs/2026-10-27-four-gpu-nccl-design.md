# Experiment C: four A10Gs in one Pod against four Pods of one, on one g5.12xlarge — registration

Written 2026-10-26 (dated 2026-10-27, the earliest day a session under it could run).
**Registered and frozen for purchase, 2026-10-27, at the commit that carries this line.** The owner approved every valid experiment of 2026-10-27 on 2026-10-26 ("유효 실험도 전부 승인하니 진행"), and on 2026-10-27 approved the paid sessions to go ahead ("유료 실험 진행 가능"). Nothing below changes after this commit, and a session run from code other than this commit's, as promoted to `main`, does not count.
Until this line, the status said: "registered for review, not approved for purchase."
**Status, 2026-10-27: run 1 is VOID at Q, after the purchase, by a defect in the scorer; no job ran and no number below is a result.** The owner approved one more attempt under "Amendment for run 2", at the end, which changes only the scorer's reading of the topology header.
**Status, 2026-10-28: run 2 is a FAILED SMOKE, stopped by a third defect in the scorer before any registered job; no number below is a result.** "Run 2" and "Amendment for run 3", at the end, say what failed and what a third attempt changes; the owner approved that amendment on 2026-10-28.
**Status, 2026-10-29: run 3 is a FAILED SMOKE, stopped by a fourth defect in the scorer before any registered job; no number below is a result.** "Run 3" and "Amendment for run 4", at the end, say what failed and what a fourth attempt changes; the owner approved that amendment on 2026-10-29.
**Status, 2026-10-29: run 4 is a FAILED SMOKE, stopped by a fifth defect in the scorer, run 3's fix being too narrow, before any registered job; no number below is a result.** "Run 4" and "Amendment for run 5", at the end, say what failed and what a fifth attempt changes; the owner approved that amendment on 2026-10-29.
**Status, 2026-10-29: run 5 is COMPLETE, Q and all five smoke and 25 registered jobs valid, and its figures and verdicts are this registration's only results.** "Run 5", at the end, records them; runs 1 to 4 are not pooled with it.
codex `gpt-6-astra` attacked the first version cold; every finding was re-derived, and this version is the reconciled one ("Review: astra's attack, reconciled", at the end).
It grows out of the draft `2026-10-22-multi-gpu-per-pod-throughput-design.md`, which is left as it was written and is history; where this page and the draft differ, this page holds, and "Changes from the draft" says what moved and why.
Every numeric bound below names where its number comes from, because `docs/11_WHAT_THIS_MEASURED.md` ("What the targets were based on") now records that several earlier bars had none.
A bound with no derivation is marked as a convention, and whatever it decides is read as a statement about the convention.

**Before purchase, three things remained**, and at this commit two are done: the nccl-tests image is pushed and its digest is in "Pinned, and recorded"; this page and the code are frozen here, which fixes the two approved script hashes. The third, `config/training/gpuquotapolicy.yaml` at 4 GPUs on `main`, is met by the promotion that carries this commit; the session's T1 checks the Application synced from `main`, and T3 cannot admit its four-GPU Pod without that quota.

## Why this is worth a session

Run 3 of `experiments/multi-pod-ddp/` showed two ranks on two g5.xlarge completing one synchronised NCCL step, one GPU per Pod, with no throughput figure (`experiments/multi-pod-ddp/README.md`, "Run 3").
The platform decides how ranks map to Pods: `spec.distributed` gives every rank its own Pod, and a job without it is one Pod that may start a launcher.
Ranks in separate Pods have separate hostnames and network namespaces, and NCCL may then treat them as separate hosts even on one node.
Whether the platform's one-rank-per-Pod layout costs intra-node bandwidth is a property of this platform, not of the hardware, and nothing in this repository has measured it.
The skills it exercises are the ones the target roles name: the NVIDIA software stack with CUDA and NCCL, interconnect understanding, and the debugging and profiling of distributed training.

## The question

On one g5.12xlarge (four A10G, PCIe only), through this platform's admission and rendering:

1. **Bus bandwidth.** What NCCL all-reduce bus bandwidth, in decimal GB/s, at 1, 4, 16, 64 and 256 MiB, does one Pod with four GPUs (`1pod4gpu`) reach, and what do four Pods with one GPU each (`4pod1gpu`) reach?
2. **Step time.** How long is a DDP step in each layout, for a synthetic model whose gradient totals the ladder's top, and how much longer is a synchronised step than the same step without synchronisation?
3. **Transport.** Which transport did NCCL choose for each rank, as NCCL's own `NCCL_DEBUG=INFO` log names it (`P2P`, `SHM` or `NET`), never assumed?
4. **Topology.** What do `nvidia-smi topo -m` and `nvidia-smi topo -p2p r` report for the four cards as the container sees them?
5. **Reference.** What does NVIDIA's `all_reduce_perf` (nccl-tests), run as one process per GPU in one Pod, as the AWS EKS guide runs it, report at the same sizes, beside the torch instrument?

## Facts this rests on, with where each comes from

The raw answers of every AWS read are saved in `data/2026-10-27-four-gpu-nccl/` (`aws-*.json`, read 2026-10-26 13:25Z to 13:50Z with `gpu-lab`, read-only).

| fact | value | source |
|---|---|---|
| g5.12xlarge shape | 48 default vCPU, 196,608 MiB memory, 4 × A10G of 22,888 MiB, 40 Gigabit network, EFA supported (one interface) | `aws-instance-type-g5.12xlarge.json` |
| A10 interconnect | "PCIe Gen4 64GB/s"; the specification table lists no NVLink | NVIDIA A10 product page, https://www.nvidia.com/en-us/data-center/products/a10-gpu/, read 2026-10-26 |
| zones offering the type | ap-northeast-2a, 2c, 2d | `aws-offerings-g5.12xlarge.json` |
| On-Demand price | **$6.97442 an hour**, effective 2026-10-01 | `aws-price-g5.12xlarge-ondemand-20261026T1325Z.json` (Price List API: one product, one hourly USD dimension) |
| Spot price, for comparison only | 2a $3.4865, 2c $3.5285, 2d $3.7245 an hour | `aws-spot-g5.12xlarge.json`; not used, see "Capacity type" |
| gp3 storage | $0.0912 per GB-month in Seoul | `aws-price-gp3-storage.json`; the `gpu` group's root volume is 100 GiB gp3 (`infra/aws/cluster/eks.tf`) |
| G and VT quotas | On-Demand 52 vCPU (`L-DB2E81BA`), Spot 48 vCPU (`L-3819A6DF`) | `aws-quota-ondemand-g-vt.json`, `aws-quota-spot-g-vt.json` |
| instances running | none pending or running in the region at 13:47Z | `aws-instances-running.json` |
| NAT data processing | $0.059 per GB | as run 3's budget used it (`experiments/multi-pod-ddp/README.md`, "Budget"); not re-read |
| NCCL and shared memory | NCCL "creates shared memory segments in `/dev/shm`"; with too little, initialization fails; in a container, use `--shm-size=1g --ulimit memlock=-1` | NCCL 2.21.5 user guide, Troubleshooting, https://docs.nvidia.com/deeplearning/nccl/archives/nccl_2215/user-guide/docs/troubleshooting.html, read 2026-10-26 |
| nccl-tests practice on EKS | `all_reduce_perf -b 8 -e 16G -f 2 -g 1 -c 1 -n 100` under `mpirun` with `-x NCCL_DEBUG=INFO`, one process per GPU, `/dev/shm` mounted into the worker, and checking that `NCCL_DEBUG=INFO` names the transport | AWS EKS user guide, "Manage EFA devices", https://docs.aws.amazon.com/eks/latest/userguide/node-efa.html, read 2026-10-26 |
| nccl-tests' warm-up and timing | at commit `8dfeab9e`, its TimeTest function runs the `-w` warm-up at the largest size and again at the smallest, not at each size; its BenchTime function times a back-to-back loop of `-n` operations with one timer and divides; `-a` chooses how the ranks' times combine; `-c 1` checks a separate run after the timed loop | `src/common.cu` at that commit, read 2026-10-26 (astra found it; I read the same lines) |
| torch, CUDA and NCCL in the training image | torch 2.5.1, CUDA 12.4, NCCL 2.21.5 | run 3's rank records; the image's config carries no `NCCL_` variable (registry config read 2026-10-26) |
| the CUDA base image | linux/amd64 digest `sha256:5645fec6…9749` ships `libnccl2` and `libnccl-dev` `2.21.5-1+cuda12.4` and sets `NCCL_VERSION=2.21.5-1` as a package label | `dpkg-query` and `env` in that image, run here 2026-10-26 |

The NVIDIA page establishes that the card has no NVLink.
It does not establish whether the four cards of this instance can use PCIe peer-to-peer inside a container, which is what `topo -p2p r` and NCCL's log are recorded for.

## Arms

All on one g5.12xlarge, the only node in the `gpu` group, so every Pod can land only there.
Each job is a fresh `MLTrainingJob`, so each builds its own NCCL communicator, and it is deleted once its evidence is saved.

| arm | Pods × GPUs per Pod | renders as | processes | instrument |
|---|---|---|---|---|
| `nccltests-1pod4gpu` | 1 × 4 | `gpuCount: 4`, no `distributed` | `mpirun -np 4` of `all_reduce_perf -g 1`, one process per GPU | nccl-tests v2.13.11 against NCCL 2.21.5 |
| `allreduce-1pod4gpu` | 1 × 4 | `gpuCount: 4`, no `distributed` | `torchrun --standalone --nproc-per-node=4` | `experiments/multi-gpu-throughput/allreduce_bench.py` |
| `allreduce-4pod1gpu` | 4 × 1 | `gpuCount: 1`, `distributed.worldSize: 4` | one per Pod | the same file |
| `ddp-1pod4gpu` | 1 × 4 | `gpuCount: 4`, no `distributed` | `torchrun --standalone --nproc-per-node=4` | `experiments/multi-gpu-throughput/ddp_step_bench.py` |
| `ddp-4pod1gpu` | 4 × 1 | `gpuCount: 1`, `distributed.worldSize: 4` | one per Pod | the same file |

**Not arms, and why.**
- **Two Pods of two GPUs.** It needs a launcher inside each `distributed` Pod, and `spec.distributed`'s documented contract says the command "must start exactly one process per Pod" (`api/v1/mltrainingjob_types.go`). Changing that contract changes the CRD description that `controller-gen` ships, which is a design of its own (the draft's D5).
- **Two-GPU arms** (`1pod2gpu`, `2pod1gpu`). The draft had them for a later cross-node pair, which is not registered here; they would add node-minutes to every repetition and answer no question on this page.
- **nccl-tests across four Pods.** It needs an MPI bootstrap across the Indexed Pods (the AWS guide uses the Kubeflow MPI Operator), which this platform does not run. The cross-Pod comparison is the torch instrument's, which bootstraps through the platform's own `MASTER_ADDR`.

## Order and repetitions

**Five smoke jobs first, one per arm in the order above, not counted.** They are the first time this platform runs four processes on four GPUs in one Pod, and the first execution of both benches and of nccl-tests here; each is scored as it finishes, and the stop rule below acts on them.
They also take every arm's first-run costs (image layers, CUDA and NCCL initialisation on a fresh node) out of the counted jobs.

**Then 25 registered jobs, five per arm, in one completely random order** drawn by `ar_job_order` (`hack/lib/allreduce-arms.sh`) with Python's `random.Random(20261027).shuffle`, pinned by `hack/test/check-allreduce-arms-lib.sh`:

| position | 1 to 5 | 6 to 10 | 11 to 15 | 16 to 20 | 21 to 25 |
|---|---|---|---|---|---|
| arm (repetition) | nccltests (2), ddp-4pod (2), allreduce-4pod (5), allreduce-4pod (1), ddp-1pod (4) | allreduce-4pod (4), nccltests (3), allreduce-1pod (3), ddp-1pod (5), ddp-4pod (3) | ddp-1pod (2), allreduce-4pod (3), nccltests (5), allreduce-1pod (4), nccltests (4) | nccltests (1), allreduce-4pod (2), ddp-1pod (1), ddp-1pod (3), allreduce-1pod (5) | ddp-4pod (4), allreduce-1pod (2), ddp-4pod (5), allreduce-1pod (1), ddp-4pod (1) |

**Why random and not blocked.** The verdict rule below is complete separation of two arms' five job figures.
Its false-positive bound needs every split of the two arms' ten positions to be equally likely when the arms do not differ; a random order of all 25 supplies exactly that, so the bound is a randomization-test statement and holds whatever the session's drift.
A cyclic Latin square, which the first version used, balances position but fixes which arm follows which, and the bound would rest on an exchangeability nothing establishes (astra, finding 5).

**Why five, derived.** Under a random order and no arm effect, one test's chance of a complete separation in a named direction is 1 / C(10, 5) = 1/252, and in either direction 2/252.
- **V1** is tested at five sizes: at most 10/252 = 3.97% for a false separation at any of them (Bonferroni).
- **V2 and V3** are two more tests: at most 4/252 = 1.59%.
- **All seven together:** at most 14/252 = 5.56%, stated rather than hidden.
Four jobs per arm would give 10/70 = 14.3% for V1 alone and three 10/20 = 50%; five is the smallest count whose V1 family is under 5%.
`analyze.false_separation_bound` computes these, and its test pins them.

**The unit of repetition is the job.** The 100 timed iterations of one job share one communicator and one moment, so they are not 100 repetitions.

## What each job does

**Message sizes: 1, 4, 16, 64 and 256 MiB.** Below about 1 MiB an all-reduce's time is mostly latency, so the ladder starts where a bandwidth reading means something; that is a convention of reading nccl-tests output, not measured here. nccl-tests is run with `-b 1M -e 256M -f 4`, which produces exactly these five sizes.

**The torch all-reduce bench** (`allreduce_bench.py`): 20 warm-up and 100 timed all-reduces per size.
Each rank fills its buffer with rank + 1, so a correct SUM holds n(n+1)/2 = 10 in every element; every timed iteration is checked, and a size that fails on any rank reports no bandwidth. Warm-up iterations are not checked.
Before each timed iteration every rank synchronises its device and waits at a barrier, outside the timed span, so a rank that arrives early does not count its wait for a late one; an iteration's time is then the slowest rank's CUDA-event time, and the job's figure at a size is the median over its 100 iterations.
Bus bandwidth is nccl-tests' convention: S / t × 2(n − 1)/n, with S one rank's buffer in bytes and decimal gigabytes.

**The DDP step bench** (`ddp_step_bench.py`): `DistributedDataParallel` over four `Linear(4096, 4096)` layers with ReLU between them, float32, batch 64 of synthetic inputs drawn on the device from a seed that depends on the rank.
- **The model.** Its gradient totals 4 × (4096² + 4096) = 67,125,248 parameters = 268,500,992 bytes, 256.06 MiB, 65,536 bytes above the ladder's top. DDP does not reduce that as one message: it reduces buckets as gradients become ready, 25 MiB by default with each 64 MiB weight in a bucket of its own, so the step's collectives are about four messages near 64 MiB, not one of 256 MiB. The bucket sizes DDP reports are recorded per job rather than assumed (astra, finding 7). The forward and backward are about 6 × 67.1 M × 64 ≈ 25.8 GFLOP, about 0.83 ms at the A10's datasheet 31.2 TFLOPS: an idealised floor, not a measured compute time.
- **Two kinds of step, alternated.** A *synced* step is forward and backward with DDP's gradient all-reduce; a *local* step is the same under `no_sync()`. No optimizer step is taken, so every step does the same arithmetic. 20 warm-up pairs and 50 timed pairs, a convention.
- **Timing.** Before each timed step every rank synchronises and waits at a barrier, outside the timed span; it then reads `time.perf_counter`, runs the step, synchronises and reads it again. A step's time is the slowest rank's.
- **What the difference is.** The median synced step minus the median local step is the *synchronisation cost* as DDP incurs it: the all-reduce the backward did not overlap, and the reducer's own bookkeeping, which `no_sync()` also skips. It is not the all-reduce's time alone, and the page does not call it that (astra, finding 6).
- **Correctness, three ways.** Every local step's checksums (the float64 sum of every gradient element) must differ between ranks, or the inputs were not rank-dependent. Every synced step's checksums must be equal on every rank. And, parameter by parameter, the synced gradient's sum must equal the mean of the ranks' local sums within 10⁻⁶ of their mean absolute sum, with a zero local gradient counted as a failure. The tolerance is derived: DDP divides by the world size (exact for 4) and sums four float32 values, three roundings of at most 2⁻²⁴ ≈ 5.96 × 10⁻⁸ each relative to the magnitudes added, about 1.8 × 10⁻⁷; 10⁻⁶ is that rounded up about five times. A missing or doubled reduction moves the sum by a share of the gradient itself (astra, finding 11). A job failing any of the three reports no step time.
- **Measured on CPU here.** The same file, run with `STEP_REHEARSAL_CPU=1` (gloo, CPU) in the training image's CPU twin on 2026-10-26, verified on four ranks and reported its buckets; with the synced step replaced by a local one, all 8 parameters failed the oracle; with every rank given the same seed, the local checksums collided and the job was refused. A CPU record says `device: cpu`, and the scorer refuses it as a measurement.

**nccl-tests** runs `mpirun --allow-run-as-root -np 4 --bind-to none --mca btl self,vader all_reduce_perf -b 1M -e 256M -f 4 -g 1 -c 1 -n 100 -w 20 -a 3`.
- **Warm-up.** `-w 20` runs 20 warm-up operations at 256 MiB and 20 at 1 MiB before the ladder, not 20 at each size (its source, above). The torch bench warms each size; the two instruments therefore do not share a warm-up history, and that is stated wherever their figures sit together.
- **Timing.** Each size's time is one timer around 100 back-to-back operations, divided by 100, and `-a 3` takes the slowest rank's; the torch bench times each operation and takes a median. The figure taken is the out-of-place bus bandwidth, printed to two decimals.
- **Correctness.** `-c 1` checks a separate run after the timed loop, not the timed operations; every size's out-of-place and in-place wrong counts must be 0, and the run must report zero out-of-bounds values.

**Settings in every job's Pods.** `NCCL_DEBUG=INFO`, `NCCL_DEBUG_SUBSYS=INIT,GRAPH,ENV` and `OMP_NUM_THREADS=1`.
The last is set everywhere because `torchrun` sets it to 1 for the processes it starts and a Pod per rank would otherwise not, which is a layout difference the comparison does not want (astra, finding 8); each rank records `OMP_NUM_THREADS`, torch's thread count and its CPU affinity.
NCCL also reads `/etc/nccl.conf` and `~/.nccl.conf`, which Python's environment cannot see, so each Pod prints whether either exists and every `NCCL_` variable it started with (astra, finding 9).
`CUDA_VISIBLE_DEVICES` is set by nothing here: the NVIDIA device plugin exposes the allocated cards, which the container sees as 0 to n − 1; each process selects `LOCAL_RANK` (0 when unset) and the benches refuse an index the Pod cannot see. Each rank records both visible-device variables as it found them.

## What the platform must render, and what changed for it

- **`/dev/shm` for Pods with more than one GPU.** `BuildJob` mounts a memory-backed `emptyDir` named `dshm`, `sizeLimit: 1Gi`, at `/dev/shm` when `gpuCount > 1`. The size is the NCCL guide's `--shm-size=1g`; the AWS guide mounts the host's `/dev/shm` instead, which this platform will not do for a tenant's Pod. It closes the draft's D3 in favour of "always for `gpuCount > 1`". The termination canary fingerprints the template rendered for a probe job with `gpuCount: 7`, so its hash moves and every canary taken before this change must be retaken; the probe keeps the volume, which runs anywhere, and still drops the state volume.
- **The training quota.** `config/training/gpuquotapolicy.yaml` admits 4 GPUs to `train-a`, up from 2. Argo syncs `config/training` from `main`.
- **Node qualification takes the expected GPU count.** `train_qualify_nodes` required allocatable `nvidia.com/gpu` 1; it now takes the count per node, required rather than defaulted: 4 here, 1 for `TRAIN=ddp`.
- **The qualification job takes the expected Pod count, and finds its Pods by the Job controller's label.** `train_qualification_held` required two Pods selected by the platform's `mltrainingjob` label, which only a `distributed` job carries; it now takes the count and selects `batch.kubernetes.io/job-name`, which every Job's Pods carry (astra, finding 1).

## The session

`TRAIN=allreduce` in `hack/eks-gitops-session.sh`, on a cluster it creates, reusing the training session's gates.

**Before the cluster is built**, the session refuses unless the two approved hashes equal the files', `NCCLTESTS_IMAGE` names an image by digest, and `TTL_MINUTES` covers every bounded wait (at least 310, below); `hack/test/check-train-session-refusals.sh` shows each refusal stopping it before Terraform.

**After the cluster is built and before any GPU is bought** (the cluster bills from its apply): T1 the training Application synced from `main`; T2 `gpu-train-a` Active and the only ClusterQueue; T3 the qualification job, one Pod of four GPUs, admitted and held unplaced with `admittedAt`; T4 the g5.12xlarge On-Demand price, read live, at most `TRAIN_MAX_PRICE` ($6.98 by default in this mode: the price read on 2026-10-26 rounded up to the cent, so any rise refuses and the approved budget stays the one spent); T5 the G and VT On-Demand vCPU in use plus 48 within the quota; Z1 the group's subnets' zones; the AWS GPU deadline registered.

**After the scale-up:**
- T6 exactly one node in the group, Ready, advertising allocatable `nvidia.com/gpu` **4**, with a Ready device plugin and no simulator; Z2 the node's zone recorded.
- T7 the qualification job ran and succeeded. Its one Pod, in the nccl-tests image, prints `nvidia-smi -L`, each card's UUID, PCI bus ID and driver, `nvidia-smi topo -m`, `nvidia-smi topo -p2p r`, `nvidia-smi -q` and `/dev/shm`'s size, and exits 3 unless it sees four distinct UUIDs.
- **Q** the session scores that log (below) and stops if it is not valid.
- T7b a warm job, one Pod of four GPUs in the torch image, that prints torch's device count and NCCL version and fails unless it sees four devices; it also pulls the torch image, so no measured job carries a first pull.
- The five smoke jobs, then the 25 registered jobs, then the scorer.

**Capacity type: On-Demand.** The `gpu` group is On-Demand for queuelab's reason (`infra/aws/cluster/eks.tf`); splitting its capacity type changes queuelab's group too. The draft's D1 stays closed in favour of On-Demand.

**Zone: unpinned, recorded.** One node carries every rank, so no rank's traffic leaves the node; the zone changes only where the image pull crosses. `TRAIN_AZ` may still pin it.

## Validity lines

A job is **valid** only if every line holds; a line whose evidence is missing **fails** it. `experiments/multi-gpu-throughput/analyze.py` applies them, and each is shown able to fail by a fixture that breaks only it (`test_analyze.py`; mutations of the scorer in "Build status").

1. **Admission and placement.** The MLTrainingJob ended Succeeded within the 240 s budget; exactly one Kueue Workload is owned by its Job and reserves `nvidia.com/gpu` 4 in total; the arm's Pod count was created, with completion indexes 0 to 3 for four Pods, and every Pod ran on the one qualified node. A one-Pod job is a Job with Kubernetes' default `backoffLimit` of 6 (`BuildJob` sets none outside `distributed`), so a failing Pod is retried; every Pod ever created is counted, so a retried job is invalid, and its retries spend its budget.
2. **Rank identity.** Every Pod's log carries this job's run id; every JSON record carries it; a line that looks like a record and does not parse fails the job. In four Pods of one, each Pod's log holds exactly its own rank's start record, the rank equal to the Pod's completion index. Ranks 0 to 3 each started once and ended with exit code 0.
3. **Four distinct GPUs.** The four ranks name four distinct GPU UUIDs (torch arms). For nccl-tests, four rank lines with four distinct process ids, whose PCI bus IDs map through the Pod's own `nvidia-smi` query to four distinct UUIDs.
4. **Transport per rank.** Every rank's own process logged at least one `NCCL INFO Channel … via <transport>` line. A line is attributed by the Pod's log it is in and the process id the rank's own record gives, together: in four Pods of one every rank can be pid 1, as run 3's were, so a pid alone across pooled logs could credit one rank with another's line (astra, finding 10).
5. **Correct sums.** As each instrument's section says.
6. **Counts.** Torch bench: warm-up 20, timed 100, the five sizes and no other. DDP bench: the registered model, 20 warm-up and 50 timed pairs. nccl-tests: its printed settings header reads warm-up 20, iterations 100, 1 MiB to 256 MiB by a factor of 4, one GPU and one thread per process, validation 1; and its command carries every registered flag, `-a 3` included.
7. **Software.** The approved script hash; NCCL 2.21.5, as torch reports it or as NCCL's own `NCCL version` line does for nccl-tests; device `cuda`; `OMP_NUM_THREADS` 1.
8. **No NCCL tuning.** Neither configuration file exists, and each Pod started with exactly `NCCL_DEBUG=INFO` and `NCCL_DEBUG_SUBSYS=INIT,GRAPH,ENV` (and, in the nccl-tests image only, its base's `NCCL_VERSION=2.21.5-1` label, which NCCL does not read). A variable NCCL logs as "set by environment" that the Pod did not start with was set by the software stack itself; it is recorded and published beside the figure, not refused, because nothing here could have prevented it.
9. **`/dev/shm`.** A Pod with four GPUs reports at least 1 GiB.
10. **A physical ceiling.** No bus bandwidth above 64 GB/s, NVIDIA's stated interconnect figure for the card; a figure above it is an instrument error, and the job is invalid rather than fast. (One direction of PCIe Gen4 x16 is about half that, the tighter physical expectation, but NVIDIA's table states 64, so 64 is the line.)

**Q, the node's qualification**, is valid only if the T7 log carries four distinct UUIDs, exactly one driver version, a 4 × 4 `topo -m` matrix among the GPUs, and `/dev/shm` of at least 1 GiB. An invalid Q voids the run.

## Endpoints and units

- **E1, bus bandwidth (GB/s, 10⁹ bytes per second), per arm and size:** the median over the arm's five registered jobs of each job's figure, every job's figure printed beside it.
- **E2, transport, per arm and rank:** the set NCCL logged, in every job, and any NCCL setting the stack applied on its own.
- **E3, topology:** the T7 `topo -m` and `topo -p2p r` matrices, each UUID's PCI bus ID, and the driver version.
- **E4, step time (ms), per DDP arm:** the medians over five jobs of each job's median synced step, median local step and synchronisation cost, and the bucket sizes DDP reported.
- **E5, admission:** per job, the Workload's reserved GPUs, its pod sets and each Pod's node.
- **E6, instruments side by side:** nccl-tests' E1 divided by `allreduce-1pod4gpu`'s, per size. Reported, not judged: the two differ in warm-up, in timing (a mean of a loop against a median of operations) and in what they check, so no tolerance could be derived.

## Verdict rules

Applied only when all five registered jobs of both arms involved are valid; otherwise the comparison is "not scored", with the invalid jobs named.

- **V1, bandwidth by layout, at each size S.** "One Pod of four reached higher bus bandwidth than four Pods of one, at S" only if every one of the five `allreduce-1pod4gpu` figures at S exceeds every one of the five `allreduce-4pod1gpu` figures; the mirror sentence when every one is below; otherwise "not distinguished at S". Basis: 2/252 per size, at most 3.97% over the five ("Order and repetitions").
- **V2, step time by layout.** The same rule on the per-job median synced step time.
- **V3, synchronisation cost by layout.** The same rule on the per-job synchronisation cost.
- **V4, what a difference may be attributed to.** A difference found by V1 to V3 is reported as a difference between layouts. Where E2 shows the two layouts' ranks logged different transports, that is reported beside it as an observation that accompanied the difference, not as its cause: the layouts also differ in launcher, namespaces and CPU scheduling, and nothing here varies the transport alone (astra, finding 8).
- **V5, topology statements.** P2P between two cards only from `topo -p2p r` and NCCL's log; the PCIe path (PIX, PXB, PHB, NODE, SYS) only from `topo -m`.

## Predictions, registered before any run

Written so that they can be wrong, and none informed by a measurement of this node.
- `allreduce-4pod1gpu` and `ddp-4pod1gpu` log `NET` for every rank, because each Pod has its own hostname and NCCL distinguishes hosts by it.
- `allreduce-1pod4gpu`, `ddp-1pod4gpu` and `nccltests-1pod4gpu` log `P2P` or `SHM`, and no `NET`.
- V1 separates in favour of the one-Pod layout at 64 and 256 MiB.
- V2 and V3 separate in favour of the one-Pod layout.
No magnitude is predicted: nothing in the tree measures this node's PCIe peer path or its Pod network.

## Falsifiers: what would make this registration's reading wrong

- Two ranks naming one UUID: "four GPUs" was two processes on one card (line 3).
- A rank with no transport line of its own: a transport credited to a rank that never reported one (line 4).
- A figure above 64 GB/s: the timing measured something other than the transfer (line 10).
- Local checksums equal across ranks, or a synced sum off the local mean: the synced equality would prove no reduction (DDP correctness).
- A different NCCL in nccl-tests than in torch, or a configuration file: E6 or a figure would describe settings nobody registered (lines 7 and 8).
- A Pod off the qualified node, or a Workload reserving other than four: the layout was not the one named (line 1).

## What a result would license, and what it would not

It would license: on one g5.12xlarge on EKS, through this platform's rendering and admission, the all-reduce bus bandwidth of NCCL 2.21.5 at five sizes in two layouts, the transports NCCL logged in each, the cards' topology as the container saw it, a synthetic DDP step's time and synchronisation cost in each layout, and nccl-tests' figure beside torch's in one of them.

It would not license:
- **NVLink** anything: the card has none, by NVIDIA's table.
- **InfiniBand, RoCE, RDMA or GPUDirect RDMA:** none is configured.
- **EFA:** the type supports one interface; this platform attaches none and ships no EFA plugin, and nothing here crosses a node.
- **Multi-node scaling:** one node.
- **That a transport caused a difference** (V4).
- Any real model's training throughput: the DDP model is synthetic, sized for its gradient.
- Another card, instance type, driver, NCCL version or tuning.
- nccl-tests across Pods: not run.

## Pinned, and recorded

**Pinned before the session:**
- g5.12xlarge, one node, On-Demand, the `gpu` group (`TRAIN_INSTANCE_TYPE`, `TRAIN_NODES=1`, set by the mode, not by the operator);
- the torch image `docker.io/pytorch/pytorch@sha256:c8268a92a69bd500f8be0e665b2630ee006dadaf7bfbc24249141b15ff622755`, run 3's, 3,337,937,647 compressed bytes (registry manifest, read 2026-10-26);
- the nccl-tests image, built from `experiments/multi-gpu-throughput/nccl-tests/Dockerfile`: base `nvidia/cuda:12.4.1-devel-ubuntu22.04` at its linux/amd64 digest `sha256:5645fec64549cc35930eee9d85aafd2b0006c0c3f22632be5a1d85e2604e9749` (4,112,380,996 compressed bytes, Docker Hub, read 2026-10-26); the base's NCCL checked to be `2.21.5-1+cuda12.4` and the built binary checked to link `libnccl.so.2.21.5`; nccl-tests at commit `8dfeab9eb9bdfdf13503e71e1f33e7f8a208b540` (tag v2.13.11, GitHub, read 2026-10-26); Open MPI `4.1.2-2ubuntu1`. **Built here on 2026-10-26** (local image `sha256:27bb844f…9b71`, 4,248,476,266 bytes uncompressed); a build with the NCCL pin changed to 2.21.4 failed at its first step, as it should. **Pushed 2026-10-27** from the committed Dockerfile (rebuilt from `origin/dev` at `6fe3003f`; every step came from cache and gave the same image `27bb844f…9b71`) to the private `gpu-lab` repository created for it, as `007635145730.dkr.ecr.ap-northeast-2.amazonaws.com/nccl-tests@sha256:27bb844f707101dfc4f03843b6ed4117996191b615123ef43413633531769b71` (tag `v2.13.11-nccl2.21.5-cuda12.4.1`, tags immutable, 4,248,473,059 bytes as ECR reports it); the session names it by that digest;
- the approved sha256 of both benches, fixed at the commit that freezes this page: `allreduce_bench.py` `af802523bcbbeed578a8f5c9c2494116bb49481e478f7ec03fedf6872b0134e3` and `ddp_step_bench.py` `7cad86378795a9586e9d197525292dc437e6710c337dd35f03b667d26b8e7417`;
- the NVIDIA device plugin v0.16.2 by digest (`config/nvidia-device-plugin/daemonset.yaml`) and Kueue v0.18.3, as run 3.

**Recorded, not pinnable:**
- **the driver**: the group uses `AL2023_x86_64_NVIDIA` without a release version, so the AMI is whatever EKS resolves at apply. The driver is recorded from `nvidia-smi` (Q), and the group's `releaseVersion` in the provenance;
- the zone, the node's name and instance ID, the topology matrices.

## Budget, from on-record prices

Every wait below is the session's own bound; every expected figure is an estimate, not a measurement.

**Per-job budget: 240 s, a convention.** It is about four times a job's expected 1 to 1.5 minutes. A job that does not end within it is invalid by timeout. The first version claimed this implied a slowest admissible bandwidth of about 0.32 GB/s; astra showed the claim assumed equal bandwidth at every size and ignored untimed work, and it is withdrawn: this page makes no claim about which bandwidth a timeout corresponds to (astra, finding 3).

**Jobs:** 5 smoke + 25 registered = 30.
**GPU budget:** node 900 s + device plugin 600 s + qualification 1,500 s + warm job 900 s + 30 × (240 + 60) s + scale-down 600 s + 300 s = 13,800 s = 230 min.
**The GPU deadline is set at the GPU budget,** 230 minutes after it is armed, not at the watchdog's remaining time less ten minutes as `TRAIN=ddp` sets it, so a fast setup cannot give the node a longer leash than this bound (astra, finding 4). EventBridge Scheduler fires within its one-minute precision and the scale-down it requests is asynchronous; the lag from the deadline to a terminated g5.12xlarge is not measured here, and is the part of the bound that is not a number.
**`TTL_MINUTES` at least 310:** the GPU budget plus the sync (600 s), queue (300 s) and hold (300 s) waits and the hour the session allows for build and teardown.

| item | expected | bounded |
|---|---|---|
| g5.12xlarge at $6.97442/h | about 60 min: 4 launch and plugin, 6 qualification with the nccl-tests pull, 2 warm with the torch pull, 30 jobs at about 1.5, 3 scale-down: about **$7.0** | 230 min to the GPU deadline: **$26.7**, plus the unmeasured termination lag |
| cluster at about $0.2633/h (`hack/eks-gitops-session.sh` header: control plane, one t3.large, one NAT) | about 2.5 h: about $0.7 | 310 min: about $1.4 |
| the node's 100 GiB gp3 root volume at $0.0912/GB-month | about $0.01 | about $0.07 |
| image pulls through the NAT at $0.059/GB | the torch image's 3.34 GB and the nccl-tests image, at least its base's 4.11 GB: about $0.44 and more by the added layers' compressed size, known when pushed | the same, once per node, the node being one |
| **total** | **about $8** | **about $28, plus the termination lag** |

The stop rule below makes the bound unlikely: a failing smoke job ends the arms after at most five jobs.

**Quota fit.** 48 vCPU against the On-Demand G and VT quota of 52: T5 passes with at most 4 vCPU of other G or VT On-Demand instances running (none ran at the 2026-10-26 read). Two g5.12xlarge (96) cannot run; nothing here asks for two.

## Stop rule, voids and termination

- **The smoke stop rule.** Each smoke job is scored as soon as it ends (`analyze.py --job`); the first that is not valid stops the run before any registered job, the node is scaled down, and the run is reported as a failed smoke with every reason. It is not repeated without the owner's approval. Rehearsed on kind and in `check-allreduce-arms-lib.sh`.
- A refusal before the cluster is built, or from T1 to T5, voids the run before any GPU is bought; it may be repeated under this registration.
- T6, Z2, T7, Q or T7b refusing voids the run after the purchase; it is not repeated without the owner's approval.
- An arm with any invalid registered job reports no figure, and its comparisons are "not scored".
- Neither the benches, the scorer, the arm library nor the session may change between the run and its reading.

**Termination, all existing machinery:**
- the AWS GPU deadline (`hack/lib/gpu-ttl.sh`, EventBridge Scheduler), armed and verified before the scale-up, scales the group to 0 at the GPU budget, so it fires even if this machine dies;
- the laptop watchdog starts the cluster's destroy at `TTL_MINUTES`, with up to three attempts;
- `train_scale_down` follows every instance ID to `terminated` before the deadline is removed, and the session's residue check asks every billing service before disarming the watchdog.
None of these is an instantaneous billing stop, and the bound above says so.
The study sweeper (`infra/aws/bootstrap/sweeper.tf`) terminates instances with a `study-deadline` tag; managed node group instances carry none, so it is not one of this session's guarantees.

## Buying the session

```
AWS_PROFILE=gpu-lab SESSION_CONFIRM=yes TRAIN=allreduce TTL_MINUTES=310 \
  APPROVED_BENCH_SHA256=<allreduce_bench.py at the freezing commit> \
  APPROVED_STEP_SHA256=<ddp_step_bench.py at the freezing commit> \
  NCCLTESTS_IMAGE=<registry>/<repository>@sha256:<the pushed image's digest> \
  hack/eks-gitops-session.sh
```

It needs: the `gpu-lab` SSO role with a live session (the state bucket's KMS key, EKS, EC2, Auto Scaling, Pricing, Service Quotas and EventBridge Scheduler), the bootstrap root's `ttl_scaledown_role_arn` output, an authenticated `gh` (the session refuses while a destroy workflow is queued, or within two hours of the nightly destroy), and `config/training/gpuquotapolicy.yaml` at 4 GPUs on `main`.

## Free rehearsal on kind

`hack/test/rehearse-four-gpu.sh` builds `kind-fourgpu` with one worker whose simulated device plugin advertises four `nvidia.com/gpu`, this tree's operator, Kueue v0.18.3 and `config/training`, and runs, with the training image's CPU twin in place of both images: T3 on the one-Pod qualification job; T6 refusing the simulated node and a count of one; T7 refusing a node with no `nvidia-smi`; one job of every arm; the scorer on each; and the smoke stop rule. What it showed is in "Build status". Nothing on kind is a bandwidth, a transport or a topology.

## Changes from the draft, and why

| draft | here | why |
|---|---|---|
| torch bench as the measurement, nccl-tests a candidate (D4) | both; nccl-tests as the reference in one Pod | nccl-tests practice is the field's reference; one Pod needs no MPI across Pods |
| four layouts at two and four GPUs | two layouts at four GPUs, plus a DDP step in each | the question is four GPUs; two-GPU arms are left for a cross-node session |
| no training step | a synthetic DDP step with a three-way correctness oracle | the question asks for step time with communication that can be measured |
| three jobs per arm, blocked (D7 open) | five, after five smoke jobs, in one random order | five sizes need a family-wise bound, and the bound needs randomization |
| `/dev/shm` an owner decision (D3) | 1 GiB for `gpuCount > 1`, always | NCCL's guide names the need and the size; a failed smoke would cost a session |
| 5 warm-up, 20 timed | 20 and 100, per size in torch; nccl-tests' own warm-up as its source does it | the AWS guide's `-n 100` |
| no ceiling, no budget per job | 64 GB/s; 240 s | NVIDIA's interconnect figure; the GPU deadline needs a sum |

The draft's D2 and D8 (a cross-node pair and its zone) are not part of this registration.

## Review: astra's attack, reconciled

codex `gpt-6-astra` (`model_reasoning_effort=high`, read-only) attacked the first version of this page cold on 2026-10-26, from a prompt that names no place to look (`data/2026-10-27-four-gpu-nccl/astra-attack-prompt.txt`; the reply is `astra-attack.txt`).
It reproduced the arithmetic of the first version where it was arithmetic, and found twelve faults. I re-derived each before acting on it; the "checked" column says how.

| # | finding | checked | disposition |
|---|---|---|---|
| 1 | The session could not run the registration: no `TRAIN=allreduce`, no arm library, scorer or Dockerfile; and the qualification gate selected Pods by a label only `distributed` jobs carry | yes: `applyDistributed` adds `platform.lkhun9311.github.io/mltrainingjob`, `BuildJob` does not | **adopted**: built (Build status); the gate and the collector select `batch.kubernetes.io/job-name` |
| 2 | nccl-tests does not warm each size, so a literal "20 per size" rule voids its arm, and E6 compares different timing procedures | yes: nccl-tests' TimeTest and BenchTime functions in its `src/common.cu` at the pinned commit | **adopted**: its warm-up and timing described as they are; validity reads its own settings header; E6 states the differences; `-a 3` for the slowest rank |
| 3 | The 0.32 GB/s timeout boundary does not follow; the DDP "under a minute" contradicted its own model | yes: 1.5 s at 256 MiB gives 0.268 GB/s and still fits; 50 × 1.25 s is 62.5 s | **adopted**: the boundary claim is withdrawn and 240 s is stated as a convention |
| 4 | The GPU deadline was set from the watchdog, not the GPU budget, so the bound was not enforced; termination is asynchronous; the root volume was not costed; T1 to T5 run after the cluster bills | yes: `gpu_min=$((left_min - 10))` | **adopted**: the deadline is set at the GPU budget in this mode; lag stated as unmeasured; gp3 costed from a price read; wording fixed |
| 5 | The false-separation bound was one-directional while the rule reads both ways, and a cyclic order does not supply exchangeability | yes: 2/252 per test; the rotation preserves each arm's predecessor | **adopted**: two-sided bounds per family; a random order of all 25 jobs |
| 6 | E4 is not "communication the backward did not hide": ranks could start a step skewed by checksum work, and `no_sync()` skips reducer work too | yes: no barrier between pairs in the first bench | **adopted in part**: a barrier before every timed step; the quantity renamed synchronisation cost and described as including the reducer. Per-rank timelines, which would separate the parts, are not built |
| 7 | The gradient total is not the collective's message size | yes: DDP's 25 MiB cap; each weight is 64 MiB | **adopted**: bucket sizes recorded; the page says about four messages near 64 MiB |
| 8 | Different transports do not establish cause; threads and affinity differ by layout | yes: `torchrun` sets `OMP_NUM_THREADS=1` | **adopted**: V4 reports a transport beside a difference, never as its cause; `OMP_NUM_THREADS=1` everywhere; threads and affinity recorded. No intervention that varies transport alone is added |
| 9 | Python's environment cannot see NCCL's configuration files | yes: NCCL reads `/etc/nccl.conf` and `~/.nccl.conf` (astra cites `src/misc/param.cc` at v2.21.5-1; I did not open it, and the probe does not depend on how NCCL reads them) | **adopted**: each Pod reports both files and its `NCCL_` variables; a present file invalidates; NCCL's own "set by environment" lines are recorded |
| 10 | A pid alone cannot attribute a transport across Pods | yes: run 3's ranks were both pid 1 | **adopted**: attribution by Pod log and pid together; fixtures with repeated pids, swapped logs and stale run ids each fail |
| 11 | Equal scalar checksums do not show the reduced gradient is the average | yes: astra's all-zero case passes the first version's checks | **adopted**: the per-parameter mean oracle, with a derived tolerance and zero gradients refused; shown failing on CPU when the reduction is removed |
| 12 | 48 of 52 does not require nothing else running | yes: 52 − 48 = 4 | **adopted**: the quota sentence corrected |

astra also corrected three numbers, all checked and fixed: the extra two-GPU arms' cost (node-minutes, not GPU-minutes), the expected GPU duration (its components summed to 50.5 minutes, not 55; the new estimate is itemised), and 256.06 MiB being 65,536 bytes above the ladder's top, not equal to it.
It could not reproduce the AWS readings, which were not archived then; they are now (`data/2026-10-27-four-gpu-nccl/aws-*.json`).

## Review: codex's bare review of the diff, reconciled

`codex review --uncommitted` (`gpt-6-astra`, `model_reasoning_effort=high`), with no prompt, read the whole uncommitted change on 2026-10-26 (`data/2026-10-27-four-gpu-nccl/codex-review-uncommitted.txt`). It is a static reading: it ran no test. Three findings, each re-derived:

| finding | checked | disposition |
|---|---|---|
| P1: NCCL prints its version banner without the `host:pid:tid … NCCL INFO` prefix, so the scorer found no version and would have stopped the run at its first smoke job | yes: `showVersion` in NCCL v2.21.5-1's `src/init.cc` writes it with a bare `printf` | **adopted**: the banner is read from every line, prefixed or not; the fixture now writes it as NCCL does, and a missing banner fails |
| P2: a state volume the spec mounts at `/dev/shm` would get a second mount there, and the API server would refuse the Job | yes: the API admits that mount path | **adopted**: the tenant's volume keeps the path and no shared-memory volume is added; `TestAStateVolumeAtDevShmIsNotMountedTwice`, red when the guard compares the wrong path |
| P2: a terminal phase read on a poll that began before the budget and answered after it was not marked a timeout | yes: each query may take 20 s | **adopted**: the runner judges the elapsed time after the last answer, and the scorer refuses a job whose `elapsed-seconds` is missing or above 240 |

## Build status

What exists, and what each was shown to do; "measured here" means run on this machine on 2026-10-26.

| piece | file | shown by |
|---|---|---|
| `/dev/shm` rendering | `internal/controller/mltrainingjob_controller.go` | `TestAPodWithSeveralGPUsGetsSharedMemory`; red when rendered at `gpuCount >= 1` and when the medium is dropped; the canary tests updated to model the kept volume |
| the quota of 4 | `config/training/gpuquotapolicy.yaml` | the kind rehearsal's ClusterQueue nominal 4 |
| GPU and Pod counts in the gates | `hack/lib/train-session.sh` | `hack/test/check-train-session-lib.sh`: 1 of 4 and 4 of 1 refused; one Pod held; red when either count is hard-coded again |
| the arms, order, Pod shell and stop rule | `hack/lib/allreduce-arms.sh` | `hack/test/check-allreduce-arms-lib.sh`: the pinned order; each Pod's shell executed against stub tools; a tampered bench exits 86; the qualification output read as a valid Q; the stop rule after a failing smoke job; six mutations of the library each turned it red |
| the session mode | `hack/eks-gitops-session.sh` | `hack/test/check-train-session-refusals.sh`: eight refusals for this mode before Terraform, the mode's settings, an operator's ceiling kept; four mutations each turned it red |
| the DDP bench | `experiments/multi-gpu-throughput/ddp_step_bench.py` | `test_ddp_step_bench.py`; measured here on CPU with gloo in the training image's CPU twin: verified on four ranks, and refused with the reduction removed or the seeds made equal |
| the scorer | `experiments/multi-gpu-throughput/analyze.py` | `test_analyze.py`, 55 tests; nine mutations of the scorer each turned it red; a tenth, sharing one pid map across Pods, survived because the scorer still read each Pod's lines right after that Pod's records, so it did not reproduce the defect; written instead as attribution from pooled logs, it turned six tests red |
| the nccl-tests image | `experiments/multi-gpu-throughput/nccl-tests/Dockerfile` | built here; a changed NCCL pin fails the build |
| the kind rehearsal | `hack/test/rehearse-four-gpu.sh` | run once to completion, 2026-10-26 14:04 to 14:26Z (`hack/four-gpu-rehearsal-20261026T140451Z/`); below |
| the late-answer recheck | `hack/lib/allreduce-arms.sh` | `check-allreduce-arms-lib.sh`: a Succeeded read two seconds into a one-second budget is a timeout; red with the recheck removed |

**The kind rehearsal, measured.** On `kind-fourgpu` (one worker advertising four simulated `nvidia.com/gpu`), the run of 14:04Z showed: `config/training` producing ClusterQueue `gpu-train-a` with nominal 4; T3 holding the one-Pod qualification job Admitted and unplaced, and refusing when two Pods were expected; T6 refusing the simulated node, and refusing four GPUs where one was expected; T7 refusing a qualification run on a node with no `nvidia-smi`, the Pod's own log naming the missing tool; every arm admitted as one Workload reserving 4 with every Pod on the worker, `/dev/shm` 1,048,576 KiB in the Pods of four GPUs and 65,536 KiB in the Pods of one; torchrun giving the DDP bench four distinct `LOCAL_RANK`s and four Pods of one giving none; the all-reduce bench refusing for want of CUDA; the scorer finding every job INVALID; and the smoke stop rule ending the run after its first job.
It also found two defects, both fixed after it:
- **Followed logs ended early.** The host had exhausted its inotify instances (`max_user_instances` 512, with four other kind clusters up), the kubelet's follow answered "failed to create fsnotify watcher: too many open files", and the DDP Pods' saved logs held only their start records, so the rehearsal's own checks of the DDP path failed. The runner now reads every surviving Pod's whole log once more, without following, before it deletes the job. On EKS the node is the session's own, but the defect is the collector's, not kind's.
- **A failing one-Pod job is retried.** The nccl-tests and one-Pod bench jobs, failing here, were retried by the Job controller up to its default `backoffLimit` and ran into the budget with five Pods each; validity line 1 now says so, and the rehearsal no longer expects one Pod of a failing job.
A second run, to show the first fix on kind, could not start its operator: the same inotify exhaustion crash-looped `kube-proxy` ("failed complete: too many open files"), so Service traffic and the admission webhooks never answered; it was stopped and its cluster deleted. **So the final-read fix is tested by reading, not on kind.** I also edited the rehearsal script while the first run was executing it, after its last measured step; its verdict lines printed as written, but that run is not a clean execution of the file as it now stands.

## Run 1, 2026-10-27: VOID at Q, after the purchase, because the scorer could not read the topology header nvidia-smi printed

**What ran.** `hack/eks-gitops-session.sh` with the command in "Buying the session", from a clean worktree at `main` `c3b36e04`, started 09:58:39Z.
Every check before the purchase passed: T1 synced at `c3b36e04`, T2, T3 (admitted 10:14:30Z, held unplaced), T4 at $6.97442 an hour against the $6.98 ceiling, T5 (0 in use plus 48 within 52), Z1, and the GPU deadline armed for 230 minutes.
The node was `i-019bd1b36bf31ec80` in ap-northeast-2c; T6, Z2 and T7 passed, the qualification job running 153.570 s after admission and succeeding.

**What failed.** Q refused with "nvidia-smi topo -m printed no 4 x 4 GPU matrix", so the session scaled the group to 0 before any registered or smoke job, and the run is void under "Stop rule, voids and termination".
The matrix was printed and complete.
`nvidia-smi` underlined its header with ANSI escapes although no terminal was attached, so the captured line begins `\t\x1b[4mGPU0\tGPU1`, and `judge_qualification` matched the header with `^\s*GPU0`, which the escape defeats.
The rest of Q held in the log: four distinct UUIDs, one driver (580.178.04), and `/dev/shm` of 1,048,576 KiB.
Nothing checked a header carrying escapes before the purchase: the scorer's fixture, `check-allreduce-arms-lib.sh`'s qualification body and the kind rehearsal's stubbed `nvidia-smi` all printed the plain form.

**What the void run's log shows, and is not a result.** Every GPU pair reads `PHB` in `topo -m`, a path through the CPU's PCIe host bridge, and every pair reads `NS`, not supported, in `topo -p2p r`.
That is one node's report on one day; it is recorded because it bears on how any figure of run 2 may be read, and it is not one of this page's endpoints.

**Teardown.** The GPU instance was launched at 10:14:52Z and terminated at 10:20:27Z (CloudTrail); the cluster's destroy finished at 10:38:36Z with every residue query answered and empty, and the watchdog was disarmed.
**Cost, estimated from the rates in "Budget", not billed:** 335 s of g5.12xlarge at $6.97442 an hour, about $0.65, and about 39.5 minutes of the cluster at $0.2633 an hour, about $0.17.

**The fix** (`faba4156`): `judge_qualification` strips ANSI escape sequences from every line before reading it.
A test carrying run 1's header byte for byte failed before the fix with the run's own message, and with the strip removed it failed again; since run 2's amendment it is `test_the_capture_with_its_underlined_headers`, which reads run 2's whole captured log, both underlined headers included.
`analyze.py`'s 93 tests with the two benches' pass, and `judge_qualification` on run 1's own log now returns no fault.

**Evidence:** `hack/four-gpu/2026-10-27-run1/`, 37 files listed in `SHA256SUMS`; `NOT-COMMITTED.sha256` holds the hashes of `terraform.log`, `seeded-key.txt` and `ttl.pid`, which are not committed.

## Amendment for run 2, 2026-10-27, approved by the owner before it is bought

The owner approved a second session on 2026-10-27 ("권장안 진행"), after run 1's record and this amendment's proposal were reported to them.
"Not repeated without the owner's approval" is lifted for exactly one more attempt, run 2: a run 2 that fails for any reason is reported as it ran, and a third needs its own amendment and approval.

**What changes**, and only this: `judge_qualification` in `experiments/multi-gpu-throughput/analyze.py` reads each line of the qualification log with ANSI escape sequences removed (`faba4156`).

**A second change, added before run 2 is bought, 2026-10-27.** The owner asked that the work continue after consulting codex, and codex `gpt-6-astra`, asked what could void run 2, found that `CHANNEL` required `Channel NN/N`, while NCCL 2.21.5 prints SHM's channel lines without the connection index (`src/transport/shm.cc:95`, read at tag `v2.21.5-1`; P2P and NET print it, `p2p.cc:364`, `net.cc:195`).
Every rank of a job whose channels all ran over SHM would then have logged "no channel transport" and been invalid, and run 1 showed no peer-to-peer support between any pair of the node's GPUs, which makes SHM the likely transport.
I re-derived it from NCCL's source and the test fixtures: the fixtures had given SHM the `/0` it never prints; written in the vendor's form, six scorer tests failed, and with `CHANNEL` accepting both forms (`9f3d0f19`) all pass, and reverting the pattern fails them again.
This changes which lines are read as transport evidence and nothing that is judged from them.
**The owner has not yet seen this second change; merging the promotion that carries it to `main` is the owner's confirmation of it**, and a run 2 bought from a `main` without it is bought under the first change alone.

**What does not change:** the question, the arms, the order and repetitions, both benches and their approved hashes, the nccl-tests image digest, the validity lines, endpoints, verdict rules, predictions, falsifiers, the stop rule, the termination chain, the TTL, the price ceiling and the GPU budget.
The approved hashes still name the benches at this commit: `allreduce_bench.py` af802523… and `ddp_step_bench.py` 7cad8637…, unchanged by the fix.

**Run 2 is bought from `main` at the promotion that carries this section**, which replaces "this commit's, as promoted to `main`" in the status line for run 2 only, with the command in "Buying the session" and the values in "Pinned, and recorded".
Run 1's evidence is not pooled with run 2's.

## Run 2, 2026-10-28: a FAILED SMOKE, because the scorer read nccl-tests' bus number as a GPU address

**What ran.** `hack/eks-gitops-session.sh` with the command in "Buying the session", from a clean worktree at `main` `1b4a8c07`, which carries both changes of "Amendment for run 2", started 22:43:34Z on 2026-10-27.
It was started after that day's nightly destroy had completed (21:38Z), and the owner approved the paid session again on 2026-10-28 ("유료 실행 승인") after renewing the credentials.
Every check before the purchase passed: T1 synced at `1b4a8c07`, T2, T3 (admitted 23:00:51Z, held unplaced), T4 at $6.97442 an hour against the $6.98 ceiling, T5 (0 in use plus 48 within 52), Z1, and the GPU deadline armed for 230 minutes.
The node was `i-0438f3f0577d816d2` in ap-northeast-2c; T6, Z2 and T7 passed, the qualification job running 200.775 s after admission.
**Q passed** with run 2's fix: four distinct UUIDs, one driver, a 4 x 4 topology and 1 GiB of `/dev/shm`; T7b passed (`AR_WARM` four devices, NCCL 2.21.5).

**What failed.** The first smoke job, `nccltests-1pod4gpu`, succeeded in 50 s and was judged invalid: "the ranks' bus IDs map to 1 distinct GPU UUID(s), want 4".
Under "Stop rule, voids and termination" the session stopped before any registered job and scaled the group to 0; the run is a failed smoke.
The job had run on four GPUs.
nccl-tests' rank line prints `[0x00]` for every rank, which is the PCI bus number alone, and this node puts all four GPUs on bus 00, at devices 1B, 1C, 1D and 1E (`AR_GPU` lines: `00000000:00:1B.0` to `00000000:00:1E.0`).
The scorer keyed the GPUs by that bus number, so all four collapsed onto one key, and it was matching the wrong field besides: its fixtures had put the GPUs on buses 1B to 1E at device 00, a layout this node does not have.
NCCL's own init lines name each rank's whole address, `rank 0 … busId 1b0` to `rank 3 … busId 1e0`, under four distinct process IDs.
The job's channel lines all read `via SHM/direct/direct` (28 lines, none P2P), so the second change of "Amendment for run 2" was needed: without it this job would also have been invalid, for want of a transport.

**Teardown.** The GPU instance was launched at 23:01:04Z and terminated at 23:10:48Z (CloudTrail); the cluster's destroy finished at 23:28:43Z with every residue query answered and empty, and the watchdog was disarmed.
**Cost, estimated from the rates in "Budget", not billed:** 584 s of g5.12xlarge at $6.97442 an hour, about $1.13, and about 44.7 minutes of the cluster at $0.2633 an hour, about $0.20.

**The fix:** `check_nccltests_job` maps each rank to a GPU through NCCL's `ncclCommInitRank … Init COMPLETE` line, joined to the rank line by process ID and rank, and keys the `AR_GPU` lines by their whole address, as the hex digits of domain, bus, device and function run together, the form NCCL prints.
The fixtures now carry this node's layout, and `test_the_smoke_job_that_was_voided_reads_as_four_gpus` judges run 2's committed smoke job directory as it was captured: with the fix it has no fault and four distinct UUIDs; against the unfixed scorer it fails, with five other tests.
`analyze.py`'s 57 tests, the two benches' tests and `check-allreduce-arms-lib.sh` pass.

**Evidence:** `hack/four-gpu/2026-10-27-run2/`, listed in `SHA256SUMS`; `NOT-COMMITTED.sha256` holds the hashes of `terraform.log`, `seeded-key.txt` and `ttl.pid`, which are not committed. `session-stdout.log` is the session's terminal output.

## Amendment for run 3, 2026-10-28, approved by the owner before it is bought

The owner approved it on 2026-10-28 ("sso login 완료, 권장안 진행"), in reply to a report that named this amendment, its new bench hashes and its disclosed collection budget as waiting for their approval, after every change below had been merged into `dev` (#422, #425, #426).
"Not repeated without the owner's approval" is lifted for exactly one more attempt, run 3: a run 3 that fails for any reason is reported as it ran, and a fourth needs its own amendment and approval.

Run 2 is reported as it ran, and under "Amendment for run 2" a third attempt needs its own amendment and approval.
**What changes**, these three and nothing else. First, `check_nccltests_job` reads which GPU each rank used from NCCL's init line instead of nccl-tests' rank line, as "Run 2" describes.
It changes which lines identify a rank's GPU and nothing judged from them: one process per rank, four distinct UUIDs, and every other validity line stand as registered.
**Two refusals are added, found by codex `gpt-6-astra` in a whole-project audit on 2026-10-28 and re-derived here; each only refuses what the registration already does not accept.**
A DDP job whose rank-0 step times are not finite, or whose synced or local time is not positive, is invalid: Python's `json` reads `NaN`, and a `NaN` median compared false in both directions, so V2 and V3 would have printed "not distinguished" over it instead of refusing (`test_ddp_nan_step_time`, `test_ddp_negative_step_time`).
The aggregate score fails unless each arm has exactly one smoke job and it is valid, as "Order and repetitions" requires; before, an invalid or missing smoke job printed and the run could still PASS when the runner's `STOPPED` marker was absent (`test_an_invalid_smoke_job_fails_the_run`, `test_a_missing_smoke_job_fails_the_run`; the old `test_smoke_jobs_are_not_counted` had pinned the PASS and now pins that the smoke job's figure is left out of the medians).
With each new check removed, its tests fail; `analyze.py`'s 61 tests, the benches' and `check-allreduce-arms-lib.sh` pass.
**Further refusals, from codex `gpt-6-astra`'s adversarial review of this purchase on 2026-10-28**, which concluded "buy after" them; each was re-derived here, and each new check, removed, fails its own test.
- **Distinct executions.** No two jobs, smoke or counted, may share a run id, a Job UID or a Pod UID, and both jobs that do are invalid, so neither reaches a median or a verdict (codex's bare review of the first version found the copies still counted); a valid smoke job copied over the five registered jobs of its arm had read as five repetitions and passed (`test_one_execution_copied_into_five_repetitions_fails`). The fixtures now give each job its own UIDs, as the cluster does.
- **One measurement per size.** nccl-tests' result rows and the torch benches' size records were kept in dictionaries by size, so a failing row followed by a passing one read as passing; a duplicate now makes the job invalid. The nccl-tests header is compared in every field it prints, the factor of 4, one aggregation iteration and no graph among them, as run 2 captured it.
- **Both topology matrices, each in its own section.** Q read the whole log for any GPU0-to-GPU3 header and four row labels: the `topo -p2p r` header could stand in for `topo -m`'s, labels without values passed, and a missing `topo -p2p r` section, which E3 needs, passed too. Each matrix is now read from its own section and must have X on the diagonal and only its legend's values elsewhere. The qualification tests now run on run 2's captured log instead of an imagined one, and the shell gate's stub prints run 2's bus layout and `topo -p2p r` matrix; run 1's and run 2's logs both pass.
- **Finite raw timings.** Both benches refused a time of zero or less, but a NaN is not, and `max()` over a column holding one could return the other rank's time, so a rank of NaNs summarised to a finite figure. Both now refuse a non-finite time, and the scorer refuses a DDP record whose `sync_cost_ms` is not its synced median less its local one.
**This changes both benches, so the approved hashes change**: `allreduce_bench.py` `0e9e939db4864907a24fc3acef4959b7f1c0fb51cf77e3859bac9065fd6eee00` and `ddp_step_bench.py` `d37981777c791af1420525232f66acbec83e2f5e61241984b79ad58134384402` replace af802523… and 7cad8637… for run 3; the change is the refusal and its `import math`, and nothing a valid record holds.
**One finding is not acted on and is disclosed:** a job's collection, bounded by its timeouts, could take up to about 445 s (four log reads of 60 s, four reads of 20 s, a 120 s delete and 5 s), against the 60 s per job the GPU budget allows. Run 2's collection took seconds, and a GPU deadline reached mid-job makes that job invalid and its arm figureless; it costs money, not a false result.
**What does not change:** everything "Amendment for run 2" lists as unchanged except the two bench hashes, and its two changes.
**Run 3 is bought from `main` at the promotion that carries this section, with `APPROVED_BENCH_SHA256` and `APPROVED_STEP_SHA256` set to the two hashes above;** the owner's general approval of paid sessions earlier on 2026-10-28 was given before this change existed and is not what approves it.
Run 1's and run 2's evidence are not pooled with run 3's.

## Run 3, 2026-10-29: a FAILED SMOKE, because the scorer read only records that start their log line

**What ran.** The command in "Buying the session" with the two hashes of "Amendment for run 3", from a clean worktree at `main` `64b264f6`, CI's image pin after the promotion `108d8a02` (#432) that carries that amendment; started 00:55:33Z on 2026-10-29.
The promotion left out two dependency updates that had reached `dev` (#429, #430: Kueue v0.20.3 among them), so the operator's Kueue library was the one run 2 ran with.
Every check before the purchase passed: T1 synced at `64b264f6`, T2, T3 (admitted 01:10:14Z, held unplaced), T4 at $6.97442 an hour against the $6.98 ceiling, T5 (0 in use plus 48 within 52), Z1, and the GPU deadline armed for 230 minutes.
The node was `i-003b517e681535b48` in ap-northeast-2c; T6, Z2 and T7 passed, the qualification job running 154.005 s after admission.
**Q passed**, and T7b passed (`AR_WARM` four devices, NCCL 2.21.5).
**Run 2's fix held on hardware:** the smoke job `nccltests-1pod4gpu` was judged valid, its four ranks on four distinct GPUs, and so was `allreduce-1pod4gpu`.

**What failed.** The third smoke job, `allreduce-4pod1gpu`, succeeded in 50 s and was judged invalid: on every rank, "recorded sizes [4194304, 16777216, 67108864, 268435456], want [1048576, …]".
Under "Stop rule, voids and termination" the session stopped before any registered job and scaled the group to 0; the run is a failed smoke, and this arm had never run on hardware before (run 1 stopped at Q, run 2 at the first smoke job, and the kind rehearsal's ranks are stubs with no NCCL threads).
**Every rank had written its 1 MiB record, whole.** NCCL's threads print to the same Pod log, and each rank's had begun a message without its newline when the bench wrote that record, so the merged log carries the record on the end of a cut NCCL line: after "via NE" on three ranks and "threadThresholds 8/8/6" on the fourth, with the cut message's rest (`T/Socket/0` and the like) on a later line of its own.
The scorer read a record only from a line that starts with `{`, so it never saw the four, and the bench's guarantee that a record is one atomic write was kept: what it never addressed is NCCL's stderr in the same Pod.
In all 32 captured logs of runs 1 to 3 and the rehearsal, 1,738 NCCL INFO lines, exactly these four carry `{"`, and each parses as its rank's 1 MiB record.

**Teardown, and a residue the session did not clear.** The GPU instance was launched at 01:10:33Z and terminated at 01:21:07Z (EC2); the session's cluster destroy failed at 01:59Z with AWS's DependencyViolation (in the uncommitted `terraform.log`) on a security group and a subnet, held by a detached network interface the VPC CNI had left from the CPU node (`eni-040e4ce7ff9b54156`, `aws-K8S-i-04fc4876feb7e3688`, status available).
Nothing billable remained: no cluster, instance, NAT gateway, Elastic IP, volume, load balancer, Auto Scaling group, log group or GPU deadline schedule.
I deleted the interface and ran the same cluster destroy by hand, which completed at 02:01:05Z; every residue query above came back empty, and I then disarmed the watchdog (`manual-destroy.log`).
**Cost, estimated from the rates in "Budget", not billed:** 634 s of g5.12xlarge at $6.97442 an hour, about $1.23, and about 65 minutes of the cluster (00:56:03Z to 02:01:05Z) at $0.2633 an hour, about $0.29.

**The fix:** `records_of` reads a record that follows a cut NCCL INFO line, from its first `{"`, and a cut record there still fails the job as one that does not parse; the cut NCCL line is left out of transport attribution, its `via` token being incomplete.
`test_the_smoke_job_whose_records_followed_nccl_fragments_is_whole` judges run 3's committed smoke job as it was captured: with the fix it has no fault and NET on all four ranks; with records read only from lines starting `{`, it fails, and so does `test_a_record_cut_in_half_after_an_nccl_fragment`; with the cut line attributed, it fails on a transport "NE…".
Run 3's other two smoke jobs are valid with and without it.
`analyze.py`'s 71 tests, the benches' tests and `check-allreduce-arms-lib.sh` pass.

**Evidence:** `hack/four-gpu/2026-10-29-run3/`, listed in `SHA256SUMS`; `NOT-COMMITTED.sha256` holds the hashes of `terraform.log`, `seeded-key.txt` and `ttl.pid`, which are not committed. `session-stdout.log` is the session's terminal output and `launcher.log` the launcher's.

## Amendment for run 4, 2026-10-29, approved by the owner before it is bought

The owner approved it on 2026-10-29 ("권장안 진행"), in reply to a report that named this amendment as waiting for their approval, after the fix had been merged into `dev` (#442).
"Not repeated without the owner's approval" is lifted for exactly one more attempt, run 4: a run 4 that fails for any reason is reported as it ran, and a fifth needs its own amendment and approval.

Run 3 is reported as it ran, and under "Amendment for run 3" a fourth attempt needs its own amendment and approval.
**What changes**, this and nothing else: the fix above, in `analyze.py`.
It changes where a record may start on its log line and which NCCL lines name a transport, and nothing judged from either.
The benches do not change, so the approved hashes stay `0e9e939d…` and `d3798177…`.
**Disclosed, not acted on:** the same cut can in principle fall before an nccl-tests result row, which the scorer reads only from a line's start; in runs 2 and 3 none did, the rows coming after NCCL's initialisation messages, and a row lost that way makes the job invalid, a cost and not a false result.
**What does not change:** everything "Amendment for run 3" lists as unchanged, its changes and its hashes.
**Run 4 is bought from `main` at the promotion that carries this section, with the two hashes above.**
That promotion carries, besides this page and the fix, only two changes to the session's own teardown: the GPU deadline refuses to arm or report when a schedule cannot be read (#436), and the cluster destroy sweeps the interfaces the VPC CNI left detached and retries once (#443).
It leaves out every other change merged into `dev` since run 3's promotion, the dependency updates (#429, #430) and the operator and gateway fixes of #433 to #440 among them, so the platform run 4 measures is the one run 3 ran on.
Run 1's, run 2's and run 3's evidence are not pooled with run 4's.

## Run 4, 2026-10-29: a FAILED SMOKE, because run 3's fix read a record only after a cut it recognised as NCCL's

**What ran.** The command in "Buying the session" with the two hashes of "Amendment for run 3", from a clean worktree at `main` `89d74921`, CI's image pin after the promotion `5bc124e3` (#445) that carries "Amendment for run 4"; started 04:17:34Z on 2026-10-29.
Every check before the purchase passed: T1 synced at `89d74921`, T2, T3 (admitted 04:33:49Z, held unplaced), T4 at $6.97442 an hour against the $6.98 ceiling, T5 (0 in use plus 48 within 52), Z1, and the GPU deadline armed for 230 minutes.
The node was `i-00ba7032b92e53215` in ap-northeast-2a; T6, Z2 and T7 passed, the qualification job running 149.511 s after admission.
**Q passed**, and T7b passed (`AR_WARM` four devices, NCCL 2.21.5).
**Run 3's fix held on hardware:** `allreduce-4pod1gpu`, the smoke job run 3 stopped at, was judged valid with NET on all four ranks, its four 1 MiB records again following cut NCCL lines; so were `nccltests-1pod4gpu`, `allreduce-1pod4gpu` and `ddp-1pod4gpu`.

**What failed.** The fifth smoke job, `ddp-4pod1gpu`, succeeded and was judged invalid: "rank 1 has 0 steps record(s), want 1", and the same for ranks 2 and 3.
Under "Stop rule, voids and termination" the session stopped before any registered job and scaled the group to 0; the run is a failed smoke, and this arm had never run on hardware before.
**Every rank had written its steps record, whole**, onto the end of a cut NCCL line as in run 3; rank 0's cut fell after "NCCL INFO" ("TUNER/Plugin: Plu"), and ranks 1 to 3's fell inside NCCL's host prefix ("c-smoke-d", "c-smoke-dd", "c-smoke-ddp-"), with the message's rest ("dp-4pod1gpu-044233-3:1:72 [0] NCCL INFO Connected all trees") on a later line.
Run 3's fix read a record after a cut only when what preceded it matched the pattern of a whole NCCL INFO line's start, so it read rank 0's and lost the other three.
That fix was written from the four cuts run 3 had shown, all of which fell after "NCCL INFO", and was tested on those four; nothing tested a cut anywhere else in NCCL's line.
In the committed logs of runs 1 to 4, 12 records follow a cut: run 3's four, and run 4's eight, in its two four-Pod smoke jobs.

**Teardown.** The GPU instance was launched at 04:34:08Z and terminated at 04:45:28Z (EC2).
The cluster destroy failed at 05:25:23Z on a detached interface the VPC CNI had left, as in run 3; the session's sweep (#443) deleted `eni-03a91e472ab5d5d2d` at 05:25:25Z, the retried destroy succeeded, every residue query was answered and empty, and the session disarmed its watchdog at 05:25:38Z, with no hand step.
**Cost, estimated from the rates in "Budget", not billed:** 680 s of g5.12xlarge at $6.97442 an hour, about $1.32, and about 67.6 minutes of the cluster (04:18:04Z to 05:25:38Z) at $0.2633 an hour, about $0.30.

**A correction to run 3's evidence.** Both runs' `launcher.log` end "session exited 0", and neither session did: run 4's printed "2 check(s) failed" and run 3's "CLUSTER DESTROY FAILED".
The launcher wrote `$?` after a `$(date …)` in the same line, which reset it; the launcher is not part of the repository, and the session's own output in `session-stdout.log` is the record of how each ended.

**The fix:** `records_of` reads a record from a line's first `{"`, whatever precedes it; a cut record there still fails the job as one that does not parse, and a line carrying a record is still left out of transport attribution.
`test_the_smoke_job_whose_records_followed_a_cut_host_prefix_is_whole` judges run 4's committed smoke job as it was captured: with the fix it has no fault and NET on all four ranks; with run 3's rule back, it fails.
`test_a_record_after_any_cut_of_any_captured_nccl_line` cuts each distinct NCCL INFO line in the committed logs of the paid runs at every offset and appends a record, which must read back whole; with run 3's rule back, it fails at the first offset.
With the fix, `analyze.py` on run 4's whole evidence judges all five smoke jobs valid, and on run 3's, its three; dev's scorer on run 4's evidence prints the session's own judgement.
`analyze.py`'s 73 tests pass.

**Evidence:** `hack/four-gpu/2026-10-29-run4/`, listed in `SHA256SUMS`; `NOT-COMMITTED.sha256` holds the hashes of `terraform.log`, `seeded-key.txt` and `ttl.pid`, which are not committed. `session-stdout.log` is the session's terminal output and `launcher.log` the launcher's.

## Amendment for run 5, 2026-10-29, approved by the owner before it is bought

The owner approved it on 2026-10-29 ("권장안 진행, 승인"), in reply to a report that named this amendment as waiting for their approval, after the fix had been merged into `dev` (#446).
"Not repeated without the owner's approval" is lifted for exactly one more attempt, run 5: a run 5 that fails for any reason is reported as it ran, and a sixth needs its own amendment and approval.

Run 4 is reported as it ran, and under "Amendment for run 4" a fifth attempt needs its own amendment and approval.
**What changes**, this and nothing else: the fix above, in `analyze.py`.
It changes where a record may start on its log line, and nothing judged from the record.
The benches do not change, so the approved hashes stay `0e9e939d…` and `d3798177…`.
**Disclosed, not acted on:** an nccl-tests result row is still read only from a line's start, so a cut before one makes the job invalid; in runs 2 to 4 none did, and that is a cost and not a false result.
**What does not change:** everything "Amendment for run 4" lists as unchanged, its changes and its hashes, and its promotion's scope: run 5 is bought from `main` at a promotion that carries this section and the fix, and no other change merged into `dev` since run 3's promotion.
**Run 5 is bought from `main` at that promotion, with the two hashes above.**
Run 1's to run 4's evidence are not pooled with run 5's.

## Run 5, 2026-10-29: COMPLETE, every registered job valid

**What ran.** The command in "Buying the session" with the two hashes of "Amendment for run 3", from a clean worktree at `main` `b14b4e50`, CI's image pin after the promotion `26b06d02` (#448) that carries "Amendment for run 5"; started 07:03:02Z on 2026-10-29.
Every check before the purchase passed: T1 synced at `b14b4e50`, T2, T3 (admitted 07:17:10Z, held unplaced), T4 at $6.97442 an hour against the $6.98 ceiling, T5 (0 in use plus 48 within 52), Z1, and the GPU deadline armed for 230 minutes.
The node was `i-0b66cbb2a8ab182d6` in ap-northeast-2d; T6, Z2 and T7 passed, the qualification job running 163.662 s after admission; Q and T7b passed (`AR_WARM` four devices, NCCL 2.21.5).
The five smoke jobs and the 25 registered jobs ran from 07:23:09Z to 07:45:14Z in the registered order, each succeeding, and T8 passed: every registered job valid.
The scorer's verdict (`c/verdict.txt`) ends "PASS".

**E3, topology, from Q's log.** Four A10Gs at PCI bus IDs `00:1B.0`, `00:1C.0`, `00:1D.0` and `00:1E.0`, driver 580.178.04.
`topo -m` names every pair of cards PHB, and `topo -p2p r` names every pair NS, peer reads not supported.

**E2, transport.** In every job, smoke and registered, every rank of `nccltests-1pod4gpu`, `allreduce-1pod4gpu` and `ddp-1pod4gpu` logged SHM, and every rank of `allreduce-4pod1gpu` and `ddp-4pod1gpu` logged NET; the stack set no NCCL variable of its own in any job.

**E1, bus bandwidth, GB/s:** the median of five jobs, each job's figure in brackets, as the verdict prints them; the `nccltests` column and the two torch columns come from different timers and warm-up histories ("nccl-tests", above), so they are not an apples-to-apples pair.

| Size | `nccltests-1pod4gpu` | `allreduce-1pod4gpu` | `allreduce-4pod1gpu` |
|---|---|---|---|
| 1 MiB | 3.88 [3.83, 3.88, 3.89, 3.80, 3.89] | 3.21 [3.18, 3.23, 3.21, 3.30, 3.20] | 0.81 [0.76, 0.81, 0.81, 0.79, 0.85] |
| 4 MiB | 3.24 [3.24, 3.22, 3.24, 3.23, 3.25] | 2.95 [2.95, 2.96, 2.93, 2.95, 2.95] | 1.34 [1.32, 1.34, 1.36, 1.28, 1.36] |
| 16 MiB | 3.32 [3.32, 3.31, 3.31, 3.32, 3.32] | 3.05 [3.05, 3.06, 3.05, 3.05, 3.05] | 1.54 [1.54, 1.54, 1.62, 1.45, 1.57] |
| 64 MiB | 3.27 [3.27, 3.27, 3.27, 3.27, 3.28] | 3.07 [3.07, 3.07, 3.07, 3.07, 3.07] | 1.62 [1.59, 1.67, 1.66, 1.56, 1.62] |
| 256 MiB | 3.05 [3.05, 3.05, 3.03, 3.05, 3.05] | 3.06 [3.05, 3.06, 3.06, 3.06, 3.06] | 1.67 [1.66, 1.67, 1.68, 1.67, 1.68] |

**E4, DDP step, ms**, the median of five jobs' medians, for a synthetic four-layer model doing forward and backward only: no optimizer step, no data loading, no checkpoint, so not a training throughput.

| | `ddp-1pod4gpu` | `ddp-4pod1gpu` |
|---|---|---|
| synced step | 133.87 [133.63, 133.95, 133.87, 133.89, 133.68] | 249.00 [254.01, 249.00, 246.28, 248.15, 250.03] |
| local step | 3.85 [3.85, 3.85, 3.85, 3.84, 3.85] | 3.98 [3.98, 3.98, 3.98, 3.98, 3.98] |
| synchronisation cost | 130.02 [129.78, 130.10, 130.02, 130.04, 129.83] | 245.02 [250.03, 245.02, 242.30, 244.17, 246.05] |

Every rank of every DDP job reported one bucket of 268,500,992 bytes, rebuilt into four of 67,125,248.

**E6, nccl-tests over torch, one Pod of four, reported and not judged:** 1.207 at 1 MiB, 1.098 at 4 MiB, 1.087 at 16 MiB, 1.065 at 64 MiB and 0.996 at 256 MiB; nccl-tests times 100 back-to-back operations with one timer after warming only 1 and 256 MiB, while torch takes a per-operation median after warming each size, so the ratio mixes the instruments' differences with the frameworks' and does not isolate torch's overhead.

**Verdicts.**
- **V1:** one Pod of four reached higher bus bandwidth than four Pods of one at every size, 1, 4, 16, 64 and 256 MiB: at each, every one of the five one-Pod figures exceeds every one of the four-Pod figures.
- **V2:** one Pod of four had the shorter synced step: every one of its five figures is below every one of the four-Pod layout's.
- **V3:** one Pod of four had the smaller synchronisation cost, by the same rule.
- **V4:** where the layouts differed, the one-Pod ranks logged SHM and the four-Pod ranks NET; that is an observation that accompanied the difference, not its cause.
- **V5:** no pair of cards supports peer reads by `topo -p2p r`, and NCCL logged no P2P in any job; the path between every pair is PHB by `topo -m`.

**Predictions.** All four held: the four-Pod arms logged NET on every rank; the one-Pod arms logged SHM, not P2P, and no NET; V1 separated for the one-Pod layout at 64 and 256 MiB, and at the three smaller sizes too, which was not predicted; V2 and V3 separated for the one-Pod layout.
**Falsifiers.** None was met: every job's four ranks named four distinct UUIDs and logged a transport of their own, no figure exceeds 3.9 GB/s against the 64 GB/s bound, every DDP job's checksums passed, nccl-tests and torch ran NCCL 2.21.5 with no configuration file, and every Pod ran on the qualified node in a Workload reserving four GPUs; each is a validity line, and every job is valid.
**What this licenses** is what "What a result would license" says, and nothing it excludes: in particular, no statement that the transport caused the difference, and nothing about NVLink, RDMA, EFA, more than one node or a real model.

**How the figures were checked.** I re-derived every figure from the raw logs with code of my own, not `analyze.py`: each torch job's figure as the median over its 100 iterations of the slowest rank's time, converted with the bench's bus factor, which agrees with the bench's own figure to within 1e-15; each nccl-tests figure from its out-of-place bus bandwidth column; each DDP figure from the per-rank step times; and the medians, the seven separations and the E6 ratios, all of which agree with the verdict above.
`analyze.py` from `dev`, run on the committed copy of the evidence, prints the session's verdict byte for byte.

**Teardown, and what it needed by hand.** The GPU instance was launched at 07:17:31Z and terminated at 07:47:40Z (EC2).
At 07:54:29Z both destroys failed before they began, terraform being unable to refresh the expired SSO token ("failed to refresh cached credentials ... StatusCode: 400"), while the CLI's cached role credentials were still valid; the session's sweep found no detached interface, correctly, since nothing had been deleted.
Nothing that bills by the GPU remained; the cluster, its CPU node and NAT gateway did.
I ran the same cluster destroy with the CLI's role credentials exported to terraform, which completed at 08:06:23Z (96 destroyed), removed the Argo CD release from the argo-bootstrap state, its cluster having gone with the destroy, and found every residue query empty, after which I disarmed the watchdog (`manual-destroy.log`).
So the session exited 1 on its teardown, and on nothing it measured; the launcher, fixed after run 4, logged that status correctly.
**Cost, estimated from the rates in "Budget", not billed:** 1,809 s of g5.12xlarge at $6.97442 an hour, about $3.50, and about 62.8 minutes of the cluster (07:03:36Z to 08:06:23Z) at $0.2633 an hour, about $0.28.
Over runs 1 to 5, about $7.83 of GPU time and $1.24 of cluster time.

**Evidence:** `hack/four-gpu/2026-10-29-run5/`, listed in `SHA256SUMS`; `NOT-COMMITTED.sha256` holds the hashes of `terraform.log`, `seeded-key.txt` and `ttl.pid`, which are not committed. `session-stdout.log` is the session's terminal output, `launcher.log` the launcher's and `manual-destroy.log` the hand teardown's.
