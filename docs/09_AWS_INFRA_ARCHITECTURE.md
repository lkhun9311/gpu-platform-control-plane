# AWS Infrastructure Architecture (M5-a / M5-b)

> **Status (2026-08-07): code written and offline-validated; never applied to AWS.** Design of record: `.reviews/milestone-m5-aws/aws-infra-integration-design.md` (v3.2, Claude/codex 20-finding reconcile applied). Terraform (`infra/aws/`), the GitHub Actions workflows (`.github/workflows/`), and the gateway Dockerfile all exist in the repository and pass offline validation (`make infra-validate`: `terraform validate`/plan, `kustomize build`, `actionlint`). Nothing in this doc has been `terraform apply`'d — zero AWS resources have ever been provisioned.

The operator is cloud-agnostic; its only AWS dependency is hosting. Scope split, stated precisely: the AWS/GitOps **hosting layer is optional** around the operator, but the **M5-b real-GPU benchmark is required** for M5's definition of done (doc 04) — the hosting exists so that run can happen credibly. Everything is built ephemeral-first: teardown is a control, not an intention.

## One-page view

```
GitHub repo (public — Argo CD reads it anonymously; source of truth)
  ├── ci.yml      ──(OIDC: image-push role)──>  ECR  <──(pull by digest)── EKS nodes
  ├── infra.yml   ──(OIDC: plan role on PR / apply role on merge, manual gate)──> Terraform
  ├── gpu.yml     ──(workflow_dispatch: apply role, gpu_desired=0|1)──> GPU node group switch   [NOT WRITTEN]
  └── destroy.yml ──(nightly cron + workflow_dispatch: apply role)──>
        delete Argo apps -> destroy argo-bootstrap state -> residue check -> destroy cluster state

Terraform (3 separate states; bootstrap starts on LOCAL state, then migrates into its own bucket)
  ├── bootstrap:      S3 state bucket + DynamoDB lock + GitHub OIDC provider + ECR
  ├── cluster:        VPC + EKS (pinned recent version) + managed add-ons + node groups + IAM + access entries
  └── argo-bootstrap: initial Argo CD install only (run once, never on routine applies)

VPC (demo-only threat model)
  ├── public subnet AZ-a (map_public_ip_on_launch=true, IGW route):
  │     CPU node group (all nodes pinned here)
  │     └── [M5-b window] GPU node group: g5.xlarge On-Demand, desired=0,
  │         taint nvidia.com/gpu=present:NoSchedule
  └── public subnet AZ-b: no nodes — exists because EKS CreateCluster requires >=2 AZs

EKS (public endpoint; auth = EKS access entries: dev admin + CI apply role)
  ├── managed add-ons (Terraform-owned, pinned): VPC CNI, CoreDNS, kube-proxy
  ├── operator + gateway (Kustomize config/, deployed by Argo CD, image by digest)
  ├── Argo CD app-of-apps: crds -> operator/gateway -> [profiles: observability, device-plugin, samples]
  ├── slim Prometheus/Grafana (off until operator custom metrics exist; access = kubectl port-forward only)
  └── GPU simulator DaemonSet (off while the real GPU node group is up)

Guardrails
  ├── TTL/owner tags on everything
  ├── budget alarm $10/day -> escalation; hard review at $30 cumulative
  └── destroy failure = retry once -> residue inventory (EC2/ELB/EBS/ECR/CloudWatch/TF state) -> break-glass manual runbook
```

## Terraform state layout

| State            | Contains                                                    | Why separate                                                                                                                                                                                   |
|------------------|-------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `bootstrap`      | S3 state bucket, DynamoDB lock, GitHub OIDC provider, ECR   | Must exist before anything else; almost never changes. **Chicken-and-egg is explicit:** it begins on local state and runs `terraform init -migrate-state` once into the bucket it just created |
| `cluster`        | VPC, EKS, managed add-ons, node groups, IAM, access entries | The blast radius of routine work — plan/apply cycles touch only this                                                                                                                           |
| `argo-bootstrap` | Initial Argo CD Helm install only                           | Terraform installs Argo CD once, then Argo CD owns the cluster; keeping it in `cluster` state would make every plan fight Argo CD's drift                                                      |

