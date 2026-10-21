# Design: the free groundwork for running `spec.distributed` on GPUs with NCCL

Written 2026-10-16, revised 2026-10-21 as v2, v3 and v4. Status: **v4, answering three reviews; not built, and second in line.**
A brainstorm with codex the same day ranked a free kind experiment on partially placed distributed jobs ahead of this, and found three things v4 still gets wrong; they bind any implementation and are listed in "Corrections that bind the build" below, ahead of the sections they amend.
v1 was parked after codex `gpt-6-astra`'s adversarial review (2026-10-16) found 3 blockers and 10 majors. v2 answered them; astra's review of v2 found 7 majors and 2 minors, and its review of v3 found 3 majors and 2 minors, none a blocker. Each finding was re-checked against the code before the next version answered it. The tables are at the end.
No money is spent by anything here; the paid run that would use it is a separate decision with its own registration.

## Why

Multi-Pod training is built and passed a registered kind experiment on CPU with gloo (`experiments/multi-pod-ddp/`).
`docs/11` still says "no NCCL and no GPU". Running the same job on GPUs on EKS is blocked by five gaps, none of which needs a GPU to close:

1. **Nothing admits a training job on EKS.** Argo installs four Kueue CRDs (`config/argocd/kueue-crds.yaml`) and says in its own comment that the controller is not installed.
2. **Nothing places a training Pod on a GPU node.** The `gpu` and `gpu_single` node groups carry the taint `nvidia.com/gpu=present:NoSchedule` and the same label `platform.lkhun9311.github.io/gpu=true` (`infra/aws/cluster/eks.tf`), and `BuildJob` renders no toleration.
3. **The workload is CPU-only.** `experiments/cpu-ddp/train.py` hard-codes gloo and CPU tensors, and the experiments' training images install the CPU wheel. (The MLTrainingJob sample names a CUDA image, but carries no `train.py`.)
4. **Nothing could tell a GPU run from a CPU one.** `experiments/multi-pod-ddp/analyze.py` would pass a run whose ranks never touched a GPU, because it checks arithmetic and rendezvous, not backend or device.
5. **The session cannot buy two training nodes.** `hack/eks-gitops-session.sh` scales `gpu_single`, whose `max_size` is 1, and qualifies one node.

## Facts this version rests on, measured 2026-10-21

- **Kueue on EKS cannot be v0.20.1, and is chosen to be v0.18.3.** `go.mod` carries `sigs.k8s.io/kueue v0.20.1` since the dependency bump of 2026-10-11 (`33bd11b`), but the operator reads and indexes `kueue.x-k8s.io/v1beta1` in ten files (`internal/controller/`, `cmd/main.go`).
  The v0.20.1 release manifest serves `v1beta1` for none of its CRDs (`served: false`); v0.18.3 serves `v1beta1` and `v1beta2`, stores `v1beta2`, and converts by webhook. So v0.20.1 on a cluster would leave the operator unable to discover the API it indexes.
  v0.19.0 also still serves `v1beta1`, so v0.18.3 is not the only compatible version; it is chosen because every kind script and every recorded kind experiment installed it.
  The client library stays at v0.20.1, which still ships the `v1beta1` types; moving the operator to `v1beta2` is a separate change, out of scope here.
- **The release ships eleven CRDs.** `config/kueue-crds/` holds four, as envtest and `test/e2e` fixtures; those four store `v1beta1` with no conversion, because envtest runs no webhook.
- **Argo does not wait for one child Application's health before the next wave.** No Application health customisation exists in this repository, so sync waves order creation only.
- **The operator's readiness proves nothing about Kueue.** Its readiness check is `healthz.Ping` (`cmd/main.go`), and its Workload index is registered without waiting for the informer to sync, so an operator that is Ready may still be failing to list or convert Workloads.
- **The session does not require an absent cluster.** It applies Terraform against whatever state exists, and `KEEP_UP=yes` leaves a cluster up.
- **The real NVIDIA device plugin follows the GPU label.** Its auto-synced DaemonSet selects `platform.lkhun9311.github.io/gpu=true` and fails on initialisation without a GPU, so that label cannot be put on a kind worker.
- **The `gpu` node group is On-Demand** (`infra/aws/cluster/vpc.tf`, `local.gpu_capacity`), its instance type defaults to a four-T4 queuelab type, and `gpu_max_nodes` is validated only to lie between 1 and 2 (`infra/aws/cluster/variables.tf`).
- **`terraform_data.gpu_quota` compares the configured worst case with the account quota** (`infra/aws/cluster/placement.tf`); it does not read what is already running.
- **`train.py` is 18,691 bytes**, so base64 in the container command is about 25 KB, far inside the object and argument limits.

