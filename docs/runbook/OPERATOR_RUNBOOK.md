# GPU platform operator runbook

For the on-call engineer of this platform's training clusters.
It assumes `kubectl`, a POSIX shell (`grep`, `head`) and the out-of-band machine console; every command below is copy-paste ready once the placeholders in `<angle brackets>` are filled in.
Where the drill cluster (kind) and production (EKS) differ, the EKS form is marked **EKS**.

**Before any change, check which cluster you are on:** `kubectl config current-context`.
- Drill: `kubectl config use-context kind-drill`. Tenant namespace `train-a`, its queue `gpu-train-a`, GPU workers `drill-worker` and `drill-worker2` (label `drill.lkhun9311.github.io/gpu=true`, the `<gpu-node-label>` below), machine console `hack/drill/oob.sh`.
- **EKS**: the context of the cluster you were paged for (`aws eks update-kubeconfig --name <cluster> --region <region>`), GPU node label `eks.amazonaws.com/nodegroup=gpu`, machine console the EC2 API (AWS CLI with the on-call role, `--region <region>`).

## 0. The objects you will meet

| object | scope | what it is | read it with |
|---|---|---|---|
| `MLTrainingJob` (`mltrainingjobs.platform.lkhun9311.github.io`) | namespace | a tenant's training job; the platform renders one batch `Job` from it | `kubectl -n <ns> get mltrainingjobs` |
| Kueue `Workload` | namespace | the admission record Kueue keeps for that `Job` | `kubectl -n <ns> get workloads` |
| Kueue `LocalQueue` / `ClusterQueue` | namespace / cluster | the tenant's queue `gpu-<tenant>` and its GPU quota | `kubectl get clusterqueues`, `kubectl -n <ns> get localqueues` |
| `GPUQuotaPolicy` | cluster | the tenant's GPU quota; with `trainingQuota: true` it is published as the ClusterQueue above | `kubectl get gpuquotapolicies` |
| `NodeHealth` | cluster | one per GPU node: the platform's view of that node and the only way its fault handling reaches it | `kubectl get nodehealths` |

The platform only watches nodes that have a `NodeHealth`.
A GPU node without one gets no fault detection and no quarantine; compare `kubectl get nodehealths -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName` with `kubectl get nodes -l <gpu-node-label>` when a node is new.

GPU fault handling runs only when the operator was started with it. Check once per shift:
`kubectl -n gpu-platform-control-plane-system get deploy -l control-plane=controller-manager -o jsonpath='{.items[0].spec.template.spec.containers[0].args}'`
`--gpu-fault-source=dcgm` means faults are detected; `--gpu-fault-evict-workloads` means work on a faulted node is moved off it. Without them, section 3's automatic steps do not happen and you taint or cordon by hand.

## 1. Submitting a training job

A single-Pod job:

```yaml
apiVersion: platform.lkhun9311.github.io/v1
kind: MLTrainingJob
metadata: {name: <name>, namespace: <ns>}
spec:
  queue: gpu-<tenant>          # the tenant's LocalQueue
  image: <image>
  gpuCount: 1                  # GPUs per Pod
  command: ["python", "/work/train.py"]
```

A distributed job that may restart (whole-job restart, every rank from the last checkpoint):

```yaml
apiVersion: platform.lkhun9311.github.io/v1
kind: MLTrainingJob
metadata: {name: <name>, namespace: <ns>}
spec:
  queue: gpu-<tenant>
  image: <image>
  gpuCount: 1                  # per rank; Kueue admits worldSize x gpuCount
  distributed:
    worldSize: 2               # ranks; rank i runs in the Pod with completion index i
    maxRestarts: 1             # whole-job restarts allowed; 0 = none
  stateVolume:
    claimName: <rwx-claim>     # must exist and be ReadWriteMany; required when maxRestarts > 0
    mountPath: /shared
  command:
    - sh
    - -c
    - |
      export CKPT_DIR=/shared CKPT_JOB_ID=<name> CKPT_RUN_ID=<name>
      python /work/train.py
```

