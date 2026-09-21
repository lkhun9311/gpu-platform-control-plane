# The resume arms — what they contrast, pre-registered

**Written 2026-09-21, before any arm exists in `internal/queuelab/protocol.go` and before any card is bought.**
`2026-09-21-stage-c-resume-arm-pre-registration.md:86` reserved exactly this page: *"Arms, rungs, repetitions,
stopping rule and outcome space are a separate pre-registration, written when the arm exists and before any
card is bought for it."* The storage and reporting halves have landed (#225, and #227 awaiting `dev`), so the
arm is now the only thing left, and this is the page that must precede it.

Two independent reviews were taken before writing this — one from codex `gpt-6-astra`, one from a separate
agent — on a brief that offered the two designs the author had in mind. **Both rejected both**, for the same
reason, and that agreement is why this page exists rather than a commit. Every claim either review made has
been checked against the tree below; the ones that did not survive are not repeated here.

From the moment the first arm constant is added, nothing on this page may be edited except to record what
happened.

## The design that was proposed, and why it is wrong

The proposal was to add one arm, `E-resume`, and contrast it against the existing `A-ignore` — identical, it
was argued, except that the victim resumes.

**They are not identical except for resuming.** The workload's checkpoint is gated on the state path being
non-empty (`internal/queuelab/submit.go:142` restores, and the writer runs at
`internal/queuelab/submit.go:248` as `n+=1; acc=x; save()` — **once per iteration**, each time an `open`, a
`write`, an `fsync` and an `os.replace`). An arm rendering an empty path performs none of that. So the
contrast would carry two differences at once: whether progress is **restored**, and whether progress is
**recorded** at all. A difference in discarded work between them could be either, and nothing in the record
would separate them.

That is the same defect the idling study was arranged to avoid. `D-full` and `D-quarter` hold the termination
contract fixed precisely so that duty is the only thing that moves (`internal/queuelab/protocol.go:105`), and
the comment above them says why: two axes at once give four cells and a difference that carries both.

**The cheaper-looking option was not available either.** Reusing the twelve committed `ex/e17-*.json` as the
contrast fails on the lab's own rules. Their canary key records the arm's rendered argv, and those records
carry five elements — `["python3", "-c", <script>, "600", "ignore"]`, with no duty argument — taken at
`qualifiedAt: 2026-08-22T07:40:27Z`. Duty has been added since, and the state path is being added now.
`keyDifferences` (`cmd/queuelabrun/canary.go:677`) compares the honouring and ignoring commands as strings, so
a run standing on that qualification is refused before it starts. The reuse was never an option; it only
looked like one.

## The arms

**`E-fresh` and `E-resume`, a matched pair, differing only in whether the state file is READ.**

Both victims mount the volume. Both write the checkpoint every iteration. `E-fresh` is started with its state
directory empty on every attempt; `E-resume` is started with the directory preserved across the attempts of
one run. The rendered argv is identical between them — the difference is the state of the volume, not the
command.

This is what makes `E-fresh` more than `A-ignore` under a new name. An `E-fresh` victim pays the full
checkpoint cost and recovers nothing; an `A-ignore` victim pays nothing and recovers nothing. Only the first
is a control for the question being asked.

**The termination contract is fixed at the ignoring arm's, and duty at full**, for the reason `D-full` and
`D-quarter` fix theirs: a honouring victim stops in milliseconds and leaves the observer nothing inside the
hold (`internal/queuelab/protocol.go:90-91`). Reclamation stays enabled, so `PolicyVariant` is `Any` and
`AssertCardinality` expects the victim preempted exactly once (`internal/queuelab/protocol.go:130`) — the same
expectation every arm but `N-ref` carries. No change is needed there.

**Dose regime: `grace-bounded` only.** Under `self-completing` the victim has less service left than the grace
period (`internal/queuelab/trace.go:191`), so it finishes what it was doing and there is little discarded work
for a resume to recover. The quantity this pair exists to move is largest where the victim is cut off with
work outstanding.

## What must be built before a card is bought

**1. The oracle must require that a resume happened.** `ResumedTheSameWork`
(`internal/queuelab/oracle.go:144`) compares only `want == reported`; it never looks at the resume count, and
`checkReportedWork` (`cmd/queuelabrun/record.go:723`) passes it only the iterations and the accumulator. **A
victim that restored nothing and ran from zero passes this check.** For the existing arms that is correct —
they make no resume claim. For `E-resume` it is the whole reading, so a second judgment is needed: the
attempt after the first must report a resume point greater than zero, tied to what the previous attempt
reported holding. Without it, a broken mount is indistinguishable from a successful resume, and it fails in
the direction that publishes a number.

