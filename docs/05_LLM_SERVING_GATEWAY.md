# LLM Serving Gateway

> Design of record: `docs/superpowers/specs/2026-06-28-m4-b-gateway-design.md` (M4-b, codex-reconciled) plus the M5 extension `docs/superpowers/specs/2026-07-04-m5-admission-guard-design.md`. **Status (2026-10-12): deployed on kind, and on EKS it has served one tenant's request once.** The 2026-09-25 GitOps cycle put it on a real cluster and the request came back `403 no_policy`, which is the auth layer answering. On 2026-10-12 a second cycle routed a tenant's streaming request through it, under HoldCap admission, to a controller-rendered vLLM engine on an A10G, and the answer came back 200 (`hack/eks-serve/runs/20261012T095840Z/README.md`). The banner said "never on EKS" until 2026-09-30, which that cycle had already contradicted. M4-b (routing/auth/rate-limit/proxy/metrics) is merged. The gateway runs on kind from `config/gateway-kind` in front of a stub backend (`hack/observability-kind.md`, `hack/chaos-fr002-serving-pod-killed.md`), was driven by the benchmark harness through its real pipeline on kind with no GPU (`hack/m5b-gateway-path.md`), was chained to a real vLLM running on CPU (`hack/m5b-chain-live.sh`, where the `InferenceDeployment` is a routing record; the CRD could not describe a vLLM container then, and since 2026-10-11 describes one pinned engine, see "Per-backend HoldCap" below), and was deployed into the kind cluster of the paid A10G sessions. One request on EKS, in a session torn down the same hour, is not operation, so nothing here is an operational claim. The M5 KV-cache-aware admission guard has since run against a real GPU — four paid repetitions on 2026-09-03, where it missed its pre-registered 1.25x premium-tail target at 83.7x and the harness declared the run invalid — and its vLLM metrics fixture is now a real capture from the pinned image, which replaced a synthetic one whose assumptions it falsified. (This line read "built and unit-tested — never deployed" until 2026-09-17, while `docs/06` said "The gateway IS deployed" and the paid session logs showed it serving traffic.)

The gateway is not the main feature; it is the runtime boundary that makes the GPUaaS control plane actually usable, and it enforces Layer 4 of admission — statically via the token bucket (M4-b) and dynamically via the KV-cache-aware admission guard (M5).

## Responsibilities (M4-b "minimum done")

| Function             | Detail                                                                                                                               |
|----------------------|--------------------------------------------------------------------------------------------------------------------------------------|
| tenant resolution    | `Authorization: Bearer <key>` → tenant via the `gateway-api-keys` Secret                                                             |
| tenant provisioning  | tenant → `GPUQuotaPolicy` (`spec.tenant` match); no policy → 403                                                                     |
| token bucket         | per-tenant `rateLimit{requestsPerMinute,burst}` from the policy → 429                                                                |
| model routing        | body `model` → `InferenceDeployment` with `spec.model.name == model` in the policy's `targetNamespace` (cache field index) → Service |
| proxy                | `httputil.ReverseProxy`, streaming-safe (`FlushInterval`), 502/504 mapping, upstream 5xx passthrough                                 |
| OpenAI compatibility | `POST /v1/chat/completions` only (ADR-3); `/v1/embeddings` deferred                                                                  |
| metrics              | 23 `gpuaas_gateway_*` series on a separate `:8081` (`internal/gateway/metrics.go`, `holdcap.go` for the per-backend mode, `routing.go` for routing) |
| audit                | structured logs with tenant, model, `request_id` (generated if absent, forwarded + echoed)                                           |

## Identity chain (canonical)

```
API key --(Secret gateway-api-keys)--> tenant
tenant  --(GPUQuotaPolicy spec.tenant)--> policy   (0 → 403; >1 → deterministic oldest + warn)
policy.spec.targetNamespace --> namespace to route InferenceDeployments in
policy.spec.rateLimit       --> token-bucket config (nil → unlimited, logged + metric)
```

## Error contract

