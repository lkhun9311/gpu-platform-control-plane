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

## Amendment, 2026-09-30 (second): the status writer was designed, reviewed and not built, and the estimand is contradicted rather than unspecified

The thin status writer this page puts in scope was designed. An external engine was asked to attack the
design before any of it was written, and it rejected it. Each of its cited reasons was checked against the
code in this repository and each held. The writer is therefore **not built**, and `status.result` stays
absent. This section records why, so the next attempt starts from here rather than from the same design.

### The estimand is not an open question, it is a contradiction

The amendment above listed `p99CI95` under "two things this amendment does not settle". That was too kind to
it. The registration and the code that would feed it name the reported statistic **five** different ways:

| Where | What it names |
|---|---|
| This page | unspecified |
| `api/v1` — `p99CI95` comment | the bootstrap 95% interval for the **colocated p99** |
| `docs/04` | an interval on the **interference ratio** |
| `api/v1` — `repetitions` comment | the report is a **median-of-runs** with a bootstrap interval |
| `internal/bench` | the point estimate `TTFTMsP99` is a **pooled** p99, while `BootstrapCI` bootstraps the **mean** of the values it is given |

"Unspecified" means nobody has chosen. "Contradicted" means several choices are already written down and
shipped — the field comments reach operators as the CRD's own description. A point estimate and an interval
that target different quantities must not be published side by side: a reader takes the pair to mean "the
ratio lies in this range", and that sentence is not true of them.

Choosing is a measurement-design decision and it is deliberately **not** made here. What can be said about
the cost of each choice: preserving the documented median needs a median bootstrap, which
`BootstrapCI` does not do; preserving the pooled p99 needs repetition blocks carrying raw observations so
each bootstrap sample can recompute it, which a vector of per-repetition p99s cannot reconstruct; adopting
the mean of per-repetition p99s is the smallest code change and the largest registration change, because it
edits the promise to fit the implementation — the direction this project treats as the one to avoid. The
decision belongs in a further dated amendment, written **before** a writer computes anything.

### Why the writer was refused

Three bindings are missing, and none of them is a detail.

- **Evidence to run.** Nothing establishes that a set of summaries, manifests, an apparatus record and a
  report came from **one** execution. Supplying yesterday's hardware preflight, today's stub summaries and
  the intended experiment's manifests passes every check the design proposed. No malice is required.
- **Evidence to the CR.** Nothing establishes that the measurement is **this CR's registered experiment** —
  not the tenants, models, rates, token lengths, sharing mode, gpuClass, warmup exclusion, timeout,
  generator version, streaming or retry behaviour. Absent evidence must not read as compliance.
- **The estimand**, above.

Two specific things the design got wrong about this repository's own harness, both found by reading the code
rather than by reasoning about it:

- **`report` writes `--json-out` before it returns its invalid-run error.** The presence of a summaries file
  therefore does not mean report validation succeeded, and an importer that trusts the file can resurrect
  evidence the reporting command explicitly refused.
- **The isolated baseline's trace checksum legitimately differs from the co-located arm's.** `gen-trace`
  filters the contender out of the same two-tenant trace, precisely so premium arrives on an identical
  schedule. A check requiring equal checksums across arms would have rejected the intended baseline. The
  comparison that is actually wanted is the baseline trace against the victim projection of the co-located
  trace — same request identities, arrivals and contents.

### What a writer may and may not claim

With the rejected design, the most that could be claimed is that *an authorized caller supplied files that
passed selected consistency checks*. It could **not** claim that GPU execution of this CR's registered
experiment produced the numbers. That gap is the whole distance between this page's promise — "a reader who
finds a ratio here must be able to trust that hardware produced it" — and what the evidence format can
support today.

Closing it needs a trusted runner that emits one bound bundle plus a receipt tying its hashes to one run,
the CR's UID and spec, the runner's identity and the validation outcome, with the runner responsible for
observing the actual gateway-to-engine route and GPU allocation. That requires **no change to the frozen
`RunManifest` schema**. If that collection path is out of scope, the honest alternative is an explicitly
operator-attested import — a narrower contract, which would mean **changing the unconditional hardware
promise in the type's own comment**. A status condition cannot quietly weaken a guarantee the CRD advertises.

