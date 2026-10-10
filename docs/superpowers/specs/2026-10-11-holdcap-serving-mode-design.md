# hold-cap as a supported InferenceDeployment serving mode (design spec)

Date: 2026-10-11 · Author: lkhun9311 · Status: approved in conversation, awaiting review of this page

Designed twice, independently, and reconciled: once by me and once by codex `gpt-6-astra` (high), neither reading the
other's draft first. Where a decision came from one side it says so. The owner chose the scope (the controller renders
the engine and the gateway applies the mode per backend) and the rollout guarantee (Recreate plus a status gate, below).

## Why

Finding 9 (`docs/11_WHAT_THIS_MEASURED.md`) is the one admission rule this project measured to protect a premium
tenant's time to first token on a shared engine: hold-cap, the gateway's serial-prefill admission together with the
engine's `--long-prefill-token-threshold=384`. Its premium p99 was about 0.30 of no admission on one A10G.
Today it is reachable only through benchmark scripts.
The engine half is a hand-applied Deployment (`config/vllm/deployment.yaml`), the gateway half is a process-wide
flag, and the only thing that keeps the two halves paired is shell (`hack/lib/prospective-pilot.sh`).
Neither half alone protected anything, so a platform that can set one without the other offers a setting that looks
like the measured rule and is not.

## What exists today

- `InferenceDeploymentSpec` has no engine fields.
  The controller renders `Args: {"--model", name, "--model-path", uri}` (`internal/controller/inferencedeployment_controller.go`,
  `mutateDeployment`), which is not vLLM's command line, so it cannot run vLLM.
- Every vLLM session so far applied the engine by hand and created a "routing record" InferenceDeployment (pause
  image, zero replicas) so the gateway could route; the controller marks that record Degraded with
  `DeploymentConflict`, and the scripts rely on it.
- The gateway reads only name, namespace, `spec.model.name` and `spec.port` from an InferenceDeployment
  (`internal/gateway/router.go`, `backendsFor`), and selects one admitter for the whole process
  (`cmd/gateway/main.go`, `newAdmitter`).
- serial-prefill keys its turn on the backend URL, which is the Service, not a Pod (`internal/gateway/serialprefill.go`).
- No InferenceDeployment webhook exists; validation is CRD markers and `config/policy/gpu-workload-static.yaml`.

## What the measurement had, exactly

The engine validator records every non-default engine argument the admission sessions ran with
(`hack/lib/prospective-pilot.sh`, `pp_expected_args`):
half precision, `max_model_len` 16384, `max_num_seqs` 64, `gpu_memory_utilization` 0.90, prefix caching off,
`max_num_batched_tokens` **512**, `scheduling_policy` priority, async scheduling off, iteration-detail logging, the
step-logging scheduler class, and a pinned model and tokenizer revision; hold-cap added the threshold 384.
The gateway ran `-bind-priority` in every arm, and hold-cap added serial-prefill with a 25 s hold.

The batch budget is 512, not the base manifest's 2048: the pilot rewrites it (`PP_BUDGET`).
My first draft carried 2048; astra's caught it, and the validator confirms 512.

## Design

### API (`api/v1/inferencedeployment_types.go`)

```go
type InferenceDeploymentSpec struct {
	// ... existing fields unchanged ...

	// engine selects an engine the controller renders itself. Absent keeps today's rendering.
	// +optional
	Engine *InferenceEngine `json:"engine,omitempty"`

	// admission selects how the gateway admits requests to this deployment.
	// +optional
	Admission *InferenceAdmission `json:"admission,omitempty"`
}

type InferenceEngine struct {
	// vllm renders the pinned vLLM profile.
	// +required
	VLLM *VLLMEngine `json:"vllm"`
}

type VLLMEngine struct {
	// profile is the engine configuration the admission study measured; it is the only one offered.
	// +kubebuilder:validation:Enum=v0.27.1-a10g
	// +required
	Profile string `json:"profile"`

	// modelRevision pins the model and tokenizer to a commit, as every measured session did.
	// +kubebuilder:validation:Pattern=`^[0-9a-f]{40}$`
	// +required
	ModelRevision string `json:"modelRevision"`
}

type InferenceAdmission struct {
	// +kubebuilder:validation:Enum=Off;HoldCap
	// +required
	Mode string `json:"mode"`

	// maxHold is how long a standard request may wait for its turn before it is refused with 429.
	// It has no default: zero would refuse every request that ever had to wait.
	// +optional
	MaxHold *metav1.Duration `json:"maxHold,omitempty"`
}
```

