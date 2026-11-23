# 17. Serving release and capacity

This document ties together three pieces of serving work: how a bad serving release is taken back, what the serving dashboards and alerts actually measure, and what one A10G can carry.
Each section states what its record measured and links that record; a section with no measurement says so and claims nothing.

Status on 2026-11-23: the release restore ([#677](https://github.com/lkhun9311/gpu-platform-control-plane/pull/677)) and the dashboards, runbook and alert ([#679](https://github.com/lkhun9311/gpu-platform-control-plane/pull/679)) are merged into `dev`; capacity ([#673](https://github.com/lkhun9311/gpu-platform-control-plane/issues/673)) is measured in two included GPU sessions, and its record, pull request [#678](https://github.com/lkhun9311/gpu-platform-control-plane/pull/678), is merged into `dev` as `d658e6d3`.
This document links that record at the pull request's head `b69771ce`, whose `experiments/a10g-capacity/` is identical to `dev`'s.

## Contents

- [Serving lifecycle this document covers](#serving-lifecycle-this-document-covers)
- [Release verification and restore in CI (#674)](#release-verification-and-restore-in-ci-674)
- [Serving dashboards, alerts and runbook (#675)](#serving-dashboards-alerts-and-runbook-675)
- [Capacity, overload and recovery on one A10G (#673)](#capacity-overload-and-recovery-on-one-a10g-673)
- [Rules for every result in this document](#rules-for-every-result-in-this-document)

## Serving lifecycle this document covers

The lifecycle is deploy, admission, observe and restore, as drawn in the README's [serving lifecycle](../README.md#serving-lifecycle).
This document collects the evidence for the restore and observe steps and for the capacity of one card.

## Release verification and restore in CI (#674)

Merged in [#677](https://github.com/lkhun9311/gpu-platform-control-plane/pull/677).
The design, the judging rule, the modes and the artifacts are in [`hack/serving-release.md`](../hack/serving-release.md); the job is [`.github/workflows/serving-release.yml`](../.github/workflows/serving-release.yml).

- In the [self-test run](https://github.com/lkhun9311/gpu-platform-control-plane/actions/runs/45046898293) on the pull request's final commit `bfa4772`, the healthy candidate passed, and the TTFT-regression and never-Ready candidates failed and were restored, each restore passing the same Ready check and gateway smoke.
- In the same run, with the saved spec corrupted, the self-test failed as it must, and the CI job asserting that passed.
- A manual [gate run](https://github.com/lkhun9311/gpu-platform-control-plane/actions/runs/45046828971) at `ba23017` with the never-Ready candidate was red, with the candidate failed and restored.
- Scope: a release pipeline on a CPU stub, not vLLM deployment automation, GitOps rollback or zero downtime.

## Serving dashboards, alerts and runbook (#675)

Merged in [#679](https://github.com/lkhun9311/gpu-platform-control-plane/pull/679).
The alert record is [`hack/gateway-alert-delivery.md`](../hack/gateway-alert-delivery.md), with its evidence in [`hack/gateway-alert-delivery-20261122T160709Z/`](../hack/gateway-alert-delivery-20261122T160709Z/); the serving runbook section is section 8 of [`docs/runbook/OPERATOR_RUNBOOK.md`](runbook/OPERATOR_RUNBOOK.md).

The dashboard's Gateway row in [`config/prometheus/operator_dashboard.json`](../config/prometheus/operator_dashboard.json) now has one panel per question, and the runbook's section 8 explains which request each one counts:

| panel | counts |
|---|---|
| Requests that ended in 5xx (final status) | requests, by the status the client got; a stream cut after its 200 is not here |
| Failed backend attempts and fallback rescues | failed attempts, so a request whose two attempts both failed counts twice; and, as a separate series, requests a second backend rescued |
| Responses cut short after starting (no status label) | started responses that ended early, by cause |
| Gateway time to first byte (TTFB) p99 and p50, not TTFT | first byte, a lower bound on time to first token |
| Gateway scrape targets up | whether an empty panel means no events or no scrape |

The runbook's section 8.4 names what it does not cover: central logging, TPOT in Grafana, and gateway HA.
Its last item, a Redis outage entry, was written before #670 merged and still says shared rate limiting is not on `dev`; that entry remains to be written.

- On kind with a CPU stub, with a model left with no engine Pod, `GatewayUpstreamErrorsReachingClients` reached a webhook receiver through Alertmanager 367.2 s after the fault started, most of it the rule's 57 s to first match and its 5-minute hold.
- The resolved notification arrived 297.7 s after the fault ended, and exactly one of each was received.
- Scope: not a page to a person, not a GPU engine.

## Capacity, overload and recovery on one A10G (#673)

Tracked in [#673](https://github.com/lkhun9311/gpu-platform-control-plane/issues/673); the record is in [#678](https://github.com/lkhun9311/gpu-platform-control-plane/pull/678), merged into `dev` as `d658e6d3` and linked here at its head `b69771ce`, whose files are the same as `dev`'s.
The full tables, per rung and per stage with every percentile's `n`, are in [the results document](https://github.com/lkhun9311/gpu-platform-control-plane/blob/b69771ceb790b002fc43e2bd57e95aeeb19eb5d8/experiments/a10g-capacity/RESULTS.md).

- **Contract.** [The measurement contract](https://github.com/lkhun9311/gpu-platform-control-plane/blob/b69771ceb790b002fc43e2bd57e95aeeb19eb5d8/experiments/a10g-capacity/CONTRACT.md) was committed in `e0d4e13a` and last changed in `911c8811` at 2026-11-22T16:16:10Z, before the first GPU session launched at 2026-11-22T23:47:29Z.
  It fixes the workload, the stages, the stability, saturation and recovery rules, the exclusion rules and the sentences each result allows.
- **CPU rehearsal.** The kit's offline gate ran the whole kit against a CPU stub, with must-fail fixtures for each rule and 23 of 23 mutants killed, and printed "all checks passed" ([gate record](https://github.com/lkhun9311/gpu-platform-control-plane/tree/b69771ceb790b002fc43e2bd57e95aeeb19eb5d8/experiments/a10g-capacity/rehearsal/20261122-gate)).
- **Attempt ledger.** [Three launches](https://github.com/lkhun9311/gpu-platform-control-plane/blob/b69771ceb790b002fc43e2bd57e95aeeb19eb5d8/experiments/a10g-capacity/attempts.md): session 1 excluded under X1 (Spot reclaim, evidence partial), sessions 2 and 3 included, which meets the contract's minimum of two.
- **What ran.** One g5.xlarge Spot instance (one A10G) in ap-northeast-2d per session; vLLM v0.27.1 by digest with the `v0.27.1-a10g` profile, whose `--max-num-seqs=64` is rendered by [`engineargs.go`](../internal/engineargs/engineargs.go); `Qwen/Qwen2.5-3B-Instruct` at a pinned revision; 512 tokens in, exactly 128 out, prefix caching off, open-loop Poisson arrivals, 60 s timeout.
  The kit was committed at `e8f92969` for session 2 and `8ab13a53` for session 3, and both built the replayer from `b45b1e51`; each session's raw rows, engine and GPU samples, report and checksums are under its run directory ([s2](https://github.com/lkhun9311/gpu-platform-control-plane/tree/b69771ceb790b002fc43e2bd57e95aeeb19eb5d8/experiments/a10g-capacity/runs/s2/run/results), [s3](https://github.com/lkhun9311/gpu-platform-control-plane/tree/b69771ceb790b002fc43e2bd57e95aeeb19eb5d8/experiments/a10g-capacity/runs/s3/run/results)).

The two sessions are reported side by side and never pooled; TTFT is p99 first, with its count of completed requests.

| | Session 2 | Session 3 |
|---|---|---|
| Highest stable pilot rung (R_sat), 50 s window | 8 req/s: p99 1,688.9 ms (n=385), all 385 completed | 8 req/s: p99 1,643.6 ms (n=385), all 385 completed |
| First unstable rung | 10 req/s: p99 15,142.3 ms (n=533) | 10 req/s: p99 15,239.9 ms (n=533) |
| Baseline, 2 req/s, 135 s window | p99 245.6 ms (n=261), all completed | p99 235.6 ms (n=261), all completed |
| Saturation stage, 8 req/s, 135 s window | **did not hold**: p99 3,698.1 ms (n=1,095), S2 and S3 failed, all completed | **did not hold**: p99 3,547.6 ms (n=1,095), S2 and S3 failed, all completed |
| Overload, 12 req/s, 90 s | p99 36,833.2 ms (n=1,083), all 1,083 completed; engine waiting peaked at 313 | p99 36,968.1 ms (n=1,083), all 1,083 completed; engine waiting peaked at 314 |
| Recovery, 2 req/s, by 20 s windows | recovered 60 s after the overload ended | recovered 60 s after the overload ended |
| Warm restart windows | 45.6, 47.2, 43.9 s | 53.8, 45.2, 44.8 s |

- The 8 req/s pilot rung passed its 50 s measured window; the 150 s saturation stage at the same rate did not hold over its 135 s measured window, in both sessions.
- From the 8 req/s rung up, and in the saturation, overload and recovery stages, the engine's running sequences peaked at 64, the profile's cap, while KV cache usage peaked at 9.9% or less: consistent with the sequence cap, not KV capacity, bounding concurrency. No session ran another cap, so the effect of raising it is not measured.
- Cost per 1M completed output tokens, by stage arrivals, is $0.6617 at 2 req/s and $0.1577 at 8 req/s at the recorded Spot price of $0.5895/h, and $0.8624 and $0.2056 at the runner's all-in cap of $0.7683/h; the 8 req/s figure is at a rate that did not meet the latency rule.

The sentence the contract allows, per session: on one A10G, with this image, profile, model revision and workload, the highest stable rate of the pilot's ladder was 8 req/s.

Not claimed: a universal or maximum capacity of the A10G, end-to-end GPU latency through the gateway (measured separately on kind and never added), any HA or zero-downtime statement (one replica; each restart window is an outage), or anything at large scale.

## Rules for every result in this document

- A result links its code SHA, its config and its raw rows.
- A result is not combined with one measured against a different baseline.
- A sentence says no more than the measurement allows; a result that missed its target is reported as missed.
