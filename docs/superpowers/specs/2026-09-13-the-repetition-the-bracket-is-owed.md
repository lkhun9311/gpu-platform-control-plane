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

## THE ANSWER: the two runs agree on every cell, and the bracket holds

Added 2026-09-14 after the run. Nothing above this line has been edited since its first cell was bought.

| cell | first run | repetition | difference | both runs |
| --- | ---: | ---: | ---: | --- |
| `rung02-shared` | 1,694.7 ms | 1,693.4 ms | **−1.3 ms** | BREACH |
| **`rung02-timeSlicing`** | **130.363 ms** | **132.430 ms** | **+2.1 ms** | **met** |
| `rung03-shared` | 2,303.3 ms | 2,309.1 ms | +5.8 ms | BREACH |
| **`rung03-timeSlicing`** | **143.2 ms** | **143.5 ms** | **+0.3 ms** | **BREACH** |
| `rung03-R1` | 64.0 ms | 63.7 ms | −0.3 ms | met |

Every **contended** cell offered 1,164 or 2,327 premium requests and exactly 139 contender requests, and
completed 139 of 139, as registered. The baseline cell carries no contender rows by construction.

The +2.1 ms is computed from the raw timestamps. An earlier version of this table said +2.0, which is the
difference of two figures already rounded to one decimal — arithmetic on rounded summaries, in a table whose
whole point is a margin of a few milliseconds. No verdict changes.

**The combination rule registered above resolves to the first branch on all four contended cells: both runs
agree, so each cell's verdict stands.** The split **met the target at 2.31 req/s and missed it at 4.61**, in
two independent sessions, and that pair of results is no longer resting on one pair of cells.

Stated as a bracket — "at least 2.31 and below 4.61" — that is a summary of two sampled loads and not a
proof that nothing between them or above them qualifies. The downward ladder's own page records why the
stronger reading is unavailable: the control's tail is not monotone in the premium rate.

**The two cells that set the edge moved by 2.1 ms and 0.3 ms between independent sessions, on different
instances and different physical cards** (GPU UUIDs `a36f5dec` and `d872290b`, checked rather than assumed). Their distances from the target are 8.6 ms and 4.2 ms. So the
margins are four times and fourteen times the repeat movement actually measured — which is what this page
was bought to find out, and it could as easily have gone the other way.

**What did not need buying, in hindsight, is nothing.** Before this run the edge rested on 130.4 and
143.2 ms against a repeat noise figure borrowed from a different arm of a different study. Borrowing it was
the only option; measuring it was worth $0.90.

### A defect the run found in the session's last line

The wrapper bought every cell, downloaded every cell, and then **failed its own end-of-session check**,
demanding `rung01-shared` and `rung01-timeSlicing` — arms this page had explicitly told it not to buy. Its
list of expected arms was written before `skip` existed and counted rung *positions* as purchases.

Nothing was lost: the evidence above came out of that run, and the instance was terminated correctly. But
**the session's last word on a successful run was FAIL**, which is the one thing an end-of-session check
must never say wrongly — an operator who trusts it would have thrown the run away or bought it again.
`hack/test/check-ladder-refusals.sh` now pins that the wrapper's expectation and the runner's plan agree
about a skipped rung.

## What an adversarial review found afterwards

Added 2026-09-14. An independent review was asked to attack the instrument and the claims, and was told the
six defects already found so that it would look for the seventh. It found sixteen more of the same shape —
a guard that exists and is not consulted, or a test that cannot reach what it claims to cover — and five
claims on these pages that reached past the evidence. **It verified the result itself**: all 21,178 raw rows
match their trace hashes, counts, indices, tenants and offsets; both topologies replay identical traces
within each rung; repeated rungs replay identical traces across sessions; every pass/breach classification
reproduces. **No verdict on this page changed.**

### Fixed, with the counterexample each one was found by

| what was wrong | what it would have produced |
| --- | --- |
| The ladder applied per-cell guards to **pooled** replays | Passing both paid sessions reported 278 contender offers where each offered 139; two replays of 300 completions and 70 contender offers each pooled into 600/140, cleared both floors, and returned a verdict on a cell where neither replay was scorable. **This page's own combination rule says the runs are never pooled, and the instrument had no way to enforce it.** It now refuses a pooled cell |
| Heavy censoring was classified **unscorable before breach** | An arm losing a fifth of its premium requests to timeouts — which is what breaching looks like at a high offered rate — came back INVALID for having too few completions left to estimate a p99 from. The instrument refused to score its own clearest failure. Workload integrity is now asked first, then censoring as a **breach**, then the tail floor |
| `ladder-verdict` skipped the trace-identity refusal | A rung whose two cells replayed different traces printed `LADDER: CONTINUE` and bought the next rung, on evidence `report` refuses with exit 1. The cheap decision accepted what the expensive one throws away |
| A **missing** requested rung became a registered STOP | Asking about a rung that was never measured exited 10, which the runner acts on by ending the climb. A boolean cannot carry "not here" and "stop here"; there is now a separate completeness question |
| The final report did not require the **baseline** | Removing the isolated-baseline file left the report at exit 0 saying "no isolated-baseline cell breached the target" when none had been measured. The requirement is now on the final report and deliberately **not** on between-rung verdicts, which run before the baseline is bought |
| A STOP did not cancel the **budget** for the rungs it cancelled | After a stop at rung 1 of a four-rung ladder the deadline projection still asked for seven cells and would refuse to buy the baseline with twenty minutes in hand |
| The baseline purchase could **silently buy nothing** | A ladder whose last entry is `skip` named a rung with no cells; the loop matched nothing, the line above it announced a purchase, and only the session's final check noticed |
| The refusal suite **exited 0 without its gitignored fixture** | On a fresh clone — always — deleting the production refusals it exists to pin left it green. The shell checks now run regardless; only the three row-based scenarios skip |
| The skip regression test **tested its own reconstruction** | Commenting out the real guard left it green: the private copy stayed correct and `grep` found the disabled line inside the comment. It now extracts and executes the wrapper's own lines |