No free-form engine arguments in this version (astra's; my draft had an `extraArgs` list with owned flags refused).
A free list would let a deployment run HoldCap on an engine the evidence says nothing about, and every owned flag
would need its own refusal. A new profile is added only with its own measurement.

The cap, 384, is a constant rendered from the mode, not a field: 384 is the only value measured.

**Validation (CEL on the spec), each a refusal at admission:**

1. `admission.mode == HoldCap` requires `engine`: the controller can only guarantee the cap on an engine it renders.
2. `maxHold` is set exactly when the mode is HoldCap, and lies in 1 s to 25 s, the longest hold measured.
3. HoldCap requires `replicas <= 1` and `gpuCount == 1` (astra's).
   serial-prefill keys on the Service, so two replicas behind one Service would be serialized as one engine: each
   would wait on the other's prefill, which nothing measured.
4. `engine` requires `model.storageUri` of the form `hf://<org>/<repo>`; the engine downloads from the Hub at the
   pinned revision. Other schemes are refused until something mounts them.

Existing objects carry neither field and keep today's rendering, routing and global admission.
The benchmark scripts' routing records therefore keep working unchanged.

### Controller rendering

With `engine` set, `mutateDeployment` renders the profile instead of today's arguments:

- image: the vLLM v0.27.1 digest that `config/vllm/deployment.yaml` pins;
- arguments: the repository from `storageUri`, `--served-model-name=<model.name>`, `--port=<port>`, `--revision` and
  `--tokenizer-revision` from `modelRevision`, and the measured settings above;
- with HoldCap, also `--long-prefill-token-threshold=384`;
- the step-logging scheduler and iteration-detail logging are not rendered: they are instrumentation, and the
  measurement's own control arm shows that they ran in every arm, the one without protection included;
- the GPU toleration, `/dev/shm`, model cache and probes that the hand-written manifest carries;
- strategy `Recreate`, so a capped and an uncapped engine never serve at the same time.

The rendered template carries the annotation `platform.lkhun9311.github.io/admission: HoldCap|Off`, set from the same
value that decided the arguments.

### Status: the mode in force, not the mode asked for

New status field `status.admission: {mode, observedGeneration}` and condition `AdmissionInForce`.

`status.admission.mode` is HoldCap only when all of these hold:

- the spec asks for HoldCap;
- the Deployment has observed its current generation;
- its template carries the HoldCap annotation;
- updated, ready and desired replicas all equal 1;
- no Pod of an older ReplicaSet remains.

Otherwise it is Off, with the reason (`RolloutInProgress`, `ScaledToZero`, `NotRequested`).
Turning HoldCap off is reported Off at once: holding an engine that is losing its cap is the case to avoid, while
leaving a capped engine unheld costs only protection.

### Gateway

- `BackendRef` gains the admission mode and hold.
  `backendsFor` sets HoldCap only when the status says HoldCap, `status.admission.observedGeneration` equals the
  object's generation, and the spec still asks for HoldCap; anything else is Off for that backend.
- A per-backend admitter wraps the global one.
  A HoldCap backend is admitted by serial-prefill with its own hold, keyed by its URL as today.
  Every other backend gets the admitter the global flag selected, exactly as now.
  The global flag does not change or disable a HoldCap backend (astra's table: replacement, not stacking).
- A HoldCap backend binds priority by tier, premium 0 and standard 1, whatever `-bind-priority` says, because its
  engine is rendered with priority scheduling.
- Fallback is disabled for requests to a HoldCap backend, premium included (astra's).
  Today a premium request carries no reservation and so keeps fallback, which could carry it to a backend with a
  different contract.
- The per-backend mode is exported as a gauge, so the mode in force is visible.

### The guarantee, and the gap it leaves

**Guaranteed:** the gateway never holds requests for an engine whose rendered template lacks the cap, provided its
view of the object is current. A capped engine and an uncapped one never serve at the same time (Recreate), and HoldCap
is never reported in force while a rollout is incomplete.

**Not guaranteed (option A, chosen by the owner):** when HoldCap is turned off and the gateway's cache lags behind the
new Pod becoming ready, the gateway can briefly hold requests for the uncapped engine.
vLLM takes tens of seconds to load, so the window needs a cache lag of that order.
Its consequence is serial-prefill without the cap, the diagnostic's `hold` arm: no protection, holds bounded by
`maxHold`, nothing unsafe.
Closing it by construction is astra's option B: a Deployment and Service per configuration revision, activated only
after the gateway acknowledges it, and a 503 when anything is uncertain. It is recorded as follow-up work, not built.

**Also outside the guarantee:**

- Two gateway replicas each keep their own serial-prefill state and would not serialize together.
  `config/gateway` pins one replica already; the spec says so beside the field.
- A cancelled request releases its turn at the gateway, but nothing proves the engine stopped computing.
  That is today's serial-prefill behaviour, and it is unchanged.

### What the evidence licenses (field comments and docs)

The field comment ships in the CRD (`controller-gen` copies it), so it carries the envelope:
measured on one A10G, one model (Qwen2.5-3B-Instruct), one load and three traces, against no admission at all.
At that load, a fixed spacing tuned for it matched hold-cap's premium tail (v26).
What hold-cap offers is protection that needs no tuning, not the lowest tail, and not an SLO.
It raises standard-tier latency and can refuse a standard request after `maxHold`.
The predictions that a longer prompt breaks the tuned spacing, and that heavy traces exhaust hold-cap's contender
headroom, are the replay's, not measurements.

`docs/05_LLM_SERVING_GATEWAY.md` gains the serial-prefill, fixed-spacing and HoldCap modes, which it does not list today.

## Tests

Each test is written to fail when the guarantee breaks, and each is mutated once to show that it does.

| Test | What it pins | Mutation that must turn it red |
|---|---|---|
| envtest: CRD validation | each CEL refusal (1–4); old manifests still accepted unchanged | delete each rule from the generated CRD |
| envtest: rendering | profile arguments exactly once each; cap present exactly when HoldCap; Recreate; annotation matches the arguments | drop the cap; render the cap under Off |
| unit: rendered arguments against the measurement | the rendered vLLM arguments equal `pp_expected_args` for the hold-cap arm, minus the two instrumentation entries | change one profile value |
| envtest: status | HoldCap in force only after a complete rollout; Off while an old ReplicaSet has Pods; Off at once when turned off | read spec instead of the rollout |
| unit: `backendsFor` | spec HoldCap with status Off gives Off; stale observedGeneration gives Off | read the spec's mode |
| gateway pipeline | an Off and a HoldCap backend side by side; the global flag does not disable HoldCap; no fallback from a HoldCap backend, premium included; priority bound by tier | re-enable premium fallback |
| existing serial-prefill tests | unchanged and still green | — |

envtest runs with its assets set and is checked for skipped specs: `ok` with every spec skipped is not a pass.
The CRD is regenerated with `make manifests` deliberately, in this repository only, and its diff is read before it
is committed.

**What no test here shows:** that a real vLLM engine started from the rendered template has the scheduler the
arguments ask for. A paid session could show it with the existing validator, which reads the engine's own
`non-default args` line, but none is part of this work. It is proposed separately, and only the owner can approve it.

## Out of scope

- Option B (per-revision Deployments and Services, gateway acknowledgement, fail-closed activation).
- More than one engine replica, other GPUs, other models, and any profile other than the measured one.
- Moving the benchmark scripts off routing records.
- A shared limiter or multi-replica gateway.

## Order of work

1. API types, CEL rules and the regenerated CRD, with the validation envtest.
2. Controller rendering and the measurement-equality unit test.
3. Status in force, with its envtest.
4. Gateway: `BackendRef`, the per-backend admitter, priority, fallback and the gauge, with pipeline tests.
5. Docs: `docs/05_LLM_SERVING_GATEWAY.md`, the sample, and the envelope.

Each step is a commit; each code commit is reviewed by codex bare (`codex review --commit`), and `make lint`,
`go test ./...` and `make docs-check` run in full after it.
