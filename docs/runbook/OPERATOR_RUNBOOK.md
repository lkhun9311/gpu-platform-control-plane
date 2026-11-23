# GPU platform operator runbook

For the on-call engineer of this platform's training clusters, and, in section 8, of its inference gateway.
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
`--gpu-fault-source=dcgm` enables GPU fault detection and the `gpu-fault` quarantine taint; `--gpu-fault-evict-workloads` additionally moves work off a faulted node. Without the first, GPU faults are not detected and you taint or cordon by hand; the readiness quarantine (`unhealthy` taint on a NotReady node) works with neither flag.

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
      export CKPT_DIR=/shared CKPT_JOB_ID=<unique-id> CKPT_RUN_ID=<run-id>
      python /work/train.py
```

Submit with `kubectl apply -f <file>`.
The platform mounts the volume; checkpointing is the trainer's job. The platform's reference trainer (`/work/train.py` in the training image) writes checkpoints under `$CKPT_DIR/$CKPT_JOB_ID`; on start it tries the checkpoint `LATEST` names, then other complete checkpoints from the newest step down, and loads the first one every rank validates. A job whose command does not point it at the shared volume restarts from step 0 every time.
`CKPT_JOB_ID` decides which checkpoints a job resumes from: keep it the same across a job's automatic attempts, and give a new submission a new ID unless it is meant to continue the old one (the trainer does not check which job wrote a checkpoint). `CKPT_RUN_ID` only labels log lines.
The reference trainer's backend defaults to `gloo` on CPU (`CKPT_BACKEND`); on **EKS** GPU nodes also export `CKPT_BACKEND=nccl`, or the job trains on the CPU.
The admission webhook refuses a distributed job whose claim is missing, not ReadWriteMany, `Lost`, or being deleted; a `Pending` claim is accepted (with a WaitForFirstConsumer class the claim is provisioned and bound when its first consumer is scheduled).
`distributed` is fixed when the job is created; image, command, GPU count and class, queue, completions and the state volume are fixed once the job's batch Job exists (even suspended) or an attempt is recorded. A different shape is a new job, which is the owner's decision.

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
   Which workloads hold the reservation, in every namespace (a Workload's admission names its ClusterQueue; the commands name the `v1beta1` API explicitly because its field names are the ones used here):
   `kubectl get workloads.v1beta1.kueue.x-k8s.io -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,CQ:.status.admission.clusterQueue,ADMISSION_GPU:.status.admission.podSetAssignments[0].resourceUsage.nvidia\.com/gpu,ADMISSION_COUNT:.status.admission.podSetAssignments[0].count' | awk -v cq='gpu-<tenant>' 'NR == 1 || $3 == cq'`
   The two `ADMISSION_` columns are what was admitted; if a Workload has `.status.reclaimablePods`, those Pods' share is already released.
   What the cohort could lend: every tenant ClusterQueue joins the cohort `gpu-platform` with no borrowing or lending limit.
   `kubectl get clusterqueues.v1beta1.kueue.x-k8s.io -o custom-columns='NAME:.metadata.name,COHORT:.spec.cohort,NOMINAL:.spec.resourceGroups[0].flavors[0].resources[0].nominalQuota,RESERVED:.status.flavorsReservation[0].resources[0].total'`
   In this flat cohort, what is free right now is max(0, sum of NOMINAL − sum of RESERVED) over **all** members, the job's own queue included; what it could borrow beyond its own nominal quota excludes its own unused share. A cohort with one member has nothing to lend. Reclaiming lent quota by preemption is separate, and only for a workload that fits its own queue's nominal quota.
   The fix belongs to the tenant (wait, or stop their own work) or to whoever owns the `GPUQuotaPolicy`; do not raise a tenant's quota or delete their other jobs on your own.
   `GPUQuotaPolicy` is cluster-scoped and written by the platform team, not by tenants; escalate quota changes to the platform owner on your rota.
   If the live quota differs from what you expect (for example from the `kubectl.kubernetes.io/last-applied-configuration` annotation), that is worth asking about, but it does not say how or by whom it changed.
   The managed fields give a clue to which tool wrote it, not who:
   `kubectl get gpuquotapolicy <policy> --show-managed-fields -o jsonpath='{range .metadata.managedFields[*]}{.manager} {.operation} {.time}{"\n"}{end}'`; the API audit log says who and when. Report it to the policy's owner rather than restoring it yourself.
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
     **known defect:** while the old Pod is still terminating on the faulted node, the Workload can be deactivated and reactivated many times over, with short-lived Pods created and deleted on other nodes. The 2026-11-07 drill saw about 30 s of this, ending when the old Pod was gone, with no overlap of old and new containers; neither the duration nor the absence of overlap is guaranteed, and on an unreachable node the old Pod may not leave at all. A fix is in a separate change. Do not act on the churn itself; if the old Pod stays on an unreachable node, treat the machine as in section 4.
   - a restartable distributed job is instead handed to its restart lifecycle (section 4).
