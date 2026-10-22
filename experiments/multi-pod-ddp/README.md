# Multi-Pod DDP through `spec.distributed`: registration

Registered 2026-10-15, before any run.
The design is `docs/superpowers/specs/2026-10-14-multi-pod-training-design.md`; this page fixes what a run must show and how it is read.
`hack/multi-pod-ddp.sh` runs it and `experiments/multi-pod-ddp/analyze.py` scores it; neither may be changed between a run and its reading.

## The question

Can an `MLTrainingJob` with `distributed: {worldSize: 2}` run two ranks as two Pods on two nodes, admitted as one Kueue workload, which find each other through the platform and complete one synchronised step?
And does one rank's failure end the whole attempt, by the Job controller?

## What a pass would license, and what it would not

It licenses the sentence above, on CPU, with gloo, on kind.
It does not license anything about GPUs, NCCL, throughput, restart, checkpoints, or placement being all-or-nothing.
Cross-node placement is forced by construction (one simulated device per worker) and is not a scheduling result.

## Cluster

- A throwaway kind cluster `ddp` from `hack/kind-config.yaml`: one control plane and two workers.
- cert-manager v1.21.1 and the operator from `config/operator-webhook`, so the admission webhooks are on the path.
- Kueue v0.18.3, as every kind script in this repository installs it; `go.mod` carries v0.20.1, and the difference is recorded, not resolved.
- The gpu-simulator advertising **one** `nvidia.com/gpu` on each worker.
- A `GPUQuotaPolicy` with `trainingQuota: true` and `limits.gpuCount: 2` for namespace `ddp`, so the operator creates ClusterQueue and LocalQueue `gpu-ddp` and labels the namespace for the GPU webhooks.
- Recorded: commit and dirty-file count, kind version, node image, kubelet version, Kueue version, cert-manager version, torch version, `train.py`'s sha256.

## Arms

Each arm is a fresh `MLTrainingJob` with `worldSize: 2`, `gpuCount: 1`, image `cpu-ddp:torch251` rebuilt from `experiments/cpu-ddp/`, command `sh -c '… exec python /work/train.py'`, and `DDP_RENDEZVOUS_TIMEOUT_SECONDS=60`.

| arm | extra setting | expected terminal phase |
|---|---|---|
| `pass` | none | Succeeded |
| `no-sync` | `DDP_NO_SYNC=1` | Succeeded |
| `bad-address` | `MASTER_ADDR=nowhere.invalid` exported over the platform's | Failed |
| `one-rank-fails` | `DDP_FAIL_RANK=1`, `DDP_FAIL_DELAY_SECONDS=10`, `DDP_HOLD_SECONDS=900` | Failed |

## Collection

From the moment each job is created until it is terminal, once a second: every Pod of the job (UID, completion index, node, phase, container state, deletion timestamp), the Job's conditions, and the MLTrainingJob's phase and `readyRanks`.
Every Pod's log is streamed from the moment its container starts, so a Pod the Job controller deletes keeps its records.
After the terminal phase: every Kueue Workload in the namespace, the Job, the MLTrainingJob and the Service.

## Criteria

A criterion that cannot be evaluated because its evidence is missing **fails**; absence is never read as a pass.
Times recorded by the API server have one-second resolution, so an ordering between one of them and a time written by `train.py` is judged after truncating the latter to the second, and "before" means "not after".

**`pass`** passes only if all of these hold:

1. exactly two Pods were ever created, with different UIDs, completion indexes 0 and 1, and different `spec.nodeName`s;
2. both ranks' `verdict` records report `observed_w_after_one_step` within 1e-6 of 0.4, `all_ranks_agree` true and `exit_code` 0;
3. exactly one Kueue Workload is owned by the child Job's UID; it has one pod set of count 2, and its `status.admission` reserves `nvidia.com/gpu` 2;
4. the MLTrainingJob reached Succeeded within 300 s of creation, and at least one sample saw `readyRanks` ≥ 1.

**`no-sync`** passes only if criteria 1 and 4 hold and the ranks' `w_after_step` at step 1 are 0.2 and 0.6, with `all_ranks_agree` false.

**`bad-address`** passes only if, within 300 s of creation, the Job carries `Failed` and the MLTrainingJob is Failed, and at least one rank's log carries `rendezvous_failed`.
The other rank may instead have been ended by the Job controller; that is allowed, because `backoffLimit: 0` fails the Job at the first failure.

**`one-rank-fails`** passes only on this sequence, within 300 s of creation:

1. rank 0's `holding` record, then
2. rank 1's `fail_injected` record, then
3. the Job's `FailureTarget` condition, reason `BackoffLimitExceeded`, then
4. rank 0's `sigterm` record, then
5. the Job's `Failed` condition, and the MLTrainingJob in phase Failed.

Rank 0 holds for 900 s, three times the arm's budget, so nothing but termination ends it inside the window.
Exit code 143 alone does not say who sent the signal, so it is recorded and not used.

## Voids

A run that fails during cluster setup, or whose collector stops before every arm is terminal, is void: it is reported as void and never as a failed criterion.
`analyze.py` prints VOID, PASS or FAIL per arm and exits non-zero unless every arm is PASS.