| Condition                                       | Status      | canonical `error.code`      |
|-------------------------------------------------|-------------|-----------------------------|
| wrong method/path                               | 405 / 404   | —                           |
| missing/unknown API key                         | 401         | `unauthorized`              |
| tenant has no GPUQuotaPolicy                    | 403         | `no_policy`                 |
| token bucket exhausted                          | 429         | `rate_limited`              |
| guard engaged, standard-tier long-context (M5)  | 429         | `kv_cache_pressure`         |
| malformed JSON / missing model                  | 400         | `bad_request`               |
| body outside the M5-b request profile           | 422         | `profile_violation`         |
| body too large                                  | 413         | `payload_too_large`         |
| input larger than the bucket can ever hold      | 413         | `payload_too_large`         |
| no InferenceDeployment for model                | 404         | `model_not_found`           |
| upstream connect/refused/DNS                    | 502         | `bad_gateway`               |

> ⚠️ **The two 413 rows share a status AND a code**, and they are different refusals: a body over the size cap
> is turned away before admission runs, while an input larger than the bucket can ever hold IS an admission
> decision. They are told apart by `X-Admission-Reason`, which the gateway sets to `input_exceeds_burst` on the
> second and leaves absent on the first, since admission never ran for it.
>
> The gateway has always sent that header — it is set for any non-empty reason before the refusal branch is
> reached. What was missing until 2026-09-28 was on the reading side: `internal/bench/report.go` classified
> every 413 as work the bucket shed, so a body-limit refusal was attributed to the guard and entered both terms
> of the admitted-work fraction. The signal was there and nothing consumed it.
>
> ⚠️ Four of these codes were wrong until 2026-09-19, and the oversized-body row named the wrong status as
> well. The document said `unknown_api_key`, `tenant_not_provisioned`, `invalid_request` and
> `upstream_unreachable`; `errorCode` in `internal/gateway/proxy.go` has always returned `unauthorized`,
> `no_policy`, `bad_request` and `bad_gateway`, and an oversized body is refused with 413, not 400. Every one
> of them reads as a plausible name, which is why nobody caught them by reading. `hack/check-doc-symbols.sh`
> now fails on a name the repository never mentions.
| upstream timeout/deadline                       | 504         | `upstream_timeout`          |
| upstream HTTP 5xx                               | passthrough | (upstream body, unmodified) |

The two 429 sources are deliberately distinguishable — the M5 flagship's R3/R4 comparison depends on telling them apart in logs and metrics.
`rate_limited` carries `Retry-After` set to the seconds until the tenant's next token, rounded up, plus 0 or 1 at random so clients refused together do not return together; an admission 429 carries a fixed `Retry-After: 5`, since the gateway cannot compute when pressure clears.

## M5 extension — KV-cache-aware admission guard

The token bucket is static; it cannot protect a premium tenant's p99 from a *within-limit* long-context noisy neighbor on a shared vLLM instance. The guard scrapes the backend's KV-cache usage and waiting-queue depth (pinned vLLM image, golden `/metrics` fixture), and while pressure is engaged (hysteresis-guarded) selectively rejects standard-tier long-context requests. Design, thresholds, tier model, and pre-registered success criteria: the guard spec. Flagship experiment protocol: doc 04.

## Admission modes and priority binding

`--admission-mode` selects one admission control (`internal/gateway/admission.go`, `prospective.go`):

- `off`, the default, admits everything that passed the token bucket.
- `static-cap` is a pressure-blind input-token bucket per backend.
- `kv-aware` is the guard above.
- `prospective` reserves a standard-tier request's estimated input tokens and a stream slot per backend before forwarding. It releases the input at the first body byte the client receives and the stream when the request ends. Both caps (`--admission-prospective-prefill-tokens`, `--admission-prospective-streams`) are required and have no default, and a reserved request is never sent to a fallback backend.
- `serial-prefill` holds a standard-tier request until no other standard-tier request on its backend is in prefill, and refuses it with 429 after `--admission-serial-prefill-max-hold`.
- `fixed-spacing` admits standard-tier requests to a backend no closer together than `--admission-fixed-spacing`, holding each for at most `--admission-fixed-spacing-max-hold`.

