# What a violation would have to mean — constraints, pre-registered

Date: 2026-09-21. Written **before** any SLO field, violation predicate or error budget is added to this repository, and before any threshold is chosen. It pre-registers what a definition may rest on and what it may not. It does not define a violation, for the reason `2026-09-09-what-would-have-to-change.md` gives about its own lever 2: a bar chosen with the last run's numbers in hand is the post-hoc threshold-moving the `static-cap` arm was invented to forbid.

## Why this exists

The gateway exports thirteen Prometheus series and none of them says whether anything went wrong. `requests_total` separates 200 from 502, and an operator reading it has to supply the judgement that turns a count into a breach. Every figure this project would want to publish about operations — availability, attainment, time to recovery — needs that judgement to live in code rather than in the reader, because otherwise each retelling is free to pick the population that flatters it.

This page exists because the obvious next step is to write one, and three things found while checking the ground would each have made that step wrong.

## What is settled

**There is no prior definition to extend.** `goodput` appears exactly once in the repository, at `internal/exputil/exputil_test.go:96`, inside a comment on a bootstrap-CI unit test: "Per-repetition deltas (resume goodput minus restart goodput)". The test exercises `BootstrapCI` on five hard-coded floats. `internal/exputil` holds two files, and no resume-versus-restart harness exists anywhere — so that line names a planned training experiment, not an implemented measurement. `SLI`, `burn rate` and `budget burn` return zero hits in any spelling.

**The phrase "error budget" is already used here for something else.** `cmd/queuelabrun/compare.go:46` and `:102` use it for timer resolution: a finding compares two arms, so it carries both arms' floors and is tested against their SUM, and quoting the larger "understates the error budget by up to a factor of two". That is metrology, not reliability. It is prior art for nothing on this page, and a definition that reuses the phrase without saying so would collide with it in a file that already reasons carefully about it.

**An SLO surface is promised and absent.** `docs/02_CONTROL_PLANE_API.md:75` shows `slo: { ttftP95Ms: 1500, tpotP95Ms: 100 }` in an `InferenceDeployment`, and line 87 of the same document says the `runtime/autoscaling/slo/warmCache` fields "are the target design — later milestones, not yet built". Grepping `api/` for `slo`, `ttftP95` or `tpotP95` returns nothing: the field does not exist in the CRD types. So a definition written anywhere else creates a second SLO surface in a repository that already advertises this one.

## What this page may take, and what it may not

**May:** the series the gateway already exports and their recorded meanings; the population rules `실행/W04-사전등록.md` fixed on 2026-08-30; and the field names `docs/02` has already advertised.

**May not:** any threshold. Not `1500` ms, not `100` ms, not a target percentage. Those two numbers are illustrative values in a target-design YAML block; no run has measured them and nothing has ever been compared against them. Promoting an example into a predicate would make an unmeasured number normative, and it would do it in the one repository whose `CLAUDE.md` says a plausible wrong number is worse than a refusal.

## The population the code has already chosen

`requests_total` is incremented at exactly four places, and the split between them is the population boundary, already drawn.

| site | helper | reaches a backend | what it counts |
| ---- | ------ | ----------------- | -------------- |
| `server.go:217` | `fail` | no | 503 cache not synced (`:318`), 401 (`:322`), 403 (`:333`), 502 no route (`:341`), 503 (`:352`), 429 from the RPM limiter (`:358`), 413 (`:373`, `:485`), 400 (`:376`) |
| `server.go:238` | `failUnresolvedModel` | no | 404 and 502 for a model that resolved to no backend, under the `_unresolved` sentinel label |
| `server.go:249` | `failReason` | no | 429 from the admission guard, carrying a machine-readable reason (`input_rate_limit`, `kv_cache_pressure`) |
| `server.go:529` | the proxy path | **yes** | every request an attempt was actually made for, at the status `publishedCode` settled on |

Only the fourth describes a request the serving stack tried to answer. The first three describe requests the gateway ended on its own, and `W04` already ruled on the largest of them: a 429 refusal is **excluded from the quantile population and counted separately as `Rejected`**, because "거부는 처치(treatment)이지 잃어버린 관측이 아니다" — shedding load is what the guard is for, and its cost is reported on its own axis rather than as latency that never happened.

