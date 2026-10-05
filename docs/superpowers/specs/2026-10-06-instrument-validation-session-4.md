# Instrument validation, session 4 — a registration

Date: 2026-10-06 · Registered **before** any card time is bought for it, and frozen from the moment the first cell is bought; later changes are appended as dated amendments.

**Why it exists.** Session 3 (`2026-10-06-instrument-validation-session-3.md`, archive hack/m5c-20261005-173703) stopped after seven cells when gate W refused a staggered cell's warm-up: its first verification request took 267.2 ms against 231 ms ± 5%. It was sent 22.4 s after the previous request ended, into an idle engine. Every staggered warm-up's first verification has been slow (232.6, 233.2, 232.6, 267.2 ms) while the serial and burst ones sit at 230.9–231.9 ms, and 128 warm drained 2,048-token serial requests across three sessions never exceeded 233.2 ms. The first single request after a staggered cycle is not yet at steady state, and W caught it. Session 3's stopping rule requires this registration before anything else is bought. Everything is session 3's **except section 1**.

## 1. What changes

| | Session 3 | Session 4 |
|---|---|---|
| Study id | `instrument-validation-s3-2026-10-06` | `instrument-validation-s4-2026-10-06` |
| Warm-up | one 2,048/16 request, one unscored cycle of the cell's type, two 2,048/16 verification requests | the same, with **one fixed, unscored 2,048/16 conditioning request** between the cycle and the verification requests, at the same drained spacing |
| W | 231 ms ± 5%, pair within 2% of the smaller | **unchanged**, on the last two requests |
| The warm-up's staggered episodes for gate S | the warm-up without its first and last two requests | the warm-up without its first and **last three** requests; each of those three is checked to be a drained 2,048/16 request |
| A refusal at the warm-up | the cell's engine log was not kept | the engine log is captured and uploaded before the matrix stops |

W is not loosened, retried or replaced by a median, and the conditioning request's latency conditions nothing: those would hide the transient W exists to catch. Measured traces, triggers, jitter, replicates, the 512-token minimum, the revision pins, S, the accounting, every estimand and bound, the frozen clock, the stopping rule and the deadline arithmetic (plus about two seconds a cell) are session 3's. Every measured request counts, request 0 included.

## 2. Sessions 2 and 3's cells

Ten bought cells across the two sessions are not pooled with session 4, replace none of its cells and calibrate nothing. An independent reading by codex `gpt-6-astra` found no further instrument defect in session 3's seven: all 2,208 requests succeeded at their caps, preemption deltas were zero, the logged indices and prompt totals reconciled, serial attribution succeeded, and both staggered cells and their warm-ups passed S. Its measured staggered cells left 22.3–34.3 s idle between episodes 118 times with no comparable spike on the next request.

## 3. Who decided what

The conditioning request was proposed by me and, independently, by astra, with W unchanged in both. Updating both warm-up extractors, keeping each earlier study's behaviour by its id, and archiving the engine log on a warm-up refusal are astra's additions, adopted. The verification latencies, the 22.4 s idle and the 128 serial requests were recomputed by me from the archives and agree with astra's; section 2's counts of requests, preemptions and transitions are astra's reading, not recomputed by me.