Recorded outside this repository as
`storage/gpu-platform-control-plane/issues/open/2026-09-30-the-status-writer-is-blocked-on-three-bindings`
and `.../defects/open/2026-09-30-the-registration-names-three-competing-estimands`.

## Amendment, 2026-09-30 (third): the estimand is decided, and the repetition count is contradicted too

The amendment above left the estimand to "a further dated amendment, written before a writer computes
anything". This is it. Nothing has been computed and no `GpuSharingBenchmark` exists in any cluster, so this
choice is being made **before** any result can influence it — which is the only time it can honestly be made.

### The decision

The primary reported object is the **ratio of median per-repetition victim TTFT p99s**, with a paired
repetition bootstrap interval on the ratio.

For each complete repetition `i`, compute the victim's TTFT p99 separately within that repetition:

```
b_i = p99(victim TTFT, baseline repetition i)
c_i = p99(victim TTFT, colocated repetition i)

B = median(b_i)      -> status.result.baselineP99Ms
C = median(c_i)      -> status.result.colocatedP99Ms
R = C / B            -> status.result.interferenceRatio
```

This estimates **the ratio of typical repetition-level tails under this protocol**. It is deliberately
neither a pooled-request p99 nor the median of the individual per-repetition ratios, and the distinction
matters: pooling re-weights repetitions by how many requests each happened to complete, which answers a
different question from one this page already committed to by giving repetitions equal standing.

The interval is a **paired** percentile bootstrap: resample complete `(b_i, c_i)` blocks with replacement,
recompute both medians and their ratio, and take the 2.5th and 97.5th percentiles. Pairing is by the
repetition identity the schedule already carries — `hack/m5c-matrix.sh` builds cells as
`arm|arm|rep|rate|weight|0`, so the block identity is recorded rather than inferred from two arrays having
equal length.

The bootstrap count, the seed, the median convention for an even number of repetitions, the percentile
convention and the rounding are frozen **by the table below**, before collection. An earlier version of this
paragraph said they were "frozen here" and then named none of them — a sentence claiming a freeze is not a
freeze, and that is the same shape as a document asserting an invariant the schema does not make. The values
are therefore written out rather than promised.

| Choice | Value | Why this one |
|---|---|---|
| Bootstrap resamples | **10000** | `cmd/benchharness/power.go` already drives `BootstrapCI` at this count, so the ratio interval is resampled as deeply as the existing power analysis rather than at a second, unexplained depth. |
| Seed | **11** | The seed `hack/m5c-matrix.sh` passes to `gen-trace` for every cell. One seed for the traffic and a different one for the analysis would make the pair harder to re-derive than it needs to be, and the bootstrap is over repetition blocks, not over the trace. |
| Median of an even count | **mean of the two central order statistics** | The ordinary convention, and the one that makes `B` and `C` continuous in the observations; taking the lower of the two would bias both arms downward by an amount that depends on the spread. |
| Percentile of the bootstrap distribution | **nearest-rank, index `ceil(q*n)-1` clamped to `n-1`** | The convention the unexported percentile helper in `internal/bench` already uses, so the interval and the per-repetition p99s inside it are computed by one rule. Interpolating here and not there would be two conventions in one number. |
| Per-repetition p99 | **nearest-rank over that repetition's completed victim requests** | Same function, same reason. |
| Rounding | **`baselineP99Ms` and `colocatedP99Ms` are the medians rounded half-up to integer milliseconds; `interferenceRatio` is computed from those ROUNDED integers and printed to 3 decimal places; `interferenceRatioCI95` and `p99CI95` are printed as `lo-hi` with the same precision as the quantity they bound** | `interferenceRatio` is defined by its own field comment as `colocatedP99Ms / baselineP99Ms`. Computing it from unrounded medians while publishing rounded fields would make the published ratio unreproducible from the published numbers — a reader dividing the two integers would get a different answer. The definition wins over the extra significant figures. |

None of these is a free choice made for convenience: each either reuses a convention already in the code or
follows from a definition already published. Where a value is borrowed, the borrowing is named so a later
change to the source is visible as a change here too.

### Which contrast `R` is the ratio of, and what the existing matrix can and cannot supply

`R = C / B` reads as "the effect of turning the contender on". The sharing matrix does not supply that
contrast, and the difference is not small.

