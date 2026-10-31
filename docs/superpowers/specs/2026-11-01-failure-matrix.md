# Failure matrix: what this project has broken on purpose, what it found broken, and what came back

Written 2026-10-31 from the records listed under "Sources", dated 2026-11-01.
It reports nothing new: every figure is copied from a committed record and cited next to itself as `[KEY:line]`, where KEY names a file in "Sources".
It is a summary for a reader who operates GPU clusters, so it states first what kind of evidence each row is.

## How to read it

Three words carry most of the weight, and they are not interchangeable.
- **Injected** means this project put the fault there itself.
  No row in this matrix is a real hardware fault.
  The two GPU-fault rows are values written into DCGM's cache on a real A10G; NVML never saw them [GF:30-31].
- **Re-admitted** means Kueue reserved quota for the job again and a new Pod started.
  It never means training resumed: the job in the GPU-fault rows is a busybox shell loop that keeps no checkpoint, so everything the displaced attempt did is lost [GF:108] [GF:120].
- **Kind** means a kind cluster, usually with simulated `nvidia.com/gpu` devices.
  Where a row ran on a real card it names the instance.

Times in the GPU-fault rows are the median, minimum and maximum of the **upper ends** of truncation intervals over five repetitions, because Kubernetes condition times are whole seconds [GF:82-87] [GF:122] [GF:361].
Five repetitions give a median and a range, not a rate [GF:102-103].

## Overview

| # | failure mode | injected or found | where | headline | recovered automatically |
|---|---|---|---|---|---|
| 1 | Xid 79 reported by DCGM [GF:96] | injected into DCGM's cache | one g5.2xlarge, real A10G, kind on the instance | end to end median 2.502 s [V:5] | job re-admitted on a simulated device; work lost |
| 2 | double-bit ECC reported by DCGM | injected into DCGM's cache | same session | end to end median 2.324 s [V:18] | as row 1 |
| 3 | corrected (single-bit) ECC, and no change | injected / nothing (controls) | same session | QUIET in 5 of 5 each [V:29] [V:31] | nothing to recover |
| 4 | the GPU exporter disappears, nothing latched | injected (DaemonSet selector) | same session | PASS [V:33] | yes |
| 5 | the GPU exporter disappears, fault latched | injected | same session | FAIL [V:34] | **no**: the platform's own taint kept the exporter off the node |
| 6 | a preempted workload ignores SIGTERM | found by review | queuelab lab | 40-second job occupied 83 seconds [TC:52] | no; the published claim was retracted |
| 7 | a job no node can take is reported Running | found by measurement | kind, simulated devices | 145 of 145 samples wrong [W:287] | fixed in code, re-measured |
| 8 | free GPUs stranded by placement | found by measurement | kind, simulated devices | 2 of 3 runs stranded without a scheduler config [W:365] | no repacking; a scheduler config changes it |
| 9 | a distributed job with one rank placed | injected (squatter Pod) | kind, simulated devices | reported Running for 598.1 of 598.1 s [W:453] | fixed in code, re-measured |
| 10 | one rank fails, or rendezvous fails | injected (environment variables) | kind on CPU; EKS on two g5.xlarge | whole job Failed, peer ended by SIGTERM [DDP:157] | **no**: the job ends Failed by design |
| 11 | a training process is killed mid-run | injected (self SIGKILL) | kind, CPU, one Pod | resumed run bit-identical, diff 0 [CR:83] | yes, from a node-local volume |
| 12 | a distributed job loses a rank and needs its state | not run | — | refused by the API [API:36] | no path exists |
| 13 | the llm-d router's endpoint picker dies | injected | kind | uncounted rehearsal, not a result | — |

## Row 1 — Xid 79 reported by DCGM

