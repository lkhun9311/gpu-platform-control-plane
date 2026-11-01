# Observability, Benchmark, and Failure

> **Status (2026-08-17).** Parts of this document are design-of-record and parts are now running; the two
> are marked separately below because an earlier version of this header claimed less than was true and a
> reader has no way to tell an unbuilt plan from an unmeasured one.
>
> **Deployed and scraped on kind:** the operator's five metrics and the gateway's twelve, through the
> ServiceMonitor and PodMonitor in `config/prometheus/`, into kube-prometheus-stack. A Grafana dashboard
> (`config/prometheus/operator_dashboard.json`) renders them, and `hack/check-dashboard.sh` asserts every
> panel's PromQL parses AND that every metric it names exists in the Go source — an unexported metric renders
> an empty graph, and an empty graph reads as "no traffic". The four alert rules pass `promtool check rules`
> via `hack/check-prometheus-rules.sh`.
>
> **Run against a real cluster:** FR-002 and FR-004, with their evidence and their instrument defects written
> up in `hack/chaos-fr002-serving-pod-killed.md`, `hack/chaos-fr002b-backend-fallback.md` and
> `hack/chaos-fr004-degraded-node.md`. The gateway IS deployed (`config/gateway-kind`), serving a stub
> backend through an `InferenceDeployment`; the admission webhook is deployed and verified end to end
> (`hack/verify-webhook-live.sh`).
>
> **Built, and run on a paid GPU:** the M5-b admission-guard benchmark harness. Four repetitions on
> 2026-09-03 and an engine-level scheduler microtest on 2026-09-04. The guard missed its pre-registered
> 1.25x premium-tail target at 83.7x, and the harness declared the run invalid rather than reporting a
> protection claim. ⚠️ This used to conclude "the run showed the gateway cannot observe the pressure they
> gate on", and that is the wrong lesson. The gateway observed pressure and acted on it: all **274** refusals
> came from the waiting-queue condition. What never fired was the KV-occupancy condition, and re-analysis
> showed it was **unreachable by construction** — the engine reported a cache of 386,912 tokens against a
> 7,695-token noisy prompt, so crossing 0.85 needed about 43 concurrent long requests and the trace never
> held more than 13 (25.9%). The failure is a threshold nothing in this workload could reach, not a signal
> the gateway cannot see (`docs/superpowers/specs/2026-09-04-the-layer-not-the-signal.md`).
>
> **Built, and run on a card once:** Xid and double-bit ECC, read from the DCGM exporter by an opt-in path into
> `NodeHealth` (`--gpu-fault-source=dcgm`, `internal/gpufault/`, 2026-10-27), rehearsed on kind against a fake
> exporter, and taken through a real card by run 2 of its registered session on 2026-10-27, with values injected
> into DCGM's cache rather than induced hardware faults: both fault arms reacted in 5 of 5 repetitions and the
> stale-latched check failed (`docs/superpowers/specs/2026-10-27-gpu-fault-reaction-design.md`). Until 2026-10-27 this
> line said nothing Xid or ECC was in the Go tree, which was true then. The DCGM exporter layer is NOT in this
> category and the claim that it was is corrected here: `config/dcgm-exporter/` deploys it and
> `internal/queuelab/dcgm.go` reads `DCGM_FI_DEV_GPU_UTIL` from it. It has now been pointed at real cards:
> session `qlgpu-20260906-032038` ran eight runs on four A10Gs and every one carries
> `deviceEvidence: device-work-observed`. Also designed only:
> eBPF layer, Nsight profiling, the SQLite/Postgres operations ledger, FR-001, FR-003, FR-005, and the
> `evidence/` report tree shown below.
>
> **Which GPUs were real, and which were not.** Every kind cluster here advertises simulated
> `nvidia.com/gpu` capacity through a fake device plugin, and the chaos runs measure control-plane reaction
> rather than device behaviour. The paid EC2 sessions used real cards, and one of them attributed device
> utilisation to Pods: `queuelabrun -compare` prints its comparison for `qlgpu-20260906-032038` with no
> `device: NOT OBSERVED` line. That is one card model on one driver on one AMI, and it does not
> retroactively make the kind runs device-observed -- those measured what they measured.

