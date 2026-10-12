# Design: serve one request on EKS, through the GitOps path, to a controller-rendered engine

Written 2026-10-12. Status: **draft for the owner's review**; nothing here is approved, built or bought.
Revision 2, after two independent pre-spend attacks (codex `gpt-6-astra`, and a Claude Opus subagent) on revision 1.
Their findings, and what each changed, are at the end; every one cited below was re-read in the tree before it was accepted.

## The question

`docs/11_WHAT_THIS_MEASURED.md` refuses "I operated a GPU platform": on EKS the GitOps path has reached authentication (`403 no_policy`, 2026-09-25) and no further.
GPU nodes have run on EKS before — the M5-b sessions scaled `gpu_single` and started vLLM on it (`infra/aws/cluster/eks.tf`, the DiskPressure note in `gpu_single`) — but those engines were applied by scripts, not by the controller, and no request reached them through the gateway as a tenant.
Since 2026-10-11 the controller renders the measured vLLM engine with HoldCap, checked on one A10G on kind with the node labelled by hand and no gateway (`hack/holdcap-conformance/runs/20261011T030610Z/README.md`).

**Does the platform, deployed by Argo CD from `main` onto a fresh EKS cluster, place the controller-rendered HoldCap engine on a g5 node, report it in force, and answer an authenticated tenant's request routed through the gateway under that admission?**

## What a pass would license, and what it would not

One sentence: the GitOps path deploys the serving chain on EKS, and one tenant's streaming request was routed by the gateway under HoldCap admission to a controller-rendered vLLM engine on an A10G and answered.
It does not license that the gateway held anything: a single uncontended request enters at once (`internal/gateway/serialprefill.go:76`).
It does not license latency, protection, capacity, quota metering of the serving Pod, multi-tenant fairness or availability.
Finding 9 stays the only protection claim.

## P0, before any of this: a platform defect the attack found

A `GPUQuotaPolicy` always labels its target namespace `platform.lkhun9311.github.io/gpu-quota-enforced=true` (`internal/controller/gpuquotapolicy_controller.go:176`).
The Pod webhook (`failurePolicy: Fail`) selects that label and denies a GPU Pod that has no Kueue queue label unless the Job controller created it (`internal/webhook/v1/gpupod_webhook.go:194`, `:204`).
The serving controller adds the queue label only when the namespace's policy has `trainingQuota: true` (`internal/controller/inferencedeployment_controller.go:180`, `:219`).
The gateway routes only to backends in a policy's `targetNamespace` (`internal/gateway/router.go:112`).
So a GPU serving Pod in any namespace the gateway can route to is refused unless the tenant's policy is a training policy — and on EKS no Kueue controller runs to meter it even then (`config/argocd/kueue-crds.yaml`).
No earlier run reached this: the conformance manager ran without webhooks (`hack/holdcap-conformance/instance.sh`), and the gateway's kind backends request no GPU.

This is a defect in the product, not in the session, and it got its own change: PR #338 admits a GPU Pod, whoever creates it, where every policy over the namespace is in ResourceQuota mode and each one's quota is owned, unscoped and already carries the GPU key in `status.hard`.
A codex adversarial review shaped those conditions, and the same review found the `quota-exempt` annotation could be laundered through a workload controller, which #338 also removes.
This session depends on #338 reaching `main`.

## What exists, and what is missing

Read from `origin/dev` at `fa4e6a2`.

| piece | today | missing |
|---|---|---|
| GPU node | `gpu_single`: g5.xlarge, Spot, `0/1/0`, label `platform.lkhun9311.github.io/gpu=true`, taint `nvidia.com/gpu=present:NoSchedule`, NVIDIA AL2023 AMI, 100 GiB root (`infra/aws/cluster/eks.tf`); matches the controller's affinity (`internal/controller/inference_engine.go:57`, `:144`) | — |
| GPU scale-up | `hack/m5b-gpu-session.sh` arms `ttl_arm`, refuses on a collision with the nightly destroy, scales, and waits for the node to arrive as a separate step (`:283-309`) | not reachable from `hack/eks-gitops-session.sh` |
| device plugin | `config/nvidia-device-plugin/` (digest-pinned, `nodeSelector` gpu=true) | no Argo Application; the `device-plugin` Application deploys the simulator |
| tenant | `seed-key` creates `gateway-api-keys` for `tenant-a` and leaves an existing Secret alone (`hack/eks-gitops-runbook.sh:240-255`) | a key for the serving tenant added to that Secret, and a request that uses that key, not the first one (`verify` uses the first, `:320`) |
| backend | the HoldCap sample | a namespace and policy the gateway routes to; the sample's own namespace is targeted by no policy |
| revision | Argo follows mutable `main`; the runbook records only the root's revision, before convergence (`:167`) | each Application's synced revision and the running image digests |

