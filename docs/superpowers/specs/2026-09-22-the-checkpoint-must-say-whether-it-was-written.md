# The checkpoint must say whether it was written — pre-registered

**Written 2026-09-22, before the field exists in `internal/queuelab/provenance.go` and before any card is
bought for the resume arms.** `2026-09-22-the-claim-exists-and-the-class-is-named.md:82` reserved exactly
this: *"There is still no evidence the checkpoint was written … That is the next branch, and the arms must
not be bought before it lands."*

From the moment the first token constant is added, nothing on this page may be edited except to record what
happened — and to keep its line references resolving against the tree the change lands in. Re-pointing a
citation is maintenance of a pointer, not a change to what was registered, and a pre-registration whose
references do not resolve is worse than one kept accurate.

## What is wrong today

`save()` (`internal/queuelab/submit.go:159`) swallowed every exception it could raise: its body ended
`except Exception: pass`. It is called once per iteration at `internal/queuelab/submit.go:284`, so every
failure it can have — a read-only mount, a full disk, a permission error, a missing directory — produced a
run **byte-identical to a successful one**.

That is not a tidiness problem. It is the failure mode that destroys the arms' reading, and it destroys it
in the direction nobody would question:

- **`E-resume` restores nothing** and reports having restored nothing. The comparison then shows the
  treatment arm doing what the control arm does, and the honest conclusion "resuming bought nothing" is
  exactly what a broken mount also produces.
- **`E-fresh` stops being the matched control.** The frozen arms page
  (`2026-09-21-the-resume-arms-and-what-they-contrast.md`) rejected contrasting `E-resume` against
  `A-ignore` precisely because the two would differ in **two** things — whether progress is restored and
  whether it is recorded at all. `E-fresh` exists to hold the recording fixed. A silently failing write
  makes `E-fresh` the arm that paid no write cost, which is the second axis coming back under a different
  name.

A null result and a broken apparatus must not be the same document.

## Why the existing vocabulary cannot carry it

The parser checks `kind` and `dev` **against each other** at `internal/queuelab/provenance.go:409`, and its
`default` arm drops the whole message. So:

- A new `kind` token for a write failure falls into that `default` and the message is discarded entirely —
  losing the iteration count, the accumulator and the resume point along with it.
- A new `dev` token pollutes `deviceStatuses` (`internal/queuelab/provenance.go:320`), a closed set whose
  members are read at the record layer to decide what the *card* did. A storage failure is not a device
  status.

**A seventh message field is the only honest place.** The arity rule at
`internal/queuelab/provenance.go:394` widens from `3..6` to `3..7`.

## What will be built

### 1. A seventh field, `saved=<token>`, over a closed set

Three tokens, constants on the Go side for the reason `DeviceNotAttempted` is one — they cross a language
boundary, and a rename on one side must not silently become an unknown status:

| token | means |
|---|---|
| `not-attempted` | the workload was given no state path, so it never tried to write |
| `ok` | every write it attempted succeeded |
| `failed` | at least one write raised |

**The failure is sticky.** Once any `save()` raises, the token stays `failed` for the rest of the run even
if later writes succeed. A volume that failed once and then worked is a volume at its limit, and a resume
arm measured on it is not a clean reading. This repository's rule is that a plausible wrong number is worse
than a refusal, so the over-strict direction is the correct one.

**Absence keeps its meaning.** A six-field message is a message from a build that could not report this,
exactly as a five-field message is one that could not report a resume point.

### 2. `recordSchemaVersion` 21 → 22

`cmd/queuelabrun/record.go:161`. The tripwire in `readableUnderCurrentSchema`
(`cmd/queuelabrun/record.go:1629`) moves with it, which withdraws every backward-read exception and forces
each one to be re-decided. Registered now, so the decision is not made under the pressure of a red test:

| version | readable when |
|---|---|
| 18 | no observation, no accumulator, no resume point, **no save status** |
| 19 | no accumulator, no resume point, **no save status** |
| 20 | no resume point, **no save status** |
| 21 | **no save status** (new case) |

The twelve committed `ex/e17-*.json` are all schema 18 and carry none of these, so they stay readable. That
is asserted, not assumed: `TestEveryRunRecordDecodesUnderThisBuild` is the check, and the schema-20 defect —
a blanket refusal of the very version that introduced a field — is the mistake this table exists to avoid
repeating.

### 3. Two refusals, not a weaker reading

Both sit beside `checkpointingArmStayedOffTheDevice` (`cmd/queuelabrun/record.go:1793`) and are scoped the
same way: by asking the **protocol** whether this arm checkpoints, never by naming arms.

**`checkpointingArmActuallyWrote`** refuses a record whose arm checkpoints and whose ledger holds an attempt
reporting `saved=failed` or `saved=not-attempted`.

**`restoringArmActuallyRestored`** closes the read side, which the write evidence does not reach. If the
replacement Pod's mount is missing, every write succeeded and the successor still restores nothing: it
reports `resumed=0`, and `resumeSupportedByLedger` (`cmd/queuelabrun/record.go:1738`) skips events whose
resume point is zero. So for an arm whose victim has `Restore` set, an attempt that has an earlier stopped
attempt of the same row reporting `iterations > 0` must itself report `resumed > 0`.

The two compose, and that is why both are needed. Either the predecessor's write failed — refused by the
first — or it succeeded and the successor must have read it.

They are refusals rather than a new validity axis, and that is a decision rather than an economy. The
work-check axis exists because a reader *classifies* on a spectrum of "verified / mismatched / unavailable".
There is no such spectrum here: for a checkpointing arm, a checkpoint that was not written is not a weaker
reading of the experiment, it is a different experiment. That is the same argument
`checkpointingArmStayedOffTheDevice` makes for the device path.

### 4. One comment corrected in the same change

`cmd/queuelabrun/record.go:1726` justifies the deliberately loose `>=` bound in `resumeSupportedByLedger` by
citing that *"the workload's save() swallows its own exceptions"*. **The bound stays; its stated reason is
wrong and is corrected.** The real reason is that the loop keeps running after the last successful write, so
a state file legitimately lags the message its writer went on to print by up to one iteration. That is true
whether or not failures are swallowed, and it stays true after this change.

## What this does NOT establish

**The field is the workload's own claim about itself.** The termination message is a channel the workload
controls, and a workload that reported `saved=ok` while writing nothing would not be caught here. Nothing in
this design is a defence against a lying workload; it is a defence against a *silent* one.

**`saved=ok` does not mean the successor could read the file.** It means the writes the process attempted
returned without raising. The read side is covered by the second refusal above, and only for arms that
restore.

**A volume that binds, accepts writes and then loses them is not caught.** Neither refusal observes the
storage; both observe what the workload said about it.

**No smoke probe lands with this.** Nothing yet confirms on a real cluster that two successive Pods see the
same file. That remains owed, and when it is written it must select the worker by label and tolerate the lab
taint — never through `probePodFrom`, which sets `spec.nodeName` and so defeats `WaitForFirstConsumer`
binding.

## What this page does not settle

**No threshold, and no outcome space.** Those belong to
`2026-09-21-the-resume-arms-and-what-they-contrast.md`, which is frozen and already fixes the repetitions,
the interleaving and the stopping rule. Nothing here changes any of them.

**Whether the arms are worth buying.** This page states what must be true for their record to mean anything.
It does not argue that the reading will be interesting.