## Corrections that bind the build (2026-10-21, after v4)

Each was raised by codex `gpt-6-astra` and re-checked against the file before it was written here.

1. **Placement goes in an EKS-only overlay, not in the shared flavor.** Five kind harnesses apply `config/kueue/resourceflavor.yaml` directly (`hack/multi-pod-ddp.sh`, `hack/checkpoint-resume.sh`, `hack/m6-kind-e2e.sh`, `hack/mlops-lineage.sh`, `hack/m5b-gateway-path.sh`), and none labels its workers; a `nodeLabels` there would leave all of their Pods unschedulable. The shared flavor stays `spec: {}`, and section 2's toleration and label are applied by an overlay the Kueue Application builds.
2. **The `admittedAt` gate needs a job held in Admitted.** The operator writes `admittedAt` only on a reconcile that sees the job admitted and not yet running (`internal/controller/admit_to_running.go`); a healthy operator that first sees an already-running job leaves it absent, by design. So section 1's check runs on a separate qualification job held admitted but unready, then released, not on each correctness cell.
3. **The price is $1.237 an hour per g5.xlarge**, the On-Demand list price in `ap-northeast-2` read from the Price List API on 2026-10-21, not "about $1.0".

## What closes each gap

### 1. Kueue v0.18.3, whole, by one Application

A new auto-synced Application, `gpu-platform-kueue`, deploys Kueue's own v0.18.3 release manifest **unmodified**: all eleven CRDs, the controller, its webhooks and its internal certificate management.
The manifest is vendored at `config/kueue-controller/manifests.yaml` with the release file's sha256, and the controller image is pinned by digest through a kustomize `images:` override, so the vendored bytes stay the release's.
It replaces the `kueue-crds` Application on EKS, so no two Applications own one object.
It syncs with `ServerSideApply=true`, as `kueue-crds` does and for the same reason: client-side apply stores the manifest in an annotation, and the Workload CRD is larger than the 262,144-byte limit.

**The switch on a cluster that already has the old Application.** The session does not require an absent cluster, so the switch must be safe where `kueue-crds` already ran. Removing it from the root leaves its four CRDs in place, because it has neither pruning nor a cascading finalizer; the new Application then applies the same CRDs server-side and takes them over.
That is what should happen, not what is known to; the kind rehearsal below starts from the old root and switches, so the takeover is observed rather than assumed.
`config/kueue-crds/` stays, as the fixture envtest and `test/e2e` read. Its README and the Argo comment that describe it as what EKS installs are corrected in the same change.

What the tests pin, each shown red by a mutation:

- the vendored file's sha256 equals the recorded release sha256;
- the rendered Application names the v0.18.3 controller by digest and no other image;
- for each of the four fixture CRDs, the `openAPIV3Schema` of each version equals the release's schema for that version. The `storage` flag and `spec.conversion` are allowed to differ, by name, because they are the one deliberate difference: envtest has no conversion webhook. This is what can be compared; v1 claimed an equality that does not hold.

**Certificates.** Kueue's internal certificate manager writes the CA bundle into its two webhook configurations and into the conversion stanzas of the five CRDs that convert by webhook, and the certificate into its Secret. The Application declares `ignoreDifferences` for exactly those fields, with `RespectIgnoreDifferences=true`, so self-heal never reverts what Kueue writes. A test pins the list against the objects the release ships.

