# GpuSharingBenchmark CRD (design spec, v1)

Date: 2026-07-04 · Milestone: M5 · Author: lkhun9311

Formal design for the killer-feature CRD, at parity with the other CRD specs. Canonical schema — docs 02/04 inline examples defer to this file. Field-name decisions: `reportUri` (not `reportPath`), `burst` (not `tokenBucketBurst`), matching the implemented API conventions (`api/v1`).

## Role

Declare one A/B GPU-sharing contention experiment as a first-class, versioned platform resource, and record its measured result in `status`. The benchmark is declarative for the same reason everything else here is: repeatable, diffable, and recorded in the ledger like any other intent.

## Scope decision — thin by design

- **In scope (M5)**: CRD type + CEL validation + samples + the load-generation harness (external script/Job) + a **thin status writer** (the harness or a small CLI writes `status` when a run completes). No heavy reconciler.
- **Optional later**: a controller that launches the run as Jobs. Explicitly *not required to publish* — the CRD's value is the protocol + recorded result, not orchestration.
- Runs require a **real GPU node**; locally only type/validation/harness are exercised (envtest).

## Spec (Go sketch)

```go
type GpuSharingBenchmarkSpec struct {
    GPUClass string `json:"gpuClass"`                        // e.g. a10g — same name as the existing API (api/v1)
    // +kubebuilder:validation:Enum=exclusive;timeSlicing;mps;sharedInstance
    SharingMode string `json:"sharingMode"`
    // sharedInstance = both tenants hit ONE vLLM instance via the gateway
    // (shared KV-cache pool — the M5 flagship topology, doc 04).
    // timeSlicing/mps = separate vLLM pods on one GPU (S2/S3 topology).

    Baseline  BenchmarkWorkload `json:"baseline"`            // latency-sensitive victim
    Contender BenchmarkWorkload `json:"contender"`           // noisy neighbor

    // +kubebuilder:validation:Minimum=5
    Repetitions int32 `json:"repetitions"`                   // >=5: p99 from 3 reps is noise
    WarmupRequests int32 `json:"warmupRequests"`
    // +kubebuilder:validation:Minimum=1000
    MinRequestsPerRun int32 `json:"minRequestsPerRun"`       // sample-size floor for a p99 claim

    Load LoadSpec `json:"load"`
}

type BenchmarkWorkload struct {
    Tenant       string `json:"tenant"`                       // must resolve through the M4-b identity chain (below)
    Model        string `json:"model"`
    QPS          string `json:"qps"`                          // decimal string, e.g. "2.0"
    InputTokens  int32  `json:"inputTokens"`
    OutputTokens int32  `json:"outputTokens"`
}

type LoadSpec struct {
    // +kubebuilder:validation:Enum=openLoop
    Mode      string `json:"mode"`      // open-loop (Poisson arrivals) ONLY — a closed-loop
                                        // client hides queueing delay (coordinated omission)
                                        // and corrupts p99; this is a validation-level guard.
    Generator string `json:"generator"` // pinned tool+version, e.g. "genai-perf vX.Y"
    Streaming bool   `json:"streaming"`
    TimeoutMs int32  `json:"timeoutMs"` // timeouts recorded as errors, never dropped
    Retries   int32  `json:"retries"`   // must be 0 for latency runs (CEL-enforced)
}
```

## Status

```go
type GpuSharingBenchmarkStatus struct {
    Phase string `json:"phase,omitempty"` // Pending | Running | Completed | Failed
    ObservedGeneration int64 `json:"observedGeneration,omitempty"`
    Result *BenchmarkResult `json:"result,omitempty"`
    Conditions []metav1.Condition `json:"conditions,omitempty"`
}

type BenchmarkResult struct {
    BaselineP99Ms     int64  `json:"baselineP99Ms,omitempty"`
    ColocatedP99Ms    int64  `json:"colocatedP99Ms,omitempty"`
    InterferenceRatio string `json:"interferenceRatio,omitempty"` // decimal string
    P99CI95           string `json:"p99CI95,omitempty"`           // bootstrap CI, e.g. "2210-2440"
    ReportURI         string `json:"reportUri,omitempty"`         // Go initialism per StorageURI precedent
}
```

Status numbers come only from a real-GPU run; until then `result` is absent (never placeholder numbers). Phase ladder mirrors the other CRDs; `Completed` requires `result.reportUri`.

## Validation (CEL)

- `spec.load.retries == 0` — retries silently repair tail latency.
- Field-local immutability via `self == oldSelf` on the result-defining fields (`sharingMode`, `baseline`, `contender`, `load`) — the same pattern NodeHealth uses for `nodeName`. A *phase-conditioned* spec lock ("immutable after Running") is **not** expressible in spec-level CEL (a spec rule cannot see `status`); if run-state locking is ever needed it requires a validating webhook, which is out of scope for v1. Editing an experiment definition means creating a new CR — which is also better provenance.
- `sharingMode == "sharedInstance"` requires `baseline.model == contender.model` (one instance).

## Tenant provisioning (identity chain, M4-b)

`spec.baseline.tenant` / `spec.contender.tenant` are not free-form: each must resolve through the M4-b identity chain — a `GPUQuotaPolicy` with matching `spec.tenant`, and an entry in the `gateway-api-keys` Secret. The harness resolves both tenants **before** starting load and fails fast (benchmark `Failed`, condition `TenantNotProvisioned`) if either is missing or ambiguous — a benchmark that silently bypasses the gateway identity model would not be measuring the platform.

## QPS calibration (protocol, doc 04)

