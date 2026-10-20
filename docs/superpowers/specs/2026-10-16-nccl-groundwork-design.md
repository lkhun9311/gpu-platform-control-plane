# Design: the free groundwork for running `spec.distributed` on GPUs with NCCL

Written 2026-10-16. Status: **parked after review, not built.** codex `gpt-6-astra`'s adversarial review (2026-10-16) found 3 blockers and 10 majors; the scope is much larger than drafted, and it waits behind the hold-cap work.
No money is spent by anything here; the paid run that would use it is a separate decision.

## Why

Multi-Pod training is built and passed a registered kind experiment on CPU with gloo (`experiments/multi-pod-ddp/`).
`docs/11` still says "no NCCL and no GPU". Running the same job on GPUs on EKS is blocked by four gaps, none of which needs a GPU to close:

1. **Nothing admits a training job on EKS.** Argo installs Kueue's CRDs (`config/argocd/kueue-crds.yaml`) and says in its own comment that the controller is not installed.
2. **Nothing lets a training Pod onto a GPU node.** The `gpu` and `gpu_single` node groups carry the taint `nvidia.com/gpu=present:NoSchedule` (`infra/aws/cluster/eks.tf`), and `BuildJob` renders no toleration.
3. **The workload is CPU-only.** `experiments/cpu-ddp/train.py` hard-codes gloo and CPU tensors, and every training image installs the CPU wheel.
4. **The session cannot buy two GPU nodes.** `hack/eks-gitops-session.sh` scales `gpu_single`, whose `max_size` is 1.

## What closes each gap

### 1. The Kueue controller, by Argo, at v0.18.3

A new Application, `gpu-platform-kueue`, auto-synced, deploying the controller from Kueue's own v0.18.3 release manifest **minus its CustomResourceDefinitions**, vendored at `config/kueue-controller/` with the release file's sha256.
The CRDs stay with `gpu-platform-kueue-crds`, so no two Applications own one object and removing one never deletes the other's CRDs.
A test reads the vendored manifest and refuses it if it contains a CRD, or if it names an image other than the v0.18.3 controller by digest; another checks that the CRDs in `config/kueue-crds/` are the ones the same release ships, so the two halves cannot drift to different versions.
The Application also deploys `config/kueue/resourceflavor.yaml`, which nothing on EKS deploys today.

### 2. GPU placement in the ResourceFlavor, not in `BuildJob`

The `gpu` ResourceFlavor gains `tolerations: [{key: nvidia.com/gpu, operator: Equal, value: present, effect: NoSchedule}]`. Kueue adds a flavor's tolerations to the Pods of every workload it admits on that flavor.
Why there and not in `BuildJob`: a toleration in `BuildJob` changes the rendered Pod template, which the termination canary hashes, so every canary reading taken so far would be invalidated, and the non-distributed golden would have to be rewritten. The flavor is also where the placement policy belongs: it is what says "this quota is GPUs", and an MLTrainingJob says nothing about nodes today.
What it costs: a training Pod is placed on a GPU node only through Kueue admission. That is already the only way an MLTrainingJob runs, since every Job is created suspended.
The flavor's empty `spec` matched the GPU simulator on kind, and a toleration does not stop that: an untainted node needs none.

### 3. A GPU path in `train.py`, chosen explicitly