This is the evidence center of the project — the proof that the platform actually operates workloads, not just defines types.

## Observability layers

| Layer                | Tool            | Sees                                                                                                          |
|----------------------|-----------------|---------------------------------------------------------------------------------------------------------------|
| GPU                  | DCGM exporter   | util, memory, XID, ECC, temp — util is a periodic sample, see the blind spot below                            |
| Serving              | vLLM metrics    | TTFT, TPOT, queue depth, KV cache                                                                             |
| Gateway              | Prometheus      | latency, status counts, admission decisions and holds, fallbacks, upstream errors, backend KV telemetry — 19 series |
| Kubernetes           | events / logs   | pod kill, pending, OOM                                                                                        |
| System (exploratory) | eBPF            | runqueue, syscall/ioctl, IO wait — secondary signal; GPU contention mostly does not surface here (doc 04, S6) |
| Profiling            | Nsight Systems  | CUDA timeline (optional)                                                                                      |
| Ledger               | Postgres/SQLite | workload_runs, benchmark_runs                                                                                 |

**What DCGM_FI_DEV_GPU_UTIL cannot see.** It is NVML's percentage of the last sample period during which a kernel was executing, and the exporter here collects once a second. A tenant whose work arrives in bursts with a period near the collection interval does not drift through the sampler's phase, so a sample that lands in an idle stretch lands there every time. Measured, not reasoned: in session `qlgpu-20260906-103327` a Pod executing 22,093 real kernels at a quarter duty on a one-second period was reported as working in **zero of 52 collections**, while the same exporter in the same run read 98 for a continuously computing neighbour and named every Pod on every card. Attribution was not failing; attribution succeeded and reported idle. Changing the workload's period to 2.6 s -- nothing else -- turned that into 15 of 51 collections above zero at a mean of 22.8 against a declared 25 (`qlgpu-20260906-125451`). Counts here are collections, not scrapes: the exporter collects once a second and serves a cached snapshot in between, while the run scrapes twice a second, so each collection is read about twice and the raw sample counts are double these.

**The gate did not save the first run; its phase did.** At a one-second period the sampler visits one phase of the workload's cycle and stays there. That phase fell in an idle stretch, so the run was refused. Had it fallen inside the burst, every collection would have read 98 and a quarter-duty card would have passed as fully busy. Do not read the refusal as a property of the instrument. A dashboard has no gate at all, and a utilisation panel is a periodic sampler with the same failure mode -- but the gate's protection here is narrower than it looks, and `docs/superpowers/specs/2026-09-06-does-reservation-track-use.md` carries the withdrawal in full. Counting collections rather than scrapes also closed a hole in the gate itself: it required two busy samples at distinct timestamps, and one cached collection read twice supplied both. It now requires them `maxObserverGap` apart, which no single snapshot can span.

The eBPF and Nsight layers require a real GPU node and are **not implemented at all today**. Xid and ECC are implemented as an opt-in health input since 2026-10-27, and on 2026-10-27 run 2 of their registered session took them through a real card with values injected into DCGM's cache, not induced hardware failures: both fault arms reacted in 5 of 5 repetitions and the stale-latched check failed (`docs/superpowers/specs/2026-10-27-gpu-fault-reaction-design.md`). The DCGM layer is different and this sentence has been wrong twice about it. It once said no code existed; the reader, the Pod-attribution resolver, the exporter deployment and the pre-spend gate all do. It then said no card had been rented; one has. In session `qlgpu-20260906-032038` the exporter named Pods on four A10Gs, the two cards the protocol used were busy in 541 and 559 of 663 samples, and the two held by the surplus occupier in 0 of 663 -- so a GPU-second in that session is an observed device-second. Everything earlier remains a second of reservation, and is labelled as one. Unmeasured layers are labeled, not faked.

