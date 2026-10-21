# Design: a distributed job with one rank placed — what the platform reports, how long it holds quota, and what Kueue's readiness timeout does about it

Written 2026-10-21. Status: **v3, registered before any run; not built.**
v1 and v2 were each reviewed adversarially by codex `gpt-6-astra` the same day: v1 had 2 blockers, 10 majors and 3 minors, v2 had 8 majors and 1 minor. Each finding was re-checked against the code or Kueue's source before the next version answered it; the tables are at the end.
Chosen over building the NCCL groundwork first, after independent brainstorms by astra and me and an adversarial review of the merged list: this one asks a control-plane question at no rented cost, and the NCCL work stays second (its design, v4 with three binding corrections, is on the unmerged branch feat/nccl-groundwork).

## The question

Finding 6 (`docs/11_WHAT_THIS_MEASURED.md`) measured a single-Pod 2-GPU job admitted with its quota reserved and unable to be placed: the platform said `Running` in 145 of 145 samples.
A distributed job can fail differently. With `distributed.worldSize: 2` the operator renders one Indexed Job of two one-GPU Pods (`internal/controller/mltrainingjob_distributed.go`), and its phase rule reports `Running` as soon as **one** Pod is Ready (`computeMLTJPhase` in `internal/controller/mltrainingjob_controller.go`: `job.Status.Ready > 0`, checked before anything about the Workload).
Kueue v0.18.3 counts the same Job as `PodsReady` only when ready plus succeeded Pods reach its full count (`(*Job).PodsReady`, Kueue `pkg/controller/jobs/job/job_controller.go`), and evicts a workload that does not get there in time if `waitForPodsReady` is configured; the release ships it unconfigured.

When Kueue admits a two-rank job and only one rank can be placed:

1. what does the platform report about it, and for how long;
2. how long does the Workload hold its quota while no rank has joined the other;
3. with `waitForPodsReady` configured, when is eviction initiated, how long after that is the quota released, how many attempts are stopped, and what does the platform report across them;
4. when the squatter is deleted 300 s after creation, does the job complete under each setting?

## What a result would license, and what it would not

It would license statements about this operator with Kueue v0.18.3 on kind, with simulated devices, for one two-rank job stranded by one occupied device, observed for 600 s: what the CR said, how long quota was held, what the readiness timeout did, and whether the job finished after the squatter was deleted at 300 s.
It would not license:

- **an unbounded hold.** A hold that lasts to the end of the window has lasted from its admission to the window's end, 600 s less the admission's offset, and is reported censored there.
- **eventual recovery in general.** The configured setting has a finite retry limit, so it can deactivate a job before capacity arrives; arrival at 300 s is one timing, and the expected admission times below are inferred from the configuration, not guaranteed by it.
- **a hard release deadline.** The timeout starts an eviction; suspension, Pod deletion and the release of the reservation follow asynchronously, and the release lag is measured, not bounded.
- **progress.** No rank has a readiness probe tied to training, so a rank waiting in rendezvous is Ready.
- anything about NCCL, GPUs, EKS, real scheduling or provisioning latency (Finding 2 bounds what a simulated device says), more than two ranks, other jobs in the cohort, or gang placement.

## Cluster

As `experiments/multi-pod-ddp/README.md`, so the two studies share every condition but the ones named here:

- a throwaway kind cluster from `hack/kind-config.yaml`, one control plane and two workers;
- cert-manager v1.21.1 and the operator from `config/operator-webhook`;
- Kueue v0.18.3 from its release manifest;
- the gpu-simulator advertising **one** `nvidia.com/gpu` on each worker;
- a `GPUQuotaPolicy` with `trainingQuota: true` and `limits.gpuCount: 2` for the study's namespace, so the ClusterQueue's nominal quota is 2.
- Recorded: commit and dirty-file count, kind, node image, kubelet, Kueue, cert-manager, torch, `train.py`'s sha256, and the Kueue configuration in force (below).

