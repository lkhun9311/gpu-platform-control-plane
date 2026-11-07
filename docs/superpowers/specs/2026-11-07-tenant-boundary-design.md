# Tenant boundary: what a tenant may do, reach and consume

Written 2026-11-07. Status: **implemented on `feat/tenant-boundary`, proven on kind (run 1 PASS, 23 of 23; see "Proof"); not applied to any existing namespace or to EKS.**
The owner decided on 2026-11-07 that a GPU-as-a-service platform gives every tenant its own RBAC ("tenant마다 rbac 부여도 해야 gpuaas 플랫폼").
A read-only review of the Kubernetes basics (storage `gpu-platform-control-plane/engineering/2026-11-07-쿠버네티스-기본-요소-공백과-왜-Kueue인가.md`) found that multi-tenancy here had been defined by quota alone: no tenant RBAC, no NetworkPolicy beyond the operator's metrics, no Pod Security labels, no CPU or memory quota, and every generated ClusterQueue accepting every namespace.
It read that as an omission from the multi-tenancy contract rather than a documented exclusion; this page closes it.

## What changes and what does not

The quota model does not change: `GPUQuotaPolicy` still owns the GPU ledger (a ResourceQuota, or a Kueue ClusterQueue in training mode).
What is added is everything around it, as one bundle per tenant rendered from `config/tenant/` and committed under `config/tenants/` (a directory per tenant), plus two code changes.
It is a GitOps bundle, not a Tenant operator: the review judged a new controller not worth adding while tenants are few and onboarding is a reviewed change.

## What a tenant gets