## GPU alerts and what to do when they fire

`config/prometheus/gpu_rules.yaml` holds six alerts and `config/prometheus/gpu_dashboard.json` the panels they are read beside.
Three alerts describe the fleet: a card reporting a fault, a ClusterQueue out of GPU quota, and a queue that has stopped admitting.
The other three describe the instruments, because each of the first three is silent when its input is missing, and silence reads as health.

What they need deployed:

| input | deployed by | without it |
|---|---|---|
| `DCGM_FI_DEV_XID_ERRORS`, `DCGM_FI_DEV_ECC_DBE_VOL_TOTAL`, `DCGM_FI_DEV_FB_USED` | `config/dcgm-exporter-ops` (exporter and its PodMonitor) | `config/dcgm-exporter` collects utilisation only; `GPUFaultFieldsNotCollected` fires |
| `kueue_*` | `config/prometheus/kueue_monitor.yaml` | nothing in this repository scraped Kueue before it |
| `kueue_cluster_queue_nominal_quota` and the other quota series | Kueue's `metrics.enableClusterQueueResources: true`, set by `config/kueue-controller/controller_manager_config.yaml` | the release file applied alone, as the kind harnesses do, leaves it off; `KueueGPUQuotaMetricsNotReported` fires |
| `kube_node_status_capacity` | kube-state-metrics, from kube-prometheus-stack; not deployed by this repository | `GPUExporterNotReporting` has no node list and is silent, and nothing says so |

There is no metric of which nodes are quarantined now.
The operator exports counters of transitions (`gpuplatform_gpufault_transitions_total`, `gpuplatform_nodehealth_taint_total`), which a restart zeroes while the taints stay, so the dashboard shows them as transitions and the current state is read from the NodeHealth objects.

`hack/check-gpu-monitoring.sh` runs promtool over the rules, their unit tests in `config/prometheus/gpu_rules_test.yaml` and the dashboard's queries.
`test/monitoring/monitoring_test.go` fails if any series the rules or the dashboard read is one nothing deployed emits, if the Xid alert and the operator disagree on which Xids are faults, or if a runbook link below stops resolving.

**Rehearsed on kind `platform`, 2026-10-31, against a fake exporter, not a card.**
A single Pod of `gpu-simulator:gpufault` with `FAKE_DCGM_ADDR=:9400`, labelled as the exporter so the PodMonitor from `config/dcgm-exporter-ops` selected it, was scraped every 15 s; the rule group was evaluated every 30 s, the kube-prometheus-stack default there.
Values were written into the fake's cache through its `/inject` endpoint, the call `hack/lib/gpu-fault.sh` makes in fake mode.

| step | time (UTC) | result |
|---|---|---|
| Xid 13 injected (application Xid, the control) | 10:52:26.7 | no alert in the following 100 s, while the series read 13 |
| Xid 79 injected | 10:54:07.440 (call returned) | |
| `GPUFaultSignalPresent` active, and firing at once (no `for`) | 10:54:33.333 (`activeAt`) | 25.9 s after the injection; the bound is one scrape plus one evaluation, 45 s |

The fake reports `DCGM_FI_DEV_XID_ERRORS` and the ECC fields only, so `DCGM_FI_DEV_FB_USED` and `DCGM_FI_DEV_GPU_UTIL` were not exercised, and nor was `GPUFaultFieldsNotCollected`'s firing side.
On the same cluster Kueue v0.18.3 was scraped through `config/prometheus/kueue_monitor.yaml` (`up` = 1); `kueue_pending_workloads` and `kueue_cluster_queue_status` were present and none of the quota series were, as its configuration predicts.
`KueueGPUQuotaMetricsNotReported` went pending at 10:52:42.8 for all three active ClusterQueues and was firing when read at 11:07:45, and `GPUFaultSignalPresent` had resolved after Xid 0 was injected at 10:54:47.
On `platform`, `KueueClusterQueueGPUQuotaExhausted` and `KueueWorkloadsPendingTooLong` were not exercised: the first needs the quota series that Kueue does not publish, and no queue there had pending work.
The rehearsal below exercises both.