`hack/m5c-matrix.sh` deploys `R1` and `shared` as **one engine holding the whole card**, and `timeSlicing`
and `mps` as **two engines with half the card each, one tenant routed to each**. So `timeSlicing / R1`
changes the contender AND the topology AND the victim's own memory allocation in one step. A reader taking
that ratio for contender-presence alone is reading a combined effect.

Two of the arms do give the registered contrast, and this page names them as the ones `R` may be computed
from:

- **`shared` over `R1`** is contender-presence with everything else held: the same single whole-card engine,
  and `gen-trace --arm R1` filters the contending tenant out of the *same* trace so the victim arrives on an
  identical schedule. That is the pairing `sharingMode: sharedInstance` describes, and it is the only one
  in this matrix where the victim's allocation does not move.
- **`timeSlicing` over `R1`** and **`mps` over `R1`** are topology comparisons. They are legitimate and they
  are what `sharingMode: timeSlicing` and `sharingMode: mps` should be understood to declare — a different
  registered question, not the same question on different hardware. A CR registering one of those modes is
  registering the topology contrast, and its `interferenceRatio` must be read that way.

This is a statement about what the numbers mean, not a change to the schema: the CRD cannot tell which
topology a report came from. The execution plan is what has to refuse a mismatch between the declared
`sharingMode` and the arms actually bought, before the card is rented.

## Amendment, 2026-09-30 (fifth): the sample this page registered cannot be executed, and a compiler now says so before the card is rented

`CompilePlan`, in `internal/bench`, takes a `GpuSharingBenchmarkSpec` and either resolves it into the harness
invocation that would measure it, or refuses and names each reason.

⚠️ **It is a library function, and nothing but tests calls it.** This paragraph said it "runs before the CR
is created and before an instance is launched" — that is what it is FOR and not what it does. A
repository-wide search finds callers only in `internal/bench/plan_test.go`. The paid path still generates its
traces without consulting it, so the protection this page advertised does not exist yet. An external review
found that, and it is recorded rather than quietly corrected because the sentence is what a reader would have
relied on.

Four of the five gaps that review named are now closed. What closed them, and what did not:

| Gap | State |
|---|---|
| The paid `gen-trace` call passed neither prompt-length flag nor `--timeout-ms`, so it used the defaults of 200 and 40,000 characters and 30,000 ms rather than the resolved 1,174 and 42,579 and the CR's 60,000 | **closed.** `hack/m5c-matrix.sh` now carries `PREMIUM_PROMPT_CHARS`, `NOISY_PROMPT_CHARS` and `REQUEST_TIMEOUT_MS` beside `MODEL_REVISION` and passes all three on both generation calls — the paid one and the plan-only one, because a plan checked against different traffic than the run sends is not a plan |
| `spec.GPUClass` was never examined and `MinRequestsPerRun` was checked against the harness floor of 100 and then dropped, so the registered floor of 1,000 reached nothing | **closed.** Both are carried on `Plan` now. A compiler that silently narrows what it was asked to execute makes "zero refusals" mean less than it says |
| The resolution table's first comment claimed the prompt corpus was recorded and it was not, so changing `promptCorpus` would leave both copies of the table agreeing with each other and with nothing the sender emits | **closed.** `print-prompt --corpus-sha` prints it from the binary that owns it, the resolver records it, and the comparison test checks it against `PromptCorpusSHA256`. Mutating one character of it reddens that assertion and nothing else |
| `CompilePlan` is called by nothing but tests | **open.** The compiler still is not wired into the paid path. Passing the resolved lengths removed the specific damage this caused; it did not make the compiler a gate |
| The completion invariant certifies string presence, not a result: `Completed` can carry a report URI and a ratio interval with no p99 and no point ratio, because both are `+optional` | **open, and it is a design decision rather than an oversight.** Making them required would refuse a status update that records a partial outcome, and this page has not settled what a partial outcome should look like. The mutation test establishes that one presence constraint is enforced and nothing broader |

Run against `config/samples/platform_v1_gpusharingbenchmark.yaml` — the protocol this page registered — it
refuses, in ten places:

| Field | Registered | What the harness does |
|---|---|---|
| `baseline.tenant`, `contender.tenant` | `tenant-premium`, `tenant-standard` | The generator writes the fixed identities `premium-1` and `standard-noisy` into every trace row. |
| `baseline.model`, `contender.model` | `llama3-8b` | The topologies serve `Qwen/Qwen2.5-3B-Instruct`; the gateway answers `ErrNoRoute` for any other name, once the engines are up. |
| `baseline.outputTokens`, `contender.outputTokens` | 128, 256 | Hard-coded at 64 and 16, and sent as `max_tokens` — a cap, not a generation length. |
| `warmupRequests` | 50 | No warmup phase and no exclusion boundary exist. Dropping leading rows afterwards is not the same protocol: with open-loop arrivals the requests straddling the boundary are still in flight when measurement begins. |
| `baseline.inputTokens`, `contender.inputTokens` | 256, 8192 tokens | The generator is configured in CHARACTERS, and `ceil(chars/4)` is not invertible — the committed calibration measures it 36 percent low at 200 characters and 30 percent high at 40,000. |
| `load.generator` | `genai-perf` | Not installed here and used by no run. A manifest naming a generator that did not produce the traffic identifies the wrong tool. |

What it accepts matters as much, because a checker that refuses everything cannot be told from one that does
not work: `load.mode: openLoop` is what `Replay` already does, `load.retries: 0` is honoured because the
sender never resubmits a logical request, `streaming: true` is required by the SSE reader, `repetitions: 5`
meets this CRD's own floor, and `minRequestsPerRun: 1000` clears the harness floor of 100.

### Two of my own earlier findings were wrong, and the correction matters

I first reported `openLoop` as absent because the camel-case token appears in no non-test file. It is
**implemented** — `Replay` dispatches each request at its scheduled offset without waiting for earlier
responses, and says so in its own comment. Absence of a name is not absence of a behaviour. `retries` was
the same mistake in the other direction: the sender makes one call per logical request, so `retries: 0` is
not unsupported, it is already the behaviour.

### Three sample floors

`MinTailSamples` is 100, the throughput ladder uses 500 privately, and this CRD requires 1000. The 100 is
derived rather than chosen: below it the nearest-rank p99 index lands on the maximum observation, so a run
with fewer than 100 victim completions reports its slowest request and calls it a tail.

### The mutation

Deleting the `warmupRequests` refusal was predicted to redden exactly two things — the per-field case and the
sample test's assertion — and it did, with the other twelve cases green. Each refusal is asserted by the
substring naming its own cause, never by counting refusals, because a count passes when two merge or one is
replaced by another.

Recorded outside this repository as
`storage/gpu-platform-control-plane/defects/open/2026-09-30-the-committed-sample-cr-cannot-be-executed`.

## Amendment, 2026-09-30 (sixth): the input length is resolved into the plan, not redefined in the spec — and that is blocked on an identity nothing records

Nine of the ten refusals above have an obvious adapter: lift two tenant constants, read the two output caps
from the spec, implement a warmup phase, name the real generator, use the served model name. The tenth is
the input length, and three ways of closing it were considered: redefine the CR field in characters, convert
tokens to characters, or carry both.

**None of those is the choice.** The resolved character length belongs in the execution plan, not in the
registration. A spec says what the experiment is; how many characters produce a given token count under a
particular tokenizer is an implementation of that declaration, and putting it in the API would move a
computation into the protocol. An `inputChars` field would only be right if an operator needed to constrain
character length *independently* of token length, and nothing here does.

So `inputTokens` stays as declared, and the plan carries a character length that has been **verified** rather
than estimated: generate a candidate with the prompt corpus, tokenize the complete templated request, accept
only a candidate whose count equals the declaration, and refuse if none is found in the supported range. An
affine fit to the calibration points is a fine way to seed that search — the fit
`30.30 + 0.19163 * chars` has residuals under 1.1 tokens at all three — but acceptance depends on the exact
count, never on the fit.

### Why that is not implemented yet

The first step of that procedure cannot be taken. It needs the served tokenizer and chat-template identity,
and this repository does not record one:

