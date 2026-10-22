# Can the archives say which stage of the admission ladder is reachable? A feasibility memo (stage A1)

Written 2026-10-22 · Free computation on archives already collected.
**No card is bought by this page, and no past verdict changes.**
It is the first stage of the staged successor the owner asked for; the registration it feeds is `2026-10-22-staged-admission-targets-design.md`, a draft.

## The question

The ladder asks how close to isolation the premium tenant's TTFT p99 can be brought on one shared engine, in four stages: T0, no regression against the hold-cap product-path run 3 with zero refusals; T1, at most 3x isolation; T2, at most 2x; T3, at most 1.25x.
Every stage keeps two guard bars against an unshed arm: aggregate throughput at least 95%, and contender work and output share at least 75%.
The lever is the engine's per-request prefill cap (vLLM's `long_prefill_token_threshold`, with the step budget `max_num_batched_tokens` kept at 512) together with the gateway's serial-prefill hold.

Before a registration names caps, can a step-time model per cap be fitted from what is already archived, and does it say which stage is plausibly reachable?

## Why the earlier attempts failed, and whether that transfers

- **The timing-family registration (2026-10-05)** was never a fit that failed on its own terms: its instrument prerequisite did not pass, because the stock iteration timer omits the scheduler's own time and no clock measured a mixed step (`2026-10-05-a-timing-family-fitted-from-the-iteration-log.md`, section 4 and its session-2 amendment).
- **The logged-engine pilot (2026-10-06)** failed under both mixed-step conventions, and the staggered late prefill's TTFT was predicted at 0.45 to 0.98 of what was observed (`2026-10-06-m5b-stays-closed-and-what-a-successor-needs-first.md`, update of 2026-10-06).
- **The step-boundary family and S1** fitted mixed and decode steps, but S1's confirmation failed 12 of 158 endpoints, all short prefill-only steps at the 128/129-token CUDA-graph boundary, past the 256-token knot, and the 32-token bursts (`2026-10-07-confirming-s1-on-unseen-settings.md`; `2026-10-08-is-s1-enough-for-the-feasibility-check.md`).

All three aimed at a general model of the sharing-matrix load, whose step compositions a simulator cannot fix in advance.
A different, narrow model already exists for the pilot load (68-token premiums at 9.25/s, 7,695-token contenders at 0.5/s, budget 512, 64 slots): the replay's five-term linear step model in `hack/prospective-pilot/simulate.py:93`, fitted on pilots A and B.
It predicted the diagnostic's hold-cap tail before purchase (0.27 to 0.36 of off predicted, 0.288 to 0.316 measured) and v27's capped prefill medians within 2% to 3% (`2026-10-08-measuring-prospective-admission-design.md`, "The diagnostic's result" and "v27 calibration's result").
So the earlier failures do not show that a narrow model must fail; they show that request lengths do not fix step compositions, which is the question below.

## What was computed

Everything here is in `data/2026-10-22-staged-admission-feasibility/`, run against the archives that are on disk but never committed, at `/home/lkhun9311/workspace/gpu-platform-control-plane/hack/m5c-*/m5c-run`.
Pilots A and B (`m5c-20261008-235046-pilotA`, `m5c-20261009-013656-pilotB`) exist only there; the diagnostic, v26 and v27's calibration (`-diagD`, `-frontierE`, `-lencalF`) are also in the release `evidence-admission-2026-10-10` under the committed checksums.

1. `coverage.py`: the replay's fit, reproduced, then every step of the three capped sessions predicted out of sample and binned by its largest contender chunk.
2. `verify_codex.py`: which contender chunk sizes the five sessions contain, at which context depth, and each tenant's share of the tokens the engine processed in the diagnostic's off cells.
3. `ladder.py`: the replay of the diagnostic's three off cells (seeds 851 to 853) under the hold with caps 512 (no cap), 384, 256, 192, 128, 96 and 72, and cap alone beside it, at step paces 1.00, 1.03 and 1.10, with the ladder's guard bars on the window ending at each trace's last scheduled instant.

### The fit reproduces

