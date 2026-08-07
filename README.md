# gpu-platform-control-plane

Kubernetes-native control plane that manages GPUs as a platform resource.

## Overview

Most GPU setups stop at running a single workload. This project treats the GPU as a shared platform resource, covering node readiness, multi-tenant quota, serving, and training through one Kubernetes-native control plane.

## Scope

The control plane is organized into the following areas:

The **State** column is the point of this table: several areas below are designed and written up but have
no code in this repository, and saying which is which is more useful to a reader than a uniform list.

| Area                   | What it does                                                                                     | State |
|------------------------|--------------------------------------------------------------------------------------------------|-------|
| Node readiness         | Mirror a Node's `Ready` condition into a `NodeHealth` CR and taint on degradation                | Built — but the CR is hand-created, and there is **no GPU-specific fault detection** (no DCGM, Xid or ECC) |
| Multi-tenant quota     | Sync per-tenant quota and isolation policy from `GPUQuotaPolicy` into namespace objects          | Built |
| Inference serving      | Manage serving workloads declaratively via `InferenceDeployment`                                 | Built |
| Training admission     | Translate `MLTrainingJob` into queued `batch/v1` Jobs admitted through Kueue (M6)                | Built |
| Gateway                | Tenant-aware serving gateway: API key → tenant, token bucket, model routing, proxy, metrics      | Built and unit-tested; **never deployed** |
| Admission guard        | KV-cache-aware three-arm admission guard and open-loop benchmark harness (M5-b)                  | Built, never run on a GPU |
| Performance isolation  | Measure multi-tenant noisy-neighbor p99 contention under GPU sharing                             | **Designed only** — no `GpuSharingBenchmark` CRD or code exists |
| Failure & recovery     | Inject failure scenarios and validate the response path                                          | **Designed only** — M7, no code |
| Ledger                 | A SQLite ledger projecting CR/status/events                                                      | **Designed only** — no code |
| CLI                    | A `platformctl` CLI                                                                              | **Designed only** — no code |

