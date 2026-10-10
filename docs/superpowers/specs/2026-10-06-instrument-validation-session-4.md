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

## Amendment, 2026-10-06 — what is bought, before it is bought

| | |
|---|---|
| Session | one g5.2xlarge spot instance in `gpu-lab`, `hack/m5c-gpu-session.sh`, `PURPOSE=new-measurement`, study `instrument-validation-s4-2026-10-06` |
| Cells | `REPS=3`, `ARMS="serial-log serial-nolog burst-log burst-nolog stagger-log stagger-nolog"`, seed 11 for every block: 18 cells |
| Warm-up spans | serial 89.2 s, burst 109.6 s, staggered 486.8 s at seed 11 — session 3's plus one 2 s gap, read from the generator; measured traces are session 3's row for row |
| Deadline | `HARD_STOP_SECONDS=39600`, `BACKSTOP_SECONDS=40200`; 700 minutes of credentials, renewed immediately before launch |
| Expected | about 8–9 hours, about $6; bounded at about $12.30 |

**Checked before launch.** Session 3's six traces at seed 11 hash as in its archive's manifests; session 4's warm-up is session 3's with one drained 2,048/16 request inserted before the verification requests; the matrix and the evaluator drop the warm-up's first and last three requests for gate S and refuse a warm-up of any other shape; the engine log is kept and uploaded on a warm-up refusal; the kind rehearsal (`IV=4`) passed.
A refusal record (`cell-refused-*`) is uploaded per cell as well, a gap an independent review by codex `gpt-6-astra` found in the session-4 changes.

## Result, 2026-10-06 — incomplete: the deadline projection stopped acquisition after one cell

The session launched at `bb182ec` at about 06:50 KST and stopped at about 07:12 KST after its first cell. The cell passed W and its other checks; the matrix then projected the remaining seventeen cells at about 640 minutes against 639 left and stopped on the boundary, as it is built to: "STOPPING: 17 cells left at ~31 min each needs about 640 min, and the deadline fires in 639 min." The instance shut itself down and was confirmed terminated.

**Why.** The first cell took 1,124 s: 487 s of replay, 89 s of warm-up and 548 s of cold start. The projection charges every remaining cell its replay, its warm-up and the observed overhead per cell so far — after one cell, the cold one — times 1.2. The pre-purchase amendment recorded that the margin after a serial first cell was about nine minutes; this cold start was slower than session 3's and used it up. A longer deadline cannot fix it: the backstop plus thirty minutes must fit in the 719 minutes SSO role credentials last, and the projection after this first cell needs more. **As registered, the session is incomplete and nothing is re-bought without a further registration.**
