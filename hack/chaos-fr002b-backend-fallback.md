# FR-002b: the head backend is removed and a second one absorbs the traffic

Scripted in [`chaos-fr002b-backend-fallback.sh`](chaos-fr002b-backend-fallback.sh). No GPU.

## Why this is separate from FR-002

[`chaos-fr002-serving-pod-killed.md`](chaos-fr002-serving-pod-killed.md) kills the pod behind the only
backend, so every failure reaches the client and `backend_fallbacks_total` stays at 0. That reading is
correct for that run, and it leaves the retry path **completely unexercised** — a counter that exists and
reads zero proves nothing about whether it can move.

## The first attempt at this measured nothing

Scaling the backend Deployment to 2 replicas looked like the obvious way to give the gateway an alternative.
It is not. A **backend here is an `InferenceDeployment`, not a pod**: `backendsFor` lists every
InferenceDeployment serving the model, sorted oldest-first, and `tryBackends` walks that list. Extra pods
are Service load balancing, one layer below the thing under test — the request would never reach the retry
path at all.

Two InferenceDeployments serving the same model name are what create the pair.

## The head is removed by scaling to zero, not by deleting a pod

A deleted pod races its replacement, so a fallback might or might not be needed on any given request. A head
with no endpoints fails deterministically, every request, until it is scaled back — which is what makes the
counter delta readable.

## Both halves of the verdict are required

| checked | why alone it is not enough |
|---|---|
| requests still succeed | a gateway that never actually lost the head would also pass |
| the fallback counter moved | a gateway falling back on **every** request, including healthy ones, would also pass |

## Observed evidence

```json
{
  "experiment": "FR-002b head backend removed, spare must absorb",
  "head": "serving/stub-llm", "spare": "serving/stub-llm-spare",
  "injection": "scale the head InferenceDeployment to zero replicas",
  "steadyStateEstablished": true,
  "headEndpointsGoneMs": 67.3,
  "requests": { "sent": 20, "succeeded": 20, "failed": 0 },
  "backendFallbacks": { "before": 0, "after": 20, "delta": 20 },
  "verdict": { "stillServed": true, "counterMoved": true }
}
```

Twenty requests, twenty successes, and a counter delta of exactly twenty. The retry path engages, and the
metric an operator would rely on records it.

The steady state also asserts what makes the two objects alternatives at all: both have endpoints, both
serve the same model name, and the head really is the older of the two — oldest-first is the routing order,
so an experiment that removed the *younger* one would be removing the spare and measuring nothing.

### Re-run on 2026-09-21, with three more counters read

The run above was reproduced after the corrections described below, on a cluster whose `stub-llm` had been
crash-looping for five days and whose `stub-llm-spare` did not exist. Same verdict, and the widened
observation says something the original could not:

```json
"backendFallbacks": { "before": 3, "after": 23, "delta": 20 },
"context": {
  "rateLimited":        { "before": null, "after": null, "delta": null },
  "upstreamErrors":     { "before": 4,    "after": 24,   "delta": 20 },
  "admissionDecisions": { "before": 12,   "after": 37,   "delta": 25 }
}
```

**`upstreamErrors` moved by exactly 20 alongside the 20 fallbacks.** Every request that reached the dead
head failed there and was then served by the spare — the two counters describing the same twenty events
from opposite ends. A fallback delta of 20 with an upstream delta of 0 would have meant the head was never
actually tried, and nothing in the original run could have distinguished that.

**`rateLimited` is `null`, not `0`.** Prometheus holds no series for it on this cluster, and recording that
as zero would have been a claim that the limiter stayed still during the window — an observation nobody
made. The distinction is the correction this script needed, and this is the run that exercises it.

`admissionDecisions` moved by 25 against 20 requests because the five pre-fault steady-state requests are
inside the same window; it is read for context and gated on nothing.

## What this evidence depended on

At the time this run was taken, `backend_fallbacks_total` could be incremented for a request that was never
retried. The failure callback set the fallback flag before the guards inside `tryBackends` decided whether a
retry was possible, so a cancelled request recorded a fallback that did not happen — and, because the status
recorder still held its seeded 200, was also published as a success.

**This run is unaffected**, and the reason is checkable rather than hopeful: all twenty requests returned
200 from the spare, none were cancelled, and the delta was exactly twenty against twenty successes. The
defective path needs a cancellation, and there was none.

It is recorded here anyway, because "the counter moved by 20" is only evidence if the counter could not have
moved for another reason. `tryBackends` now reports whether it actually advanced to another candidate rather
than leaving the caller to infer it, so a later reader does not have to reconstruct that argument.

## Together with FR-002

| run | backends | outcome | `backend_fallbacks_total` |
|---|---|---|---|
| FR-002 | one | 9 of 10 requests failed | 0 — correct, nothing to fall back to |
| FR-002b | two | 20 of 20 succeeded | +20 |

