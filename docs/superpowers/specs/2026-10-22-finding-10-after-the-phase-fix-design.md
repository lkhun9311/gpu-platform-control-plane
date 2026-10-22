# Finding 10 after the phase fix, under the registered window: a registration

Written 2026-10-22, before any run.
**DRAFT until the owner commits it; it is frozen from that commit, and no run before it counts.**
Free: a local kind cluster, no rented hardware.
Finding 10's registered table stays as it was measured (`docs/11_WHAT_THIS_MEASURED.md`, Finding 10); this asks what the platform says now.

## Why

The fix of 2026-10-21 makes a distributed job `Running` only when every rank is Ready or has succeeded and at least one is still Ready (`2026-10-21-phase-waits-for-every-rank-design.md`, "The rule").
It was confirmed on one `off` run per scenario at a 300 s window with the squatter deleted at 150 s, which the scorer reported as a rehearsal (the same page, "Confirmation on kind").
Finding 10's own table names what that left open: not under the registered 600 s window, and not with `ready-timeout`.
It also measured a second defect the fix does not touch, the quota coming back 28.9 s before the device in all ten evictions, and said only what the queue counts, not what a second workload meets.

## The question

Under Finding 10's registered harness and window, with only the controller changed, is a half-placed distributed job ever reported `Running`, in either Kueue setting; and when the readiness timeout evicts it, what does a workload waiting on the released quota meet during the gap before the device is free?

## Fixed values

Finding 10's, unchanged (`experiments/distributed-partial-placement/README.md`, "Fixed values"): Kueue v0.18.3; `off` with no `waitForPodsReady`; `ready-timeout` with `timeout: 120s`, `recoveryTimeout: 120s`, `blockAdmission: false`, `backoffBaseSeconds: 30`, `backoffLimitCount: 2`; `worldSize: 2`, one simulated GPU per rank and per worker, two workers; ClusterQueue quota 2; the squatter on the second worker with grace period 0; **window 600 s, `late` deletes the squatter at 300 s**.
The operator is built from the working tree at the commit that freezes this page, which must contain the fix (`943e4b1` or later); the run records that commit and refuses a dirty tree under `internal/` or `cmd/`.

## Runs

The registered eight, in Finding 10's order: `off` never, late, never, late; one configuration change; `ready-timeout` never, late, never, late.
Then two runs of a ninth scenario, **`ready-timeout-witness`**, described below.
Ten runs of 600 s, about 2 h 10 m with isolation waits and the Kueue restart.

### The witness scenario

`ready-timeout`, squatter never deleted, and at creation a second workload, the witness: one Kueue-admitted Job asking for one `nvidia.com/gpu` in the same ClusterQueue, with no node selector, queued behind the two-rank job.
While the job holds both units of quota the witness cannot be admitted; when an eviction releases them, Kueue can admit the witness at once, and its Pod can bind only to the first worker, whose device the evicted rank still holds.
The witness turns "the queue counts a device free that a process still holds" into something a second tenant experiences: admitted, and unplaceable, for as long as the gap lasts.
The witness's container runs `sleep 60` and exits 0, so it holds its unit for about a minute once placed.
It changes the two-rank job's later admissions, because the witness then holds one of two units, so its runs are scored only for M8 and M9 and never pooled with the registered `ready-timeout-never` runs.
Only the first eviction of each witness run is read for M9: two measurements in all, published as a series and not as a rate.

## What is measured

Finding 10's M1 to M8, by the same `analyze.py` at the commit that freezes this page, and one more:
- **M9, the witness's admitted-but-unplaceable time**: from its Workload's `QuotaReserved` turning True to its Pod's `PodScheduled` turning True, with the reason and message of every `PodScheduled=False` in between; and the same Pod's scheduling time against the evicted rank's container `finishedAt`.

## Registered predictions

Read from the code at the fix and from Finding 10's measurements; each can be contradicted, and a contradiction is reported before anything changes.
- **Q1, both settings, every scenario:** while stranded, the CR is never `Running` in any poll or watch event: M1 is 0.0 s in all ten runs.
- **Q2, `off-never`:** `Pending` then `Admitted` with `readyRanks` 1 to the window's end; no `runningObservedAt`; M2 censored at the window's end as before, about 599 s, because the fix changes the report and not the hold.
- **Q3, `off-late`:** one entry into `Running`, within 10 s after the second rank is Ready, after the squatter's deletion at 300 s; `admitToRunningSeconds` at least 300; `Succeeded` inside the window.
- **Q4, `ready-timeout-never`:** Finding 10's P3 holds unchanged (admissions near 0, 150 and 330 s, two `PodsReadyTimeout`, then deactivation), and the CR is never `Running`; `admittedAt` is the first admission's stamp and never moves.
- **Q5, `ready-timeout-late`:** Finding 10's P4 holds, and the only entry into `Running` comes after the admission whose ranks both became Ready.
- **Q6, M8, a repeat and not a blind prediction:** in every stopped attempt the placed rank holds its device 25 to 35 s after the quota's release and exits 137, as Finding 10 measured, because the fix does not touch the trainer's signal handling.
- **Q7, M9:** the witness is admitted within 3 s of each release and stays `PodScheduled=False` with an `nvidia.com/gpu` message until within 3 s after the evicted rank's `finishedAt`; so M9 is within 5 s of that eviction's M8. It is informed by M8 and is marked so.

## Validity, per run

Finding 10's rules unchanged (`2026-10-21-distributed-partial-placement-design.md`, "Validity, per run"), and for the witness runs also: the witness was created before the job's first admission, was never admitted while the job held both units, and its Pod was the only other Pod requesting `nvidia.com/gpu`.
A void run is reported with its reason and its scenario is rerun once.

## Building it

- `hack/distributed-partial-placement.sh`: the `ready-timeout:witness` scenario, the witness manifest under `experiments/distributed-partial-placement/`, and the recorder watching its Workload and Pod.
- `analyze.py`: Q1 to Q7 beside P1 to P6, and M9, each with a fixture test that changes when its one input changes; P1 and P2 are kept and are expected to be contradicted, as in the confirmation, because they describe the old rule.
- The harness's window and `late` time stay at their registered values; a run at any other window is a rehearsal by the scorer's existing rule.

## What each outcome licenses

| outcome | licenses | does not |
|---|---|---|
| Q1 holds in all ten | the fix holds under the registered window and with the readiness timeout: a half-placed two-rank job is not reported `Running` on this harness | more ranks, real devices, other cohorts |
| Q1 fails anywhere | the fix has a path it does not cover, named by the run and the state | anything about the hold, which Q2 and Q4 measure separately |
| Q7 holds | a second tenant admitted into the released quota waited about as long as the evicted process held its device, unplaceable but admitted | that it is unbounded, or that a real GPU's release takes as long |
| Q7 fails | how the witness's wait differs from M8, which is then the finding | — |

## What it does not do

It does not shorten the hold, change the grace period or the trainer's signal handling, or test `blockAdmission: true`; each would be its own treatment.
