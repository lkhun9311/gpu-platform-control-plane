# Design: an MLTrainingJob whose ranks run in separate Pods

Written 2026-10-14. Status: **draft for the owner's review**; nothing here is built.
Shaped by two adversarial reviews of earlier drafts, a codex `gpt-6-astra` one of the first sketch and a Claude Opus one of the first written version; every finding is answered at the end.

## The gap

`docs/11_WHAT_THIS_MEASURED.md` ("I built a training platform") says distributed training has run only as two gloo ranks inside one Pod (`experiments/cpu-ddp/`), and that `parallelism: 2` would not give multi-Pod rendezvous, "since the operator sets no `completionMode`, no `subdomain` and creates no headless Service".
This design closes that gap with the smallest contract a reviewer can hold the platform to, and no more.

## What a pass would license

That an `MLTrainingJob` can run N ranks as N Pods, admitted as one Kueue workload, which find each other through the platform and complete one synchronised step; and that one rank's failure ends the whole attempt.
Nothing about GPUs, NCCL, throughput, elastic training, restart or checkpoints.

## The contract

### 1. An explicit opt-in, not a new meaning for `parallelism`

A new optional field, `spec.distributed`, a **pointer** to `{worldSize}`. A value struct would be encoded as `distributed: {}` by every Go caller, the termination canary among them.
`worldSize` is `+required`, between 2 and 8, so `distributed: {}` is refused rather than reaching the server without the bounds being evaluated.
`parallelism` keeps its meaning (concurrent Pods of an ordinary Job), so existing jobs, tests and the canary (`cmd/queuelabrun/canary.go`, which renders `parallelism: 3, completions: 5`) are unchanged.

