# The device is held for min(remaining service, grace period)

The reclaim experiment showed that a workload ignoring SIGTERM defeats quota reclaim while its remaining
service fits inside the termination grace period, and is cut off at grace once it does not. Two points, one
on each side. It implied a model and did not test one:

    held = min(remaining service, grace period)

That model is why the admission guard caps grace at 120 seconds for device holders, so it should be measured
rather than assumed.

## Why not through the queuelab

Two reasons, and the second is the more interesting.

`MLTrainingJob` has no grace field, so the lab cannot vary this axis at all.

More to the point, `TerminationContractTrace` **refuses** any dose whose remaining service does not match the
declared regime — `self-completing` errors at or above the grace period, `grace-bounded` errors below it. The
guard is right to exist: it stops a run silently sitting in a regime other than the one it claims. But it
also writes `terminationGraceSec = 30` into the harness as an axiom and rejects every configuration that
would probe it. The lab cannot answer where the knee is, because it will not run the points near it.

So this uses plain Pods, where the parameter is free.

## Result

Remaining service 45 s, deleted 2 s in, so 43 s left in every case. The workload is `sleep` as PID 1, which
ignores SIGTERM without a handler — the arm that defeats reclaim.

| grace | remaining | held | model says |
|---|---|---|---|
| 10 s | 43 s | 11.20 s | 10 |
| 20 s | 43 s | 20.67 s | 20 |
| 30 s | 43 s | 31.30 s | 30 |
| 60 s | 43 s | **42.69 s** | 43 |
| 120 s | 43 s | **43.35 s** | 43 |

**The model holds and the knee is where it predicts.** Below 43 seconds of grace the hold tracks grace; above
it the hold tracks remaining service and stops responding to grace at all. Residuals are between −0.3 and
+1.3 seconds, which is the API round trip this measurement includes at each end.

## What it means for the platform

**A borrower holds a reclaimed device for `min(its remaining work, its own grace period)`.** Both terms are
the tenant's: it chooses the workload and it chooses the grace. The platform's only lever is a cap on the
second, which is why one exists.

The cap turns an unbounded hold into a bounded one. At `grace ≤ 120` the worst case is 120 seconds regardless
of how long the workload would otherwise have run — the second row of the table, generalised. Without it,
`terminationGracePeriodSeconds: 3600` is a supported Kubernetes field that keeps a device for an hour against
an owner that has already reclaimed it.

It does not make reclaim immediate. Nothing in Kubernetes will, short of refusing the grace period entirely,
and that pushes tenants toward ignoring SIGTERM — which this same table shows is the behaviour that costs the
owner the most.

## What it does not say

- **No GPU.** These Pods request no device at all; the quantity measured is how long a Pod object survives
  its own deletion, which is what a device-holder's occupancy would follow. The reclaim experiment measured
  the device-holding version and agrees at the two points it can reach.
- **One workload shape.** `sleep` as PID 1. A workload that handles SIGTERM and exits promptly holds the
  device for as long as its handler takes, which this does not measure.
- **Five points, one run each.** The knee is located between 30 and 60 by two points either side of 43, not
  bisected.
- **Wall time including two API round trips**, so every figure is an upper bound on the container's own
  shutdown by roughly a second.

## Reproducing

    ./hack/grace-holds-the-device.sh                       # defaults: remaining 45s, grace 10..120
    REMAINING=90 GRACES="30 60 90 150" ./hack/grace-holds-the-device.sh