| Where an identity would live | What is actually there |
|---|---|
| `internal/bench/testdata/tokenizer_calibration.json` | A model name and a corpus hash. Its own comment claimed the tokenizer was "at the recorded revision"; no revision is recorded. |
| `config/vllm-shared/engine-a.yaml` | The vLLM image is digest-pinned. The model is passed by name with no revision argument. |
| `RunManifest.TokenizerRev` | Declared, documented as recording exactly this, and **written by nothing**. |

That last row is the same shape as `GatewaySHA` and `ImageDigests`, which were declared and unwritten until
a guard was built for them. `TokenizerRev` was not in that repair.

So `CompilePlan` still refuses the input length, and its refusal now says why correctly. The earlier wording
blamed the estimator for not being invertible, which is not the obstacle: the obstacle is that there is
nothing to resolve *against*. Measuring the revision and filling `TokenizerRev` is the unblocking step, and
it needs an engine started once — not a rented GPU, since the calibration itself was captured on a CPU image.

### Unblocking step taken, 2026-09-30: the tokenizer identity is measured and demanded

The revision is measured. `Qwen/Qwen2.5-3B-Instruct` is at
`aa8e72537993ba99e69dfaafa59ed015b17504d1`, and the calibration file now records that revision, the sha256
of each tokenizer file at it, a combined hash of the four core files with the combining rule written out, and
the sha256 of the chat template itself. Only the tokenizer files were fetched; the weights were not.

The file's `tokenizerSharedWith` claim is now established rather than asserted: `Qwen/Qwen2.5-7B-Instruct`
carries byte-identical copies of all four core tokenizer files: the merges list, the tokenizer definition,
the tokenizer config and the vocabulary. The two repository revisions differ, so the repo hash alone would
have said nothing — the per-file hashes said it. Those four are named in prose rather than in backticks
because they live in an upstream model repository and not in this one, and the docs gate resolves a
backticked name as a path here. It caught three of them on the first run of this amendment, correctly.

`RequireProvenance` now demands `tokenizerRev`, and `commitShaped` is deliberately **not** reused for it.
That function accepts 7 to 40 hex characters and a `-dirty` suffix, both meaningful for a build of this
repository and meaningless for an upstream model revision: a prefix would let two different tokenizers share
one recorded identity, and nothing upstream is dirty. A separate check demands exactly 40 lowercase hex.

**Two paths write a manifest, not one.** `gen-trace` and `prepare-traces` both construct a `RunManifest`,
and the flag had to go into both — adding it to one would have left the M5-b path refused at its first
replay, with both engines already up. That is the most expensive place in this project to learn anything,
and it is where the model-name mismatch was learned once already.

### What this did not fix, and one mistake worth recording

The resolver still does not exist. An identity makes it possible; it does not make it written. `CompilePlan`
keeps refusing the input length until something can tokenize a candidate and compare the count.

And the guard that demands the revision in `hack/m5b-arms.sh` was first placed beside `GW_SHA`, which sits
after `go build`, `docker build`, the ECR login and the image push. Three attempts to trip it deliberately
all stopped on an earlier refusal instead — `RATE`, then the TTL deadline, then `REGISTRY` — and a control
run that supplied the value stopped on the same line, which is what showed the guard had never executed.
It moved to the pre-spend block beside `RATE` and now fires in both directions. A refusal placed after the
spending it was meant to prevent is not a guard, and the only way that surfaced was trying to break it.

### Unblocked, 2026-09-30: the input length is resolved by measurement

The tenth refusal is closed. `CompilePlan` no longer refuses every positive `inputTokens`; it looks the count
up in a table measured against the served tokenizer, and refuses only a count nobody has swept.

`hack/resolve-input-lengths.sh` does the sweeping. It fetches the tokenizer files at the pinned revision
(no weights — 3.7 GB of safetensors would add nothing to a token count), generates candidate prompts through
`benchharness print-prompt` so the corpus and its tiling stay in Go and are not reimplemented, tokenizes the
complete templated request **inside the serving image itself**, and accepts only a candidate whose count
equals the declaration.

| Declared | Resolved | Matches in the window |
|---|---|---|
| 256 tokens | **1174 characters** | 8 |
| 8192 tokens | **42579 characters** | 3 |

