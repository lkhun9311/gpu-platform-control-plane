# A distributed job is Running only when every rank is: design

Status: v2, 2026-10-21. v1 was reviewed adversarially before its confirmation run; the review is at the end, and the rule below is the corrected one.

## The defect

Finding 10 (`docs/11_WHAT_THIS_MEASURED.md`) measured a two-rank `MLTrainingJob` with one rank placed and the other unplaceable.
The CR said `Running` for 598.1 s of a 598.1 s window, 0.4 s after the placed rank turned Ready, while that rank sat blocked in `init_process_group` and no training step could run.
`computeMLTJPhase` reports `Running` when `job.Status.Ready > 0`, which Finding 6 chose so that a Pod no node accepted could not count.
For a distributed job one Ready rank is not progress: the ranks rendezvous before the first step, so a job missing any rank does no work at all.
Kueue's own readiness rule, `(*Job).PodsReady`, counted the same job unready the whole time, so the platform and its admission controller disagreed about the same object.

The cost is the one Finding 6 named, now for distributed jobs: `admitToRunningSeconds` is closed on entry into `Running`, so the platform's latency metric for a stranded gang reads about 0.4 s when the true wait was unbounded.

## The rule

For a job with `spec.distributed`, `Running` requires both

    ready >= 1
    ready + succeeded + len(uncountedTerminatedPods.succeeded) >= min(parallelism, completions)

The second line is Kueue v0.18.3's `(*Job).PodsReady` with its `podsCount` (`pkg/controller/jobs/job/job_controller.go`), so the platform and Kueue count a Job's ranks the same way.
The first line is not Kueue's, and the difference is deliberate.
Kueue asks whether the ranks came up, and every rank having succeeded answers yes; this phase says what is happening now.
A nil `Ready` is not `Running`, for Finding 6's reason (an unknown is not "running"); Kueue reads it as zero and would still count successes.

Succeeded ranks count because ranks finish at different moments, and the `readyRanks` field already says ranks that finish in seconds may never all be Ready at once.
Without them a job whose rank 0 exited first would drop from `Running` to `Admitted` while its other rank was still working.
The uncounted-succeeded term is the Job controller's staging area for Pods it has seen finish and not yet added to `succeeded`.

`ready >= 1` is what keeps a finishing job from entering `Running`.
Every finishing run in Finding 10's evidence passes through `ready 2`, then `ready 0, succeeded 0` for 1.007 to 1.012 s while the containers exit, then `ready 0, succeeded 2` with `SuccessCriteriaMet` and no `Complete` for 21 to 28 ms, then `Complete` (times between the watch events' arrivals).
Without the first line that third state would be `Running`, so a finishing job would re-enter `Running` at its end, and a controller that never saw the ranks Ready would record the end as the start.
`SuccessCriteriaMet` is not taken as completion here, for the reason `internal/queuelab/provenance.go` gives: it is set before every Pod has terminated.

For a job **without** `spec.distributed`, the rule stays `ready > 0`.
Its Pods are independent workers, and the existing table row "parallel job with one of two pods ready is running" pins that deliberately: one worker running is work happening.
The distinction is made on `spec.distributed`, not on `completionMode: Indexed` or on parallelism, because the spec is what says the Pods depend on each other.

### What else changes as a consequence

- **`admitToRunningSeconds` for a distributed job now ends when this controller first sees every rank Ready, with one still Ready.**
  That is the moment the gang can start, which is what the field's comment ("how long the tenant waited between having quota and using it") claims to measure.
  `runningObservedAt`'s published description (the Go comment and the generated CRD) is changed to say so.
- **A distributed job moves `Running` → `Admitted` when a rank stops being Ready** (evicted, terminating, deleted), and for the about 1 s its ranks take to exit at the end (1.032 to 1.040 s from `ready 0` to `Complete` in Finding 10's records).
  The old rule did the second too, from the same `ready 0` state; it did the first only when the last Ready rank went.
  `runningObservedAt` is written once, so the metric is not taken twice; the phase counter counts the re-entry into `Admitted`, as it already counts every entry.
- **Jobs already stamped keep their stamp.**
  A distributed job that entered `Running` under the old rule has `runningObservedAt` and `admitToRunningSeconds` from its first Ready rank, and histogram observations already emitted stay emitted.
  After the upgrade such a job reads `Admitted` until its gang is complete, with the old stamp beside it; only jobs that reach `Running` after the upgrade carry the new meaning.
- **The `Admitted` condition reason is unchanged** (`QuotaReserved`).
  `status.readyRanks` already shows how many ranks are Ready, so a second spelling of "waiting for ranks" would be a copy to keep in step.

### Not in scope

- `admittedAt` is the first admission's stamp and is never reset, so across Kueue re-admissions (Finding 10's `ready-timeout` setting) the interval spans every attempt.
  That is a separate question about what the metric should mean under eviction, and this change neither fixes nor worsens it.
