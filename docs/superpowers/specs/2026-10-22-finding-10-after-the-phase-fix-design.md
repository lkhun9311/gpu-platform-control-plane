# Finding 10 after the phase fix, under the registered window: a registration

Written 2026-10-22, before any run.
**Registered 2026-10-23 by the owner's approval; frozen from the commit that adds this line, and no run before it counts.**
The draft of 2026-10-22 predicted Finding 10's 28.9 s hold would repeat; the trainer's fix of the same day (`fe5ccfc1`, #382) changed that before anything ran, so Q6, Q7 and the question were rewritten for it before this page was frozen.
Free: a local kind cluster, no rented hardware.
Finding 10's registered table stays as it was measured (`docs/11_WHAT_THIS_MEASURED.md`, Finding 10); this asks what the platform says now.

## Why

The fix of 2026-10-21 makes a distributed job `Running` only when every rank is Ready or has succeeded and at least one is still Ready (`2026-10-21-phase-waits-for-every-rank-design.md`, "The rule").
It was confirmed on one `off` run per scenario at a 300 s window with the squatter deleted at 150 s, which the scorer reported as a rehearsal (the same page, "Confirmation on kind").
Finding 10's own table names what that left open: not under the registered 600 s window, and not with `ready-timeout`.
It also measured a second defect, the quota coming back 28.9 s before the device in all ten evictions, and said only what the queue counts, not what a second workload meets.
That one was the trainer's: blocked in `init_process_group`, the rank could not run its Python SIGTERM handler, and the kubelet killed it at the 30 s grace period.
The trainer now waits for rendezvous on a worker thread and lets its main thread act on the signal (`fe5ccfc1`), and its unit test stops a rank blocked that way within 5 s with exit 143; it has not run on a cluster.

## The question

Under Finding 10's registered harness and window, with the controller's phase fix and the trainer's signal fix both in place, is a half-placed distributed job ever reported `Running`, in either Kueue setting; when the readiness timeout evicts it, how long does the placed rank now hold its device after the quota is released; and what does a workload waiting on that quota meet?
The two fixes are not separated: this asks what the platform says now, not which change made the difference.

## Fixed values

Finding 10's, unchanged (`experiments/distributed-partial-placement/README.md`, "Fixed values"): Kueue v0.18.3; `off` with no `waitForPodsReady`; `ready-timeout` with `timeout: 120s`, `recoveryTimeout: 120s`, `blockAdmission: false`, `backoffBaseSeconds: 30`, `backoffLimitCount: 2`; `worldSize: 2`, one simulated GPU per rank and per worker, two workers; ClusterQueue quota 2; the squatter on the second worker with grace period 0; **window 600 s, `late` deletes the squatter at 300 s**.
The operator and the trainer image are built from the working tree at the commit that freezes this page, which must contain both fixes (`943e4b1` and `fe5ccfc1`); the run records that commit and the trainer's `train.py` hash, and refuses a dirty tree under `internal/` or `cmd/`.

## Runs

The registered eight, in Finding 10's order: `off` never, late, never, late; one configuration change; `ready-timeout` never, late, never, late.
Then two runs of a ninth scenario, **`ready-timeout-witness`**, described below.
Ten runs of 600 s, about 2 h 10 m with isolation waits and the Kueue restart.

### The witness scenario

`ready-timeout`, squatter never deleted, and a second workload, the witness: one Kueue-admitted Job asking for one `nvidia.com/gpu` in the same ClusterQueue, with no node selector, created as soon as the two-rank job's Workload is first seen with `QuotaReserved=True`, so it queues behind a job already holding both units.
It is not created with the job, because the operator creates the job's Workload a few seconds after the CR, and a witness admitted first would hold one of two units and leave the two-rank job unadmittable.
While the job holds both units of quota the witness cannot be admitted; when an eviction releases them, Kueue can admit the witness at once, and its Pod can bind only to the first worker, whose device the evicted rank holds until its Pod is gone.
The witness turns "the queue counts a device free that a process still holds" into something a second tenant experiences: admitted, and unplaceable, for as long as the gap lasts, and under Q6 that gap should now be a few seconds at most.
The witness's container runs `sleep 60` and exits 0, so it holds its unit for about a minute once placed.
It changes the two-rank job's later admissions, because the witness then holds one of two units, so its runs are scored only for M8 and M9 and never pooled with the registered `ready-timeout-never` runs.
Only the first eviction of each witness run is read for M9: two measurements in all, published as a series and not as a rate.

## What is measured

Finding 10's M1 to M8, by the same `analyze.py` at the commit that freezes this page, and one more:
- **M9, the witness's admitted-but-unplaceable time**: from its Workload's `QuotaReserved` turning True to its Pod's `PodScheduled` turning True, with the reason and message of every `PodScheduled=False` in between; and the same Pod's scheduling time against the evicted rank's container `finishedAt`.

## Registered predictions

Read from the code at the fix and from Finding 10's measurements; each can be contradicted, and a contradiction is reported before anything changes.
- **Q1, both settings, every scenario:** while stranded, the CR is never `Running` in any poll or watch event: M1 is 0.0 s in all ten runs.
  It is read unrounded and after every single watch event, not only from the integrated time; a state seen only where two streams' events share a millisecond, whose order the recorder cannot know, is reported not evaluable rather than either way.
- **Q2, `off-never`:** `Pending` then `Admitted` with `readyRanks` 1 to the window's end; no `runningObservedAt`; M2 censored at the window's end as before, about 599 s, because the fix changes the report and not the hold.
- **Q3, `off-late`:** one entry into `Running`, within 10 s after the second rank is Ready, after the squatter's deletion at 300 s; `admitToRunningSeconds` at least 300; `Succeeded` inside the window.
- **Q4, `ready-timeout-never`:** Finding 10's P3 holds unchanged (admissions near 0, 150 and 330 s, two `PodsReadyTimeout`, then deactivation), and the CR is never `Running`; `admittedAt` is the first admission's stamp and never moves.
- **Q5, `ready-timeout-late`:** Finding 10's P4 holds, and the only entry into `Running` comes after the admission whose ranks both became Ready.
- **Q6, M8, informed and not blind:** in every stopped attempt the placed rank's container ends with exit 143, not 137, and M8 is from −3 to 5 s, uncensored.
  Finding 10's 28.9 s against a 30 s grace period puts the SIGTERM about 1.1 s before the recorded release, and the unit test stops the rank within 5 s of it, so M8 can be negative: the device freed before the queue said so.
  Exit 137 anywhere, or M8 over 5 s, contradicts it and is reported before anything changes.
- **Q7, M9:** in both witness runs the witness is admitted within 3 s of the first release, M9 is at most 5 s, and its Pod's `PodScheduled=True` is not earlier than the evicted rank's `finishedAt`, which the API gives in whole seconds against the recorder's milliseconds, so up to 1 s earlier is read as the same instant. It is informed by Q6 and is marked so.
  A finished witness Workload can keep `QuotaReserved=True`, so the validity rule below counts `Finished=True` as released.

## Validity, per run

Finding 10's rules unchanged (`2026-10-21-distributed-partial-placement-design.md`, "Validity, per run"), and for the witness runs also: the witness was created after the job's first reservation and before its first `Evicted`, was never admitted while the job held both units, and its Pod was the only other Pod requesting `nvidia.com/gpu`.
A void run is reported with its reason and its scenario is rerun once.

## Building it

- `hack/distributed-partial-placement.sh`: the `ready-timeout:witness` scenario, the witness manifest under `experiments/distributed-partial-placement/`, and the recorder watching its Workload and Pod.
- `analyze.py`: Q1 to Q7 beside P1 to P6, and M9, each with a fixture test that changes when its one input changes; P1 and P2 are kept and are expected to be contradicted, as in the confirmation, because they describe the old rule, and so is P6, because it describes the old trainer.
- The harness's window and `late` time stay at their registered values; a run at any other window is a rehearsal by the scorer's existing rule.
- Before this page is frozen, a rehearsal of one witness run at a short window, reported as a rehearsal, shows the witness Job is admitted by Kueue, is not refused by the platform's webhooks, and is read by `analyze.py`.
  It ran on 2026-10-23 at `8b139ede` with a 200 s window, not counted: valid by every rule, the witness created 1 s after the job's reservation, the evicted rank exiting 143 with M8 −1.1 s, the witness reserving 1.0 s after the release and scheduled 0.04 s after that, never unschedulable.
  Those are one rehearsal's numbers and are not the study's; Q6's range was written before it, from Finding 10's 28.9 s against the 30 s grace period, and was not changed after it.

## What each outcome licenses

| outcome | licenses | does not |
|---|---|---|
| Q1 holds in all ten | the fix holds under the registered window and with the readiness timeout: a half-placed two-rank job is not reported `Running` on this harness | more ranks, real devices, other cohorts |
| Q1 fails anywhere | the fix has a path it does not cover, named by the run and the state | anything about the hold, which Q2 and Q4 measure separately |
| Q6 holds | on this harness the evicted rank now stops on SIGTERM, and the quota and the device come back within seconds of each other | that a real GPU or another trainer releases as fast |
| Q6 fails | the signal fix does not hold on a cluster, named by the attempt, its exit code and M8 | — |
| Q7 holds | a second tenant admitted into the released quota met no gap longer than 5 s | that it is never longer, with two measurements |
| Q7 fails | how the witness's wait differs from M8, which is then the finding | — |

## What it does not do

It does not change the grace period, separate the two fixes' effects, or test `blockAdmission: true`; each would be its own treatment.