282,897 steps and coefficients `[15.3639, 0.0966, 0.0959, 0.9292, 3.0468]` ms: intercept, per prefill token, per scheduled request, per thousand tokens of context, per million of prefill-attention work (`coverage.txt:1`).
codex `gpt-6-astra`, working independently, reached the same 282,897 and the same coefficients (`astra-a1.txt`).

### Where it is good, out of sample

Held-out steps of the diagnostic, v26 and v27's calibration, measured over predicted, summed per bin (`coverage.txt`):

| largest contender chunk in the step | steps | measured / predicted | line |
|---|---:|---:|---|
| 384 exactly | 94,067 | 1.030 | `coverage.txt:9` |
| 193 to 256 | 798 | 0.997 | `coverage.txt:7` |
| 129 to 192 | 787 | 0.997 | `coverage.txt:6` |
| 65 to 128 | 892 | 1.011 | `coverage.txt:12` |
| 1 to 64, context of 2,000 or more | 3,439 | 1.099 | `coverage.txt:14` |
| any contender chunk, total tokens at most 128 (CUDA-graph captured) | 1,843 | 1.133 | `coverage.txt:30` |

So the model runs about 3% fast on capped steps, which is the 1.0205 to 1.0275 pace the diagnostic's hold-cap cells showed, and 10% to 13% fast on tiny chunks deep in a prompt and on graph-captured steps carrying one.
astra's held-out bias on the capped arms, computed its own way, is −2.07%, −3.30% and −3.58% for the three sessions (`astra-a1.txt`), the same direction and size.

### Where it has no data

The bins above hide what matters for 256 and 128, and astra found it first; I re-derived its table exactly (`verify_codex.txt:1-5`):

| contender chunk | steps | first chunk | interior | final | interior context range |
|---|---:|---:|---:|---:|---|
| 65 to 128 | 6,344 | 743 | 4,654 | 952 | 1 to 2,088 |
| 129 to 256 | 3,104 | 1,105 | 137 | 1,942 | 4 to 1,950 |
| 257 to 384 | 89,771 | 4,614 | 83,564 | 1,593 | 1 to 7,310 |

Every interior chunk of 256 or fewer tokens in the archives sits in a full 512-token step beside a second contender's prefill, at a context below 2,100 tokens (`verify_codex.txt:2-3`).
Deep in a prompt, small chunks appear only as final remainders.
A cap of 256 or 128 makes a single contender take small interior chunks at every depth from the first to about 7,500 tokens, beside premium decodes; that trajectory is not in the archives, and the model interpolates it between shallow interiors and deep remainders.
A cap of 128 does not put those steps under the graph boundary: one decode beside a 128-token chunk is already 129 tokens.

### What the replay predicts for each cap, as a screen

Worst block of the three, at the fitted pace (`ladder-1.0.txt:54-61`), with the 1.03 pace the capped sessions ran at (`ladder-1.03.txt:54-61`) and 10% slower (`ladder-1.1.txt:54-60`):

"Throughput" can mean two things here, and they bind differently (next section), so both are shown: every token the engine processed, prompt and output, or output tokens alone, which is how the price-of-protection safeguards that the guard bars descend from defined it (`2026-09-05-the-price-of-protection.md:209-210`).

The guard bars under the draft's registered definitions, output of successful streams completed inside a 420 s window, the contender's share of it, and its prompt work (`ladder-1.0.txt:70-77`, `ladder-1.03.txt:70-77`, `ladder-1.1.txt:70-77`), with the all-token throughput beside them (`ladder-1.0.txt:54-61`, `ladder-1.03.txt:54-61`, `ladder-1.1.txt:54-60`):