S3 state controls (v3): versioning, SSE-KMS with a scoped key policy, public-access block, bucket policy denying non-TLS and non-KMS writes, least-privileged state roles; DynamoDB lock encrypted + PITR + deletion protection.

## Network

| Decision              | Value                                                                                                                 | Why                                                                                                                                  |
|-----------------------|-----------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------|
| Subnets               | Public subnets in **two AZs**                                                                                         | EKS `CreateCluster` rejects fewer than 2 AZs — a single-AZ VPC fails at first apply                                                  |
| Node reachability     | `map_public_ip_on_launch=true`, IGW route, **public EKS endpoint** — nodes reach the EKS API/ECR/S3 over the internet | Without auto-assigned public IPs, public-subnet nodes cannot bootstrap at all (no NAT exists to fall back on)                        |
| Node placement        | All node groups pinned to **one AZ**                                                                                  | Avoids **workload** cross-AZ traffic between nodes; EKS control-plane ENI traffic across AZs may remain and is expected to be minor  |
| NAT                   | None — public subnets only                                                                                            | One NAT gateway is ~$1.08/day before data processing (×2 for 2-AZ HA) — pointless for a demo cluster holding no private data         |
| Compensating controls | Tight security groups, IMDSv2 (below), no public SSH, minimal node IAM                                                | Public subnets change the threat model; these controls are the explicit price, and this is labeled **demo-only, not production EKS** |
| Region                | `us-east-1`                                                                                                           | Cost basis for the M5-b budget (doc 04); recorded in every run report                                                                |

## Identity and access

| Principal            | Mechanism                                                      | Constraints                                                                                                                                                                                                                                                                                                                    |
|----------------------|----------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| CI (image push)      | GitHub OIDC → image-push role                                  | Trust pins `aud=sts.amazonaws.com` + `sub` (repo/ref/environment)                                                                                                                                                                                                                                                              |
| CI (terraform plan)  | GitHub OIDC → plan role (PR context)                           | Read-only; forked-PR contexts denied                                                                                                                                                                                                                                                                                           |
| CI (terraform apply) | GitHub OIDC → apply role (merge + manual-approval environment) | Separate role and trust from plan. AWS IAM trust can only match `aud`/`sub` — `job_workflow_ref` is **not** usable as a condition key; if workflow pinning is needed, encode it via GitHub's customized `sub` template. Immutable repo/owner-ID `sub` claims require **opt-in** for repos created before 2026-07-15 (this one) |
| Operator             | **No IRSA**                                                    | The manager calls only the Kubernetes API — an AWS role would be attack surface with no function                                                                                                                                                                                                                               |
| Node instances       | IMDSv2: `httpTokens=required` + `httpPutResponseHopLimit=1`    | An **instance** option, not a pod control: it blocks IMDS from pod-network containers (extra hop), but hostNetwork pods still reach it — that exception is documented, not hidden. Node bootstrap/ECR pull must be tested at hop-limit 1                                                                                       |
| Cluster access       | **EKS access entries**: dev admin entry + CI apply-role entry  | The apply role needs kubectl to run pre-destroy (delete Argo apps) — without its access entry, `destroy.yml` cannot do ordered teardown                                                                                                                                                                                        |

## Cluster add-ons (ownership explicit, same rule as CRDs)

