# Instrument validation, session 5 — a registration

Date: 2026-10-06 · Registered **before** any card time is bought for it, and frozen from the moment the first cell is bought; later changes are appended as dated amendments.

**Why it exists.** Session 4 (`2026-10-06-instrument-validation-session-4.md`, archive hack/m5c-20261005-215015) stopped after one cell on the matrix's deadline projection, and its stopping rule requires a further registration before anything else is bought. Session 5 buys session 4's design — the same study id, `instrument-validation-s4-2026-10-06`, the same traces, warm-ups, gates, bounds and stopping rule — **with two scheduling changes and nothing else**. It was designed by me and, independently, by codex `gpt-6-astra`.

## 1. Correcting session 4's account

Session 4's result says its first cell's overhead was 548 s and that a longer deadline could not have helped. Both are wrong, found by astra and recomputed by me from `iv_remaining_projection` in `hack/m5c-matrix.sh` and the archives' `cell-timings.tsv`:

- The projection charges each cell its configured replay length plus its warm-up's last offset and 30 s — 617, 457 and 2,924 s for serial, burst and staggered cells — so the overhead it carries is `1124 − 617 = 507 s` (session 2: 418 s, session 3: 366 s).
- The stop is exact: `5×617 + 6×457 + 6×2924 + 17×507 = 31,990 s`, times 1.2, is 640 minutes, against 639 left.
- A hard stop of 670 minutes with a backstop of 680 needs 710 minutes of credentials, within the 719 an SSO role credential lasts, and would have left 649 minutes against 640.

## 2. The two changes

| | Session 4 | Session 5 |
|---|---|---|
| Block 1's order | the six arms in hash order | **the first staggered arm in hash order goes first**; the other five keep their hash order. Blocks 2 and 3 unchanged |
| Deadline | `HARD_STOP_SECONDS=39600`, `BACKSTOP_SECONDS=40200` | `HARD_STOP_SECONDS=40200`, `BACKSTOP_SECONDS=40800`; 710 minutes of credentials, issued immediately before launch |

**Why the order.** The guard charges every remaining cell the overhead observed so far, cold first cell included, times 1.2; finishing the longest cell first leaves less work under that factor. With a staggered first cell and session 4's 507 s overhead: `6×617 + 6×457 + 5×2924 + 17×507 = 29,683 s`, times 1.2, is 594 minutes, against about 611 left at the first boundary under the 670-minute hard stop. The guard is not weakened: it still charges the full observed overhead, and a slower card still stops the run. Trace seeds are separate from cell order and unchanged.

**Expected.** About 8–9 hours, about $6; bounded at about $12.50 by the $1.10/hour cap and the backstop.

## 3. Who decided what

The staggered first cell is astra's proposal; my own was to split the blocks over two cards, which would have put I5's endpoints on different cards. Raising the deadline within the credential limit is astra's correction of my claim that it could not help. Both are adopted together, which leaves about 17 minutes at the first boundary rather than either's six or nine.

## Result, 2026-10-06 — complete; the verdict is FAIL on I1 alone, and the frozen clock predicts every setting within 2%

The session launched at `2b4dcad` at about 07:28 KST, passed its first deadline boundary after the staggered first cell, and completed all 18 cells at about 14:57 KST with no refusal; the instance was confirmed terminated. `instrument_gates.py` at the launch commit was run once on hack/m5c-20261005-222736:

| Gate | Result |
|---|---|
| W and S | every cell passes, warm-up and measured |
| I1, pooled intervals | serial TTFT +0.14% [+0.11, +0.18]; burst TTFT −0.16% [−1.01, +0.31]; staggered TTFT +0.17% [−0.02, +0.37], prefill alone +0.27% [−0.55, +1.15]; inter-token time within +0.33% everywhere — all inside ±2% |
| **I1, each setting within ±5%** | **fails**: burst (64, 256, 64) rank 2 at −21.8%, staggered (1, 256, 256) prefill at +5.7% |
| I2 | passes |
| **I3, frozen clock** | **passes**: the median error of every one of the 27 serial settings, held-out lengths 768, 3,072 and 6,144 included, lies within ±2% with its bootstrap interval inside ±5%; the largest single error of 486 requests is 2.9% |
| I3, decode clock | passes |
| I5 | passes, worst drift 0.61% |
| I4 (published) | +5.0%, +15.6% and +55.3% at 1, 4 and 16 decoders |

**The registered verdict is FAIL: I1.** As registered, the timing fit refuses (its prerequisite is a passing instrument), no simulator study is bought on these records, and nothing is re-bought to make I1 pass.

**Diagnostics, after the verdict and not part of it.** Sixteen of the 127 burst settings exceed 5%, all of them ranks of the 64-request, 256-token burst, and each by one block alone (rank 2: −2.3%, +0.4%, −63.5% across the blocks): sixty-four simultaneous requests are scheduled in eight 2,048-token chunks, and a rank whose requests fall in a different chunk from one run to the next moves its TTFT by a chunk's time. That is a property of ranking within the largest burst, not of the logging, whose pooled burst effect is −0.16%. One staggered setting exceeds it, the 256-token prefill behind one decoder, positive in all three blocks (+3.4%, +4.9%, +8.8%) — a cost of a few milliseconds on the shortest requests that the logging may really impose. Every serial setting's TTFT is within ±0.5% and its inter-token time within ±0.6%.

**What stands.** The stock engine's iteration log, with the clock frozen from session 1, predicts a request's TTFT within 2% at every serial setting including lengths it had never seen, and its decode clock is stable; the instrument's own accounting held over 18 cells. What did not pass is the claim that turning the log on changes no single setting by more than 5%.