3. Check the work: `kubectl -n <ns> get pods -o wide` shows the job's new Pod and its node, and the job's `Phase` returns to `Running`. If it does not, it is waiting for admission or placement: section 2.
   Tell the tenant: a job moved off a faulted node is a new Pod and has lost everything local to the old container. Whether it resumes depends on its trainer and a persistent checkpoint (a single-Pod job can have a state volume too); read its logs before telling them it lost its progress.
4. Decide about the card:
   - **Hardware faults (for example Xid 48, 63, 64, 74, 79, 92, 94, 95, or any double-bit ECC) keep the node out of service until the card is reset or replaced.** Leave the taint and the latch alone and open a hardware ticket with the node, card UUID, field and value from the message.
   - After a GPU **reset** that leaves every fault field at zero, the next fresh scrape of the same card releases the latch and the taint by itself (annotation `...cleared-at`).
   - After a card **replacement** the new card has another UUID, and the latch, which names the old one, does not release by itself: once the new card reads zero, acknowledge the old fingerprint (below), and remove the acknowledgement once the latch has cleared.
   - Only for a fault you have decided to live with: write the fingerprint into the `NodeHealth`'s `gpufault.platform.lkhun9311.github.io/acknowledged` annotation; at the next fresh reading that still shows exactly that fault (or a fresh, complete, fault-free reading), `GPUHealthy` becomes `True` reason `Acknowledged` and the taint goes. A stale, unavailable or incomplete reading does not release it, so check `GPUSignal=True Fresh` first. The acknowledgement stays until removed and silences that exact fault if it comes back; remove it when the exception ends. A different fault does not match it.
5. **Never** remove the `gpu-fault` taint by hand: the operator latches the fault and puts it back, and in between you have scheduled work onto a broken card.

`Phase=Quarantine` with `faultSignal.source=node-not-ready` means the node's kubelet is not Ready; the node carries `platform.lkhun9311.github.io/unhealthy:NoSchedule` until it is Ready again.

## 4. A distributed job after a lost node

A restartable job (`maxRestarts > 0`) runs in attempts. Read them:

`kubectl -n <ns> get mltrainingjob <name> -o jsonpath='{range .status.attempts[*]}{.number} {.state} trigger={.trigger} nodes={.nodes} nodeUIDs={.nodeUIDs} waitingFor={.waitingFor} fencedBy={.fencedBy}{"\n"}{end}'`