A tenant is a name `<tenant>`, one namespace `<namespace>` and one identity group `tenant:<tenant>` (the group is what the cluster's authenticator maps the tenant's users to; on EKS, an access entry's Kubernetes group).

| object | what it says | why |
|---|---|---|
| `Namespace` | labels `platform.lkhun9311.github.io/tenant: <tenant>`; Pod Security `enforce: baseline`, `audit` and `warn: restricted`, versions pinned to `v1.31` | baseline refuses privileged, hostPath, host network and host PID Pods now; the platform's generated training and serving Pods do not yet meet `restricted`, so it is audited and warned rather than enforced |
| `Role` `tenant` + `RoleBinding` to group `tenant:<tenant>` | create, update, patch, delete, read `mltrainingjobs` and `inferencedeployments`; create, delete, read `persistentvolumeclaims` (a distributed job's state volume); read `pods`, `pods/log`, `jobs`, `services`, `events`, Kueue `workloads` and `localqueues` | the tenant submits work only through the platform's resources; it never writes Jobs, Pods, Workloads, LocalQueues, ResourceQuotas or NetworkPolicies, so it cannot bypass admission, remap its queue or open its own network |
| `NetworkPolicy` `default-deny` | selects every Pod; no ingress, no egress | everything below is an exception to it |
| `NetworkPolicy` `allow-dns` | egress to `kube-system` Pods `k8s-app=kube-dns`, UDP and TCP 53 | names resolve |
| `NetworkPolicy` `allow-same-namespace` | ingress from and egress to Pods in the same namespace, engines excluded on both ends | distributed ranks rendezvous and talk to each other; a tenant's own trainer still cannot call an engine around the gateway |
| `NetworkPolicy` `allow-gateway-to-engines` | ingress to Pods `app.kubernetes.io/name=inferencedeployment` from Pods `app.kubernetes.io/component=gateway` in namespaces labelled `platform.lkhun9311.github.io/role: platform` | the gateway is the only way in to an engine, so authentication, rate limits and priority binding cannot be skipped |
| `NetworkPolicy` `allow-monitoring` | ingress from namespaces labelled `platform.lkhun9311.github.io/role: monitoring` | metrics scraping |
| `NetworkPolicy` `allow-engine-egress` | egress from engine Pods to TCP 443 outside the private ranges | model downloads; in production this is a model mirror or an egress proxy, and the rule narrows to it |
| `LimitRange` | per container default request 100m CPU / 256Mi memory / 1Gi ephemeral storage, default limit 4Gi memory / 64Gi ephemeral storage, maximum 32 CPU / 128Gi memory / 200Gi ephemeral storage | the generated Pods carry no requests, and the quota refuses Pods without them; the ephemeral-storage limit stops one container's writable layer or emptyDir model cache from filling a node's disk and evicting other tenants there |
| `ResourceQuota` `tenant-baseline` | requests.cpu, requests.memory, limits.memory, requests and limits of ephemeral-storage, pods, persistentvolumeclaims, requests.storage, and object counts of mltrainingjobs, inferencedeployments, services, deployments, replicasets, jobs and Kueue workloads | GPU quota alone does not stop a tenant from exhausting a node's CPU, memory or disk or the API with objects; the generated kinds are counted because a tenant may delete its resource with `--cascade=orphan`, freeing the parent's count and keeping the children; it is a separate object from the GPUQuotaPolicy's, so switching training mode cannot remove it |

Volume mounts (NFS, EFS) are made by the kubelet in the node's network namespace and are not subject to NetworkPolicy, so no rule is needed for the state volume.
That also means the network rules do nothing to separate two tenants' files: storage separation is the claim policy below plus dynamic provisioning, never a shared filesystem root (see "Onboarding rules").
Tenant service accounts: the bundle sets `automountServiceAccountToken: false` on the namespace's `default` ServiceAccount; trainers and engines do not call the API.

The platform namespace carries `platform.lkhun9311.github.io/role: platform` in `config/manager/manager.yaml`, so the label the gateway rule trusts ships with the gateway's namespace rather than being an onboarding step.
The monitoring label is an onboarding step, because where Prometheus runs is the operator's choice and nothing in this repository deploys it.

## Code and admission changes

1. **ClusterQueue `namespaceSelector`** (`internal/controller/kueue_quota.go`): from the empty selector (every namespace) to `kubernetes.io/metadata.name In [<targetNamespace>]`.
   That label is set by the API server to the namespace's name and cannot be changed, so a LocalQueue in another namespace pointing at this ClusterQueue admits nothing, even if someone could create one.
   An existing ClusterQueue is corrected on its next reconcile by the controller's drift check.
2. **Reserved metadata** (`config/policy/tenant-reserved-metadata.yaml`, a ValidatingAdmissionPolicy): a request from a user in a `tenant:` group may not add, change or remove `platform.lkhun9311.github.io/fenced-nodes` on an MLTrainingJob, and may not remove the controller's finalizer `mltrainingjob.platform.lkhun9311.github.io/finalizer`, including while the job is being deleted.
   The restart barrier trusts the annotation as an operator's statement that a machine is off; a tenant writing it could start a new attempt next to a still-running rank.
   The finalizer holds a deleted job until its rank Pods are retired; removing it would leave those Pods held by their own finalizers with no parent to release them.
   It is a deny on tenant identities, not an allow-list of operators, so the platform's own identities (kind's `system:masters`, an EKS cluster-admin access entry, the session runners) keep working without being enumerated, and RBAC already limits who can write MLTrainingJobs at all to the tenant and platform administrators.
   The price is one onboarding rule: an operator identity never also carries a `tenant:` group.
3. **Claim binding** (`config/policy/tenant-claim-binding.yaml`): a tenant's PersistentVolumeClaim may not set `spec.volumeName` or `spec.selector`.
   Either binds any compatible PersistentVolume no `claimRef` reserves, so a tenant could take a volume staged for another tenant, or one backed by a hostPath or a shared filesystem root that Pod Security never sees, because the Pod names only the claim.
   What is left is dynamic provisioning, which gives each claim its own volume (on EFS, its own access point).

The premium tier (`platform.lkhun9311.github.io/tier` on a GPUQuotaPolicy) and namespace labels need no admission rule: GPUQuotaPolicy and Namespace are cluster-scoped and the tenant role grants neither.

## Onboarding rules

1. Render the tenant with `hack/tenant/render.sh <tenant> <namespace>` and commit `config/tenants/` (a directory per tenant); an Argo CD Application names that directory.
2. Map the tenant's people to the group `tenant:<tenant>` and nothing else; never put an operator, a runner or a break-glass identity in a `tenant:` group.
3. Label the namespace Prometheus runs in `platform.lkhun9311.github.io/role: monitoring`.
4. Offer a tenant storage only through a StorageClass that provisions per claim; never stage a PersistentVolume of a shared filesystem's root for a tenant, and reserve any static volume with a `claimRef`.
5. On EKS, turn on `network_policy_enabled` only once every namespace that must keep working has policies: strict mode denies a new Pod's traffic until a policy allows it.

## Lab and production

The bundle is identical in both profiles.
What differs is only whether NetworkPolicy is enforced: a CNI must implement it.
- kind: install Calico (pinned below) instead of kindnet for this proof.
- EKS: enable network policy in the VPC CNI add-on in strict mode — `network_policy_enabled` in `infra/aws/cluster`, defaulting to off, not applied by this change.
  Strict mode matters: the default (standard) mode allows all traffic to a new Pod until its policies are programmed, and a tenant creating Pods repeatedly would reopen that window each time.
  The two configuration keys follow the add-on's documentation and are pinned by a plan-time test, but have not been read back from `aws eks describe-addon-configuration` for the pinned version; that is the first step of any apply.
A NetworkPolicy object on a CNI that does not enforce it does nothing, and nothing errors; the proof below runs on an enforcing CNI for that reason.

The bundle is not yet applied to any existing namespace.
`config/training`, `config/serving` and `config/kueue` still create `train-a`, `serve-a`, `tenant-a` and `tenant-b` as bare namespaces, and the paid session runners create their own.
Enrolling them is a separate change, because it changes what those paths run under: the runners' direct vLLM manifests carry neither engine label the rules select, and one pilot renderer mounts a hostPath that baseline refuses.

## Proof (kind, free)

`hack/tenant-boundary/run.sh` builds a throwaway three-node cluster `tenantlab` (kind node `v1.37.0`, Calico `v3.33.0` at a pinned manifest hash) with the platform CRDs, the Kueue CRDs and `config/policy`.
The platform namespace is taken from the `config/default` render, so the label the gateway rule trusts is the shipped one.
Tenant A is `train-a` and tenant B is `serve-a`, both applied from `config/tenants/`; the stand-ins are busybox Pods pinned by digest, each serving its own name, spread over both workers.
Tenant requests are made by impersonating `user-train-a` in group `tenant:train-a`.
`hack/tenant-boundary/check.py` holds what each check must observe and scores `results.jsonl` into `verdict.json`.
A refusal counts only in the words of the layer that should refuse (RBAC, the named admission policy, Pod Security), and a blocked connection counts only as a timeout whose client and target each succeeded in another check.

Run 1 (`hack/tenant-boundary/2026-11-07-run1/`, commit `bfbf59e5`, clean tree): **PASS, 23 of 23.**

| # | check | expected | observed |
|---|---|---|---|
| 1 | A creates an MLTrainingJob in its namespace | allowed | exit 0 |
| 2 | A creates an MLTrainingJob in B's namespace | RBAC | refused by RBAC |
| 3–7 | A creates a Pod, a Job, a ResourceQuota, a LocalQueue, a NetworkPolicy in its namespace | RBAC | each refused by RBAC |
| 8 | A sets `fenced-nodes` on its job | `tenant-reserved-metadata` | refused by it |
| 9 | an administrator sets `fenced-nodes` | allowed | exit 0 |
| 10 | A removes the controller's finalizer | `tenant-reserved-metadata` | refused by it |
| 11 | A creates a claim naming `spec.volumeName` | `tenant-claim-binding` | refused by it |
| 12 | A writes a GPUQuotaPolicy's tier annotation | RBAC | refused by RBAC (update) |
| 13 | A relaxes its namespace's Pod Security label | RBAC | refused by RBAC (update) |
| 14 | an administrator creates a privileged Pod in A | Pod Security | refused, `baseline:v1.31` |
| 15 | rank to rank in A, across nodes | reached | `rank-1` answered |
| 16 | A resolves `kubernetes.default.svc.cluster.local` | resolved | `10.96.0.1` |
| 17–18 | the gateway reaches A's and B's engines | reached | both answered |
| 19–20 | monitoring reaches the gateway and a rank in A | reached | both answered |
| 21 | A reaches B's engine | timeout | timed out |
| 22 | A reaches the gateway's metrics port by Pod IP | timeout | timed out |
| 23 | A's trainer reaches A's own engine | timeout | timed out |

The envtest suite `internal/webhook/v1/tenant_boundary_e2e_test.go` asserts checks 1–13 again (not Pod Security) against an apiserver with the bundle and both policies read from disk, and `hack/test/check-tenant-boundary.sh` (in `make harness-check`) re-scores the archive and turns each of the 23 records into the opposite outcome once; every one fails at its own check.
It also feeds the scorer a refusal in the wrong words for each refusal layer, a refused connection in place of a timeout, a failed client and a failed target behind a timeout, an absent record, a duplicate and a dirty tree; each fails.
The archived `verdict.json` is from the scorer at the branch head, which after the run gained one fix: check 16 matched the address as a substring, and the resolver's own `10.96.0.10` contains `10.96.0.1`, so a mutation that removed the answer still passed.

Two findings of the runs themselves, both now in the runner:
- A ResourceQuota refuses every create it covers with "status unknown for quota" until the quota controller has computed its usage, and a custom resource's count arrives later than the built-in ones; the first run's first create was refused this way. A tenant onboarded moments ago sees the same refusal.
- `kubectl annotate`, `label` and `patch` read the object before writing it, so a tenant without read access is refused at the read; the proof PUTs the edited object so the refused verb is the write.

## Not covered

- An admission rule restricting which images or registries a tenant may use (separate item in the basics review).
- Per-tenant gateway credentials and their rotation.
- Offboarding: deleting the bundle removes the access; retained PVCs and finished work are the operator's to clean up.
- Kueue's runtime refusal of a foreign LocalQueue: the proof checks the selector the controller writes, not a running Kueue.
- The real gateway and generated engines: the kind proof uses stand-ins carrying their labels; the generated engine Pods' labels are read from `infdLabels`, not observed.
- EKS: nothing here ran on EKS, including the strict-mode keys.
- Node disk reserved for the platform (kubelet eviction thresholds) beyond the per-container limit.

## Review by gpt-6-astra (2026-11-07, read-only, against this page and the tree)

The prompt asked only what would let one tenant reach or affect another, escalate, or lock the platform out.

| # | finding | taken? | what changed |
|---|---|---|---|
| 1 | orphan deletion (`--cascade=orphan`) frees the parent's count and keeps its Service and Deployment | taken | the quota counts services, deployments, replicasets, jobs and Kueue workloads |
| 2 | EKS stays fail-open; standard mode allows a new Pod's traffic until policies arrive | taken | the switch sets strict mode; the page says no namespace is enrolled yet and nothing ran on EKS |
| 3 | ephemeral storage is unbounded, so one container can put a node into DiskPressure | taken | ephemeral-storage defaults, maximum and quota; node-level reservation is listed as not covered |
| 4 | a claim with `volumeName` or a selector binds an unreserved PV, including a hostPath one | taken | `tenant-claim-binding` refuses both for tenant identities |
| 5 | a shared EFS root is not separated by namespaces | taken as an onboarding rule | rule 4; the claim policy leaves only dynamic provisioning |
| 6 | the real platform namespace lacks the label the gateway rule trusts | taken | `config/manager/manager.yaml` carries it; the proof takes the namespace from the render |
| 7 | a tenant can remove the job finalizer during deletion and orphan the rank Pods | taken | `tenant-reserved-metadata` refuses removing it |
| 8 | enrolling the runners' namespaces would break their manifests | taken as a constraint | the bundle is not applied to them; enrolling is a separate change |
| 9 | an operator identity that also carries a `tenant:` group is refused fencing | taken as an onboarding rule | rule 2; a dedicated fencing capability was refused as more than the risk needs while operators are few |
| 10 | `allow-same-namespace` lets a tenant's trainer call its engine around the gateway | taken | engines are excluded from it on both ends; check 23 |

