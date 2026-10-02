# gpu-platform-control-plane

Kubernetes-native control plane that manages GPUs as a platform resource.

## Overview

Most GPU setups stop at running a single workload. This project treats the GPU as a shared platform resource, covering node readiness, multi-tenant quota, serving, and training through one Kubernetes-native control plane.

## The measurement, first

The control plane is the instrument. This is what it measured on a rented A10G under the **frozen execution
contract** — ten cells, five repetitions per arm, 2026-10-01:

| Arm | Victim TTFT p99 (median of 5) | vs isolated | Premium completed | Timeouts |
|---|---:|---:|---:|---:|
| Isolated (`R1`) | 174 ms | 1.0x | 23,275 / 23,275 | 0 |
| One engine, both tenants (`shared`) | 3,998 ms | **23.0x** | 23,274 / 23,275 | 0 |

**One competing tenant on the same card takes the victim's tail from 174 ms to four seconds, while total
output throughput stays level — 589.2 against 589.3 tok/s.** The latency cost is not confined to the tail:
the median also rose, 87.8 ms to 161.3 ms (1.84x), and the damage grows with the percentile (p95 16.4x,
p99 23.0x). The mechanism is that one contending prompt occupies the engine far longer than the victim's
tail budget, so what has to be divided is not the card — it is a request already in flight.

**The load, stated because it moves the number.** Premium prompts of 1,174 characters, which the served
tokenizer counts as **256 tokens** — the value `baseline.inputTokens` declares — and contender prompts of
42,579 characters at **8,192 tokens**. Rate 9.4045/s, 505 s per cell, seed 11, `timeoutMs` 60,000.

**What this run does not say.** It bought no split-card arm, so it makes no claim about `timeSlicing`.
It publishes **no confidence interval**: five repetitions of one trace show repetition stability under one
fixed load, not variation over loads, seeds or machines. The five per-repetition ratios are
22.96 · 23.01 · 22.95 · 22.93 · 22.97 — an **observed range, not an interval**. The p99 is over *completed*
premium requests, and one of `shared`'s 23,275 did not complete: an HTTP 502 in repetition 3.
Three ratios can be formed from this evidence and they differ in the fourth significant figure, so the one
being quoted has to be named. The registered estimand is the ratio of per-repetition medians: under the
registered rounding that is `3998/174` = **22.977**, and at raw precision the same medians give **22.969**.
The **pooled-request** ratio is **22.972**, and it is the one the pre-registered reading 4 computes -- its
aggregation was never specified, which [a dated post-hoc
amendment](docs/superpowers/specs/2026-09-10-does-splitting-the-card-buy-protection.md) records rather than
settles retroactively. "About 23.0x" is the only summary that does not depend on the choice.

### The earlier three-arm pilot, and why it is not the headline

A ninth paid pilot (2026-09-13, `hack/m5c-20260913-011031`, commit `85ae2fa`) bought three arms at two
repetitions each and is **the only run here that measured a split card**:

| Arm | Victim TTFT p99 | vs isolated | Contender served | Timeouts |
|---|---:|---:|---:|---:|
| Isolated (`R1`) | 69.5 ms | 1.0x | — | 0 |
| One engine, both tenants (`shared`) | 1,892.2 ms | **27.2x** | 278/278 | 0 |
| Two engines, half a card each (`timeSlicing`) | 1,007.5 ms | **14.5x** | 278/278 | 0 |

**Splitting the card halved the victim's tail and the contender still finished all of its work — it paid in
latency instead.** Both sharing modes missed a pre-registered 2x bar at that load, and on a ladder holding
the contender byte-identical the same `timeSlicing` arm *passes* at 1.16 and 2.31 requests a second and
breaches at 4.61.

