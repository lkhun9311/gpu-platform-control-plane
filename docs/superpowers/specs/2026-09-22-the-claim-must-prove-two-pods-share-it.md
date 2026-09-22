# The claim must prove two Pods share it — pre-registered

**Written 2026-09-22, before the probe exists and before any card is bought for the resume arms.** It is the
last thing the two pages before it left owed:

> **No smoke probe lands with this.** Nothing yet confirms on a real cluster that two successive Pods see the
> same file. That remains owed, and when it is written it must select the worker by label and tolerate the lab
> taint — never through `probePodFrom`, which sets `spec.nodeName` and so defeats `WaitForFirstConsumer`
> binding.
> — `2026-09-22-the-checkpoint-must-say-whether-it-was-written.md:132`, and the same constraint at
> `2026-09-22-the-claim-exists-and-the-class-is-named.md:87`

From the moment the first probe constant is added, nothing on this page may be edited except to record what
happened — and to keep its line references resolving against the tree the change lands in.

A second engine reviewed the design before this page was written. Three of its corrections are load-bearing
below and are marked where they land; every claim it made was checked against the code rather than taken on
its word.

## What is missing

Two runtime refusals now exist for the resume arms: a checkpointing arm whose row reports a failed write is
refused, and a restoring arm whose successor restored nothing from a predecessor that had something is
refused. Both read the LEDGER. Neither has ever been shown to pass on a cluster, because **nothing in this
repository has ever mounted a real claim twice.**

The gap is admitted in the code that causes it. `probePodFrom` (`cmd/queuelabrun/canary_apply.go:198`)
strips the state volume from every probe Pod and says so: *"What a run's Pod does with the volume is
therefore NOT probed."* So the entire storage path — does the named class bind, does a replacement Pod get
the same volume, does a byte written by one Pod reach another — is unexercised, and the first thing to
exercise it would be a paid run.

## What the probe establishes, operationally

**Not "the class works".** That is too broad to fail honestly, and naming it that way was the first thing the
review rejected. The probe passes only when all of these hold together:

1. A claim of the run's own shape binds: same class as `-state-class`, same capacity (`StateClaimSize`,
   `internal/queuelab/submit.go:402`), same access mode, and the mount comes from the REAL renderer rather
   than being constructed here.
2. A **writer** Pod runs on the intended worker and writes a payload unique to this probe invocation.
3. That writer **completes and is gone** before the reader is created.
4. A **reader** Pod, with a different Pod UID, bound to the **same PVC UID**, reads back exactly that
   payload.

Point 4's two identities are the review's correction and both are checked: a reader that happened to bind a
different volume, or a payload that a previous probe's residue could satisfy, would otherwise pass. The
payload is unique per invocation for exactly that reason.

## What the probe must not do, and why each one is a trap

**It must not use `probePodFrom`.** That function pins `spec.NodeName` (`cmd/queuelabrun/canary_apply.go:293`),
which removes the scheduler — and `WaitForFirstConsumer` binding is a SCHEDULER decision. A probe that
bypassed it would report success on a binding mode the run will never use. Placement is instead a node
selector on `workerLabelKey` plus a toleration matching the taint `withOwnershipTaint`
(`cmd/queuelabrun/ownership.go:485`) installs, both carrying the probe's own run id.

**It must not wait for the claim to bind before creating the writer.** Under `WaitForFirstConsumer` there is
no first consumer until a Pod is scheduled, so waiting first is a deadlock. The claim is created Pending and
the writer is what binds it.

**It must not treat `ReadWriteOnce` as succession.** That mode permits two Pods on the same node
simultaneously; it does not order them. Point 3 above is enforced by observing the writer's terminal state
and then its absence, not by assuming the delete took effect. `BuildJob` renders `RestartPolicy: Never`
(`internal/controller/mltrainingjob_controller.go:167`), so a completed writer stays completed.

