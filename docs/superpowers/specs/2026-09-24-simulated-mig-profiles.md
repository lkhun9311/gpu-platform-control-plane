# Simulated MIG: can the control plane express, admit and place a resource it cannot substitute?

> **Pre-registration. Written before any trial was run.** Arms, bars, invalidation rules and the stopping
> rule below are fixed. Nothing here is a result.

Designed independently by `gpt-5.6-sol` and `gpt-6-astra` and reconciled here; both recommended the same
scope. Which model answered was confirmed from the CLI's rollout records, because `gpt-6-sol` is not a valid
slug and is served silently by astra with exit 0.

---

## Why this exists, and what it is not

`docs/11_WHAT_THIS_MEASURED.md` records that sharing a card was **rejected at the load those studies used** —
14.5x with time-slicing, 20.7x with the engine's own scheduler, against a 2x bar. MIG is in a different
position entirely: it has **never been judged**. The account's SCP permits only `t3.*`, `g4dn.*` and `g5.*`,
and neither T4 nor A10G supports MIG, so no card this project can launch has the feature.

Real MIG performance and isolation therefore cannot be measured here and are **not** hypotheses of this
study. What can be measured is the chain the control plane would have to get right for MIG to be usable at
all:

    device-plugin registration → Node allocatable → Kueue admission → Job unsuspend → scheduler placement

The profile names are **opaque fixtures**. `nvidia.com/mig-1g.5gb` here is a string that happens to look like
a MIG profile; nothing in this study models memory slices, SM partitions, a parent GPU, or which profile
combinations a real card permits. Claiming otherwise would be the toy version of this experiment.

## Corrections carried in from the review

Three premises I stated were wrong, and are recorded because the design depends on them.

**The control-plane taint is not declared anywhere.** `hack/kind-config.yaml` mentions no taint; it is kind's
default, observed live. So node eligibility is a **fixture to verify every trial**, not a property of the
repository.

**The canary hash does not move when a CRD field is added.** It hashes the Pod template that `BuildJob`
renders from a fixed sentinel input (`cmd/queuelabrun/canary.go:228`). A new field only reaches the hash once
the renderer reads it *and* the sentinel sets it — which is the argument for keeping this study out of the
CRD.

**The quota API is single-key by construction.** `GPUQuotaLimits` carries one `GPUCount`
(`api/v1/gpuquotapolicy_types.go`) and the reconciler caps one hard-coded resource
(`internal/controller/kueue_quota.go`). Adding a profile field to `MLTrainingJob` alone would not give this
platform profile-aware admission; the quota API and its reconciler would have to move too.

## A gap this study will document rather than fix

The admission guards count **only** `nvidia.com/gpu`. The name is a constant
(`internal/webhook/v1/gpupod_webhook.go:36`), `gpuRequestOf` sums that one key
(`internal/webhook/v1/gpupod_webhook.go:304`), and `GPUJobValidator.Handle` returns early with
`admission.Allowed("")` when the total is zero (`internal/webhook/v1/gpujob_webhook.go:73`). A Job requesting
only a MIG-named resource therefore reads as requesting no GPU and passes the guard untouched.

*(Those line numbers were wrong on first writing — taken from a review's citation and pasted without
checking. `:71` is the line that extracts the PodSpec. Verified by hand before this file was committed.)*

That is a real enforcement hole, and this study measures **accounting, not enforcement**. It is stated here
so a passing result is not mistaken for tenant-proof policy.

---

## Scope: B

| option | what it would measure | `make manifests` | verdict |
|---|---|---|---|
| **A** simulator advertises several keys; plain Jobs | representation and placement | not needed | insufficient — says nothing about admission |
| **B** A + an experiment-owned ClusterQueue with per-profile quota | representation, **admission**, placement | not needed | **adopted** |
| **C** B + a profile field on `MLTrainingJob` | product API translation | **required**, plus quota API and guards to be honest | deferred — it is API design, and mixing it in widens the failure surface |

The target is a plain `batch/v1` Job, not an `MLTrainingJob`, for a specific reason: Finding 6 showed the CR
reports `Running` whenever `job.Status.Active > 0`, which counts pending Pods. Using the CR as the oracle
here would import a known defect into a study about something else. (That defect was fixed on 2026-09-25 —
the phase now reads `job.Status.Ready` — after this was registered. The choice of oracle stands: it was made
while the defect was live, and a study should not change what it measures with because the code moved.)

Reconfiguration cost — drain, re-advertise, converge — is an **exploratory appendix**, not a hypothesis. A
sleep this study injects is not a measurement of what a real card takes to repartition.

---

## Fixture

Two worker nodes, verified eligible each trial. Two opaque keys:

| symbol | resource name |
|---|---|
| `p` | `nvidia.com/mig-1g.5gb` |
| `q` | `nvidia.com/mig-2g.10gb` |

Baseline inventory **W1: `p=2`**, **W2: `q=2`**; every other node/profile pair is 0. Experiment-owned
ResourceFlavor, ClusterQueue and LocalQueue, no cohort, no borrowing, no preemption, no topology-aware
scheduling. Baseline quota **`p=1`, `q=1`**.

`p` and `q` are independent integers. **No exchange rate is assumed** — two `p` are not one `q`, and nothing
here claims a card could offer this combination.

Targets are 1-profile, 1-device Jobs with `suspend: true`, the queue label, a digest-pinned sleeper
pre-loaded on both nodes, and no selector, affinity or toleration.