## Design

### 1. Two new Argo Applications, both from `main`, listed in `config/argocd/kustomization.yaml`

- **`nvidia-device-plugin`**, path `config/nvidia-device-plugin`, automated. It schedules nothing until a node labelled gpu=true joins. The simulator Application is never synced on EKS.
- **`serving`**, path `config/serving` (new), manual, synced by a `kubectl patch` of its `operation` (no argocd CLI). It holds namespace `serve-a`, a `GPUQuotaPolicy` for tenant `serve-a` targeting it (one GPU, no training quota, which is what P0 must make admissible), and the HoldCap `InferenceDeployment`.

Both reach `main` by a promotion before the session; the automated plugin Application then exists on every cluster that tracks `main`, where it schedules nothing without a GPU node.

### 2. The session

Extending `hack/eks-gitops-session.sh`, with three changes to its existing behaviour:

- **Fail fast before spending.** The GPU steps run only if `apply`, `seed-key` and `verify` all passed; today a failed step is counted and the loop continues (`hack/eks-gitops-session.sh:173`).
- **Every new subcommand reports through the runbook's `failures` counter**, because the runbook runs its command with `|| true` and judges only that counter (`hack/eks-gitops-runbook.sh:411`); each one is shown to fail once by breaking its input in the rehearsal.
- **Every wait is bounded**, and the bounds sum to less than the remaining deadline.

New subcommands, in order:

1. **`gpu-up`**: reuse `hack/m5b-gpu-session.sh`'s sequence — refuse on a collision with `.github/workflows/destroy.yml` (18:00 UTC), `ttl_arm` and verify, scale `gpu_single` to 1, then wait (bounded) for a node to register. The schedule's name is written to the session's directory, so a later process can disarm it.
2. **`gpu-ready`**: wait (bounded) for the plugin Pod on that node to be Ready and the node to advertise `nvidia.com/gpu: 1`.
3. **`serve-sync`**: add a key for `serve-a` to the existing Secret, save it, sync `serving`.
4. **`serve-ready`**: wait (bounded, 25 minutes, against a 900 s startup probe and the 9 min 31 s the conformance engine took) for `status.admission.mode=HoldCap` at the current generation. Record the node, the engine's argument line, and each Application's synced revision with the running operator and gateway image digests.
5. **`serve-request`**: one streaming request with the saved `serve-a` key, model `Qwen/Qwen2.5-3B-Instruct`, read by the same rules as `internal/bench/httpsender.go`: well-formed frames, non-empty content, no in-band error, a final `data: [DONE]`.
6. **`serve-recover`**: delete the engine Pod; record when status leaves HoldCap and returns, then send one request and require it to pass as in step 5.
7. **`gpu-down`**: scale to 0, wait (bounded) for the instance to terminate, `ttl_disarm` by the recorded name, and read the node group's desired size, all before the existing teardown.

The laptop watchdog also disarms the schedule when it fires.

### 3. Pass bars, fixed before any run

| bar | passes when |
|---|---|
| S1 | the plugin Pod is Ready on the GPU node and the node advertises `nvidia.com/gpu: 1` |
| S2 | the engine Pod runs on a node of the `gpu_single` node group (its `eks.amazonaws.com/nodegroup` label), instance type `g5.xlarge` |
| S3 | `status.admission.mode` is `HoldCap` for the current generation, and the engine's arguments match `pp_expected_args 384` as the conformance session checked them |
| S4 | the request in step 5 passes; its response carries `X-Engine-Priority` equal to the tenant tier's priority, which the gateway sets only when the backend is under HoldCap or priority binding is on, and priority binding is off in `config/gateway` (`internal/gateway/server.go:561`, `cmd/gateway/main.go:135`) |
| S5 | after the Pod is deleted, status leaves HoldCap before the new Pod is ready and returns for the same generation, and the request after it passes as in S4 |
| S6 | the node group's desired size is 0 and its instance is terminated; the schedule is gone; and after destroy the seven existing residue checks and the cluster's CloudWatch log group are empty |

S1–S4 are the claim; S5 is lifecycle evidence, timing only, since a deleted Pod is replaced from the same capped template; S6 is the cost guard.
Records name the gauge's label value as the code spells it, `hold-cap` (`internal/gateway/holdcap.go:19`).
A failure is reported as a failure; no bar is reinterpreted afterwards.

### 4. Rehearsal on kind, free, after the promotion

