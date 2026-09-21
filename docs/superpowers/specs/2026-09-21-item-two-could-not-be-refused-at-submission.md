# Item 2 could not be refused at submission — what was done instead

Date: 2026-09-21, written after the arms landed (#230) and **before any card is bought for them.**

This page records what happened to item 2 of `2026-09-21-the-resume-arms-and-what-they-contrast.md`. That
page is frozen — its own rule, and the arm constants now exist — so this is a new page rather than an edit,
the same way `2026-09-21-the-resume-arm-chain.md` amended a frozen page before it.

Its item 2 said, and still says:

> **The device path must be refused at submission, not reported as unavailable.** … for these two the verdict
> *is* the measurement, so a device-path run of them must be refused before it is submitted.

**The requirement as written is not implementable, and the reason is not a missing feature.**

## Why nothing at submission can know

Whether the workload takes the device path is decided by one thing: whether `ctypes.CDLL("libcuda.so.1")`
succeeds inside the container, and then whether init, device, context, module, allocation and a probe launch
all succeed after it. Every one of those is a fact about the NODE — its driver and its container toolkit —
discovered by the container after it starts.

Nothing the runner holds at submission predicts it:

- `GPUCount` is 1 or 2 for all three trace rows always, and on kind the same numbers are served by a fake
  device plugin. The GPU request does not distinguish a real card from a simulated one.
- `-require-device` is a DECLARATION that device evidence is this run's deliverable, not a fact about the
  path. A run without it can still land on a node with a working driver.
- `devicePreflight` probes the selected worker, but its result describes the probe. A probe that failed does
  not establish that a later victim cannot reach the driver.

## What was done instead

**The path was made unreachable rather than predicted.** The workload skips the driver entirely when it is
given a progress file:

```python
launch=None if state else cuda()
```

Gated on the state path and not on the resume flag, so `E-fresh` is held to the CPU path too. Gating on the
flag would leave the control arm eligible for CUDA while the treatment arm was not, and the pair's entire
value is that the two differ in one thing.

Measured, not argued. With the same fake driver on `LD_LIBRARY_PATH` and the same rendered command, only the
state path differing:

```
state=""   ->  iters=908050  kind=cuda-fma   dev=ok
state=set  ->  iters=685     kind=cpu-float  dev=not-attempted
```

`dev=not-attempted` is the point: the driver is not reached and failed, it is not reached at all.
`TestACheckpointingWorkloadNeverReachesForTheDriver` asserts both halves against the same shim, so a day when
the fake driver stops loading fails the precondition rather than passing the conclusion.

**A second, weaker check sits in the record decoder.** `checkpointingArmStayedOffTheDevice` refuses a
document whose arm checkpoints and whose ledger shows any attempt reporting `cuda-fma`. It is a safety net
for records read by builds other than the one that wrote them, not the mechanism.

It sweeps the LEDGER rather than reading `measurement.workload.kind`, and that is not redundancy. That field
is derived from one attempt — the one `VictimAttemptUID` picks as ending the hold — and a resumed row has
several, so a later attempt that reached the driver would not appear in it at all. The review that found this
is the reason the check is written the way it is.

## What this costs, stated plainly

**The registered requirement is not met as written, and this page does not pretend otherwise.** A device-path
run of these arms is not refused before submission; it is made impossible to produce, and refused on the way
into the record if one ever appears. Those are different guarantees. The one that was registered would have
caught a mis-configured invocation before the cluster was touched; what exists catches a mis-built workload
at the point it would enter the evidence.

**The command changed again**, so `canaryKey.HonorCommand` and `IgnoreCommand` move and every qualification
taken before this is re-taken once — already owed from the moment any arm rendered a state path.

**One thing is deliberately NOT done.** A device-path run of the resume arms is not invalidated mid-flight.
`soleTerminated` reads a terminated container's status, so the workload's kind is observable only after an
attempt stops; aborting on the first CUDA report would need live telemetry this harness does not have, and
building it to save a run that the gate above already makes impossible is work with no reading behind it.

## What this page does not change

Items 3 and 4 stand exactly as registered: the claim must be created and its storage class named, and the
canary must learn the resuming command. Nothing here touches them.