⚠️ **A five-repetition run at the longer prompt reversed that arm, and the reversal is published.** On
2026-10-02 the same three arms were bought again — fifteen cells, `hack/m5c-20261002-014903`, commit
`b97d88e` — and `timeSlicing` came back at **14,868 ms against `shared`'s 4,001**, which is 3.7x *worse* than
the control it beats in the table above. The answer changed from `5 (timeSlicing)` to `3`
(**INCONCLUSIVE**). The arrival schedule was identical; the premium prompt was **294 tokens instead of 50**
and the timeout 60s instead of 30s, which is the leading explanation and is not separated from the timeout
change. So the row above is **one load's result**, and what the later run adds is that a different load gave a
different answer — not a measurement of how the answer varies with load, and not a demonstration that this row
is unstable. See `docs/superpowers/specs/2026-09-10-does-splitting-the-card-buy-protection.md`, "The result,
2026-10-02".

⚠️ **That pilot ran a different load, and the two tables must not be combined.** It predates the input-length
resolution: its premium prompts were 200 characters — the generator's flag default, which the tokenizer
counts as 68 tokens and which corresponds to no `inputTokens` declaration at all — with `timeoutMs` 30,000
and two repetitions. Dividing 23.0x by 14.5x, or reading 27.2x against 23.0x as an effect of the
calibration, would be an unregistered comparison. The seventh amendment to the design spec records what is
frozen now and why.

### Can a reader check this?

Both tables were recomputed from their runs' raw rows with the command the harness ships:

```
go run ./cmd/benchharness report $(for f in raw-*.jsonl; do echo --raw $f; done)
```

**The sample behind each tail is published, not just the tail.** The registration requires it — a pooled
p99 hides how many repetitions it came from, and five tight ones mean something five scattered ones do not:

| arm | per-repetition premium TTFT p99 (ms) | median |
|---|---|---:|
| `R1` | 174.078 · 173.832 · 174.297 · 174.387 · 174.034 | **174.078** |
| `shared` | 3996.117 · 4000.349 · 4000.510 · 3998.338 · 3997.887 | **3998.338** |

The median of each row is that arm's registered point estimate, and their ratio is the registered object.
The spread of a row is an **observed range, not a confidence interval**. Under the registered rounding the
ratio is 3998/174 = 22.977; at raw precision the same medians give 22.969, and the pooled-request ratio
is 22.972. The three are named where the table is introduced, because reading 4 computes the pooled one.

⚠️ **The rows are not in this repository; they are attached to a release.** One line in `.gitignore` excludes
the directory a paid run writes, and the evidence is carried in a sibling **private** repository that also
holds the engineering journal, the defect records and the cost ledger — working notes rather than
portfolio material. The rows are 15 MB and 29 MB; 900 KB and 1.8 MB compressed, so size was never the
reason.

