# Instrument validation, session 2 — a registration

Date: 2026-10-05 · Registered **before** any card time is bought for it, and frozen from the moment the first cell is bought; later changes are appended as dated amendments.

**Why it exists.** Session 1 (`2026-10-05-can-the-stock-engine-time-an-iteration-instrument-validation.md`, archive hack/m5c-20261005-085339) failed I1 and I3, and that verdict stands. Its diagnostics found three design defects only a card could show — a cold first request in every cell, a prefill clock of the wrong form, and short staggered prefills whose TTFT spreads by about a quarter — and an independent reading by codex `gpt-6-astra` found a fourth: in every `(16, 8,192, *)` staggered episode the prefill was sent 655–823 ms before the last decoder's first token, so that setting never measured sixteen established decoders. The user approved a second session. **Session 1's data choose the clock's form and its coefficients; session 2 tests them, and nothing is refitted on it.** The design was made by me and by astra independently and reconciled; section 7 records who decided what.

## 1. What does not change

Engine, model, tokenizer revision, card class, `--no-async-scheduling` and iteration logging as in session 1, batching limits, prefix caching off, CUDA graphs on, transport, output caps of the serial and burst settings, the nine arms and their 21 cells (three randomised blocks of six synchronous cells, then three async cells, published only), one trace per episode type replayed by every block and mode, I1's rank roles and whole-episode bootstrap, I2, I4 (published), I5, the decode clock and its spread criterion.

## 2. Warm-up, excluded and verified

After each fresh engine is ready and before the cell's measured replay, the matrix replays a warm-up trace: one drained 2,048-token request with 16 outputs, one complete unscored cycle of the cell's episode type, then two drained 2,048/16 **verification** requests. Its rows go to `raw-warmup-<arm>-<rep>.jsonl` and the last warm-up iteration index to `warmup-boundary-<arm>-<rep>.txt`.

