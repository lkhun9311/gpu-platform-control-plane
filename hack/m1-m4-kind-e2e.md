# M1-M4a kind end-to-end: CRDs, node quarantine, quota enforcement and the serving phase ladder

M1 through M4-a were verified by envtest and nothing else. Their code exists, their
tests pass, and until this run no log showed the four of them behaving on a real
cluster. That is the same gap M6 had before [`m6-kind-e2e.sh`](m6-kind-e2e.sh), and it
is closed the same way: drive them end to end on `kind` and commit what happened.

The whole run is scripted in [`m1-m4-kind-e2e.sh`](m1-m4-kind-e2e.sh); this document
explains what it asserts and records the observed evidence, which is in
[`m1-m4-e2e-evidence.log`](m1-m4-e2e-evidence.log).

> **No real GPU and no AWS.** The fake device plugin advertises `nvidia.com/gpu`
> capacity, and the serving container is a stand-in
> ([`serving-stub/`](serving-stub/)) that accepts the `--model` and `--model-path`
> arguments the operator passes and answers `/health`. It serves no model. What is
> demonstrated is the control plane's behaviour, never inference performance.

## What is being demonstrated

Five things, each chosen because it can fail in a way a green tick would not show.

1. **The CRDs install and the operator runs.** Five CRDs, applied from the committed
   `config/crd` rather than regenerated, and the operator reaches Ready.

2. **`NodeHealth` mirrors the node, and quarantine actually taints it.** The script
   stops a worker's kubelet, waits for `Quarantine`, and then checks the node itself
   carries `platform.lkhun9311.github.io/unhealthy:NoSchedule` — then restarts the
   kubelet and checks the taint comes *off*. A phase that moves without the taint
   following it is a status field reporting an enforcement that never happened, and
   reading the phase twice would not tell the two apart.

3. **`GPUQuotaPolicy` syncs a `ResourceQuota` that binds.** Not "the object exists":
   a pod requesting 2 GPUs against a ceiling of 1 is submitted, and the API server's
   refusal is recorded verbatim.

4. **A policy refuses to take over a `ResourceQuota` it does not own.** The synced
   name is deterministic (`gpuquota-<policy>`), so a foreign object of exactly that
   name is planted *before* the policy exists. The policy must go `Degraded` and
   leave it untouched. This is the one assertion here that shows a boundary rather
   than a feature, and it is the only thing outside envtest that has exercised
   `metav1.IsControlledBy` on this path.

5. **`InferenceDeployment` walks the phase ladder.** It reaches `Ready` with a replica
   whose container is genuinely ready, and when scaled to zero it resolves to `Ready`
   for the reason `ScaledToZero` — "zero wanted" and "none ready yet" are different
   states that a naive reading conflates, and the reason string is where that
   distinction is recorded.

## Prerequisites

`docker`, `kind`, `kubectl`, and the repository's `bin/kustomize` (the script puts
`bin/` on `PATH` itself). Network access is needed once, to fetch the Kueue release
manifest.

## Procedure

```sh
./hack/m1-m4-kind-e2e.sh
# evidence is written to hack/m1-m4-e2e-evidence.log
# tear down when done:
kind delete cluster --name m1m4
```

The cluster is `m1m4`, created by the script and deliberately not one of the
long-lived ones. The `platform` cluster carries months of state from M6 and M7, and
this repository has already been bitten once by an old cluster that made an incomplete
procedure look complete — only a fresh cluster shows what these milestones do unaided.

Three steps in the script are there because the run failed without them, and each is
worth naming because none is obvious from the manifests:

- **Kueue is installed although nothing in M1-M4a uses it.** The operator does not
  start without it: `GPUQuotaPolicy` `Owns` `ClusterQueue` and `LocalQueue`, and
  `MLTrainingJob` puts a field index and a watch on `Workload`, so the manager's cache
  cannot start those informers when the Kueue CRDs are absent. A milestone can be
  independent of a dependency and still need it installed to be observed at all.

- **The operator image is overridden on the live Deployment.**
  `config/manager/kustomization.yaml` pins the operator to an ECR digest that `ci.yml`
  rewrites on every publish, and `kind` has no credentials for that registry. The pin's
  own comment says the local path is meant to override it — via `make deploy`, which
  rewrites the committed kustomization, and this run must not do that, because the tree
  it installs from is the thing being evidenced. `kubectl set image` on the live object
  leaves the repository untouched and puts the substitution in the log.

