# Measuring the duty the workload actually slept — pre-registration

**Written 2026-09-28, before any of the code below exists.** From the moment the workload's report grows an
eighth field, nothing on this page may be edited except to record what happened.

Two duty guards in `internal/queuelab` were narrowed on 2026-09-28 (PR #298) to stop claiming what they do not
measure. They now assert an operational ceiling on reported launch counts and an ordering by declared duty, and
they say plainly that they do not measure the fraction of time spent sleeping. This page registers the change
that makes the measurement real, and what must be true for it to count.

## What is missing today, stated precisely

`submit.go:216` has the workload print its **configured** duty:

    def msg(): return "iters=%d kind=%s dev=%s duty=%g acc=%.17g resumed=%d saved=%s"%(...)

`duty` there is `sys.argv[3]`, parsed at `:135` and never touched again. Carrying it and checking it proves
**configuration provenance** — the value reached the workload — and nothing about how the workload spent its
service. A workload whose `time.sleep` were deleted would report the same `duty=0.5` while sleeping none of it.

That is exactly the mutation used to test the narrowed guards, and it is why they are guards and not
measurements.

## The claim this change may make, and the ones it may not

The figure registered here is **wall time spent inside the workload's own sleep calls**, over an elapsed window
the workload also measures. It is named that and nothing shorter.

It is **not** GPU utilisation. Its complement is **not** measured device compute time: the remainder of the
window includes descheduling, sleep overrun, interpreter overhead and kernel-launch latency, none of which this
instrument separates.

And the measured fraction is **not required to equal the requested duty**. Replacing a brittle count ratio with
an equally brittle demand that observation match configuration exactly would be the same defect wearing a
better name. The registered comparison is a tolerance band, and what the band is gets decided below.

## The failure a reviewer should hunt for

**Accounting for intended sleep instead of performed sleep.** The line

    sleep_total += (1.0-duty)*PERIOD

would reproduce today's defect under a convincing field name, and it is not a hypothetical: `submit.go:289`
already computes that quantity as the argument to `time.sleep`, and it is **wrong even as an intention**,
because the call is `time.sleep(min((1.0-duty)*PERIOD, rest))` — the final segment is clamped by the remaining
window and sleeps *less* than the expression. Summing the intention would overcount exactly at the boundary the
guards cannot see.

The accumulation therefore reads the monotonic clock on **both sides of the actual call**, and the diff is what
is added. Nothing derived from `duty` may appear in the accumulated total.

## The second failure, which is specific to this repository

`cmd/queuelabrun` predicts the workload's arithmetic by **parsing the shipped script with a regular
expression**: `accumulatorStepPattern` in `internal/queuelab/oracle.go` matches

    for _ in range(50000): x=(x*1.0000001)%1000000.0

and `ScriptAccumulatorParams` returns an error if it does not match. `checkReportedWork` then answers
`workUnavailable` — **a verdict that silently disappears rather than a test that goes red**. Editing the
workload's inner loop by one character, or inserting a line that breaks that statement's shape, withdraws the
oracle from every CPU-path run while the suite stays green.

So this change must leave that statement byte-identical, and the spec must prove it did. The timing code goes
around the loop, never inside its statement.

## The chain, link by link

**1. The workload measures two quantities and reports them.** Elapsed window and accumulated sleep, both from
`time.monotonic()`, both printed as new fields. The final idle segment is included: a run that ends inside its
last sleep must have that sleep in both totals, which is the case the launch-interval alternative could not see
(the last idle stretch has no following launch, so an ideal half-duty workload reads as 1/3 by intervals).

**2. The message goes to eight fields, and this overturns an assertion made deliberately.**
`provenance.go:394` refuses `len(fields) > 7`, and `provenance_test.go:500` asserts that
`"iters=900 kind=cpu-float dev=no-libcuda duty=1 acc=1.5 resumed=0 saved=ok extra=1"` is refused. That row was
written on purpose. **This change overturns it**, the same way `2026-09-21-the-resume-arm-chain.md` registered
the sixth field's overturn in advance. What survives unchanged is the rule the row exists for: a field this
build cannot read refuses the count beside it.

The widening must move **both** bounds. `:439` records what happens otherwise — widening the arity for the
seventh field without widening the `>= 6` guard skipped the resume point on every seven-field message, value
present and parsed nowhere, and the spec that caught it only did so because one message happened to be shorter.
`len(fields) == 7` becomes `>= 7` in the same edit.

Every older arity keeps reading. The 47 literal messages in `provenance_test.go` and the five three-field
messages in `cmd/queuelabrun/device_preflight_test.go` are the evidence for that, and `"iters=9"` must still be
refused as an unreadable wire format.

**A second assertion is overturned, and it was not in this page's first draft.**
`submit_test.go:643` requires the script to contain `resumed=%d saved=%s"` — the message's literal tail — and
its comment states that the save status **must be the last field**, because the parser reads by position and a
seventh field that were not `saved=` would make every message unparseable. That reasoning stays correct about
positions one through seven; what it gets wrong is treating "last" as the property being protected. The new
fields go **after** `saved=`, so every existing position is untouched and `parseSavedField` keeps reading index
six. The assertion and its comment are rewritten to pin the positions they actually depend on, and the rewrite
is the overturn.

**And the script's own bytes are part of the canary key, which this page's first draft also missed.**
`sleeperCommand` renders the workload into the container's argv as `python3 -c <script>`, and
`cmd/queuelabrun/canary.go:222` fills `canaryKey.HonorCommand` and `IgnoreCommand` from `Spec.Command`. So a
single character changed in the script moves both — the mechanism `submit.go:116` describes when it says
changing the workload forces a re-take. Nothing in the tree carries a committed canary value to edit (the
canary is rendered at run time from this same renderer), so the cost is a re-take before the next qualified
run, not a fixture to update. It is recorded here because a change that moves a qualification key silently is
the shape of defect this page exists to prevent.

**3. The ledger carries the observations, and absence is not zero.** `LifecycleEvent` gains pointer fields
beside `DutyCycle`, so a record from a build whose workload could not measure reads as **unmeasured** rather
than as measured zero. A full-duty run that genuinely slept nothing must stay distinguishable from a run that
did not measure: the first reports a measured zero, the second reports nothing.

**4. `recordSchemaVersion` goes 22 → 23, and the tripwire moves with it.**
`readableUnderCurrentSchema` opens with `if recordSchemaVersion != 22 { return false }`, which withdraws every
exception the moment the constant moves. Its comment says to keep it on the next bump, and this is that bump. A
fifth case arm is added for 22, on the premise that a 22 build could not report these observations, and the
premise is enforced by inspecting the events rather than assumed — `DisallowUnknownFields` cannot catch a
relabelled newer record, because decoding uses today's struct where the field is known at every version.

The twelve committed `ex/e17-*.json` documents declare `schemaVersion 18` and must keep decoding. They are the
runs this repository's pages quote, and orphaning them is the specific accident this tripwire exists to
prevent: it happened once, when bumping to 20 silently withdrew an exception spelled `!= 19`.

**5. The two narrowed guards are replaced rather than tightened.** Both execute the rendered production
command. One verifies the CUDA-shim path explicitly, the other forces and verifies the CPU fallback, so that
neither can pass by having taken the path it was not written for — which is the defect the device test's own
comment records about its CPU twin.

## What must be shown, and recorded as outcomes rather than as "tests passed"

Three controls, each of which must be run and its result written into the change:

1. **Replace only the sleep operation with a no-op**, leaving the timing and reporting code intact. The
   ordinary rendered artifact must pass; this mutant must fail, because observed sleep collapses while the
   reported configuration does not change. This is the control the count-ratio guards fail twice out of two
   runs at the margin and once out of two on ordering.
2. **A run that ends after its final idle segment.** That segment must appear in the accumulated sleep and in
   the elapsed window. A measurement that closes its window before the last sleep would report a high duty for
   a workload that idled, and nothing in the old assertions could see it.
3. **Remove the timing fields from the message.** The result must be **measurement absent** — not a passing
   duty check, and not a measured zero. A full-duty run with an explicitly measured zero sleep must remain
   distinguishable from this case in the record.

The oracle control is a fourth, and it is not optional: `ScriptAccumulatorParams` must still find the
accumulator loop after the edit, asserted directly rather than inferred from a green suite, because its failure
mode is a withdrawn verdict.

## What this page refuses

**No tolerance is chosen here.** What band between measured and requested duty counts as agreement is decided
after the instrument is shown to work, on its own dated page, and before any arm comparison uses it. Choosing
it now — knowing which way the existing runs lean — is what pre-registration exists to prevent.

**No paid run.** The measurement runs locally and rents nothing.

**No change to the eligible population, the arms, or the existing waste arithmetic.** This adds an observation
and a schema version. `DutyCycle` keeps meaning what the workload was configured for, under its existing name,
and the measured quantity arrives beside it under a different one. Nothing already recorded is reinterpreted.

**No claim that the old guards were wrong to exist.** They are an operational regression guard on reported
counts and stay useful as that. What this change removes is the gap between what they check and what a reader
would assume they check.
