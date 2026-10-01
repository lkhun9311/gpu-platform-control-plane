# Kubernetes-native GPUaaS Control Plane

> **Status (2026-08-07).** This document surveys the whole project; the areas it covers are at different
> stages, matched here to the README's evidence table — this banner does not upgrade or soften any of them.
> **Built:** `NodeHealth` (node readiness — but the CR is hand-created and no GPU fault signal reaches it:
> nothing Xid or ECC exists at all, and the DCGM code that does exist is a utilisation reader the queuelab
> uses, not a health input), `GPUQuotaPolicy` (quota), `InferenceDeployment` (serving), `MLTrainingJob` +
> Kueue (training admission). **Built, unit-tested, deployed on kind, and on EKS only as far as authentication:** the gateway — the 2026-09-25 GitOps cycle reached it on a real cluster and the request ended at `403 no_policy`, so routing and serving through it on EKS remain unproven. **Built and MEASURED
> on a paid GPU:** the M5-b admission guard and benchmark harness — four repetitions on 2026-09-03 and an
> engine-level scheduler microtest on 2026-09-04. The guard failed: 83.7x against a pre-registered 1.25x
> premium-tail target, and the harness declared the run invalid rather than reporting a protection claim.
> **Built, and run for real on kind:** failure & recovery (M7) — a `WorkloadRun` CRD, a controller and a
> driver, with a recorded run in which deleting a serving Pod produced a recovery trail nobody wrote by
> hand. **Type and CRD built, never run:** `GpuSharingBenchmark` / performance isolation — the API type, the
> generated CRD and 33 envtest specs exist. The spec is immutable once created — a protocol change is a new
> registration — and the CRD also refuses a retry, a two-model shared instance, one tenant on both sides of
> the comparison, a closed-loop arrival mode, a qps that is not a positive plain decimal, sample sizes below
> the registered floors, and a status that claims `Completed` without naming a report. Each of those rules was
> deleted in turn to check which specs it holds. There is no status writer and no measured result; its sizing
> arithmetic and run script already existed. **Partly built, and projected for the first time on 2026-09-30:** the SQLite ledger and the
> `platformctl` CLI — storage, projector and reader for 2 of 6 tables, with no run yet projected outside a
> test. **Applied and destroyed in one cycle, not
> applied now:** the `cluster` half of the AWS hosting path — its first apply, on 2026-08-31, failed on all
> four node groups against an SCP deny; on 2026-09-18 a full apply of 96 resources succeeded and a
> hand-dispatched teardown removed all 96, verified by resource ID
> (`hack/eks-cluster-cycle-20260918.md`). That cluster carried no GPU node, no load balancer and no Argo CD,
> so the teardown's hard cases are still untested. **Withdrawn once,
> then re-measured, then observed on hardware:** the queuelab reclaim result. Twelve runs on a kind cluster
> carried the banner `device: NOT OBSERVED`; a $3.90 session then reproduced it on four A10Gs, eight runs
> accepted by `-require-device`, and the banner is gone. Owner wait separates by 28.8 s there against 29.0 s
> on kind, so the result survived its own instrument. A second study then showed reservation and use coming
> apart by a factor of four while every reservation-based figure stayed the same, and found that a duty cycle
> synchronised with the exporter's collection interval is reported by whichever single phase the sampler
> happens to sit on -- zero in the run that was measured, but as plausibly a full 98. Every GPU in the kind
> clusters is still simulated by a fake device plugin, and those runs are still reservation.
>
> **Built, and the reason the paid numbers are worth reading:** a characterization harness that pins what
> each GPU-renting script does before it may be run against a card. Four runners, 45 recorded cases, each
> driving the real script with recording stubs and diffing the AWS calls, the exit status, what the operator
> was told and what the run directory held. It fixes the host side only, which is stated where it is used
> rather than left to be assumed.

A Kubernetes-native control plane for multi-tenant GPU inference workloads — GPU quota, node readiness, LLM serving, performance isolation, noisy-neighbor benchmarking, and observability-driven operations.

This project is **not** a vLLM demo. It treats GPU inference workloads as declarative Kubernetes platform resources and builds the control plane around them.

## What this is / is not

