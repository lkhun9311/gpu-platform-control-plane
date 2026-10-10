# Control Plane API

> **Status (2026-09-30).** Per CRD: `InferenceDeployment`, `GPUQuotaPolicy`, and `NodeHealth` are **built**
> (`NodeHealth` gets no GPU fault signal — nothing Xid or ECC exists, and the DCGM code that does exist is
> a utilisation reader for the queuelab rather than a health input). `MLTrainingJob`
> is **built** (M6, run end-to-end on kind — never on real hardware). M6 is not the only milestone with live
> end-to-end evidence: M7, the gateway chain and the chaos scenarios all have run records under `hack/`.
> `GpuSharingBenchmark` has a **type and a generated CRD** (2026-09-30) that treats the spec as an immutable registration and enforces the load protocol at admission, with 33 envtest specs; `CompilePlan` (`internal/bench/plan.go`, 2026-09-30) decides whether a declared protocol is one this harness can execute and names each reason it cannot, and it is **called only from tests** — so the compiler is built and tested, the published measurements came from the shell harness, and the execution integration is unfinished. With the **thin status writer** also outstanding, nothing has ever written `status.result` and no result has been recorded through it. Its sizing arithmetic and run script exist and the sharing matrix has run on rented cards. This line said "designed only — no CRD" until 2026-09-30, and the table below was dated 2026-07 and never re-read when the prose around it was corrected — so this document contradicted itself about two CRDs at once, and `make docs-check` cannot see that because it resolves names, not claims.
> `WorkloadRun` is **built and has been run for real on kind** (M7): a CRD, a controller, a driver, and a
> recorded run in which deleting a serving Pod produced a recovery trail nobody wrote by hand. The gateway
> (Layer 4, M4-b) is **built, unit-tested and deployed on kind but never on EKS**. The M5 KV-cache-aware admission guard is
> **built, and MEASURED on a paid GPU**: four repetitions on 2026-09-03 and an engine-level scheduler microtest on 2026-09-04. The guard failed — 83.7x against a pre-registered 1.25x premium-tail target — and the harness declared the run invalid rather than reporting a protection claim. Every GPU in the kind clusters is simulated by a fake device plugin. The GPUs in the paid EC2 sessions —
> more than thirty of them since 2026-09-02 — were real.

The control plane is a set of CRDs in API group `platform.lkhun9311.github.io/v1`, each reconciled by a controller that converges native Kubernetes objects toward the declared intent. (Some pasted designs use a shorter `platform.ai/v1` as a conceptual surface; the implemented group is the one above, and all examples here use it.)

## CRD family

| CRD                   | Role                                                               | Tier                                       | Implemented today (2026-09-30)                                                                                                   |
|-----------------------|--------------------------------------------------------------------|--------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------|
| `InferenceDeployment` | model-serving intent → Deployment/Service/KEDA                     | Core                                       | type + serving reconciler (Deployment/Service, phase ladder) — M4-a merged                                                       |
| `GPUQuotaPolicy`      | per-tenant GPU quota / rate limit → ResourceQuota + gateway config | Core                                       | type + reconciler (ResourceQuota sync, drift recovery) — M3 merged; `rateLimit` field consumed by the M4-b gateway — **M4-b merged, gateway built, unit-tested and deployed on kind, never on EKS** |
| `NodeHealth`          | GPU node intake & operational state                                | Core                                       | type + reconciler (observe + taint, finalizer, drift recovery) — M2/M3 merged                                                    |
| `GpuSharingBenchmark` | declarative noisy-neighbor / sharing benchmark                     | Core (killer feature)                      | type + generated CRD + 33 envtest specs, per spec `2026-07-04-gpusharingbenchmark-crd-design.md` and its 2026-09-30 amendment; the spec is immutable once created, so a protocol change is a new CR. **No status writer and no recorded result** (M5) — deliberately not a heavy reconciler, which is the spec's own scope decision, so the absent controller is registered design and not a gap |
| `WorkloadRun`         | record a workload execution as evidence                            | Evidence / CRD-lite                        | type + reconciler, registered in `cmd/main.go`, and driven end to end on kind (M7): deleting a serving Pod produced a recovery trail nobody wrote by hand. This cell read "sketched below only — no spec or code yet" while the status block at the top of this same document said it was built and had been run for real |
| `MLTrainingJob`       | Kueue-admitted training job                                        | **M6 (promoted from stretch, 2026-07-04)** | type + full reconciler — Job+Kueue Workload translation, two-tenant cohort borrowing/reclaim preemption, run end-to-end on kind — **M6 merged** (`hack/m6-kind-e2e.md`). Not the only milestone with a live run record; see `hack/m7-evidence-trail.log` and the chaos write-ups |

