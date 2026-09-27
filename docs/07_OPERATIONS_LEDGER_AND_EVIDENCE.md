# Operations Ledger and Evidence

> **Status (2026-09-27): storage and projector exist for 2 of the 6 tables; nothing can be run yet.**
> `internal/ledger` holds versioned migrations and an idempotent projector for `workload_runs` and
> `operation_events` only, with the design of record at
> `docs/superpowers/specs/2026-09-27-operations-ledger-slice-one-design.md`. `model_versions`,
> `deployment_runs`, `benchmark_runs` and `node_health_history` do not exist — not as tables, not as stubs.
>
> **What is missing matters as much as what is there.** `ProjectWorkloadRuns` is called by tests and by nothing
> else: there is no command that reads an apiserver or a database, so no ledger has ever been written outside a
> test. Until that lands, this page describes storage that works and a workflow that does not run. (A separate,
> unrelated event ledger lives inside the queuelab measurement lab — `internal/queuelab/ledger.go` — but it is
> not this ledger and implements none of the tables below.)
>
> This is part of M7 (failure/evidence; renumbered from M6 when training admission was promoted to M6,
> 2026-07-04). Every GPU in the kind clusters is simulated by a fake device plugin. The GPUs in the paid EC2 sessions — more than thirty of them since 2026-09-02 — were real.

A small operations ledger records what the platform did, as durable evidence. It is deliberately **not** a full MLOps store — GPU-infra operations tracking only.

> The ledger is **not** the source of truth for scheduling or quota. The source of truth is the Kubernetes resources, their status, and the controllers. The ledger is an evidence projection of controller decisions, benchmark runs, and workload events.

## Ledger tables (6)

| Table                 | Keep     | Why                                                          |
|-----------------------|----------|--------------------------------------------------------------|
| `model_versions`      | yes      | linked to InferenceDeployment                                |
| `deployment_runs`     | yes      | model deployment lifecycle                                   |
| `benchmark_runs`      | yes      | node intake, noisy-neighbor, load tests                      |
| `node_health_history` | yes      | NodeHealth phase transitions                                 |
| `workload_runs`       | yes      | inference / failure / training records (backs `WorkloadRun`) |
| `operation_events`    | yes      | controller/action/audit common events                        |
| `index_versions`      | excluded | scene-retrieval only — separate project                      |
| `promotion_records`   | stretch  | only if MLOps-lite is added                                  |

## Evidence matrix

The table below is a target evidence checklist per feature, not an inventory of evidence already collected
— several of its columns (report, screenshot) point at artifact types that do not exist yet for most rows.
See the README's per-area State column for what is actually built.

| Feature             | Code       | Test       | Metric            | Report           | Screenshot |
|---------------------|------------|------------|-------------------|------------------|------------|
| InferenceDeployment | controller | envtest    | Ready condition   | deploy report    | kubectl    |
| GPUQuotaPolicy      | controller | quota test | reject count      | fr-001           | Grafana    |
| NodeHealth          | controller | intake     | DCGM / node Ready | node report      | dashboard  |
| Gateway             | gateway    | load test  | p95/p99           | gateway report   | Grafana    |
| Noisy neighbor      | benchmark  | A/B        | p99 delta         | isolation report | p99 chart  |
| Failure             | scripts    | injection  | recovery time     | FR docs          | events     |

## To fill

- ledger DDL (SQLite local / Postgres real), projector from CR/status/events
- evidence collection scripts, screenshot conventions