|                      |                                                                                              |
|----------------------|----------------------------------------------------------------------------------------------|
| **What this is**     | A Kubernetes-native GPUaaS control plane                                                     |
| **What this is not** | An LLM demo, a data platform, a full MLOps stack, or a scene-retrieval/vector-index platform |
| **Killer feature**   | A GPU control-plane prototype and a contention **measurement** lab. Performance isolation is what the lab measures, not what this platform delivers — and the one protection claim it tested failed, at 83.7x against a pre-registered 1.25x bar. What the lab *did* produce, under the frozen execution contract: the victim's TTFT p99 is **23.0x** its isolated value when one competing tenant joins the engine (five repetitions, 2026-10-01, 23,274 of 23,275 premium requests completed, no interval published). **Splitting the card** was measured only by an earlier three-arm pilot at a different prompt length and timeout — 27.2x shared against 14.5x split, two repetitions — and the two loads must not be combined ([findings](11_WHAT_THIS_MEASURED.md)) |
| **The missing integration** | `InferenceDeployment` cannot describe the engine the benchmark measures. Its spec carries no args and no volumes, so the chain test registers a **zero-replica no-op image** purely to give the gateway a route to resolve, and vLLM is deployed beside it by a shell script. This is a gap in the declarative surface the project is named for, not an incidental limitation — stated here rather than left in a table row further down, because a reader deciding whether the control plane controls anything should meet it early |
| **Core demo**        | Separately tested components, not one chain. `InferenceDeploymentSpec` carries no args and no volumes, so it cannot describe the vLLM engine the benchmark measures — `hack/m5b-chain-live.sh` registers a zero-replica no-op image purely so the gateway can resolve a route, and vLLM is deployed beside it. The honest sequence is: quota admission (tested), gateway identity and limits (tested), contention measured by a separate harness, recovery recorded by `WorkloadRun` |
| **Evidence**         | CRDs, controllers and the gateway (code and unit tests) exist. So do a benchmark write-up (`hack/m5d-writeup.md`), a Grafana dashboard (`config/prometheus/operator_dashboard.json`) and three failure reports (`hack/chaos-fr*.md`). The **operations ledger** is partly built — storage, projector, reader and `cmd/platformctl` for 2 of its 6 tables, with nothing yet projected outside a test. ⚠️ Two earlier versions of this row were wrong in opposite directions. It once called all four "planned evidence types, not yet produced", which was false of the repository. It then said `evidence/` "holds five `.gitkeep` files and nothing else", which stopped being true when `evidence/README.md` was committed — that file is now the only tracked thing under `evidence/`, and it exists to say the tree is empty on purpose and to point at `docs/captures/`, `experiments/*/README.md` and `hack/*.log`, which is where the evidence actually lives |

## The main contribution

A multi-tenant GPUaaS control plane that:

1. admits GPU workloads through layered quota control,
2. mirrors node readiness and taints an unhealthy node — it does **not** validate a GPU or gate serving on GPU qualification, which needs a fault signal this project has no hardware for,
3. routes LLM traffic through a tenant-aware gateway,
4. measures noisy-neighbor effects under GPU sharing,
5. records failures, benchmarks, and lifecycle events as evidence.

## Core CRDs