| attempt state | means |
|---|---|
| `Preparing` / `Active` | the attempt is recorded and its Job is being made / its Job exists (suspended or running: read the job's `Phase` and its Pods for admission and readiness) |
| `Stopping` | a trigger was seen; the old attempt is being retired; `waitingFor` says on what |
| `Stopped` | everything of the attempt is confirmed gone; the next attempt starts, or the job fails if `maxRestarts` is spent |

A lost node is not itself a trigger. The attempt moves to `Stopping` when its Job fails (`RankFailed`: typically the surviving rank's collective times out once its peer stops answering), the GPU fault path hands it over (`NodeFault`), Kueue evicts it (`Evicted`), or its Job disappears (`JobDeleted`). An attempt still `Active` with a dead node is waiting for one of these; look at the surviving ranks' logs.

The next attempt never starts while anything of the old one could still be writing to the shared volume. `waitingFor` names what holds it:

- `job <name> to be deleted`: the old Job is being deleted, and it waits for its Pods. If this lasts more than a minute, look at the attempt's Pods: `kubectl -n <ns> get pods -l job-name=<name> -o wide`. A Pod `Terminating` on a `NotReady` node will not leave by itself: its machine is not answering. Do the machine steps below for that node.
- `pods <a,b> to be gone; held until their kubelet reports them stopped or their node is fenced: <pod>@<node>`: every rank Pod carries the finalizer `platform.lkhun9311.github.io/rank-stopped`, which the controller removes only when the Pod reads `Succeeded` or `Failed`, was never bound, or is being deleted from a node fenced for the attempt. A terminal phase is usually the kubelet's report, but the cluster's Pod garbage collector also marks a Pod `Failed` when its Node object is deleted; the restart barrier still demands a fence for that node (next item), the job's deletion does not (below).
- `workload <wl> to be gone`: Kueue is removing the old admission; seconds.
- `node <node> to be fenced (annotation platform.lkhun9311.github.io/fenced-nodes)`: the node held a rank, is not Ready (or no longer exists, or was replaced by another machine of the same name), and nothing has confirmed the machine is off.

**Fencing is your statement that the machine is off.** A node that stopped answering the API may still be running the rank and writing to the shared volume; the controller never infers that a machine is off from the API, from a deleted Node object, or from a missing Pod.

Machine steps, for each node the attempt ran on (`nodes`) that is NotReady, gone, or **hung**:

**A hung machine whose Node still reads `Ready`.** The Node's `Ready` condition lags the machine: its heartbeat is the kubelet's Lease, and the condition flips to `NotReady` only after the Lease has not been renewed for the controller's grace period (tens of seconds).
Powering a machine off never makes a rank's writes less safe (the fencing contract only needs the machine to be off), so you do not have to wait for `NotReady`.
Power off when **both** hold: the out-of-band console says the machine is not answering, and its Lease has stopped renewing, `kubectl -n kube-node-lease get lease <node> -o jsonpath='{.spec.renewTime}{"\n"}'` older than a minute (`date -u` for now).
If the console says it answers, or the Lease is still renewing, it is not hung: look at the ranks' logs instead.

1. Identify the machine the rank ran on, not whatever now has that name. The attempt's `nodeUIDs` holds the Node's UID when the rank was first seen there (`absent` or `replaced` if it was already gone or replaced by then).
   Drill: the machine is the node name. **EKS**: while the Node object still has that UID, `kubectl get node <node> -o jsonpath='{.metadata.uid} {.spec.providerID}'` gives `aws:///<az>/<instance-id>`; if it is gone or its UID differs, find the instance by its private DNS name, `aws ec2 describe-instances --region <region> --filters Name=private-dns-name,Values=<node> --query 'Reservations[].Instances[].[InstanceId,State.Name,LaunchTime]'`, and take the instance that was running when the rank's Pod was bound there. The attempt's `createdAt` is when its Job was made, before admission and placement, so it alone does not identify the instance; if more than one instance could match, do not terminate on a guess: escalate to the infrastructure owner.
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

Deleting the `MLTrainingJob` waits for its rank Pods under the same finalizer rule, so a job on a hung node stays until the node is powered off; but unlike the restart barrier it does not check the attempt's nodes for a fence. Before deleting a job whose machine stopped answering, power the machine off first anyway.

**After the machine is off.** Its `NodeHealth` reads `Pending` with `Ready=False` reason `NodeNotFound` once the Node object is gone. Leave it: it costs nothing, and it resumes watching a machine that rejoins under the same name.
- Repair or replace the machine through the hardware/infrastructure owner. The drill console has no power-on; on **EKS** a terminated instance never returns, and the node group launches a new instance, which usually registers under a new name.
- A new GPU node needs a `NodeHealth` before the platform watches it (section 0). No running platform controller creates one; the drill's setup and the EKS session runner create them for the nodes they bring up, but a node added any other way has none. Check first, `kubectl get nodehealths -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName`, and if the node is missing create one, named after it, with `kubectl apply -f <file>`:

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
kubectl -n <ns> logs <pod> | grep -E '"event": "(resume|restart_from_zero|start|refused|checkpoint_rejected|checkpoint_refused)"'
kubectl -n <ns> logs <pod> | grep '"event": "step"' | head -20
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
- **No running controller creates a `NodeHealth` for a new GPU node**; create it by hand (section 4, "After the machine is off").
- **Deleting a job does not wait for a fence**: the finalizer accepts a `Failed` phase, which the Pod garbage collector also sets when a Node object is deleted, so a deleted job's last Pods can leave while their machine was never confirmed off (section 4).
- **One faulted card quarantines its whole node** (section 3, step 2); per-card exclusion needs the device plugin to stop advertising that card.
- **Nothing shows a cohort's lendable quota directly**; compute it as in section 2, step 2.
- **A hung machine is recognised from the console and the Lease, not by the platform** (section 4); the platform does not read the out-of-band console.

## 8. Serving: an engine Pod terminated, a 503 surge, a Redis outage

The gateway is `deploy/gateway` in `gpu-platform-control-plane-system`; each model is served by an `InferenceDeployment` in the tenant's target namespace, whose controller owns a Deployment and a Service of the same name (Pods labelled `app.kubernetes.io/instance=<name>`).
Read the dashboard's Gateway row first. Each panel answers one question, and two of them count the same request differently:

| panel | counts | a request whose stream an engine death cut short |
|---|---|---|
| Requests that ended in 5xx (final status) | requests, by the status the client got | not here: it is counted under the 2xx it had already sent |
| Failed backend attempts and fallback rescues | attempts (a request tried twice counts twice), and requests a second backend rescued | not here either |
| Responses cut short after starting | started responses ended early, by `cause`; no status label | here, as `upstream_aborted` |
| Gateway TTFB | first byte, a lower bound on time to first token, not TTFT | |

A panel showing "no series" is not a measured zero: either the counter has never been incremented since the gateway started, or Prometheus is not scraping the gateway at all.
The "Gateway scrape targets up" panel tells the two apart; read it before reading an empty panel as good news.

The two serving alerts are in `config/prometheus/gateway_rules.yaml`:
`GatewayUpstreamErrorsReachingClients` fires when a model's final-5xx rate over 5 minutes stays above 0.1 per second for 5 minutes;
`GatewayModelDegraded` fires when a spare backend has been rescuing a model's requests for 10 minutes.

### 8.1 An engine Pod terminated

What happens, in order:
- New requests reach a Service with no ready endpoint: the connection fails and the gateway answers 502 (504 on a timeout).
  If the model has a second `InferenceDeployment`, the gateway tries it once; the failed attempt counts in `upstream_errors_total` and a rescue in `backend_fallbacks_total`, and the client gets the spare's answer.
- Streams that were already answering are cut: the client had a 200 and its connection is aborted.
  They count under 200 in `requests_total`, so only the cut-short panel (`cause="upstream_aborted"`) and the request record's `cutShort` field show them.
- The `InferenceDeployment` controller replaces the Pod.
  On kind, with the benchharness stub, the first client error came 49 ms after the delete and 200s resumed after about 1.3 s, endpoint propagation included ([FR-002 record](../../hack/chaos-fr002-serving-pod-killed.md)); a GPU engine loading weights takes far longer, and that was not measured there.
- A kill that short does not fire `GatewayUpstreamErrorsReachingClients`: the rule needs a 5xx rate above 0.1 per second over a 5-minute window, about 30 failed requests, and needs it held for 5 minutes.
  A backend with no Pod for minutes does fire it; [the kind rehearsal](../../hack/gateway-alert-delivery.md) records the fault, the firing and the resolved notification at a webhook receiver.

Steps:
1. `kubectl -n <ns> get inferencedeployment <name> -o jsonpath='{.spec.replicasOwner} {.spec.replicas}{"\n"}'`, then `kubectl -n <ns> get deploy <name> -o jsonpath='{.spec.replicas}{"\n"}'`.
   With `replicasOwner` absent or `Controller`, the controller writes the Deployment's replicas from `spec.replicas` on every reconcile: a 0 there was set by someone, and scaling the Deployment by hand is undone.
   With `External`, an autoscaler owns the Deployment's replicas and `spec.replicas` is only the starting count; a Deployment at 0 is that autoscaler's decision, so read the autoscaler.
2. `kubectl -n <ns> get pods -l app.kubernetes.io/instance=<name> -o wide`, then `kubectl -n <ns> describe pod <pod>` for the last state (`OOMKilled`, `Evicted`, `Error`) and `kubectl -n <ns> logs <pod> --previous` for an engine that keeps restarting.
3. `kubectl -n <ns> get endpointslices -l kubernetes.io/service-name=<name> -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]} ready={.conditions.ready}{"\n"}{end}'`: the gateway can reach the model only once an endpoint reads `ready=true`; the default table lists unready addresses too.
4. A Pod on a node that went `NotReady` is a node problem first: section 3 for a GPU fault, section 4's machine steps for a lost machine.
5. Tell the tenant that streams in flight at the time were cut and the gateway does not replay a started stream; their client has to retry.

### 8.2 A 503 surge

A dead engine shows as 502 or 504, not 503.
A 503 comes from one of seven places, and only the last is the engine:

| source | where | how to tell |
|---|---|---|
| the api-keys Secret could not be read | `internal/gateway/server.go:550` | `tenant=""` and `model=""` on the series; log `cannot read the api-keys secret` |
| the rate limiter was never initialised | `internal/gateway/server.go:588` | `model=""`; log `rate limiter was never initialised` |
| the shared rate limit store could not answer, under `closed` | `internal/gateway/server.go:598` | `model=""`; body code `rate_limit_unavailable`; log `rate limit could not be decided` (section 8.4) |
| a holding admitter ran out of room to hold | `internal/gateway/server.go:421` | the response's `X-Admission-Reason` header |
| the request record's arrival line could not be written | `internal/gateway/server.go:656` | only with `--request-record-path`; log `cannot write the request record` (section 8.3) |
| a HoldCap or `PrefixAffinity` backend behind the shared store | `internal/gateway/server.go:684` | body code `single_gateway_required`; `gpuaas_gateway_single_gateway_refusals_total{feature}` |
| the engine answered 503 itself | `internal/gateway/proxy.go:874` | passed through as the engine's status; not retried and not a failed attempt, so `upstream_errors_total` stays flat |

`sum by (tenant, model) (rate(gpuaas_gateway_requests_total{code="503"}[5m]))` gives the labels; then
`kubectl -n gpu-platform-control-plane-system logs -l app.kubernetes.io/component=gateway --prefix --tail=-1 | grep -E 'cannot read the api-keys secret|rate limiter was never initialised|rate limit could not be decided|per-process feature cannot run|cannot write the request record'`.
If none of those lines appear and the labels carry a model, read that model's engine logs (step 2 of 8.1): an engine still loading weights, out of memory, or at capacity answers 503 with the connection accepted.

### 8.3 The request record and its trade-offs

With `--request-record-path`, the gateway appends one JSON line per event to that file (`internal/gateway/requestrecord.go`).
The flag's help says it is for benchmark runs (`cmd/gateway/main.go:187`), and the deployed `config/gateway` does not set it.

- `arrive`, once the body has been read: `requestId`, `tenant`, `arrivedUnixNanos` (`requestrecord.go:48`).
  A request refused before its body is read (401, 403, the limiter's 429) has no arrive line.
- `done`, on every way out of the handler (`server.go:522`): `requestId`, `tenant`, `tier`, `decision`, `reason`, `status`, `priority`, `answered`, `cutShort`, and the stamps `entered`, `arrived`, `recorded`, `deciding`, `decided`, `handoff`, `released`, `firstContent`, `ended` (`requestrecord.go:71`).

Three trade-offs, each from the code:
1. **The arrival line is synced per request.** `arrive` writes and calls `Sync` before it returns, under the recorder's one mutex (`requestrecord.go:129`, the lock at `:134`, the sync at `:139`), and it runs before routing and admission (`server.go:656`).
   So a request the gateway admits always has a line on disk, and every request with a body waits for an fsync, one at a time across the process.
   `recordedUnixNanos` is stamped after the sync (`requestrecord.go:201`), so that cost is measured rather than assumed.
2. **The done line has no sync of its own** (`requestrecord.go:142`).
   It reaches the disk with the next arrival's fsync of the same file, the kernel's writeback, or the sync in `Close` at shutdown (`requestrecord.go:37`, called from `cmd/gateway/main.go:366`).
   A crash loses the done lines written since the last of these, and a failed done write is ignored (`requestrecord.go:329`); the analysis finds the missing line by its join and treats the arm as ineligible (`requestrecord.go:327`).
3. **A failed arrival write refuses the request with 503** (`server.go:656`): serving it would leave admitted work the measurement cannot see.
   The 503 is counted in `requests_total` with the tenant and model, so a full disk or an unwritable record path turns every request with a body into a 503 and can fire `GatewayUpstreamErrorsReachingClients` with every engine healthy.
   Free the space, or restart the gateway without the flag if the run is over.

### 8.4 A Redis outage (shared rate limit store)

This applies only to a gateway started with `--rate-limit-store=redis`; `config/gateway/` ships the default `memory` store at one replica and no Redis (`cmd/gateway/main.go:140`).
That store is the multi-gateway profile, and it supports only `--admission-mode=off` ([run 2](../../hack/gateway-shared-ratelimit/2026-11-22-run2/README.md), "Two separate supported configurations"): the gateway refuses any other mode at start (`internal/gateway/server.go:250`, called from `cmd/gateway/main.go:487`) and answers 503 `single_gateway_required` for HoldCap and `PrefixAffinity` backends (`server.go:684`).
It is one Redis with no HA and no failover (`docs/superpowers/specs/2026-11-21-gateway-shared-ratelimit-design.md:234`).

Which policy is in force:
`kubectl -n gpu-platform-control-plane-system get deploy gateway -o jsonpath='{.spec.template.spec.containers[?(@.name=="gateway")].command} {.spec.template.spec.containers[?(@.name=="gateway")].args}{"\n"}'`.
No `--rate-limit-redis-failure-policy` means `local` (`cmd/gateway/main.go:152`); `--rate-limit-redis-addr` names the Redis.

How to tell the store is down (each replica judges Redis on its own, so read every Pod):
- `gpuaas_gateway_ratelimit_redis_available` is 0 (`internal/gateway/metrics.go:185`); it returns to 1 only on that replica's next successful call.
  It starts at 1 before any call (`ratelimit_redis.go:188`) and only a rate-limited tenant's request calls Redis, so a 1 is the last answer seen, not a health check.
- `gpuaas_gateway_ratelimit_redis_errors_total` rises: timeouts, refused connections, script errors (`metrics.go:167`).
- `gpuaas_gateway_ratelimit_degraded_decisions_total{policy}` rises: requests decided without Redis (`metrics.go:176`).
- `gpuaas_gateway_ratelimit_redis_seconds` piling at the deadline is a Redis too slow to answer, which counts as down (`metrics.go:158`).
- Logs, `kubectl -n gpu-platform-control-plane-system logs -l app.kubernetes.io/component=gateway --prefix --tail=-1` (with `-l`, kubectl shows only 10 lines per Pod otherwise): `Redis rate limit store failed; deciding by the failure policy` once as a replica enters the outage (`internal/gateway/ratelimit_redis.go:251`) and `Redis rate limit store answered again; the shared budget is in force` once as it leaves (`ratelimit_redis.go:260`); under `closed`, `rate limit could not be decided; refusing` for every refused request (`server.go:595`).
- No rule in `config/prometheus/gateway_rules.yaml` reads these series.
  Under `closed` the 503s count in `requests_total` with `model=""` (`server.go:597`), so enough limited traffic fires `GatewayUpstreamErrorsReachingClients` for `model=""`; under `local` nothing fires.

What the gateway does:
- One call is bounded by `--rate-limit-redis-timeout`, default 100 ms, dial included (`cmd/gateway/main.go:150`, `ratelimit_redis.go:47`), and is never retried, because a lost reply may already have spent the token (`ratelimit_redis.go:177`).
- A failed call keeps that replica off Redis for one second (`ratelimit_redis.go:49`, `:248`); the first request after that second tries Redis again, so a replica pays the deadline about once a second while Redis is gone.
- `local` (default): the replica decides from its own in-memory bucket (`ratelimit_redis.go:239`), so a tenant's limit loosens up to replicas × the one-bucket bound.
- `closed`: 503 with body code `rate_limit_unavailable` and `Retry-After: 1` (`ratelimit_redis.go:243`, `server.go:596`).
- Either way, a tenant with no `rateLimit` never calls Redis (`ratelimit_redis.go:205`), and an admitted stream does not touch it again.

Measured on kind, three gateway replicas, one tenant at 60 requests/min with burst 5, 10 requests a second for 60 s, Redis scaled to 0 for 10.7 to 11.7 s, three repetitions ([run 2](../../hack/gateway-shared-ratelimit/2026-11-22-run2/README.md), event arms; counts in its `events/score.txt`):
- `local`: admitted 104 / 105 / 102 against a one-bucket bound of 64.90, no request failed, and the 3 / 4 / 4 streams in flight all completed.
- `closed`: 503s 118 / 125 / 123, the last sent 1.1 to 2.0 s after Redis was ready, and the 3 / 3 / 4 streams in flight all completed.
- Each replica counted 7 to 10 Redis errors per outage, about one per second; in the first repetition of each policy two requests waited out the 100 ms deadline (seq 104 and 105 in `events/redis-3-down-closed-1.tsv`, 106 and 107 in `events/redis-3-down-local-1.tsv`; the README counts one for `closed`).
- A CPU stub on one node over loopback: not a real network, a remote Redis or a GPU engine.

Steps:
1. Confirm Redis from the address in `--rate-limit-redis-addr`: its Pod and endpoints, then `kubectl -n <redis-ns> exec <redis-pod> -- redis-cli ping`, with `REDISCLI_AUTH` set if it has a password.
   Errors with Redis answering point at the address, the network or the password; the log line in step one carries the error.
2. Under `local`, decide whether up to replicas × each tenant's limit is acceptable for the outage.
   If not, scaling the gateway to one replica makes the local bucket the tenant's limit again, at the cost of capacity and of the streams on the removed Pods.
   Changing the policy to `closed` is a restart of every replica, and refuses every limited tenant until Redis answers.
3. Under `closed`, tell tenants the 503 `rate_limit_unavailable` is not their budget and to retry after `Retry-After`.
4. Bring Redis back, then watch `gpuaas_gateway_ratelimit_redis_available` return to 1 on every Pod with the `answered again` line.
   A Redis restarted without persistence starts every bucket full, so each tenant gets one fresh burst (`ratelimit_redis.go:114`).

### 8.5 What this section does not cover

- **Central logging.** The request record is a local file in the gateway Pod and gateway logs are read with `kubectl logs`; nothing ships either elsewhere.
- **TPOT in Grafana.** The gateway measures first byte and whole-request duration only; no series measures time per output token, so no panel shows it.
- **HA.** The shipped gateway runs one replica (`config/gateway/deployment.yaml`, because the memory store's rate-limit buckets live in process memory), so a gateway Pod restart is an outage for every model; this section has no procedure for it.
  The shared store's Redis has no HA either (section 8.4).
