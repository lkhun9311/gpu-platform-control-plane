# Confirming S1 on settings it never saw: the registration

*Registered 2026-10-07 before purchase, from the design in `2026-10-07-confirming-s1-on-unseen-settings-design.md`. Nothing here is bought without the owner's explicit approval.*

## What is confirmed

S1, exactly as stage 2 printed it (`2026-10-07-graph-and-eager-mixed-steps.md`, `b57c104`):
- **non-attention terms:** c 15.4473; f slopes 0.0786395, 0.0897957, 0.0958142 and 0.0937947 ms per token on the knots 0/256/512/1,024/2,048; d1 0.111382; d2 0; u_graph 1.46159 for a mixed step of at most 128 scheduled tokens; u_eager 7.28906 above;
- **attention:** 36 × the median `flash_attn_varlen_func` time for the step's composition, measured on an A10G by the grid-3 method (`2026-10-07-an-operator-model-with-measured-attention.md`), at coefficient 1.

These are a literal in `hack/tail-crossing-model/s1_confirm.py`, which fits nothing.

## The cells

Study `step-confirm-2026-10-07` (`internal/bench`, `designStepConfirm`):
- the step-boundary study's engine, instrument, decoder minimum and cap (512), late-prefill cap, lag and jitter, and conditioning warm-up;
- new settings, listed in the design page's table: 16 serial lengths × 3 caps, 9 burst settings, 12 staggered settings, two of which are the archive's controls.

| Arm | Cycles per cell | Requests per cell | Trace span | Warm-up span |
|---|---:|---:|---:|---:|
| serial-step | 6 | 288 | 855,120 ms | 150,520 ms |
| burst-step | 4 | 528 | 263,520 ms | 73,880 ms |
| stagger-step | 7 | 819 | 3,825,263 ms | 553,220 ms |

All at seed 47, identical in every block. The plan check passes it (`check-matrix-plan-refusals.sh`, section 9h).

**Nine cells, three blocks, all three arms in each.** The staggered cell is first in block 1 and the rest are in hash order.

One seed rather than one per block, a departure from the design review's suggestion, for two reasons:
- the settings are what is new;
- the matrix, the evaluator's seed gate and the plan check have been proved with one seed per study.

So the blocks measure repeatability, not seed variation.

## The procedure, in this order

1. **Launch**, after role credentials are re-issued:
   ```
   AWS_PROFILE=gpu-lab STUDY=step-confirm-2026-10-07 \
     ARMS="serial-step burst-step stagger-step" REPS=3 SEEDS=47 \
     PURPOSE=new-measurement HARD_STOP_SECONDS=33000 BACKSTOP_SECONDS=33600 \
     HYPOTHESIS="S1 confirmation: frozen S1 predicts every judged endpoint within 10% mean and 15% step error" \
     STOPPING_RULE="one session of 9 cells; one kernel session for its compositions; s1_confirm.py at the frozen commit runs once; nothing is refitted or re-bought" \
     bash hack/m5c-gpu-session.sh
   ```
   - **Expected:** about 6.3 hours of a g5.2xlarge Spot instance, about $4.5.
   - **Bound:** the 560-minute backstop at the $1.10 per hour cap, $10.27.
2. **Fix the compositions before anything is judged.** `python3 hack/attention-bench/archive_compositions.py --confirm <archive>/m5c-run > docs/superpowers/specs/data/<date>-confirm-compositions.json`, committed.
   - The script prints compositions only, never an occupancy.
   - No residual, prediction or occupancy is computed until step 4.
3. **Time them:** `BENCH_GRID=3 COMPOSITIONS=<that file> hack/attention-microbench.sh`, one g5.xlarge Spot session of about 15 to 25 minutes.
   - Its results carry the manifest's sha256.
   - A failed session is reported, and re-buying needs the owner's approval. It is not re-run by choice.
4. **Evaluate once:** `BENCHHARNESS=<cmd/benchharness at the frozen commit> python3 hack/tail-crossing-model/s1_confirm.py <archive>/m5c-run <compositions> <kernel results>`.

## The gates (each refuses)

- **The archive:** the step-boundary evaluator's own gate 1, pointed at this study's nine cells, id and seed:
  - design, by `matrix-plan-check`;
  - every trace and warm-up byte for byte at seed 47;
  - provenance and the registered engine configuration with the instrument's hash;
  - W, S and I2.
- **The instrument:** gate 2 (`check_step_log`) on every cell.
- **The kernel times:**
  - the sha256 of the manifest they timed must match;
  - the manifest must equal what the archive's steps hold, composition and count;
  - every time must be finite, measured by graph replay on an NVIDIA A10G with FlashAttention version 2, the device and version S1's attention term was measured with.

## The verdict

An endpoint is one setting's one phase (prefill-only, mixed, decode, late-prefill).
- It fails beyond ±10% on its mean or 15% on its mean |step error|.
- An endpoint with under 10 steps is not judged.
- At most 10% of endpoints may be unjudged, or the confirmation refuses.

**Three coverage endpoints are mandatory.** Each must have at least 10 steps or the confirmation refuses:
- graph-run mixed steps (T ≤ 128);
- eager mixed steps (T > 128);
- mixed steps with several prefills.