**The objection against importing a tokenizer does not apply here, and that was measured rather than
assumed.** `cmd/benchharness/exacttokens.go` refuses to vendor one because it would be "a second copy of a
decision that lives in the served model". This tokenizes inside the digest-pinned serving image, and that
image carries `transformers 5.15.0` and `tokenizers 0.22.2` — the same versions as the CPU image the
calibration was taken with. It is the same implementation, not a copy of it.

**The search is linear, and it has to be.** The token count is not monotone in the character count: over
100..400 characters it decreases 29 times, because byte-pair merges differ at the boundary. A binary search
would step over answers that exist — the external review warned against assuming monotonicity, and the
measurement agreed with the warning. An affine fit to the calibration points places the window and the
window is swept exhaustively.

**Several lengths give the same count, so the rule is the smallest.** Eight character lengths produce 256
tokens in a 301-wide window and three produce 8192. The smallest is the fewest bytes on the wire for the
declared count, and the table keeps the full list so the choice is visible rather than implied. Mutating the
recorded value to 1175 — a member of that list, but not the smallest — reddens both the table comparison and
the plan test, so the rule is enforced and not merely stated.

**The resolved length lives in the plan, not in the CR.** `Plan.BaselinePromptChars` and
`Plan.ContenderPromptChars` carry it, with `Plan.TokenizerRevision` beside them. That is the boundary this
page settled in its sixth amendment: the spec says what the experiment is, and how many characters produce a
token count under one particular tokenizer is an implementation of that declaration.

What this does not establish: that the engine will agree. The engine is the authority on its own count and
`stamp-exact-tokens` asks it at run time. If the two disagree the engine is right and the table is stale,
which is what the recorded revision exists to make noticeable.

### Two corrections this amendment carries

**`outputTokens` is a ceiling, not a length.** The field comment said "the generation length per request"
while the sender passes it as the engine's `max_tokens`, an upper bound. A response that stops earlier is
shorter and nothing makes the engine emit that many. Field comments ship to operators as the CRD
description, so that was a promise the code does not keep. The comment now says ceiling and records what it
used to say.

**Seven comments carried a wrong calibration figure**, because the two estimator errors are conventionally
normalised against different denominators. At 200 characters the estimate is 50 against a measured 68 — 36
percent of the estimate, 26.5 percent of the measurement. At 40,000 the estimate is 10,000 against 7,695 —
30 percent of the measurement, 23 percent of the estimate. The calibration file mixed 36 with 30; seven
comments mixed 36 with 23. All seven now say 30 and quote the raw pairs, and the calibration file now says
to quote the pairs rather than a percentage. Its claim that the ratio "is not monotone" was also wrong on
its own three samples, which decrease monotonically at 1.36, 0.774 and 0.770; what they establish is that no
single multiplicative factor fits all three.

**It is a nominal 95% interval.** Five repetitions are enough to compute this statistic and to bootstrap it.
They are not enough to establish 95% coverage, and more bootstrap draws do not create more repetitions. Every
`b_i` and `c_i` must be published alongside the summary so a reader can see the sample the interval came
from. Calling it "the 95% interval" without that qualification would be the same overclaim this project has
had to withdraw four times elsewhere.

### Why the ratio interval is primary, not the colocated one

The experiment asks about *relative* interference and its baseline is **measured, not known**. An interval on
the colocated p99 alone carries no uncertainty for the denominator, so it cannot bound the quantity the
experiment reports. A colocated-only interval plus a point ratio is defensible as explicitly limited
descriptive reporting, and it does not satisfy what `docs/04` asks for.

So `p99CI95` **keeps its current meaning** — the interval on the colocated median p99, in milliseconds — and
a separately named field carries the ratio interval. Redefining `p99CI95` from milliseconds to a dimensionless
ratio would silently change the units of a field whose comment ships to operators in the CRD description.

### What this forces

| In the registration / API | In the code |
|---|---|
| Name the latency endpoint explicitly as victim TTFT p99, and define `B`, `C`, `R`, the pairing, the exclusions and the bootstrap method here and in `docs/04`. | A dedicated median-and-ratio analysis function. `BootstrapCI` must **not** be reused: it bootstraps the mean of its inputs, and changing it in place would silently alter the M5-b and price-of-protection studies that already depend on it. |
| Restate `baselineP99Ms` and `colocatedP99Ms` as medians of repetition-level p99s, not pooled p99s. Keep `repetitions >= 5`. | Derive `b_i` and `c_i` from validated raw records and the explicit block identity, not from a pooled pass. |
| Add `interferenceRatioCI95` beside `p99CI95`. Adding a status field regenerates the CRD, which is a deliberate step, not a side effect. | Compute both intervals from the same bootstrap draws, and freeze the rounding so the published integer millisecond fields and the published ratio agree to a documented precision. `interferenceRatio` is defined as `colocatedP99Ms / baselineP99Ms`, so computing it from unrounded values while publishing rounded integers would contradict its own definition. |