Rules, all as CEL on `MLTrainingJobSpec` rather than on the field, because a rule on an absent optional field is not evaluated (the trap `trainingQuota` hit, #339):

- **Immutable from creation:** `has(self.distributed) == has(oldSelf.distributed) && (!has(self.distributed) || self.distributed == oldSelf.distributed)`. The world size is baked into each Pod's environment, which a Job template cannot change. Other fields keep the webhook's rule, mutable until the Job exists (`internal/webhook/v1/mltrainingjob_webhook.go:101-114`). The two shapes differ on purpose: this one guards what Pods are built from.
- **`parallelism` and `completions` must be 1 with `distributed` set.** Both default to 1 in the CRD, so an omitted value arrives as 1 and is accepted. An explicit 0, which `defaultOne` (`internal/controller/mltrainingjob_controller.go:237`) would treat as 1, and anything above 1 are refused. The controller renders both as `worldSize`.
- **`stateVolume` is refused with `distributed` set.** One ReadWriteOnce claim cannot follow ranks onto different nodes, and two attempts at one rank would share checkpoint paths with no fencing. A distributed checkpoint is its own design.

For a job with `distributed` set, and only for one, the webhook refuses at create, before any child exists, a name the children cannot carry; an ordinary job keeps today's rules, digit-leading names included. The Service `<name>-ddp` must be a DNS-1035 label: it starts with a letter, has no dots, and `len(name) ≤ 59`. With `worldSize ≤ 8` the Pod hostname `<name>-<index>` is always shorter, so the Service rule is the one that binds.

### 2. What the controller renders

- An **Indexed Job**: `completionMode: Indexed`, `completions = parallelism = worldSize`, `backoffLimit: 0`. The create path copies only some fields today (`internal/controller/mltrainingjob_controller.go:101-118`), so it copies **both** `CompletionMode` and `BackoffLimit` explicitly; left out, `backoffLimit` defaults to 6 and a failed rank is replaced. envtest pins the persisted Job, not `BuildJob`'s return value.
- **Any rank failure fails the attempt.** With `backoffLimit: 0` the first failed Pod fails the Job, and the Job controller terminates the other ranks (SIGTERM, then SIGKILL at the grace period, 30 s since `BuildJob` sets none). On Kubernetes 1.31 and later the Job carries `FailureTarget` until every Pod has terminated and only then `Failed`. In that interval the existing phase translation (`internal/controller/mltrainingjob_controller.go:304`) can move the MLTrainingJob from Running back to Admitted, or to Pending once admission is released, before Failed; this design does not change that, and its tests assert only the terminal Failed. The interval is bounded by the grace period plus the controllers' own observation delay, not by the grace period alone. There is no per-rank retry, because a replacement rank cannot rejoin a running group and a replaced rank 0 replaces the rendezvous store. Coordinated restart is out of scope.
- **Pod labels** `platform.lkhun9311.github.io/mltrainingjob: <name>` and `platform.lkhun9311.github.io/mltrainingjob-uid: <uid>`, set on the template, which is copied whole into the Job. The Service selects on both, so it never selects Pods of an earlier incarnation with the same name.
- A **headless Service** `<name>-ddp` (`clusterIP: None`, `publishNotReadyAddresses: true`), owned by the MLTrainingJob. It is created before the Job, because Pods resolve the rank-0 address as soon as they start. Kueue ignores Services, so admission order does not matter here. The controller adds `Owns(&corev1.Service{})` and its own `services` RBAC marker (get, list, watch, create, update), so a deleted Service is recreated.
- **The Service is created, never adopted.** The controller gets `<name>-ddp` by that name (the existing `ownedConflict` reads the CR's bare name and is not reused); if it is absent it is created with `Create`, never `CreateOrUpdate`, so a Service that appears in between makes the create fail with AlreadyExists and is judged on the next pass. An existing one is used only if `metav1.IsControlledBy` matches this MLTrainingJob's **UID**, and only then is drift corrected. One being deleted is waited for.
- **A foreign Service of that name blocks creating the Job, and only that.** It is never adopted or modified. The MLTrainingJob stays in phase `Pending`, which it is in before any Job exists, with a condition `RendezvousService=False`, reason `ServiceConflict`. It is not `Failed`, and no failure metric is counted; `markFailed` is not used. The controller requeues every 30 s, because `Owns(Service)` does not enqueue it when a foreign Service goes away, and clears the condition to `True` once its own Service exists. If a Job already exists, a later Service conflict is reported in the same condition but does not stop the Job's status being translated, so phase and `readyRanks` keep following it. The `-ddp` suffix keeps clear of the InferenceDeployment controller's Services, which take a CR's bare name (`internal/controller/inferencedeployment_controller.go:118`). An InferenceDeployment named `<name>-ddp` would still collide, and that is what the conflict report is for.
- **Pod environment**: `WORLD_SIZE=worldSize`, `MASTER_ADDR=<name>-0.<name>-ddp.<namespace>.svc`, `MASTER_PORT=29500`, and `RANK` from a `fieldRef` on the annotation `batch.kubernetes.io/job-completion-index`. `$(JOB_COMPLETION_INDEX)` cannot be referenced, because the Job controller appends that variable after the template's. The Pod `subdomain` is `<name>-ddp`.
- **One process per Pod.** `WORLD_SIZE` counts Pods, so a command must start exactly one training process. `torchrun --standalone` starts its own group per Pod and would print a correct-looking result with no cross-Pod communication; the field's documentation says so.
- **No partial admission.** The child Job carries no `kueue.x-k8s.io/job-min-parallelism`, so Kueue admits one pod set of `worldSize` Pods or nothing. `gpuCount` stays per Pod, so the queue needs `worldSize × gpuCount`.
- With `distributed` unset, `BuildJob` renders exactly what it renders today.

### 3. Status, honestly named

`Running` still means the first Pod Ready (`internal/controller/mltrainingjob_controller.go:304`), and `admitToRunningSeconds` still measures that.
For a distributed job that is not "training started", so a new field `status.readyRanks` (`*int32`) carries the Job's `status.ready`. It is nil for a job without `distributed`, and 0 is written as 0, so absent and zero never look alike (`api/v1/mltrainingjob_types.go:151-152`).
`status.ready` counts Pods that are Ready and not terminating, and ranks that finish in seconds may never all be Ready at once, so `readyRanks` is a snapshot, not a claim that the group formed. Only the workload's output can say that.
It gets a printcolumn.

Adding the two fields regenerates the CRD and deepcopy code here with `make manifests` / `make generate`, diff read before commit. The Korean mirror repository is not regenerated by this change; its annotations are carried by hand when it is synced.

## Evidence

**envtest**, against the API server with the CRDs and webhooks (no Job controller, so Job status is written by the test where a check needs it):

- the persisted Job is Indexed with `backoffLimit: 0`, the environment above and the subdomain;
- the Service exists before the Job, is owned, selects by name and uid, and is recreated after deletion;
- a foreign Service of that name, present before or appearing between the get and the create, stops the Job being created, leaves the phase Pending with `RendezvousService=False/ServiceConflict`, counts no failure, is untouched, and the condition clears once it is gone; a Service owned by an earlier incarnation (same name, other UID) is treated as foreign;
- each CEL rule and the name rule refuse what they say: adding, removing and changing `distributed`, `distributed: {}`, `parallelism: 0` (sent as raw JSON, since the Go client omits a zero) and `2` with it, `stateVolume` with it, a distributed name starting with a digit, a 60-character distributed name; and a non-distributed digit-leading name is still accepted;
- `readyRanks` follows a hand-written Job `status.ready` and stays nil without `distributed`;
- `distributed` unset renders byte-identically to today (a golden of the current `BuildJob` output).

Each check is shown red by a mutation of the production code.

**kind**, registered before the run in `experiments/multi-pod-ddp/`:

- a cluster with **two workers** and the node image recorded, the gpu-simulator advertising one device on each, and a policy with `trainingQuota` whose ClusterQueue admits 2 GPUs, so the namespace is labelled and the GPU webhooks are on the path. One device per worker forces the two ranks onto different nodes; that is by construction, recorded, and not presented as a scheduling result;
- `train.py` started directly, one process per Pod, `worldSize: 2`, `gpuCount: 1`. It reads its knobs from the environment (`DDP_HOLD_SECONDS` and the no-sync switch already exist), and the CRD has no `env` field, so they are set in the command (`sh -c 'VAR=… exec python train.py'`). Two knobs are added for this experiment: a rendezvous timeout passed to `init_process_group`, set to 60 s because torch's default is 30 minutes, and a rank that exits 1 after the verdict, for `one-rank-fails`;
- **pass:**
  - both ranks report `w = 0.4` after one all-reduced step, from two Pods with different UIDs, completion indexes 0 and 1, and different `spec.nodeName`s;
  - exactly one Kueue Workload is owned by the child Job's UID, with one pod set of count 2, admitted with a reservation of 2 `nvidia.com/gpu` in its `status.admission`. Arithmetic and a Succeeded phase alone could occur with no Workload, since the phase translation reports Succeeded from the Job;
  - the MLTrainingJob reaches Succeeded, and `readyRanks` was observed;
- **controls, each fresh, with a terminal verdict:**
  - `no-sync`: all-reduce disabled. The ranks still rendezvous for the digest gather and must report 0.2 and 0.6;
  - `bad-address`: a command overriding `MASTER_ADDR` to a name that does not resolve, with the rendezvous timeout at 60 s.
    - The deadlines are separate: 60 s for rendezvous, up to the grace period for cleanup, and 300 s for the whole control.
    - It passes when at least one rank's log carries a rendezvous failure and the Job reaches Failed within 300 s.
    - The other rank may instead be ended by the Job controller, since `backoffLimit: 0` fails the Job at the first failure;
  - `one-rank-fails`: tests that the Job controller, and nothing else, ends the surviving rank.
    - `train.py` installs a SIGTERM handler that writes a timestamped `sigterm` record and exits 143. Python runs as PID 1 in the container, where a default-action SIGTERM is not delivered as a kill, so without the handler a correct termination would surface as SIGKILL after the grace period.
    - Rank 0 writes `hold-entered` and then sleeps in `DDP_HOLD_SECONDS`, outside any gloo call, for longer than the control's whole budget. Rank 1 waits until it has its own verdict plus 10 s, then exits 1.
    - It passes only on this sequence, read from the live records:
      1. rank 0's `hold-entered`, then
      2. rank 1's exit 1, then
      3. the Job's `FailureTarget` (reason `BackoffLimitExceeded`), then
      4. rank 0's `sigterm`, then
      5. Job `Failed`, and the MLTrainingJob Failed.
    - Exit 143 alone does not say who sent the signal, so it is not the criterion; the sequence is.
- the collector watches Pod status and streams every Pod's log from the moment each Pod exists, before any failure is injected. On failure the Job controller deletes the surviving Pods, so evidence gathered after a terminal phase would lose exactly the decisive rank. A rank whose records are missing fails the experiment. Every Pod attempt is read by UID and index, not `.items[0]` (`hack/cpu-ddp.sh:169`). The versions of kind, the node image, Kueue (v0.18.3 in the bootstrap against v0.20.1 in `go.mod`) and torch are recorded.

## Out of scope

- GPUs and NCCL.
- Group restart, and checkpoints for distributed jobs.
- Elastic or partial admission, and more than one process per Pod.
- Making `Running` mean all ranks.
- **Placement is not all-or-nothing.** Kueue reserves quota, not scheduling, and nothing here configures `waitForPodsReady`. If one rank cannot be placed, the other holds its GPU in rendezvous until the job's own timeout. The kind cluster is sized so both fit; a production contract would need `waitForPodsReady` or a scheduler that gangs.

## The reviews that shaped this, and what each finding changed

| finding | from | answer |
|---|---|---|
| the create path would drop `CompletionMode` | astra | copied explicitly, with `BackoffLimit`; envtest pins the persisted Job |
| `backoffLimit` would not be copied either, defaulting to 6 | Opus | both named and copied |
| `parallelism` would become immutable application config | astra | opt-in `distributed`, immutable by CEL; `parallelism` unchanged |
| CRD defaults make `parallelism: 2` arrive as 2/1; "1" is what cannot be told from unset | astra, Opus | must be 1 with `distributed`; explicit 0 refused |
| CEL on an absent field is not evaluated; `worldSize` not required; a value struct encodes `{}` | Opus | spec-level transition rule; `worldSize` required; pointer field |
| Indexed retries are per index, not per group | astra | `backoffLimit: 0`: any rank failure fails the attempt |
| killing a rank lets gloo end its peer, not the Job controller; `Failed` waits for termination | Opus | `one-rank-fails` exits rank 1 while rank 0 sleeps outside gloo and requires SIGTERM; `FailureTarget` window stated |
| `torchrun --standalone` gives a false positive | astra | one process per Pod, `train.py` started directly |
| no rendezvous timeout: torch waits 30 minutes holding quota | Opus | 60 s on the command line; the DNS-race claim removed |
| the cpu-ddp queue admits one GPU | astra | the experiment's queue admits `worldSize × gpuCount` |
| partial admission would shrink a fixed world | astra | no `job-min-parallelism` |
| admission is all-or-nothing, placement is not | Opus | stated out of scope, with what would close it |
| one RWO `stateVolume` across Pods | astra | refused with `distributed` |
| Service ownership, selection, repair, collisions | astra, Opus | `-ddp` suffix, name+uid selector, owned and watched with its own RBAC; a foreign Service blocks the Job under its own reason |
| names valid for the CR invalid for children; DNS-1035 needs a leading letter | astra, Opus | refused at create: leading letter, no dots, ≤ 59 |
| `Running` and admission latency describe the first Pod; `readyRanks` unspecified | astra, Opus | kept as is; `readyRanks` as `*int32`, nil without `distributed`, a snapshot, tested |
| the negative controls and the collector could misclassify | astra | fresh controls with bounded terminal verdicts; every attempt collected |
| cross-node is forced by one device per worker | Opus | stated as by construction |
| two immutability shapes | Opus | stated as intended |
| the termination canary renders 3/5 | astra | untouched, since `parallelism` keeps its meaning |
| regeneration and the Korean mirror | Opus | regenerated here; the mirror is synced separately |

Second codex `gpt-6-astra` round, on the version above. It found no defect in the CEL rule, the pointer field, `readyRanks`, the hostname, DNS and annotation mechanisms, or the omitted partial admission.

| finding | severity | answer |
|---|---|---|
| Python as PID 1 ignores a default SIGTERM; "143 or `DisruptionTarget`" attributes nothing | blocker | a SIGTERM handler that records itself; pass only on the ordered sequence from hold to Failed |
| evidence collected after a terminal phase loses the deleted rank | major | live Pod watch and log streams from creation; missing records fail |
| "its own reason" left phase, recovery and ordering undefined; `markFailed` always fails | major | Pending with `RendezvousService=False/ServiceConflict`, 30 s requeue, cleared on recovery, never blocks translating an existing Job |
| `ownedConflict` reads the bare name; `CreateOrUpdate` can adopt a racing Service | major | get by the suffixed name, `Create` only, UID-checked ownership, AlreadyExists judged next pass |
| arithmetic and Succeeded do not prove one 2-Pod Workload | major | one Workload owned by the Job's UID, pod set count 2, 2 GPUs reserved; nodeNames asserted |
| a 60 s operation timeout is not a control deadline | major | separate deadlines; one causal rendezvous failure, the peer may be controller-ended |
| the `FailureTarget` window can move the phase backwards | minor | stated as existing behaviour; tests assert the terminal phase only |
| the name rule was not scoped to distributed jobs | minor | distributed only; a digit-leading ordinary name still accepted |