| arm | premium p99 / replayed isolation, 1.00 / 1.03 / 1.10 | aggregate output / off, worst at any pace | contender output share / off's, 1.00 / 1.03 / 1.10 | contender prompt work / off, 1.00 / 1.03 / 1.10 | all-token throughput / off, 1.00 / 1.03 / 1.10 | stage on every block, registered / all-token |
|---|---|---|---|---|---|---|
| hold, 384 (hold-cap) | 6.73 / 6.92 / 9.62 | 0.999 | 0.988 / 0.993 / 0.990 | 0.992 / 0.993 / 0.989 | 0.994 / 0.995 / 0.992 | below T1 everywhere |
| hold, 256 | 2.32 / 2.38 / 2.41 | 0.999 | 0.960 / 0.948 / 0.888 | 0.966 / 0.947 / 0.890 | 0.974 / 0.960 / 0.916 | registered: T1 at all three; all-token: T1, T1, guard fails |
| hold, 192 | 2.02 / 2.05 / 2.08 | 0.993 | 0.866 / 0.844 / 0.793 | 0.873 / 0.847 / 0.794 | 0.902 / 0.883 / 0.842 | registered: T1 at all three, 1% to 4% above 2x; all-token: guard fails |
| hold, 128 | 1.75 / 1.78 / 1.79 | 0.993 | 0.713 / 0.697 / 0.653 | 0.717 / 0.696 / 0.652 | 0.782 / 0.766 / 0.733 | guard fails under both: the contender's share and work below 75% |
| hold, 72 | 1.50 / 1.53 / 1.52 | 0.991 | 0.510 / 0.493 / 0.463 | 0.510 / 0.495 / 0.464 | 0.622 / 0.611 / 0.589 | guard fails under both |

The screen first scored token-level sums inside the window; a bare `codex review --uncommitted` by astra found that those are not the registered quantities, a stream finishing after the window still credited and the contender's output not normalised to a share, and the registered columns were added. They move no stage reading.

The replayed isolation is the same trace's premium rows alone, 66 to 67 ms (`ladder-1.0.txt:6-37`); the diagnostic measured 63.5 ms, so against the measured anchor every ratio above is about 4% higher.
Cap alone, without the hold, is worse than off at every cap (`ladder-1.0.txt`, the `cap-only` rows), as the diagnostic measured at 384.

Per block at 256 and the fitted pace, the contender's completion median is 1.55, 2.54 and 1.66 times off's and its p95 20.2, 23.2 and 11.8 s, with no hold refusal (`ladder-1.0.txt:7,21,35`).
At 1.03, trace 852 has six hold refusals and a p95 of 26.8 s.
Those are Finding 9's contender limits, which the ladder's guard bars do not include; 256 would reach T1 under the ladder's bars and fail Finding 9's median limit on 852.

### Why the guard bar binds where it does, under each definition

In the diagnostic's off cells the contender's tokens were 73.5% to 77.7% of everything the engine processed (`verify_codex.txt:6-8`).
- **All tokens.** With the premium's work unchanged, throughput at least 95% of off's needs contender work at least `1 − 0.05/0.735 = 0.932` of off's, so this bar binds long before the 75% contender bars.
- **Output tokens.** The load's output is premium 9.25/s × 64 against contender 0.5/s × 16, so the contender's output is `8 / (592 + 8) = 1.3%` of it: the aggregate bar cannot see the contender at all, and the two 75% contender bars are the guards that bind. Every hold arm down to a cap of 72 keeps at least 0.991 of off's completed output (`ladder-1.0.txt:70-77`, `ladder-1.1.txt:70-77`).

Which one the owner meant decides whether hold-192 is a guard failure or a ratio 1% to 4% above T2, and it is open decision 4 of the draft registration.

### Why 192 and 128 fail on stability, and why that part does not depend on the unmeasured steps

A serial hold forwards the next contender when the previous one's first token arrives, so its service time is one capped prefill, and at 0.5 contenders a second it keeps up only while that prefill averages under 2 s.
A 7,695-token prompt takes at least 16, 21, 31, 41 and 61 steps at caps 512, 384, 256, 192 and 128.
At 128, the intercept and the per-token term alone give `61 × 15.36 + 7,695 × 0.0966 = 1,680 ms` before any decoder, context or attention term; those two coefficients are the best-supported in the fit.
The replay's whole prefill at 128 is 2,540 to 2,554 ms at p50, and 2,076 to 2,089 ms at 192 (`ladder-1.0.txt:8-9,22-23,36-37`).
The unmeasured interior steps can only add attention cost to that, and the measured bias on small and graph-captured steps runs the same way, slower than predicted.
So at this load the hold at 192 or 128 builds a queue for the whole 420 s cell, whatever the uncovered terms turn out to be.
At 128 the queue costs more than a quarter of the contender's work on one trace, which fails the 75% bar under either definition; at 192 it costs 13% at the fitted pace, which fails only the all-token throughput bar.