| field | value |
|---|---|
| how injected | `dcgmi test --inject`, field 230 (`DCGM_FI_DEV_XID_ERRORS`) := 79, "GPU has fallen off the bus" [GF:23] [GF:27] [GF:96]. **An injection into DCGM's cache, not a hardware fault.** The device plugin reads NVML, not DCGM, so `allocatable` was expected to stay put [GF:29-31], and it did: P5 held [V:2], `alloc_before=1`, `alloc_after=1` [GF:365] |
| where | one g5.2xlarge Spot instance (one A10G) [P:5], `i-09d3bd39d799d566f` in ap-northeast-2a [GF:388], driver 595.91.07 [GF:386]. A kind cluster on the instance: the worker T holds the real card; the control-plane H advertises one **simulated** GPU [GF:189-192] |
| detection signal | the operator scrapes each node's dcgm-exporter once a second, 0.8 s timeout, data stale after 5 s [GF:47]; any Xid other than 13, 31, 43, 45 or 68 is a fault [GF:74] |
| platform reaction | `GPUHealthy=False` and taint `platform.lkhun9311.github.io/gpu-fault=true:NoSchedule` on the node [GF:56]; the Kueue Workload of each GPU Pod deactivated [GF:57]; Kueue evicts, the Job is suspended, the quota released [GF:58-60]; the reconciler reactivates the Workload, Kueue re-admits it, the new Pod lands on H [GF:62-63]. All of it is opt-in behind two operator flags [GF:46] |
| measured times, 5 of 5 valid [V:3] | detect 1.627 s (1.051–1.758) [V:4]; taint 0.008 s (0.008–0.010) [V:15]; evict request 0.093 s (0.090–0.093) [V:6]; Kueue eviction decision 0.774 s (0.774–0.775) [V:9]; quota release 0.774 s (0.774–0.775) [V:11]; container stop 0.774 s (0.774–0.775) [V:14]; re-admission 1.000 s (1.000–1.000) [V:12]; **end to end 2.502 s (1.926–2.634)** [V:5]; new container running 3.926 s (3.502–4.634) [V:13]; lost work 15 s (14–15) [V:10]. The registered idealised detect bound was 2.8 s [GF:126-127]; the largest detect upper end across both fault arms was 1.789 s [GF:362] |
| recovered | the job was re-admitted and placed on H inside the 120 s window in every repetition [GF:363], **on a simulated device** [GF:192] [GF:386] |
| did not recover | the work: the job keeps no checkpoint, so lost work is the whole displaced attempt [GF:120] [GF:236] |
| known gaps | nothing about what a real Xid does through NVML, which may take the card off the bus or need a reset [GF:233]; nothing about the device plugin's health path or driver resets [GF:234]; one node, one card, one job at a time [GF:235]; a host engine that stops updating while the exporter keeps serving its last snapshot reads as fresh [GF:237]; kind, not EKS [GF:238] |
| evidence | `hack/gpu-fault/2026-10-27-run2/verdict.txt`, with `SHA256SUMS` in the same directory [GF:391]; the registration and result are in `docs/superpowers/specs/2026-10-27-gpu-fault-reaction-design.md` |

## Row 2 — double-bit ECC reported by DCGM

| field | value |
|---|---|
| how injected | field 311 (`DCGM_FI_DEV_ECC_DBE_VOL_TOTAL`) := 1 [GF:97], into DCGM's cache, **not a hardware fault**; a double-bit count above zero is a fault [GF:75] |
| where, detection, reaction | as row 1, in the same session, arms interleaved in rotated blocks [GF:101] |
| measured times, 5 of 5 valid [V:16] | detect 1.448 s (1.314–1.789) [V:17]; taint 0.008 s (0.007–0.010) [V:28]; evict request 0.092 s (0.014–0.093) [V:19]; Kueue eviction decision 0.775 s (0.774–0.855) [V:22]; quota release 0.775 s (0.774–0.855) [V:24]; container stop 0.775 s (0.774–0.855) [V:27]; re-admission 1.000 s (1.000–1.000) [V:25]; **end to end 2.324 s (2.189–2.664)** [V:18]; new container running 3.664 s (2.412–4.324) [V:26]; lost work 14 s (14–15) [V:23] |
| recovered, did not, gaps | as row 1 |
| evidence | as row 1 |

## Row 3 — controls: a corrected error, and no change at all

