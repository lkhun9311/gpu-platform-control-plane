# 17. Serving release and capacity

This document ties together three pieces of serving work: what one A10G can carry, how a bad serving release is taken back, and what the serving dashboards and alerts actually measure.
Each section is filled only after its issue's done-when is met.
Until then the section says it is pending, and nothing in it is a result.

Status on 2026-11-23: all three sections are pending.

## Contents

- [Serving lifecycle this document covers](#serving-lifecycle-this-document-covers)
- [Capacity, overload and recovery on one A10G (#673)](#capacity-overload-and-recovery-on-one-a10g-673)
- [Release verification and restore in CI (#674)](#release-verification-and-restore-in-ci-674)
- [Serving dashboards, alerts and runbook (#675)](#serving-dashboards-alerts-and-runbook-675)
- [Rules for every result in this document](#rules-for-every-result-in-this-document)

## Serving lifecycle this document covers

The lifecycle is deploy, admission, observe and restore, as drawn in the README's [serving lifecycle](../README.md#serving-lifecycle).
The deploy and admission steps exist in the code today.
This document adds the evidence for the observe and restore steps and for the capacity of one card.

## Capacity, overload and recovery on one A10G (#673)

**Pending.** Tracked in [#673](https://github.com/lkhun9311/gpu-platform-control-plane/issues/673).
No measurement is reported here yet.

When filled, this section will hold:

- the measurement contract, with the commit that shows it predates the first GPU session
- the CPU rehearsal and its must-fail cases
- the attempt ledger, with every launched GPU session and its outcome
- per repeat: saturation, overload, recovery and the restart window, each as code SHA, config, raw rows, calculation and the sentence the result allows
- what it does not claim: universal capacity, end-to-end GPU latency through the gateway, HA

## Release verification and restore in CI (#674)

**Pending.** Tracked in [#674](https://github.com/lkhun9311/gpu-platform-control-plane/issues/674).
No pipeline run is reported here yet.

When filled, this section will hold:

- the self-test: the healthy candidate passes, and the TTFT-regression and never-Ready candidates fail and are restored
- a gate run with a bad candidate that is red and shows the restore
- a broken restore that turns the self-test red
- links to each run's artifacts: the CR before, the candidate, and the CR after
- the scope: a release pipeline on a CPU stub, not vLLM deployment automation, GitOps rollback or zero downtime

## Serving dashboards, alerts and runbook (#675)

**Pending.** Tracked in [#675](https://github.com/lkhun9311/gpu-platform-control-plane/issues/675).
No alert rehearsal is reported here yet.

When filled, this section will hold:

- the changed dashboard panels and their queries
- one alert's firing and resolved notifications at a local test receiver, next to the fault's start and end times
- what the runbook does not cover: central logging, TPOT in Grafana, HA

## Rules for every result in this document

- A result links its code SHA, its config and its raw rows.
- A result is not combined with one measured against a different baseline.
- A sentence says no more than the measurement allows; a result that missed its target is reported as missed.
