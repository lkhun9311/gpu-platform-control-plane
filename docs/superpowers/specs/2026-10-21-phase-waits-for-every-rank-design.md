# A distributed job is Running only when every rank is: design

Status: v1, 2026-10-21, before implementation.

## The defect

Finding 10 (`docs/11_WHAT_THIS_MEASURED.md`) measured a two-rank `MLTrainingJob` with one rank placed and the other unplaceable.
The CR said `Running` for 598.1 s of a 598.1 s window, 0.4 s after the placed rank turned Ready, while that rank sat blocked in `init_process_group` and no training step could run.
`computeMLTJPhase` reports `Running` when `job.Status.Ready > 0`, which Finding 6 chose so that a Pod no node accepted could not count.
For a distributed job one Ready rank is not progress: the ranks rendezvous before the first step, so a job missing any rank does no work at all.
Kueue's own readiness rule, `(*Job).PodsReady`, counted the same job unready the whole time, so the platform and its admission controller disagreed about the same object.

The cost is the one Finding 6 named, now for distributed jobs: `admitToRunningSeconds` is closed on entry into `Running`, so the platform's latency metric for a stranded gang reads about 0.4 s when the true wait was unbounded.

## The rule

For a job with `spec.distributed`, `Running` requires

    ready + succeeded + len(uncountedTerminatedPods.succeeded) >= podsCount
    podsCount = min(parallelism, completions)

which is Kueue v0.18.3's `(*Job).PodsReady` (`pkg/controller/jobs/job/job_controller.go`, `PodsReady` and `podsCount`) transcribed rather than paraphrased.
Transcribing it is the point: the finding was a disagreement between two readings of one Job, and the fix is that there is one reading.
`ready` is still `*job.Status.Ready`, and a nil `Ready` still falls through to `Admitted`, for Finding 6's reason (an unknown is not "running").

Succeeded ranks count because ranks finish at different moments, and the `readyRanks` field already says ranks that finish in seconds may never all be Ready at once.
Without them a job whose rank 0 exited first would drop from `Running` back to `Admitted` for its last seconds.
The uncounted-succeeded term is the Job controller's staging area for Pods it has seen finish and not yet added to `succeeded`; leaving it out would open the same gap for the length of one Job sync.

For a job **without** `spec.distributed`, the rule stays `ready > 0`.
Its Pods are independent workers, and the existing table row "parallel job with one of two pods ready is running" pins that deliberately: one worker running is work happening.
The distinction is made on `spec.distributed`, not on `completionMode: Indexed` or on parallelism, because the spec is what says the Pods depend on each other.

### What else changes as a consequence

- **`admitToRunningSeconds` for a distributed job now ends when the last rank is Ready.**
  That is the moment the gang can start, which is what the field's comment ("how long the tenant waited between having quota and using it") claims to measure.
- **A distributed job can move `Running` → `Admitted`.**
  When a rank stops being Ready (evicted, terminating, deleted) the count falls below `podsCount` and the phase says so.
  The old rule did this too, but only when the last Ready rank went.
  `runningObservedAt` is set once and never overwritten, so the metric is not taken twice; the phase counter counts the re-entry, as it already counts every entry.
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
| distributed, 1 of 2 Ready | Admitted | today's `ready > 0` |
| distributed, 1 Ready + 1 succeeded | Running | dropping `succeeded` |
| distributed, 1 Ready + 1 uncounted succeeded | Running | dropping the uncounted term |
| distributed, parallelism 3, completions 2, 2 Ready | Running | using parallelism instead of the minimum |
| distributed, 2 of 2 active, Ready nil | Admitted | reading Active when Ready is unknown |
| non-distributed, parallelism 2, 1 of 2 Ready | Running | applying the gang rule to independent workers |

`computeMLTJPhase` takes whether the job is distributed as an argument, so the table drives both branches without building a full `MLTrainingJob`.
The envtest "keeps following an existing Job after its Service is replaced by a foreign one" currently sets 1 of 2 Ready and expects `Running`, which is the defect.
It is changed to 2 of 2, because its subject is the Service conflict, and a new envtest asserts the reconciler path end to end: 1 of 2 Ready gives `Admitted` with `readyRanks` 1 and no `runningObservedAt`; 2 of 2 then gives `Running`.

Each new row is mutated against the implementation to show it fails: revert to `ready > 0`; drop `succeeded`; drop the uncounted term; use parallelism; apply the rule regardless of `spec.distributed`.

## Confirmation on kind

Finding 10's harness (`hack/distributed-partial-placement.sh`) builds the operator from the working tree, so it measures the fix with nothing changed but the controller.
One `off:never` and one `off:late` run, at `WINDOW=300 LATE_AT=150`, which the scorer reports as a rehearsal: this confirms a rule, it is not a new study, and its numbers are not compared with the registered ones.

What it must show, read from the MLTrainingJob watch stream:

- `off:never`: the CR is never `Running`; it is `Admitted` from admission to the window's end, with `readyRanks` 1.
- `off:late`: `Admitted` until the second rank is Ready after the squatter's deletion, then `Running`, then `Succeeded`; `admitToRunningSeconds` is about 150 s, not under 1 s.

The scorer's P1 and P2 were registered for the old rule and are expected to fail; the run is read for the two statements above, not scored against them.

## Documents

Finding 10's last paragraph says the fix "has not been made"; it is changed to name this change and the confirmation run.
Finding 6's text describes the `Ready > 0` rule as the current one and gets a sentence saying distributed jobs now need every rank.