## The `nccl` profile (added 2026-10-21, for a GPU run not yet registered)

Everything above is the `gloo` profile, which is the default and whose output on run 2 is pinned byte for byte by `test_analyze.py`.
`analyze.py --profile nccl --script-sha256 <hex> <dir>` additionally requires, in `pass` and `no-sync`, that each rank's own records show backend `nccl`, device and tensor device type `cuda`, a GPU UUID distinct from the other rank's, a node labelled `eks.amazonaws.com/nodegroup: gpu` in the arm's saved `nodes.json`, and a `train.py` hash equal to the approved one.
The profile and the hash come from the registration, given by whoever scores; a run whose `provenance.txt` records a different profile is void either way round.
No GPU run has been scored with it; each criterion is shown able to fail by a fixture that falsifies only its own field.

## Run 3 registration: EKS, NCCL, two g5.xlarge (registered 2026-10-22, before the run)

Approved by the owner on 2026-10-22 as one paid session.

**The question** is the one above, asked on GPUs: do the two ranks run as two Pods on two GPU nodes of the `gpu` group, admitted as one Kueue workload, find each other through the platform, and complete one synchronised step with NCCL on CUDA? And does one rank's failure end the attempt, by the Job controller?
A pass licenses that sentence for two A10Gs, one per g5.xlarge, on EKS, deployed by the product's GitOps path.
It licenses nothing about throughput, more than one GPU per Pod, a launcher such as `torchrun`, gang scheduling, or any interconnect beyond the VPC network.
Cross-node placement is forced by construction: one GPU per node and one GPU per rank.

**The session:**
- `TRAIN=ddp` in `hack/eks-gitops-session.sh`, on a cluster it creates;
- `TTL_MINUTES=180`, `TRAIN_MAX_PRICE=1.40`;
- `APPROVED_TRAIN_SHA256=733f264307f7f661482852e322377a76ee50448ea52a2bbc5fc65dbf10891a5d`;
- `TRAIN_ARMS="pass no-sync bad-address one-rank-fails"`, in that order.

**The software:**
- The image is `docker.io/pytorch/pytorch@sha256:c8268a92a69bd500f8be0e665b2630ee006dadaf7bfbc24249141b15ff622755`.
- `train.py` travels in the command as base64, with `DDP_BACKEND=nccl`.
- `gpuClass` is `a10g`.
- Everything else in each arm is the kind harness's: its arm environments, `DDP_RENDEZVOUS_TIMEOUT_SECONDS=60`, and the 300 s budget.
- Kueue is v0.18.3, from the `gpu-platform-kueue` Application on `main`.
- Devices come from the real NVIDIA device plugin, with no simulator.

**The smoke cell is `pass`, run first.**
This code has never executed NCCL or CUDA, so its first execution is not taken as a measurement unless it works.
If `pass` is not PASS under the `nccl` profile, the run is reported as a failed smoke cell.
The other three arms still run and are recorded, but they are not reported as results of this registration.

**Criteria:**
- Every criterion above, unchanged.
- The `nccl` profile in `pass` and `no-sync`, with the hash above.
- The analyzer at the commit the session runs from, scored by the session's T8 and by hand from the evidence afterwards. Both readings must agree.

**Voids:**
- Any gate from T1 to T7 that refuses voids the run, and no arm is scored.
- T1 to T5 refuse before any GPU is bought. A run voided there may be repeated under this registration, since it bought no GPU.
- A run voided after the purchase is not repeated without the owner's approval.
- Neither `analyze.py` nor the session may change between the run and its reading.

**Budget:**
- Expected: about $3. That is the cluster at about $0.26 an hour for about 1.5 hours, two g5.xlarge at $1.237 an hour each for about 40 minutes, and the 3.3 GB image pulled through the NAT once per node at $0.059 a GB.
- Bounded at about $8 if every wait runs to its deadline: the AWS deadline scales the nodes down at most 170 minutes after the start, and the watchdog destroys the cluster at 180.

## Results

### Run 3, `hack/multi-pod-ddp-eks-20261022T004202Z/`: the smoke cell and all four arms PASS under the `nccl` profile

The session ran at the registration's commit `07694a2`, with `dirty_files=0`, on 2026-10-22 in `gpu-lab`, under the settings registered above.
The evidence is the session's directory, without `terraform.log`, the watchdog's pid file and the gateway key the runbook seeds.

**Gates.**
The GitOps baseline passed: all 13 Applications existed, and every automated one was Synced and Healthy, `gpu-platform-kueue` and `cert-manager` included.
T1 to T5 passed before anything was bought:
- T3: the qualification job was admitted at 00:58:44Z with both Pods unplaced;
- T4: the price read $1.237 an hour;
- T5: 0 of 52 vCPU was in use.

The two g5.xlarge launched at 00:59:03Z and were qualified by name (T6).
The qualification job was released by the scale-up and succeeded, with `admitToRunningSeconds` 176.924, image pull included (T7).

