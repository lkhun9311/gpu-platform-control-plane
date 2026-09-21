# The resume arm — the chain it pulls, pre-registered

Date: 2026-09-21, written after the oracle (#219), the accumulator report (#221) and the review that corrected both (#222), and **before any line of the resuming workload exists.**

This page amends `2026-09-21-stage-c-resume-arm-pre-registration.md` in the open. That page registered what Stage C costs in general; it could not name the specific chain, because two of the links were discovered while building the half that came first. It is frozen — its own rule — so the amendment is a new page rather than an edit.

From the moment the workload gains a state file, nothing here may be edited except to record what happened.

## Why an amendment rather than starting the work

The earlier page said the resume arm needs a volume and that the canary does not probe the controller path. Both true. What it did not say is that **making the arm honest costs a schema bump and overturns an assertion written three PRs ago**, and that is the kind of thing this repository has learned to write down first.

The evidence for writing it down is this session. Three times — bumping `recordSchemaVersion`, adding the decode demand, adding the re-derivation — a change required of an older document something it cannot contain, and each orphaned the twelve committed `ex/e17-*.json`. All three were caught, none was predicted. The earlier page's boundary statement is what made them quick to recognise; it did not make them fewer, because it did not name these links.

## The chain, link by link

**1. The workload gains a state file, and that is a new convention.** It writes to exactly one path today, `/dev/termination-log`, and that file is a message the kubelet copies out — not storage. A resume arm needs a path that survives the Pod, which means a mount, a location and a format that nothing here has precedent for.

**2. The argv grows, so both canary commands change.** `canaryKey.HonorCommand` and `IgnoreCommand` carry the rendered argv (`cmd/queuelabrun/canary.go:194`), and a single character changes them. **Not `PodTemplateHash`** — that is taken over a fixed synthetic template and moves only when the operator's renderer does. The earlier page got this backwards and #222 corrected it; stating it again here is cheaper than letting the wrong file be opened twice.

**3. Reporting the resume costs a sixth message field.** A resumed attempt that does not say so is indistinguishable from one that ran from zero: the oracle accepts both, because the pair is consistent either way. So the honest arm reports it — and `ReportFromMessage` currently refuses anything past five fields (`internal/queuelab/provenance.go:316`), while `provenance_test.go:390` asserts `"iters=900 kind=cuda-fma dev=ok duty=0.25 acc=1.0 sixth=2"` is refused. **That assertion was written in this session, deliberately, and this change overturns it.** The widening is the same shape the 3→4 and 4→5 widenings had, and it inherits their rule: every older arity keeps reading.

**4. The record schema goes 20 → 21.** Events gain the resume marker, `DisallowUnknownFields` refuses a 21 document to a 20 build, and the decode exception must be scoped so that 18, 19 and 20 stay readable **without** the new field — the mistake made three times this session, in the same function, for the same reason.

**5. The CRD gains a volume field, and `api/v1` has no precedent for one.** `BuildJob` renders no volumes and its comment requires it to stay a pure function of its argument, because `cmd/queuelabrun` keys a reading on the template it produces.

## What the earlier page left open and this one closes

**The unprobed path now has an instrument.** `internal/controller/suite_test.go:88` runs a real `envtest`, and `mltrainingjob_immutable_test.go:34`'s `createAndSettle` already creates an `MLTrainingJob` and drives reconciles until the owned Job exists. So the reconciler → Job → Pod-template path the canary cannot reach is testable here today, by extension rather than by new scaffolding.

**That is a requirement of this work, not an option.** The volume is attached on exactly the path no canary probes, so the change must arrive with a test that renders it through the controller. Without one, the only thing standing between a mis-rendered mount and a paid session is a reading no instrument takes.

## What this page refuses

**The storage class is not chosen here on the strength of a measurement this cluster cannot make.** `standard` / `rancher.io/local-path` / `WaitForFirstConsumer` is what the kind cluster offers, and the binding mode happens to solve node affinity — a PV is created where the first consumer lands, so a resumed Pod is pulled back to it. That is a convenience of the development cluster, **not** a statement about the GPU cluster, which has no provisioner recorded anywhere in this tree. A study that runs on hardware will have to state its own storage, and this page must not be read as having settled that.

**And the oracle's limit stands.** Stage C remains CPU-path only: the device loop never advances the accumulator, so a resumed and an uninterrupted attempt both report the seed and would agree for the wrong reason. `checkReportedWork` already reports `work-unavailable` there, and a resume verdict on the device path is refused rather than estimated.

## What this page costs

Nothing. Every fact above was read out of the working tree, and the one it declines to settle — what storage a real GPU run would use — is declined because nothing in the tree records it.
