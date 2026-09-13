# The repetition the bracket is owed — pre-registration

**Written 2026-09-13, after the downward ladder answered L1, and before any card time was bought for this.**
Nothing on this page may be edited from the moment its first cell is bought, except to record what happened.

This page buys the repetition `2026-09-13-the-ladder-has-to-search-downward.md` registered in advance and
then demanded. It adds no rung, no arm, no criterion and no reading.

## What is owed, and why

That page's rule: *"If a rung lands within 10% of 139.0 ms, that rung — and only that rung — is repeated,
because that is where repeat noise could decide the answer. This rule is registered now so that it cannot be
invoked selectively later."*

Two rungs landed inside that band, and they are the two that set the answer's edge:

| cell | premium TTFT p99 | distance from the 139.0 ms target |
| --- | ---: | ---: |
| `rung02-timeSlicing` | 130.4 ms | 8.6 ms **under** — scored *met* |
| `rung03-timeSlicing` | 143.2 ms | 4.2 ms **over** — scored *BREACH* |

The split's bracket, **[2.31, 4.61) req/s**, is exactly the boundary between those two cells. The sharing
matrix measured this instrument's repeat noise on a control at **1.375 ms** across repetitions of one trace,
so the margins are three and six times that noise. Not nothing, and not comfortable.

**Nothing about the direction of the answer is at stake.** `shared` missed the target by factors of nine,
twelve and seventeen at the three rungs; no repetition moves that. What is at stake is only whether the
split's qualified rate is 2.31 req/s or something above it.

## What is bought

**Rungs 2 and 3 again, at the same parameters, in the same order, one repetition each.** Rung 1 is not
re-bought: `timeSlicing` cleared the target there by 15.2 ms and `shared` missed it by 1,143 ms, and neither
is inside the band this page exists to resolve.

| rung | premium | `RATE` | `NOISY_WEIGHT` | premium offers | contender offers |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | — | **not bought** | — | — | — |
| 2 | 2.31 req/s | 2.564749 | 0.11403366 | 1,164 | 139 |
| 3 | 4.61 req/s | 4.847585 | 0.05746316 | 2,327 | 139 |

**The rung numbers are held, not renumbered.** A run that called 2.31 req/s "rung 1" would file it under the
name the previous run gave 1.16 req/s, and the arm name is what stops two offered loads pooling into one
summary. The runner grew one word for this — a rung entry of `skip` keeps its position and buys nothing —
and a test pins that a skipped rung does not shift the ones below it.

**Same order, deliberately.** Rung 2 runs `timeSlicing` first and rung 3 runs `shared` first, which is what
the counterbalance produced the first time. A repetition exists to measure repeat noise, and changing the
order would let an order effect wear noise's name.

**The isolated baseline is bought again**, at the rung the ladder ends on, because the runner buys it there
and because a second `R1` measurement gives the baseline's own repeat noise for free. The first measured
64.0 ms at 4.61 req/s.

## How the two runs combine — decided before this one ran

Each cell is scored on its own evidence, in its own run, by the same instrument. The two runs are then read
side by side, and the rule is:

- **Both runs agree that a cell met** → the cell met. **Both agree it breached** → it breached.
- **The two runs disagree about a cell** → that cell is **inside the noise**, and the bracket edge it sets
  is reported as **unresolved** rather than resolved in the direction of either run.

The runs are **not pooled into one p99.** Pooling two repetitions is what the sharing matrix does with
repetitions of one load, and it is the wrong instrument here: a pooled p99 can read *met* while one
repetition breached, which is precisely the fact this page is buying.

**If the two runs disagree**, the honest statement is that the split's qualified rate lies between 2.31 and
4.61 req/s and this trace length cannot place it more precisely without more repetitions than the study is
willing to buy. That is a worse answer than a resolved bracket and a better one than a bracket asserted from
a single pair of cells four milliseconds apart.

## Budget

| line | cost | note |
| --- | ---: | --- |
| two rungs, four cells | ~$0.75 | at the demonstrated $0.68/h and the **measured** 11 minutes per split cell, plus 25 minutes of bring-up |
| the one `R1` cell | ~$0.15 | at rung 3 |
| **total** | **~$0.90** | one session |

The estimate uses the rate this study actually measured rather than the 8.3 minutes per cell the last two
budgets used, which was a single-engine figure applied to cells that roll out two. Spent so far: about
**$1.47**.

## What this run will not be able to say

- **Anything about rung 1**, which it does not buy.
- **Anything the downward ladder could not say**: rates below about 1 req/s, maximum throughput, sustained
  stability, or whether the batch cap or the topology moved the result.
- **A tighter bracket than [2.31, 4.61).** Resolving the two cells confirms or dissolves that bracket's
  edge; it does not subdivide it. A rung between them is a different purchase.

## What was decided before any data

That only rungs 2 and 3 are bought and why; that the rung numbers are held rather than renumbered; that the
order is unchanged so an order effect cannot wear noise's name; the combination rule, including what
"disagree" means and that the runs are not pooled; and that a disagreement is reported as an unresolved
edge rather than resolved toward either run.