`DDP_BACKEND` selects `gloo` (default, today's behaviour) or `nccl`.
With `nccl` the script refuses to start unless CUDA is available, puts the model, data and digest tensors on `cuda:0` (one GPU per Pod, so the local device is always 0), and records the device name, the GPU UUID and the NCCL version in its `rendezvous` record. A run that quietly fell back to CPU would print the same arithmetic; the record is what tells them apart, and the refusal is what stops it.
The CPU experiment keeps passing unchanged: its arms do not set `DDP_BACKEND`.

**The image.** The public `pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime`, pinned by digest, with `train.py` supplied in the command (base64, decoded to `/tmp/train.py`), because an MLTrainingJob can mount no ConfigMap and an image of our own would need an ECR repository the bootstrap root does not create. The script hashes itself, so the record still names the code that ran.

### 4. Two GPU nodes in the session

`TRAIN=ddp` in `hack/eks-gitops-session.sh` scales the `gpu` node group, with `gpu_node_instance_type = g5.xlarge` and `gpu_max_nodes = 2` passed to Terraform, to two nodes, under the same deadline, residue checks and teardown as the serving card.
Two g5.xlarge are 8 vCPU against the account's quota, one A10G each, so the two ranks run on two nodes by construction, as on kind. The `gpu` group is On-Demand (`infra/aws/cluster/vpc.tf`), about $1.0 an hour per node.
The two modes are exclusive in one session.

### 5. A training namespace with quota

`config/training/`: namespace `train-a`, and a GPUQuotaPolicy with `trainingQuota: true` and `limits.gpuCount: 2`, which makes the controller create ClusterQueue and LocalQueue `gpu-train-a` and label the namespace for the GPU webhooks. A manual Application, as `config/serving/` is, synced by the session's training mode.

## Evidence before any money

- envtest: none of this changes the operator; the existing suite must stay green.
- The tests above on the vendored Kueue manifest and the CRD versions, each shown red by a mutation.
- On kind: a cluster with one worker tainted `nvidia.com/gpu=present:NoSchedule`; Kueue installed from `config/kueue-controller/` the way Argo will build it (`kustomize build`); the flavor with its toleration; a `worldSize: 2` job admitted and its Pods observed carrying the toleration and running on the tainted node. That is the only place the placement can be shown without a GPU.
- `train.py`: the gloo arms of `experiments/multi-pod-ddp/` rerun unchanged and pass; `DDP_BACKEND=nccl` on a CPU-only Pod refuses to start, by name.
- The session's training mode rehearsed with the AWS stub the teardown replay uses, up to the purchase, and its teardown scenarios replayed.

## What it would license

Nothing by itself: it makes a paid NCCL run possible. That run, its registration and its budget come after this, with the owner's approval.

## Out of scope

The paid run, more than one GPU per Pod, a launcher such as `torchrun` across nodes, gang scheduling, and the `gpu_shared` group.

## The review that parked it (codex `gpt-6-astra`, 2026-10-16)

| finding | severity |
|---|---|
| v0.18.3 ships eleven CRDs, `config/kueue-crds/` holds four; a controller without the rest does not run | blocker |
| the vendored CRDs store `v1beta1` with `conversion: None`, upstream stores `v1beta2` with conversion webhooks; equality fails and envtest fixtures depend on the difference | blocker |
| nothing makes the scorer require NCCL, CUDA devices or distinct GPUs; the current analyzer still passes with backend and device evidence removed | blocker |
| Kueue's own certificate management writes into objects two Applications would own; no drift strategy | major |
| `kustomize build` does not rehearse Argo ownership, health, ordering or self-heal | major |
| a toleration admits the taint but selects no node group, card or distinct node | major |
| the session qualifies one joined node (`head -1`); a second may never arrive | major |
| the price gate reads Spot; the `gpu` group is On-Demand | major |
| the quota guard checks configured demand, not remaining headroom or GPU suitability | major |
| Terraform apply bypasses an `aws` stub, so the proposed rehearsal is not free or hermetic | major |
| a self-hash identifies the script; nothing checks it against an approved one | major |
| a CPU refusal test does not exercise the CUDA path | major |
| `limits.gpuCount: 2` joins a shared cohort with reclaim; not a hard ceiling | major |
| fractional `gpu_max_nodes`, an argument size bound, image-pull cost, the canary claim's scope, the Application's real name | minor |

Confirmed by the same review: Kueue v0.18.3 does copy a flavor's tolerations into the Job's Pod template before unsuspending it, and nothing in the operator or its webhooks strips or refuses them.
