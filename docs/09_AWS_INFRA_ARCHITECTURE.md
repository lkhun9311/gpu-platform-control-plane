# AWS Infrastructure Architecture (M5-a / M5-b)

> **Status (2026-08-27): `bootstrap` is applied; `cluster` is planned and not applied.** The state bucket, its KMS key, the GitHub OIDC provider, the three CI roles, the ECR repository and the budget alarms exist in account `007635145730` (`ap-northeast-2`). The `cluster` state has been planned against that account — 89 resources — and never applied, so no VPC, EKS cluster, node or NAT gateway exists and nothing is currently billing beyond a few cents of S3 and KMS. `argo-bootstrap` has never been initialised.
>
> Design of record: an internal integration design (v3.2) reconciled from two independent AI reviews that raised 20 findings between them; that working document is not published. The network design in this document supersedes v3.2's public-subnet topology — see *What is deliberately absent*.

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
  ├── bootstrap:      S3 state bucket (locks on <key>.tflock) + GitHub OIDC provider + ECR
  ├── cluster:        VPC + EKS (pinned recent version) + managed add-ons + node groups + IAM + access entries
  └── argo-bootstrap: initial Argo CD install only (run once, never on routine applies)

VPC (3 AZ; nodes hold no public address)
  ├── public subnet x3 (ELB-tagged, NO instances):
  │     NAT gateway (ONE, in AZ-a) + internet gateway route
  └── private subnet x3 (no auto public IP, default route -> NAT):
        EKS control-plane ENIs
        CPU node group (pinned to AZ-a, the NAT's zone)
        [session] GPU node groups: desired=0, subnets derived from instance-type offerings,
                  taint nvidia.com/gpu=present:NoSchedule
        S3 gateway endpoint (free) -- ECR layers live in S3, so image pulls bypass the NAT

EKS (private endpoint always; public endpoint only for explicitly named CIDRs -- default none)
  auth = EKS access entries: dev admin + CI apply role
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
| `bootstrap`      | S3 state bucket, GitHub OIDC provider, ECR                  | Must exist before anything else; almost never changes. **Chicken-and-egg is explicit:** it begins on local state and runs `terraform init -migrate-state` once into the bucket it just created |
| `cluster`        | VPC, EKS, managed add-ons, node groups, IAM, access entries | The blast radius of routine work — plan/apply cycles touch only this                                                                                                                           |
| `argo-bootstrap` | Initial Argo CD Helm install only                           | Terraform installs Argo CD once, then Argo CD owns the cluster; keeping it in `cluster` state would make every plan fight Argo CD's drift                                                      |

S3 state controls (v3): versioning, SSE-KMS with a scoped key policy, public-access block, bucket policy denying non-TLS and non-KMS writes, least-privileged state roles. Locking is the backend's own `use_lockfile` (Terraform ≥ 1.10) rather than a DynamoDB table — see the note below.

## Network

| Decision              | Value                                                                                                      | Why                                                                                                                                                                                                              |
|-----------------------|------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Subnets               | **Three AZs, public + private in each**                                                                     | EKS `CreateCluster` rejects fewer than 2 AZs. The third exists because `g5` is offered in `2a/2c/2d` but **not** `2b`, so two zones can leave the A10G groups one home                                             |
| Node reachability     | Private subnets, **no public IP**, default route to NAT; **private EKS endpoint**                            | A node with a routable address makes its security group the only thing between the internet and a kubelet. The private endpoint is what lets addressless workers reach the API without leaving the VPC             |
| API endpoint exposure | `endpoint_private_access=true`; public half derived from `api_public_access_cidrs` (**default empty**)      | The module default is `0.0.0.0/0` and this repo never set the argument. Reaching the endpoint ≠ authenticating to it, but a world-reachable endpoint is one a leaked credential works from anywhere. `0.0.0.0/0` now fails validation |
| Node placement        | CPU group pinned to AZ-a (the NAT's zone); GPU groups derived from instance-type offerings (`placement.tf`) | Keeps CPU egress in-zone; GPU placement must follow capacity, not subnet index                                                                                                                                     |
| NAT                   | **One** gateway, not one per AZ                                                                              | Per-AZ NAT buys AZ-fault isolation, worth less than its hourly rate on a cluster whose failure mode is a re-run. Price: cross-AZ egress from two zones at $0.01/GB each way                                        |
| VPC endpoints         | **S3 gateway only.** No interface endpoints                                                                  | The gateway endpoint is free and removes image-layer traffic from the NAT. A fully private cluster needs ~9 interface endpoints, billed per hour per AZ — more than the single NAT they would replace              |
| Node shell access     | **SSM Session Manager**, no bastion                                                                          | No inbound port at all; the agent dials out and access is an IAM decision CloudTrail records. A bastion is a permanently billed instance whose job is to hold an open SSH port                                     |
| Region                | `ap-northeast-2`                                                                                            | Where the G/VT quota was granted (52 vCPU, 2026-08-26). State bucket, cluster and registry all live beside it                                                                                                       |

### What is deliberately absent, and why

The 3-tier reference architecture this project's author built as an AWS SA puts an ALB in the public subnet,
WAF and Shield in front of it, CloudFront over an S3 origin, and a bastion in the public subnet. Each of those
is the right answer to a question this workload does not ask.

| Service            | Verdict | Reason                                                                                                                                                                                                                                                                                                              |
|--------------------|---------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| ALB in front of the **EKS API** | **Cannot** | The API endpoint is AWS-managed and its TLS certificate is issued for `*.eks.amazonaws.com`. An ALB terminates TLS and presents its own, so `kubectl` fails certificate validation unless the kubeconfig is told to skip it. The private endpoint's ENI addresses are also not a documented, stable target set. Passthrough would need an NLB — and WAF does not attach to NLB |
| WAF                | **No**  | WAF inspects L7 HTTP for web-application attacks and attaches to CloudFront/ALB/API Gateway. There is no public HTTP application here. Against `kubectl` traffic its managed rule groups would produce false positives and block nothing real — the API's actual defence is SigV4 + RBAC + the CIDR allow-list |
| ALB in front of the **gateway** | **Correct, and still off** | This *is* the true analogue of the reference architecture's WAS tier, and the public subnets carry `kubernetes.io/role/elb` so one can land. It stays off because the flagship number is TTFT p99: a load balancer in the request path is a hop whose latency would be inside the measurement. If the gateway is ever exposed for a demo rather than a measurement, ALB + ACM + WAF is the shape |
| CloudFront         | **No**  | A CDN for static origins. The only S3 bucket here holds Terraform state, which must never be publicly readable — fronting it with CloudFront points the wrong way |
| Bastion host       | **No**  | Replaced, not supplemented, by SSM (above) |
| RDS / ElastiCache tier | **N/A** | There is no database. The stateful thing in this system is the KV cache, which is GPU memory on the node and cannot be moved to a data tier |
| Secrets Manager    | **Deferred** | The gateway's tenant API keys are created by a session script as a Kubernetes Secret. External Secrets + Secrets Manager is the correct production shape at ~$0.40/secret/month; deferred because the only secret today is a literal `premium-key` in a cluster that lives for hours, and adding a dependency to the measurement path before the measurement runs is the wrong order |
| KMS                | **Already in use** | Terraform state bucket key, and EKS envelope encryption for Kubernetes Secrets |

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
M5-a  0. bootstrap state (local -> migrate): S3 + GitHub OIDC + ECR            <- start here
      1. cluster state: VPC (3 AZ, public + private) + NAT + EKS + add-ons + CPU node group + access entries
      2. ci.yml builds + pushes the operator image to ECR (gateway joins after M4-b)
      3. operator via Kustomize (plain apply first, then Argo CD)
      4. argo-bootstrap state + app-of-apps (crds/operator; profiles off)
      5. operator custom metrics (CODE work) -> slim observability profile
M5-b  6. [if GPU scheduling demo] simulator DaemonSet profile
      7. gpu.yml scale-up -> real GPU node group -> flagship runs               <- always last
```

Rule: observability and the NVIDIA plugin must not precede a working operator path; GPU cost must not start before everything else is proven.

## Non-goals

- Multi-AZ **high availability** (one NAT, one CPU node), multi-region, and per-AZ redundancy — this cluster is ephemeral and its failure mode is a re-run.
- Private subnets and NAT were on this list until 2026-08-27, on the argument that they were hardening theater for a four-hour cluster. Pricing the NAT ended the argument: $0.059/hour against a session that already burns G-family instances by the hour. The list keeps only the items whose cost still exceeds what they buy here.
- Cluster upgrades (recreate instead) and production-grade EKS security posture beyond the listed compensating controls.
- Autoscaling the GPU node group (Karpenter/Cluster Autoscaler) — one auditable `workflow_dispatch` switch is the point.
- Spot instances for authoritative benchmark runs (interruption invalidates latency data).
- Terraform-managed in-cluster resources beyond the initial Argo CD install (ownership boundary).