- **W (refusal):** both verification TTFTs within 5% of 231 ms (session 1's warm median for that request) and within 2% of each other; otherwise the cell is refused and the session stops. The warm-up is not repeated until it passes.
- Every warm-up iteration is accounted for, and the measured iterations must follow the boundary without a gap. **No measured request is excluded** — request 0 of the measured trace counts.

## 3. The prefill clock, frozen

The omitted time of a serial request is predicted, not fitted:

```
TTFT − Σⱼ elapsedⱼ  =  a + Σⱼ (b + c·Pⱼ)        over the request's context steps j, Pⱼ = scheduled context tokens
a = 6.446325 ms   b = 17.776531 ms per step   c = 0.002620206 ms per token
```

These are the least-squares values over session 1's 159 warm serial-log requests (request 0 of each cell excluded), recomputed by me from the archive and by astra independently, to every digit shown. Predicted omitted time: 24.894, 25.564, 26.906, 29.589, 52.732 and 99.017 ms at 256, 512, 1,024, 2,048, 4,096 and 8,192 tokens.

**Held-out lengths** 768, 3,072 and 6,144 tokens are added to the serial episodes; they were never measured. Their predicted omitted times are **26.235, 50.049 and 75.874 ms**, and their partial final chunks test whether the per-step cost adds as the form says.

**I3 (prefill):** for every serial setting (length × output cap), the signed prediction error divided by observed TTFT; its median's block-stratified whole-episode bootstrap 95% interval (2,000 resamples, seed 20261005) lies within ±5%. Every residual, the largest, and the share beyond 5% are published. This certifies typical timing per setting, not every request; the form's own worst residual on its calibration data is 7.2%. **I3 (decode)** is unchanged.

## 4. Staggered episodes, repaired

- **Decoders capped at 512 output tokens** (session 1: 128), so they decode for about 8 to 13 seconds after their first token.
- **The prefill is sent at 1.3 × the decoders' estimated prefill time + 200 ms + a seeded uniform 0–100 ms.** From session 1's timings the `(16, 8,192)` decoders' last first token falls about 18.3 s after they are sent and the new trigger at about 22.7 s, inside a decode window that lasts to about 31 s; the small settings have seconds of margin.
- **S (refusal):** in every staggered episode the prefill is sent after every decoder's first token and its first token arrives before any decoder's last; any violation refuses the cell.
- **Replicates:** the six short-prefill settings (256 tokens) seven times per cell and the six long-prefill settings three times; seeded order per cycle.
- **Statistic:** staggered TTFT in I1 is compared by **arithmetic mean**, not median — a median jumps between the two modes session 1 showed — with rank roles and whole-episode resampling as before, and the prefill role is also judged on its own so decoder ranks cannot dilute it. Mode occupancy is published and conditions nothing.

## 5. Serial and burst replicates

Serial: lengths 256, 512, 768, 1,024, 2,048, 3,072, 4,096, 6,144 and 8,192 × caps 1, 16 and 64, **six cycles** per cell. Bursts: unchanged, three cycles. Every trace length is fixed by the generator before launch and checked by `PLAN_ONLY`.

## 6. Budget and stopping rule

About 8–9 hours of instance time, measured from the generator's trace spans plus session 1's per-cell overhead and the warm-up; expected cost about $6 at session 1's spot price, bounded by the $1.10/hour cap and the backstop. The deadline is set from the generated spans before launch and written in a pre-purchase amendment, with credentials renewed immediately before it.

One session. The evaluator as committed at launch runs once; its verdict is the answer. W, S, accounting or preemption refusals stop acquisition and the session is reported incomplete. No cell is replaced, no gate is peeked at while the session runs, and a failed or inconclusive verdict buys nothing further — no simulator study and no third session without a new registration.

## 7. Who decided what

| | Me, before astra | astra | Fixed |
|---|---|---|---|
| Warm-up | one serial cycle, published check | warm request + unscored cycle of the cell's type + two verification requests, refusal | astra's |
| Clock form | `a + b0·k + b1·L` | `a + Σ(b + c·Pⱼ)` — the same form | agreed |
| Coefficients | a prediction range, published | frozen values, no refit | astra's |
| Held-out lengths | none | 768, 3,072, 6,144 | astra's |
| I3 | median and 95th percentile per setting | per-setting median with bootstrap interval within ±5% | astra's |
| Staggered spread | six cycles | means; more short-prefill replicates | astra's |
| Staggered trigger | — (not seen) | trigger after the decoders' first tokens; found the `(16, 8,192)` defect | astra's finding; **my mechanism** — the replay is open-loop, so a longer decode window and a later fixed trigger, verified by S |

Every session-1 number above was recomputed by me from the archive before it was written here; astra's figures and mine agree to the digits shown.

## Amendment, 2026-10-05 — what is bought, before it is bought

**The async controls are dropped.** With all 21 cells the session does not fit the credentials it can run under. The matrix stops on a cell boundary when the remaining cells, each charged its replay, its warm-up and the observed overhead per cell times 1.2, exceed the time left; after session 1's cold first cell (436 s beyond its replay) that projects about 11.9 hours, and SSO role credentials last 12 hours from issue. The three async cells are publication-only and gate nothing, so they go: **18 cells**, three randomised blocks of the six synchronous arms. `instrument_gates.py` checks W and S on any async cell present and says in its output that none is. Shortening the staggered warm-up was considered and rejected: in session 1 the first burst and staggered episode of every cell was 1.5 to 6 times its setting's median, so a serial warm-up cycle need not warm them.

| | |
|---|---|
| Session | one g5.2xlarge spot instance in `gpu-lab`, `hack/m5c-gpu-session.sh`, `PURPOSE=new-measurement`, study `instrument-validation-s2-2026-10-05` |
| Cells | `REPS=3`, `ARMS="serial-log serial-nolog burst-log burst-nolog stagger-log stagger-nolog"`; seed 11 for every block |
| Trace spans | serial 487.2 s, burst 304.7 s, staggered 2,378.3 s at seed 11 (staggered at most 2,395.2 s at any seed); warm-ups 115.2, 135.6 and 512.8 s |
| Deadline | `HARD_STOP_SECONDS=39600`, `BACKSTOP_SECONDS=40200`. After the first cell the projection leaves about 9 minutes if that cell is serial and more otherwise; the session needs 700 minutes of credentials, renewed immediately before launch |
| Expected | about 8–9 hours; about $6 at session 1's spot price, bounded at about $12.30 by the $1.10/hour cap and the backstop |

**Disclosed before launch.**
- W's "within 2% of each other" is measured against the smaller TTFT, in the matrix and in the evaluator alike.
- Gate S runs per staggered cell in the matrix, by the evaluator's own function, so a violation stops acquisition; an independent review by codex `gpt-6-astra` found it had run only after the session. The same review found that a log missing the head of its warm-up passed and that I3 grouped by the observed output count; the evaluator now refuses a log that does not start at iteration 0 — every cell starts a fresh engine — and groups I3 by the trace's cap. Each has a test that fails when it is reverted.
- The choice of mean over median for staggered TTFT is not pinned by a test: no synthetic case was found in which the two disagree about the verdict.
- `python3` on the instance is inferred, not observed: the matrix had not run it there before; cloud-init, which executes the instance's user-data, is itself a Python 3 program on the Ubuntu 22.04 Deep Learning AMI.
- Rehearsed on kind (`IV=2`): serial-log, serial-nolog and serial-async passed end to end with warm-ups and boundaries, the stub answering 231 ms and reporting its prompt tokens; 1,536 iteration lines, of which 1,296 after the boundary, exactly the warm-up's 30 and the measured 162 requests at eight steps each. Burst and staggered cells were not rehearsed for length; gate S's matrix block was executed in `check-instrument-validation-harness.sh` against good and violating staggered cells.

## Amendment, 2026-10-05, during the session and before any of its cells is read — two checks made exact

An independent review by codex `gpt-6-astra` of the fit code found two weaknesses in this page's evaluator, and both are fixed in `instrument_gates.py` before any session-2 cell has been opened (only file names have been listed):

- **S used a decoder's stream end as its last token.** The end is stamped after the stream's termination. Session 1's decode regressions put that delay at no more than 0.43 ms at any length, so S now requires the prefill's first token at least 1 ms before every decoder's stream end. The matrix applies S per cell with the launch commit's rule (no margin); the verdict applies the margin, and if the two disagree on any cell the verdict says so.
- **The warm-up was bounded but not accounted for.** The prompt tokens scheduled before the boundary must now equal the prompt tokens of the warm-up's requests, so a boundary that cuts the warm-up short or reaches into the measured trace refuses.

As in session 1, the evaluator at the launch commit (`0560304`) will also be run and its verdict published beside the amended one.
