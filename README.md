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
| Training admission | Translate `MLTrainingJob` into queued `batch/v1` Jobs admitted through Kueue |
| Failure & recovery | Inject failure scenarios and validate the response path |
| Observability & ledger | Metrics, dashboards, and a SQLite ledger that projects CR/status/events |
| Gateway & CLI | A lightweight multi-tenant gateway and a `platformctl` CLI |

Training admission uses [Kueue](https://kueue.sigs.k8s.io/) as the admission engine. This project
does not reimplement a scheduler; it provides the `MLTrainingJob` abstraction and the status
translation on top of Kueue.

## Architecture

The control plane owns the CRDs and reconciles them into native cluster objects. The data plane is
ordinary Kubernetes resources created and garbage-collected through owner references.

## Status

The project is built milestone by milestone.

| Milestone | Scope | Status |
|---|---|---|
| M1 | Set up the project skeleton and define the four CRDs, verified with envtest | In progress (project scaffolded, CRDs pending) |
| M2 | Ensure reconciliation is idempotent, with finalizers and drift recovery | Designed |
| M3 | Taint or cordon unhealthy nodes and sync per-tenant quota | Designed |
| M4 | Manage inference workloads and route them through the gateway | Designed |
| M5 | Admit training jobs through Kueue | Designed |
| M6 | Inject failure scenarios and record an operational evidence trail | Designed |
| M6.5 | Run a second workload type (scene retrieval) on the same control plane | Designed |

GPU capacity used in validation is simulated. Real GPU serving, hardware fault detection, and AWS
deployment are designed but not yet exercised.

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

Simulated GPU capacity on a worker node, for scheduling/quota validation:

```bash
kubectl patch node platform-worker --subresource=status --type=json \
  -p='[{"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"4"},
       {"op":"add","path":"/status/allocatable/nvidia.com~1gpu","value":"4"}]'
```

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