**Delivered to a receiver on a throwaway kind cluster `mon`, 2026-10-31 23:55 to 2026-11-01 00:28 UTC, commit `7b7f1b6b`, clean tree.**
`hack/gpu-alert-delivery.sh` created the cluster, ran it and deleted it; the evidence is `hack/gpu-alert-delivery-20261031T235222Z/`.
Prometheus and Alertmanager came from kube-prometheus-stack 88.3.0, the chart `platform` runs, with kube-state-metrics on.
Alertmanager's only receiver was a webhook into a Pod that printed each request body with its arrival time (`sink.jsonl`), with `group_by: ['...']`, `group_wait: 10s`, `group_interval: 30s` and `send_resolved: true`.
Kueue came from `config/kueue-controller`, so its configuration was the one EKS gets; Prometheus held `kueue_cluster_queue_nominal_quota` for the test queue before anything was induced, and `KueueGPUQuotaMetricsNotReported` never went pending in the run.
The GPU was gpu-simulator's fake `nvidia.com/gpu` on the worker, and the exporter a second gpu-simulator serving the fake DCGM fields, scraped through the PodMonitor from `config/dcgm-exporter-ops`.
Rules were evaluated every 30 s and the exporter scraped every 15 s.
"Fired" is the first `ALERTS{alertstate="firing"}` sample, stamped with the evaluation that wrote it; "resolved" is the `endsAt` Prometheus sent; "received" is the sink's clock, which is the same host clock.

| alert | induced (UTC) | fired | received firing | resolution induced | resolved | received resolved |
|---|---|---|---|---|---|---|
| `GPUFaultSignalPresent`, Xid 79 | 23:57:23.90 Xid 79 injected | 23:57:30.81 | 23:57:40.82 (+10.0 s) | 23:57:44.25 Xid 0 | 23:58:00.81 | 23:58:10.82 (+10.0 s) |
| `GPUFaultSignalPresent`, double-bit ECC | 23:58:14.64 ECC 1 injected | 23:58:30.81 | 23:58:40.81 (+10.0 s) | 23:58:45.29 ECC 0 | 23:59:00.81 | 23:59:10.81 (+10.0 s) |
| `GPUExporterNotReporting` | 23:59:15.36 exporter scaled to 0, Pod gone 23:59:16.45 | 00:10:00.81 (pending from 00:00:00.81) | 00:10:10.81 (+10.0 s) | 00:10:13.19 scaled to 1 | 00:10:30.81 | 00:10:40.81 (+10.0 s) |
| `KueueClusterQueueGPUQuotaExhausted` | 23:55:38.67 second Job created against a queue of one GPU (pending from 23:56:11.85) | 00:11:11.85 | 00:11:21.86 (+10.0 s) | 00:27:25.42 admitted Job deleted | 00:27:41.85 | 00:27:51.89 (+10.0 s) |
| `KueueWorkloadsPendingTooLong` | 23:55:38.67, the same Job | 00:27:11.85 (pending from 00:26:11.85) | 00:27:21.85 (+10.0 s) | 00:27:25.42, the same deletion | 00:27:41.85 | 00:27:51.86 (+10.0 s) |

Every firing and every resolution reached the receiver exactly once: ten bodies, five firing and five resolved.
Each arrived 10.0 s after Prometheus's evaluation, which is the configured `group_wait`; the hop itself is not separable from it in this data, and an operator's Alertmanager with the chart's defaults (30 s, 5 min) would add those instead.
Xid 13, injected at 23:55:53.79, raised nothing in the 90 s that followed.
`GPUExporterNotReporting` went pending 44 s after the exporter Pod was gone, the time for the PodMonitor's target to drop and its series to go stale, and fired ten minutes later, as its `for` says.
`KueueWorkloadsPendingTooLong` fired 31 min 33 s after the queue's only admission was observed (23:55:38.63).
That admission created Kueue's counter series, which the rule counts as an admission for a full 30-minute window, so the rule went pending only at 00:26:11.85 and then held for its one-minute `for`.