`MLTrainingJob` was promoted from stretch to **M6** (2026-07-04): it shows the same `GPUQuotaPolicy` can extend from inference to training. The main narrative stays inference-first GPUaaS + performance isolation; M6 is the training-admission bridge, not a second flagship.

> **Quota ownership rule (M6 design decision):** inference quota flows `GPUQuotaPolicy → ResourceQuota` (as shipped in M3). Training quota flows `GPUQuotaPolicy → Kueue ClusterQueue/LocalQueue` — Kueue owns the training admission decision. (The controller creates a ClusterQueue and a LocalQueue and references a `ResourceFlavor` it does not create; the conditions it writes are `Synced` and, in training mode, `Admitting`. There is no `TrainingQuotaSynced` condition — this line named one for months.) The same GPUs are never counted by both mechanisms: a ResourceQuota that also counted training GPUs could block a pod Kueue already admitted (double-accounting). If a namespace ResourceQuota is kept over training, it is an intentional coarse ceiling with the documented invariant `Kueue quota ≤ ceiling`.

## 4-layer admission

Quota and policy are enforced in depth, each layer doing what it is best at:

| Layer | Mechanism                                                   | Enforces                                                                                                      | Status |
|-------|-------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------|--------|
| 1     | Admission webhooks (`internal/webhook/v1`)                  | in namespaces labelled `platform.lkhun9311.github.io/gpu-quota-enforced: "true"`, on CREATE only: a GPU Job must carry a Kueue queue label unless the namespace is metered by a ResourceQuota; a GPU Pod without a queue label must come from the Job controller and trace to a queued Job; `quota-exempt` is honoured only for a kube-system service account; an over-long termination grace is refused on every path. It does **not** check that the queue named matches the one a policy derives | built, exercised on kind (`hack/quota-bypass-guard.md`) |
| 2     | ResourceQuota                                               | one aggregate key — `requests.nvidia.com/gpu`. Not CR counts, and not split per `gpuClass`. When `trainingQuota` is true the controller **deletes** this ResourceQuota and the ceiling moves to the Kueue ClusterQueue | built |
| 3     | Controller conditions                                       | `InferenceDeployment` writes an `Available` condition and a phase (`Pending`/`Progressing`/`Ready`/`Degraded`) computed from the Deployment's observed generation, replica counts and `ProgressDeadlineExceeded` | built |
| 4     | Gateway token bucket (+ M5: KV-cache-aware admission guard) | runtime RPM / burst → HTTP 429; under backend pressure, selective 429 for standard-tier long-context requests | built; see the measured limits in `hack/m5d-writeup.md` |

The webhooks refuse unaccountable intent at submit time; ResourceQuota or Kueue caps consumption; the controller reports whether the serving Deployment converged; the gateway shapes runtime traffic. No single layer is trusted to do all of it, and layers 1 and 2 are alternatives rather than a stack — `trainingQuota` decides which of them holds the budget.

> ⚠️ An earlier version of this table listed `ValidatingAdmissionPolicy` (VAP) as layer 1 and named `QuotaSatisfied`, `NodeClassHealthy` and `WarmCacheReady` as layer 3. **Neither exists in this repository.** There is no `ValidatingAdmissionPolicy` or `ValidatingAdmissionPolicyBinding` under `config/` — what is installed is a `ValidatingWebhookConfiguration` — and the controller writes none of those three conditions. A VAP layer remains a reasonable design for static policy (GPU-class allowlist, replica max, image registry) and is **not built**.

## InferenceDeployment (target design)

```yaml
apiVersion: platform.lkhun9311.github.io/v1
kind: InferenceDeployment
metadata:
  name: llama3-8b
  namespace: tenant-a
spec:
  tenant: tenant-a
  model:
    name: llama3-8b
    artifactUri: s3://models/llama3-8b/v1
    digest: sha256:abc...
    sizeGiB: 16
  runtime:
    engine: vllm
    image: vllm/vllm-openai:<tested-version>
    args:
      maxModelLen: 4096
      maxNumSeqs: 64
      enablePrefixCaching: true
      gpuMemoryUtilization: 0.90
  gpu:
    class: a10g
    count: 1
  replicas: { min: 1, max: 3 }
  autoscaling: { metric: queue_depth, target: 20 }
  slo: { ttftP95Ms: 1500, tpotP95Ms: 100 }
  warmCache: { enabled: true }
status:
  phase: Ready
  conditions:
    - { type: QuotaSatisfied, status: "True" }
    - { type: NodeClassHealthy, status: "True" }
    - { type: WarmCacheReady, status: "True" }
```