### The repetition count is contradicted in three places

While settling this, a second disagreement of the same shape turned up. Three parts of this repository name a
different number of repetitions:

| Where | Number |
|---|---|
| This CRD — `repetitions` has `+kubebuilder:validation:Minimum=5` | **5 or more** |
| `hack/m5c-gpu-session.sh` — its own comment: "a pilot is one repetition and a confirmatory run is three" | **3** |
| `hack/m5c-matrix.sh` — `REPS="${REPS:-4}"`, justified as a bootstrap-block argument | **4** |

A run bought at three or four repetitions **cannot be published into this CRD at all**: the API refuses the
spec. That is the schema working, but it means the paid runner as it stands would buy evidence this type
cannot accept, and nothing in either script knows that. The session script deliberately has no `REPS` default
precisely so the number is a decision — which is right, and is why this is a mismatch to resolve rather than a
default to fix. Resolving it is part of the execution plan that must exist before the GPU is rented, not part
of this amendment.

### What is still not decided here

Nothing in this amendment establishes that a number came from hardware. The three bindings from the second
amendment — evidence to run, evidence to CR, and now a frozen analysis contract — are what a writer needs, and
only the third is settled by this page.

## Amendment, 2026-09-30 (fourth): the schema now enforces the ratio interval, and one of these specs proved nothing at first

`interferenceRatioCI95` shipped as a field, and the completion invariant was widened to demand it. The third
amendment made the ratio interval the primary reported object; leaving it optional would have let a benchmark
reach `Completed` carrying a point ratio with no spread — which is the shape the completion rule was written
to refuse in the first place, one field over. The rule now reads:

```
!has(self.phase) || self.phase != 'Completed' ||
  (has(self.result) && has(self.result.reportUri) && size(self.result.reportUri) > 0
   && has(self.result.interferenceRatioCI95) && size(self.result.interferenceRatioCI95) > 0)
```

`p99CI95` kept its milliseconds and its meaning: the interval on the colocated median p99. Two intervals,
two units, two names.

### The specs, and what the mutation showed

Three specs were added and one existing spec was widened. The clause was then deleted from the **generated
CRD** — parsed and removed as a YAML value, never by cutting lines, because a broken YAML installs nothing
and `Ran 0 of N` is a harness failure rather than a discriminating test. The prediction was written down
first: exactly two specs should redden.

| | Prediction | Result |
|---|---|---|
| Unmutated baseline | 38 passed, 0 failed | 38 passed, 0 failed |
| Clause deleted | 36 passed, 2 failed — `with a report but no ratio interval`, `with an empty ratio interval` | exactly that |

The third new spec, `refuses Completed with a ratio interval but no report`, stayed green under the mutation,
which is the point of writing it: each clause has one spec where the **other** field is supplied, so neither
clause can hide behind the other. Without that pairing, deleting the `reportUri` clause would still leave
every object refused — by the ratio clause, with a message the tests never read.

### One spec proved nothing on its first run, and it looked like a refusal

`refuses Completed with a ratio interval but no report` failed its first run, and the failure was mine:
the object name was `gsb-done-ciNoUri`, which is not an RFC 1123 subdomain, so `Create` was rejected before
any status update happened and the CEL rule was never evaluated. A red spec whose refusal comes from a
different rule than the one under test is the same false reading as a green one that never ran. Read the
refusal text, not the colour.

The envtest run before it reported `Ran 0 of 117` with every spec skipped, because `--bin-dir bin` is a
relative path and `-p path` then answers with one, so `fork/exec bin/k8s/.../etcd` found nothing. `Makefile`
passes `$(LOCALBIN)` absolutely for exactly this reason. Neither failure was a defect in the schema, and both
would have read as one.