Two things are public, and they do different work. The **commitment** is every evidence file's sha256 in
[docs/12_EVIDENCE_CHECKSUMS.md](docs/12_EVIDENCE_CHECKSUMS.md), published before anyone asked for a copy: a
hash cannot be reversed, so it reveals nothing, but it fixes *when* the claim was made. The **download** is
two archives attached to [the evidence release](https://github.com/lkhun9311/gpu-platform-control-plane/releases/tag/evidence-m5c-2026-10-01), which a hash cannot substitute for — `hack/verify-published-evidence.sh`
recomputes every published figure from them without a GPU and exits 0 only if all of them match. The ten-cell
download is a derivative: two files have an account identifier and a GPU UUID masked, two are withheld, and
`docs/12` lists which, so its digest is a new one rather than the committed `92d54eb3…`. The evidence also carries its own inner chain: every raw row
names the trace checksum it was replayed from, and every manifest names the prompt corpus that trace was
cut from, so a *sample* of rows is enough to establish provenance.

A reader who never asks still takes the figures on trust, and that is narrowed rather than removed. The
stronger guarantee is the pre-registration: the load, the rounding, the percentile convention and the
readings were frozen in dated amendments before the run, and `hack/m5c-gpu-session.sh` buys the whole thing
again from a commit.

The findings, their bounds, and the claims this project is **not** entitled to make are in
[docs/11_WHAT_THIS_MEASURED.md](docs/11_WHAT_THIS_MEASURED.md); the mistakes are in
[docs/10_WHAT_I_GOT_WRONG.md](docs/10_WHAT_I_GOT_WRONG.md).

⚠️ **A CR declared the load above; nothing has written its `status.result`.** The distinction matters
and this paragraph used to collapse it. `benchharness compile-plan` turned
`config/samples/platform_v1_gpusharingbenchmark_executable.yaml` into the environment the runner reads, the
instance logged `load compiled from a GpuSharingBenchmark, sha256 304fe77c…`, and
`hack/m5c-matrix.sh:163-186` refuses to start if any value the CR declared is missing from that block. So the
CRD is the *declaration* the table above was measured under. What it is not is the *recorder*: no controller
writes `status.result`, so the numbers reach a reader through a report rather than through the type's own
status. That gap is the honest state of the flagship, and
[the record of what blocks it](docs/superpowers/specs/2026-07-04-gpusharingbenchmark-crd-design.md) names three
bindings rather than a missing afternoon of work.

**Two paid runs on 2026-10-01, and the first one failed.** The morning run compiled the same CR at commit
`471b86b`, completed **cell 1 of 10**, and then **stopped itself on a cell boundary**: measured cell time was
15.7 min against the runner's assumed 10, so ten cells need about 212 min and the deadline was 160. It cost
**$0.25** and bought one cell, not a comparison. The afternoon run, after the deadline and the credential
guard were both derived from the matrix's own stopping rule, completed **10 of 10 cells** in about 126
minutes for **$1.44** — commit `7b69214`, and the table at the top of this file is that run. Total spend for
the pair: **$1.69**.

Both commits are the tree the evidence was **collected** from, which each run's archive records in its own
`commit.txt`. Neither is the version that **analysed** it: the figures quoted here were recomputed later,
and the analysis version is not pinned anywhere yet. `hack/verify-published-evidence.sh` already
distinguishes the two — it reads the archive's `commit.txt` and accepts an `ANALYSIS_COMMIT` to require a
specific scorer — so what is missing is the decision about which value to pin, not the machinery.

⚠️ An earlier version of this section ended **"the table above is still the ninth pilot's"**, which stayed
true for exactly as long as the morning failure was the only CR-driven run. It was left standing after the
afternoon run replaced the headline, so the file said the measurement was from 2026-10-01 at the top and from
2026-09-13 here. The correction is recorded rather than quietly applied, because a reader who saw the old
text should be able to tell which sentence moved.

## Scope

The control plane is organized into the following areas:

The **State** column is the point of this table: several areas below are designed and written up but have
no code in this repository, and saying which is which is more useful to a reader than a uniform list.

| Area                   | What it does                                                                                     | State |
|------------------------|--------------------------------------------------------------------------------------------------|-------|
| Node readiness         | Mirror a Node's `Ready` condition into a `NodeHealth` CR and taint on degradation                | Built — but the CR is hand-created, and there is **no GPU-specific fault detection** (no DCGM, Xid or ECC) |
| Multi-tenant quota     | Sync an aggregate per-tenant GPU ceiling from `GPUQuotaPolicy` into a namespace `ResourceQuota`, or into a Kueue `ClusterQueue` for training, and supply the gateway's rate limits | Built. There is no isolation policy in the type — the earlier wording said so and the API has never had one. `spec.gpuClass` is recorded and **not** enforced per class: one aggregate `requests.nvidia.com/gpu` key is capped regardless of class |
| Inference serving      | Manage serving workloads declaratively via `InferenceDeployment`                                 | Built |
| Training admission     | Translate `MLTrainingJob` into queued `batch/v1` Jobs admitted through Kueue (M6)                | Built. It also reports what the tenant waited: `admitToRunningSeconds` on the CR and a histogram beside it, and it refuses the window when Kueue carried no usable stamp, when it never saw the admission, or when the interval comes out negative. **It does not establish continuous observation**: if the admission stamp was persisted and this controller was then down while the Pod became ready, the next transition it sees subtracts the stamp from `now` and publishes a figure that includes the downtime, with `Observed=True`. What the field means is admission to *first observed* readiness |
| Gateway                | Tenant-aware serving gateway: API key → tenant, token bucket, model routing, proxy, metrics      | Built, unit-tested and **deployed on kind** — in front of a stub backend ([observability](hack/observability-kind.md), [chaos](hack/chaos-fr002-serving-pod-killed.md)), driven by the benchmark harness through its real pipeline with no GPU ([path](hack/m5b-gateway-path.md)), chained to a real vLLM running on CPU ([chain](hack/m5b-chain-live-evidence.log), where the `InferenceDeployment` is a routing record and not a vLLM deployment), and deployed into the kind cluster of the paid A10G sessions. **Deployed to EKS through the GitOps path on 2026-09-25** — Argo CD installed by its own Terraform root, `config/argocd/root.yaml` applied, and the gateway it deployed answered `/readyz` 200, refused an unregistered key with 401 `unauthorized`, and accepted a key from the Secret with 403 `no_policy`. That is authentication reaching the key store, **not** proof of serving: no backend was deployed, and `device-plugin`, `observability` and `samples` are manual and stayed `OutOfSync`, so the claim is about the automated baseline ([pre-registration and result](docs/superpowers/specs/2026-09-25-gitops-rehearsal-on-clean-kind.md)) |
| Admission guard        | KV-cache-aware three-arm admission guard and open-loop benchmark harness (M5-b)                  | **Built and measured on a paid GPU.** The guard missed its pre-registered 1.25x premium-tail target at 83.7x over four repetitions, and the harness declared the run invalid rather than reporting a protection claim. Re-analysing the same rows at no further spend then found the occupancy signal the milestone was named for had been unreachable by construction and never fired at all ([write-up](hack/m5d-writeup.md), [analysis](docs/superpowers/specs/2026-09-04-the-layer-not-the-signal.md)) |
| Performance isolation  | Measure multi-tenant noisy-neighbor p99 contention under GPU sharing                             | **Measured on a rented A10G — the table at the top of this file.** Under the frozen contract the victim's TTFT p99 is **23.0x** its isolated value with one shared engine, five repetitions, 23,274 of 23,275 premium requests completed, no interval published. The **split card** was measured only by the earlier three-arm pilot, at a different prompt length and timeout: 27.2x shared and 14.5x split, two repetitions ([pre-registration and result](docs/superpowers/specs/2026-09-10-does-splitting-the-card-buy-protection.md)). Nine paid pilots and six capacity-ladder sessions produced it. What is **not** built: the `GpuSharingBenchmark` CRD registers the protocol and refuses a badly declared one, and nothing writes its `status.result` — so the numbers are a harness result rather than a control-plane one. The defects the instrument had before it could be trusted are counted in [docs/10](docs/10_WHAT_I_GOT_WRONG.md) rather than here |
| Paid-run harness       | Pin what a GPU-renting script does before it can be run against a card                            | Built, and enforced: `make spot-lifecycle` is a prerequisite of `make infra-validate`, which CI runs. Four runners, 64 recorded scenarios plus one source-order assertion — 65 checks (counted from the `run_scenario` calls per `scenarios_*` function: 16 microtest, 11 price-of-protection, 19 m5c, 18 queuelab, and the single assertion at `characterize.sh:881`; two earlier figures in this row, 53 and 72, were both wrong): every scenario runs the real script with `aws` and `sleep` replaced by recording stubs and diffs the AWS calls, exit status, messages and run-directory contents against a golden. It pins the **host** side. What it cannot tell — whether a cluster then comes up — is covered separately by two rehearsals that run for real on a local kind cluster: `hack/test/rehearse-bringup.sh` extracts the GPU-free span of a session's user-data, and `hack/test/rehearse-m5c-matrix.sh` runs the M5-c matrix itself with stub engines and simulated devices |
| Failure & recovery     | Inject failure scenarios and record an operational evidence trail                                | Built — `WorkloadRun` CRD, controller and driver — and **run for real**: deleting a serving Pod produced a trail nobody wrote by hand, and the run exposed a defect envtest could not. Two of three scenarios are recordable ([evidence](hack/m6-kind-e2e.md)) |
| Ledger                 | A SQLite ledger projecting CR/status/events                                                      | **Storage, projector, reader and a CLI** — 2 of 6 tables. `cmd/platformctl` dispatches `workload-runs project`, `list` and `get`; the earlier "no command yet" was stale. **It has now projected a cluster**: one `WorkloadRun` from an M7 run, `seen=1 written=1 events-new=3`, and a second pass reported `events-already=3` so the idempotence is measured ([record](hack/ledger-first-projection.md)). Four of the six tables still do not exist, and nothing runs the projector on a schedule |
| CLI                    | A `platformctl` CLI                                                                              | **One command group only** — `workload-runs project\|get\|list` against the ledger; nothing else |

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
| [M5-a](https://github.com/lkhun9311/gpu-platform-control-plane/releases/tag/m5-a-hosting) | AWS hosting: Terraform state bootstrap, EKS, OIDC CI → ECR, Argo CD GitOps, ephemeral apply/destroy with a TTL kill switch | Code done and offline-validated. **`bootstrap` is applied** (state bucket, KMS key, OIDC provider, CI roles, ECR, budget). **`cluster` is not applied now, and has been applied before** — the first attempt, on 2026-08-31, failed on all four node groups against an SCP that denied every `ec2:CreateLaunchTemplate` in the account (`infra/aws/org/scp/README.md`), and the remote state held resources until they were removed on 2026-09-03. On **2026-09-18 it was applied and destroyed in one deliberate cycle**: 96 resources created, one t3.large and **no GPU instance**, then a hand-dispatched teardown that destroyed all 96 and left nothing behind that a check by resource ID could find ([record](hack/eks-cluster-cycle-20260918.md)). The runner could not reach the API, so the two ordered Argo steps were skipped — nothing was lost because no Argo CD was installed. **That path was tested on 2026-09-25**: a second cycle installed Argo CD from `infra/aws/argo-bootstrap`, applied the GitOps root, met all six pre-registered bars and destroyed the cluster 25 minutes later at about $0.26/h, and the teardown was confirmed by asking EKS, EC2, Auto Scaling and ELB **by hand afterwards** — the session's own verdict was a FAIL it should not have reported, because it compared a tag listing that still named resources the EC2 API had already dropped. The seven-service check now in `hack/eks-gitops-session.sh` is the fix that followed, and it has not yet run against a live teardown ([record](docs/superpowers/specs/2026-09-25-gitops-rehearsal-on-clean-kind.md)) |
| [M5-b](https://github.com/lkhun9311/gpu-platform-control-plane/releases/tag/m5-b-admission-guard) | Three-arm KV-cache-aware admission guard measured on a paid GPU, with an open-loop harness whose pre-registered checks withheld the protection claim. The guard missed its 1.25x premium-tail target at **83.7x** over four repetitions and the run was declared invalid. Re-scoring the same evidence later, at no further spend, showed the arm that matched isolation's tail had admitted **none** of the contending tenant's work — because its bucket was configured smaller than the contender's prompt, which a tail-only reading would have reported as the best result in the study | **Run.** Four paid repetitions 2026-09-03, engine-level scheduler microtest 2026-09-04. A negative result with a measured mechanism ([pre-registration](docs/superpowers/specs/2026-09-05-the-price-of-protection.md)) |
| M5-c | Cost/fairness frontier and sharing-mode matrix (exclusive / time-slicing / MPS) — hardens the M5-b evidence | Card chosen by arithmetic rather than by preference: `SharingPlan.Validate` refuses a T4, which leaves each engine 284 KV tokens against a 7,695-token prompt. All three arms' manifests and the run script are written. **Run on rented cards nine times from 2026-09-10, and "tested" was the wrong word for them before that** — this line said "written and tested" until 2026-09-10, when reading the runner, rehearsing it against a kind cluster, writing the code for its own readings, running the runner itself, and then attacking the result with a second engine and a mutation battery found 37 defects — among them that neither sharing arm could deploy at all (both overlays targeted a namespace nothing creates), that the control arm had no device plugin, that one pre-registered reading was unreachable because an earlier one subsumed it, and that a port-forward race left two of four arms completing nothing while the report called the result a censored tail. All 37 are fixed and each is pinned by a test that was deliberately broken to confirm it fires. That 37 counts this pass only — the pilots that followed found defects 41 through 56, sixteen more, fixed the same way. Three of the last thirteen were in the readings themselves, computing a quantity the pre-registration had not asked for while every unit test stayed green. Its deferral used to be justified by device attribution, which was never the obstacle — `hack/m5c-matrix.sh` deliberately runs no observer on the sharing node. The real reason was that its `shared` arm is M5-b's topology on an engine whose budget and policy were unsettled, and those are settled now. **Pre-registered 2026-09-10** against the same bars the previous study used, carried forward rather than chosen, with the outcome space the last one left uncovered closed in advance ([pre-registration](docs/superpowers/specs/2026-09-10-does-splitting-the-card-buy-protection.md), [sizing](hack/m5c-sharing-sizing.md)) |
| M5-d | Technical write-up with the measured numbers | Reasoning, pre-registered checks and stated limits were written BEFORE the run so they could not be fitted to it, and the markers are filled from paid evidence. **Closed on a measured negative.** A successor study then took the same question to the engine's own scheduler — eight configurations, three repetitions, no timeouts — and the best of them holds the premium tail at **20.7x** an isolated baseline against a 2x bar, with its median missing by 2.8x. A contending prompt occupies the engine for about a second and the tail budget is a tenth of that, so dividing the work does not divide the machine ([write-up](hack/m5d-writeup.md), [result](docs/superpowers/specs/2026-09-08-the-load-needs-an-upper-gate.md)) |
| [M6](https://github.com/lkhun9311/gpu-platform-control-plane/releases/tag/m6-training-admission) | Training admission: `MLTrainingJob` → Job + Kueue Workload; two-tenant cohort borrowing and quota-reclaim preemption, run end to end on kind | Done ([evidence](hack/m6-kind-e2e.md)) |
| [queuelab](https://github.com/lkhun9311/gpu-platform-control-plane/releases/tag/queuelab) | Queue-policy measurement lab: censoring-aware list/watch lifecycle ledger replayed against real Kueue | Withdrawn once, re-measured, then observed on hardware. Twelve kind runs the runner's own gates accept ([result](hack/queuelab-reclaim-first-result.md)) carried the banner `device: NOT OBSERVED`, so every GPU-second in them is a second of reservation. A $3.90 session on four A10Gs then ran eight more, all accepted by `-require-device`, and **`queuelabrun -compare` prints its comparison without that line**. Owner wait separates by 28.8 s there against 29.0 s on kind, so the result survived its own instrument. A second study then separated **reservation from use**: two sets of runs reserved 51.084 and 50.802 GPU-seconds — the same to within a twentieth of their floor — while the card did 48.115 and 12.193 observed device-seconds, a factor of four with every reservation-based figure unchanged ([observation](docs/superpowers/specs/2026-09-05-the-device-was-never-observed.md), [idling](docs/superpowers/specs/2026-09-06-does-reservation-track-use.md), [runner](hack/queuelab-gpu-session.sh)) |
| M7 | Inject failure scenarios and record an operational evidence trail (`WorkloadRun`) | CRD, controller and a single-controller driver, tested on envtest; the trail refuses rather than concludes when it has a hole. `hack/m7-evidence-trail.sh` **has been run**: a real Pod deletion produced Ready → Pending → Ready in a trail nobody wrote by hand, and the run exposed a defect envtest could not (recovery credited to the healthy state the run began in). **DegradedNode has now been recorded too**: a throwaway kind cluster with a worker is the machine whose disruption nobody minds, and stopping that worker's kubelet produced `Ready → Quarantine → Ready` at 0s, 46s and 48s with the verdict `Recovered` — every phase published by the operator rather than by the script. **BackendFallback** was removed from the type because what it injects and what a `WorkloadRun` observes are different things: a backend there is a whole `InferenceDeployment`, and the scenario removes the head one so a second absorbs the traffic, which shows up in the gateway's fallback counter rather than as one target returning to health. (The reason given here until 2026-09-27 — that a scaled-to-zero backend reports Ready and so is invisible — was corrected when a security review showed that blind spot was also an exploit: editing a target's replicas to 0 mid-run turned an observed failure into `Recovered`. The watcher now requires a ready replica.) |

**What has not been exercised.** Every GPU in the kind clusters is simulated by a fake device plugin, and
most of this repository has only ever met one of those. More than thirty paid EC2 sessions did not — 31 run
directories under `hack/` carry an instance id and the earliest sessions predate that convention — across
M5-b, M5-c, the capacity ladders, the price-of-protection sweep and queuelab. The State and Status columns
above say per row which is which rather than leaving
it to be inferred. This paragraph used to say nothing here had ever run against real hardware, which
contradicted the two rows directly above it. Two distinctions worth stating plainly, because they are easy
to blur:

- The admission guard and its benchmark harness **have** seen a GPU: four paid repetitions on 2026-09-03,
  which is where the numbers in the M5-b and M5-d rows come from. The sentence here used to say they never
  had, and that was written before the run and not updated after it. What preceded the run still stands: the
  metrics fixture is a real capture from the pinned vLLM image and replaced a synthetic one whose
  assumptions it falsified; the guard has been driven through engage and release against a running vLLM; and
  the whole chain — harness, gateway, engine — has carried a request and returned a `kv_cache_pressure`
  rejection ([evidence](hack/m5b-chain-live-evidence.log)). That chain work was on a CPU build, where the
  engine queues before its cache fills, so it exercised the WAITING arm of the engage condition and not the
  KV-usage arm. **The paid run did not exercise the second one either** — this line used to say it did, and
  `hack/m5d-writeup.md` contradicts it: the occupancy limb was unreachable by construction (a 386,912-token
  cache against a 7,695-token prompt), and all of that run's refusals came from the waiting-queue limb.
- The contention benchmark is **not coded at all**. It is a design document. Earlier revisions of this README
  described it as if it existed; that was wrong.
- The SQLite ledger and `platformctl` were in that sentence until 2026-09-27 and are no longer: `internal/ledger`
  holds migrations, an idempotent projector and a reader for **2 of the 6 designed tables**, and
  `cmd/platformctl` can project from a cluster and read back what it recorded. The other four tables do not
  exist, and no run has been projected outside a test.

**Flagship benchmark:** KV-cache-aware noisy-neighbor p99 protection — a real-GPU benchmark that compares premium tenant latency under baseline, colocated long-context noisy-neighbor, and Gateway admission-guard modes. It **has** been run on a GPU, and the numbers are a negative result the pre-registered checks refused to call a win: premium TTFT p99 of 82.2 ms isolated against **6,882.0 ms** under the guard, missing the 1.25x target at 83.7x, and the run declared invalid ([write-up](hack/m5d-writeup.md)). This line used to say there were no numbers; there are, and they say the guard did not work.

## The queuelab reclaim result: withdrawn once, and now re-measured

On 2026-08-02 this repository published a live measurement of Kueue quota-reclaim preemption. **It was wrong
and it was withdrawn.** The experiment has since produced a result the runner's own gates accept: twelve
runs, two per cell across two dose regimes, two arms and two workers, carrying
`verdict: admissible-under-implemented-gates` with no failed claims.

Honouring SIGTERM under reclaim discards the work in flight; ignoring it discards none and converts the
victim's remaining service into the quota owner's waiting time, with the preemption recorded as ineffective.
Both arms reproduce across their two runs.

The magnitudes are NOT restated here, deliberately: they were, and they drifted -- this paragraph claimed
four runs after the set had grown to twelve. The result page carries them and is re-derivable from the
records with `queuelabrun -compare`.

What the result supports is a MODEL, `held = min(remaining service, grace)`, checked in both dose regimes
and at the kink between them, rather than any single figure: the owner's wait responds to dose by twelve
seconds across two levels, so it is not a property of the platform and must not be quoted as one. The
honouring arm's own hold measures below the harness's resolution floor and is reported as unresolved rather
than as a small number. Every ledger time is when a watch event ARRIVED, and the gap to the kubelet's own
stamp bounds what is resolvable at all. The GPU is simulated, so these are seconds of RESERVATION and the
records say so. Details, and what the result does not support, are in
[hack/queuelab-reclaim-first-result.md](hack/queuelab-reclaim-first-result.md).

Three of this platform's defences were broken the same way — each expressed a guarantee in terms of a field
the tenant writes — and each was found by attacking it rather than reading it:
[hack/tenant-writable-fields.md](hack/tenant-writable-fields.md).

**The result that survived contact with review** is the other regime. An unresponsive workload defeats
quota reclaim completely while its remaining service fits inside the Pod's termination grace period — it
finishes, nothing is discarded, and the owner waits the whole of that service with the preemption recorded
as ineffective. Once remaining service exceeds grace, it is killed at exactly the grace boundary. So
`terminationGracePeriodSeconds`, set per Pod by the tenant being preempted, is the bound on how badly a
quota-restoration promise can be broken:
[hack/queuelab-grace-boundary.md](hack/queuelab-grace-boundary.md).

What follows is the account of the withdrawn one, kept because the reason it was wrong is the reason the
gates exist.

Nothing was ever preempted: the lab's workload ran `sleep` as PID 1, and a container's PID 1 ignores
`SIGTERM` without an explicit handler, so the jobs ran to completion and were re-executed. A later review
found the experiment's design confounded as well, independently of that bug.

`queuelabrun` **refuses by design to emit a countable result it cannot stand behind** — it exits non-zero and
names the validity claims that failed. The earlier result counted because a run that looked fine was allowed
to count; the runs above count because each one proves it held its worker exclusively for the whole window,
qualified the node it ran on, and observed continuously, and says so in a record a reader can re-derive the
verdict from.

The full account — five mistakes, what each one's evidence was, and what changed — is in
[docs/10_WHAT_I_GOT_WRONG.md](docs/10_WHAT_I_GOT_WRONG.md).

Its counterpart is [docs/11_WHAT_THIS_MEASURED.md](docs/11_WHAT_THIS_MEASURED.md) — **eight findings
that survived**, each citing the pre-registration it was measured against, and a table of the four
claims this project is **not** entitled to make. Among them: a 2-GPU job left Pending with 2 GPUs free
while the platform reported it `Running` in 145 of 145 samples; an admission guard that measured 83.7x
against its own 1.25x bar and was declared invalid; and a registered 6-cell campaign in which supplying
a GPU-aware scheduler configuration stranded nothing in 3 of 3 runs while supplying none stranded in 2
of 3. If you read one page in this repository, read that one.

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

# the shared Kueue fixtures — REQUIRED before any GPUQuotaPolicy with trainingQuota works
kubectl apply -k config/kueue
```

`config/kueue` is deliberately outside `config/default`. Its resources are cluster-scoped and referenced by
name — the ClusterQueue the policy controller writes points at a ResourceFlavor called exactly `gpu` — and
`config/default` applies a `namePrefix`, which would rename the flavor out from under that reference.

Applying it is easy to forget, and forgetting it used to fail silently: the ClusterQueue sits
`Active=False FlavorNotFound`, every training Job submitted to it stays suspended, and the policy still read
`Synced=True`. The policy now carries a second condition for exactly this, so the state is visible:

```bash
kubectl get gpuquotapolicy <name> -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
# Synced=True QuotaSynced
# Admitting=False ClusterQueueInactive     <- the fixture is missing
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
internal/       the substance: five reconcilers, the serving gateway,
                the admission guard and benchmark harness, the queuelab
                measurement layer
cmd/            controller manager, gateway, benchmark harness, queuelab runner
config/         kustomize manifests (CRD, RBAC, manager, Kueue fixtures)
hack/           local cluster config and the M6 end-to-end script + evidence
infra/          Terraform for the AWS hosting path (bootstrap applied; cluster applied
                and destroyed in one cycle on 2026-09-18, not applied now)
docs/           design documents and specs
test/           e2e test scaffolding
```

## License

[Apache 2.0](LICENSE)