**It must not hold a device.** The rendered template asks for `nvidia.com/gpu`
(`cmd/queuelabrun/qualify.go:40`); the probe strips it. A storage probe that took a card would contend with
the very runs it is clearing the way for.

**It must not report "cleanup was called" as "cleanup finished".** The existing release helper
(`cmd/queuelabrun/canary_apply.go:567`) reports failures and returns once a deletion is accepted; acceptance
is not absence. Probe success and cleanup completion are reported as two separate outcomes, and an
unresolved leftover must never be printed as a restored worker.

## The worker is acquired

Through the ordinary ownership transaction, as the device preflight does. A storage probe uses no GPU, but it
consumes node-local volume attachment capacity, CSI activity and filesystem I/O, any of which can perturb a
live run's checkpoint timing without either side failing.

**Acquisition does not make a binding failure unambiguous**, and this page does not claim it does. The
transaction excludes other invocations of this harness; it does not isolate the storage backend, and
`NoSchedule` evicts nothing already running. So: a busy worker means the probe is not performed; a failure
names the stage it failed at; a pass claims nothing about global isolation.

## Which claim

**Its own, in the probe namespace** — `queuelab-canary` (`cmd/queuelabrun/canary.go:88`), which is shared by
every probe, accepted when someone else created it, and never deleted.

The claim's NAME is the run's own (`StateClaimName`, `internal/queuelab/submit.go:394`) and that is not a
collision. PersistentVolumeClaims are namespaced: `queuelab-state` in `queuelab-canary` and `queuelab-state`
in a run's namespace are different objects with different UIDs, and a Pod resolves the name within its own
namespace. **An earlier draft of this design treated the shared spelling as contamination and was wrong**;
the review corrected it, and the correction is what lets the probe render through the real path instead of
constructing a parallel one.

Measured, not assumed — the renderer produces, for the probe's own identity and namespace:

```
CLAIM ns=queuelab-canary name=queuelab-state class=<the named class>
TPL volumes=[{"name":"state","persistentVolumeClaim":{"claimName":"queuelab-state"}}]
TPL mounts=[{"name":"state","mountPath":"/queuelab-state"}]
```

## The flag

`-state-class` is currently in `runOnlyFlagNames`, which refuses it beside ANY operator mode. The probe needs
it, so it gains a second legitimate consumer.

**The invariant being preserved is not "this flag belongs to runs".** It is that every explicitly supplied
flag is either consumed or refused — the same rule the device flags follow, belonging to `-device-preflight`
and to a run and refused everywhere else. Removing `-state-class` from the refusal without giving it a new
consumer would be a regression; giving it one is not.

## What this does NOT establish

**It is not a preemption test and not a durability test.** Two sequential Pods on one healthy node establish
the storage path. They do not establish survival across node failure, cross-node reattachment, or
interruption in the middle of a checkpoint replacement. The arms' own runs are what exercise preemption.

**A pass is about this worker, this class, at this time.** It is not a promise about a later allocation, a
different namespace's admission behaviour, or the eventual run.

**It does not verify the run's own claim.** The probe's claim is a different object. Verifying the actual
claim a run will use would mean Pods in the run's namespace before its trace is submitted, and the collector
refuses a non-empty Pod baseline (`cmd/queuelabrun/collector.go`) — so that design has a real cost and is
deliberately not taken here.

**Reclaim behaviour is reported, not controlled.** The bound PersistentVolume's `reclaimPolicy` and identity
are recorded so an operator can see whether a `Retain` class is accumulating backing storage. The probe does
not change the policy to make its own cleanup simpler, and `Delete` expresses intent rather than completion.

## What this page does not settle

**No threshold, no outcome space.** Those belong to
`2026-09-21-the-resume-arms-and-what-they-contrast.md`, which is frozen. Nothing here changes the arms, the
repetitions, the interleaving or the stopping rule.

**Whether the class an operator names is the right one.** The probe reports what that class did. Choosing it
remains a statement about the cluster a paid run will use.