## Verdict per stage, at the diagnostic's frozen load

| stage | my reading | astra's reading |
|---|---|---|
| T0 | plausible: it is run 3's configuration, which met its registered lines with zero refusals | plausible |
| T1, at most 3x | plausible at 256, by a margin of about 20% on the ratio; under the all-token definition by 1 to 2.4 points on the throughput bar at the paces the cards ran, and 10% slower breaks it; under the output definition at every pace replayed | plausible at 256 |
| T2, at most 2x | **implausible at this load within the guard bars**: 192 sits at 2.02 to 2.08 on the replayed anchor, about 5% higher on the measured one, and fails all-token throughput; 128 reaches the ratio only by building a queue that fails the contender-work bar under either definition | **not decidable**: the 128 regime's timing is unsupported and its retention is near the bar |
| T3, at most 1.25x | implausible with this lever: even a cap of 72, which nearly splits the premium prompt, stays at 1.50 while the guards collapse | implausible |

**Where we differ, and why.** astra's "not decidable" rests on the uncovered 128-token trajectory, which is right about the ratio: 1.75 at 128 is an interpolation.
My "implausible" rests on the stability floor above, which uses only the covered terms, so the guard fails at 192 and 128 regardless of the uncovered ones.
We agree that a measurement, not the replay, has to decide, and that the registration must keep 192 and 128 as arms rather than drop them on this screen.

### What a lighter load would change, recorded and not adopted

Keeping two contenders in three or one in two, with the premium untouched, the same replay puts the hold at 128 to 192 inside T2 on every block at the fitted pace and 10% slower, and still nothing near T3: the best is 1.58 at 96 with half the contenders (`light-1.0-1of2.txt:48-52`, `light-1.1-1of2.txt:48-52`, `light-1.0-2of3.txt:48-52`, `light-1.1-2of3.txt:48-52`).
A load chosen because a replay says it passes is the selection this repository's registrations exist to prevent, so the draft registration does not use one; a lighter load needs its own reason, registered before its traces are replayed.

## What it licenses

A registration at the frozen load whose arms are the hold at 384, 256, 192 and 128, with a screen that predicts T1 at 256 and nothing higher.
It does not license any stage as reached; every figure above is the replay's, on traces the replay was fitted near, and the paid session decides.

## What a paid calibration would have to measure first, if the owner wants one before the main study

Agreed with astra, who listed it independently:
- a single contender's interior chunks of 256 and 128 at every context depth, beside the premium decodes the load produces, which the archives never had;
- the scheduler's period, the gateway-to-engine-add wait and the content delivery at those caps, since the replay carries the last two as constants;
- 64-slot occupancy, because the CPU experiment showed a cap does nothing when the slots are full (`2026-10-08-measuring-prospective-admission-design.md`, "The CPU experiment, redone");
- same-session isolation and unshed arms, so no ratio borrows another card's denominator.

The registration draft folds these into the main session's own step logs rather than buying a calibration session first, and the owner decides which.

## The most dangerous way this goes wrong

astra's, which I adopt: a low premium p99 bought by quietly lowering the contender's effective load.
A queue that never drains inside the cell, scored on survivors, or work counted after the window, would pass a guard bar the engine did not earn.
The registration's guard bars are read from the engine's own step log over a window shared by every arm, as v26's work line was (`hack/prospective-pilot/pilot_report.py`, the shared-window work), and an unfinished contender's unprocessed tokens count as not done.

## Who established what

The fit, the binned residuals, the replay screen, the token shares and the stability arithmetic are mine, computed by the scripts above.
astra independently reproduced the fit, computed the coverage table and the held-out bias, and named the most dangerous error; I re-derived its coverage table exactly before using it.
Its replay figures for hold-cap on the diagnostic's own cells (410, 407 and 444 ms against 423, 479 and 452 measured) are its own and were not re-derived here.