| Add-on                           | Owner                                                | Note                                                                                                                                                    |
|----------------------------------|------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------|
| VPC CNI, CoreDNS, kube-proxy     | Terraform (**EKS managed add-ons**, versions pinned) | Cluster-lifecycle infrastructure — never Argo's                                                                                                         |
| EBS CSI                          | Not installed                                        | No PVCs by default (slim observability runs without persistence); installing it would create the exact teardown residue the guardrails exist to prevent |
| NVIDIA device plugin / simulator | Argo CD `device-plugin` profile                      | Workload-facing, mutually exclusive modes — see GPU section                                                                                             |

## CI/CD pipelines

| Workflow      | Trigger                            | Steps                                                                                                                                                                                   |                                                                                                                           |
|---------------|------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------|
| `ci.yml`      | push / PR                          | `go test` (envtest) → build **operator** image → push to ECR. The gateway now has a Dockerfile (`Dockerfile.gateway`) and manifests (`config/gateway/`), but `ci.yml` does not yet build or push a gateway image — that CI wiring has not been added.                                                      |                                                                                                                           |
| `infra.yml`   | PR (plan) / merge (apply)          | `terraform plan` with plan role on PR; `apply` behind a manual-approval environment with apply role                                                                                     |                                                                                                                           |
| `gpu.yml`     | `workflow_dispatch` only           | Gated apply of `gpu_desired=0\                                                                                                                                                          | 1` — the **only** actor that scales the GPU node group (no autoscaler by design: one auditable switch, ephemeral windows) |
| `destroy.yml` | nightly cron + `workflow_dispatch` | Delete Argo apps → destroy `argo-bootstrap` state → residue check → destroy `cluster` state; on failure: retry once → residue inventory → break-glass runbook + budget-alarm escalation |                                                                                                                           |

Deployment is **by digest**: CI pushes the image, then opens a PR bumping the digest in `config/`; Argo CD deploys what Git says. The ECR lifecycle policy expires only untagged/PR images — never a digest referenced from the default branch (lifecycle vs Git-pin conflict resolved by construction).

## GitOps topology (Argo CD)

| Application     | Source                        | Ownership rules                                                                                                                                                                             |
|-----------------|-------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `crds`          | `config/crd` (Kustomize)      | `ServerSideApply=true`; operator CRDs have exactly one owner                                                                                                                                |
| `operator`      | `config/` (Kustomize)         | Manager + RBAC; image digest from Git                                                                                                                                                       |
| `gateway`       | `config/gateway/` (Kustomize) | M4-b deliverable; same digest-bump flow                                                                                                                                                     |
| `observability` | slim Prometheus/Grafana chart | **Disabled until operator custom metrics exist**; chart CRDs `Prune=false` + `Replace=false`, Helm `skipCrds` pinned; access = `kubectl port-forward` only (public LoadBalancer prohibited) |
| `device-plugin` | NVIDIA plugin or simulator    | Separate profile; simulator and real plugin are mutually exclusive (manual profile toggle, flipped in the same PR as `gpu.yml` scale-up)                                                    |
| `samples`       | `config/samples`              | Manual sync only, never auto — samples are demo actions, not desired state                                                                                                                  |

The repo is public, so Argo CD reads it anonymously — no deploy credential to create, rotate, or leak. Argo CD does not manage its own chart (installed by `argo-bootstrap`, then left alone). Root app-of-apps orders: crds → operator/gateway → profiles.

## GPU capacity: simulated vs real

| Mode             | Mechanism                                                               | Constraints                                                                                                                                                                                                                                                          |
|------------------|-------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Simulated (kind) | `kubectl patch node .../status/capacity`                                | Local only — holds because no device plugin reconciles capacity there                                                                                                                                                                                                |
| Simulated (EKS)  | Device-plugin-style simulator DaemonSet                                 | Registers on the kubelet socket (hostPath `/var/lib/kubelet/device-plugins`), fake `Allocate` — it makes `nvidia.com/gpu` **schedulable**, nothing more: CPU-only test pods; any CUDA/vLLM pod fails at runtime, and quota/scheduling evidence is scoped accordingly |
| Real (EKS, M5-b) | GPU node group scaled 0→1 via `gpu.yml`, On-Demand `g5.xlarge`, tainted | Exists only during benchmark windows; simulator profile disabled while up; Spot is dev-test only, non-authoritative                                                                                                                                                  |