Each registered setting must also show the phases its shape requires. Each is listed here from the shape alone, and a required phase with no step refuses rather than vanishes:
- a serial setting: prefill-only, plus decode when its cap exceeds 1;
- a burst setting: prefill-only and decode;
- a staggered setting: decode, mixed and late-prefill.

**PASS** when every judged endpoint, the three coverage endpoints included, is within both bounds. Per-block errors are published for every endpoint and judge nothing.

## What it can establish, and what not

**A pass establishes** that the frozen S1 predicts step occupancy within the bounds for compositions it never saw:
- on this engine, model, budget and card;
- with attention measured per composition.

**It does not establish:**
- a simulator: P → A waits, inter-step gaps, TTFT and tails are outside S1;
- any other engine build, budget, model or GPU;
- that an unmeasured composition's attention can be predicted. S1 needs the kernel time of each composition it is given.

**A fail is reported as a fail.** Nothing is refitted, and no threshold, bin, rounding or boundary changes after the data.

## Not tested before purchase

- **A kind rehearsal of the -step path.** The stub engine cannot load the instrument plugin. The matrix's -step handling is the step-boundary session's, which ran 21 cells on the card. The study's own additions are covered by the harness checks (`check-instrument-validation-harness.sh` section 23, `check-matrix-plan-refusals.sh` section 9h).
- **`s1_confirm.gates` on a real archive of this study,** since none exists. It reuses `step_boundary.gate_archive` and `gate_instrument` with the study's cells, id and seed swapped in for the call. Those gates take the study from the shell library, which knows this study.

## Review before freezing

codex `gpt-6-astra`'s bare review of the stage-3 code found three defects. Each is fixed with a test before this page was frozen:
- `instrument_gates.study_of` opened the serial-log cell unconditionally, which this study does not record, so every confirmation archive would have failed before any gate. It now falls back to the serial-step cell. Archives with a serial-log cell read exactly as before.
- A required phase with no step dropped out of judgement silently; required phases are now enumerated and refuse.
- Kernel times from any GPU and FlashAttention version passed; the evaluator now demands the A10G and FA2.

## Result, 2026-10-08 — REFUSED at gate 1: the staggered cells' engine logs were rotated

**The sessions.**

| Session | Instance | Time (KST) | Outcome |
|---|---|---|---|
| Engine, from `47b4951` | i-0d83b74a7f5b0435b, g5.2xlarge Spot | launched 18:28:35 on 2026-10-07, terminated 23:48:11, about 5.3 hours | all 9 cells `completed` (staggered 4,816, 4,527 and 4,527 s; serial 1,197, 1,188 and 1,188 s; burst 516 s each), SESSION DONE |
| Kernel | i-0dda0eaaaaad95155, g5.xlarge Spot | 23:54:22 to 00:08:50 | 1,712 compositions, FA 2 on an A10G, all by graph replay |

The engine session's script printed "TERMINATION UNCONFIRMED" because shutting-down outlasted its polls. The instance was confirmed `terminated` by hand afterwards. Cost is not yet in Cost Explorer.

**Procedure followed.**
- The composition manifest was extracted and committed (`aecb0c5`, sha256 `b19b1b92…`) before anything was timed or judged: 166,830 steps, 1,712 compositions.
- The evaluator then ran once at the frozen code. Its whole output is `data/2026-10-07-confirm-evaluation.txt`, and the kernel times are `data/2026-10-07-confirm-kernel-times.json`.

**The refusal.** `REFUSED: stagger-step-1: the captured log starts at iteration 38573, not 0, so part of the warm-up is missing from it.`

| Cell | Engine log | Iteration lines | First | Instrument steps |
|---|---:|---:|---|---:|
| stagger-step-1 | 3,037,464 bytes | 13,107 | 38,573 | 51,680 |
| stagger-step-2 | 3,028,843 bytes | 13,068 | 38,612 | 51,680 |
| stagger-step-3 | 3,076,843 bytes | 13,275 | 38,405 | 51,680 |
| serial-step-1 | 2,181,373 bytes | 9,304 | 0 | 9,304 |
| burst-step-1 | 818,255 bytes | 3,222 | 0 | 3,222 |

The kubelet rotates a container's log at its default `containerLogMaxSize` of 10 MiB, and `kubectl logs` returns only the newest file.
- The step-boundary session's staggered logs were 8.4 MiB (37,960 iterations) and stayed whole.
- This study's longer staggered traces would have made about 11.4 MiB (232 bytes per iteration line × 51,680).
- So only their tail was captured.

The instrument's own logs are whole: 51,680 steps each. But gate 1 (the warm-up boundary inside the engine log) and gate 2 (the one-to-one reconciliation of instrument steps with the engine's iteration lines) cannot be checked for the rotated part.

**What follows from the registration.**
- The confirmation has no verdict. No prediction, residual or occupancy was computed, and none will be under this registration.
- Not tested before purchase: no earlier cell's engine log had reached 10 MiB, and none of the pre-purchase checks ran a trace this long.
- Re-buying needs another note and the owner's approval.