| field | value |
|---|---|
| how injected | `benign`: field 310, single-bit ECC, := 1 [GF:98], which the policy never treats as a fault [GF:76]; `none`: nothing in the window, then a sentinel value so the operator is shown to have been reading [GF:99] |
| where | as row 1 |
| detection signal | the operator records every value it reads, so a quiet window is shown to have been read and ignored rather than never read [GF:66] [GF:145] |
| platform reaction | none, which is the prediction [GF:132] |
| measured | `benign` QUIET, valid 5 of 5 [V:29]; `none` QUIET, valid 5 of 5 [V:31]; each "5 fully observed window(s); this is a count, not a rate" [V:30] [V:32] |
| known gaps | five windows per arm is not a false-positive rate [GF:240] |
| evidence | as row 1 |

## Row 4 — the exporter disappears while the card is healthy

| field | value |
|---|---|
| how injected | the exporter's DaemonSet is given a node selector nothing matches, then the selector is removed [GF:375], for 15 s [GF:134] |
| where | as row 1 |
| detection signal | no fresh reading: `GPUSignal=False` with a no-reading reason [GF:71] |
| platform reaction | `GPUSignal=False` (`NoExporter`), `GPUHealthy=Unknown`, no taint [GF:366]; missing data neither sets nor clears a fault [GF:70] |
| measured | check stale-healthy PASS [V:33]; one check, no timing endpoint registered for it |
| recovered | the exporter came back; with no taint on the node it had nothing to block it [GF:379] |
| evidence | as row 1 |

## Row 5 — the exporter disappears while a fault is latched

| field | value |
|---|---|
| how injected | Xid 79 latched first, then the exporter removed as in row 4 [GF:370] |
| where | as row 1 |
| platform reaction | the fault, the taint and the fingerprint all stayed while the exporter was gone, with `GPUSignal=False` (`NoExporter`) [GF:370]; stale data did not release the latch |
| measured | check stale-latched **FAIL** [V:34]. The runner logged "the exporter did not come back" and never injected the clearing zero [GF:371]. The scorer's printed reason [V:35] is wrong about the cause; the verdict stands [GF:372] |
| did not recover | the exporter. It tolerated `nvidia.com/gpu:NoSchedule` only, and the node carried the platform's own `gpu-fault:NoSchedule` taint, so its DaemonSet placed no new Pod there [GF:376-377]. A latched fault clears automatically only on a fresh all-zero reading from that exporter, so afterwards only an operator's acknowledgement clears the node [GF:68] [GF:382-383]. **A defect in the product, not the apparatus** [GF:382] |
| fix, and what is not verified | the exporter now tolerates the fault taint [DS:54-56], and `TestTheExporterToleratesTheFaultTaintItIsNeededToClear` fails without it [EXT:21-22]. The cause was reproduced on a throwaway kind node, where adding the toleration brought the Pod back [GF:378]. **The fix has not been re-run on a card**; the instance's evidence does not record the Pod's scheduling events [GF:380] |
| known gaps | the NVIDIA device plugin's DaemonSet still tolerates only `nvidia.com/gpu` [DP:41-44], so it would not return to a quarantined node either; noted, not measured [GF:384] |
| evidence | `hack/gpu-fault/2026-10-27-run2/`, the check's record named at [GF:369] |

## Row 6 — preemption that did not preempt (Finding 5)

| field | value |
|---|---|
| how found | not injected: a review of a published reclaim result noticed the victim's stop reason was `Succeeded` [TC:35-37] |
| where | the queuelab lab cluster under Kueue's in-cohort reclaim [TC:46]; Finding 5 does not name the machine |
| detection signal | none in the control plane: "preempted" and "finished on its own" look alike unless something reads the termination reason [W:269-271] |
| platform reaction | Kueue marked the victim `Preempted` at 34.076 s [TC:46]. Its container ran `sleep` as PID 1, which ignores SIGTERM [W:264-265], so it ran to natural completion at 42.638 s with exit 0, SIGTERM having arrived with about 9 s of service left [W:266] |
| measured | the owner's Workload was admitted 112 ms after its create, but its Pod was Ready 9.394 s later, because the victim still held the device [TC:49-50]; the victim was re-admitted and re-ran its full service, so a 40-second job occupied 83 seconds [TC:52]. One reproduced run |
| did not recover | the published figure: the claim of admission in about 120 ms at a cost of about 39 GPU-seconds was retracted the same day [W:261-262] |
| known gaps | quota reclamation is only as correct as the workload's signal handling, which the quota system cannot observe [W:269-270] |
| evidence | `docs/superpowers/specs/2026-08-02-queuelab-termination-contract-design.md`, `docs/10_WHAT_I_GOT_WRONG.md` [W:274-275] |

