# AIBrix Autoscaling Lab: Lane 2

Lane 2 of `docs/superpowers/specs/2026-11-18-upstream-integration-design.md`, tracked as issue #654.
It has two parts.
First, an InferenceDeployment can hand its replicas to an external autoscaler, and the reconciler then stops writing them.
Second, a free kind lab runs AIBrix's PodAutoscaler against such a deployment and replays the case of vllm-project/aibrix#3439, where one metric source becomes unavailable.

The serving pods are llm-d-inference-sim, which runs no model.
Its metrics are fixed fake values, so nothing below says how fast anything serves.
The lab records what the autoscaler decided and when it decided it.

## Contents

- [Who writes the replicas](#who-writes-the-replicas)
- [What runs](#what-runs)
- [How to run it](#how-to-run-it)
- [The #3439 replay](#the-3439-replay)
- [The two writers, live](#the-two-writers-live)
- [Verdict and upstream contribution](#verdict-and-upstream-contribution)
- [Limits](#limits)
- [Verifying #3509](#verifying-3509)

## Who writes the replicas

The serving reconciler used to set the Deployment's replicas from the InferenceDeployment on every reconcile (`internal/controller/inferencedeployment_controller.go`).
An autoscaler that changed them was undone on the next reconcile, and the Deployment watch made that reconcile come at once.
The design's first rule for an adoption is one writer per field, so the API now says who that writer is.

| `spec.replicasOwner` | Who writes the Deployment's replicas | What `spec.replicas` means |
|---|---|---|
| absent or `Controller` | the reconciler, on every reconcile, as before | the number of replicas |
| `External` | the autoscaler only; the reconciler sets them once, when it creates the Deployment | the starting count |

`External` changes three readers as well as the writer:

- The phase and the EngineInForce condition are judged against the Deployment's own replicas, the autoscaler's decision, instead of `spec.replicas`.
  Otherwise six ready replicas under a starting count of four would read as a scale-down still in progress.
- A WorkloadRun no longer treats `spec.replicas: 0` as "asked for zero" on such a target, because zero is only where it started.
  An autoscaler's own scale-down to zero still reads as not serving, because the phase is Progressing until it has drained.
- The gateway never counts such a backend as one engine (`servingEngines` in `internal/gateway/router.go`).
  An autoscaler can add an engine before status reports it ready, and the KV guard reads a single engine's state only when there is exactly one.

**HoldCap and PrefixAffinity.**
Both already require `replicas <= 1`, because each one is correct only when a single engine sits behind the Service.
That rule bounds `spec.replicas`, which an external owner no longer decides, so it would no longer bound anything.
The CRD therefore refuses `External` together with `admission.mode: HoldCap` or `routing.policy: PrefixAffinity`.
This also matches the design's statement that HoldCap stays on the direct-backend path.
Supporting HoldCap under an autoscaler would need the autoscaler's maximum to be 1, and AIBrix does not report it to gpuaas.

Turning `External` back to `Controller` sets the Deployment to `spec.replicas` on the next reconcile, whatever the autoscaler had chosen.

### Tests and the mutations they catch

| Test | Mutation | Result under the mutation |
|---|---|---|
| envtest: leaves the Deployment's replicas to the autoscaler when replicasOwner is External | `mutateDeployment` writes replicas unconditionally | the scale to 3 is undone: `Expected <int32>: 1 to equal <int32>: 3` |
| same test, phase step | `replicaTarget` ignores the owner | phase `Progressing`, expected `Ready` |
| `TestIsServingReadsAnExternallyScaledTargetByItsReadyReplicas` | `isServing` ignores the owner | a target started at 0 with two ready replicas is not serving |
| gateway: counts the engines that may answer behind each backend | `servingEngines` drops the owner floor | `"scaled": 1`, expected 2 |
| envtest: refuses an external replica owner with HoldCap or PrefixAffinity | (CEL rules, checked by the refusal messages) | not mutation-tested separately |

The envtest scales the Deployment through its scale subresource, as an HPA would.
AIBrix instead merge-patches the Deployment.
Both are writes of the same field, and the lab below shows the reconciler leaving AIBrix's writes alone.

## What runs

`hack/aibrix-lane2.sh up` creates a one-node kind cluster named `aibrix-lane2`.
Its kubeconfig is a private file under `tmp/aibrix-lane2/`, and no call reads or writes `~/.kube/config`.

| Component | Where it runs | Pinned to |
|---|---|---|
| AIBrix controller-manager, pod autoscaler controller only | in the cluster, from upstream's config/standalone/autoscaler-controller overlay with the image swapped and `--v=2` added | AIBrix main 01ac3858c6a1, built locally onto a digest-pinned distroless base |
| gpuaas InferenceDeployment reconciler | on the host (`hack/aibrix-lane2/reconciler`), the same type the manager registers | this repository's commit, recorded in each run's `pins.txt` |
| `chat`: the InferenceDeployment's pods | generic serving container, `replicasOwner: External`, starting at 4 | llm-d-inference-sim 6ab9d4b2367a (the lane 1 build), behind `hack/aibrix-lane2/simshim` |
| `queue-metrics`: the external metric | a plain Deployment and Service, same simulator | same |

`simshim` exists because the generic container is started as `--model <name> --model-path <uri>` on port 8080, while the simulator rejects `--model-path` and listens on 8000.
It drops that flag, adds the port and the fake metric, and execs the simulator.

Only the reconciler runs on the host because the full manager also starts the admission webhooks and the Kueue controllers.
Those need certificates and CRDs the lab does not install, and none of them touches a Deployment's replicas.

## How to run it

```
hack/aibrix-lane2.sh up
go run ./hack/aibrix-lane2/reconciler --kubeconfig tmp/aibrix-lane2/kubeconfig >tmp/aibrix-lane2/reconciler.log 2>&1 &
hack/aibrix-lane2.sh replay 0s 90      # the arm #3439 describes
hack/aibrix-lane2.sh fight             # hand the replicas back to the controller
hack/aibrix-lane2.sh replay 300s 420   # AIBrix's default scale-down cooldown, outage longer than it
hack/aibrix-lane2.sh down
```

Each run writes a directory under `hack/aibrix-lane2/runs`, named by its start time and arm: `timeline.tsv` (a row every 5 s), `events.txt`, `aibrix-decisions.log` (the lines that decide the case), the full AIBrix and reconciler logs gzipped, and the final PodAutoscaler and InferenceDeployment.

The three committed runs were taken at commit c2a61c973cd5.
Their `pins.txt` says "with uncommitted changes".
The only uncommitted path at the time was the runs directory itself, which the check then included.
f36bf8d3b706 excludes it.

## The #3439 replay

The shape is the one in the report.
A KPA has a per-pod metric, `kv_cache_usage_perc` at 0.25 against a target of 0.5.
That is AIBrix's name for vLLM's renamed `gpu_cache_usage_perc`, which the simulator reports as a fraction.
It also has an external metric, the queue length, at 200 against a target of 50.
At 4 pods the pod metric asks for 2 and the queue asks for 4, so the queue is what holds 4.
The outage scales `queue-metrics` to zero, so every fetch of the external metric fails.
The recovery brings it back at 300, which asks for 6.

AIBrix logged its recommendations as a list of the per-source counts it took the maximum over.

**Cooldown 0s** (`runs/20261118T133004Z-cooldown-0s`):

| UTC | Event | AIBrix recommendations | Deployment replicas |
|---|---|---|---|
| 13:30:13 to 13:31:43 | both sources readable | [2,4], max 4 | 4 |
| 13:31:47 | queue endpoint removed | | 4 |
| 13:32:00 | first reconcile after it: "Failed to compute replicas for metric" for the queue, then the pod metric alone | [2], max 2 | 4 → 2, reason "All metrics below target" |
| 13:32:07 to 13:33:20 | outage continues | [2] | 2 |
| about 13:33:21 | queue endpoint back at 300 | | 2 |
| 13:33:23 | first reconcile after it | [2,4] → 4, then [4,6] → 6 | 2 → 4 → 6, ready 6 by 13:33:27 |

**Cooldown 300s, AIBrix's default** (`runs/20261118T133619Z-cooldown-300s`):

| UTC | Event | AIBrix recommendations | Deployment replicas |
|---|---|---|---|
| until 13:38:03 | both sources readable | [2,4] | 4 |
| 13:38:07 | queue endpoint removed | | 4 |
| 13:38:20 to 13:43:10 | 30 failed fetches of the queue source logged (43 over the whole outage) | [2] | 4, held by the cooldown window |
| 13:43:10 | 5 min 7 s after the last [2,4] | [2] | 4 → 2, reason "All metrics below target" |
| 13:45:14 | queue endpoint back at 300 | | 2 |
| 13:45:20 | | → 4, then → 6 | 2 → 4 → 6, ready 6 by 13:45:25 |

What the two runs show:

1. The report's mechanism holds end to end on main 01ac3858c6a1.
   The failed source is skipped, the maximum is taken over the source left, and the target scales down on it.
2. With a 0s cooldown it happens on the first reconcile after the endpoint goes, 13 s here.
3. The default 300s cooldown delays it, but does not prevent it.
   An outage longer than the window removes the replicas.
4. Recovery and a valid scale-up are unaffected.
   As soon as the queue source reads again, the larger recommendation wins and the target goes to 6 within the same reconcile.
   This is the half the HPA rule in the report keeps: scale-ups from the remaining sources still go ahead.
5. Nothing outside the controller log says that a source failed.
   The three runs have no Warning event from the PodAutoscaler and no FailedComputeScale event, because that event fires only when every source fails.
   The scale-down is recorded with the reason "All metrics below target", although one of the two metrics could not be read.

## The two writers, live

`runs/20261118T133358Z-controller-owned` starts from 6 replicas under `External` and then removes `replicasOwner`, so the controller owns the replicas again.

| UTC | Deployment replicas | PodAutoscaler desired |
|---|---|---|
| 13:33:58 to 13:34:14 | 6 | 6 |
| 13:34:19, owner removed | 4 (`spec.replicas`) | 6 |
| 13:34:23 to 13:36:13 | 4 at every sample | 6 |

In those 116 s AIBrix logged "Successfully rescaled" from 4 to 6 twenty-four times, and the Deployment was set back to 4 every time.
The final managed fields name the reconciler as the last writer, at 13:36:13.
This is the conflict the envtest guards against, here between the real AIBrix controller and the real reconciler.
Under `External`, in the other two runs, the Deployment's replicas followed AIBrix's decisions at every sample.
Those runs did not record managed fields, so that is shown by the timeline and not by the field owner.

## Verdict and upstream contribution

**Not already covered.**
No fix for #3439 has merged into AIBrix main, and no pull request for it is open as of 2026-11-18.
The issue is labelled kind/bug but not triage/accepted.
The fix author says a fix with tests is ready and is waiting for the maintainer's decision on the default (hold or best-effort, opt-in or not).
The maintainer's open question is the capacity cost of holding replicas through a long outage.
The related #2592 (merged 2026-08-23) covers only the case where every source fails.

**What follows upstream: a reproduction comment on #3439, not yet a pull request.**
AIBrix's CONTRIBUTING limits work on an issue without triage/accepted to "investigation, reproduction, and improving the issue".
It also says that a test-only change is not automatically exempt.
So the contribution is the replay above, posted as a comment.
It does not repeat what the thread already has: the mechanism, the restore cost data, or the visibility point.
It adds observed timelines for both cooldown settings and the confirmation that a scale-up is not blocked.
Those bear directly on the maintainer's capacity-cost question.
Extra test coverage, such as an end-to-end case of a failing source followed by a recovery scale-up, is offered to the fix author for the PR once the issue is accepted, rather than sent separately.

## Limits

- The serving pods are a simulator with fixed fake metrics.
  The per-pod metric never moves, so this lab exercises the decision logic and not how the metrics behave under load.
- The external source is a second simulator standing in for a gateway queue endpoint.
  Its outage is "the Service has no endpoint", which fails fast.
  A slow or hanging endpoint would spend AIBrix's fetch retries differently and was not tried.
- One kind node and one run of each arm.
  The times are the controller's 10 s resync and fetch backoff on this machine, not a property to rely on.
- The gpuaas reconciler ran on the host and not in the manager, so the admission webhooks were not in the path.
  None of them touches replicas.
- The CRD rules that refuse `External` with HoldCap or PrefixAffinity are checked by their refusal messages and were not mutation-tested on their own.

## Verifying #3509

vllm-project/aibrix#3509 is the fix the maintainer asked for on #3439.
It adds the opt-in annotation `autoscaling.aibrix.ai/hold-scale-down-on-metric-failure`.
With it, a failing source blocks a metric-driven scale-down, a healthy source can still scale up, and the replica bounds still apply.
Whether or not it is set, a Warning event names the failed source and a scale-down on partial data gets its own reason.

`hack/aibrix-pr3509.sh` replays the same two sources against the PR's base, main afdb4791527e, and its head cb1a2f3f05d6.
It reuses this lab's simulator images and upstream's overlay.
The target is a plain Deployment, so no gpuaas reconciler runs and only AIBrix writes the replicas.
The cooldown is 0s and `maxReplicas` is 6.
The queue source stays down from phase 2 to phase 8.
While it is down, the pod metric's target is moved so that the healthy source asks for more or fewer replicas, and the bounds are moved across the current count.

| Phase | Change | Healthy source asks |
|---|---|---|
| 1 | both sources readable | 2, queue asks 4 |
| 2 | queue endpoint removed | 2 |
| 3 | kv target 0.5 → 0.2 | 5 from 4 pods |
| 4 | kv target 0.15 | 9 from 5 pods, above max 6 |
| 5 | kv target 0.5 | 3 from 6 pods |
| 6 | minReplicas 7, maxReplicas 8 | below min |
| 7 | minReplicas 1, maxReplicas 5 | current above max |
| 8 | queue back at 100 | 2 or 3, queue asks 2 |

Runs are under `hack/aibrix-pr3509/runs`.
Each has `timeline.tsv`, `events.txt`, `aibrix-decisions.log`, the full controller log gzipped, and the final PodAutoscaler.

### Results

| Case | main, KPA and APA | PR, annotation off | PR, annotation "true" |
|---|---|---|---|
| Outage, healthy source asks 2 | 4 → 2 on the first reconcile, 13 s (KPA) and 10 s (APA) after the first outage sample; APA then goes to 1 | same as main; APA's 15 rescales match main's one for one | held at 4 for the whole phase (KPA 19, APA 17 held passes) |
| Healthy source above target, queue still down | scales up | scales up | 4 → 5 (KPA and APA) |
| Scale-up past maxReplicas 6 | | | 5 → 6, stops at 6 |
| Healthy source below target again | | | held at 6 |
| minReplicas 7 | | | 6 → 7 |
| maxReplicas 5 | | | 7 → 5, reason "current replicas above maximum" |
| Queue source back | | | KPA 5 → 3, APA 5 → 3 → 2 → 3; hold released |
| Warning event naming the source | none | `FailedGetMetrics` | `FailedComputeScale` while held, `FailedGetMetrics` on a scale-up |
| Scale-down reason | "All metrics below target" | "Available metrics below target (vllm:num_requests_waiting could not be read)" | (held) |

The main and annotation-off KPA runs went into KPA panic mode after the scale-up from 2.
Panic keeps the peak, so their phases 5 to 7 do not compare with the held run and are left out of the table.

### What is wrong or missing

**The per-reconcile Warning uses up the PodAutoscaler's event budget.**
client-go v0.31.8, which AIBrix uses, passes 25 events per involved object and then one every 5 minutes (`defaultSpamBurst`, `defaultSpamQPS` in `tools/record/events_cache.go`).
The key is the object, not the reason.
The PR raises `FailedGetMetrics` or `FailedComputeScale` on every pass while a source fails, about every 7 s here.

| Run | PodAutoscaler events emitted (controller log) | reached the API server |
|---|---|---|
| main KPA | 12 | 12 |
| PR KPA, annotation off | 54 | 27 |
| PR KPA, annotation on | 47 | 25 |
| main APA | 34 | 27 |
| PR APA, annotation off | 68 | 25 |
| PR APA, annotation on | 52 | 25 |

In the annotation-off KPA run, the last event to arrive is at 08:18:51.
The scale-downs at 08:19:12 (6 → 3), 08:19:19 and 08:20:30 have no `SuccessfulRescale` event, although each carries the new "Available metrics below target" reason.
In the annotation-on KPA run, the scale to 7 for minReplicas and to 5 for maxReplicas have no event, and the hold warnings after 08:05:50 are dropped too.
In both, the controller log shows every one of them.
main APA also loses events, from its own 1 ↔ 2 oscillation, but the PR doubles the count.

**A scale forced by the bounds during a hold names no failed source.**
The hold returns an error, and `computeScaleDecision` turns that error into a bounds decision without `FailedMetrics`.
The scale to 5 at 08:07:15 (KPA, annotation on) has reason "current replicas above maximum", and no warning in that pass names the queue source.
The next pass, back at the hold, does.

**A hold is recorded as a failed scaling decision.**
`setStatus` is called with `success=false`, so every pass past the 5 s guard appends a `FailedComputeScale` entry to `scalingHistory` and moves `lastScaleTime`.
In the KPA annotation-on run, `lastScaleTime` is 08:07:46, a held pass that changed nothing, and three of the five history entries are holds.
`lastScaleTime` is documented as the last time the replicas changed.

**A hold leaves the outage out of the scale-up cooldown.**
A held pass returns before `stabilizeRecommendation`, so its recommendation is never recorded.
`hack/aibrix-pr3509.sh upwindow` sets `scale-up-cooldown-window: 60s` and `scale-down-cooldown-window: 300s`, holds the queue down for 80 s, and then asks for 7 (capped at 6).

| Run | kv target patched | scaled 4 → 6 |
|---|---|---|
| annotation off | 08:44:44 | 08:45:57, 73 s later |
| annotation on | 08:48:36 | 08:48:44, 8 s later |

With the annotation off, the outage's recommendations of 2 sit in the 60 s window and hold the scale-up back.
With it on, they were never recorded.
The default scale-up window is 0, so this only shows when a user sets one.
It is a difference in behaviour, not clearly a defect, and the design does not say which is wanted.

**The regression test depends on the clock.**
`TestComputeDesiredReplicasHoldsScaleDownWhileAMetricFails` calls `ComputeDesiredReplicas` twice with `time.Now()`.
The metric window keeps one value per second, so when the two calls fall in the same second the second value replaces the first.
A copy of the test with the two timestamps pinned 2 ns apart across a second boundary gets 5 replicas instead of 8, for KPA and APA.
The window then averages 25 and 100.
The same copy with both timestamps equal passes.

### Checked and not a problem

- The PR's unit tests pass: `go test -race ./pkg/controller/podautoscaler/...` at cb1a2f3f.
- The stabilized recommendation never goes below the current count when the raw one is at or above it, so checking the hold before stabilization does not miss a scale-down.
- A held reconcile returns no error, and the periodic resync evaluates it again; the runs show a pass every 7 s throughout each hold.

### Limits of this verification

- One run per case on one kind node, with simulator metrics that never move on their own.
- The healthy source's demand was changed by patching its target value, not by changing the metric.
- The outage is a Service with no endpoint, which fails fast.
- codex (gpt-6-astra, high, read-only) reviewed the diff independently.
  The bounds-warning, history, cooldown and test-clock findings were its points.
  Each was then checked here, by the runs above or by the pinned-timestamp test.
  The event budget finding came from these runs.