**Ordering, and what proves the operator reached Kueue.** The Application syncs in wave -2, as `kueue-crds` did. Waves do not wait for health, so the operator can start before Kueue answers.
Two failures are possible then, and they are different: before the CRDs are served, registering the Workload index fails and the operator exits; after, while the conversion webhook is not yet answering, the index registers but the informer cannot list or convert Workloads, and the operator stays Ready.
So operator readiness is not the gate. The training mode waits for `deployment/kueue-controller-manager` Available, then applies the training policy and waits for the ClusterQueue `gpu-train-a`, which the operator creates through its Kueue client, to report `Active` from Kueue. That shows the operator writes to Kueue and Kueue's controller answers.
It does not show the operator reads Workloads: Kueue admits and unsuspends a Job on its own, whatever the operator's cache sees. What does is the MLTrainingJob's status: the operator stamps `admittedAt` there from the Workload's `Admitted` condition after reading it (`internal/controller/mltrainingjob_controller.go`), so the session requires that stamp, equal to the Workload's own condition time, before it counts the job as started. Training mode runs only on a cluster it created (section 5), so neither the ClusterQueue nor the stamp can predate the session. The operator's restart count is recorded beside them.

**Rehearsed with Argo, not with `kustomize build`.** On kind, by the clean-kind GitOps rehearsal (`docs/superpowers/specs/2026-09-25-gitops-rehearsal-on-clean-kind.md`), starting from today's root and then switching to the new one:

- the four old CRDs taken over by `gpu-platform-kueue` with no deletion, and the other seven created;
- every **automated** Application Synced and Healthy, judged as that rehearsal already judges it; the manual Applications (observability, samples, serving, training) are expected to stay unsynced, and observability references monitoring CRDs nothing installs;
- `gpu-train-a` `Active` as above;
- three drifts repaired by self-heal: the controller Deployment deleted, its replica count changed, a webhook configuration deleted;
- fifteen minutes with no OutOfSync caused by certificate writes.

### 2. Placement in the ResourceFlavor, scoped to the training node group