**The squatter.** Before each job, a Pod in namespace `squat` (no quota label, so the platform's GPU webhooks do not see it; no queue name, so Kueue does not manage it) requests `nvidia.com/gpu: 1`, is bound by `nodeName` to the second worker, runs `sleep infinity`, and has `terminationGracePeriodSeconds: 0`.
With one device per worker the job's two ranks then have one device between them: Kueue admits both (quota 2), one rank is placed on the first worker, and the other stays Pending.
Which index is placed is the scheduler's choice and is recorded; nothing is scored on it.

**The workload.** The multi-Pod experiment's `cpu-ddp` image and `train.py`, unchanged, with `DDP_RENDEZVOUS_TIMEOUT_SECONDS=1500`.
A rank whose peer address does not resolve retries until that timeout (the archived `bad-address` arm failed 86 s after starting with 60 s), so while stranded the trainer has no reason of its own to stop inside the window. That is a reason, not a guarantee: other failures can end it, so the validity rules below check how every rank container ended.

## Settings and scenarios

| setting | the `waitForPodsReady` stanza in Kueue's `Configuration` |
|---|---|
| `off` | absent, as the release ships it |
| `ready-timeout` | `timeout: 120s`, `recoveryTimeout: 120s`, `blockAdmission: false`, `requeuingStrategy: {timestamp: Eviction, backoffBaseSeconds: 30, backoffMaxSeconds: 3600, backoffLimitCount: 2}` |

The configuration is the release's own `config.kueue.x-k8s.io/v1beta2` document in `kueue-manager-config`, edited only by adding or removing that stanza. In `v1beta2` the stanza's presence is what enables the feature; there is no `enable` field, and `blockAdmission` defaults to false (Kueue `apis/config/v1beta2`). Every field is still written, so nothing rests on a default.

| scenario | the squatter |
|---|---|
| `never` | stays for the whole window |
| `late` | is deleted 300 s after the job is created |

**Order.** All four `off` runs, then one configuration change, then all four `ready-timeout` runs; within each, `never`, `late`, `never`, `late`. One change of setting, made once.

**Applying a setting.** The ConfigMap is replaced, the controller Deployment restarted, and the harness waits for the rollout to complete. The setting is in force only if all of these hold: the rollout completed with exactly one `kueue-controller-manager` Pod, that Pod started after the ConfigMap was written, it is Ready, and its startup log, where Kueue prints the configuration it loaded, shows `waitForPodsReady` as registered (absent for `off`). A setting not in force voids every run under it.

**Isolation.** Each run ends by deleting its MLTrainingJob and squatter. The next run starts only when, sampled, the namespace has no Job, Pod or Workload, the ClusterQueue reserves 0 `nvidia.com/gpu`, and both workers have their device free. A run that starts without that is void.

## Collection

Once a second from creation to the end of the window, each sample one JSON line with the time it was taken and whether every read succeeded; a failed read is written as failed, never as an empty object:

- the MLTrainingJob's `status` (phase, conditions, `readyRanks`, `admittedAt`, `runningObservedAt`);
- the Job's `spec.suspend` and `status` (`active`, `ready`, `succeeded`, `failed`, conditions);
- every Kueue Workload owned by the Job: UID, `spec.active`, every condition with its status, reason and `lastTransitionTime`, and `status.requeueState`;
- the ClusterQueue's `status.flavorsReservation` for `nvidia.com/gpu`;
- every Pod of the job: UID, completion index, node, phase, conditions (with `PodScheduled`'s reason and message), Ready, deletion timestamp, and container state including `startedAt`, `finishedAt`, exit code and reason;
- the squatter: phase, node, deletion timestamp, and whether it still exists.

Every rank Pod's log is streamed from container start; a stream that ends before its container has terminated is restarted, and a Pod whose container ran but whose log has no `rendezvous_start` record is missing evidence.

**Watch streams.** A condition says only what holds now, so a poll can miss a reservation released and taken again between two samples, overwriting the release's `lastTransitionTime`. So the harness also records a Kubernetes watch of the namespace's Workloads, MLTrainingJobs and Pods for the whole window, each event stamped as it arrives (`experiments/distributed-partial-placement/watch.py`). A watch delivers every write; a stream that ends early is restarted, and the restart is recorded, so a gap in it is visible.
The watch is the primary record of transitions; the polled samples are the cross-check and the source for the ClusterQueue and the squatter, which the watch does not cover.

## Timing rule

- **Transitions** come from the watch: the time an object's change arrived, beside the condition's own `lastTransitionTime` (one-second resolution) where it has one.
- **Durations that combine two objects**, such as M1 (the CR's phase and a Pod's scheduling), are computed on the merged watch timeline, the state of each object holding from one of its events to its next.
- **Polled durations** are reported only as a cross-check, as a lower and an upper bound: the intervals between consecutive successful samples where both ends show the state, and where either end does. The largest gap is not used as an uncertainty, because errors at several boundaries add up.
- **Censored durations.** A duration whose end is not observed inside the window is reported as at least its observed length, marked censored, and never as complete.
The multi-Pod harness's samples were not one second apart (its archived `bad-address` timeline: 109 samples over 121.6 s), so samples are never counted as seconds.

## What is measured

"Joined" means some rank logged a successful rendezvous; "stranded" means one of the current attempt's rank Pods exists with `PodScheduled=False`.

- **M1, reported Running while stranded:** time with the CR's phase `Running` while stranded.
- **M2, quota held before joining:** for each admission, from the Workload's `QuotaReserved` turning True to whichever comes first, its turning False or the ranks joining; censored at the window's end if neither is seen. Read from the Workload's own transitions in the watch, not the ClusterQueue's aggregate; the aggregate is recorded beside it.
- **M3, eviction requests and stopped attempts, kept apart.** A request is a distinct `Evicted=True` transition with its reason: `PodsReadyTimeout`, or one starting with `Deactivated` (Kueue writes `DeactivatedDueToRequeuingLimitExceeded`, joining the reason and its cause; it matches by prefix itself). An attempt is stopped by it only when, after the request, the Job is seen suspended and the placed rank's container ends as an eviction ends one (below). Also: the largest `requeueState.count` seen, because deactivation clears it, and whether the Workload ended with `spec.active: false`.
- **M4, eviction lag:** for each request, from `Evicted` turning True to `QuotaReserved` turning False; censored if no release is seen in the window.
- **M5, outcome:** the CR's phase at the end of the window, and time from creation to `Succeeded` if reached.
- **M6, cost of discarded attempts:** the number of admissions, and for each discarded one the container-seconds its placed rank ran, from `startedAt` to `finishedAt` only. A container whose `finishedAt` is never seen is reported censored, at least its last observed running time; a deletion timestamp is never used, because it is a deadline, not an end. Pods that never started count as zero.
- **M7, the CR across an eviction:** its phase from each request onward, and the value of `admittedAt` against each admission's Kueue stamp.
- **When the second rank was placed**, in `late`: its `PodScheduled` turning True. The squatter's deletion is the intervention and is reported with it; the device's becoming usable is not observed and is not claimed, because an API object's disappearance does not wait for the kubelet.

## Registered predictions, read from the code before any run

Each can be contradicted by the runs; a contradicted prediction is reported as a finding, with the code it was read from re-read.

- **P1, `off-never`:** M1 is at least 95% of the time from the CR's first `Running` to the end of the window, and that first `Running` comes within 10 s of the placed rank's Ready; M2's single admission is censored at the window's end, so it held for the window less its admission offset; M3 has no request.
- **P2, `off-late`:** from the CR's first `Running`, within 10 s of the placed rank's Ready, until the second rank is placed after the squatter's deletion, the CR is `Running` for at least 95% of that time; the CR reaches `Succeeded` within the window; one admission.
- **P3, `ready-timeout-never`:** three admissions. The first two end in `PodsReadyTimeout` requests 120 to 135 s after their admission, each followed by a stopped attempt; the third ends in a request whose reason starts with `Deactivated` inside the window; the largest requeue count seen is 2. Inferred, not guaranteed, from the backoff of 30 s then 60 s with Kueue's small jitter: admissions near 0, 150 and 330 s. M4 is measured and reported, censored where it must be; no bound is predicted.
- **P4, `ready-timeout-late`:** at least one stopped attempt precedes the squatter's deletion, and the job reaches `Succeeded` in a later admission within the window.
- **P5, the CR across an eviction:** within 30 s of each eviction the CR is not `Running`. `admittedAt` is either absent or equal to the Kueue stamp of the first admission the operator saw as admitted and not yet running, and is never moved to a later admission (`internal/controller/admit_to_running.go` records it once).

## Validity, per run

Missing evidence fails a validity rule; absence is never read as a pass. A void run is reported with its reason, and its scenario is rerun once.

- the setting in force and the run isolated, as above;
- each worker advertised exactly one `nvidia.com/gpu`, and the squatter was Running on the second worker from before creation until its deletion (`late`) or the end of the window (`never`);
- **the treatment happened:** the first admission was observed; it created exactly two rank Pods; exactly one was placed and became Ready; the other carried `PodScheduled=False` with reason `Unschedulable` and a message naming `nvidia.com/gpu`; and the placed rank logged `rendezvous_start` and no successful rendezvous before the squatter's deletion;
- while the squatter held its device, no sample shows both ranks placed;
- **before the squatter's deletion (all of `never`), every rank container ended for an accounted reason:** it was still running at the window's end, or an eviction ended it. An eviction ended it only in this order: the `Evicted=True` request, then the Pod's deletion, then the container's end with exit 143 and a `sigterm` record, or 137 after the grace period, or no terminated state before the Pod was gone. A container that terminated before its Pod's deletion, or with any other exit, or with `rendezvous_failed`, ended by itself, and that voids the run, because then the trainer, not the platform, ended the stranding;
- **after the squatter's deletion** (`late`), a rank's failure is not a validity problem: it is an outcome, scored against P2 or P4 as a job that did not reach `Succeeded`, with how it ended;
- no more than 3 s between consecutive successful samples, every rank Pod that ran has its log, and each watch stream covers the window, with any restart's gap under 3 s.

## Building it

- `hack/distributed-partial-placement.sh`, a new harness. It repeats the multi-Pod harness's cluster setup rather than sourcing it, so `hack/multi-pod-ddp.sh` stays byte-identical to the version its recorded run used.
- `experiments/distributed-partial-placement/sample.py`, the poller, and `experiments/distributed-partial-placement/watch.py`, the watch recorder.
- `experiments/distributed-partial-placement/analyze.py`: validity, M1 to M7 and each prediction printed as held or contradicted, with every number and its bounds or censoring.
- `test_analyze.py` beside it, on fixture timelines: each measure, the timing rule and each validity rule shown to change when the one input it reads is changed, and each validity rule shown to fail on missing evidence.
- The registration page, `experiments/distributed-partial-placement/README.md`, fixed before the first run.

## Cost

No rented hardware: eight runs of 600 s, isolation waits and one Kueue restart, about 100 minutes of a local kind cluster.

## What follows from each outcome

If P1 holds, the platform reports a half-placed distributed job as `Running` and holds its whole quota for as long as it was watched; the product fix it points at, reporting `Running` only when every rank is Ready, is its own change, designed after this result.
If P3 and P4 hold, the readiness timeout stops a stranded job's hold at the cost M6 measures, and still lets it finish when capacity arrives before its retries run out; whether the platform should configure it is a decision for after.
A contradicted prediction is reported as contradicted, by how much, before anything is changed.

## Out of scope

More than two ranks, competing jobs in the cohort, `blockAdmission: true`, Topology-Aware Scheduling, NCCL and GPUs, EKS, and any change to the operator.

## The review of v1 (codex `gpt-6-astra`, 2026-10-21), and where v2 answers it

Each finding was re-checked; the two blockers against Kueue's `apis/config/v1beta2` and the harness, the deactivation threshold against `triggerDeactivation` in Kueue's `pkg/controller/core/workload_controller.go`.

| finding | severity | v2 |
|---|---|---|
| the stanza used `v1beta1`'s `enable`, which the release's `v1beta2` configuration rejects in strict decoding | blocker | settings: the release's `v1beta2` document, the stanza's presence as the switch |
| runs are not isolated: a stranded job from one run holds the quota the next needs | blocker | isolation: delete, drain, and check before each run |
| off, on, off, on needs three changes, not one | major | order: four `off`, one change, four `ready-timeout` |
| a Pod started after the ConfigMap does not show the configuration is in force | major | applying a setting: rollout, one Ready Pod, the loaded configuration in its log |
| M2 depended on an unbound Pod and read the queue's aggregate | major | M2: the Workload's own `QuotaReserved`, to release or joining |
| the timeout starts an eviction; it is not a release deadline | major | M4 measures the lag; "what it would not license" says no bound |
| the eviction count missed the deactivating stop, and the requeue count is cleared | major | M3: every `Evicted` transition with its reason, and the largest count seen |
| a long rendezvous timeout does not show the trainer did not end the job | major | validity: every container's end accounted for |
| missing logs and failed reads could satisfy validity | major | collection: failed reads written as failed, streams restarted; validity: absence fails |
| samples are not one second apart, and transitions fall between them | major | timing rule: object times first, sample intervals with their uncertainty |
| a valid run need not have the treatment at all | major | validity: one rank placed and Ready, the other `Unschedulable` on `nvidia.com/gpu`, rendezvous started |
| `admittedAt` is the first admission the operator saw, and `Running` can outlast an eviction | minor | P5 reworded, with a 30 s window |
| extra Pod objects are not the cost of discarded attempts | minor | M6: admissions and container-seconds |
| "without bound" and general recovery exceed two 600 s observations | major | what it would not license |
| the squatter's deletion is an intervention, not capacity arrival | minor | v2 measured the squatter Pod gone; v3 replaced that, below |

## The review of v2 (codex `gpt-6-astra`, 2026-10-21), and where v3 answers it

Each finding was re-checked: the joined eviction reason against `ReasonWithCause` and `IsEvictedByDeactivation` in Kueue's `pkg/workload/workload.go`, the asynchronous release against its Job reconciler.

| finding | severity | v3 |
|---|---|---|
| the deactivating eviction's reason is `DeactivatedDueToRequeuingLimitExceeded`, not `Deactivated` | major | M3 and P3: matched by prefix, as Kueue does |
| a release and readmission between two polls loses the release's time, even with no gap in the samples | major | collection: watch streams of Workloads, MLTrainingJobs and Pods |
| the largest gap is no uncertainty for a sum of intervals, and one sample is not one instant | major | timing rule: merged watch timeline; polled sums as lower and upper bounds |
| a deletion timestamp is a deadline, not a container's end | major | M6: `finishedAt` only, censored otherwise |
| a deleted Pod's disappearance is not the device becoming usable | major | the second rank's `PodScheduled` instead; device availability not claimed |
| voiding every rank failure after capacity hides failures of P2 and P4 | major | validity: after the squatter's deletion a failure is an outcome |
| an eviction request is not a stopped attempt, and overlap is not cause | major | M3 keeps requests and stopped attempts apart; validity fixes the order of request, deletion and end |
| unfinished intervals have no rule, and a hold to the window's end is not 600 s | major | timing rule: censored durations; the hold is 600 s less the admission offset |
| P2 aligned Pod readiness and the CR's `Running` with no tolerance | minor | P1 and P2: from the CR's first `Running`, within 10 s of Ready |