| CRD                   | Role                                         | Status (2026-07)                                                                                                     |
|-----------------------|----------------------------------------------|----------------------------------------------------------------------------------------------------------------------|
| `InferenceDeployment` | declare a model-serving intent               | type + serving reconciler (Deployment/Service, phase ladder) — M4-a merged                                           |
| `GPUQuotaPolicy`      | per-tenant GPU quota / rate limit            | type + reconciler (ResourceQuota sync, drift recovery) — M3 merged; `rateLimit` feeds the M4-b gateway — **M4-b merged, gateway built, unit-tested, deployed on kind, and reached on EKS only to the point of authentication** (2026-09-25, `403 no_policy`) |
| `NodeHealth`          | GPU node intake and operational state        | type + reconciler (observe + taint, finalizer, drift recovery) — M2/M3 merged; **no GPU fault signal reaches it** — nothing Xid or ECC exists, and the DCGM code that does exist reads utilisation for the queuelab rather than health for this controller |
| `GpuSharingBenchmark` | declare a noisy-neighbor / sharing benchmark | type + CRD + 33 envtest specs, per spec `2026-07-04-gpusharingbenchmark-crd-design.md` and its 2026-09-30 amendment; the spec is immutable once created. `CompilePlan` (`internal/bench/plan.go`) compiles a spec into the harness invocation or refuses it with a reason per unsupported value — **called only from tests**, so the CR has never driven a run. The committed sample is one of the specs it refuses. No status writer, no measured result through this path (M5) |
| `WorkloadRun`         | record a workload execution                  | type + reconciler + driver — `internal/controller/workloadrun_controller.go` (320 lines). A Pod kill was recorded automatically as `Ready → Pending → Ready` with recovery at 20 s on kind (`hack/m7-evidence-trail.log`). It is not a general-purpose ledger |
| `MLTrainingJob`       | Kueue-admitted training job                  | type + full reconciler — translates to a `batch/v1` Job admitted through Kueue, two-tenant cohort borrowing/reclaim preemption, run end-to-end on kind (`hack/m6-kind-e2e.md`) — **M6 merged and built**. It is not the only milestone with a live run record: M7 (`hack/m7-evidence-trail.log`), the gateway chain and the three chaos scenarios have theirs |

Milestone numbering is unified across all docs and the README: M1 skeleton/CRDs · M2 NodeHealth reconciliation contract · M3 enforcement (taint + ResourceQuota) · M4 serving (M4-a InferenceDeployment, M4-b gateway) · M5-a AWS hosting (Terraform/CI/GitOps, operator on EKS) · M5-b real-GPU flagship (benchmark + admission guard) · M5-c depth (cost/fairness frontier + sharing-mode matrix) · M5-d technical write-up · M6 training admission (Kueue — promoted from stretch 2026-07-04) · M7 failure/evidence (`WorkloadRun`). Older drafts that used other numberings defer to this.

## Execution boundary (honest framing)

The control-plane logic (CRDs, controllers, admission, quota, gateway routing) runs and is tested locally against a kind cluster with **simulated GPU capacity**. Anything that requires real hardware — DCGM metrics, MPS / time-slicing, eBPF runqueue correlation, measured p99 under contention — is marked clearly and is executed only on a **real GPU node** (e.g. AWS a10g). Where a result has not been measured on real hardware, the docs say so rather than inventing numbers. Methodology and null results are reported honestly.

## Document map

| Doc                                     | Contents                                                                           |
|-----------------------------------------|------------------------------------------------------------------------------------|
| `01_REFERENCE_ARCHITECTURE.md`          | one-page architecture, non-goals, execution boundary                               |
| `02_CONTROL_PLANE_API.md`               | CRD family, 4-layer admission                                                      |
| `03_GPU_NODE_LIFECYCLE.md`              | NodeHealth, intake runbook, lifecycle                                              |
| `04_GPU_GOVERNANCE_AND_ISOLATION.md`    | **killer feature**: isolation + noisy-neighbor benchmark                           |
| `05_LLM_SERVING_GATEWAY.md`             | tenant-aware gateway, Open WebUI boundary                                          |
| `06_OBSERVABILITY_BENCHMARK_FAILURE.md` | observability layers, failure reports                                              |
| `07_OPERATIONS_LEDGER_AND_EVIDENCE.md`  | ledger schema, evidence matrix                                                     |
| `08_INTERVIEW_DEFENSE.md` — **not in this repository** | interview Q&A. `.gitignore` publishes `docs/00`–`07` and `09` only, so this file is untracked and exists on the author's machine alone. This row promised a reader a document they cannot open |
| `09_AWS_INFRA_ARCHITECTURE.md`          | M5-a/M5-b AWS architecture: Terraform states, network, OIDC, GitOps, cost/teardown |

## README vs this doc

The repository `README.md` should be a 30-second summary — the positioning line, the demo path, and links to evidence — and link here for detail. This document is the full overview; the README is the front door.

## One-line positioning

> Kubernetes-native GPUaaS control plane with multi-tenant performance isolation: declare GPU inference workloads as `InferenceDeployment`, govern resources and nodes with `GPUQuotaPolicy` and `NodeHealth`, route tenant LLM traffic through a gateway, and quantify p99 interference under GPU sharing with a noisy-neighbor benchmark.