Training admission (M6) uses [Kueue](https://kueue.sigs.k8s.io/) as the admission engine — this project does not reimplement a scheduler; it provides the `MLTrainingJob` abstraction and the status translation on top of Kueue. For training GPUs, Kueue owns the admission quota (`GPUQuotaPolicy` syncs to ClusterQueue/ResourceFlavor rather than double-counting the same GPUs in a namespace ResourceQuota).

## Architecture

The control plane owns the CRDs and reconciles them into native cluster objects. The data plane is ordinary Kubernetes resources created and garbage-collected through owner references.

## Status

The project is built milestone by milestone.

Each finished milestone is tagged and released, so the code at any stage can be read or checked out
directly from the [Releases](https://github.com/lkhun9311/gpu-platform-control-plane/releases) page.

| Milestone | Scope | Status |
|---|---|---|
| [M1](https://github.com/lkhun9311/gpu-platform-control-plane/releases/tag/m1-skeleton) | Project skeleton and the four core CRDs, verified with envtest | Done |
| [M2](https://github.com/lkhun9311/gpu-platform-control-plane/releases/tag/m2-reconcilers) | Idempotent reconciliation with finalizers and drift recovery (NodeHealth reference) | Done |
| [M3](https://github.com/lkhun9311/gpu-platform-control-plane/releases/tag/m3-enforcement) | Taint unhealthy nodes (NodeHealth enforcement) and sync per-tenant quota into ResourceQuota | Done |
| [M4-a](https://github.com/lkhun9311/gpu-platform-control-plane/releases/tag/m4-serving) | `InferenceDeployment` → Deployment/Service with a phase ladder | Done |
| [M4-b](https://github.com/lkhun9311/gpu-platform-control-plane/releases/tag/m4-serving) | Tenant-aware serving gateway: API key → tenant, token bucket → 429, model routing, proxy, metrics | Done |
| [M5-a](https://github.com/lkhun9311/gpu-platform-control-plane/releases/tag/m5-a-hosting) | AWS hosting: Terraform state bootstrap, EKS, OIDC CI → ECR, Argo CD GitOps, ephemeral apply/destroy with a TTL kill switch | Code done, offline-validated; **never applied to AWS** |
| [M5-b](https://github.com/lkhun9311/gpu-platform-control-plane/releases/tag/m5-b-admission-guard) | Three-arm KV-cache-aware admission guard and open-loop benchmark harness, with pre-registered checks that refuse to call load shedding a win | GPU-free half done and tested; **no GPU run yet** |
| M5-c | Cost/fairness frontier and sharing-mode matrix (exclusive / time-slicing / MPS) — hardens the M5-b evidence | Planned |
| M5-d | Technical write-up with the measured numbers | Planned |
| [M6](https://github.com/lkhun9311/gpu-platform-control-plane/releases/tag/m6-training-admission) | Training admission: `MLTrainingJob` → Job + Kueue Workload; two-tenant cohort borrowing and quota-reclaim preemption, run end to end on kind | Done ([evidence](hack/m6-kind-e2e.md)) |
| [queuelab](https://github.com/lkhun9311/gpu-platform-control-plane/releases/tag/queuelab) | Queue-policy measurement lab: censoring-aware list/watch lifecycle ledger replayed against real Kueue | **Result retracted — no valid experimental number.** See the correction below |
| M7 | Inject failure scenarios and record an operational evidence trail (`WorkloadRun`) | Sketched |

**What has not been exercised.** Every GPU in this project is simulated by a fake device plugin. Nothing
here has ever run against real hardware, and the State and Status columns above say so per row rather than
leaving it to be inferred. Two distinctions worth stating plainly, because they are easy to blur:

- The admission guard and its benchmark harness are **written and unit-tested but have never seen a GPU**,
  and the guard's vLLM metrics fixture is synthetic — labelled as such in the fixture itself — so its
  engage/release thresholds are unvalidated.
- The contention benchmark, the SQLite ledger and `platformctl` are **not coded at all**. They are design
  documents. Earlier revisions of this README described them as if they existed; that was wrong.

**Flagship benchmark:** KV-cache-aware noisy-neighbor p99 protection — a real-GPU benchmark that compares premium tenant latency under baseline, colocated long-context noisy-neighbor, and Gateway admission-guard modes. The harness, the guard and the pre-registered checks are written and tested; **it has never been run on a GPU, so there are no numbers.**

## Correction: the queuelab reclaim result is withdrawn

On 2026-08-02 this repository published a live measurement of Kueue quota-reclaim preemption. The claim was
that switching `reclaimWithinCohort` from `Never` to `Any` admitted the quota owner about 120 ms after its
submission, at a cost of roughly 39 GPU-seconds of the borrower's discarded work. **It was wrong, and it is
withdrawn. There are currently zero valid queuelab experimental numbers.**

What was wrong, in the order it was found:

1. **Nothing was ever preempted.** The lab's sleeper ran `sleep` as PID 1, and a container's PID 1 ignores
   `SIGTERM` without an explicit handler. A controlled experiment settles it: a workload running
   `trap 'exit 143' TERM; sleep N & wait` terminates in 1 s with exit 143, while a bare `sleep N` survives
   the full 30 s termination grace and dies only to `SIGKILL` at 34 s. The measured workloads ran to
   completion and were re-executed. The waste figure was real but for the opposite reason, and the
   accounting inferred causation from adjacency: it charged discarded work whenever a preemption decision
   was followed by a stop, without ever checking the stop reason its own ledger had recorded.
2. **The "120 ms admission" was quota reservation, not service.** The owner's Pod became Ready 9.4 s later.
3. **The experiment's design was invalid too.** The fixture is three jobs: the borrower that is meant to be
   reclaimed, the quota owner whose admission is the endpoint, and `a1`, a co-tenant that is supposed to
   hold its own unit throughout. All three shared one duration, so `a1` released a GPU 31 ms before the
   alleged victim did (42.607 s vs 42.638 s, owner Ready at 43.550 s). The endpoint — "the owner ran because
   the victim was reclaimed" — could not be attributed to the reclamation at all. The stated 40-second dose
   was really 49 seconds, derived by subtracting two trace offsets that were never meant to encode it. And
   the experiment defines three arms (honoring victim, ignoring victim, no-reclaim reference); the runner
   could not select a termination contract, so **the honoring arm did not exist in the executable.**

What exists now instead of a number: the measurement layer will not charge discarded work without an
observed failed terminal phase, the protocol closes the co-tenant confound and states its dose explicitly,
and **`queuelabrun` refuses by design to emit a countable result** — it exits non-zero and names the
validity gates that are still unimplemented. That refusal is the current state of this milestone, and it is
deliberate: the earlier result counted because a run that looked fine was allowed to count.

## Tech stack

- Go, controller-runtime, scaffolded with [kubebuilder](https://book.kubebuilder.io/)
- kind for the local cluster, envtest for controller tests
- Kueue (training admission), kube-prometheus-stack (metrics)

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
internal/       the substance: four reconcilers, the serving gateway,
                the admission guard and benchmark harness, the queuelab
                measurement layer
cmd/            controller manager, gateway, benchmark harness, queuelab runner
config/         kustomize manifests (CRD, RBAC, manager, Kueue fixtures)
hack/           local cluster config and the M6 end-to-end script + evidence
infra/          Terraform for the AWS hosting path (never applied)
docs/           design documents and specs
test/           e2e test scaffolding
```

## License

[Apache 2.0](LICENSE)
