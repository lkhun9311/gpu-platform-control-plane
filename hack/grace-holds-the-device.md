# A Pod survives its own deletion for min(remaining service, grace period)

The title used to say "the device is held", and that was an inference this repository refuses everywhere
else. What the script below measures is how long a Pod OBJECT survives after `kubectl delete`, on Pods that
request no device at all, on a cluster whose `nvidia.com/gpu` capacity comes from a fake device plugin. Every
run record in this lab carries `deviceUseEstablished: false` precisely so that GPU-seconds are never read as
computation; a title claiming otherwise was the same overclaim with the caveat moved to the bottom of the
page. It is corrected here rather than quietly deleted, because the correction is the point: the model below
is about Pod lifetime, and device occupancy FOLLOWS Pod lifetime, which is a second step this page does not
take.

The model:

    held = min(remaining service, grace period)

It matters because the admission guard caps grace at 120 seconds for device holders, and a cap wants a
measured curve rather than an assumed one.

## What the lab establishes without this script

This page used to claim the lab could not reach this axis at all, and that claim was too strong. The lab
measures the grace period DIRECTLY, inside every validity gate it has, as the difference between its two arms
in the `grace-bounded` regime:

| dose regime | quantity | A-honor | A-ignore | difference | floor |
|---|---|---|---|---|---|
| grace-bounded | quota owner running after admission | 2.674 s | 30.754 s | **28.1 s** | 5.387 s |
| grace-bounded | borrower discarded | 21.408 GPU-s | 51.382 GPU-s | 30.0 s | 5.387 s |

Both differences are the grace period, recovered from the experiment rather than assumed by it, over four
interleaved runs with an exclusive-worker window, a termination canary, continuous list/watch observation and
a containment audit behind each one, and reproduced on a second worker node with the cluster's occupancy
held fixed (0.132 s apart under the honouring arm, against a 6.334 s floor).
`queuelabrun -compare` re-derives them from the records:

    $ queuelabrun -compare 'ex/e16-grace-bounded-*-e16g??.json'
    $ queuelabrun -compare 'ex/e16-self-completing-*.json,ex/e16-grace-bounded-*-e16g??.json' -mode model

The first row is the one that matters to a platform: it is the quota owner's own waiting time, and it is what
a reclaim promise is judged on. The second is the borrower's loss, which is real and is not a service-level
objective.

So the load-bearing half of the finding — that an unresponsive victim converts grace into the owner's waiting
time — is gated. What is NOT gated is the SHAPE of the curve across grace values, and that is what remains
below.

## Why the sweep still runs outside the lab

`MLTrainingJob` has no grace field, so the lab cannot vary this axis.

`TerminationContractTrace` also refuses any dose whose remaining service does not match the declared regime —
`self-completing` errors at or above the grace period, `grace-bounded` errors below it. That guard is right
to exist: it stops a run silently sitting in a regime other than the one it claims.

Adding the field was proposed and rejected under review. `terminationGraceSec = 30` is not an axiom the lab
asserts: it is the apiserver's own default, and `judgeCanary` REFUSES to qualify a worker whose stored value
is anything else. Making the harness set grace would turn that environment check into a tautology, dissolve
the four other constants sized against 30, and expose a field that would let a tenant quadruple the worst-case
reclaim the cap exists to bound. The sweep stays out here, on plain Pods, where the parameter is free and
where what is measured is honestly a Pod's lifetime.

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

**A borrower's Pod survives reclamation for `min(its remaining work, its own grace period)`, and a device is
released when its Pod is gone.** Both terms are the tenant's: it chooses the workload and it chooses the
grace. The platform's only lever is a cap on the second, which is why one exists. The second clause is the
step this page does not measure — it is how Kubernetes accounts for extended resources, not an observation
made here.

The cap turns an unbounded hold into a bounded one. At `grace ≤ 120` the worst case is 120 seconds regardless
of how long the workload would otherwise have run — the second row of the table, generalised. Without it,
`terminationGracePeriodSeconds: 3600` is a supported Kubernetes field that keeps a device for an hour against
an owner that has already reclaimed it.

It does not make reclaim immediate. Nothing in Kubernetes will, short of refusing the grace period entirely,
and that pushes tenants toward ignoring SIGTERM — which this same table shows is the behaviour that costs the
owner the most.

## What it does not say

- **No GPU, and no device at all.** These Pods request none; the quantity measured is how long a Pod object
  survives its own deletion. That a device-holder's occupancy follows its Pod's lifetime is how Kubernetes
  accounts for extended resources, not something observed here — and on this cluster the capacity is
  advertised by a fake device plugin, so even the reclaim experiment measures seconds of RESERVATION. The
  physical-device claim stays an inference until a real-GPU stage.
- **One workload shape.** `sleep` as PID 1. A workload that handles SIGTERM and exits promptly holds the
  device for as long as its handler takes, which this does not measure.
- **Five points, one run each.** The knee is located between 30 and 60 by two points either side of 43, not
  bisected.
- **Wall time including two API round trips**, so every figure is an upper bound on the container's own
  shutdown by roughly a second.

## Reproducing

    ./hack/grace-holds-the-device.sh                       # defaults: remaining 45s, grace 10..120
    REMAINING=90 GRACES="30 60 90 150" ./hack/grace-holds-the-device.sh