Argo follows `main`, so the rehearsal can only run once both Applications are there; a failed rehearsal costs a further promotion.
It follows the 2026-09-25 rehearsal, including loading the ECR-pinned images into kind (`docs/superpowers/specs/2026-09-25-gitops-rehearsal-on-clean-kind.md`), with `gpu-up`/`gpu-ready`/`gpu-down` stubbed.
No kind node is labelled `platform.lkhun9311.github.io/gpu=true`: the real device plugin, now automated, would schedule there and crash-loop with no card, and the simulator would advertise a device vLLM cannot use.
So the engine Pod's affinity matches no node, and the rehearsal asserts exactly what that leaves: the Pod is **created** (which before #338 it was not — FailedCreate from the webhook), Pending for node affinity, charged against `serve-a`'s ResourceQuota, status `Off`, and the gateway's answer to `serve-a`'s key while the backend has no endpoint.
It cannot reach S1–S5, and does not claim to.
The session installs no tools, so both the rehearsal and the session record the laptop's `kubectl`, `helm`, `terraform` and `aws` versions (`tool-versions.txt`), and the rehearsal counts only if it ran on the versions the session then runs on; nothing pins them, so the comparison is the operator's.

## Cost and risk

Estimates, not measurements:

- **Cluster:** about $0.26/h before data (control plane, one t3.large, one NAT, one EIP), measured on 2026-09-25 (`hack/eks-gitops-session.sh:19`). Only a laptop process enforces its deadline; every budget alarm has already fired this month (`:25`).
- **GPU:** g5.xlarge Spot. The comment beside the node group says $0.357–0.424/h (`infra/aws/cluster/eks.tf`); a price query on 2026-09-10 read $0.574–0.596/h (`docs/superpowers/specs/2026-09-10-does-splitting-the-card-buy-protection.md`). The session reads the price at purchase and records it.
- **NAT data, the largest line:** the image is 9.11 GiB compressed and the weights 6.18 GiB (`infra/aws/cluster/eks.tf`); with the second download S5 causes, about 21.5 GiB at $0.059/GB (`infra/aws/cluster/vpc.tf`), roughly $1.4, plus cross-zone charges if Spot lands outside the NAT's zone. NAT data was the largest line of the first three paid sessions (`infra/aws/bootstrap/ecr.tf`).
- **Docker Hub** serves the image anonymously; nothing in the tree establishes its allowance, so a throttled pull is a risk that ends the session at `serve-ready`.
- **Spot** can refuse; the session then ends at `gpu-up` and that is the record.

## Out of scope

Latency or protection on EKS; quota metering of the serving Pod; a second tenant; autoscaling; the ECR mirror; multi-replica gateways; training on EKS.

## Approval needed, in order

1. P0's fix, as its own change.
2. This design.
3. A `dev` → `main` promotion carrying P0, the two Applications and `config/serving`.
4. The paid session, in `gpu-lab`, after the kind rehearsal passes.

## The attacks on revision 1, and what each changed

| finding | source | change |
|---|---|---|
| the webhook refuses the serving Pod in a policy namespace | Opus | P0 |
| the deadline is not a billing cutoff; the cluster's is laptop-enforced | both | stated under Cost; S6 widened |
| the GPU schedule is never disarmed and is process-local | both | its name is recorded; `gpu-down` and the watchdog disarm it |
| failed prerequisites still reach the GPU; `\|\| true` hides a subcommand's status | astra | fail-fast; the counter rule |
| scale-up accepted is not capacity; waits unbounded | astra | `gpu-up` waits for the node; every wait bounded |
| one request cannot show a hold; the gauge reads the same status as S3 | both | the claim narrowed to "routed under"; S4 requires `X-Engine-Priority` |
| `[DONE]` does not exclude an in-band engine error | astra | S4 reads the stream by `httpsender`'s rules |
| S5's "any refusal" passes on broken auth, and Pod deletion cannot produce an uncapped engine | both | S5 is timing plus a passing request |
| the root SHA does not identify the children | astra | every Application's revision and the image digests are recorded |
| the rehearsal would go green on a refusal that hides P0; it needs the ECR images loaded; no tool-version contract exists | both | rehearsal rewritten |
| the nightly destroy is a second clock | astra | `gpu-up` refuses on a collision |
| cost omits NAT data, the CPU worker, and a newer Spot price | both | Cost rewritten |
| S6 misses the log group and the schedule | both | S6 widened |
| `seed-key` leaves the Secret alone and `verify` uses its first key | Opus | `serve-sync` adds a key; requests use it |
| S1 passes with zero plugin Pods | Opus | S1 requires the Ready plugin and the advertised GPU |
| "nothing has run on an EKS GPU node" | astra | corrected in the question |
| "one pull is within its limit" has no source | both | stated as a risk |
