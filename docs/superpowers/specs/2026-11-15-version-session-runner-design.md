# The version study's session runner (#607, #597)

The version study ([registration](2026-11-15-vllm-version-async-study-design.md)) has every piece but the one that runs them in order on one instance:
- the sender (#593);
- the trace, bundle and manifest writers (#604);
- the calibration runner (#605);
- the ledger and campaign check (#588).

This page designs that runner and the watchdog that bounds it.
It is written before the code and attacked before it is built, as the registration was.

## What it is

Two parts, so that everything that decides a measurement is Go code tested against stubs, and the shell only launches.

| Part | Runs where | Does |
|---|---|---|
| `benchharness version-session` | on the instance | the whole campaign below, against an `Engines` interface |
| a launcher, hack/version-session.sh (planned) | on the operator's machine | launch one g5.xlarge (`hack/lib/spot-run.sh`), arm the watchdog, collect evidence, terminate |

`Engines` has two implementations:
- **docker:** `docker run --gpus all` with the controller's rendered arguments. This is the paid path.
- **stub:** `benchharness stub-serve` as a subprocess. This is the free rehearsal, #595.

The orchestrator never knows which one it drives, so the rehearsal runs the same code paths as the paid run.

## Order of a session

Every step writes its evidence before the next starts. Every step has the bound `PhaseBounds` registers.

1. **Setup checks** (inside the 2,700 s setup bound):
   - the GPU is an A10G;
   - both engine images are present locally at their pinned digests;
   - the model and tokenizer revision are in the cache;
   - the campaign directory is empty and reserved;
   - the deadline file the launcher wrote is readable.
2. **Preflight, per treatment, in the order A, B, C** (900 s each):
   - Start the engine and wait for readiness: `/health` returns 200, then one priming request per input × output class.
   - Compare its runtime identity to the registration (`CampaignBundle.CompareRuntime` needs the bundle, so preflight records the identity and the bundle step compares it).
   - Send 30 requests from a preflight trace, each held to `ClassifyRow`.
   - Stop the engine.
   - Any failure stops the session, because a treatment that cannot pass preflight cannot be compared. Each image's compile cache is populated here and never cleared.
3. **Calibration on A** with `RungRunner` (bounded by `CalibrationRule.MaxSeconds`). An unresolved ladder stops the session with the artifact written.
4. **Bundle** (`WriteCampaignBundle`). The price is read from the AWS Price List API at this point, with its source and time recorded. Then `MayStartBlock` runs for all six planned blocks, and refusal stops the session.
5. **Blocks**, in ledger order: planned 1 to 6, then replacements for invalid ones while the budget allows. Each block runs as follows:
   - `MayStartBlock` with spending so far and the valid blocks still needed. Refusal ends the campaign as an incomplete pilot.
   - Write the block's six manifests (`VersionCellManifest`) before any of its cells runs.
   - For each treatment in `ArmOrder`:
     - start a fresh engine;
     - check readiness (600 s);
     - compare runtime identity against the bundle;
     - for each load in `LoadOrder`, run the cell, then verify the drain;
     - stop the engine.

     An engine that misses readiness is unavailable for that visit. Its cells are written with every row `engine-unavailable`, which is an outcome and not invalidity.
   - A cell is one replay of its trace with the registered sampling and recorded timing:
     - the drain ends when the engine's own gauges read zero, within 120 s;
     - if they do not, the engine is restarted before the next load, and the restart is recorded.
   - Classify the block from its cells by the invalidation rules. The rules never look at endpoint values.
   - Append the attempt to the ledger with its reason and times, before the next block.
6. **Close:** archive the ledger, run `CheckVersionCampaign`, write the campaign summary, stop. The verdict is computed offline from the archived evidence, not on the instance.

Stop rules end the campaign as an incomplete pilot:
- the budget check refuses;
- the deadline is close;
- lag invalidates the same treatment in two blocks;
- a recorder error occurs.

## Invalidation, as the runner applies it

These are the registration's rules, applied per cell:
- **Accounting:** `ReconcileRecording` against the trace, and P against the bundle's measured rows.
- **Dispatch lag:** transport write − intended arrival, p99 over P above 10 ms or maximum above 100 ms.
- **Protocol:** `ClassifyRow` over every row.
- **Identity:** `LoadManifest` refuses the manifest, or `CompareRuntime` refuses the running engine.
- **Recorder:** any write or durability error.
- **External cause:** the instance's own event log. The runner records the log; deciding the cause stays a human step, with the log as the only evidence.

One invalid cell invalidates its block.

## The watchdog (#597)

The registered absolute teardown deadline is `TeardownDeadlineSeconds(rate)` after launch, whatever phase is running. Three independent layers enforce it, and each one alone ends the billing:

| Layer | Survives | Mechanism |
|---|---|---|
| on the instance | the operator's machine sleeping or losing credentials | user-data starts `( sleep <launch + deadline − now>; shutdown -h now ) &` before anything else, and the instance is launched with instance-initiated shutdown behaviour terminate. This is the pattern of `hack/gpu-fault-session.sh` |
| in the orchestrator | a phase overrunning its bound | before each phase and each cell, the orchestrator compares the time left with that step's bound plus teardown. If it does not fit, the campaign stops as incomplete and the orchestrator exits, so the evidence upload runs within the deadline |
| on the operator's machine | the instance hanging before its own shutdown | the launcher's EXIT trap calls `spot_terminate`, and a polling loop terminates at the deadline plus a margin |

The release gate requires showing the first layer works:
- the rehearsal launches nothing paid;
- a t3 instance run (cents) with a short deadline shows the instance terminating itself while the orchestrator is busy;
- the test harness checks the user-data renders the backstop before any other step.

## What the rehearsal (#595) proves

Run with the stub engines through `benchharness version-session`, against stubs that honour the sampling fields and report the registered prompt counts:
- Two blocks, so the campaign must end as an incomplete pilot.
- Injected failures, each landing where the rules say:
  - an HTTP 500;
  - a broken stream;
  - a timeout;
  - an engine that never becomes ready;
  - a nonconforming completion;
  - a drain that does not end.
- Every file the paid run writes is written and loads: manifests, rows, ledger, bundle, calibration.

## The attack, and what it changed (2026-11-15)

codex `gpt-6-astra` attacked this page before any code existed. The full text is in the storage repository at `gpu-platform-control-plane/issues/open/2026-11-15-version-session-runner-attack-codex-astra.md`. Its verdict: not buildable as designed. I re-checked its central claims in the code:
- `CompareRuntime` compares an observed hash with the review file's hash;
- the worst case is 55,680 s at W = 300, which is $19.13 compute and $21.13 with the reserve at the recorded $1.237/h;
- `spot_launch` already requires a `study-deadline` tag that the existing sweeper enforces.

Each change below is a GitHub issue, and this page stays the plan until they are done.

| Change | Issue |
|---|---|
| Separate the reviewed-flags hash from the observed arguments, and check identity before calibration | #608 |
| A pure exported vLLM argument renderer shared by the controller and a docker engine adapter (`/dev/shm` 1 GiB, a persistent per-image compile cache, the start record) | #609 |
| A context and a bound on every step: calibration (with its own start of A), the replay recorder, docker operations, uploads | #610 |
| The drain timed from the last scheduled arrival; a drain restart is a full start | #611 |
| A durable attempt-start record and recovery, and the external-cause rule | #612 |
| Raw and study dispositions mapped; engine-unavailable rows written; dispatch lag as transport write − intended arrival | #613 |
| Durable evidence: fsync, checkpoints, periodic upload; separate result, recovery and termination status | #614 |
| The offline evaluator: endpoints from intended arrival with failures at +∞, the exact bootstrap, the verdict; the GPU and output-digest diagnostics | #615 |
| A purchase gate on a fitting worst case, the price read before launch, and the deadline enforced on AWS (one time contract) | #616, replacing #597 |
| A conforming stub with a capacity model, and a full six-block rehearsal with failure injection | #617, the scope of #595 |

The attack's answers to this page's open questions, adopted:
- **Preflight before calibration.** Identity is checked at once rather than deferred to the bundle, and calibration starts A again with its own time accounted.
- **Drain restarts.** A restart after a drain overrun is a full start, then readiness, then identity, then warm-up. It stays non-invalidating, as registered, and is reported with its cause, duration and place.
- **The orchestrator's checks are not enough.** An AWS-side enforcer is required. The existing `study-deadline` sweeper qualifies if it is verified before purchase. It must also cover a launch whose response was lost.

**External cause (owner decision, 2026-11-15):** an automatic predicate over AWS's own records for the instance. These are scheduled events, failed system status checks and spot interruption notices within the block. The registration's invalidation rule 6 is amended with it.

**No paid campaign can start yet.** The worst case does not fit the cap at the registered bounds. The readiness bound can be narrowed only by the paid measurement (#594), not by a stub, followed by an amendment (#616).