After the run, on the same cluster, the line in `controller_manager_config.yaml` was commented out again by hand and Kueue restarted (`mutation-kueue-config.txt`).
`kueue_cluster_queue_nominal_quota` for the queue went from one series to none, and `KueueGPUQuotaMetricsNotReported` went pending within a minute; so the line is what produces the quota alert's input.

What this does not show:

- A human receiver. The webhook is the last hop shown; no email, Slack or pager route is configured anywhere in this repository.
- EKS. This was kind, with simulated GPUs, a fake exporter and Prometheus inside the cluster; EKS has no Prometheus deployed by this repository at all.
- A real DCGM exporter disappearing. The fake's Hostname is `$NODE_NAME`, as the real 3.3.9 binary's is (read off its `GetHostname`), but no real exporter was removed from a real card.
- Alertmanager's own failure, a receiver answering an error, or a notification lost and retried; every request here was answered 200.

### GPUFaultSignalPresent

A card's DCGM fields carry a fault under the operator's own policy (`internal/gpufault/classify.go`): a non-zero Xid other than the application Xids 13, 31, 43, 45 and 68, or a double-bit ECC count above zero.

1. Read the NodeHealth for the node: `kubectl get nodehealths -o wide`, then its `GPUHealthy` and `GPUSignal` conditions.
   With `--gpu-fault-source=dcgm` the operator has already tainted the node `platform.lkhun9311.github.io/gpu-fault`, and with `--gpu-fault-evict-workloads` it has deactivated the Kueue Workloads of GPU Pods there.
   Without the flag nothing has reacted, and the node still takes GPU work until someone taints or cordons it.
2. Decide whether the card is to be repaired or the fault accepted.
   A GPU reset or driver reload that leaves every fault field at zero releases the latch on the next fresh scrape.
   To accept the fault instead, write the fingerprint from the NodeHealth's `gpufault.platform.lkhun9311.github.io/fingerprint` annotation into `gpufault.platform.lkhun9311.github.io/acknowledged`; a different fault later will not match it.
3. Do not read a resolved alert as a recovered node.
   The Xid field holds the last Xid only, so an application Xid after a fatal one resolves this alert while the operator, which latches, keeps the taint.

### GPUFaultFieldsNotCollected

A node exports `DCGM_FI_DEV_GPU_UTIL` but not the Xid and double-bit ECC fields, so `GPUFaultSignalPresent` cannot fire there.
Deploy the exporter from `config/dcgm-exporter-ops` (or `config/dcgm-exporter-fault`), which collect them.
The operator's fault path on the same node reports `FieldMissing` for the same reason.

### GPUExporterNotReporting