In the target design the controller reconciles this into a Deployment (vLLM), a Service, a ConfigMap, and a KEDA ScaledObject, owned via owner references, and gates `phase: Ready` on the conditions above.

> Implemented today (M4-a merged): the CRD type carries `model{name,storageUri}`, `image`, `gpuClass`, `gpuCount`, `replicas`, `port`, and the serving reconciler converges a Deployment + Service with a 7-step phase ladder (`phase / observedGeneration / readyReplicas / conditions`). The richer `runtime/autoscaling/slo/warmCache` fields, ConfigMap, and KEDA ScaledObject above are the target design — later milestones, not yet built. (Target field names like `artifactUri` are aspirational; the implemented name is `storageUri`.)
>
> ⚠️ **The three conditions in the `status` block above are target design too, and the sentence that follows the block used to claim they gate readiness.** They do not exist: `QuotaSatisfied`, `NodeClassHealthy` and `WarmCacheReady` are written nowhere in the controller. What `computeInfDPhase` actually writes is one condition named `Available` plus a phase whose values include `Ready`, both derived from the Deployment's observed generation, its three replica counts, and a `Progressing=False/ProgressDeadlineExceeded` rollout failure. It does not read the Deployment's own `Available` condition, and it does not independently check quota, node class or cache warmth. The design spec recorded these three as deferred from the start (`docs/superpowers/specs/2026-06-27-m4-a-inferencedeployment-serving-design.md:72`); this document then printed the deferred version as if it ran.

## GPUQuotaPolicy (target design)

```yaml
apiVersion: platform.lkhun9311.github.io/v1
kind: GPUQuotaPolicy
metadata:
  name: tenant-a-quota
  namespace: tenant-a
spec:
  tenant: tenant-a
  allowedGpuClasses: [a10g, l4, t4]
  maxConcurrentInferenceDeployments: 3
  maxReplicasPerDeployment: 3
  maxGpuPerDeployment: 1
  maxGpusInUse: 2
  rateLimit: { requestsPerMinute: 600, burst: 100 }   # implemented field names (api/v1)
status:
  phase: Active
  usage: { currentInferenceDeployments: 1, currentGpusInUse: 1, requestsLast1m: 82 }
```

The controller syncs this into a namespace `ResourceQuota` (and feeds the gateway token bucket).

> Implemented today: `tenant`, `targetNamespace`, `gpuClass`, `limits.gpuCount`, and optional `rateLimit{requestsPerMinute,burst}`, with a phase/observedGeneration/conditions status. ResourceQuota sync (the aggregate GPU ceiling, kept in sync against drift, ownership-guarded) shipped in M3; `rateLimit` is consumed by the M4-b gateway (in progress). The richer limit set (`allowedGpuClasses` and per-class scoping, replica limits) is a later target, and the M5 guard adds a tenant tier (annotation first, `spec.tier` if promoted — see the admission-guard spec).

## GpuSharingBenchmark (Core — killer feature)

Canonical schema and rationale: `docs/superpowers/specs/2026-07-04-gpusharingbenchmark-crd-design.md` (field names `gpuClass`, `reportUri`; `repetitions >= 5`; open-loop `load` spec is mandatory). Sample and protocol: doc 04.

```yaml
apiVersion: platform.lkhun9311.github.io/v1
kind: GpuSharingBenchmark
metadata:
  name: premium-vs-longcontext-shared
  namespace: platform-system
spec:
  gpuClass: a10g
  sharingMode: sharedInstance     # exclusive | timeSlicing | mps | sharedInstance
  baseline:  { tenant: tenant-premium,  model: llama3-8b, qps: "2.0", inputTokens: 256,  outputTokens: 128 }
  contender: { tenant: tenant-standard, model: llama3-8b, qps: "6.0", inputTokens: 8192, outputTokens: 256 }
  repetitions: 5
  warmupRequests: 50
  minRequestsPerRun: 1000
  load: { mode: openLoop, generator: "genai-perf", streaming: true, timeoutMs: 60000, retries: 0 }
# status.result{baselineP99Ms,colocatedP99Ms,interferenceRatio,p99CI95,reportUri} is written
# only by a real-GPU run — never placeholder numbers.
```

