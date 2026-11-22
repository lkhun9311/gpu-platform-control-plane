# A serving alert delivered: firing and resolved at a webhook receiver

[`hack/alert-firing-verification.md`](alert-firing-verification.md) showed `GatewayUpstreamErrorsReachingClients` reaching the firing state inside Prometheus.
It did not show a notification leaving Prometheus, and a rule that fires into an Alertmanager with no route pages nobody.
This run follows one alert from the fault to the receiver and back, on kind, with [`gateway-alert-delivery.sh`](gateway-alert-delivery.sh).
Evidence: [`gateway-alert-delivery-20261122T160709Z/`](gateway-alert-delivery-20261122T160709Z/), run at commit `e08e6e3b` with no uncommitted change under `config`, `cmd`, `internal`, `api` or the script (`provenance.txt`).

## The rule and why a Pod kill does not fire it

From `config/prometheus/gateway_rules.yaml`, unchanged:

```
sum by (model) (rate(gpuaas_gateway_requests_total{code=~"5.."}[5m])) > 0.1
for: 5m
```

The rate needs about 30 failed requests inside a 5-minute window, and the condition has to hold for 5 minutes of evaluations.
The [FR-002 Pod kill](chaos-fr002-serving-pod-killed.md) recovered in about 1.3 s with one to two failed requests, so it cannot fire this rule.
The fault here is a model with no engine Pod at all: its `InferenceDeployment` patched to `replicas: 0`, which the operator holds, and patched back once the receiver had the firing notification.

## Setup

- kind, one node; kube-prometheus-stack 88.3.0 with Alertmanager; Prometheus `evaluation_interval: 30s`, the gateway scraped every 15 s by `config/prometheus/gateway_podmonitor.yaml`.
- Alertmanager's only receiver is a webhook into a Pod that prints each body with its arrival time; `group_wait: 10s`, `group_interval: 30s`, `send_resolved: true` (`kps-values.yaml`).
  The chart's defaults are 30 s and 5 min, and a real receiver adds those on top of the times below.
- The operator and gateway built from the commit above; one `InferenceDeployment` running the benchharness stub; a load Pod sending one request at a time with a 0.5 s pause, which measured 0.87 successful requests per second before the fault.

## Timeline

All times UTC, 2026-11-22. "Script" is when this script observed or did something (`events.tsv`); "Prometheus" and "Alertmanager" times are the ones those components stamped.

| time | source | what |
|---|---|---|
| 16:12:25.161 | script | baseline: alert inactive, gateway 200 rate 0.87/s |
| **16:12:25.196** | script | **fault start**: `InferenceDeployment demo-llm` patched to `replicas: 0` |
| 16:12:51.382 | script | 5xx first seen in a Prometheus query (0.36/s over 1 m) |
| 16:13:22.417 | Prometheus | rule evaluation that first matched, `activeAt` (pending), 57 s after the fault |
| 16:18:22.416 | Prometheus | first firing evaluation, the alert's `startsAt`, 5 m 0 s after `activeAt` |
| **16:18:32.436** | receiver | **firing notification received**, 10.0 s after `startsAt` (the `group_wait`) |
| **16:18:34.753** | script | **fault end**: patched back to `replicas: 1` |
| 16:18:52.108 | script | gateway 200 rate back above 0.5/s in a Prometheus query |
| 16:22:52.416 | Prometheus | last firing evaluation |
| 16:23:22.416 | Prometheus | first evaluation without a match, the alert's `endsAt` |
| **16:23:32.461** | receiver | **resolved notification received**, 10.0 s after `endsAt` |

Fault start to firing received: 367.2 s. Fault end to resolved received: 297.7 s.
Both are dominated by the rule rather than by delivery: 57 s to the first match, the 5-minute `for:`, and on the way out the 5-minute rate window draining below 0.1/s, after which delivery took 10 s each way.
Exactly one firing and one resolved notification reached the receiver (`sink.jsonl`).
At the end the gateway had counted 643 requests with 200 and 375 with 502 for the model (`requests-by-code-at-end.json`); no other 5xx code appeared.

## What this does and does not show

It shows the path `gateway counter -> Prometheus rule -> Alertmanager route -> webhook` working in both directions, with the committed rule and PodMonitor.
It does not show a person being paged: email, Slack or a pager would be one more receiver, and none is configured.
It is not a GPU engine: a stub with no weights to load, so the recovery side says nothing about how long a real engine takes to come back.
The script's "backend rollout complete" event, 0.7 s after the fault end, is `kubectl rollout status` returning, and is not used above; the 200 rate in Prometheus is the recovery reading.

## Running it

```bash
KUSTOMIZE=bin/kustomize hack/gateway-alert-delivery.sh   # this run took 16 minutes; KEEP=1 leaves the cluster up
```