A node advertises `nvidia.com/gpu` (kube-state-metrics' `kube_node_status_capacity`) and no DCGM series carries its name in `Hostname`, so neither alert above can fire for its cards.
It is the case `GPUFaultFieldsNotCollected` cannot see, because that alert needs the utilisation series the vanished exporter took with it.

1. `kubectl -n gpu-platform-control-plane-system get pods -l app.kubernetes.io/component=dcgm-exporter -o wide` shows whether an exporter Pod runs on the node.
   None: the DaemonSet's nodeSelector (`platform.lkhun9311.github.io/gpu=true`) or its tolerations do not match the node.
2. A Pod that runs but is not reporting: its scrape target in Prometheus (`up` for the `dcgm-exporter` PodMonitor) and the exporter's log.
3. Until it reports again, a fault on that node reaches the operator's `--gpu-fault-source=dcgm` path as `FieldMissing` and reaches no alert.

### KueueClusterQueueGPUQuotaExhausted

The queue has reserved its whole nominal `nvidia.com/gpu` quota for fifteen minutes while workloads requesting GPUs are pending.

1. `kubectl get clusterqueue <name> -o yaml` shows the reservation per flavour and whether the cohort lends.
2. Find what holds the quota: `kubectl get workloads -A` filtered to the queue's LocalQueues, with their admission times.
   A long-running job is the queue in use, and the decision below is about priority, not repair.
3. The levers are the tenant's: raise the `GPUQuotaPolicy` that syncs this queue, lend from the cohort, or stop work.
   Fifteen minutes is a convention, not a measured bound.

### KueueGPUQuotaMetricsNotReported

An active ClusterQueue has no `kueue_cluster_queue_nominal_quota` series, which means Kueue runs without `metrics.enableClusterQueueResources`.
`KueueClusterQueueGPUQuotaExhausted` is blind on every queue until it is set in Kueue's `controller_manager_config.yaml`.

### KueueWorkloadsPendingTooLong

A ClusterQueue has had pending workloads for the whole of the last 30 minutes and admitted none in that time.
Kueue publishes a pending count and no per-workload age, so this is a statement about the queue: its oldest pending workload has waited at least 30 minutes unless it was deleted and replaced inside the window.

1. `kubectl get workloads -A` and the pending ones' `QuotaReserved` condition message say why Kueue is not admitting them.
2. If the queue is also out of quota, `KueueClusterQueueGPUQuotaExhausted` is the cause and its runbook applies.
3. If the workloads are `inadmissible`, Kueue has stopped retrying them; the condition message names the flavour or resource that cannot fit, often a request larger than the queue's whole quota.

## Failure reports (5)

| ID     | Scenario           | Expected evidence                                            |
|--------|--------------------|--------------------------------------------------------------|
| FR-001 | quota exceeded     | HTTP 429 with `error.code=rate_limited`, `gpuaas_gateway_rate_limited_total{tenant}` delta ⚠️ |

⚠️ **FR-001 was corrected on 2026-09-27, and two parts of it are still unbuilt.** The row used to promise an
event and `workload_runs.failure_reason=quota_exceed`. No such code exists: the gateway refuses with
`rate_limited` and counts `gpuaas_gateway_rate_limited_total` per tenant, and `quota_exceed` appears nowhere in
this repository. Nor could the operations ledger supply it — `WorkloadRun`'s scenario enum admits only
`ServingPodKilled` and `DegradedNode`, so a quota refusal is not a run this API can perform, and adding the
enum value would create one that can never reach a verdict.

Still missing, named here rather than implied: the refusal is **not recorded durably anywhere** — it exists in
the response the client received and in a counter that resets with the process — and no Kubernetes event is
emitted for it. Closing that is a gateway change, not a storage one.
| FR-002 | serving pod killed | gateway error spike, recovery time                           |
| FR-003 | GPU OOM            | pod failure, NodeHealth / workload failure                   |
| FR-004 | degraded node      | scheduling reject / avoidance (taint)                        |
| FR-005 | noisy neighbor     | p99 increase + metric timeline (doc 04)                      |

## Local vs real-GPU feasibility

| Scenario                    | Local (kind, simulated GPU)           | Needs real GPU            |
|-----------------------------|---------------------------------------|---------------------------|
| quota exceeded (FR-001)     | not yet run; HTTP 429 is exercised in gateway unit tests, and the gateway is now deployed on kind so the scenario is reachable | no                        |
| serving pod killed (FR-002) | **RUN** — see `hack/chaos-fr002-serving-pod-killed.md`; the fallback path has its own run in `hack/chaos-fr002b-backend-fallback.md` | real vLLM recovery timing |
| GPU OOM (FR-003)            | hard                                  | yes                       |
| degraded node (FR-004)      | **RUN** — see `hack/chaos-fr004-degraded-node.md`; kubelet is stopped for real, and the operator's own reaction is reported as a bound because it is faster than the harness can resolve | DCGM-based signal         |
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
