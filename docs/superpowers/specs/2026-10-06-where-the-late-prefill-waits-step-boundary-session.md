# Where the late prefill waits — a step-boundary session, registered

Date: 2026-10-06 · **Frozen by the amendment at the end, before any cell was bought,** and changed after it only by dated amendments. **Nothing is bought without the user's approval of the purchase.**

**Why it exists.**
- The logged-engine pilot (`2026-10-06-a-timing-family-for-the-logged-synchronous-engine.md`) failed. Every staggered late prefill's client TTFT exceeded the model's account of its own steps by at least 11.1 ms (11.3 ms under the other convention). The archive could not say why.
- `2026-10-06-step-boundary-instrumentation-built-and-parked.md` built an instrument that can say why, and parked it until a decision depended on it. One now does: the owner wants M5-b's successor pursued, and its feasibility check needs a step-time model of mixed prefill and decode.
- I and codex `gpt-6-astra` designed it independently. My reduced design was narrowed by astra's review, and this page was rewritten after astra attacked its first draft (section 9).

**What it is not.** It re-asks nothing that failed. The instrument-validation I1 stays failed, the logged-engine pilot stays failed, and M5-b stays closed. This is a new instrument on a new target.

## 1. The system and the instrument

The engine is instrument session 5's: vLLM v0.27.1 at the pinned digest, Qwen2.5-3B-Instruct at the pinned revision, one A10G (g5.2xlarge), a 2,048-token batch budget, 64 sequences, `--no-async-scheduling`, `--enable-logging-iteration-details`, prefix caching off.

**The instrument** is `hack/vllm-plugins/step_logging_scheduler.py`, loaded with `--scheduler-cls step_logging_scheduler.StepLoggingScheduler` from a ConfigMap of the checked-in file. The matrix compares its sha256 inside the pod with the file at the frozen commit. It changes no scheduling decision. It records:
- each request's arrival in the scheduler, A (entry to `add_request`);
- vLLM's own `Request.arrival_time`, P, stamped in the frontend after templating and tokenization, just before the request is sent to the engine core (`v1/engine/input_processor.py`);
- each step's scheduling entry and exit (t0, t1), the requests scheduled with their tokens and their computed tokens before the step;
- the scheduler update's entry and exit (t2, t3);
- a wall-clock reading bracketed by two monotonic readings on every record, and the instrument's own cost, including buffering and the handoff to its writer.

It does no file I/O while requests are in flight. After a drain it hands the batch to one long-lived writer thread, which serialises nothing until the scheduler thread has finished the batch's last record. The writer writes and closes the batch's file, stamps its end, then appends one closing flush record carrying that end. **Outside every recorded cost and stamp:** that one closing append, and the single event set that releases the writer. Every request carries `X-Request-Id <arm>-<block>-<warmup|measured>-<trace index>`, which vLLM makes its engine id as `chatcmpl-<id>-<8 characters>`, so client and engine rows join one to one by prefix.

**Validated on v0.27.1's CPU build, at no cost**, with `hack/vllm-plugins/validate-on-cpu.sh` and `smoke-step-evaluator-on-cpu.sh`. The validation's evidence is kept in `data/2026-10-06-step-instrument-cpu-validation/`, from which `check_step_log.py` reproduces its summary:
- 70 steps matched the engine's 70 Iteration lines with equal tokens at each;
- every request joined one to one and scheduled prompt + output − 1 tokens;
- the instrument's own cost was at most 0.069% of a step's occupancy, admissions, drain checks and handoffs included;
- clock brackets were at most 0.91 µs;
- vLLM's non-default args line names the class;
- in the smoke run, the evaluator's joins and the S ≤ P ≤ A ≤ F ≤ O ≤ C ordering held on real output.

None of that is a fact about the A10G.

**Target, declared before the data.** The staggered results concern **the instrumented engine**. Whether they transfer to the uninstrumented engine is not tested here, and nothing below may claim it.

## 2. Cells