- **The apply uses `--force-conflicts`.** That image override takes ownership of
  `.spec.template.spec.containers[name="manager"].image` as the field manager
  `kubectl-set`, and a later server-side apply of the same manifest is refused with a
  conflict. It is invisible on a fresh cluster and appears only from the second run
  onwards.

## Observed evidence

Every line below is from
[`m1-m4-e2e-evidence.log`](m1-m4-e2e-evidence.log); the script exited 0.

### The node was quarantined, and the node knew it

```
  nodehealth/nh-m1m4-worker {.status.phase} = Ready  (after 0s)
  no unhealthy taint while the node is Ready, as required
  -- stopping the kubelet so the Node goes NotReady --
  nodehealth/nh-m1m4-worker {.status.phase} = Quarantine  (after 33s)
  taint present on m1m4-worker (after 0s)
```

The taint as the API server holds it, with Kubernetes' own unreachable taint beside it
— two independent witnesses to one event:

```
[{"effect":"NoSchedule","key":"platform.lkhun9311.github.io/unhealthy","value":"true"},
 {"effect":"NoSchedule","key":"node.kubernetes.io/unreachable","timeAdded":"2026-09-29T11:34:05Z"}]
```

and the fault signal the CR recorded, `{"source":"node-not-ready"}`. On restarting the
kubelet the phase returned to `Ready` in 3s and the taint was gone.

### The quota was enforced by the API server, not by the operator's opinion

```
  the ResourceQuota the policy created, with its hard ceiling:
{"requests.nvidia.com/gpu":"1"}
  -- a pod asking for 2 GPUs against a ceiling of 1 must be REFUSED --
  refused, as the ceiling requires. The API server said:
    Error from server (Forbidden): error when creating "STDIN": pods "over-quota" is forbidden:
    exceeded quota: gpuquota-m1m4-policy, requested: requests.nvidia.com/gpu=2,
    used: requests.nvidia.com/gpu=0, limited: requests.nvidia.com/gpu=1
```

### The policy refused an object it did not own

```
  gpuquotapolicy/m1m4-collide {.status.phase} = Degraded  (after 0s)
  the refusal it recorded:
ResourceQuota m1m4-tenant/gpuquota-m1m4-collide already exists and is not owned by this policy
  and the planted object, which must still be the one that was planted:
    {"pods":"7"}
  untouched: the policy neither hijacked nor deleted it
```

### The serving ladder, and the distinction at zero

```
  -n m1m4-tenant inferencedeployment/m1m4-serving {.status.phase} = Ready  (after 3s)
  the Available condition's reason with a replica up:
MinimumReplicasAvailable
  the pod's own readiness, and its restart count:
POD                             READY   RESTARTS   NODE
m1m4-serving-779788d796-9wn6n   true    0          m1m4-worker2
  -- scaled to zero: 'zero wanted' and 'none ready yet' must not read the same --
  -n m1m4-tenant inferencedeployment/m1m4-serving {.status.phase} = Ready  (after 3s)
  ... {.status.conditions[?(@.type=="Available")].reason} = ScaledToZero  (after 0s)
```

`READY true` with `RESTARTS 0` is recorded next to the phase on purpose. `Ready` is a
status field the operator writes; the readiness column is the probe the kubelet
actually ran, and a replica counted ready whose container never answered `/health` is
the failure an earlier version of this script produced.

## Notes and caveats

**A quarantined node does not get its GPUs back.** Step 2 stops and starts a worker's
kubelet, which empties `/var/lib/kubelet/device-plugins`. The simulator pod stays
`Running` with 0 restarts and never re-registers, so that node advertises 0 GPUs for
the rest of the run — visible in the capacity table step 5 prints before it schedules
anything. Nothing reported the loss: no pod died, no phase moved, no condition went
false. A real `nvidia-device-plugin` watches `kubelet.sock` and re-registers for
exactly this reason; the simulator in this repository does not. The step order was left
alone rather than rearranged to avoid the collision, because reordering would remove
the observation, not the fault.

**Steps 3 and 5 are not independent.** The GPU ceiling of 1 that step 3 leaves standing
is the ceiling the step 5 replica runs under, so the serving deployment is demonstrably
inside an enforced quota. The cost is that a serving pod left behind by an earlier run
holds that one GPU — including in `CrashLoopBackOff` — and blocks the next run's
ReplicaSet entirely. The script therefore deletes the tenant namespace and both
policies before step 3 rather than reusing them.

**What this does not show.** No inference, no real GPU, no multi-tenant scheduling
pressure, and no failure injection beyond stopping one kubelet. The serving stub
answers `/health` and nothing else, so `Ready` here means the control plane's
definition of ready was met — not that a model was served.
