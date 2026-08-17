# FR-002 kind chaos: the serving pod dies and the gateway has to survive it

Runs the FR-002 scenario from [`docs/06_OBSERVABILITY_BENCHMARK_FAILURE.md`](../docs/06_OBSERVABILITY_BENCHMARK_FAILURE.md).
Scripted in [`chaos-fr002-serving-pod-killed.sh`](chaos-fr002-serving-pod-killed.sh). No GPU.

Unlike FR-004, this one needs the gateway actually deployed and actually scraped, which is why it comes
after [`observability-kind.md`](observability-kind.md).

## Two observers, and the second one is the point

The client's view comes from this script's own requests. The gateway's view comes from its Prometheus
counters. The run compares them, and **the comparison is the result** — an on-call engineer sees the
counters, not the client, so a gateway whose metrics stay clean through an outage its users felt is a worse
problem than the outage. The harness fails the run if the client saw errors the counters do not show.

## What cannot be separated here, unlike FR-004

FR-004 splits Kubernetes' detection from the operator's reaction, because they are different mechanisms
observable at different moments. Here they are not separable: the gateway proxies to a Service, so it learns
about the replacement pod exactly when kube-proxy does. Endpoint propagation is inside the reported error
window and this platform does not control it. The record says so in an `attribution` field rather than
letting the number be read as the gateway's own recovery time.

## Observed evidence

kind `platform`, gateway from `config/gateway-kind`, backend an `InferenceDeployment` running the
benchharness stub.

```json
{
  "experiment": "FR-002 serving pod killed",
  "steadyStateEstablished": true,
  "samplingIntervalMs": 304.2,
  "disrupted": true,
  "latenciesMs": { "killToFirstError": 51.7, "killToRecovery": 3079.8, "errorWindow": 3028.0 },
  "clientView":  { "sampled": 10, "failed": 9 },
  "gatewayView": { "requests5xx": 9, "upstreamErrors": 9, "backendFallbacks": 0,
                   "agreesWithClient": "true" }
}
```

**9 and 9.** Every failure the client experienced appears in the gateway's own counters. That agreement is
the load-bearing result; the 3-second recovery is secondary and mostly belongs to Kubernetes anyway.

`backendFallbacks: 0` is correct rather than disappointing — there is one `InferenceDeployment` for this
model, so there was no later backend to fall back to. The panel exists to distinguish failures a retry
absorbed from failures that reached the client, and with a single backend every failure is the second kind.

## The instrument claimed a resolution it did not have

The first run reported `samplingIntervalMs: 100` — the nominal value, written as a constant — while
collecting **3 samples across 5.3 seconds**.

A failing request blocks for its curl timeout, which was `-m 5`. So the sampling interval widens precisely
when things break, which is exactly when it needs to be tight: the loop samples at 100ms while healthy and
at seconds while broken. Every latency in that record carried seconds of unstated uncertainty.

Fixed two ways. The timeout is now `-m 1`, and the interval is **measured and recorded** rather than
asserted — the corrected run reports 304.2ms over 10 samples, and `killToRecovery` is stated as
`3079.8ms +/- one sample`.

This is the same defect FR-004 had, from the opposite direction. There the resolution was recorded and the
record exposed a half-finished fix; here it was hard-coded, so a record showing 3 samples in 5.3 seconds
still said `100` beside it. **Measure the instrument every run and put the number in the artifact** —
a constant cannot contradict the data it sits next to.

## Two setup faults worth keeping

**The API key Secret is keyed by API key, not by tenant.** `resolveTenant` looks up `sec.Data[key]` and
returns the value as the tenant, so `--from-literal=premium-key=premium-1` means the key is `premium-key`
and the tenant is `premium-1`. Getting it backwards produces a clean `401` that looks like a wrong password.

**`InferenceDeployment.spec.port` does not reach the workload.** It sets the containerPort, the Service port
and the probe target, but nothing passes it to the container, so the stub kept listening on its own default
`:8090` while everything around it was configured for `8000`. This fails loudly — readiness never passes —
which is the acceptable outcome; it is recorded because the field reads like it configures the workload and
does not.

## Running it

```bash
kubectl port-forward -n gpu-platform-control-plane-system svc/gateway 8080:8080 &
kubectl port-forward -n monitoring svc/kps-kube-prometheus-stack-prometheus 9090:9090 &
OUT=./ex/chaos-fr002.json ./hack/chaos-fr002-serving-pod-killed.sh
```

The steady state aborts unless five pre-fault requests all return 200 and the gateway's counter is visible
in Prometheus. Both matter: without the first, a later non-2xx is not attributable to the kill; without the
second, the run could not compare the two observers at all.