Study `step-boundary-2026-10-06`, with study s4's episode design and warm-ups at one fresh seed, 31, the same in every block so that each pair replays identical traces. Six blocks, laid out by `hack/m5c-matrix.sh`:

| Arm | Blocks |
|---|---|
| `serial-log`, `serial-step` | 1, 3, 5 |
| `burst-log`, `burst-step` | 1–6 |
| `stagger-step` | 1, 3, 5 |

That is 21 cells. Inside a block the order is the sha256 hash order, except that block 1 starts with its staggered cell. Serial and staggered cells are spread over the session rather than front-loaded. `PLAN_ONLY` finds every planned trace scorable.

**Time and money.**
- Session 5's per-type cell times give 20,685 s (5.75 h) of warm cells.
- The matrix's own projection after a cold first staggered cell (3,252 s in session 5, an overhead of 328 s against the charged 2,924) is ceil(1.2 × (6×617 + 12×457 + 2×2,924 + 20×328) / 60) = 432 minutes. With the first cell that is 486 minutes, before bring-up.
- The hard stop, backstop and the dollar bound they imply are set in the freezing amendment.

## 3. Gates, in order; each refuses

1. **Archive** (`step_boundary.gate_archive`):
   - exactly the 21 registered cells, since an incomplete session is a refusal;
   - every measured and warm-up trace is the registered matrix (`matrix-plan-check`), and is what `gen-trace` makes at the registered seed 31, byte for byte (`check_registered_seed`), so every pair replays identical traces;
   - provenance: image, revision, flags, and the instrument in exactly the `-step` cells;
   - the whole registered engine configuration (model, dtype, context length, 64 sequences, 0.90 memory, prefix caching off, 2,048-token budget, port) in every cell, with no other budget, sequence cap or prefix caching, and every `-step` cell's archived plugin sha256 equal to the instrument at the frozen commit (`check_registered_engine`);
   - W on every warm-up, S on every staggered episode (warm-up included, conditioning request handled as in session 4), and I2 (no preemption, contiguous iterations, drained serial episodes).