Submit with `kubectl apply -f <file>`.
The platform mounts the volume; checkpointing is the trainer's job. The platform's reference trainer (`/work/train.py` in the training image) writes checkpoints under `$CKPT_DIR/$CKPT_JOB_ID` and resumes from the newest complete one; a job whose command does not point it at the shared volume restarts from step 0 every time.
The admission webhook refuses a distributed job whose claim is missing, not ReadWriteMany, `Lost`, or being deleted; a `Pending` claim is accepted (a WaitForFirstConsumer class binds when the first rank mounts it).
Image, command, GPU count and `distributed` cannot be changed once the job has started; a different shape is a new job, which is the owner's decision.

`kubectl -n <ns> get mltrainingjob <name>` shows `Phase` and `Ready Ranks`.
`Ready Ranks` is filled in only for a distributed job; for a single-Pod job the column is empty by design, and `Phase` alone says whether its Pod is up.

| phase | means |
|---|---|
| `Pending` | not admitted, or between two attempts of a restartable job (section 2, step 1) |
| `Admitted` | quota reserved, but not every rank is up: Pods waiting for a node, pulling, or starting |
| `Running` | every rank's Pod Ready or already succeeded, with at least one still Ready |
| `Succeeded` | the Job completed |
| `Failed` | read the `JobSynced` condition: `RestartsExhausted` (a restartable job spent `maxRestarts`) or `JobConflict` (a Job of the same name this job does not own); otherwise the `Admitted` condition's `JobFailed` |

`Running` is Pod readiness, not training: training has started when the trainer logs a step (section 5).

## 2. Why is my job not running?

Work down this list; stop at the first answer.

