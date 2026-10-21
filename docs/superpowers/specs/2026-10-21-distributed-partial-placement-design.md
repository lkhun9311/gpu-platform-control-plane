# Design: a distributed job with one rank placed — what the platform reports, how long it holds quota, and whether Kueue's readiness timeout bounds it

Written 2026-10-21. Status: **v1, registered before any run; not built.**
Chosen the same day over building the NCCL groundwork first, after independent brainstorms by codex `gpt-6-astra` and me and an adversarial review of the merged list: this one asks a control-plane question at no rented cost, and the NCCL work stays second (its design, v4 with three binding corrections, is on the unmerged branch feat/nccl-groundwork).

## The question

Finding 6 (`docs/11_WHAT_THIS_MEASURED.md`) measured a single-Pod 2-GPU job that was admitted with its quota reserved and could not be placed: the platform said `Running` in 145 of 145 samples.
A distributed job can fail differently. With `distributed.worldSize: 2` the operator renders one Indexed Job of two one-GPU Pods (`internal/controller/mltrainingjob_distributed.go`), and its phase rule reports `Running` as soon as **one** Pod is Ready (`computeMLTJPhase`, `internal/controller/mltrainingjob_controller.go`: `job.Status.Ready > 0`).
Kueue v0.18.3 counts the same Job as `PodsReady` only when ready plus succeeded Pods reach the Job's full count (`(*Job).PodsReady` in Kueue's `pkg/controller/jobs/job/job_controller.go`), and can evict and requeue a workload that does not get there in time, if `waitForPodsReady` is enabled; the release ships it disabled.

So, when Kueue admits a two-rank job and only one rank can be placed:

1. what does the platform report about it, and for how long;
2. how long does it hold the queue's quota while it cannot make progress;
3. does enabling `waitForPodsReady` bound that hold, and what does the platform report about a job Kueue evicts and readmits;
4. if capacity arrives later, does the job still complete, under each setting?

## What a result would license, and what it would not

It would license statements about this operator with Kueue v0.18.3 on kind, with simulated devices, for a two-rank job stranded by one occupied device: what the CR said, how long quota was held, what the readiness timeout did.
It would not license anything about NCCL, GPUs, EKS, real scheduling or provisioning latency (Finding 2 bounds what a simulated device can say), more than two ranks, or gang placement: `waitForPodsReady` evicts after the fact; it does not place all ranks or none.
`Running` is not progress: no Pod here has a readiness probe that reflects training, so a Ready rank waiting in rendezvous is Ready. The study measures that, and claims nothing about training throughput.

## Cluster

As `experiments/multi-pod-ddp/README.md`, so the two studies share every condition but the ones named here:

- a throwaway kind cluster from `hack/kind-config.yaml`, one control plane and two workers;
- cert-manager v1.21.1 and the operator from `config/operator-webhook`;
- Kueue v0.18.3 from its release manifest;
- the gpu-simulator advertising **one** `nvidia.com/gpu` on each worker;
- a `GPUQuotaPolicy` with `trainingQuota: true` and `limits.gpuCount: 2` for the study's namespace, so the ClusterQueue's nominal quota is 2: enough to admit both ranks, whatever the nodes can hold.
- Recorded: commit and dirty-file count, kind, node image, kubelet, Kueue, cert-manager, torch, `train.py`'s sha256, and the Kueue configuration in force (below).

