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
astra's review of that correction (`d2453ba`) found two defects in the new validity checks, also fixed with a failing-first test each before any reading: a container still running at the window's end with its eviction pending was voided as ending by itself, because a deletion request was taken for an end; and the watch-against-poll check required one watch snapshot to match a poll that is several separate reads, so each resource is now matched on its own within 2 s.
The registered run is read only with the corrected scorer, whose commit the results name.

## Result (registered run 2026-10-21, `hack/distributed-partial-placement-20261021T065335Z/`)

Run from harness commit `b3d1194` and scored with `b651f81`; `score.txt` there is the scorer's output, and scoring the gzipped recordings gave byte-identical output to scoring them uncompressed, whose checksums are in `SHA256SUMS-uncompressed-jsonl`.
Both settings were shown in force, all eight runs were valid, and every registered prediction held in both repetitions:

| run | prediction | the numbers |
|---|---|---|
| `off-never` ×2 | P1 held | `Running` while stranded 598.1 s of 598.1 s from the first `Running`, 0.4 s after the placed rank's Ready; one reservation of 599 s, censored at the window's end; no eviction |
| `off-late` ×2 | P2 held | `Running` for all 299.2 s to the second rank's placement at 300.6 and 300.7 s; `Succeeded` at 303.7 and 304.9 s; one admission |
| `ready-timeout-never` ×2 | P3, P5, P6 held | admissions at 0, 150 and 330 s; two `PodsReadyTimeout` requests 120 s after their admission, each stopping its attempt; a third ending in `DeactivatedDueToRequeuingLimitExceeded`; largest requeue count 2; each release 1.1 s after its request; `Running` while stranded 356.2 s |
| `ready-timeout-late` ×2 | P4, P5, P6 held | two stopped attempts before the squatter's deletion, the third admission at 330 s, `Succeeded` at 334.4 and 334.9 s; `Running` while stranded 237.6 and 237.8 s |

In every one of the ten evictions the placed rank kept its device 28.9 s after the quota was released and ended with exit 137 (P6, informed by the second rehearsal); each discarded attempt cost 149 to 150 s of that rank's container time.
The headline figures were re-derived by a separate script from the Workload conditions' own transition times and the containers' timestamps: admissions at 0, 150 and 330 s, evictions 120 s after admission, releases 1 s after, the device held 29 s at whole-second resolution.
What it means and what it does not is Finding 10 in `docs/11_WHAT_THIS_MEASURED.md`.

## After the phase fix

The fix Finding 10 pointed at, `Running` only when every rank is Ready, was confirmed on this harness with only the controller changed: one `off` run per scenario at `WINDOW=300 LATE_AT=150`, in `hack/distributed-partial-placement-20261021T093821Z/`.
That is not a run of this study, and the scorer says so; P1 and P2 describe the old rule and fail there as expected.
What it showed is in `docs/superpowers/specs/2026-10-21-phase-waits-for-every-rank-design.md`, "Confirmation on kind".

## Result after both fixes (registered run 2026-10-23, `hack/distributed-partial-placement-20261023T011849Z/`)

Registered by `docs/superpowers/specs/2026-10-22-finding-10-after-the-phase-fix-design.md` and run from its freezing commit `55530a98`, with the controller's phase fix and the trainer's signal fix both in place, at the registered 600 s window with the squatter deleted at 300 s.
`score.txt` is the scorer's output, identical to what the run printed; scoring the gzipped recordings gave byte-identical output, and the uncompressed checksums are in `SHA256SUMS-uncompressed-jsonl`.
`dirty_files=1` in `provenance.txt` is this evidence directory itself, which exists before that line is written.
Both settings were shown in force, all ten runs were valid, and every registered prediction held:

| run | prediction | the numbers |
|---|---|---|
| all ten | Q1 held | M1 0 s, unrounded and after every single watch event, with no state seen only in a tie |
| `off-never` ×2 | Q2 held | `Pending`, then `Admitted` with `readyRanks` 1 to the window's end; no `runningObservedAt`; one reservation of 599.8 and 599.2 s, censored at the window's end |
| `off-late` ×2 | Q3 held | one entry into `Running`, 0.494 and 0.512 s after the second rank was Ready; `admitToRunningSeconds` 301.466 and 301.838; `Succeeded` at 305.1 and 305.6 s |
| `ready-timeout-never` ×2 | Q4, Q6 held | Finding 10's P3 unchanged: admissions at 0, 150 and 330 s, two `PodsReadyTimeout` requests 120 s after their admission, then deactivation; no entry into `Running`; `admittedAt` the first admission's stamp throughout |
| `ready-timeout-late` ×2 | Q5, Q6 held | Finding 10's P4 unchanged, admissions at 0, 150 and 330 s; the only entry into `Running` 0.4 s after the third admission's ranks were both Ready; `Succeeded` at 334.1 and 334.8 s |
| `ready-timeout-witness` ×2 | Q1, Q6, Q7 held | the witness reserved 1.0 s after the first release, its Pod scheduled 0.03 s after that (M9), 2 s after the evicted rank's `finishedAt` |

In all sixteen stopped attempts the placed rank ended with exit 143, and its container's `finishedAt` was 1.1 s before the recorded release (M8 −1.1 s, uncensored); exit 137 appears nowhere in the recordings.
`finishedAt` is whole seconds, so −1.1 s says the rank stopped within the second before Kueue's release was recorded, not that it stopped before it was asked to.
P1, P2 and P6 were contradicted, as the registration said they would be, because they describe the old phase rule and the old trainer.

A separate script read the watch streams without `analyze.py` and re-derived the headline figures:
- the CR's phase sequence in every run, with entries into `Running` only in the four `late` runs and only after both ranks' first Ready;
- exit codes 143 and 0 only;
- every stopped attempt's `finishedAt` 1.06 to 1.07 s before its Workload's quota transition;
- in both witness runs, the witness's quota reserved 1.01 s after the first release and its Pod scheduled 0.03 s after that.

Two things no prediction covered were seen, and they are reported as observations:
- In the witness runs the job's second admission came at 186 s, not 150 s, because its two-GPU request waited for the witness to finish its 60 s on one of the two; the third came 180 s after the second, as without the witness.
- In the four `late` runs the CR read `Running` for 1.0 to 2.7 s and then `Admitted` for 1.0 to 2.0 s before `Succeeded`. In that interval the ranks' Pods were still `Running` with `Ready=False`, then `Succeeded` about a second before the Job recorded `Complete`, and the phase rule, which needs a Ready rank for `Running` and the Job's completion for `Succeeded`, calls that `Admitted`. So the job's last seconds are reported as not yet running, the cautious side of the error Finding 10 measured.

## Rehearsals

Two rehearsals ran before registration, on 200 s windows, to find harness defects; their numbers are not results and are not published.
The first ran the harness without the watch streams; the second with them.