The pair is what makes either number mean something: the first shows failures reaching the client when there
is no alternative, the second shows them absorbed when there is, and the counter separates the two cases
exactly as its help text claims.

## Running it

This experiment had evidence and no reproduction path: the run was recorded, the `stub-llm-spare` it needs
was never committed anywhere, and the cluster's `stub-llm` had been sitting in `CrashLoopBackOff` for days
because its image cannot accept the arguments the operator passes. The steps below are what actually stood
it back up on 2026-09-21, in the order they were run.

**The stub image.** `benchharness stub-serve` is the only backend in this repository that satisfies the
operator's contract — the `InferenceDeployment` controller builds every serving container with exactly
`--model <name> --model-path <storageUri>` and probes `GET /health` on the named port. `hashicorp/http-echo`,
which the old `stub-llm` used, accepts neither and exits 2 on startup.

```bash
W=$(mktemp -d)
CGO_ENABLED=0 GOOS=linux go build -o "$W/benchharness" ./cmd/benchharness
printf 'FROM gcr.io/distroless/static:nonroot\nCOPY benchharness /benchharness\nUSER 65532:65532\nENTRYPOINT ["/benchharness","stub-serve"]\n' > "$W/Dockerfile"
docker build -t benchharness:fr002b "$W"
kind load docker-image benchharness:fr002b --name platform
```

**The pair.** Two `InferenceDeployment`s serving the same model name, from the same image. `spec.port` must
be **8090**: it sets the containerPort, the Service port and the probe target, but nothing passes it to the
container, so the stub listens on its own default regardless. `gpuCount: 0`, because a GPU request against
a simulated device plugin is one more way for this to fail for a reason that is not the experiment.

```bash
for n in stub-llm stub-llm-spare; do
  kubectl -n serving apply -f - <<EOF
apiVersion: platform.lkhun9311.github.io/v1
kind: InferenceDeployment
metadata: {name: $n, namespace: serving}
spec:
  model: {name: demo-llm, storageUri: "stub://profile?tokens=8&ttft-ms=5&itl-ms=2"}
  image: benchharness:fr002b
  gpuCount: 0
  replicas: 1
  port: 8090
EOF
done
```

`stub-llm` must be the **older** of the two — `backendsFor` sorts oldest-first and the head is what gets
removed. Creating the spare second is what guarantees that, and the script refuses the run if it is not so.

**The access path.**

```bash
KCTX=kind-platform
kubectl --context $KCTX port-forward -n gpu-platform-control-plane-system svc/gateway 8080:8080 &
kubectl --context $KCTX port-forward -n monitoring svc/kps-kube-prometheus-stack-prometheus 9090:9090 &
KCTX=$KCTX OUT=./ex/chaos-fr002b.json ./hack/chaos-fr002b-backend-fallback.sh
```

**Name the cluster.** Every `kubectl` in this script used to run against whatever context happened to be
current. On 2026-09-21 that was an EKS cluster destroyed three days earlier, so every call failed at DNS
resolution and the first check reported `InferenceDeployment stub-llm does not exist` — about a CR sitting
`Ready` in the kind cluster one context away. A wrong-cluster run is indistinguishable from a missing object
unless the script says which cluster it means, so `KCTX` now does, and a reachability probe runs before any
check that could report absence.

**One request before the run, on purpose.** Prometheus does not materialise a counter nobody has
incremented, so on a fresh cluster `gpuaas_gateway_backend_fallbacks_total` has no series at all — not a
series reading zero. Send one request through the gateway first and let a scrape interval pass. The script
now refuses to start when the series is missing rather than reading it as zero, which is the correction
described below.

## The counter this script could not have read

The first version of `promq` printed `0` for a query that matched nothing. Three different situations
produced that same number: the scrape is broken, the series does not exist yet, and the counter really is at
zero. A run in any of the first two states would have reported `delta 0` and concluded the gateway did not
fall back — **a verdict about the gateway drawn from a fact about the query.**

That is not hypothetical. On 2026-09-21 this cluster held no series for `backend_fallbacks_total` or
`rate_limited_total` at all, while `requests_total` sat at 4.

`fr002` had already chosen the other convention — its `promq` returns the empty string and it guards with
`die` — so the two scripts disagreed, and only the guarded one could tell the cases apart. `promq` here now
returns the empty string too, and `must_promq` refuses the run when the gated counter is absent.

Three further counters are read for the same window and deliberately **not** gated on: `rate_limited_total`,
`upstream_errors_total` and `admission_decisions_total`. They answer what else the injection did, which the
fallback delta alone cannot — a gateway that absorbed the traffic by rate-limiting it would also leave
requests succeeding. An absent one is recorded as `null`, never as `0`.
