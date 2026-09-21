# The claim exists and the class is named — item 3, and what it does not buy

Date: 2026-09-22, written with the code that implements it and **before any card is bought for the resume
arms.**

This page closes item 3 of `2026-09-21-the-resume-arms-and-what-they-contrast.md`, which is frozen, so this
is a new page rather than an edit — the same way `2026-09-21-item-two-could-not-be-refused-at-submission.md`
recorded what happened to item 2.

Its item 3 said:

> **Somebody must create the claim, and the storage class must be named.** … A run that creates a claim with
> no `storageClassName` has chosen the cluster default by omission … The run protocol must state which class
> it asks for and refuse a cluster that cannot provide it, rather than letting an unbound claim surface as a
> victim stuck Pending.

**This one was implementable as written, and is implemented as written.**

## What now happens

`queuelab.StateClaim` renders the claim and **refuses to render one without a class.** There is no default
anywhere in the path: the flag defaults to empty, the renderer errors on empty, and the two arms that need a
claim are refused before the cluster is touched if the operator did not name one.

The refusal is in both directions. `stateRequestFor` refuses a checkpointing arm with no `-state-class`, and
also refuses `-state-class` given with an arm that checkpoints nothing — the second because a flag that
creates nothing and says nothing is the failure `decideOperatorMode` already refuses for its own run-only
flags: the invocation looks configured to its author while doing none of it. `-state-class` is in
`runOnlyFlagNames`, so typing it alongside a recovery mode is refused too.

On the cluster the two failures are reported apart, and the split is the point:

| What went wrong | Disposition | Where the operator looks |
|---|---|---|
| The named class does not exist | `environment-unqualified` | the cluster |
| The Create of the claim failed | `setup-failed` | this run |

The class is read **before** the claim is created and before the fixtures are applied, so a cluster that
cannot host the measurement is refused while the only thing to tear down is the namespace.

`sameMechanism` gained a `PersistentVolumeClaim` branch. It compared nothing for this kind before — it fell
through to `nil` — so a claim left by an earlier attempt **under the same transaction** would have been
adopted whatever class it was made with, and a rerun with a different `-state-class` would have recorded one
class's binding behaviour under another's name. Size and access mode are deliberately not compared: the file
is one short line, and parallelism is pinned to 1.

## Which class — this page does not choose one

**The operator names the class; this page names no default and the code has none.** That is the same refusal
`api/v1`'s `StateVolume` makes for the API, for the same reason: no provisioner for a GPU cluster is recorded
anywhere in this tree, and the only binding behaviour anything here has measured is kind's local-path.

What the operator must know when choosing:

- **`WaitForFirstConsumer` is the safe binding mode for this lab.** The lab pins every trace Pod to one
  tainted worker through the flavour's node selector and tolerations. A class that binds `Immediate` can
  bind the volume to some other node, and then the victim is unschedulable for the whole horizon — which
  reads as a preemption that never recovered. kind's local-path is WFFC and happens to solve this by
  binding wherever the first consumer lands.
- **`reclaimPolicy` decides whether the storage costs money after the run.** See the next section.

## What this does NOT buy, stated plainly

**A class that exists is not a promise that provisioning succeeds.** A broken CSI driver, an exhausted quota
or a zone with no capacity all leave a claim that is accepted and never binds. The check removes the one
failure knowable before the run; it says nothing about the rest, and a victim can still sit Pending.

**Namespace deletion is not backend cleanup.** The claim dies with the run's namespace, which is why teardown
does not enumerate it — `emptyObjectFor` knows only `Namespace`, `ClusterQueue` and `ResourceFlavor`. But the
PersistentVolume behind it, and the disk behind that, are governed by the class's `reclaimPolicy`. Under
`Delete` they go; under `Retain` they stay, and they keep costing money after every run, invisibly, because
nothing in this repository looks at them. **An operator running the resume arms repeatedly on a `Retain`
class is accumulating volumes nothing here will ever remove.** That is a fact about the class they chose, and
this page is the only place it is written down.

**There is still no evidence the checkpoint was ever written.** `save()` swallows its exceptions
(`except Exception: pass`), by design, so a read-only volume or a full disk produces a run that looks
identical to a successful one. `E-resume` would then restore nothing and be reported as having resumed
nothing — the null result, indistinguishable from the real one. Closing this needs a seventh message field
and `recordSchemaVersion = 22`, because the parser's cross-token rule between `kind` and `dev`
(the `switch` at `internal/queuelab/provenance.go:355`, whose `default` drops the whole message) refuses a
message that reports a write failure in either existing vocabulary. **That is the next branch, and the arms
must not be bought before it lands.**

**There is no smoke probe.** Nothing yet confirms on a real cluster that the class binds and that two
successive Pods see the same file. When it is written it must select the worker by label and tolerate the
lab taint — it must NOT use `probePodFrom`, which sets `spec.nodeName` and bypasses the scheduler, because
that is exactly what defeats `WaitForFirstConsumer` binding.

## What this page does not change

Items 1, 2, 4 and 5 are closed (#229, #232 with its amendment, #234, #230). Nothing here touches the arms'
contrast, the device gate or the canary.