**2. The device path must be refused at submission, not reported as unavailable.** On the device path the
loop calls the kernel and never advances `x` — the CPU branch at `internal/queuelab/submit.go:243` is the only
writer — so the checkpoint holds the seed, and restoring it sets the iteration count `n` to the restored value
while restoring **no work at all**. The result is an inflated count that the accumulator check cannot
contradict. `checkReportedWork` answering `work-unavailable` after the fact is right for the arms that exist;
for these two the verdict *is* the measurement, so a device-path run of them must be refused before it is
submitted.

**3. Somebody must create the claim, and the storage class must be named.** Nothing in this repository creates
a PersistentVolumeClaim. Once #227 lands, `BuildJob`
(`internal/controller/mltrainingjob_controller.go:152` on this branch, which does not yet carry the volume)
references one by name and the canary names a sentinel it then strips. The comment on `StateVolume` says
the storage class is deliberately not chosen — **that is only true of the API**. A run that creates a claim
with no `storageClassName` has chosen the cluster default by omission, which on kind is local-path with
`WaitForFirstConsumer` and on a GPU cluster is whatever CSI driver happens to be installed, or nothing. The
run protocol must state which class it asks for and refuse a cluster that cannot provide it, rather than
letting an unbound claim surface as a victim stuck Pending.

**4. The canary must know the command the arms actually run.** `canaryContract` carries the honouring and
ignoring commands and claims at `cmd/queuelabrun/canary.go:142` that *"the probe runs the bytes the arm runs
by construction"*. That holds because `harnessTerminationContract` renders through the same function `submit`
does — but it renders with an empty state path, so an `E-resume` victim's argv matches neither recorded
command. Either the key gains the resuming command as a third field, or the claim stops being true silently.
The probe strips the volume already, in `probePodFrom`, so probing a resuming command costs no storage.

**5. The arm enumeration is two closed lists, not one.** `internal/queuelab/protocol.go` holds the constants
and `parseArm` (`cmd/queuelabrun/spine.go:125`) holds a second switch whose error message names all five arms
by hand. Both must grow together; a constant added to one and not the other is an arm that exists and cannot
be requested.

## Repetitions and the stopping rule

**Two runs of each arm, taken interleaved, and the pair is compared only if the interleaving held.**
`compare.go` already publishes whether the arms alternate in the order the runs were taken, and states that
when they do not, *"every difference below is confounded with time: node warming, image cache state and any
drift in the cluster all move together with the arm"*. Two runs taken back to back in the order
`E-fresh, E-resume` are confounded with exactly that. The order is therefore `E-fresh, E-resume, E-resume,
E-fresh` — four runs, two of each — or the comparison is not made.

**The stopping rule is that the pair either produces two valid records per arm or it produces none.** A run
invalidated for any reason the ledger already refuses is retaken, not dropped: dropping the invalid ones and
keeping the rest selects on the outcome.

**No threshold is chosen here.** This page registers what is measured and what would make the measurement
invalid. What counts as a difference worth reporting is the comparison's own business, and choosing it now,
knowing which direction the author expects, is the thing pre-registration exists to prevent.

## What this page does not settle

**Whether resumption is worth doing.** The pair measures what a checkpointing victim recovers when it is
preempted; it says nothing about whether the per-iteration `fsync` cost is acceptable in a real workload, and
the `E-fresh` arm exists precisely so that cost is visible rather than absorbed into the comparison.

**The GPU cluster's storage.** Point 3 requires the run protocol to name a class and refuse a cluster that
cannot provide it. It does not choose one, because no provisioner for a GPU cluster is recorded anywhere in
this tree and choosing one from a kind cluster's behaviour is the inference this lab refuses elsewhere.

**Anything about the device path beyond refusing it.** A resuming device workload would need the kernel's
buffer checkpointed, which is a different piece of work with a different oracle.

## What this page costs

Nothing yet. No code changes with it. Its cost arrives when the arms are added: two closed lists grow, the
canary key gains a field and every qualification taken before it is re-taken, and four paid runs are bought
rather than one.
