# 17. Serving release and capacity

This document ties together three pieces of serving work: how a bad serving release is taken back, what the serving dashboards and alerts actually measure, and what one A10G can carry.
Each section states what its record measured and links that record; a section with no measurement says so and claims nothing.

Status on 2026-11-23: the release restore ([#677](https://github.com/lkhun9311/gpu-platform-control-plane/pull/677)) and the dashboards, runbook and alert ([#679](https://github.com/lkhun9311/gpu-platform-control-plane/pull/679)) are merged into `dev`; capacity ([#673](https://github.com/lkhun9311/gpu-platform-control-plane/issues/673)) is not measured yet, and nothing else here waits for it.

## Contents

- [Serving lifecycle this document covers](#serving-lifecycle-this-document-covers)
- [Release verification and restore in CI (#674)](#release-verification-and-restore-in-ci-674)
- [Serving dashboards, alerts and runbook (#675)](#serving-dashboards-alerts-and-runbook-675)
- [Capacity, overload and recovery on one A10G (#673)](#capacity-overload-and-recovery-on-one-a10g-673)
- [Rules for every result in this document](#rules-for-every-result-in-this-document)

## Serving lifecycle this document covers

The lifecycle is deploy, admission, observe and restore, as drawn in the README's [serving lifecycle](../README.md#serving-lifecycle).
This document collects the evidence for the restore and observe steps and, once it exists, for the capacity of one card.

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
| Failed backend attempts and fallback rescues | attempts, so a request tried twice counts twice, and requests a second backend rescued |
| Responses cut short after starting (no status label) | started responses that ended early, by cause |
| Gateway time to first byte (TTFB) p99 and p50, not TTFT | first byte, a lower bound on time to first token |
| Gateway scrape targets up | whether an empty panel means no events or no scrape |

The runbook's section 8.4 names what it does not cover: central logging, TPOT in Grafana, and gateway HA.
Its last item, a Redis outage entry, was written before #670 merged and still says shared rate limiting is not on `dev`; that entry remains to be written.

- On kind with a CPU stub, with a model left with no engine Pod, `GatewayUpstreamErrorsReachingClients` reached a webhook receiver through Alertmanager 367.2 s after the fault started, most of it the rule's 57 s to first match and its 5-minute hold.
- The resolved notification arrived 297.7 s after the fault ended, and exactly one of each was received.
- Scope: not a page to a person, not a GPU engine.

## Capacity, overload and recovery on one A10G (#673)

**Not measured yet.** Tracked in [#673](https://github.com/lkhun9311/gpu-platform-control-plane/issues/673).
No measurement is reported here, and nothing else in this document waits for one.

When filled, this section will hold:

- the measurement contract, with the commit that shows it predates the first GPU session
- the CPU rehearsal and its must-fail cases
- the attempt ledger, with every launched GPU session and its outcome
- per repeat: saturation, overload, recovery and the restart window, each as code SHA, config, raw rows, calculation and the sentence the result allows
- what it does not claim: universal capacity, end-to-end GPU latency through the gateway, HA

## Rules for every result in this document

- A result links its code SHA, its config and its raw rows.
- A result is not combined with one measured against a different baseline.
- A sentence says no more than the measurement allows; a result that missed its target is reported as missed.
