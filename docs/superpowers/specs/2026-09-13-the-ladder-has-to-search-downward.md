# The ladder has to search downward — pre-registration

**Written 2026-09-13, after the first ladder returned L5, and before any card time was bought for this one.**
Nothing on this page may be edited from the moment its first cell is bought, except to record what happened.

This page amends `2026-09-13-what-the-split-costs-in-throughput.md` in the open. It changes **only where the
rungs sit**. The criterion, the arms, the readings, the stopping rule, the counterbalanced order and the
outcome space are that page's, unchanged, and the instrument that evaluates them is the same code.

## Why this exists

The first ladder placed its bottom rung at the load the sharing matrix answered — 9.22 premium requests per
second — and climbed. Both topologies miss the 139.0 ms target at that load by a factor of seven, in numbers
the first page cites in its own second paragraph. **A ladder that climbs from there can return nothing but
"no qualified operating point at or above the bottom rung", and it did.** Two cells were bought to
re-confirm a figure the study already had.

The error was not the criterion and not the stopping rule. It was the **search direction**, chosen without
checking the evidence that already decided it. This page fixes that and nothing else.

## What it takes from the two runs above it, and what it may not

**May:** the 139.0 ms target and where it comes from; the trace shape, model, engine settings and cache
budgets; the harness, the readings and the counterbalance; and the measured fact that at 9.22 premium
requests per second **both topologies breach**, three times over on three instances and three cards.

**May not:** any capacity number, because none has been measured; and the target itself, which was fixed
before any rung of either ladder ran and is not recomputed from this one's evidence.

## The question, unchanged

> **How much premium load can each topology sustain while still meeting the premium latency target, and how
> much of that does the split cost?**

## Capacity, defined before the run — unchanged

> **Sustainable premium rate** = the highest offered premium arrival rate at which, over a 505-second
> arrival window, the arm's premium TTFT p99 is **≤ 139.0 ms** and fewer than **1%** of premium requests are
> censored by the client timeout.

## The rungs

Three, below the answered load, **ascending in rate** so that the registered stopping rule applies exactly
as written: climb until both topologies breach, and the highest rung each one met is its bracket.

"Searching downward" is about where the rungs sit, not about the direction the runner walks them. Inverting
the walk would have inverted the stopping rule and the readings' notion of "highest met rung", and a
direction flag threaded through a scorer is a second way for the same criterion to mean two things.

The parameters were solved offline against the real `gen-trace` at `--seed 11`, and the counts below are
**measured from the generated traces, not predicted**:

| rung | premium | `RATE` | `NOISY_WEIGHT` | premium offers | contender offers |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1.16 req/s | 1.431979 | 0.23386882 | 585 | 139 |
| 2 | 2.31 req/s | 2.564749 | 0.11403366 | 1,164 | 139 |
| 3 | 4.61 req/s | 4.847585 | 0.05746316 | 2,327 | 139 |

`PREMIUM_WEIGHT=1`, `PROBE_WEIGHT=0`, `DURATION_MS=505000`, `--seed 11` at every rung. The contender lands
at exactly **139 offers at all three rungs**, which is the count every rung of the first ladder held and the
count the sharing matrix ran.

**Why the bottom rung is 1.16 and not lower.** The readings refuse a premium tail resting on fewer than 500
completed requests, because a nearest-rank p99 over fewer than that moves with one slow response. At 505
seconds, 500 requests is about 1 per second. **The ladder cannot search below roughly 1 req/s without
changing the trace length, and this page does not change it** — a longer trace at a lower rate is a
different experiment with a different amount of contender work in it.

**Why there is no fourth rung.** 9.22 req/s is already measured, three times, and both topologies breach
there. It is the ladder's **ceiling by prior measurement rather than by purchase**, so a bracket that closes
at rung 3 is closed against it for free.

## Order, repetitions, stopping rule — unchanged

Odd rungs run `shared → timeSlicing`, even rungs the reverse. One repetition per cell, with the registered
exception that a rung landing within a tenth of the target is repeated. Climb until **both** topologies
breach; buy the single `R1` cell at the rung the ladder ends on.

## What each result would mean

| the ladder shows | the sustainable-rate statement |
| --- | --- |
| both meet at rung 3 | both topologies sustain at least 4.61 req/s and breach by 9.22; the bracket is [4.61, 9.22] for both and the ladder did not separate them |
| `timeSlicing` meets at a higher rung than `shared` | the split sustains more premium load at this target — the capacity cost of separation is **negative** at this operating point |
| `shared` meets at a higher rung | the split **costs** capacity, and the tail improvement the sharing matrix measured was bought out of headroom |
| neither meets at rung 1 | no qualified point at or above 1.16 req/s. The target is then unreachable under this contender load at any rate this trace length can measure, which is itself the answer and needs no further rung |

The last row is the one this page is most likely to get wrong under pressure, so it is written down: **if
rung 1 breaches, the target does not move and the trace does not lengthen.** That would say the 139 ms
premium requirement is not satisfiable against 139 contending prompts of 40,000 characters on one A10G,
under either topology — a finding, not a failed run.

## Budget

| line | cost | note |
| --- | ---: | --- |
| three rungs, six cells | ~$0.65 | at the demonstrated $0.68/h; fewer if the stopping rule fires at rung 1 or 2 |
| the one `R1` cell | ~$0.10 | at whichever rung the ladder ends on |
| **total** | **~$0.75** | one session |

Spent on this study so far: about **$0.40** — a session the host killed four minutes in, and the two cells
that returned L5.

## What this run will not be able to say

- **Anything about rates below about 1 req/s**, for the sample-floor reason above.
- **Whether the batch cap or the topology moved the result.** Inherited unchanged from the sharing matrix,
  which records it: the premium engine runs `--max-num-seqs=64` whole-card and `32` split.
- **Maximum throughput.** The criterion is service-qualified; an arm that breaches can still be completing
  more work than one that does not.
- **Sustained stability.** 505 seconds per cell, once.

## What was decided before any data

The three rungs and their exact generator parameters, measured offline; that the rungs ascend so the frozen
stopping rule and readings apply unchanged; that 9.22 req/s is the ceiling by prior measurement rather than
by purchase; the sample-floor argument that sets the bottom rung; that the target does not move if rung 1
breaches; and the budget.

None of it was decided from a result of this ladder, because this ladder has none. What it *was* decided
from is the first ladder's result, and this page says so in its title.