A definition that puts all four in one denominator would let the gateway improve its own score by refusing more traffic. That is not a hypothetical failure mode: it is the exact shape `2026-09-04-the-layer-not-the-signal.md` recorded, where M5-b's refusals turned out to be anti-correlated with harm.

## Three quantities that are not interchangeable

**`upstream_errors_total` is attempt-scoped.** Its help string says so: "Failed backend ATTEMPTS by tenant and model; a retried request contributes more than one." It cannot sit over a request-scoped denominator. `backend_fallbacks_total` is the request-scoped companion, and `metrics.go:96` records why they are kept apart — the ratio between them is what separates redundancy absorbing failures from redundancy merely counting them.

**`completedOutput` is already goodput, under another name.** `internal/bench/sharing_matrix.go:621` returns `OutputTokensByTenant[t] - OutputTokensFromFailedStreamsByTenant[t]` — output minus whatever arrived on a stream that then broke. `report.go:182` records what its absence cost: an arm that completed half the contender's responses and broke the rest after fifteen of sixteen tokens reported 97 percent of the control's output instead of 50. Any definition that introduces the word "goodput" for something else has to say how it differs from this, or it renames a measured quantity.

**`admittedWorkFraction` measures a different axis entirely.** `report.go:571` is `AdmittedInputTokens / OfferedInputTokens` — **input** tokens, at admission time. `2026-07-25-m5b-admission-guard-3arm-design.md:44` explicitly excludes completion throughput and output-token throughput from it, as outcomes unknown at admission. Folding it and `completedOutput` into one headline number would average an input-side ratio with an output-side one.

## What this page refuses to pick, and why the refusal is not a stall

`실행/W04-사전등록.md:18` already stated the honest position: "이 프로젝트에는 실제 사용자도 제품 책임자도 없다. 따라서 아래 수치는 **SLO가 아니라 벤치마크 임계값**이다. 위반 시 배포를 멈추는 규칙도, 오류 예산을 소비할 주체도 없다."

That sentence is true today, and code that consumed an error budget nothing can spend would make it false. An error budget with no consumer is decoration, and decoration in a metrics path is worse than an absence because it reads as a control.

`2026-09-09` names the only door out: a bar may be set "from a stated service objective that does not read this run's results". No such objective has ever been written down here. **Writing one is the prerequisite, and it is a separate act from measuring** — which is precisely why it can be done now, before the next card is bought, without contaminating anything.

## What a definition must settle before it is written into code

1. **Where the objective lives.** The `InferenceDeployment.spec.slo` field `docs/02` already advertises, or somewhere else that then has to explain why not there.
2. **Which of the four record sites are in the denominator**, against the `W04` treatment/observation rule — and whether `_unresolved` routing failures are the serving stack's fault or the caller's.
3. **Whether the predicate is latency, availability, or both**, given that `request_duration_seconds` carries buckets at 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60 and 120 seconds, so any latency bar not near a bucket edge is interpolated rather than observed.
4. **What consumes the budget**, or an explicit statement that nothing does and the number is reporting-only — stated in the code, not only here.
5. **What the word "goodput" will mean if it is used at all**, against `completedOutput`, which already computes it for serving, and against the training sense the one existing mention carries.

Each is a decision, not a measurement. None needs a GPU.

## Two things this page fixes on its way past

**`docs/06_OBSERVABILITY_BENCHMARK_FAILURE.md:54` understates the gateway.** Its Observability layers table gives the gateway row as "latency, 429, request count". The gateway exports thirteen series, including the admission, fallback and backend-telemetry families that any violation definition would have to read. The table is not wrong about what it lists; it is wrong by omission, in the document where a reader would go to find out what is observable. `make docs-check` cannot catch this — it checks that backticked names exist, and this claim names nothing.

**`docs/06`'s "To fill" list does not mention this gap.** It lists dashboard JSON, failure-injection scripts, and an honest local-versus-GPU table. So the missing violation definition was not a known deferral being tracked; it was simply absent, and the roadmap's own scan reported it as present in `queuelab`/`bench` on the strength of the two false friends above.

## What this page costs

Nothing. Every fact above was read out of the working tree.
