# The five decisions, settled — and the one that settles as a refusal

Date: 2026-09-21, written after `2026-09-21-what-a-violation-would-have-to-mean.md` and the four changes it licensed (#211, #212, #213, #215). That page ended with five things a definition must settle before it is written into code, and said each was a decision rather than a measurement. Four are answered below from evidence the repository now holds. The fifth is answered by declining, and the decline is written into the code as that page required.

**No threshold is set here either.** The bar remains unset for the reason `2026-09-09-what-would-have-to-change.md` gives; what changes is that the quantities a bar would apply to are now measured rather than hoped for.

## What was measured between the two pages

A locally built gateway, run against the kind cluster with one authenticated request, went from one `gpuaas` series to twelve. Four readings carried the arguments the earlier pages had only asserted:

| reading | what it settles |
| ------- | --------------- |
| `backend_attempts_total{model="demo-llm",tenant="premium"} 1` | the denominator exists and is populated by the proxy path alone |
| `upstream_errors_total{...} 2` | it is **attempt**-scoped: one request, two attempts (head and spare) |
| `time_to_first_byte_seconds_count{...} 1` | a 502 leaves a first byte — the error envelope **is** the byte |
| `time_to_first_byte_seconds_bucket{...,le="1.5"} 1` | the declared 1500 ms sits on a real edge, counted rather than interpolated |

The second line is the one worth keeping. `upstream_errors_total` reading 2 against a single request is the arithmetic `GatewayUpstreamErrorsReachingClients` was rewritten to avoid, observed live rather than reasoned about.

## 1. Where the objective lives — `InferenceDeployment.spec.slo`

`docs/02_CONTROL_PLANE_API.md:75` has advertised `slo: { ttftP95Ms, tpotP95Ms }` since `f13bdbf` (2026-08-07), and line 87 of the same document calls it target design, not yet built. Grepping `api/` for `slo`, `ttftP95` or `tpotP95` still returns nothing.

It lives there, and nowhere else. A second surface would mean two places to state one thing, in a repository that already advertises the first.

**It is not added in this change**, and the reason is decision 4: a field whose value nothing reads is a schema that has to be honoured forever in exchange for nothing. The order is consumer first, field second — which is why this page can settle where it goes without putting it there.

## 2. What is in the denominator — the proxy path, and only it

`requests_total` is incremented at four sites; only `server.go:533` describes a request the serving stack tried to answer. The other three (`fail`, `failUnresolvedModel`, `failReason`) end before any attempt. `backend_attempts_total` now names that population directly, incremented immediately before `tryBackends` at `server.go:517`, and `request_duration_seconds` and `time_to_first_byte_seconds` are observed on that same path — so all three agree on their population by construction rather than by convention.

Refusals stay out, on the rule `실행/W04-사전등록.md:18` already set: a refusal is a treatment, not a lost observation. A denominator that swept them in would let the gateway improve its own score by refusing more traffic.

**`_unresolved` routing failures are the serving stack's fault, and they are excluded anyway.** A model that resolves to no backend is a control-plane failure — the caller named something the operator was supposed to have created — but the request never reached an attempt, so it is outside this population by the same rule that excludes a 429. It is counted in `requests_total` under the `_unresolved` sentinel, where a separate question can find it.

## 3. What the predicate is — latency, and specifically first byte

Availability has a series already (`requests_total{code=~"5.."}`, alerted on since before these pages) and needs no new definition. Latency did not, and now has two.

The predicate, when one is written, is over `time_to_first_byte_seconds` rather than `request_duration_seconds`. The latter is whole-request duration (`server.go:532`), so for a stream it is dominated by how many tokens were asked for: two models whose serving begins equally fast differ there entirely by output length.

**This remains a lower bound on the declared objective, and the gap is unmeasured.** First byte precedes first token on a streaming response. A request above a given edge had certainly not produced a token by then; one below it may still have been slow to its first. The `le="1.5"` bucket makes the declared figure readable, which is not the same as making it a bar.

## 4. What consumes the budget — nothing, and the code now says so

`실행/W04-사전등록.md:18` states the honest position: there is no user and no product owner here, so these are benchmark thresholds rather than SLOs, and nothing exists to spend an error budget.

That is still true, and the previous page required the statement to live in the code rather than only in a document. It now does, in `internal/gateway/metrics.go`, next to the series a reader would otherwise assume something acts on.

**This is the decision that keeps the field out of the CRD.** An error budget with no consumer is decoration, and decoration in a metrics path is worse than an absence because it reads as a control. What would change it is a consumer — a release gate, an autoscaler input, a page — and that is a different page's work.

## 5. What "goodput" will mean — nothing new, here

It is not introduced for serving. `completedOutput` (`internal/bench/sharing_matrix.go:621`) already computes the quantity for the benchmark — output minus tokens that arrived on a stream that then broke — and renaming a measured thing buys confusion rather than clarity.

The word's one appearance in this repository (`internal/exputil/exputil_test.go:96`) is a **training** quantity: resume goodput minus restart goodput, in a comment on a bootstrap-CI test whose harness does not exist. That sense belongs to the checkpoint/resume work and keeps the word if that work ever claims it.

So: two axes, two names already in use, and no third.

## What this page does not settle

The bar. Every quantity above is now measured on this cluster, and none of them has a threshold, an alert, or a consumer. Setting one needs a stated service objective that does not read any run's results — which `2026-09-09-what-would-have-to-change.md` demanded, `docs/02`'s declaration predates the runs by a month and therefore satisfies, and which is still waiting on decision 4's answer to change.