⚠️ **The YAML above is the registered schema, not a runnable request.** The committed sample carries these
exact values (`config/samples/platform_v1_gpusharingbenchmark.yaml`), and `CompilePlan`
(`internal/bench/plan.go`) refuses it: `TestTheCommittedSampleCannotBeExecuted` exists to keep that true
rather than to hide it.

**The runnable one is the second sample,** `config/samples/platform_v1_gpusharingbenchmark_executable.yaml`.
That is the file to feed `benchharness compile-plan -cr`, and it is the file both paid runs of 2026-10-01 were
compiled from. Its own header comment states what a CR still cannot declare — the trace duration, the study
identifier, and the prompt lengths in characters — so a run driven by it is one whose load and protocol came
from the CR, not one a controller reconciled.

Three different counts describe the refusals, and this paragraph used to print one of them as if it were all
three. `CompilePlan` has **thirteen** refusal sites, three of which fire once per arm; **eleven** distinct
unsupported values each have their own case in `TestEachUnsupportedValueIsRefusedOnItsOwn`; and the committed
sample itself receives **six** — `baseline.tenant`, `contender.tenant`, `baseline.model`, `contender.model`,
`load.generator` and `warmupRequests`. It received eight until 2026-10-01, when `outputTokens` became a value
the plan carries rather than one it refuses.

The sentence here used to list "caps generation" among the reasons, and the first correction of it was wrong
too: generation **is** still capped — `internal/bench/httpsender.go:295` puts the value in the request's
`max_tokens`, as it always did. What disappeared is the *restriction to one fixed cap*. A limit the CR now
chooses and a limit the generator hard-coded are both caps, and calling the second one's removal "no longer
caps" describes neither.

### Known limits of `GpuSharingBenchmark`, and the refusal that states each one

These are the values the harness does not support. They are listed here so a reviewer reads them rather than
discovering them at run time, and each one below is pre-refused at compile time instead of being honoured
partially.

⚠️ **Two fields are neither refused nor enforced, which is a third state this section used to hide.**
`CompilePlan` stores `gpuClass` and `minRequestsPerRun` on the `Plan` (`internal/bench/plan.go:191-192`), and
the `compile-plan` export block never prints them (`cmd/benchharness/compileplan.go:115-150`). So raising the
executable sample's `minRequestsPerRun` from 1,000 to 1,000,000 changes the CR's sha256 and changes nothing
else: the compiler checks only the floor, the runner is never told the number, and the analysis path reads the
harness constant `MinTailSamples = 100` (`internal/bench/report.go:769`) rather than the CR's value. Keeping a
declared value in a struct is not the same as carrying it to the run — that distinction is what the
`outputTokens` work above was about, and these two fields are still on the wrong side of it. Verified by
reading the code path, not by executing a changed CR.

| Field | What is supported | Refused by, and why that is not a missing afternoon of work |
|---|---|---|
| `baseline.tenant`, `contender.tenant` | `premium-1`, `standard-noisy` | `plan.go:53,57`. The trace generator writes these two identities into every row. The names are not a string: one `TENANTS` list derives the API-key secret, the `api_keys` map, the premium tier list, the `GPUQuotaPolicy` and the vLLM priority map, across 12 files. A hand-kept copy is what cost the first paid run a quarter of every replay to 401s (two of four tenants missing from the key secret) and the second its two probe tenants to 403s (keyed but given no policy); a tenant missing from the priority map would fail more quietly still, replaying the control *without an error*. |
| `baseline.model`, `contender.model` | `Qwen/Qwen2.5-3B-Instruct` | `plan.go:68`. The gateway answers `ErrNoRoute` for any other name once the engines are up. Parameterising it is possible, but the model binds the tokenizer, and the token-to-character resolution table below was measured against this one. |
| `warmupRequests` | `0` | `plan.go:96`. There is no warmup phase and no exclusion boundary. Dropping rows after the fact is a different protocol from not sending them, so a positive value could not be honoured, only approximated. |
| `load.generator` | `benchharness-replay` (the exact literal, `plan.go:275`) | `plan.go:118`. The registered sample names `genai-perf`, which never produced traffic here. The sample is deliberately **not** edited to match: a manifest naming a generator that did not send the requests is provenance for the wrong tool. |
| `baseline/contender.inputTokens` | `256`, `8192` | `plan.go:152`. The generator is configured in characters; these are the two token counts whose character lengths were measured against the served tokenizer rather than estimated, and no formula inverts the count. |
| `load.mode`, `load.retries`, `load.streaming`, `minRequestsPerRun`, `repetitions`, `sharingMode`, `outputTokens` | `openLoop`, `0`, `true`, **≥ 1000** (the CRD's own `Minimum`, `api/v1/gpusharingbenchmark_types.go:80` — the harness floor of 100 in `plan.go:102` is a different, lower bound and this row used to print it as the API's), ≥ 5, the modes the matrix deploys, any positive cap | The remaining sites in the same file. These constrain the measurement rather than the platform: a retry repairs the tail this benchmark exists to measure, and a non-streaming response has no first-token time. |