The `gpu` ResourceFlavor (`config/kueue/resourceflavor.yaml`, the controller's fixed `kueueFlavor`) gains:

- `tolerations: [{key: nvidia.com/gpu, operator: Equal, value: present, effect: NoSchedule}]`, and
- `nodeLabels: {platform.lkhun9311.github.io/train: "true"}`, a label of its own that only the `gpu` node group carries, added beside its existing labels in `infra/aws/cluster/eks.tf`.

Kueue v0.18.3 copies both into the Pod template of every workload it admits on that flavor before unsuspending it; the review confirmed this, and that nothing in the operator or its webhooks strips them.
Why there and not in `BuildJob`: a toleration in `BuildJob` changes the rendered template the termination canary hashes, which would invalidate every canary reading so far and rewrite the non-distributed golden. The canary hashes `BuildJob`'s output, which this leaves unchanged; it does not claim to describe the live Pod, which Kueue mutates.

Why a new label and not `platform.lkhun9311.github.io/gpu`: `gpu` and `gpu_single` share that one, so a flavor selecting it would admit a training Pod onto a serving card, and a `gpu_single` group at desired size 0 does not prove its node is gone. The new label is on `gpu` nodes only, so no `gpu_single` node can match whatever its state.
It also keeps the kind rehearsal possible: the real NVIDIA device plugin selects the GPU label and fails without a GPU, so that label cannot go on a kind worker, and this one can.
The flavor still does not choose distinct nodes or distinct cards. Those are what the analyzer checks (section 4), and with one A10G per g5.xlarge and one GPU per Pod, two Running ranks can only be on two nodes; the evidence says so rather than the construction.

On kind the GPU-simulator worker gets the training label and the taint, so the flavor behaves as on EKS and the toleration is shown working.
This flavor is also deployed on EKS for the first time, by the Application in section 1.

### 3. A GPU path in `train.py`, chosen explicitly

`DDP_BACKEND` selects `gloo` (default, today's behaviour) or `nccl`.
With `nccl` the script refuses to start unless CUDA is available, puts the model, data and digest tensors on `cuda:0` (one GPU per Pod), and records in its `rendezvous` record the backend in use (`torch.distributed.get_backend()`), the tensors' device type, the device name, the GPU UUID, `torch.version.cuda` and `torch.cuda.nccl.version()`.
The CPU experiment's arms do not set `DDP_BACKEND`, and they rerun unchanged and pass.

**What can be tested without a GPU, and what cannot.** Unit tests run the selection logic with `torch.cuda` replaced by a fake: the refusal by name when CUDA is absent, the device chosen when it is present, and every field of the record. They do not exercise NCCL or a real device; the first execution of that path is the paid run, whose registration must treat it as untested code and include a smoke cell before any measured one.

**The image** is the public `pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime`, pinned by digest, with `train.py` supplied in the command as base64 decoded to `/tmp/train.py`, because an MLTrainingJob mounts no ConfigMap and an image of our own would need an ECR repository the bootstrap root does not create.
The script hashes itself and records it; that hash identifies the code, and section 4 is what checks it against the approved one.

### 4. An analyzer profile that requires the GPU evidence

`experiments/multi-pod-ddp/analyze.py` gains an `nccl` profile, selected by the run's registration, not by the evidence.
The criteria below apply to the arms the registration names as completing; an arm registered to fail, like `bad-address`, which never reaches rendezvous, keeps its own criteria and is judged by them. Under the profile a completing arm passes only if every rank's record shows:

- backend `nccl` and tensors on device type `cuda`;
- a GPU UUID, and the UUIDs are pairwise distinct across ranks;
- a node name, the names are pairwise distinct, and each node carried the `eks.amazonaws.com/nodegroup: gpu` label in the node objects the collector saved;
- the script sha256 equal to the sha256 written in the registration, so the code that ran is the code that was approved.

A missing field fails the criterion, as everywhere in this analyzer. Each criterion is shown red by a fixture that removes or falsifies only that field, and the `gloo` profile's existing behaviour is pinned unchanged.

### 5. Two training nodes in the session, with gates that read what they gate

`TRAIN=ddp` in `hack/eks-gitops-session.sh` passes `gpu_node_instance_type = g5.xlarge` and `gpu_max_nodes = 2` to Terraform, scales the `gpu` node group to 2, and runs under the same deadline, residue checks and teardown as the serving card.

- **Only on a cluster it creates.** Training mode refuses before `terraform apply` unless the cluster does not exist (`aws eks describe-cluster` answers `ResourceNotFoundException`), and refuses `KEEP_UP=yes`. On an existing cluster the `gpu` group was created with the queuelab default `g4dn.12xlarge`; changing its instance type forces a replacement, and with a fixed group name that replacement can fail partway, before any gate runs. A fresh cluster also means no ClusterQueue, policy or status in it predates the session, including the two `trainingQuota` sample policies an earlier manual sync could have left.

- **Every node, not the first.** The session waits for two nodes of the `gpu` group to join, and qualifies each by name: Ready, the device plugin Running on it, `nvidia.com/gpu: 1` allocatable. It refuses to start the job until both qualify, and a deadline that passes with one stops the session.
- **The price gate reads the right price.** The `gpu` group is On-Demand, so the gate reads the On-Demand list price of g5.xlarge in the region from the AWS Price List API and refuses above a ceiling. The Spot gate stays for the serving card.
- **The quota gate reads headroom.** Before scaling, the session reads current usage of "Running On-Demand G and VT instances" (`L-DB2E81BA`) from its CloudWatch usage metric and refuses unless usage plus the 8 vCPU it will add fits the quota.
  The metric is sampled, so the gate takes the maximum over the last fifteen minutes and refuses when there is no datapoint; it is a check against a stale picture, not a reservation, and another launch between the read and the scale-up can still take the headroom. The per-node qualification is what then shows the capacity arrived. `terraform_data.gpu_quota` keeps checking the configured worst case.
- **`gpu_max_nodes` must be an integer**, by a validation added beside the existing range check.

**What can be tested for free, and what cannot.** The session runs `terraform apply` before any of these gates, so a test that runs the whole script cannot reach them without spending. The gates and the two-node scale-down are therefore written as functions in a file the session sources, `hack/lib/train-session.sh`, and tested by calling them directly, with `aws` and `kubectl` replaced by stubs that answer per scenario and record every invocation's arguments:

- each refusal reached by its own scenario: price above the ceiling, a missing price, usage with no headroom, no usage datapoint, one node of two qualified at the deadline, a node without the device plugin, a fractional or out-of-range node count;
- the scale-down recorded as `update-nodegroup-config` on the group `gpu` with desired size 0, and both instances followed to `terminated`, so a scale-down that targets the wrong group or follows one instance fails.

Terraform is stubbed by none of this, so `terraform apply` and `destroy` in training mode are exercised only by the paid session, as they are for serving today. v1 called the rehearsal hermetic; it is not, and the existing teardown replay, which answers canned responses and records nothing, is not extended to claim otherwise.

### 6. A training namespace with quota, and what the quota does not bound

`config/training/`: namespace `train-a` and a GPUQuotaPolicy with `trainingQuota: true` and `limits.gpuCount: 2`, which makes the controller create ClusterQueue and LocalQueue `gpu-train-a`. A manual Application, as `config/serving/` is, synced by the training mode.
That ClusterQueue joins the shared cohort `gpu-platform` with reclaim, so `gpuCount` is an admission quota, not a ceiling: within a cohort it can borrow. On the fresh cluster training mode requires, the session checks that `gpu-train-a` is the only ClusterQueue, so nothing is lent to it.
What bounds the GPUs bought is not the quota and not `max_size` alone. `max_size` of 2 bounds a scale-up, but a managed node group's version or launch-template update raises the group's size temporarily to launch replacements first; the session starts no such update. So the bound is: two nodes, because the session scales to two and never updates the group, checked by the instance IDs it records launching in the group and follows to termination. A third instance in the record is a finding, not a rounding.

## Evidence before any money

- envtest and the full `go test ./...`: the operator is unchanged and stays green.
- The Kueue manifest, image and CRD-schema tests, the `ignoreDifferences` test, the analyzer's `nccl` criteria, the `train.py` unit tests and the session's new refusals: each shown red by a mutation of the thing it pins.
- On kind with Argo: the rehearsal in section 1, then a `worldSize: 2` job admitted and its Pods observed carrying the toleration and the node selector, on the labelled tainted worker.
- The `gloo` arms of `experiments/multi-pod-ddp/` rerun unchanged and pass.

## What it would license

Nothing by itself: it makes a paid NCCL run possible and scoreable. That run, its registration, its smoke cell and its budget come after this, with the owner's approval.
For that budget: two g5.xlarge On-Demand at $1.237 an hour each, the cluster at about $0.26 an hour, and the CUDA image pulled once per node through the NAT, a few GB each at $0.059 a GB.

## Out of scope

The paid run; moving the operator to Kueue `v1beta2`; more than one GPU per Pod; a launcher such as `torchrun` across nodes; gang scheduling; and the `gpu_shared` group.

## The review that parked v1 (codex `gpt-6-astra`, 2026-10-16), and where v2 answers it

| finding | severity | v2 |
|---|---|---|
| v0.18.3 ships eleven CRDs, `config/kueue-crds/` holds four; a controller without the rest does not run | blocker | §1: the whole release by one Application; the four stay as fixtures |
| the vendored CRDs store `v1beta1` with `conversion: None`, upstream stores `v1beta2` with conversion webhooks; equality fails and envtest fixtures depend on the difference | blocker | §1: per-version schema equality, with storage and conversion named as the allowed difference |
| nothing makes the scorer require NCCL, CUDA devices or distinct GPUs; the current analyzer still passes with backend and device evidence removed | blocker | §4: the `nccl` profile, each criterion shown red |
| Kueue's own certificate management writes into objects two Applications would own; no drift strategy | major | §1: one owner, and `ignoreDifferences` on the fields Kueue writes |
| `kustomize build` does not rehearse Argo ownership, health, ordering or self-heal | major | §1: rehearsed under Argo on kind, with self-heal and a quiet period |
| a toleration admits the taint but selects no node group, card or distinct node | major | §2: `nodeLabels` on a training-only label of the `gpu` group; §4: distinctness checked by the analyzer |
| the session qualifies one joined node (`head -1`); a second may never arrive | major | §5: both nodes qualified by name, or the session stops |
| the price gate reads Spot; the `gpu` group is On-Demand | major | §5: the On-Demand list price |
| the quota guard checks configured demand, not remaining headroom or GPU suitability | major | §5: current usage plus 8 against the quota; suitability is the per-node qualification |
| Terraform apply bypasses an `aws` stub, so the proposed rehearsal is not free or hermetic | major | §5: the claim is narrowed to the refusals and the teardown replay |
| a self-hash identifies the script; nothing checks it against an approved one | major | §4: the hash is compared with the registration's |
| a CPU refusal test does not exercise the CUDA path | major | §3: fake-CUDA unit tests, and the paid run's smoke cell, said as such |
| `limits.gpuCount: 2` joins a shared cohort with reclaim; not a hard ceiling | major | §6: named as an admission quota; the ceiling is `max_size` |
| fractional `gpu_max_nodes`, an argument size bound, image-pull cost, the canary claim's scope, the Application's real name | minor | §5 integer validation; facts (25 KB); budget note; §2 canary scope; the Application is `kueue-crds`, replaced |

## The review of v2 (codex `gpt-6-astra`, 2026-10-21), and where v3 answers it

Every finding was re-checked against the file it cites before it was accepted; all nine held.
The same review re-scored the CPU experiment's evidence with the backend, device, UUID and hash fields removed and still got four PASS results, which is v1's third blocker reproduced, and found all eight fixture schemas equal to v0.18.3's.

| finding | severity | v3 |
|---|---|---|
| the replacement Application drops `ServerSideApply=true`, without which the Workload CRD exceeds the annotation limit | major | §1: kept, with the reason |
| "every Application Synced and Healthy" cannot hold: the rehearsal judges automated Applications only, and manual ones stay unsynced | major | §1: judged over automated Applications, the manual ones named |
| the GPU label on a kind worker schedules the real NVIDIA plugin, which fails without a GPU | major | §2: a training-only label |
| the session applies Terraform before the new gates, so a whole-script test is not free; the teardown stub records nothing | major | §5: the gates as sourced functions, tested with recording stubs |
| "every session builds a fresh cluster" is not enforced; `KEEP_UP=yes` exists | major | §1: the switch is made safe on an existing cluster and observed in the rehearsal |
| `gpu_single` at desired size 0 does not prove its node is gone | major | §2: the training label is on `gpu` nodes only |
| operator Ready is `healthz.Ping` and proves nothing about its Kueue cache | major | §1: `gpu-train-a` `Active`, then the job's admission |
| a conversion-webhook outage was described as an index failure | minor | §1: the two failure stages separated |
| v0.18.3 is chosen, not required: v0.19.0 also serves `v1beta1` | minor | facts: reworded |

Also raised as unverified, and answered: the quota metric's freshness (§5: maximum over fifteen minutes, refusal without a datapoint, named as no reservation) and the `nccl` profile against negative arms (§4: its criteria apply to completing arms only).
The release asset's bytes, which astra could only hash from a cached copy, I downloaded fresh on 2026-10-21: sha256 `d605eec48cc2c557ba5f3f66111af1f1265368dab1497eacc2292a140b023737`, the same.
Still unverified, and left to the paid run's registration: the CUDA image's digest, pull size and NCCL behaviour.

## The review of v3 (codex `gpt-6-astra`, 2026-10-21), and where v4 answers it

Each finding was re-checked: the `gpu` group's default type is `g4dn.12xlarge` (`infra/aws/cluster/variables.tf`), and the operator stamps `admittedAt` from the Workload it reads. The same review re-verified the CPU evidence's blind spot, the eight schemas, the five conversion CRDs, and the cached release's sha256.

| finding | severity | v4 |
|---|---|---|
| on an existing cluster, changing the `gpu` group's instance type forces a replacement that can fail before any gate | major | §5: training mode refuses unless it creates the cluster, and refuses `KEEP_UP=yes` |
| `max_size = 2` is not a hard ceiling: a managed node group update launches replacements first | major | §6: the bound is the session's scale-up with no group update, checked by the recorded instance IDs |
| Kueue admits and unsuspends a Job without the operator, so admission does not show the operator's cache works; `Active` can predate the session | major | §1: the operator's `admittedAt` stamp, equal to the Workload's condition, on a cluster the session created |
| "the only training tenant" is not guaranteed: sample policies from an earlier manual sync | minor | §5 and §6: a fresh cluster, and `gpu-train-a` checked to be the only ClusterQueue |
| "every training image installs the CPU wheel" is too broad: the MLTrainingJob sample names a CUDA image | minor | gap 3: narrowed to the experiments' images |

Confirmed by the same review: Kueue v0.18.3 does copy a flavor's tolerations into the Job's Pod template before unsuspending it, and nothing in the operator or its webhooks strips or refuses them.