Contender QPS values are not chosen by feel: run a single-tenant saturation sweep first, then pin run points at ~30/60/90% of the measured saturation QPS. The sweep result is committed alongside the run as `saturation-curve.csv`.

## Sample

```yaml
apiVersion: platform.lkhun9311.github.io/v1
kind: GpuSharingBenchmark
metadata:
  name: premium-vs-longcontext-shared
  namespace: platform-system
spec:
  gpuClass: a10g
  sharingMode: sharedInstance
  baseline:  { tenant: tenant-premium,  model: llama3-8b, qps: "2.0", inputTokens: 256,  outputTokens: 128 }
  contender: { tenant: tenant-standard, model: llama3-8b, qps: "6.0", inputTokens: 8192, outputTokens: 256 }
  repetitions: 5
  warmupRequests: 50
  minRequestsPerRun: 1000
  load: { mode: openLoop, generator: "genai-perf", streaming: true, timeoutMs: 60000, retries: 0 }
```

## Testing

envtest: type registration, CEL rejections (retries>0, mutation of an immutable field, sharedInstance model mismatch), phase ladder via the thin status writer. The measured path is validated only on real GPU.

## Amendment, 2026-09-30: the type shipped, and an external review found four accepted objects that would measure the wrong thing

The type, the generated CRD, the sample and envtest specs landed on 2026-09-30 (commit `91ba082`). There is
still no status writer and no measured result. What follows is the record of what the implementation changed
about this registration, and why — written after the fact, as an amendment rather than as an edit to the
sections above.

A review by a second engine constructed four objects that the first implementation accepted, and each was then
confirmed against a real apiserver in envtest rather than argued about:

| Accepted, and wrong | What it would have produced |
|---|---|
| `qps` as an unrestricted string | `""`, `" 2.0"`, `"NaN"`, `"-1"`, `"2e0"`, `"0"` and `"abc"` were all admitted — seven of seven |
| `status.phase: Completed` with no `result` | a completed benchmark naming no report at all |
| `contender.qps: "0"` | a repeatable ratio near one, from a run with no contention in it |
| one tenant on both sides | intra-tenant contention reported as isolation between tenants |

The same review found a defect the implementation had introduced rather than inherited. `streaming` and
`warmupRequests` were optional with `omitempty`; the whole-spec comparison on update is over API values and
counts field presence; a Go round-trip drops an omitempty zero. So an object created with an explicit
`streaming: false` **could never be updated again, for any field** — including the ones this page had called
mutable. Measured, not deduced: the refusal named the immutability rule.

### What this amendment changes in the registered protocol

- **The whole spec is immutable, not four of its fields.** The original design named `sharingMode`,
  `baseline`, `contender` and `load`, leaving `repetitions`, `warmupRequests`, `minRequestsPerRun` and
  `gpuClass` editable. That boundary is withdrawn. Raising a repetition count after seeing an inconclusive
  result changes the stopping rule, and changing `gpuClass` mid-comparison compares different hardware. Under
  this repository's pre-registration discipline a protocol change is a new registration, so it is now a new
  CR, linked to the original. The rule is `self.spec == oldSelf.spec`.
- **`streaming` and `warmupRequests` are required and always serialized.** They were the only optional fields
  in the spec; with whole-spec equality in force, an optional field is a way to freeze an object out of every
  future update.
- **`qps` is a positive plain decimal.** `MaxLength=16`, pattern `^[0-9]+(\.[0-9]+)?$`, and a rule refusing
  every spelling of zero. The string representation is kept — the value appears verbatim in reports — and the
  cost is accepted openly: two spellings of one rate are two different values to the immutability rule.
- **Zero is not how a control condition is expressed.** The control condition is the harness running the
  baseline with the contender disabled; the registered rate describes the active condition. Overloading
  `qps: "0"` to mean absence would make one field carry two meanings.
- **`baseline.tenant` and `contender.tenant` must differ.**
- **`Completed` requires a non-empty `status.result.reportUri`**, enforced on the status schema rather than in
  prose. The design's claim that run-state locking needs a webhook was too broad for the root scope — a
  root-scoped rule sees both spec and status — though it is correct for a spec-scoped rule.
- **Four field-local transition rules became one root conjunction, then one whole-spec equality.** The
  original design asked for `self == oldSelf` per field. Error locality is worse; the protection is stronger.

Also recorded: `warmupRequests >= 0`, both token counts `>= 1`, and `timeoutMs >= 1` were added by the
implementation and are not in the sketch above. They belong to the registration now.

### Two things this amendment does not settle

- **`generator` still names no version.** The field's contract is a pinned tool and version; the sample here
  and in `config/samples`, `docs/02` and `docs/04` all say `genai-perf` with no version. `genai-perf` is not
  installed on this machine, so no real version can be read, and inventing one to satisfy the contract would
  be worse than leaving the gap visible. It stays open until a run pins it.
- **`p99CI95` does not say what it is an interval on.** This page leaves the estimand unspecified, the type
  documents it as the colocated p99's interval, and `docs/04` asks for an interval on the interference ratio.
  A colocated-only interval does not carry the uncertainty in the denominator. Naming the estimand is a
  separate amendment, to be written before a writer computes it.

### What still cannot be enforced here

A harness can discard timed-out requests, compute a p99 over the survivors, and publish a favourable ratio
with a perfectly valid `reportUri`. Every rule above would pass. Censoring is a measurement-integrity problem
that belongs to the harness and to report validation — retain attempted arrivals and failures, define the
treatment of timeouts, and check the published statistic against the raw observations. A report URI is a
completion requirement, not evidence that the number in it is right.