`--bind-priority` writes the tenant tier's engine priority into every forwarded body (premium 0, standard 1), overwriting any caller value, and reports it in `X-Engine-Priority`. It only matters to an engine started with `--scheduling-policy=priority`.
Without the flag, the gateway binds the tier anyway when every backend a request may still be sent to is an engine the controller reports in force, its `EngineInForce` condition True for the current generation (set once every serving Pod runs the template rendered from `spec.engine`), because every rendered engine schedules by priority; without a bound tier all requests reach it at one priority and the policy does nothing. The hold-cap product study measured that on EKS: the product's Off left the premium TTFT p99 at 6 to 10 s where the lab's off, which bound the tier, gave about 1.5 s (`hack/eks-serve/holdcap-study/runs/`). A request that may fall back to a backend the controller does not render stays unbound, since that engine may not accept a priority.
Unbound does not mean caller-chosen: such a request that may still reach a rendered engine has any `priority` the caller sent removed, because the rendered head would otherwise schedule a standard tenant's -100 ahead of premium's 0. Only a request that can reach no rendered engine keeps the caller's field.

Both are off by default. They are M5-b's successor mechanisms, shown correct on kind (`hack/test/rehearse-prospective-admission.sh`) (`docs/superpowers/specs/2026-10-06-m5b-stays-closed-and-what-a-successor-needs-first.md`). `prospective` has not been measured for protection. Priority binding has, only as a constant: every arm of the admission studies ran with `-bind-priority` (`hack/lib/prospective-pilot.sh`), so its own effect was not separated. `serial-prefill` and `fixed-spacing` were measured on an A10G: the hold alone left the premium tail at 0.99 of off's, with the engine's cap it cut it to about 0.30, and a fixed spacing tuned at that load tied within 15% (`docs/11_WHAT_THIS_MEASURED.md`, Finding 9).

### Per-backend HoldCap

An `InferenceDeployment` with `admission.mode: HoldCap` and an `engine` is admitted by serial-prefill with its own `admission.maxHold`, whatever `--admission-mode` says.
The two never stack: the process-wide mode has no say over a HoldCap backend.
The controller renders the measured vLLM engine for it, with `--long-prefill-token-threshold=384` (`internal/controller/inference_engine.go`).
The gateway applies HoldCap only while the object's `status.admission` reports HoldCap for its current generation and its spec still asks for it (`backendAdmission` in `internal/gateway/router.go`).
The controller reports HoldCap only once the capped engine is the only one serving.

On a HoldCap backend:

- every request carries its tier's engine priority, whether or not `--bind-priority` is set;
- a request is never sent to another backend, premium included, and a fallback never enters a HoldCap backend;
- a standard-tier request that does not stream, or asks for other than one choice, is refused with 400 (`holdcap_requires_stream`, `holdcap_single_choice`), because the hold is released by the first content event.

`gpuaas_gateway_backend_admission_mode{namespace,name,mode}` shows, per backend, whether it gets `hold-cap` or the process-wide mode (`gateway`).

What the evidence licenses: HoldCap was measured on one A10G, one engine version, one model (Qwen2.5-3B-Instruct) and one streaming load, in three registered blocks, against no admission (`docs/11_WHAT_THIS_MEASURED.md`, Finding 9).
A fixed spacing tuned for that load tied with it within the registered 15%, so HoldCap offers protection that needs no tuning, not the lowest tail and not an SLO.
It raises standard-tier latency and refuses a standard request held longer than `maxHold`.

The rendering itself was checked on a real engine on 2026-10-11 (`hack/holdcap-conformance/runs/20261011T030610Z/README.md`).
The engine the controller started reported the measured arguments with the cap, status turned HoldCap only once that engine was ready and Off 0.1 s after HoldCap was turned off, and Recreate rolled to an engine without the cap.
That session ran no gateway and measured no latency.

Known gaps, none of which holds requests for an engine without the cap:

- Editing the object, `maxHold` included, moves its generation, so the backend gets the process-wide mode until the controller reports HoldCap again.
- When HoldCap is turned off and the gateway's cache lags the new engine becoming ready, requests can be held briefly for the uncapped engine: no protection, and holds bounded by `maxHold`. The window is the cache lag plus up to `maxHold`, not the cache lag alone, because a request keeps the admission it was routed with while it waits. It has not been measured.
- A plain deployment ahead of a HoldCap one for the same model no longer falls back into it, so if the plain one is down, its requests fail.
- serial-prefill state lives in one gateway process. A gateway rollout under the default RollingUpdate briefly runs two, and each admits on its own.

### Routing across the deployments serving one model

Without a policy the gateway sends every request for a model to its oldest `InferenceDeployment` and keeps the others as fallback.
`spec.routing.policy` on an `InferenceDeployment` selects `RoundRobin`, `LeastQueue` or `PrefixAffinity` (`internal/gateway/routing.go`).
A policy applies only when every deployment serving the model in the namespace names the same one and none is HoldCap; any disagreement keeps the default ordering.

- `LeastQueue` picks the deployment with the fewest requests this gateway has outstanding on it.
- `PrefixAffinity` re-implements the approximate prefix index of Gateway API Inference Extension proposal 0602 and llm-d: a chain of hashes over 256-character chunks of the prompt, seeded with the tenant and the model, a per-backend LRU sized to the A10G engine's measured KV capacity (`internal/gateway/prefixindex.go`), and a load escape to the least-loaded deployment that is an uncalibrated heuristic.
- A routed response carries `X-Routing-Policy`, `X-Routing-Backend`, `X-Routing-Reason`, `X-Routing-Load` and, under `PrefixAffinity`, `X-Routing-Match`; `gpuaas_gateway_routing_decisions_total` and `gpuaas_gateway_routing_outstanding_requests` count the decisions and the outstanding requests per backend.
- The engine profile `v0.27.1-a10g-prefix-cache` is the measured profile with vLLM's prefix caching on; the CRD refuses HoldCap on it.

What the evidence licenses: nothing yet. None of the three policies has been measured; `docs/superpowers/specs/2026-10-27-prefix-aware-routing-design.md` registers the study that would, on two A10Gs, and it has been rehearsed on kind only.
The index and the outstanding counts live in one gateway process, so a second replica would route on its own view.

## Open WebUI principle

> Open WebUI must not connect directly to vLLM. It always uses the gateway as its OpenAI-compatible base URL.

This single rule is what makes it "a platform boundary" rather than "a UI bolted onto vLLM."

## Minimum metrics (M4-b)

```
gpuaas_gateway_requests_total{tenant,model,code}
gpuaas_gateway_request_duration_seconds_bucket{tenant,model}
gpuaas_gateway_rate_limited_total{tenant}
gpuaas_gateway_upstream_errors_total{tenant,model}
```

M5 adds the guard series (`gpuaas_gateway_admission_decisions_total`, backend pressure gauges — guard spec), and the prospective mode adds `gpuaas_gateway_admission_reserved_input_tokens` and `gpuaas_gateway_admission_running_standard_streams`, by backend.
Every series this component exposes carries the `gpuaas_gateway_` prefix (`internal/gateway/metrics.go`); this
line named it `admission_guard_decisions_total`, which matches nothing a scrape would return.

## Deployment

`config/gateway/`: Deployment `replicas: 1` (in-memory bucket — scaling multiplies limits; documented ADR), Service, ServiceAccount, minimal RBAC (`get;list;watch` on the two CRDs + the api-keys Secret). Definition of done for M4-b includes the Makefile target, a gateway Dockerfile, and these manifests — `go run` is not a deployment story.

`--metrics-bearer-token-file` makes `/metrics` on `:8081` demand `Authorization: Bearer <token>` read from that file, answering 401 with no metric bytes otherwise; unset, `/metrics` stays open as before, and the gateway refuses to start if the flag names a missing or empty file (`internal/gateway/metricsauth.go`).
`/readyz` on the same port stays open either way, because the kubelet's readiness and liveness probes call it without credentials; `config/prometheus/gateway_podmonitor.yaml` sends no token, so an operator who sets the flag also adds an `authorization` block referencing a Secret with the same token.

## Deferred

`/v1/embeddings` · distributed token bucket (Redis) · per-model limits · Open WebUI wiring · `platformctl` · ServiceMonitor.