**The smoke cell `pass` passed, so the run is a measurement.**
Both ranks recorded:
- backend `nccl`, NCCL 2.21.5, CUDA 12.4;
- device and tensor device type `cuda`;
- GPU UUIDs `5c1d5a84-…` and `d3e6fa0b-…`;
- nodes in the `gpu` group;
- the approved `train.py` hash.

Both reported w = 0.4000000059604645 and agreed, and the job succeeded 9 s after creation.

**The other three arms:**
- `no-sync`: diverged to 0.2 and 0.6 on the same two GPUs and passed the same GPU criteria.
- `bad-address`: failed in rendezvous with `DistNetworkError`, and the Job Failed at 113 s.
- `one-rank-fails`: followed the registered sequence; rank 1 failed at 01:05:37.869, `FailureTarget` came at 01:05:40, rank 0's SIGTERM at 01:05:40.999, and Failed at 01:05:42.

The session's T8 and a reading by hand afterwards, from the same commit, printed identical output.

**Teardown.**
The nodes were followed to terminated; their shutdown began at 01:08:10Z, 9 min 7 s after launch.
Nothing that charges remained after the destroy, and the kill switch was disarmed only then.
At list prices the run cost about $1: about $0.38 of GPU time, $0.19 of cluster time and $0.39 of image pulls through the NAT.

**What it does not show.**
Correction 5's 8082 rule is shown only indirectly: the `gpu` flavor, which correction 5 says could not be applied without Kueue's visibility API, was applied, and the ranks were placed through it. The APIServices' own condition was not recorded.
Nothing here is a throughput figure.

### Run 2, `hack/multi-pod-ddp-20261014T231122Z/`: all four arms PASS

At commit `c74d42c`, on kindest/node v1.37.0, Kueue v0.18.3, cert-manager v1.21.1, torch 2.5.1+cpu; the provenance file has the digests.
Its `dirty_files=1` is the run's own evidence directory, which the harness creates before it counts.

| arm | result | what the scorer read |
|---|---|---|
| `pass` | PASS | two Pods, indexes 0 and 1, on `ddp-worker` and `ddp-worker2`; both ranks `w = 0.4000000059604645`, agreeing, exit 0; one Workload, one pod set of 2, admitted `nvidia.com/gpu` 2; Succeeded after 5 s; `readyRanks` reached 2 |
| `no-sync` | PASS | the same two-node placement; step-1 `w` 0.2 on rank 0 and 0.6 on rank 1, not agreeing; Succeeded after 4 s; `readyRanks` reached 2 |
| `bad-address` | PASS | Job Failed and the MLTrainingJob Failed after 122 s; rank 1 recorded `rendezvous_failed` (DistNetworkError) |
| `one-rank-fails` | PASS | hold 23:15:51.627, rank 1's failure 23:16:01.623, `FailureTarget` (BackoffLimitExceeded) 23:16:04, rank 0's SIGTERM 23:16:04.455, Failed 23:16:05; Failed after 16 s |

The scorer was shown able to fail on copies of this evidence before its PASS was used: a wrong `w`, both Pods on one node, one GPU admitted, `readyRanks` removed, an unparsable sample line, ranks agreeing under no-sync, the rendezvous record removed, the SIGTERM record removed or moved before `FailureTarget`, and the hold record removed each turned the arm red.

After the run, a codex `gpt-6-astra` review of the branch found that the scorer took its arms from the directories present, so a run stopped between arms could exit 0 on the arms it reached.
It now takes them from `provenance.txt` and reports a requested arm with no directory as VOID; run 2 rescored to the same four PASS, and a copy holding only `pass/` now exits 1.

A second astra review, of what to buy next, found two more ways the scorer accepted evidence that did not show what it claimed, and both reproduced: logs cut down to their verdict lines passed, and both ranks' logs merged under one invented Pod UID passed.
Records had been pooled by the rank they claimed, with nothing tying a rank to the Pod that ran it.
The scorer now requires every sampled Pod to have its own log, holding one rank equal to its completion index, under this run's id and the Pod's own hostname, with the records each arm needs; and in `pass`, the step-1 all-reduce's future completed on both ranks.
Run 2 rescored to the same four PASS, and each of those two cases, logs swapped between Pods, a wrong run id, a missing log, missing step records and an all-reduce that never completed now fails by name.

Two things the run showed that the registration did not ask about:

- On success too, the phase went Running → Admitted → Succeeded, because the Job's ready count falls to 0 a moment before it reports Complete. The design states that window for failure; it is not specific to failure.
- The bad address was refused by a different rank in run 1 (rank 0) than in run 2 (rank 1), which is the reason the criterion asks for at least one rank rather than a particular one.

### Run 1, at `ce7d1aa`: not used

`bad-address` and `one-rank-fails` passed, and `pass` and `no-sync` failed because the harness wrote each sample as broken JSON: a newline from `grep` split every record, and an empty status emptied one.
The first scorer skipped unparsable lines, so it reported `readyRanks` as never sampled, a statement about the platform that the evidence did not support.
Both were fixed in `c74d42c` (each sample is assembled by Python from whole objects, and the scorer now refuses a file with any unparsable line), and every arm was rerun fresh as run 2.
Its evidence was not committed.