2. **Instrument** (`check_step_log.py` on every `-step` cell, with the client's output counts):
   - one to one with the engine's Iteration lines, with equal tokens at every step;
   - every client request joined to exactly one engine request, and the reverse;
   - each request's tokens summing to prompt + output − 1, and its computed tokens continuous;
   - step boundaries ordered and not overlapping;
   - the log ending on a flush, and every write ending before the next request arrived;
   - no overflow;
   - the instrument's own cost at most 1% of every step's occupancy, t0 to t3. That cost is the step's scheduling record, its update record (the drain check and any handoff to the writer included), and the admissions recorded since the previous step's update.
3. **Overhead, equivalence where it can be powered** (`step_boundary.gate_overhead`):
   - **Endpoints, 75 in all:**
     - Serial: each setting's median TTFT (27) and median ITL (18), where ITL is (end − first token) / (output − 1) and includes stream termination.
     - Burst: each episode type's mean over episodes of mean TTFT, maximum TTFT and mean ITL (30).
   - **Rule:** for each, the paired-block 95% t-interval of log(step / log) must lie inside log(0.95) to log(1.05), with 3 serial pairs (df 2) and 6 burst pairs (df 5).
   - **Planning power, mine.** Using session 5's paired block SDs as a stand-in (largest 0.0061 serial, 0.0198 burst, in log ratio), 20,000 simulations of independent normal blocks at zero effect pass all 75 together 19,810 times, 99.05%. This is reproducible with `hack/tail-crossing-model/step_boundary_power.py` at seed 3; astra's independent reconstruction gave 98.94%. That stand-in is a different instrument and the endpoints are not independent, so the figure is a planning estimate.
   - **This gate covers serial and burst only.** A failure is reported as "the instrument's overhead is not established" and does not stop Q1 to Q3 from being reported for the instrumented engine.

## 4. Q1 — where the late prefill waits (a prediction, reported, not a gate)

For each staggered late prefill, from the client row and the instrument, all on one host's clock:
- S is the client send;
- P is vLLM's arrival stamp;
- A is the scheduler arrival;
- F is the t0 of the first step scheduling it;
- O is the t3 of the step completing its prompt;
- C is the client's first content.

The engine core takes new requests only between steps (`EngineCoreProc.run_busy_loop`), so a request that arrives while a step is in flight waits in P → A. That is the mechanism under test.

**Baseline.** For each prompt length, the median P → A of the serial-step requests, which arrive at an idle engine.

**The wait** of a late prefill is (P → A − the baseline at its length) + (A → F).

**Prediction, written before the data:** for each of the six short-prefill settings, the mean wait over its episodes is at least half the mean gap the pilot left under the context convention:

| Decoders, decoder prompt, late prompt | Half the pilot's mean gap |
|---|---:|
| 1, 256, 256 | 9.873 ms |
| 1, 8,192, 256 | 15.442 ms |
| 4, 256, 256 | 8.967 ms |
| 4, 8,192, 256 | 15.047 ms |
| 16, 256, 256 | 13.162 ms |
| 16, 8,192, 256 | 28.532 ms |

These are re-derived by me, and independently by astra, from `docs/superpowers/specs/data/2026-10-06-logged-engine-pilot.json`.

- Each setting is judged on its point estimate, and Q1 holds only if all six do. The three block means and their t95 interval (df 2) are published beside each and judge nothing.
- Every component, S → P, P → A, A → F, F → O and O → C, is published in ms for all twelve staggered settings, F → O including steps of other requests between the late prefill's own.

## 5. Q3 — the family on measured occupancy (a verdict, but not a gate)

- **Family:** `c + f(P) + d1·n + d2·n² + m·P·n + h·Σpᵢ·Cᵢ + k·K_d`, with nonnegative coefficients, knots 0/256/512/1,024/2,048, and `k` always in.
- **Features from the instrument's own counts, with no reconstruction:**
  - P is the scheduled context tokens of requests whose prompt is unfinished;
  - n is the decoders;
  - K_d is the sum over decoders of computed tokens + 1;
  - H is the sum over prompts of tokens × computed tokens.
- **Target:** each `-step` step's measured occupancy, t0 to t3, in ms, with no clock correction.
- **Fit:**
  - Train on serial and burst `-step` episodes, equal total weight per setting, column-normalised.
  - Hold out by one seeded order of each setting's cycle positions, fixed across its cells and cut into thirds; the cell at index j of its type holds out third j mod 3. So each position is held out once over three serial cells and twice over six burst cells.
  - Never train on staggered episodes.
- Every step that schedules a measured request must belong to exactly one measured episode; a step shared by two refuses Q3 rather than dropping out of both.
- **Pass:** every held-out and staggered setting's mean predicted occupancy is within 10% of the measured, separately for context-bearing, pure-decode and late-prefill steps; the design has full rank and a condition number of at most 100.
- **What a pass is not.** Occupancy excludes the time between one step's t3 and the next step's t0: output publication and admission work.
  - That gap is published for consecutive steps of one measured episode, identified by the episode's own requests, so warm-up steps are not in it. Per type it is published as median, p95 and block medians.
  - A pass here makes no simulator-readiness claim until that gap and the P → A wait are modelled too.
- A Q3 refusal (rank or condition) is Q3's verdict and does not suppress the gates, the decomposition or Q1.

## 6. Stopping

- **One session and one analysis at the frozen commit.** There is no extension, and no re-purchase toward a pass.
- If gate 1 or 2 refuses, nothing past it is read.
- If gate 3 fails, Q1 and Q3 are still reported for the instrumented engine, and its overhead stays unestablished.
- The matrix stops acquisition when a cell is refused (W, S, provenance, or the instrument log not captured) or the deadline projection refuses. An incomplete session is a refusal.

## 7. What a result licenses

**May license:**
- serial and burst equivalence of the instrument on the 75 endpoints;
- a measured decomposition of the staggered late prefill's TTFT, for the instrumented engine;
- held-out prediction of measured occupancy at this configuration.

**Must refuse:**
- staggered on/off equivalence;
- a total overhead bound inferred from self-timing;
- an attribution inside S → P (HTTP, templating, tokenization) or O → C (publication, delivery);
- anything about async engines, other budgets (512 included), models or cards;
- any protection claim.

## 8. Not tested before purchase

- The whole evaluator has not run on a whole step-boundary archive, because none exists; its parts have, as above.
- The plugin's behaviour under CUDA has not been seen.
- The kind rehearsal's stub engine does not load the instrument, so the `-step` collection path in the matrix has been exercised by its functions' tests, not on a cluster.

## 9. Who decided what, and what astra's review of the first draft changed

- **Mine:** the reduced design (serial and burst pairs; staggered instrumented only), the self-timed cost, the writer thread, the use of vLLM's own arrival stamp for P, the serial baseline, and the joint power.
- **astra's:**
  - the narrowed target;
  - that waiting falls in P → A, not A → F, which made the first Q1 unidentifiable;
  - that the first Q2's premise was false, so it is removed: long late prefills' own steps were already within 10% in the pilot;
  - the correct 21-cell count and the 486-minute projection;
  - the occupancy target's missing inter-step gap;
  - spreading serial and staggered cells over the session;
  - the enumerated endpoints.
- **Defects found in the code before freezing, all fixed with tests that fail when reverted:**
  - the conditioning request missing from the study's gate S, which would have refused the first cell;
  - a held-out order redrawn per cell, which left one cycle never held out;
  - a log capture that accepted a truncated last batch;
  - a precedence error that passed an 8% overhead;
  - a final flush that could race the last output;
  - a handoff cost lost for the last drain;
  - admission cost left out of the 1% bound;
  - a write's end stamped before its file closed;
  - traces not checked against the registered seed;
  - a Q3 refusal that erased the whole evaluation;
  - a gap population that included warm-up steps;
  - steps shared by two episodes dropped silently from Q3;
  - a handoff and drain check left out of the recorded cost (a 20 ms injected delay recorded as 0.002 ms);
  - a provenance check that passed a 512-token budget, 32 sequences and prefix caching on, and never read the archived plugin hash;
  - an engine-option check that a later `--max-num-batched-tokens 512` or `--dtype=bfloat16` could override unseen;
  - an overlap refusal in the gap report that ended the whole evaluation.
- Who found them: the conditioning, held-out and capture defects came from astra's bare review of the code; the flush race from its review of my reduced design; the next six from its attack on the rewritten page, the next three from its second attack and the last two from a bare review of those fixes. The 8% precedence error was caught by my own self-test.

## Amendment, 2026-10-06 — frozen before purchase

This page is frozen at the commit that adds this amendment; the evaluator, the instrument, the matrix and the session script are those of that commit. Before freezing, every check below was run at it: the self-test suites (`check-tail-crossing-self-tests.sh`), `make harness-check`, `make spot-lifecycle`, the full Go suite, `make lint`, `make docs-check`, `PLAN_ONLY` for the 21 cells, `validate-on-cpu.sh` and `smoke-step-evaluator-on-cpu.sh`.

**Launch, as it will be run, after role credentials are re-issued:**

```
AWS_PROFILE=gpu-lab STUDY=step-boundary-2026-10-06 \
  ARMS="serial-log serial-step burst-log burst-step stagger-step" REPS=6 SEEDS=31 \
  PURPOSE=new-measurement HARD_STOP_SECONDS=36000 BACKSTOP_SECONDS=36600 \
  HYPOTHESIS="step-boundary session: gates 1-3, Q1 and Q3 as registered" \
  STOPPING_RULE="one session of 21 cells; step_boundary.py at the frozen commit runs once; refusals and the deadline projection stop acquisition; nothing is re-bought" \
  bash hack/m5c-gpu-session.sh
```

**Deadline and money.**
- The hard stop is 600 minutes and the backstop 610, so the session script demands 640 minutes of credentials.
- After the cold first cell the guard has about 521 minutes against its 432-minute projection.
- Expected: about 8.5 hours of instance time, about $6 at the observed spot price.
- Bound: 610 minutes at the $1.10/hour cap, **$11.18**.

**The analysis**, once and only once, at this commit:

```
BENCHHARNESS=<cmd/benchharness at this commit> python3 hack/tail-crossing-model/step_boundary.py hack/<archive>/m5c-run
```

## Result, 2026-10-07 — the instrument passes all three gates within ±5%; both registered predictions fail

**The session.** It launched at the frozen commit `6de7f59` and completed all 21 cells with no refusal. The deadline guard's last projection had 258 minutes left against 12 projected. CloudTrail records the instance i-015c2de4ce40d8214 launched at 22:39:59 KST on 2026-10-06 and terminated at 04:32:28 KST, 5.87 hours. The archive is hack/m5c-20261006-133937.

**Its cost is not yet in Cost Explorer.** The whole session falls in 2026-10-06 UTC, and so do the last 5.86 hours of session 5 (i-098660626ffa74b07, terminated 05:51 UTC). Cost Explorer read on 2026-10-07 shows 5.856 g5.2xlarge spot hours and $4.00 for that day, which is one session's worth, not two. The $2.89 first written here was an earlier reading of the same day and could not be this session's cost. At the $0.68–0.69 per hour these two days were billed, 5.87 hours is about $4.0 of spot time; that is an estimate until the day is final.

**One defect of the session script, not of the data.** After unpacking the evidence, `hack/m5c-gpu-session.sh` failed its repetition check with "arm serial-log is missing repetition 2 of 6". That check expected every arm in every block, and this registration buys serial and staggered cells in blocks 1, 3 and 5 only, which the matrix laid out correctly. The evaluator's gate 1, which checks the registered 21 cells, passed. A kind rehearsal of the -step path would have caught the check (section 8 said none was run), and it is fixed after this record.

`hack/tail-crossing-model/step_boundary.py` at `6de7f59` was run once on the archive. Its whole output is kept as `data/2026-10-07-step-boundary-analysis.txt`.

| | Result |
|---|---|
| Gate 1, archive | **passes**: 21 cells, design, all 42 traces seed 31's byte for byte, the registered engine configuration in every cell and this tree's instrument in every -step cell, and W, S and I2 |
| Gate 2, instrument | **passes** in all 12 -step cells: every step one to one with the engine's log (3,080 or 3,081 per burst cell, 5,314 per serial cell, 37,960 per staggered cell), every request joined and reconciled, own cost median about 0.07% and worst 0.56% of a step's occupancy, clock brackets median under 0.5 µs |
| Gate 3, overhead | **passes**: all 75 endpoints inside ±5%; the widest intervals are serial (1,024, 16) ITL [−1.04, +1.34] and burst (16, 256, 64) mean TTFT [−0.66, +0.95] log-points. Nine intervals exclude zero, all on the slower side, the highest serial (8,192, 64) ITL [+0.26, +0.46]: the instrument's cost is small, not unmeasurable |
| Q1 | **does not hold** on any of the six short-prefill settings |
| Q3 | **fails**: condition 13.7; 13 phases outside 10% |

**The decomposition of the late prefill's TTFT**, in mean ms, for the instrumented engine:

| Setting | S → P | P → A | A → F | F → O | O → C |
|---|---:|---:|---:|---:|---:|
| (1, 256, 256) | 2.99 | 11.15 | 0.016 | 45.15 | 2.18 |
| (4, 256, 256) | 3.49 | 10.90 | 0.018 | 46.14 | 2.64 |
| (16, 256, 256) | 5.04 | 12.11 | 0.016 | 49.01 | 3.69 |
| (1, 8,192, 256) | 3.03 | 12.29 | 0.016 | 58.41 | 2.17 |
| (4, 8,192, 256) | 3.54 | 14.42 | 0.017 | 59.77 | 2.63 |
| (16, 8,192, 256) | 4.70 | 18.97 | 0.018 | 104.07 | 3.80 |

The 8,192-token late prefills are in the output file.

- A → F averages 0.016–0.022 ms in every setting; over all 180 late prefills the largest is 0.043 ms.
- The excess sits before that, in P → A, the hop from the frontend's stamp to the scheduler. Section 4's mechanism, the core taking new requests only between steps, would put it there. The evaluator measures where the time is, not why: it does not compute overlap with the step in flight or separate transport and process scheduling from it.
- Steps follow each other with a median gap of 0.037–0.044 ms; p95 is 0.070 ms or less.

**Q1.** The wait beyond an idle engine's P → A, 8.5 to 16.6 ms, is 29% to 48% of the gap the pilot left. That is short of the registered half in every setting, so by the registered point rule **the prediction fails**. The closest are (4, 256, 256) at 8.53 against 8.97 and (1, 256, 256) at 8.78 against 9.87. The block-mean t95 intervals, which section 4 publishes and lets judge nothing, contain the half in four of the six settings; only the two 16-decoder settings exclude it. So the data do not show the prediction false everywhere: they show it unconfirmed, and clearly short with 16 decoders.

**Q3.** On measured occupancy, with no clock correction, the family's 13 failures are all among the 14 phases the pilot's nominal fit failed on corrected log time; the pilot's fourteenth, burst (16, 2,048, 64) decode at +10.7%, passes here.
- The six short late prefills' own steps are under-predicted by 21% to 38%. The six 8,192-token late prefills are within 10% (−0.6% to −9.4%).
- Decode steps beside long-context decoders are over-predicted by up to 55%.

So the failure does not need the clock correction to appear. This does not measure what the correction contributed to the pilot, whose predictor and timings differ. The family is trained on serial and burst episodes, which include 1,260 mixed steps of 18,049 (a prefill and running decoders together), and it has an `m·P·n` term whose fitted value is not zero. It still does not predict a short late prefill joining running decoders.

**What this establishes.** For the instrumented engine:
- The instrument records every step and request, at a direct cost under 0.6% of any step.
- It moves no serial or burst endpoint by more than the ±5% bound, with intervals within about ±1.3%. Nine of the 75 intervals exclude zero, all slower, by at most 0.46 log-points.
- A short late prefill's wait (its P → A beyond an idle engine's, plus A → F) is 29% to 48% of the pilot's gap. Nothing here divides the rest of that gap among its other components; it was measured on another session's engine.

