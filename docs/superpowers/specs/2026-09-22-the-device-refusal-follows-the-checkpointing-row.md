# The device refusal follows the row that checkpoints — a correction

**Written 2026-09-22, after the refusal shipped and before any card is bought.** This page exists because
`2026-09-21-item-two-could-not-be-refused-at-submission.md:57` registered an acceptance rule in its broader
form, and that form is wrong. A changed acceptance rule does not belong in a footnote of the page that got
it wrong, and it does not belong buried in the budget page either.

## What was registered

> **A second, weaker check sits in the record decoder.** `checkpointingArmStayedOffTheDevice` refuses a
> document whose arm checkpoints and whose ledger shows **any** attempt reporting `cuda-fma`.
>
> — `2026-09-21-item-two-could-not-be-refused-at-submission.md:57`

The same page argued the sweep on purpose: *"an arm that checkpointed the wrong row would be a different
defect with the same consequence."* That sentence was copied into the function's doc comment and into the
call site, so the wrong argument existed in **three places** and each one corroborated the other two.

## Why it is wrong

`Arm.StateFor` (`internal/queuelab/protocol.go:130`) returns an empty plan for every row that is not the
victim — the guard is one line, `internal/queuelab/protocol.go:139`. Under `E-fresh` and `E-resume`, only
`a2-borrow` is given a state path. The co-tenant and the quota owner render no progress file, never take the
workload's checkpoint branch, and use the device exactly as they do under `A-honor`, `A-ignore`, `N-ref`,
`D-full` and `D-quarter`.

So the registered rule refuses a correct record. Both E arms put three rows on the node; two of them are
**supposed** to report `cuda-fma`; the decoder would have refused the document on either of them.

**The cost would have been a paid session, and nothing local would have shown it.** On kind nothing reaches
a driver, so every row reports `cpu-loop` and the sweep never fires. The first record that could trip it is
the first one bought on a real GPU node, and it would have arrived as a decode refusal on data that was
already paid for and could not be re-collected.

## What the refusal is actually about

Not "a checkpointing arm must stay off the device" as a property of the arm. The property belongs to the
**row**, and it is about the accumulator.

On the device path the loop launches the kernel and never advances the accumulator. A row that checkpoints
would therefore write the seed into its progress file and a resumed attempt would report exactly what an
attempt that restored nothing reports. That is what makes the record unreadable, and it is true of the row
that checkpoints and of no other row.

## The amended rule

**For an arm the protocol says checkpoints, every attempt of a row that arm gives a state path to must
report a CPU workload. Attempts of rows the arm gives no state path to are not judged here.**

Implemented at `cmd/queuelabrun/record.go:1793`. The ledger is still swept attempt by attempt — that half of
the original argument stands, because `measurement.workload.kind` is derived from the one attempt
`VictimAttemptUID` picks and a resumed row has several. What changed is that each attempt is now matched
against `arm.StateFor(e.Job)` (`cmd/queuelabrun/record.go:1830`) before it can be refused, and the refusal
message names the row (`cmd/queuelabrun/record.go:1835`).

This makes the device check consistent with its two siblings, which were per-row from the day they were
written: `checkpointingArmActuallyWrote` (`cmd/queuelabrun/record.go:1861`) and
`restoringArmActuallyRestored` (`cmd/queuelabrun/record.go:1906`) both ask `StateFor` per event. The
inconsistency was visible in the codebase the whole time — `checkpointingArmActuallyWrote`'s own comment
cited the device check as the contrast, *"that check sweeps every row"* — and it read as a deliberate
difference rather than as a defect.

## What this does NOT change

Nothing that the frozen pre-registrations fix. Stated explicitly, because a correction to an acceptance rule
is exactly where an unrelated change would be easiest to smuggle in:

| held fixed | where it lives |
|---|---|
| the seven arms and what they contrast | `2026-09-21-the-resume-arms-and-what-they-contrast.md` (frozen) |
| repetitions, interleaving, stopping rule | same page |
| dose, duty, termination contract per row | `Arm.ContractFor`, untouched |
| the order rows are submitted in | untouched |
| every validity axis and verdict | untouched — this is a decode refusal, not a verdict |
| `recordSchemaVersion` | stays **22**; no field changed, so no backward-read case is added |

No arm is named anywhere in the amended check. It asks the protocol which rows checkpoint, which is the
property the refusal is about, and an arm added later gets the right treatment without this code being
edited.

## Evidence

The tests that pin it are `cmd/queuelabrun/record_test.go:3083` (the quota owner of a checkpointing arm,
reporting `cuda-fma`, accepted) and `cmd/queuelabrun/record_test.go:3090` (the co-tenant, same). The wiring
test asserts on `"checkpoints row"` at `cmd/queuelabrun/record_test.go:3408`, which is text the old message
did not contain.

Perturbation **X1** — restore the sweep over every row — is **RED on exactly those two rows** and green
everywhere else. Before this change it was green, which is the whole point: the rule was guarded by nothing,
and a test existed that pinned the wrong behaviour rather than none at all.

## What this page does not settle

**It does not establish that a checkpointing victim stayed off the device.** It establishes that the
decoder refuses one that did not. The mechanism remains the workload's own branch in
`internal/queuelab/submit.go`, and the preflight remains the thing that confirms a driver was reachable at
all.

**It says nothing about whether the checkpoint was written or read.** Those are the two refusals registered
on `2026-09-22-the-checkpoint-must-say-whether-it-was-written.md`, and they are unchanged by this.

**It does not make the E arms buyable.** The storage class is still undeclared on the cluster, the session
script still has no `resume` study and still hardcodes `-require-device`, and the stopping rule still has no
finite retry budget. Those are three separate pieces of owed work.