## Row 7 — a job no node can take is reported Running (Finding 6)

| field | value |
|---|---|
| how produced | not a fault but a capacity shape: a 2-GPU job with 2 GPUs free in total and no single node able to take it, 25 pre-registered trials on two worker nodes [W:281-282] |
| where | kind: the long-lived `kind-platform` cluster for the 2026-09-24 run [W:318] [FR:136-137], a throwaway one for the 2026-10-23 rerun [FR:115] [FR:118]; nothing about real GPUs [W:320] |
| detection signal | none: the phase read `job.Status.Active > 0`, and Kubernetes counts pending Pods as active [W:294-296] |
| platform reaction | the CR said `Running` while unscheduled in 145 of 145 samples, spanning 179.1 s, in the fragmented arm, and the same in the aggregate-short arm [W:287] [W:289]; the platform's own admit-to-running latency was measured from that false transition [W:297-298] |
| recovered | fixed 2026-09-25: the phase reads `job.Status.Ready` [W:301]. A registered rerun on 2026-10-23 showed the CR `Running` while unscheduled in 0 samples, against 145 per trial before [W:315-318] |
| also measured | repacking one holder moved the same Pod to scheduled 0.51–1.43 s after the deletion, in five trials [W:316] |
| known gaps | no automatic repacking exists in this platform; the thing moved was a `pause` container, not live training [W:320-321] |
| evidence | `experiments/fragmentation/`, `docs/superpowers/specs/2026-09-24-node-level-gpu-fragmentation.md` [W:323] |

## Row 8 — free GPUs stranded by placement (Finding 8)

| field | value |
|---|---|
| how produced | a fixed submission sequence on workers advertising 2, 1 and 1 devices, with and without a GPU-aware `KubeSchedulerConfiguration` [W:359-361] |
| where | local kind clusters [ST:5], simulated devices [W:410] |
| detection signal | the registered figure `stranded_devices`: free devices no pending workload can use [W:368-369] |
| platform reaction | none automatic; the remedy is scheduler configuration [W:374-375] |
| measured | without a configuration, the 2-device request was refused in 2 of 3 runs, two devices stranded each time; with packing, bound in 3 of 3 [W:365-366]. A second campaign of 72 cells [W:398]: C1 10 of 12 against 0 of 12, one-sided p 0.00003 [W:402]; C2, where packing should lose, 6 of 12 against 12 of 12, p 0.0069 [W:403]; C3 12 of 12 against 0 of 12 [W:404] |
| known gaps | the sign reverses with the demand mix [W:406]; fixed sequences are not an arrival process [W:410] |
| evidence | `hack/stranded-v2-20261023T031645Z/` and the pages named at [W:412] |

## Row 9 — a distributed job with only one rank placed (Finding 10)

