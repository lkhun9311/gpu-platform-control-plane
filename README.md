# gpu-platform-control-plane

Kubernetes-native control plane that manages GPUs as a platform resource.

## Overview

Most GPU setups stop at running a single workload. This project treats the GPU as a shared platform resource, covering node readiness, multi-tenant quota, serving, and training through one Kubernetes-native control plane.

## Scope

The control plane is organized into the following areas:

| Area | What it does |
|---|---|
| GPU node readiness | Represent node GPU state as a `NodeHealth` CR; block scheduling on degraded nodes |
| Multi-tenant quota | Sync per-tenant quota and isolation policy from `GPUQuotaPolicy` into namespace objects |
| Inference serving | Manage serving workloads declaratively via `InferenceDeployment` |
| Performance isolation | Measure multi-tenant noisy-neighbor p99 contention under GPU sharing via `GpuSharingBenchmark` (killer feature) |
| Failure & recovery | Inject failure scenarios and validate the response path |
| Observability & ledger | Metrics, dashboards, and a SQLite ledger that projects CR/status/events |
| Gateway & CLI | A lightweight multi-tenant gateway and a `platformctl` CLI |
| Training admission (stretch) | Translate `MLTrainingJob` into queued `batch/v1` Jobs admitted through Kueue |

Training admission is a stretch track. It uses [Kueue](https://kueue.sigs.k8s.io/) as the admission
engine — this project does not reimplement a scheduler; it provides the `MLTrainingJob` abstraction
and the status translation on top of Kueue.

## Architecture

The control plane owns the CRDs and reconciles them into native cluster objects. The data plane is
ordinary Kubernetes resources created and garbage-collected through owner references.

## Status

The project is built milestone by milestone.

| Milestone | Scope | Status |
|---|---|---|
| M1 | Set up the project skeleton and define the core CRDs, verified with envtest | Done |
| M2 | Make reconciliation idempotent, with finalizers and drift recovery (NodeHealth reference) | In progress |
| M3 | Taint/cordon unhealthy nodes (NodeHealth enforcement) and sync per-tenant quota | Designed |
| M4 | Manage inference workloads (`InferenceDeployment`) and route them through the tenant-aware gateway | Designed |
| M5 | Measure multi-tenant noisy-neighbor p99 contention via `GpuSharingBenchmark`, with a real-GPU baseline-vs-colocated run (killer feature) | Designed |
| M6 | Inject failure scenarios and record an operational evidence trail (`WorkloadRun`) | Designed |
| Stretch | Admit training jobs through Kueue (`MLTrainingJob`) | Designed |

GPU capacity used in validation is simulated. Real GPU serving, hardware fault detection, the
contention benchmark's p99 figures, and AWS deployment are designed but not yet exercised.

**Flagship benchmark:** KV-cache-aware noisy-neighbor p99 protection — a real-GPU benchmark that
compares premium tenant latency under baseline, colocated long-context noisy-neighbor, and Gateway
admission-guard modes. See `docs/04_GPU_GOVERNANCE_AND_ISOLATION.md` (M5 Flagship Experiment).

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

Simulated GPU capacity on a **kind** worker node, only for end-to-end scheduling/quota-*enforcement*
validation (the GPUQuotaPolicy controller itself needs no GPU capacity — it writes a
`requests.nvidia.com/gpu` ResourceQuota; capacity matters only when sample pods actually request GPU):

```bash
kubectl patch node platform-worker --subresource=status --type=json \
  -p='[{"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"4"},
       {"op":"add","path":"/status/allocatable/nvidia.com~1gpu","value":"4"}]'
```

> This node-status patch holds on kind because no device plugin reconciles GPU capacity there.
> On a real cluster (e.g. EKS) the kubelet/device plugin owns node status and would overwrite it, so advertise simulated capacity with a device-plugin-style DaemonSet instead.

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
