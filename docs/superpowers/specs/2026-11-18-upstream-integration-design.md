# Upstream integration lanes: run upstream components where gpuaas has its own

Date: 2026-11-18. Status: proposed, owner review pending.

## Why

gpuaas built its own versions of components that upstream projects already own.
`internal/gateway/prefixindex.go` re-implements the llm-d / GIE approximate prefix index (docs/05_LLM_SERVING_GATEWAY.md, PrefixAffinity).
The serving reconciler writes `Deployment.spec.replicas` from the CR (internal/controller/inferencedeployment_controller.go), which rules out an upstream autoscaler.
Work on a home-grown copy finds defects only in the copy.
The upstream merges so far (llm-d-inference-sim #915, #920) came from gpuaas running the upstream simulator, and the A10G measurements that moved vLLM #59963 and #58420 ran upstream engine code.

## Principle

gpuaas owns tenant policy, the experiment, and the evidence.
Upstream components own routing, scaling and workload execution, and each one gpuaas adopts is pinned, covered by a gpuaas contract test, and exercised by a reproducible failure test whose upstream-only reduction is the contribution.

## What stays home-grown

- Tenant intent and policy: GPUQuotaPolicy, identity-to-namespace binding, quota ownership, trusted priority, bypass prevention.
- The measurement harness and its evidence rules: frozen traces, provenance, paid-session safeguards, the version study. It is the reference for every published number.
- HoldCap and the admission experiments, kept on the direct-backend path, because reserving against backend A while an EPP picks backend B is incoherent until both are coordinated.
- WorkloadRun and the distinction between quota reserved, ranks ready and work progressing.

## Lanes

| Lane | Upstream component | First gpuaas issue | Likely upstream output | Effort, risk |
|---|---|---|---|---|
| 1. Prefix-aware routing | llm-d-router EPP with GIE InferencePool, replacing new work on `prefixindex.go` | #599: replay the shared-942 shape through the approximate and precise prefix scorers on kind; endpoint delete/recreate and cancellation tests | Regression tests or fixes for endpoint churn, stale cache state, simulator conformance | 5–7 days, medium |
| 2. Autoscaling under partial telemetry | AIBrix PodAutoscaler | New: stop the reconciler from owning replicas when an autoscaler is declared; replay AIBrix #3439's missing-metric scenario on simulator pods | Failure and recovery coverage beside the fix the #3439 author offered | 4–6 days, medium |
| 3. Load generation | inference-perf for new client capabilities; the registered harness stays the scorer | New: run one frozen trace through inference-perf and check equivalence of send time, first content, timeout, cancellation and usage on a deterministic SSE fixture | Streaming accounting fixes, trace import, comparability docs (inference-perf #669 thread) | 3–5 days, medium |
| 4. Engine scheduling evidence | vLLM, SGLang scheduler code | Ongoing paid runs per upstream PR (#58420 done, #67811 done), plus the hybrid-model GPU track on L4 (separate $50 cap) | Measured validation, regression fixtures | per PR, needs owner approval per run |
| 5. Training admission (deferred) | Kubeflow Trainer TrainJob with Kueue | Replay the partial-placement and SIGTERM lab through TrainJob | Kueue/Trainer readiness and re-admission tests | 7–10 days, high |
| 6. Serving lifecycle (deferred) | KServe, LWS for multi-pod replicas, Dynamo later | One KServe-backed serving intent; an LWS worker-kill fixture | Status, rollout and group-restart coverage | 7–10 days, high |

#600 (EPP kill with queued requests under fail-open) is closed as covered upstream: llm-d-router #4203 and its open PR #4292 cover the hang, and docs/operations.md documents the 500 after the body was sent.
A kind run of #4292 under a force-deleted EPP is still useful as review evidence on that PR.
#601 (fault-reaction loop) stays a gpuaas issue; its Kueue side joins lane 5 if it is revived.

## Rules for each adoption

- One writer per field and one owner per decision: one replica writer, one admission owner, one endpoint selector. Write that contract before integrating.
- Pin the upstream version and keep an upgrade replay test, so a new upstream release that changes behaviour shows up as a failing gpuaas test.
- A suspected upstream defect is reduced to an upstream-only reproducer before any upstream post. A gpuaas-only defect stays local.
- Spend at most two days on a speculative contribution before there is a reproducer or a maintainer-backed direction.

## Risks and caps

1. Breadth eats the runway. At most two active lanes and one open upstream PR per project.
2. Adoption breaks the policy guarantees. Forged-owner and quota-accounting tests must pass before an adopted path is supported.
3. The single-GPU budget yields misleading comparisons. Kind for controller and routing correctness, the A10G or L4 for engine behaviour only, two engines on one GPU never stand in for independent replicas. Each paid run needs a written question CPU tests cannot answer and owner approval.

## Order, next four weeks

| Week | Work | Exit |
|---|---|---|
| 1 | Lane 1 on kind: pinned llm-d-router and simulator, two endpoints, #599 replay | Reproducible endpoint replacement and cancellation tests; HoldCap left on the direct path |
| 2 | Reduce the strongest routing discrepancy to an upstream-only fixture | Upstream test or fix, or a recorded conformance result and the lane stops growing |
| 3 | Lane 2: delegated replica ownership, #3439 scenario | Repeatable kind scenario and an upstream contribution or an already-covered record |
| 4 | Review rounds, replay against merged fixes, two case studies | Lane 3 only if review work leaves room; lanes 5 and 6 stay parked |

Brainstormed independently with codex (gpt-6-astra, high) and compared; codex could not read the gpuaas issue list, so the issue mapping above is mine.
