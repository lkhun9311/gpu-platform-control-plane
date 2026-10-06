# LLM Serving Gateway

> Design of record: `docs/superpowers/specs/2026-06-28-m4-b-gateway-design.md` (M4-b, codex-reconciled) plus the M5 extension `docs/superpowers/specs/2026-07-04-m5-admission-guard-design.md`. **Status (2026-09-30): deployed on kind; on EKS only as far as authentication.** The 2026-09-25 GitOps cycle put it on a real cluster and the request came back `403 no_policy`, which is the auth layer answering — routing a tenant request through to a backend on EKS has not happened. The banner said "never on EKS" until 2026-09-30, which that cycle had already contradicted. M4-b (routing/auth/rate-limit/proxy/metrics) is merged. The gateway runs on kind from `config/gateway-kind` in front of a stub backend (`hack/observability-kind.md`, `hack/chaos-fr002-serving-pod-killed.md`), was driven by the benchmark harness through its real pipeline on kind with no GPU (`hack/m5b-gateway-path.md`), was chained to a real vLLM running on CPU (`hack/m5b-chain-live.sh`, where the `InferenceDeployment` is a routing record and cannot describe a vLLM container at all), and was deployed into the kind cluster of the paid A10G sessions. It has **never** been deployed to EKS or through the GitOps path, so nothing here is an operational claim. The M5 KV-cache-aware admission guard has since run against a real GPU — four paid repetitions on 2026-09-03, where it missed its pre-registered 1.25x premium-tail target at 83.7x and the harness declared the run invalid — and its vLLM metrics fixture is now a real capture from the pinned image, which replaced a synthetic one whose assumptions it falsified. (This line read "built and unit-tested — never deployed" until 2026-09-17, while `docs/06` said "The gateway IS deployed" and the paid session logs showed it serving traffic.)

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
| metrics              | 17 `gpuaas_gateway_*` series on a separate `:8081` (`internal/gateway/metrics.go`)                                                   |
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

## M5 extension — KV-cache-aware admission guard

The token bucket is static; it cannot protect a premium tenant's p99 from a *within-limit* long-context noisy neighbor on a shared vLLM instance. The guard scrapes the backend's KV-cache usage and waiting-queue depth (pinned vLLM image, golden `/metrics` fixture), and while pressure is engaged (hysteresis-guarded) selectively rejects standard-tier long-context requests. Design, thresholds, tier model, and pre-registered success criteria: the guard spec. Flagship experiment protocol: doc 04.

## Admission modes and priority binding

`--admission-mode` selects one admission control (`internal/gateway/admission.go`, `prospective.go`):

- `off`, the default, admits everything that passed the token bucket.
- `static-cap` is a pressure-blind input-token bucket per backend.
- `kv-aware` is the guard above.
- `prospective` reserves a standard-tier request's estimated input tokens and a stream slot per backend before forwarding. It releases the input at the first body byte the client receives and the stream when the request ends. Both caps (`--admission-prospective-prefill-tokens`, `--admission-prospective-streams`) are required and have no default, and a reserved request is never sent to a fallback backend.

`--bind-priority` writes the tenant tier's engine priority into every forwarded body (premium 0, standard 1), overwriting any caller value, and reports it in `X-Engine-Priority`. It only matters to an engine started with `--scheduling-policy=priority`.

Both are off by default. They are M5-b's successor mechanisms, shown correct on kind (`hack/test/rehearse-prospective-admission.sh`) and not measured for protection (`docs/superpowers/specs/2026-10-06-m5b-stays-closed-and-what-a-successor-needs-first.md`).

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

## Deferred

`/v1/embeddings` · distributed token bucket (Redis) · per-model limits · Open WebUI wiring · `platformctl` · ServiceMonitor · auth on `/metrics`.
