# Observability, Benchmark, and Failure

> **Status (2026-08-07).** Most of this document is design-of-record, not built. **Built (code,
> unit-tested), never deployed:** gateway Prometheus metrics. **Built (code, unit-tested), never run on a
> GPU:** the M5-b admission-guard benchmark harness (its vLLM metrics fixture is synthetic, so thresholds
> are unvalidated). **Designed only — no code:** the DCGM exporter layer (no DCGM, Xid, or ECC anywhere in
> the Go tree), the eBPF layer, Nsight profiling, the SQLite/Postgres operations ledger, the five failure
> reports (FR-001…FR-005, M7), and the `evidence/` report tree shown below (the real `evidence/` directory
> in this repo holds only empty placeholder subdirectories today). **Working today:** Kubernetes
> events/logs, and `NodeHealth` phase transitions (built, but with no GPU-specific fault detection). No GPU
> in this project is real.

This is the evidence center of the project — the proof that the platform actually operates workloads, not just defines types.

## Observability layers

| Layer                | Tool            | Sees                                                                                                          |
|----------------------|-----------------|---------------------------------------------------------------------------------------------------------------|
| GPU                  | DCGM exporter   | util, memory, XID, ECC, temp                                                                                  |
| Serving              | vLLM metrics    | TTFT, TPOT, queue depth, KV cache                                                                             |
| Gateway              | Prometheus      | latency, 429, request count                                                                                   |
| Kubernetes           | events / logs   | pod kill, pending, OOM                                                                                        |
| System (exploratory) | eBPF            | runqueue, syscall/ioctl, IO wait — secondary signal; GPU contention mostly does not surface here (doc 04, S6) |
| Profiling            | Nsight Systems  | CUDA timeline (optional)                                                                                      |
| Ledger               | Postgres/SQLite | workload_runs, benchmark_runs                                                                                 |

GPU/eBPF/Nsight layers require a real GPU node and are **not implemented at all today** — zero DCGM/Xid/ECC code exists in the Go tree, and no eBPF or Nsight integration exists (see doc 01 execution boundary). Unmeasured layers are labeled, not faked.

## Failure reports (5)

| ID     | Scenario           | Expected evidence                                            |
|--------|--------------------|--------------------------------------------------------------|
| FR-001 | quota exceeded     | HTTP 429, event, `workload_runs.failure_reason=quota_exceed` |
| FR-002 | serving pod killed | gateway error spike, recovery time                           |
| FR-003 | GPU OOM            | pod failure, NodeHealth / workload failure                   |
| FR-004 | degraded node      | scheduling reject / avoidance (taint)                        |
| FR-005 | noisy neighbor     | p99 increase + metric timeline (doc 04)                      |

## Local vs real-GPU feasibility

| Scenario                    | Local (kind, simulated GPU)           | Needs real GPU            |
|-----------------------------|---------------------------------------|---------------------------|
| quota exceeded (FR-001)     | yes — HTTP 429, exercised in gateway unit tests (the gateway itself has never been deployed to a running cluster) | no                        |
| serving pod killed (FR-002) | yes with a mock backend               | real vLLM recovery timing |
| GPU OOM (FR-003)            | hard                                  | yes                       |
| degraded node (FR-004)      | yes — NodeHealth simulated            | DCGM-based signal         |
| noisy neighbor (FR-005)     | harness only                          | yes (measured p99)        |

Numbers from real-GPU scenarios are committed only after a real run; locally we ship the harness and say so.

## M5 flagship evidence matrix (KV cache + admission guard)

| Scenario               | Local / kind                           | Real GPU required       | Evidence                                                                   |
|------------------------|----------------------------------------|-------------------------|----------------------------------------------------------------------------|
| Quota exceeded         | yes                                    | no                      | HTTP 429 log, ResourceQuota event                                          |
| Pod kill recovery      | partial                                | for real vLLM timing    | restart timeline, Gateway error metric                                     |
| GPU OOM                | no                                     | yes                     | pod event, DCGM memory, failure report                                     |
| Degraded node          | simulated                              | for DCGM-based signal   | NodeHealth phase transition                                                |
| Noisy neighbor p99     | harness only                           | yes                     | R1 baseline vs R2/R3 colocated p99 chart (+ CI)                            |
| KV cache pressure      | metric schema only                     | yes                     | vLLM KV cache usage + p99 time-align                                       |
| Admission guard off/on | envtest with stub metrics (guard spec) | for real latency impact | R3 vs R4 p99 comparison + standard-tenant cost (429 rate, throughput loss) |

## Report tree

This is the **target** layout — none of it exists yet. The `evidence/` directory in this repository today
contains only empty placeholder subdirectories (`command-logs/`, `incident-reports/`, `manifests/`,
`screenshots/`, `benchmark-reports/`), each holding a `.gitkeep` and nothing else.

```
evidence/
  benchmark-reports/
    noisy-neighbor/
      baseline.csv  colocated.csv  timeslicing.csv  mps.csv
      result-analysis.md  grafana-p99-spike.png  ebpf-timeline.png
  failures/
    fr-001-quota-exceed.md ... fr-005-noisy-neighbor.md
```

## To fill

- Prometheus/Grafana manifests + dashboard JSON
- failure-injection scripts (`scripts/demo-06-failure-injection.sh`)
- which FRs were actually run locally vs on real GPU (honest table)