## Cost model and teardown enforcement

| Control           | Value                                                                                                                                                                                                            |
|-------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| EKS version       | Pinned recent at provisioning. Ephemeral clusters are **recreated, not upgraded** — which is also how the $0.10/hr standard-support rate stays true (extended support is $0.60/hr; this design never reaches it) |
| Idle cost         | CPU-only cluster ≈ $4–6/day (EKS control plane $0.10/hr + small nodes)                                                                                                                                           |
| GPU cost          | `g5.xlarge` ≈ $1.0/hr On-Demand (us-east-1), existing only during M5-b/M5-c windows                                                                                                                              |
| Budget alarm      | $10/day with escalation; hard review at $30 cumulative                                                                                                                                                           |
| Scheduled destroy | `destroy.yml` nightly cron; failure path is operational, not just an alert: retry once → residue inventory (EC2, ELB, EBS, ECR, CloudWatch, orphaned TF state) → break-glass manual runbook                      |
| Residue controls  | TTL/owner tags, PVC/PV + LoadBalancer audit, ECR lifecycle (untagged/PR images only), CloudWatch log retention, snapshot cleanup                                                                                 |

## Execution boundary (what exists today)

| Layer                         | Status                                                                                             |
|-------------------------------|----------------------------------------------------------------------------------------------------|
| Terraform code (`infra/aws/`) | **Written** (`bootstrap`, `cluster`, `argo-bootstrap` states) and offline-validated — never `terraform apply`'d |
| GitHub workflows              | **Written** (`ci.yml`, `infra.yml`, `destroy.yml`, `lint.yml`, `test.yml`, `test-e2e.yml`) — never run against real AWS credentials or infrastructure. `gpu.yml`, the GPU node-group switch this document describes, is **designed only and does not exist** |
| Gateway image                 | `Dockerfile.gateway` and `config/gateway/` manifests **exist**; `ci.yml` still builds/pushes only the operator image — the gateway image has never been built by CI or deployed |
| Operator custom metrics       | **Implemented** (`internal/controller/metrics.go` — taints, degraded transitions, quota drift)     |
| Everything in this doc        | Code written per this design (v3.2) and offline-validated; zero AWS resources have ever been provisioned |

## Build order (M5-a → M5-b)

```
M5-a  0. bootstrap state (local -> migrate): S3/DynamoDB + GitHub OIDC + ECR   <- start here
      1. cluster state: VPC (2-AZ subnets) + EKS + managed add-ons + CPU node group + access entries
      2. ci.yml builds + pushes the operator image to ECR (gateway joins after M4-b)
      3. operator via Kustomize (plain apply first, then Argo CD)
      4. argo-bootstrap state + app-of-apps (crds/operator; profiles off)
      5. operator custom metrics (CODE work) -> slim observability profile
M5-b  6. [if GPU scheduling demo] simulator DaemonSet profile
      7. gpu.yml scale-up -> real GPU node group -> flagship runs               <- always last
```

Rule: observability and the NVIDIA plugin must not precede a working operator path; GPU cost must not start before everything else is proven.

## Non-goals

- Multi-AZ high availability, private subnets/NAT, multi-region — this is an ephemeral demo, and pretending otherwise would be dishonest hardening theater.
- Cluster upgrades (recreate instead) and production-grade EKS security posture beyond the listed compensating controls.
- Autoscaling the GPU node group (Karpenter/Cluster Autoscaler) — one auditable `workflow_dispatch` switch is the point.
- Spot instances for authoritative benchmark runs (interruption invalidates latency data).
- Terraform-managed in-cluster resources beyond the initial Argo CD install (ownership boundary).