- Gang placement. This makes the report honest; it does not stop a half-placed job holding quota.
  Kueue's `waitForPodsReady` bounds that hold, as Finding 10 measured.

## Tests

The table in `mltrainingjob_phase_test.go` gains rows, each one there to reject a specific wrong rule:

| row | phase | rejects |
|---|---|---|
| distributed, 2 of 2 Ready | Running | a rule that never reports Running |
| distributed, 1 of 2 Ready | Admitted | the old `ready > 0` |
| distributed, 1 Ready + 1 succeeded | Running | dropping `succeeded` |
| distributed, 1 Ready + 1 uncounted succeeded | Running | dropping the uncounted term |
| distributed, parallelism 3, completions 2, 2 Ready | Running | using parallelism instead of the minimum |
| distributed, 2 of 3 Ready | Admitted | comparing against a constant 2 |
| distributed, 3 of 3 Ready | Running | comparing against a constant 2 |
| distributed, 0 Ready + 2 succeeded, no `Complete` | Admitted | dropping `ready >= 1` |
| distributed, Ready nil + 2 succeeded | Admitted | reading a nil Ready as zero, as Kueue does |
| distributed, 2 of 2 active, Ready nil | Admitted | reading Active when Ready is unknown |
| non-distributed, parallelism 2, 1 of 2 Ready | Running | applying the gang rule to independent workers |

`computeMLTJPhase` takes whether the job is distributed as an argument, so the table drives both branches without building a full `MLTrainingJob`.
The envtest "keeps following an existing Job after its Service is replaced by a foreign one" set 1 of 2 Ready and expected `Running`, which is the defect; it now sets 2 of 2, because its subject is the Service conflict.
A new envtest asserts the reconciler path end to end: 1 of 2 Ready gives `Admitted` with `readyRanks` 1, `admittedAt` set and no `runningObservedAt` or `admitToRunningSeconds`; 2 of 2 then gives `Running` with both.

Each new row and the envtest are mutated against the implementation to show they fail: revert to `ready > 0`; drop `succeeded`; drop the uncounted term; use parallelism; compare against 2; drop `ready >= 1`; apply the rule regardless of `spec.distributed`; pass `false` from the reconciler.

## Confirmation on kind

Finding 10's harness (`hack/distributed-partial-placement.sh`) builds the operator from the working tree, so it measures the fix with nothing changed but the controller.
One `off:never` and one `off:late` run, at `WINDOW=300 LATE_AT=150`, which the scorer reports as a rehearsal: this confirms a rule, it is not a new study, and its numbers are not compared with the registered ones.

What it must show, read from the MLTrainingJob watch stream:

- `off:never`: the CR is never `Running`; it is `Admitted` from admission to the window's end, with `readyRanks` 1, and has no `runningObservedAt`.
- `off:late`: `Admitted` until the second rank is Ready after the squatter's deletion, then `Running`, then `Admitted` for no more than the seconds its ranks take to exit, then `Succeeded`, with exactly one entry into `Running`; `admitToRunningSeconds` is about 150 s, not under 1 s.

The scorer's P1 and P2 were registered for the old rule and are expected to fail; the run is read for the two statements above, not scored against them.

## Documents

Finding 10's last paragraph says the fix "has not been made"; it is changed to name this change and the confirmation run.
Finding 6's text describes the `Ready > 0` rule as the current one and gets a sentence saying distributed jobs now need every rank.

## Review of v1

codex `gpt-6-astra`, high effort, asked to show the design wrong. Each finding was checked against the code or the recorded evidence before it was acted on.

| finding | severity | checked | v2 |
|---|---|---|---|
| `ready 0, succeeded 2` without `Complete` is a real state, and v1 called it `Running` | high | yes: all four finishing runs in `hack/distributed-partial-placement-20261021T065335Z/`, Job watch | `ready >= 1` |
| so v1's finishing job reads `Running → Admitted → Running → Succeeded`, against the confirmation it registered | medium | yes, same records | the same line; the confirmation now states the exit dip |
| every distributed row had two ranks, so a constant 2 passed all of them | medium | yes | 2-of-3 and 3-of-3 rows |
| jobs stamped before the upgrade keep the old latency | medium | yes: `runningObservedAt` is written once (`admit_to_running.go`) | stated under consequences and in the field's description |
| "transcribed" was false for a nil Ready, which Kueue reads as zero | low | yes: `job_controller.go`, v0.18.3 and v0.20.1 | claim withdrawn, difference stated, row added |
| `runningObservedAt`'s published description still said "a ready Pod" | low | yes: `api/v1/mltrainingjob_types.go`, the generated CRD | description changed, CRD regenerated |
