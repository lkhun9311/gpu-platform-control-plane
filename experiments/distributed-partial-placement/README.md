# A distributed job with one rank placed: registration

Registered 2026-10-21, before any registered run.
The design, with the reasoning and the three adversarial reviews that shaped it, is `docs/superpowers/specs/2026-10-21-distributed-partial-placement-design.md`; this page fixes what a run is and how it is read.
`hack/distributed-partial-placement.sh` runs it, `sample.py` and `watch.py` here record it, and `analyze.py` here scores it; none of them may be changed between the registered run and its reading.

## The question

When Kueue admits a two-rank `MLTrainingJob` and only one rank can be placed, what does the platform report, how long is the quota held before the ranks join, what does Kueue's `waitForPodsReady` do about it, and does the job finish when the blocking device is freed at 300 s?

## Fixed values

| | |
|---|---|
| Kueue | v0.18.3, release manifest, configuration `config.kueue.x-k8s.io/v1beta2` |
| `off` | no `waitForPodsReady` stanza |
| `ready-timeout` | `timeout: 120s`, `recoveryTimeout: 120s`, `blockAdmission: false`, `requeuingStrategy: {timestamp: Eviction, backoffBaseSeconds: 30, backoffMaxSeconds: 3600, backoffLimitCount: 2}` |
| job | `worldSize: 2`, `gpuCount: 1`, image `cpu-ddp:torch251`, `DDP_RENDEZVOUS_TIMEOUT_SECONDS=1500` |
| quota | ClusterQueue nominal `nvidia.com/gpu` 2 |
| devices | one simulated `nvidia.com/gpu` per worker, two workers |
| squatter | `nvidia.com/gpu: 1`, bound to the second worker, `terminationGracePeriodSeconds: 0` |
| window | 600 s from the job's creation |
| `late` | the squatter is deleted 300 s after creation |
| runs | `off` never, late, never, late; one configuration change; `ready-timeout` never, late, never, late |

`analyze.py` refuses to score a run as registered unless the harness recorded `window=600 late_at=300`; a run with any other window is reported as a rehearsal.

## What is read

The measures M1 to M7, the timing rule, the validity rules and the predictions P1 to P5 are the design's, sections "What is measured", "Timing rule", "Validity, per run" and "Registered predictions"; `analyze.py` implements them and its tests pin each one.
A rule whose evidence is missing fails. A void run is reported with its reason and its scenario is rerun once.

## The scorer was corrected during the registered run, before it was read

The registered run started at 06:56Z from commit `b3d1194`. While it ran, codex `gpt-6-astra`'s review of that commit (`codex review --commit b3d1194`, no prompt) found six scorer defects; none was in the harness or the recorders, so the evidence being collected was unaffected.
They were fixed, each with a test that fails against `b3d1194`'s scorer, before any registered run's measures were read: M8 took ranks from earlier attempts; observations after the window were counted; a deletion request alone counted as a stopped attempt; a watch that died without an end marker counted as covering the window, so the watch is now checked against every successful poll; P1 read Running alone instead of Running while stranded; and a void registered run left the exit at zero.
The registered run is read only with the corrected scorer, whose commit the results name.

## Rehearsals

Two rehearsals ran before registration, on 200 s windows, to find harness defects; their numbers are not results and are not published.
The first ran the harness without the watch streams; the second with them.
