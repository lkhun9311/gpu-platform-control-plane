# Stage C — the resume arm, pre-registered

**Written 2026-09-21, before any line of the resuming workload exists.** Stage C was designed in
`2026-08-16-queuelab-workload-occupancy-design.md:155` and never built. This page does not redesign it. It
registers what building it **costs**, because the cost is not code: it is the validity of measurements this
repository has already taken, and that is a thing to declare before the first template byte changes rather
than to discover in a report afterwards.

From the moment the Pod template changes, nothing on this page may be edited except to record what happened.

## What Stage C is, unchanged from its design

> A resuming arm writes progress to a volume and restarts from it. The interesting property is that it needs
> an oracle: the run must be able to say the resumed work is the *same* work, not merely work of the same
> shape. A final hash over the computed result gives that — an arm that resumed correctly produces the hash a
> run that was never preempted produces.

The motivating measurement is that page's too: `A-honor` loses **40.8 GPU-seconds of progress even though it
stopped politely**, because the row re-executes from zero. Today's platform discards everything a preempted
workload did, and the politeness of its shutdown changes nothing about that.

## What it costs, stated before it is spent

Four things break, and none of them is a bug. They are the instrument working.

**1. The record schema goes 19 → 20.** `cmd/queuelabrun/record.go:136` holds `recordSchemaVersion = 19`.
The convention for a bump is visible at `:1490`: the prior version is admitted only under a narrow condition,
and a document that already carries the new field is **refused**, because re-running today's judgement over it
would reach a verdict its run never took. Stage C's bump inherits that shape.

**2. Every termination canary is re-taken.** `canaryKey.PodTemplateHash` is a SHA-256 over the whole
`PodTemplateSpec`, marshalled to JSON (`cmd/queuelabrun/canary.go`). A single argv character changes it.
`sleeperCommand`'s own comment says why that matters: "two spellings of the same experiment would need two
canaries and would compare as different mechanisms. One spelling." So the resume arm cannot be a quiet
variant — it is a new template, and every node's qualification expires with it.

**3. Runs taken before the change stop being comparable.** The design's Risks section already made this
argument for Stage A: the record's schema version is what marks the boundary, and pre-change runs measured a
different thing. The count of affected runs is **25 as of 2026-08-16**, quoted from that page rather than
measured here — run records live outside this repository, so this page cannot count them and does not pretend
to.

**4. The canary's residual grows, and this is the one the design did not name.** `record.go:333` states the
protection — the controller "cannot change it without invalidating every reading taken before the change" —
and `:338` states its limit: "what is left is the reconcile loop and the Job controller", because the probe
Pod is created by that tool directly. The refusal a run meets spells the same thing out at `:356`: "nothing
here submits an MLTrainingJob, so Kueue admits nothing and no Job creates" the Pod. A resume arm needs a
**volume**, and `BuildJob`
(`internal/controller/mltrainingjob_controller.go:152`) renders none — `MLTrainingJobSpec` has no field for
one. Attaching it is a change to the controller path, which is precisely the part the canary does not probe.
**The gate that protects every other template change does not protect this one.**

## The oracle has a limit, and it must be written down now

The obvious oracle is already in the workload. `internal/queuelab/submit.go:211` seeds `x=1.0` and `:217`
advances it by `x=(x*1.0000001)%1000000.0`, 50,000 times per iteration — a deterministic function of the
iteration count alone. A resumed run that reaches the same `n` should hold the same `x`.

**It is CPU-only.** On the device path the loop calls `launch()` and never touches `x` (`submit.go:213-222`);
the arithmetic happens in a GPU buffer the script does not read back. So an `x`-based oracle proves resumption
on the CPU fallback and proves **nothing at all** on a real device, where it would report the seed value on
both arms and agree for the wrong reason.

Two options follow, and this page picks the second:

- Read the device buffer back and hash that. It makes the oracle work on both paths, and it adds a CUDA
  memcpy to a workload whose whole constraint is that it must run *without* a device.
- **Register Stage C as CPU-path only, and refuse a device-path resume verdict** until an oracle exists that
  covers it. A refusal is the move this repository already makes when a reading cannot be established —
  `must_promq`, the canary gate, the `ABSENT` reporting in `check-prometheus-rules.sh` — and it is cheaper to
  state the limit now than to explain a GPU-session result that was never oracle-backed.

## What this page does not settle

The study itself. Arms, rungs, repetitions, stopping rule and outcome space are a separate pre-registration,
written when the arm exists and before any card is bought for it. This page exists so that the work of
building the arm begins with its invalidation boundary stated rather than inferred.

## What this page costs

Nothing. Every fact above was read out of the working tree, and the one number it could not read — how many
historical runs exist — is quoted with its source and its date instead of guessed.
