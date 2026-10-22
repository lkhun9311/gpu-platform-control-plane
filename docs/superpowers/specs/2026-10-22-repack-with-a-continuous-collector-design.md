# The repack arm again, with a collector the intervention cannot pause: a registration

Written 2026-10-22, before any trial.
**DRAFT until the owner commits it together with the collector change; frozen from that commit, and no trial before it counts.**
Free: a local kind cluster, no rented hardware.
The fragmentation study's 25 trials stand as published, R's five included as evidence that breached the gap rule (`experiments/fragmentation/README.md`, "R: repacking fixed it without adding anything").

## Why

The pre-registration invalidates a trial on any collection gap over 5 s (`2026-09-24-node-level-gpu-fragmentation.md`, "Invalidation").
In all five R trials the sampler shared a loop with the intervention, so it paused while the replica was created and waited for, and each timeline has a 13.57 to 13.63 s hole; the middle state, one device free with demand preserved, was seen only by a point check in the run log.
So by the study's own rule R has no valid trial, and the repack claim travels with that caveat (Finding 6's last paragraph).

## What changed in the harness, uncommitted, for the owner to review

`hack/fragmentation.sh`:
- The 1 s sampler is `collect_timeline`, run as its own background process for the whole window; the foreground waits for it rather than sampling.
- R's intervention runs in the foreground at `REPACK_AT` seconds (default 60, the registered value). For R a marker file the collector honours exists from the trial's start until the deadline has been extended, so neither a short window nor a slow intervention can end the sampling first; the deadline moves by the intervention's duration plus `REPACK_WATCH` seconds (default 60), and never to less than `REPACK_WATCH` after the deletion, through a file the collector rereads.
- An exit trap stops and reaps a running collector, so a foreground that fails under `set -e` or is interrupted mid-intervention does not leave it sampling.
- The intervention's steps are written to `events-<trial>.jsonl` against the timeline's clock: `repack-start`, `replica-running`, `original-delete`.
- `judge_timeline` adds `gap_rule=ok|INVALID`; `coverage=ok|INVALID|unknown`, which holds the window's two edges to the same 5 s against a `window-end` event the foreground writes when the collector has finished; and, for R, `middle_state_samples`, the timeline's own samples with one device free between `replica-running` and `original-delete`.
- A collector that exits early makes the trial `INVALID collector-failed`, its errors kept in `collector-<trial>.log`; an abandoned trial stops its collector first.
- The script can be sourced without running, so a test can replace its cluster calls.

`hack/test/check-fragmentation-collector.sh`, in `make harness-check`, runs a stubbed R trial whose replica takes 7 s to run and checks: no gap over 5 s, at least 5 middle-state samples, the target ends scheduled, the stubbed deletion happened, the timeline runs past it; a stubbed collector death is invalid and logged; and the judgement calls a 13.6 s gap invalid and exactly 5 s within the rule.
It also runs R with a 1 s window, which must still sample past the deletion, and R with a failing deletion, after which the timeline must stop growing.
It passed (max gap 1.03 s, 10 middle-state samples).
Each fix was shown to be what the test pins: with the collector stopped by `kill -STOP` for the intervention, the shape of the old defect, two checks failed with a 17.12 s gap and 0 middle-state samples; without the marker from the start, four failed, the timeline ending at 3.12 s against a deletion at 19.19 s; without the exit trap's reaping, the timeline grew from 19 to 22 samples after the foreground died.
The last two were found by a bare `codex review --uncommitted` (codex `gpt-6-astra`, read-only), which reported both as P2; I wrote the fixes and the cases.
The mutation with no marker also kept `gap_rule=ok` on a timeline that stopped at 3 s, so the gap rule alone does not show a collection that ended early; that is why `coverage` was added, and a judgement case with a timeline stopping 18 s early fails it, and passes when the coverage check is replaced by `True`.

## Trials

Ten, alternating so that neither arm owns the start or the end of the session: R, F, F, R, R, F, F, R, R, F, each `hack/fragmentation.sh trial <arm> <n>` into one `EXDIR` after `hack/fragmentation.sh fixture`.
- **R**, the repack arm exactly as registered: holders on both workers, quota 5, the replica on the second worker before the original on the first is deleted, at 60 s.
- **F**, the fragmented arm with no intervention, as the same session's control: what R's target would have done without the repack.

## What is read, and the bars

The original bars for R, unchanged: every trial in the `(1,0)` middle state, then **the same Pod UID** scheduled within 60 s of the original holder's deletion (`2026-09-24-node-level-gpu-fragmentation.md`, the bar table).
Now also from the timeline itself, not the run log:
- `gap_rule=ok` and `coverage=ok` in every trial of both arms;
- for R, `middle_state_samples` at least 5, since the replica is Running for the 10 s before the deletion;
- for F, `fragmentation` to the window's end with the target never scheduled.

**A prediction the code makes since the trials last ran:** Finding 6's fix reads `job.Status.Ready`, so in F and in R's stranded stretch the CR should say `Admitted`, not `Running`; `cr_running_while_unscheduled` is predicted 0 in all ten trials, where it was 145 samples in each F trial before the fix.
That is a re-confirmation of Finding 6's fix on its own harness, and a contradiction is reported as one.

## Readings

- **R passes** when all five R trials meet the bars with `gap_rule=ok` and the middle state observed; that replaces the caveat on the repack claim with five valid trials.
- **R invalid again** when any trial breaks the gap rule or lacks middle-state samples, with its timeline; then the collector, not the cluster, is what to fix.
- **R fails** when a valid trial's target is not the same Pod or is not scheduled within 60 s.
Invalidation as registered: a trial invalidated is rerun once at the end, and a second invalidation of the same arm ends the redo as inconclusive.

## What it does not say

The same as the original: a `pause` container moved by hand on simulated devices, not live training, real GPUs or automatic repacking.
