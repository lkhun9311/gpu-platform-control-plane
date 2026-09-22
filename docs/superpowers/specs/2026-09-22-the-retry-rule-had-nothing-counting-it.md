# The retry rule had nothing counting it — a budget amendment

**Written 2026-09-22, before any card is bought for the resume arms.** The frozen page
`2026-09-21-the-resume-arms-and-what-they-contrast.md` fixes the arms, the order, the repetitions and the
stopping rule, and forbids its own editing. This page does not change any of those. It adds the one thing
that page left unbounded, and it is written separately because that page may not be edited.

## What is registered, and what is missing from it

> **The stopping rule is that the pair either produces two valid records per arm or it produces none.** A run
> invalidated for any reason the ledger already refuses is retaken, not dropped: dropping the invalid ones
> and keeping the rest selects on the outcome.
>
> — `2026-09-21-the-resume-arms-and-what-they-contrast.md:139`

The rule is right about selection. Dropping the invalid runs and keeping the rest is exactly how a null
result gets manufactured, and the page is correct to forbid it.

**But "retaken" has no bound, and nothing counts it.** Measured, not assumed:

- `hack/gpu-session.sh` builds `SEQUENCE` by repeating a block `REPS` times and never records an attempt
  count. When a run fails it exits and prints `Fix the cause, then resume: START_AT=N` — so **a retry is a
  human re-invocation**, and the script that spends the money cannot tell a first attempt from a fifth.
- `START_AT` is range-checked against the sequence length and nothing else. That check exists because a
  `START_AT` past the end once skipped every run and printed `all runs completed` — a false success in the
  one wrapper that spends money.
- No artifact carries an attempt ordinal. A session that re-entered four times leaves four sets of records
  and no document saying so.

So the registered rule is satisfiable by an unbounded number of paid attempts, and the record of how many it
took is not kept anywhere. Those are two different defects and this page closes both.

## Why an unbounded retry is not a neutral rule

**It reintroduces the selection it forbids, one level up.** "Retake until two valid records per arm" selects
over *sessions* the way dropping invalid runs selects over *runs*. If a cluster condition makes invalidation
correlated with the arm — a resume arm whose replacement Pod is likelier to land on a cold node, say — then
retrying until all four pass keeps exactly the attempts where that condition happened not to bite.

**And the bill is unbounded in a way this repository has already been burned by.** The per-run cost is
recorded in the script itself: *"on rented hardware it costs about three minutes a run"*
(`hack/gpu-session.sh:30`). Four runs is the block; an unbounded retry rule is an unbounded multiple of it.

## The amendment

**One ABBA block. At most four run starts. Zero replacement runs.**

| | registered |
|---|---|
| block | `E-fresh, E-resume, E-resume, E-fresh` — unchanged, from `2026-09-21-the-resume-arms-and-what-they-contrast.md:136` |
| run starts permitted | **four**, total, for the whole campaign |
| replacement runs | **zero** — an invalidated run is not retaken |
| publish the comparison | only if **all four** runs produce valid records |
| otherwise | publish the **attempt history**, not a comparison |

The trade this makes is deliberate. The frozen page forbids dropping invalid runs because that selects on
the outcome; forbidding retakes as well means a single invalidation ends the campaign with no comparison.
**That is the honest failure**: it produces no number rather than a number assembled from the attempts that
happened to work.

**The attempt history is published in either case.** Four run starts, what each produced, and for an
invalidated one the refusal the ledger gave. A campaign that ends without a comparison must still leave a
document saying what was bought, or the next session cannot tell "not attempted" from "attempted and
refused" — a distinction this lab has already mistaken once.

## What must exist before a card is bought

Not part of the stopping rule, but this amendment is unenforceable without them, so they are registered here
rather than discovered during a paid session:

1. **A campaign manifest** written before the first run start, naming the four runs and their order, and an
   **attempt ordinal on every artifact path** so a re-entry cannot overwrite a previous attempt's records.
   Today `EXDIR` plus `START_AT` makes overwriting the normal way to resume.
2. **The session script must be able to express the block at all.** `STUDY` accepts only `reclaim` and
   `idling` (`hack/gpu-session.sh:494`), so there is no form in which these four runs can be requested.
3. **The refusal must be reachable before the money is spent**, not at decode time. A campaign that cannot
   run its fourth run should fail at the first, not on the bill.

## What this page does NOT change

| held fixed | where |
|---|---|
| the arms and what they contrast | the frozen page, untouched |
| the dose, the duty, the termination contract per row | untouched |
| the order within the block | `2026-09-21-the-resume-arms-and-what-they-contrast.md:136`, quoted above and unchanged |
| the interleaving requirement | `cmd/queuelabrun/compare.go:296` decides it, unchanged |
| every validity axis and verdict | untouched |
| the threshold and outcome space | still unchosen, deliberately |

**No threshold is chosen here either.** This page bounds what may be bought. What counts as a difference
worth reporting remains the comparison's business, and choosing it now — knowing which direction the author
expects — is the thing pre-registration exists to prevent.

## What this page does not settle

**Whether four runs are enough to see anything.** They are what the frozen page registered; this page only
refuses to buy a fifth. If four turn out to be too few, that is a finding for a new pre-registration written
before more cards are bought, not a reason to extend a campaign already in flight.

**Whether the cluster can run them.** It declares no storage class today, so the campaign cannot start
regardless of its budget. That is separate owed work.