| field | value |
|---|---|
| how injected | a squatter Pod holds one of two workers' devices, so one rank of a two-rank job runs and the other stays `Unschedulable` [W:448] |
| where | kind, one simulated GPU per rank; eight registered 600 s runs [W:448-449] |
| detection signal | before the fix, none: the phase rule counted one Ready rank as `Running` [W:447] |
| platform reaction, before the fixes | with Kueue's `waitForPodsReady` off, the CR said `Running` for 598.1 of 598.1 s and the 2-GPU quota was held 599 s, to the window's end [W:453]; with a 120 s timeout and 2 retries, three admissions at 0, 150 and 330 s, each about 121 s [W:455]. The quota came back about 1.1 s after each eviction, but the evicted rank kept its device for 28.9 s more and ended with exit 137, in all ten evictions [W:461] |
| recovered | two fixes, each re-measured. The phase now needs every rank Ready [W:469]; the trainer now runs its SIGTERM handler during rendezvous [W:471]. On 2026-10-23, ten valid runs [W:473]: never `Running` with a rank unplaced [W:475]; in all sixteen evictions the rank ended with exit 143 and `finishedAt` 1.1 s before the recorded release [W:476]; a second tenant was admitted 1.0 s after the first release [W:477] |
| did not change | the hold itself: 599 s without the timeout, admissions at 0, 150 and 330 s with it [W:475] |
| known gaps | nothing about GPUs, NCCL, more than two ranks, gang placement [W:467]; a workload that blocks SIGTERM as the old trainer did still holds its device to the grace period [W:471] [W:481] |
| evidence | `hack/distributed-partial-placement-20261023T011849Z/` and the pages named at [W:483] |

## Row 10 — one rank fails, or ranks cannot find each other

| field | value |
|---|---|
| how injected | `one-rank-fails`: `DDP_FAIL_RANK=1` after 10 s while rank 0 holds; `bad-address`: `MASTER_ADDR=nowhere.invalid` [DDP:35-36]; rendezvous timeout 60 s [DDP:29] |
| where | run 2: kind, CPU, gloo, one simulated device per worker [DDP:20-23] [DDP:174-176]. Run 3: EKS, two g5.xlarge with one A10G each, NCCL 2.21.5 [DDP:129] [DDP:146], **in different availability zones**, ap-northeast-2c and ap-northeast-2a [DDP:171] |
| detection signal | the Job controller: `backoffLimit: 0` fails the Job at the first failed rank [DDP:59] [DIST:85-86] |
| platform reaction | the Job gets `FailureTarget` (`BackoffLimitExceeded`), the holding peer receives SIGTERM, the Job and the MLTrainingJob end Failed [DDP:61-67] |
| measured, run 3 | rank 1 failed at 01:05:37.869, `FailureTarget` at 01:05:40, rank 0's SIGTERM at 01:05:40.999, Failed at 01:05:42 [DDP:157]; `bad-address` failed in rendezvous and the Job Failed at 113 s [DDP:156]. One run per arm |
| measured, run 2 | `one-rank-fails` Failed after 16 s; `bad-address` Failed after 122 s [DDP:183-184]. One run per arm |
| did not recover | the job, by design: "Any rank failing fails the whole job; there is no per-rank retry and no restart" [API:87] |
| known gaps | no throughput figure [DDP:168]; nothing about NCCL between two nodes in one zone [DDP:172]; cross-node placement was forced by construction [DDP:91] |
| evidence | `hack/multi-pod-ddp-eks-20261022T004202Z/` (run 3), `hack/multi-pod-ddp-20261014T231122Z/` (run 2) |

## Row 11 — a training process is killed and resumed from a checkpoint

| field | value |
|---|---|
| how injected | rank 1 SIGKILLs itself at the start of step 25, once [CR:31]: a process dying, **not Kueue preemption** [CR:111] |
| where | a three-node kind cluster; one `MLTrainingJob` with two gloo ranks under `torchrun` in **one Pod**, on CPU, with a PersistentVolumeClaim through `stateVolume` [CR:19] [CR:24-25]; three repetitions per arm [CR:44] |
| detection signal | the Pod fails; the Job's default `backoffLimit` replaces it, with no restart logic of the experiment's own [CR:25-26] |
| measured | `resume` (weights, optimizer, step, data generator): `steps_run` 40 and diff 0 against the uninterrupted run, in all three [CR:83]; `restart` with no checkpoint: `steps_run` 64, the same final model 24 steps later [CR:82] [CR:89]; the incomplete resumes were caught at 0.358 and 0.245 [CR:84-85]; kill to the replacement's first record 11 to 12 s in all twelve killed runs [CR:94] |
| recovered | training state, exactly, from a node-local volume |
| known gaps | no GPUs or NCCL, and a checkpoint of bytes [CR:106]; losing the node is not tested, because the kind provisioner's volume binds to one node and the replacement lands where the first Pod ran [CR:107-108]; a kill in the middle of a write is not attacked [CR:109-110] |
| evidence | `hack/checkpoint-resume-20261009T020455Z/` [CR:75] |