## Hypotheses

- **H1 — representation.** The exact profile key survives registration → `allocatable` → Pod request →
  Kueue's recorded reservation.
- **H2 — admission is per-profile.** Exhausting `q`'s quota does not consume `p`'s, and a `p` request is
  admitted in the same instant a `q` request is not.
- **H3 — placement does not substitute.** A `q` request admitted by Kueue is **not** placed on `p` capacity.
- **H4 — the checks can fail.** In the positive-control arm, the quota-blocked and profile-mismatch verdicts
  must both be absent.

No hypothesis about MIG performance, isolation or reconfiguration time is registered.

## Arms — four, n = 5, 20 confirmatory trials

| arm | inventory | quota | expected |
|---|---|---|---|
| **P** positive | W1 `p=2`, W2 `q=2` | `p=1, q=1` | a `q` request is admitted **and placed on W2** |
| **Q** admission-negative | as P | `p=1, q=0` | the `q` request is **never admitted**, Job stays suspended, **no Pod exists**; a concurrent `p` request is admitted and placed |
| **M** placement-negative | W1 `p=2`, **W2 `p=2`** (no `q` anywhere) | as P | the `q` request **is admitted**, then `PodScheduled=False/Unschedulable`, with `p` capacity sitting free |
| **I** independence | as P | `p=1, q=1` | a `p` holder exhausts `p`; a second `p` request waits **even after `q` is released**, and is admitted only when the first `p` is released |

**M is the arm that makes the study worth running.** Total fake device count is 4 in both P and M, so any
check that counts devices in aggregate passes both — and only the per-profile arithmetic separates them.
That is deliberately not a claim that 4 `p` equal 2 `p` + 2 `q` in any physical sense.

Order is counterbalanced across five blocks so each arm appears once in each position.

## Verdicts

Taken from the Workload, the Job and the Pod — never from `MLTrainingJob.phase` and never from
`Job.status.active`.

| verdict | evidence |
|---|---|
| `scheduled` | Workload `Admitted=True` **with the requested key in its reservation**; Job `suspend=false`; Pod has `nodeName` and `PodScheduled=True` |
| `quota-blocked` | Workload `Admitted≠True` naming insufficient quota for the requested key; Job suspended; **no Pod**; the other profile's quota still free |
| `profile-mismatch` | Workload `Admitted=True`; Job unsuspended; Pod exists, `PodScheduled=False`, reason `Unschedulable`, message names the requested key; headroom for the requested key is 0 while the other profile's is ≥ 1 |
| `unknown` | anything else, including taint, affinity, PVC, image or webhook causes — never folded into a bucket to make a bar |

## Bars, fixed now

- **P**: 5/5 admitted within 60 s and placed within 60 s of admission; `quota-blocked` 0/5; `profile-mismatch` 0/5.
- **Q**: 5/5 unadmitted for a 180 s window with no Pod; the concurrent `p` request placed within 60 s.
- **M**: 5/5 admitted within 60 s, then unplaced for the whole 180 s window with `p` headroom ≥ 1; `profile-mismatch` 5/5.
- **I**: 5/5 — the second `p` still waiting after `q` is released, admitted within 60 s of the first `p` being released.
- **Reservations carrying the wrong key: 0 across all arms.**

Times are diagnostic. No percentile or SLO is reported from n = 5.

## Instrument checks, because a verdict function can be wrong

Separately from the confirmatory trials, the classifier is fed deliberately corrupted evidence — an
advertised inventory that differs from the declared one, a reservation with the key removed, a substituted
Pod UID — and **must** refuse each. Originals are kept; the mutated copies are labelled as such.

**Sampling is continuous.** The fragmentation study's repack arm left a 13.6 s hole in every trial because
its sampler paused during an intervention, and that breached its own 5 s rule. Here the collector runs as a
separate process that no arm can pause, and a gap over 5 s invalidates the trial.

**Durations are computed from timestamps, never from sample counts.** The same study published "145 seconds"
for a window spanning 179.1 s because a count was printed with an `s` after it.

## Invalidation, which is not failure

**Invalid** (re-run once at the end; a second invalidation of the same arm ends that arm as inconclusive):
node NotReady or allocatable drift; simulator, Kueue or operator restart; an inactive ClusterQueue; a holder
on the wrong node; an unrelated profile Pod; leftover Workloads or quota usage; image-pull, webhook or watch
failure; **any collection gap over 5 s**.

**A result, recorded as such:** Q admits; M places on `p`; I's second `p` is admitted early; a reservation
carries the wrong key; the simulator advertises something other than what was declared.

## What this cannot license

Real MIG creation or profile compatibility; GPU memory, SM or fault isolation; noisy-neighbour behaviour;
CUDA, NVML or DCGM; the NVIDIA device plugin's actual MIG strategies; parent-GPU topology; the safety or
duration of live repartitioning; `MLTrainingJob` or `GPUQuotaPolicy` profile support; and — because the
guards count only `nvidia.com/gpu` — any claim that a tenant cannot bypass this accounting.

If every bar is met, the honest sentence is:

> Simulated MIG profiles as distinct extended resources on kind and verified, against pre-registered
> controls, that Kueue accounts for them independently and that Kubernetes will not substitute one profile
> for another (n = 5 per arm, no real GPU).

And the one this does not license:

> Implemented MIG-based GPU isolation with verified performance and live reconfiguration.