Every fix was confirmed by restoring the defect and watching a named test go red.

### Then fixed as well, because each one either burns money or reports the wrong thing

- **Load validation happened after rental.** A mistyped study, a rung the registry does not admit, or a
  trace whose counts the readings would refuse reached the card before the refusal — about 25 minutes of
  bring-up each time. The wrapper now runs the matrix in a plan-only mode before `run-instances`: it
  generates every planned cell's trace with the real `gen-trace` and asks the real
  `bench.LadderPlanRefusal` whether the readings could score it. **The thresholds stay in `internal/bench`**
  — the shell counts what came out and asks, so no registered number is written down twice. The case that
  motivated it is not hypothetical: omit `DURATION_MS` and the wrapper's default of 420000 generates **470
  premium requests against a floor of 500** at the bottom rung.

  Checking this also found a refusal of mine stating something untrue. It said "gen-trace refuses an arm the
  named study does not admit". Run it: `gen-trace --arm not-an-arm-at-all` writes 297 rows and a manifest
  and exits 0. The guard is in `replay`'s manifest validation, **on the rented card**.
- **The credential margin read the credential cache, not the active credential.** It took the newest cache
  entry whose account matched, which establishes "some credential for this account expires then". An active
  credential with twenty minutes left, beside another role's twelve-hour entry, read as twelve hours. It now
  asks `aws configure export-credentials` — the same chain every call in the session goes through — and
  reads only the expiry field. The cache scan remains as the fallback for a CLI too old to have it.
- **Session identity.** The S3 prefix now carries a per-launch nonce, and the completion marker carries it
  too and is verified before anything is downloaded. Reusing an output name at the same commit used to
  qualify the previous experiment's `DONE`, archive and commit file: the wrapper would download the old
  session, print SESSION DONE, and terminate the instance it had just paid to launch.

### And then the remaining four, none of which changed a number here

- **Row-level identity.** The loader read `rows[0].Arm` and pooled the rest under it. Every row's arm and
  trace checksum is now checked, the way every row's study already was. The counterexample was the review's:
  appending one cell's rows to another's moved the reported p99 from 1,694.7 ms to 1,179.3 at exit 0.
- **An unknown study id** fell through to the M5-b arm order, dropped every arm of the real study out of the
  table, and exited 0 saying it had evaluated no criteria — which is what a report says about a study whose
  readings are not written, a different thing a reader cannot tell apart. It is refused now. Evidence
  written before the study field existed carries an empty id and still loads, which a test pins.
- **The paid manifests named no build.** `gen-trace` has accepted `--engine-image` and `--gateway-sha` since
  it was written and nothing ever passed them. The matrix now reads the engine's digest out of the
  manifests it applies — and **refuses a run whose three engine manifests disagree**, because two topologies
  on two engine builds is not a comparison of topologies. `--gateway-image` is still not passed: the
  gateway runs from a binary built on the instance and there is no image digest to name, and filling the
  field with something that looks like one would be worse than leaving it empty.
- **The rehearsal could not drive a skip-led ladder**, which is the shape a repetition takes, and its
  forced-STOP path exited before the assertions a stop does not change — so breaking the baseline's tenant
  filter or the per-cell handover *specifically on the stopping path* left that mode green. Both are fixed
  and both were re-run on kind. Moving the tenant helper turned out to matter: it was defined two hundred
  lines below the branch that now calls it, which in bash is not a forward declaration.

One more, found while writing this list: **the end-of-session check derived the stopping point from
whatever survived.** A run that wrote rung-1 files, recorded a verdict explicitly saying CONTINUE, and then
died before rung 2 came back as `SESSION DONE` at exit 0 — an interrupted ladder reported as a complete
one. Rungs above the one reached are now waived only against a **recorded STOP**, read out of the evidence.

**What is still open, named rather than implied:**

- **`--require-provenance` is not enabled.** The manifests now carry the engine digest and the commit, but
  the guard that demands them is not switched on, because `--gateway-image` has nothing true to put in it.
- **Partial recovery is gated on near-total absence**: if a README and one raw file are already on disk,
  per-cell uploads in S3 are not reconciled against what is missing.
- **The first-cell deadline shortcut** returns early before the empirical projection exists, so it does not
  notice an already-expired deadline.

None of the three can produce a wrong number. All three can waste a session.

### And the most dangerous thing that is not a bug

**The stopping rule assumes a capacity boundary can be inferred from the first joint breach.** If batching
made the split breach at 4.61 req/s and qualify again at 6, the instrument would behave exactly as
registered — stop at 4.61, never buy 6, and support a confident "below 4.61" that is false. Repeating the
same trace tests reproducibility at a sampled point; it does not test that assumption. The control's tail is
already non-monotone across the four rates measured, which is the warning shot.

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