## Row 12 — a distributed job that needs its state back: no path exists

| field | value |
|---|---|
| status | not run, and not runnable on this platform as it stands |
| why | the API refuses `stateVolume` with `distributed`, "one claim cannot follow ranks onto different nodes" [API:36]; a distributed job's Job has `backoffLimit` 0, because a replaced rank cannot rejoin a group mid-step [DIST:85-86] |
| consequence | rows 10 and 11 do not combine: a multi-Pod job that loses a rank ends Failed and has no platform-provided state to resume from. Row 11's resume is single-Pod only |
| also not measured | what rows 1 and 2's eviction path does to a multi-Pod job: every fault repetition used a one-GPU, one-Pod job [GF:108] |

## Row 13 — the llm-d router's endpoint picker dies: an uncounted rehearsal of a draft registration, not a result

These observations were recorded on 2026-10-31 before the registration they inform was frozen, so none is a counted run [LLMD:3].
They live on the unmerged branch `feat/llmd-failover-repro` at commit f93d4be3, not on `dev`.
Setup: kind cluster `llmd-ha`, llm-d-router-standalone v1.0.0, priority routing with fail-open on, Envoy reached through `kubectl port-forward` [LLMD:10].

| field | value |
|---|---|
| how injected | endpoint-picker (EPP) Pods force-deleted [LLMD:16] [LLMD:36] |
| what was seen, both EPPs gone | 66 requests: 28 arrived at the backend with an empty body, 38 intact [LLMD:20]; the dead EPP hosts left Envoy's host list about 36.6 s after the kill [LLMD:23] |
| with `ignore_health_on_host_removal: true` | 72 requests: the first arrived empty and took 3.9 s, the other 71 intact; one run [LLMD:28-29] |
| primary EPP killed under load | 891 requests outstanding at the fault all ended 3.0 to 3.1 s after it, with 400 [LLMD:36-37]; 38 requests sent after the fault were body-lost [LLMD:38] |
| standing | exploratory; it changed what the draft registration asks, and nothing here is a measured result |
| evidence | on that branch: experiments/llmd-failover/evidence/2026-10-31-failopen-body/README.md |

## What no row covers

- A real GPU hardware fault, a GPU reset, or a node reboot: every GPU fault above was injected into DCGM's cache [GF:233].
- Losing a GPU node with a job on it.
- An NCCL hang or timeout inside a running collective.
- Many nodes faulting at once [GF:235].
- Slurm: this project has not run it.

## Sources

| KEY | file |
|---|---|
| V | `hack/gpu-fault/2026-10-27-run2/verdict.txt` |
| P | `hack/gpu-fault/2026-10-27-run2/session-provenance.txt` |
| GF | `docs/superpowers/specs/2026-10-27-gpu-fault-reaction-design.md` |
| W | `docs/11_WHAT_THIS_MEASURED.md` |
| TC | `docs/superpowers/specs/2026-08-02-queuelab-termination-contract-design.md` |
| DDP | `experiments/multi-pod-ddp/README.md` |
| CR | `experiments/checkpoint-resume/README.md` |
| API | `api/v1/mltrainingjob_types.go` |
| DIST | `internal/controller/mltrainingjob_distributed.go` |
| DS | `config/dcgm-exporter/daemonset.yaml` |
| DP | `config/nvidia-device-plugin/daemonset.yaml` |
| EXT | `internal/controller/nodehealth_gpufault_exporter_test.go` |
| FR | `experiments/fragmentation/README.md` |
| ST | `docs/superpowers/specs/2026-10-22-stranding-where-packing-should-lose-design.md` |
| LLMD | branch feat/llmd-failover-repro at f93d4be3, experiments/llmd-failover/evidence/2026-10-31-failopen-body/README.md |