**What it does not.** Any staggered on/off equivalence; anything about the uninstrumented, async or other-budget engine; the cause of the P → A excess; or a simulator-ready model. Q3 failed, so no simulator or M5-b feasibility check is built on this family. A different family would be a new registration fitted on data it is not tested on. This archive is now seen.

**Corrections after review, 2026-10-07.** codex `gpt-6-astra`, reading the first version of this Result cold against the output, the registration and the archive, found the following; I re-measured each from the archive before changing the text.
- The heading said the instrument "costs nothing measurable"; nine intervals exclude zero.
- "Within 0.02 ms" was a mean read as a maximum.
- "The core taking new requests only between steps" named a cause the evaluator does not measure.
- "Short of half everywhere" was written as "false" without the intervals beside it.
- "The same places" omitted one pilot failure.
- "21% to 38%" omitted that the six long late prefills pass.
- "Not an artefact of the clock correction" claimed more than a fit without the correction shows.
- "A family fitted on unmixed steps" was false: its training holds 1,260 mixed steps.
- "The rest is its own steps" divided a gap no calculation here partitions.
- Two burst cells have 3,081 steps, not 3,080; the instrument is in the -step cells, not every cell.

The cost paragraph was wrong by my own reading of Cost Explorer.

The same review found three latent evaluator defects, none present in this archive, fixed in `5dc9732`:
- revision, async scheduling and scheduler class were checked for presence, not as effective values;
- a first step with tokens already computed passed the instrument check;
- the clock-offset spread was computed and dropped.

At `5dc9732` the evaluator's output on this archive is byte-identical to the kept file.

A later review found the evaluator's exit status was the overhead gate's alone, so this analysis exited 0 with Q3 FAIL. It now exits 3 when the gates pass and Q3 does not (fixed in the commit after `6377bcc`). The printed output is unchanged.
