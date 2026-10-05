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