1. **The platform's view.** `kubectl -n <ns> get mltrainingjob <name> -o jsonpath='{.status.phase}{"\n"}{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'`
   - `Admitted=False` reason `Restarting`: a restartable job between attempts; go to section 4 and read the current attempt's `waitingFor`, which names what the restart waits on.
   - `Admitted=False` reason `RendezvousServiceUnavailable`: the job's rendezvous Service could not be created (often a foreign Service of the same name); read the `RendezvousService` condition's message.
   - `Admitted=False` reason `QueuedForAdmission`: Kueue has not admitted it; go to 2. This condition carries no message by design; Kueue's reason is on the Workload (step 2).
   - phase `Admitted` (`Admitted=True` reason `QuotaReserved`): quota is not the problem; go to 3.
2. **Quota.** Find the job's Workload: `kubectl -n <ns> get job <name> -o jsonpath='{.metadata.uid}'`, then
   `kubectl -n <ns> get workloads -l kueue.x-k8s.io/job-uid=<uid>` and
   `kubectl -n <ns> get workload <wl> -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'`.
   The `QuotaReserved=False` message is the answer, e.g. `couldn't assign flavors to pod set main: insufficient unused quota for nvidia.com/gpu in flavor gpu, 1 more needed`: the tenant's queue, with whatever it may borrow from the shared cohort `gpu-platform`, cannot fit the request, whatever the nodes have free.
   For context: `kubectl get clusterqueue gpu-<tenant> -o jsonpath='{.spec.resourceGroups[0].flavors[0].resources[0].nominalQuota} nominal, {.status.flavorsReservation[0].resources[0].total} reserved, {.status.flavorsReservation[0].resources[0].borrowed} borrowed{"\n"}'`.
   Which workloads hold the reservation, in every namespace (a Workload's admission names its ClusterQueue):
   `kubectl get workloads -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,CQ:.status.admission.clusterQueue,GPU:.status.admission.podSetAssignments[0].resourceUsage.nvidia\.com/gpu,COUNT:.status.admission.podSetAssignments[0].count' | grep -w gpu-<tenant>`
   What the cohort could lend: every tenant ClusterQueue joins the cohort `gpu-platform` with no borrowing or lending limit, so a queue may borrow any other member's nominal quota that is not reserved.
   `kubectl get clusterqueues -o custom-columns='NAME:.metadata.name,COHORT:.spec.cohort,NOMINAL:.spec.resourceGroups[0].flavors[0].resources[0].nominalQuota,RESERVED:.status.flavorsReservation[0].resources[0].total'`; lendable = the sum of NOMINAL − RESERVED over the other members. A cohort with one member has nothing to lend. Borrowed quota is reclaimed by preemption when its owner submits.
   The fix belongs to the tenant (wait, or stop their own work) or to whoever owns the `GPUQuotaPolicy`; do not raise a tenant's quota or delete their other jobs on your own.
   `GPUQuotaPolicy` is cluster-scoped and written by the platform team, not by tenants; escalate quota changes to the platform owner on your rota.
   If the live quota differs from what you expect (for example from the `kubectl.kubernetes.io/last-applied-configuration` annotation), someone changed it outside `kubectl apply`; see who and when with
   `kubectl get gpuquotapolicy <policy> --show-managed-fields -o jsonpath='{range .metadata.managedFields[*]}{.manager} {.operation} {.time}{"\n"}{end}'`, and report it with the policy's owner rather than restoring it yourself.
3. **Placement.** The job is admitted but a Pod has no node:
   `kubectl -n <ns> get pods -l job-name=<name> -o wide` (a Pod `Pending` with no NODE), then
   `kubectl -n <ns> describe pod <pod>` and read the `FailedScheduling` event, e.g. `0/3 nodes are available: ... 2 Insufficient nvidia.com/gpu`.
   That message alone does not tell capacity from fragmentation. Count the free GPUs per node:
   `kubectl describe nodes -l <gpu-node-label> | grep -E '^Name:|nvidia.com/gpu'` prints, per node, Capacity, Allocatable, then the allocated request; free = allocatable − allocated.
   - **Fragmentation**: the free GPUs add up to the request, but cannot be grouped into Pods of `gpuCount` each. Count, per node, the whole Pods that fit (free ÷ `gpuCount`, rounded down) and add them up; fewer than the Pods still to place is fragmentation. Example: two nodes with one free GPU each, one Pod asking for two.
   - **Capacity**: the free GPUs across eligible nodes are fewer than the request.
   - **Excluded nodes**: a node with free GPUs carries a taint the Pod does not tolerate (`platform.lkhun9311.github.io/gpu-fault`, `platform.lkhun9311.github.io/unhealthy`, cordon); see section 3.
   Fragmentation is fixed by moving work, which is the owners' decision: report which jobs hold the stranded GPUs and on which nodes; do not delete other tenants' work to make room.
4. **A distributed job** stays `Admitted` until every rank is up; one rank without a node holds the whole quota of the job until Kueue's readiness timeout, if one is configured, evicts it.

## 3. A GPU fault

With `--gpu-fault-source=dcgm` (section 0) the operator scrapes each `NodeHealth` node's DCGM exporter every second.
A non-zero Xid other than the application Xids 13, 31, 43, 45 and 68, or a double-bit ECC count above zero, is a fault.

1. Find it: `kubectl get nodehealths` (column `Phase`: `Ready`, `Quarantine`, `Pending`), then for the node:
   `kubectl get nodehealth <nh> -o jsonpath='{.status.faultSignal}{"\n"}{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'`
   - `GPUSignal=True` reason `Fresh`: the reading is current. `False` (`Stale`, `NoExporter`, `ScrapeFailed`, ...): the platform cannot see the cards, which is not health.
   - `GPUHealthy=False` reason `XidError`, `EccDoubleBitError` or `MultipleFaults`, message `fault <card>/<field>=<value>`: the fault. The fingerprint is also in the annotation `gpufault.platform.lkhun9311.github.io/fingerprint`.
     `<card>` is the card's UUID as the DCGM exporter labels it (`GPU-…` on a real NVIDIA card; the drill's simulated exporter names its cards `fake-gpu-<n>`). That is the UUID the hardware ticket asks for.
   - `faultSignal` names one cause only: `{source: dcgm, code: <fingerprint>}`, or `{source: node-not-ready}` when the kubelet is also down, which hides a GPU fault behind it. Read both the `GPUHealthy` condition and the node's taints.
2. What the platform did (with the flags of section 0):
   - the node is tainted `platform.lkhun9311.github.io/gpu-fault=true:NoSchedule` (`kubectl get node <node> -o jsonpath='{.spec.taints}'`): nothing new is placed there, except Pods that tolerate the taint (the exporters do);
     the taint is on the Node, so **one faulted card takes every card of that node out of service**, healthy ones included: the scheduler places GPU Pods by count and cannot be told to avoid one card. The cluster's usable GPUs drop by the node's whole count until it is repaired; say so when you report the incident.
   - with `--gpu-fault-evict-workloads`, the Kueue Workloads of GPU Pods on that node that belong to a Job were deactivated (annotations `gpufault.platform.lkhun9311.github.io/deactivated-*` on the Workload); once Kueue has evicted them they are reactivated (`...reactivated-at`) and queue again, and come back wherever there is room, if there is room;
     **known defect:** while the old Pod is still terminating on the faulted node (up to its grace period, about 30 s), the Workload can be deactivated and reactivated many times over, with short-lived Pods created and deleted on other nodes. It stops by itself once the old Pod is gone, the old and new containers do not overlap, and a fix is in a separate change; do not act on it.
   - a restartable distributed job is instead handed to its restart lifecycle (section 4).
3. Check the work: `kubectl -n <ns> get pods -o wide` shows the job's new Pod and its node, and the job's `Phase` returns to `Running`. If it does not, it is waiting for admission or placement: section 2.
   Tell the tenant: a job moved off a faulted node is a new Pod. A single-Pod job, or any job whose command does not resume from a checkpoint on a shared volume, starts again from step 0 and has lost its progress.
4. Decide about the card:
   - **Hardware faults (for example Xid 48, 63, 64, 74, 79, 92, 94, 95, or any double-bit ECC) keep the node out of service until the card is reset or replaced.** Leave the taint and the latch alone and open a hardware ticket with the node, card UUID, field and value from the message.
   - After a GPU **reset** that leaves every fault field at zero, the next fresh scrape of the same card releases the latch and the taint by itself (annotation `...cleared-at`).
   - After a card **replacement** the new card has another UUID, and the latch, which names the old one, does not release by itself: once the new card reads zero, acknowledge the old fingerprint (below), and remove the acknowledgement once the latch has cleared.
   - Only for a fault you have decided to live with: write the fingerprint into the `NodeHealth`'s `gpufault.platform.lkhun9311.github.io/acknowledged` annotation; `GPUHealthy` becomes `True` reason `Acknowledged` and the taint goes. The acknowledgement stays until removed and silences that exact fault if it comes back; remove it when the exception ends. A different fault does not match it.
5. **Never** remove the `gpu-fault` taint by hand: the operator latches the fault and puts it back, and in between you have scheduled work onto a broken card.

`Phase=Quarantine` with `faultSignal.source=node-not-ready` means the node's kubelet is not Ready; the node carries `platform.lkhun9311.github.io/unhealthy:NoSchedule` until it is Ready again.

## 4. A distributed job after a lost node

A restartable job (`maxRestarts > 0`) runs in attempts. Read them:

`kubectl -n <ns> get mltrainingjob <name> -o jsonpath='{range .status.attempts[*]}{.number} {.state} trigger={.trigger} nodes={.nodes} nodeUIDs={.nodeUIDs} waitingFor={.waitingFor} fencedBy={.fencedBy}{"\n"}{end}'`

| attempt state | means |
|---|---|
| `Preparing` / `Active` | its Job is being made / running |
| `Stopping` | a trigger was seen; the old attempt is being retired; `waitingFor` says on what |
| `Stopped` | everything of the attempt is confirmed gone; the next attempt starts, or the job fails if `maxRestarts` is spent |

A lost node is not itself a trigger. The attempt moves to `Stopping` when its Job fails (`RankFailed`: typically the surviving rank's collective times out once its peer stops answering), the GPU fault path hands it over (`NodeFault`), Kueue evicts it (`Evicted`), or its Job disappears (`JobDeleted`). An attempt still `Active` with a dead node is waiting for one of these; look at the surviving ranks' logs.

The next attempt never starts while anything of the old one could still be writing to the shared volume. `waitingFor` names what holds it:

- `job <name> to be deleted`: the old Job is being deleted, and it waits for its Pods. If this lasts more than a minute, look at the attempt's Pods: `kubectl -n <ns> get pods -l job-name=<name> -o wide`. A Pod `Terminating` on a `NotReady` node will not leave by itself: its machine is not answering. Do the machine steps below for that node.
- `pods <a,b> to be gone; held until their kubelet reports them stopped or their node is fenced: <pod>@<node>`: every rank Pod carries the finalizer `platform.lkhun9311.github.io/rank-stopped`, which the controller removes only when that Pod's kubelet has reported it stopped, or its node is fenced.
- `workload <wl> to be gone`: Kueue is removing the old admission; seconds.
- `node <node> to be fenced (annotation platform.lkhun9311.github.io/fenced-nodes)`: the node held a rank, is not Ready (or no longer exists, or was replaced by another machine of the same name), and nothing has confirmed the machine is off.

**Fencing is your statement that the machine is off.** A node that stopped answering the API may still be running the rank and writing to the shared volume; the controller never infers that a machine is off from the API, from a deleted Node object, or from a missing Pod.

Machine steps, for each node the attempt ran on (`nodes`) that is NotReady, gone, or **hung**:

**A hung machine whose Node still reads `Ready`.** The Node's `Ready` condition lags the machine: its heartbeat is the kubelet's Lease, and the condition flips to `NotReady` only after the Lease has not been renewed for the controller's grace period (tens of seconds).
Powering a machine off never makes a rank's writes less safe (the fencing contract only needs the machine to be off), so you do not have to wait for `NotReady`.
Power off when **both** hold: the out-of-band console says the machine is not answering, and its Lease has stopped renewing, `kubectl -n kube-node-lease get lease <node> -o jsonpath='{.spec.renewTime}{"\n"}'` older than a minute (`date -u` for now).
If the console says it answers, or the Lease is still renewing, it is not hung: look at the ranks' logs instead.

1. Identify the machine the rank ran on, not whatever now has that name. The attempt's `nodeUIDs` holds the Node's UID when the rank was first seen there (`absent` or `replaced` if it was already gone or replaced by then).
   Drill: the machine is the node name. **EKS**: while the Node object still has that UID, `kubectl get node <node> -o jsonpath='{.metadata.uid} {.spec.providerID}'` gives `aws:///<az>/<instance-id>`; if it is gone or its UID differs, find the instance by its private DNS name, `aws ec2 describe-instances --region <region> --filters Name=private-dns-name,Values=<node> --query 'Reservations[].Instances[].[InstanceId,State.Name,LaunchTime]'`, and take the one that was running when the attempt started (its `createdAt`).
2. Confirm its state out of band, never through Kubernetes: drill `hack/drill/oob.sh status <node>` (`on, answering` / `on, not answering (hung)` / `off`); **EKS** `aws ec2 describe-instances --region <region> --instance-ids <id> --query 'Reservations[].Instances[].State.Name'` (`terminated` or `stopped` is off).
3. If it is not off, power it off out of band: drill `hack/drill/oob.sh poweroff <node>`; **EKS** `aws ec2 terminate-instances --region <region> --instance-ids <id>`, then repeat step 2 until `terminated`.
   A hung machine is not an off machine: it can resume and write. Powering it off also removes its Node object (EKS does this for a terminated instance; the drill console does the same), which lets its Pods go.
4. Only then fence it. Read the annotation first, and write it back with the node added, keeping every existing entry:
   `kubectl -n <ns> get mltrainingjob <name> -o jsonpath='{.metadata.annotations.platform\.lkhun9311\.github\.io/fenced-nodes}{"\n"}'`
   `kubectl -n <ns> annotate mltrainingjob <name> platform.lkhun9311.github.io/fenced-nodes=<existing-entries,><node> --overwrite`
   - If `waitingFor` says "an earlier attempt ran on another machine of the same name, so name it as `<node>@<id>`", write that exact `<node>@<id>` instead of the bare name.
   - An entry is **spent** by the attempt that stopped on it (the attempt's `fencedBy`). If the same node is lost again in a later attempt, `waitingFor` says the entry is spent; add an entry scoped to the current attempt number `N`: `<node>#N` (or `<node>@<id>#N`).
   - Never list a node that is still running; never fence a node you have not confirmed off.
5. Watch the attempt reach `Stopped` and the next one start (`Preparing` → `Active`).
   The new attempt needs `worldSize` × `gpuCount` free GPUs on healthy nodes and may be admitted while a rank still has no node; if it does not start, section 2.
6. Verify training resumed from the checkpoint (section 5), not from step 0.
7. Tell the tenant the restart happened and what is left of its budget: the current attempt number `N` is the last number in `.status.attempts`, and `.spec.distributed.maxRestarts` allows `maxRestarts + 1` attempts in all; when `N` exceeds `maxRestarts`, the next lost node fails the job with `RestartsExhausted`. Whether to resubmit with a larger budget is the tenant's decision.

Deleting the `MLTrainingJob` does not skip any of this: its deletion waits until every rank Pod is known stopped, so a job on a hung node stays until the node is powered off and fenced.

**After the machine is off.** Its `NodeHealth` reads `Pending` with `Ready=False` reason `NodeNotFound` once the Node object is gone. Leave it: it costs nothing, and it resumes watching a machine that rejoins under the same name.
- Repair or replace the machine through the hardware/infrastructure owner. The drill console has no power-on; on **EKS** a terminated instance never returns, and the node group launches a new instance, which usually registers under a new name.
- A new GPU node needs a `NodeHealth` before the platform watches it (section 0); nothing creates one automatically today. Create one per node, named after it, with `kubectl apply -f <file>`:

  ```yaml
  apiVersion: platform.lkhun9311.github.io/v1
  kind: NodeHealth
  metadata: {name: <node>}
  spec: {nodeName: <node>}
  ```
- A machine that rejoins under the **same** name is a new Node with a new UID. If a later attempt runs there and is lost, `waitingFor` asks for `<node>@<id>` (step 4); write that form.
- Delete the old `NodeHealth` only when the machine is decommissioned for good and no Node of that name will return; never to silence a node that still exists (section 6).

## 5. Did training resume?

For the platform's reference trainer: it writes one JSON line per event to each rank Pod's log, each with `attempt`, `rank` and `event`.
For every rank of the new attempt (label `platform.lkhun9311.github.io/mltrainingjob-attempt=<N>`):

```
kubectl -n <ns> get pods -l job-name=<name>,platform.lkhun9311.github.io/mltrainingjob-attempt=<N> -o wide
kubectl -n <ns> logs <pod> | grep -E '"event": "(resume|restart_from_zero|start|refused|checkpoint_rejected|checkpoint_refused|step)"' | head -20
```

A resume, for every rank:
- `"event": "resume"` with `"from_step": S` (S > 0) and the checkpoint `from_dir`, the same on every rank;
- then `"event": "start"` with `"resumed_from_step": S`;
- then `"event": "step"` records from step S+1 on, increasing.

Anything else is not a resume:
- `"event": "restart_from_zero"`: no usable checkpoint was found; the job trains from scratch. Report it.
- `"event": "refused"`: the rank refused to continue (for example a checkpoint that does not match it) and exits; read its `reason`.
- `"event": "checkpoint_rejected"`: a checkpoint failed its checks while loading and an older one, or none, is tried; the later `resume` or `restart_from_zero` says which.
- `"event": "checkpoint_refused"`: a checkpoint was not published while saving, because the ranks disagreed; the previous one stays the newest.

The job is done when its phase is `Succeeded`.

## 6. Never

- Never force-delete a rank Pod (`--grace-period=0 --force`) or remove the `rank-stopped` finalizer by hand to make a restart go: that is exactly the case the barrier exists for, a rank still writing on a machine nobody confirmed off.
- Never fence a node without confirming out of band that its machine is off.
- Never remove `gpu-fault` or `unhealthy` taints by hand.
- Never delete another tenant's job, or change a tenant's quota, to make room for a job.
- Never delete a `NodeHealth` to silence a node: the node then has no fault handling at all.

## 7. Known limitations (platform changes, not procedures)

Found by the 2026-11-07 drill (`hack/drill/results-20261107/README.md`); each is a change to the platform, and until it lands the procedure above is the workaround.
- **The restart barrier's message hides a hung machine.** While a rank's machine hangs, `waitingFor` reads `job <name> to be deleted`, not the node; section 4 tells you to look at the Pods.
- **A displaced Workload churns while its old Pod terminates** (section 3, step 2).
- **No `NodeHealth` is created for a new GPU node**; create it by hand (section 4, "After the machine is off").
- **One faulted card quarantines its whole node** (section 3, step 2); per-card exclusion needs the device plugin to stop advertising that card.
- **Nothing shows a cohort's lendable quota directly**; compute it as in section 2, step 2.
- **A hung machine is recognised from the console and the Lease, not by the platform** (section 4); the platform does not read the out-of-band console.