**The stranding.** Before each job is created, a squatter Pod in namespace `squat` (no quota label, so the platform's GPU webhooks do not see it, and no queue name, so Kueue does not manage it) requests `nvidia.com/gpu: 1` and is bound by `nodeName` to the second worker.
With one device per worker, the job's two ranks then have one device between them: Kueue admits both (quota 2), one rank is placed on the first worker, and the other stays Pending.
Which index is placed is the scheduler's choice and is recorded; nothing is scored on it.

**The workload.** The multi-Pod experiment's `cpu-ddp` image and `train.py`, unchanged, with `DDP_RENDEZVOUS_TIMEOUT_SECONDS=1500`.
A rank that cannot reach its peer retries until that timeout (the archived `bad-address` arm failed 86 s after starting with a 60 s timeout), so with 1,500 s the trainer cannot end the job inside the 600 s window: whatever ends or bounds it in the window is the platform's or Kueue's doing, not the trainer's.

## Arms and scenarios

Two Kueue settings, each with two scenarios, each run twice: eight runs, each a fresh job, observed for 600 s from creation.

| setting | Kueue `waitForPodsReady` |
|---|---|
| `off` | as the release ships it: absent, so disabled |
| `ready-timeout` | `enable: true`, `timeout: 120s`, `recoveryTimeout: 120s`, `blockAdmission: false`, `requeuingStrategy: {timestamp: Eviction, backoffBaseSeconds: 30, backoffMaxSeconds: 3600, backoffLimitCount: 2}` |

Every field is written out, because enabling the feature defaults `blockAdmission` to true and the backoff base to 60 s (Kueue `apis/config/v1beta1/defaults.go`), and `blockAdmission` would change admission for other jobs, which this study does not measure.
The setting is applied by replacing `kueue-manager-config` and restarting `kueue-controller-manager`; a run is valid only if the controller Pod started after the ConfigMap was written, and the ConfigMap's content is recorded with its sha256.

| scenario | the squatter |
|---|---|
| `never` | stays for the whole window |
| `late` | is deleted 300 s after the job is created |

The order is fixed: `off-never`, `off-late`, then the restart, then `ready-timeout-never`, `ready-timeout-late`, then the same four again in the same order.

## Collection

Once a second from creation to the end of the window, each sample one JSON line:

- the MLTrainingJob's `status` (phase, conditions, `readyRanks`, `admittedAt`, `runningObservedAt`);
- the Job's `spec.suspend` and `status` (`active`, `ready`, `succeeded`, `failed`, conditions);
- every Kueue Workload owned by the Job: its UID, `spec.active`, conditions (`QuotaReserved`, `Admitted`, `PodsReady`, `Evicted` with reason, `Requeued`, `Finished`) and `status.requeueState`;
- the ClusterQueue's `status.flavorsReservation` and `flavorsUsage` for `nvidia.com/gpu`;
- every Pod of the job: UID, completion index, node, phase, Ready, deletion timestamp;
- the squatter's phase and node.

Every rank Pod's log is streamed from container start, as in the multi-Pod harness. The squatter's deletion time is recorded when the harness deletes it.
The Workload timeline is what the multi-Pod harness lacked: it collected Workloads only at the end, and an end snapshot cannot say how long quota was held across evictions.

## What is measured

Per run, from the samples, with "stranded" meaning at least one of the job's rank Pods exists with no `spec.nodeName`:

- **M1, reported-running while stranded:** seconds with the CR's phase `Running` and the job stranded.
- **M2, quota held while stranded:** seconds with the ClusterQueue reserving 2 `nvidia.com/gpu` and the job stranded.
- **M3, evictions:** the number of distinct `Evicted=True` transitions with reason `PodsReadyTimeout`, the Workload's requeue count, and whether it ended deactivated (`spec.active: false`).
- **M4, outcome:** the CR's phase at the end of the window, and seconds from creation to `Succeeded` if it got there.
- **M5, discarded attempts:** distinct rank Pod UIDs created, beyond the two a single attempt needs.
- **M6, the CR across an eviction:** its phase and `admittedAt` / `runningObservedAt` in the samples after each eviction and readmission.

## Registered predictions, read from the code before any run

Each is a statement the runs can contradict; a contradicted prediction is a finding, not a failed run.

- **P1, `off-never`:** M1 covers at least 95% of the samples from the first Ready rank to the end of the window; M2 covers the whole window from admission; M3 is zero; the CR is not `Succeeded`.
- **P2, `off-late`:** M1 runs from the first Ready rank until the second rank is placed after the squatter's deletion, and the CR reaches `Succeeded` within the window.
- **P3, `ready-timeout-never`:** the first eviction, reason `PodsReadyTimeout`, comes between 120 and 150 s after admission; at each eviction the ClusterQueue's reservation returns to 0; after two requeues the Workload is deactivated inside the window; M2 is at most the sum of its admitted intervals, each at most 150 s.
- **P4, `ready-timeout-late`:** at least one eviction precedes the squatter's deletion, and the job reaches `Succeeded` in a later admission within the window; M5 is at least 2.
- **P5, the CR across an eviction:** after an eviction the CR leaves `Running`, and `admittedAt` keeps the first admission's value, because the operator records the first admission only (`internal/controller/admit_to_running.go`).

## Validity, per run

A run is void, and not scored, if any of these fails; a void run is reported with its reason and its scenario rerun once.

- each worker advertised exactly one `nvidia.com/gpu`, and the squatter was Running on the second worker from before the job's creation until its scheduled deletion (or the window's end for `never`);
- while the squatter held its device, no sample shows both ranks placed;
- no rank log carries `rendezvous_failed` inside the window, so the trainer did not end the job;
- the Kueue setting was in force: ConfigMap content as registered, and the controller Pod started after it was written;
- no sample is missing for more than 3 consecutive seconds.

## Building it

- `hack/distributed-partial-placement.sh`, a new harness. It repeats the multi-Pod harness's cluster setup rather than sourcing it, so `hack/multi-pod-ddp.sh` stays byte-identical to the version its recorded run used.
- `experiments/distributed-partial-placement/analyze.py`, which computes M1 to M6, judges validity and prints each prediction as held or contradicted, with every number it used.
- Its tests, `test_analyze.py`, on fixture timelines: each measure and each validity rule shown to change when the one thing it reads is changed, so a measure that ignores its input fails.
- The registration on `experiments/distributed-partial-placement/README.md`, fixed before the first run.

## Cost

No rented hardware. Eight runs of 600 s plus setup and one Kueue restart: about 100 minutes of a local kind cluster.

## What follows from each outcome

If P1 holds, the platform reports a half-placed distributed job as `Running` and holds its whole quota without bound, which is Finding 6's defect in the distributed case; the product fix it points at, reporting `Running` only when every rank is Ready, is its own change, designed after this result.
If P3 and P4 hold, Kueue's readiness timeout bounds the hold and still lets a job finish once capacity arrives, at the cost the runs measure in discarded attempts; whether the platform should ship it enabled is a decision for after, not part of this study.
If any prediction is contradicted, the record says which and by how much, and the code that the prediction was read from is re-read before anything is changed.

## Out of scope

More than two ranks, competing jobs in the same cohort, `blockAdmission: true`, Topology-Aware Scheduling, NCCL and GPUs, EKS, and any change to the operator.
