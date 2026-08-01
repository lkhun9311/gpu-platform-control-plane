# gpu-platform-control-plane

Kubernetes-native control plane that manages GPUs as a platform resource.

## Overview

Most GPU setups stop at running a single workload. This project treats the GPU as a shared platform resource, covering node readiness, multi-tenant quota, serving, and training through one Kubernetes-native control plane.

## Scope

The control plane is organized into the following areas:

| Area                   | What it does                                                                                                    |
|------------------------|-----------------------------------------------------------------------------------------------------------------|
| GPU node readiness     | Represent node GPU state as a `NodeHealth` CR; block scheduling on degraded nodes                               |
| Multi-tenant quota     | Sync per-tenant quota and isolation policy from `GPUQuotaPolicy` into namespace objects                         |
| Inference serving      | Manage serving workloads declaratively via `InferenceDeployment`                                                |
| Performance isolation  | Measure multi-tenant noisy-neighbor p99 contention under GPU sharing via `GpuSharingBenchmark` (killer feature) |
| Failure & recovery     | Inject failure scenarios and validate the response path                                                         |
| Observability & ledger | Metrics, dashboards, and a SQLite ledger that projects CR/status/events                                         |
| Gateway & CLI          | A lightweight multi-tenant gateway and a `platformctl` CLI                                                      |
| Training admission     | Translate `MLTrainingJob` into queued `batch/v1` Jobs admitted through Kueue (M6)                               |

Training admission (M6) uses [Kueue](https://kueue.sigs.k8s.io/) as the admission engine — this project does not reimplement a scheduler; it provides the `MLTrainingJob` abstraction and the status translation on top of Kueue. For training GPUs, Kueue owns the admission quota (`GPUQuotaPolicy` syncs to ClusterQueue/ResourceFlavor rather than double-counting the same GPUs in a namespace ResourceQuota).

## Architecture

The control plane owns the CRDs and reconciles them into native cluster objects. The data plane is ordinary Kubernetes resources created and garbage-collected through owner references.

## Status

The project is built milestone by milestone.

| Milestone | Scope                                                                                                                                                                            | Status          |
|-----------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------|
| M1        | Set up the project skeleton and define the core CRDs, verified with envtest                                                                                                      | Done            |
| M2        | Make reconciliation idempotent, with finalizers and drift recovery (NodeHealth reference)                                                                                        | Done            |
| M3        | Taint unhealthy nodes (NodeHealth enforcement) and sync per-tenant quota into ResourceQuota                                                                                      | Done            |
| M4-a      | Manage inference workloads: `InferenceDeployment` → Deployment/Service with a phase ladder                                                                                       | Done            |
| M4-b      | Tenant-aware serving gateway: API key → tenant, token bucket → 429, model routing, proxy, metrics                                                                                | Done            |
| M5-a      | AWS hosting: Terraform (state bootstrap, EKS, node groups), GitHub Actions CI (OIDC → ECR), Argo CD GitOps, operator deployed on EKS, slim observability — no GPU yet            | Designed (v3.1) |
| M5-b      | Real-GPU flagship on that infra: GPU node group (On-Demand, ephemeral), `GpuSharingBenchmark` + KV-cache-aware admission guard, measured noisy-neighbor p99 A/B (killer feature) | Designed        |
| M5-c      | Depth: cost/fairness frontier (≥3 guard thresholds) + sharing-mode matrix (exclusive / time-slicing / MPS) — hardens the M5-b evidence, no new features                          | Planned         |
| M5-d      | Technical write-up with the measured numbers (published after M5-c)                                                                                                              | Planned         |
| M6        | Training admission (promoted from stretch): `MLTrainingJob` → Job + Kueue Workload, 2-tenant cohort borrowing + quota-reclaim preemption on kind; Kueue owns training quota                | Done ([evidence](hack/m6-kind-e2e.md)) |
| M7        | Inject failure scenarios and record an operational evidence trail (`WorkloadRun`)                                                                                                | Sketched        |

GPU capacity used in validation is simulated. Real GPU serving, hardware fault detection, the contention benchmark's p99 figures, and AWS deployment are designed but not yet exercised.

**Flagship benchmark:** KV-cache-aware noisy-neighbor p99 protection — a real-GPU benchmark that compares premium tenant latency under baseline, colocated long-context noisy-neighbor, and Gateway admission-guard modes. See `docs/04_GPU_GOVERNANCE_AND_ISOLATION.md` (M5 Flagship Experiment).

## Tech stack

- Go, controller-runtime, scaffolded with [kubebuilder](https://book.kubebuilder.io/)
- kind for the local cluster, envtest for controller tests
- Kueue (training admission), KEDA (autoscaling), kube-prometheus-stack (metrics)

## Local development

Requires Docker, Go, kind, kubectl, and kubebuilder.

```bash
# create the local 3-node cluster (control-plane + 2 workers)
kind create cluster --config hack/kind-config.yaml

# generate manifests and build the controller binary
make manifests
make build

# run controller tests (envtest)
make test
```

Simulated GPU capacity on a **kind** worker node, only for end-to-end scheduling/quota-*enforcement* validation (the GPUQuotaPolicy controller itself needs no GPU capacity — it writes a `requests.nvidia.com/gpu` ResourceQuota; capacity matters only when sample pods actually request GPU):

```bash
kubectl patch node platform-worker --subresource=status --type=json \
  -p='[{"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"4"},
       {"op":"add","path":"/status/allocatable/nvidia.com~1gpu","value":"4"}]'
```

> This node-status patch holds on kind because no device plugin reconciles GPU capacity there. On a real cluster (e.g. EKS) the kubelet/device plugin owns node status and would overwrite it, so advertise simulated capacity with a device-plugin-style DaemonSet instead.

## Repository layout

```
api/            CRD types
cmd/            controller manager entrypoint
config/         kustomize manifests (CRD, RBAC, manager)
hack/           dev config and scaffolding helpers (kind-config.yaml)
test/           e2e test scaffolding
```

## License

[Apache 2.0](LICENSE)