What exists today: the CRD, the samples, the harness, the compiler that decides whether a spec is executable,
and a command that calls it — `benchharness compile-plan` (`cmd/benchharness/compileplan.go:78`), which is how
both paid runs of 2026-10-01 got their load. This paragraph used to say "anything that calls the compiler
outside tests" does not exist, which contradicted the instruction six paragraphs above to run that very
command. What does not exist is narrower and worth stating exactly: **no controller calls the compiler, and
nothing writes `status.result`.** So the measured numbers in `README.md` came from the shell harness on a
rented card, and no `status.result` has ever been written. Status numbers, when they come, come from a real-GPU run (doc 04); they are not
invented locally.

## WorkloadRun (new, Evidence CRD-lite)

A common record of a workload execution (inference load test, benchmark, failure injection, training). Deliberately thin — no heavy reconciler — so it stays an evidence resource, not an MLOps platform.

```yaml
apiVersion: platform.lkhun9311.github.io/v1
kind: WorkloadRun
metadata:
  name: llama3-loadtest-20260623
spec:
  tenant: tenant-a
  workloadType: inference        # inference | benchmark | failure | training
  targetRef: { kind: InferenceDeployment, name: llama3-8b }
  scenario: gateway-loadtest
status:
  phase: Completed
  startedAt: "2026-06-23T12:00:00Z"
  completedAt: "2026-06-23T12:10:00Z"
  metrics: { p95LatencyMs: 620, p99LatencyMs: 1300, throughputRps: 18, errorRate: 0.01 }
  reportUri: evidence/benchmark-reports/gateway-loadtest.md   # illustrative path only — the type, reconciler
                                                                # and driver exist (M7,
                                                                # internal/controller/workloadrun_controller.go),
                                                                # but nothing is committed at this path today
```

## MLTrainingJob (M6 — promoted from stretch)

Implemented as a CRD type (queue/image/command/gpuClass/gpuCount/parallelism/completions) with a full reconciler — **M6 is merged**. It demonstrates that `GPUQuotaPolicy` can govern training as well as inference. The reconciler translates a `MLTrainingJob` into a `batch/v1` Job admitted through Kueue (LocalQueue/ClusterQueue, referencing a `ResourceFlavor` it does not create), and the two-tenant scenario of cohort **borrowing and quota reclaim** was run end-to-end on kind (evidence: `hack/m6-kind-e2e.md`).

⚠️ Three claims in this paragraph were wrong, and the evidence file had already said so. It calls Kueue's global `fairSharing` "left disabled here" and states outright that "Borrowing + reclaim is the accurate name for this evidence; calling it Fair Sharing" is not — this document called it fair sharing anyway. The metrics are not queue-wait/admitted/denied: `internal/controller/metrics.go` emits `gpuplatform_mltrainingjob_admit_to_running_seconds` (time from admission to Running, which is not queue wait), plus phase, failure and unobserved counters — there is no admitted or denied counter. And M6 is not the only milestone with live end-to-end evidence: `hack/m7-evidence-trail.log` records a real kind run ending `COMPLETE verdict=Recovered`, and the three chaos write-ups and `hack/observability-kind.md` are run records too. It ran on simulated GPU capacity; no real hardware was used. The optional artifact-lite — one real single-GPU PyTorch fine-tune job run through this same path — has not happened.

⚠️ That last sentence used to continue "the M5 real-GPU session itself has not happened", and it was wrong. The session ran: four repetitions on 2026-09-03 and an engine-level microtest on 2026-09-04, on paid A10Gs. What did not happen is the fine-tune through the `MLTrainingJob` path. The two are separate, and collapsing them let a true statement about the training artifact deny a session that had already produced results — including the one this project's flagship was built on, and failed (`hack/m5d-writeup.md`). Quota ownership follows the rule above.
