# What This Measured

> **Status (2026-09-23).** The findings, separated from the apparatus that produced them.
>
> `docs/10_WHAT_I_GOT_WRONG.md` records the mistakes. This records what survived them. Every number below
> cites the pre-registration or result page it came from, and every claim is bounded by what the measurement
> could actually see.

The control plane is not the result. It is the instrument. The results are seven findings that could not be
asked without it, and four claims this project is **not** entitled to make.

---

## The thread through all of it

**A GPU platform's instruments do not report what they cannot see.**

Reservation cannot see use (1). The scheduler cannot see whether a device is real (2). A tail metric cannot
see the work that was refused (4). A quota system cannot see whether the workload honours a signal (5).
Finding 3 is the exception, and it is the mechanism for why one of those blind spots cannot be closed by
sharing the card.

---

## Finding 1 — reservation does not track use, and the gap reached 4x

Two arms were given identical GPU quota and differed only in how much of their service they spent computing.

| arm | n | reserved GPU-s | mean utilisation | observed device-s |
|---|---:|---:|---:|---:|
| `D-full` | 3 | 51.084 | 94.2% | **48.115** |
| `D-quarter` | 3 | 50.802 | 23.9% | **12.193** |

Reservation differed by **0.282 s** against a summed floor of 5.814 s — the same, by the instrument's own
resolution. Observed device-seconds differed by **35.922 s**, a ratio of **0.253**, inside the 0.15–0.40 band
the document fixed *before* the run.

**Why it matters.** Schedulers admit on reservation. Quota systems count reservation. Cloud invoices bill
reservation. All three can be correct and all three can be useless at once: this pair of runs is
indistinguishable to every reservation-based figure and differs fourfold in what the card actually did.

**What it does not say.** Nothing about whether the utilisation figure itself is trustworthy at finer
resolution, and nothing about multi-tenant interference — both arms ran alone.

*(`docs/superpowers/specs/2026-09-06-does-reservation-track-use.md:331`, `:338`)*

---

## Finding 2 — a fake device plugin reproduces real-hardware scheduling measurements

The same queue-policy experiment was run twice: once on kind with a device plugin this repository wrote
(kubelet device-plugin v1beta1 gRPC, `cmd/gpu-simulator`), once on four rented A10Gs.

| | kind, fake plugin | four A10Gs |
|---|---:|---:|
| owner wait difference | 29.0 s | **28.8 s** |
| GPU-second difference | 30.0 | **30.0** |

**Why it matters.** The scheduler does not know the devices are fake. It admits, places and preempts from
`allocatable` and pod requests, which are identical in shape either way. So **scheduling, queueing and
preemption questions can be answered rigorously for $0**, and a rented card adds no information to them.
That is a methodological result, not a convenience: it says which questions need hardware and which do not.

**What it does not say.** Nothing about anything downstream of placement — utilisation, throughput, memory,
interconnect. For those the fake device is not merely weaker evidence; it is no evidence.

*(`docs/superpowers/specs/2026-09-05-the-device-was-never-observed.md:265`)*

---

## Finding 3 — splitting a card does not divide the machine

Time-slicing one A10G between two engines, against an isolated single-tenant baseline (`R1`):

| arm | premium TTFT p99 | /R1 | premium TPOT p99 | /R1 | contender served | timeouts |
|---|---:|---:|---:|---:|---:|---:|
| `R1` | 69.5 ms | 1.0x | 18.2 ms | 1.0x | — | 0 |
| `shared` | 1,892.2 ms | 27.2x | 89.1 ms | 4.9x | 278/278 | 0 |
| `timeSlicing` | **1,007.5 ms** | **14.5x** | 44.1 ms | 2.42x | 278/278 | 0 |

The improvement is real: **884.6 ms**, against a control whose two repetitions differed by **1.375 ms**.
That is a range check and nothing more. An earlier draft of the source spec expressed the same comparison as
a multiple and **dropped the multiple rather than correcting it**, because the registered rule asks whether
the improvement clears the range, not by how many times — and because the multiple invites a precision the
two numbers do not carry. This page reintroduced it anyway, as "632 times the noise", until a review caught
it.

It misses the pre-registered 2x bar by sevenfold **at this load**, and a successor study that took the same
question to the engine's own scheduler — eight configurations, three repetitions — reached **20.7x** at best.
**Below that load the same arm passes.** On a ladder whose contender was held byte-identical across rungs,
`timeSlicing` met the 139 ms premium target at 1.16 req/s (123.7 ms) and at 2.31 req/s (130.3 ms, repeated
at 130.8 ms), and breached only at 4.61 req/s. What fails is the claim stated without a load, not the
mechanism at every load.

**The mechanism, which is the actual finding.** A contending prompt occupies the engine for about **1.03 s**.
The premium tail budget is a tenth of that. When the latency target is shorter than one contending request's
service time, no sharing mode reaches it, because the unit that must be divided is not the card — it is a
request already in flight.

**What it does not say.** Nothing about MIG. Neither card this account may launch supports it — the
register that reads DCGM labels records exactly that: *"correct for T4 and A10G, neither of which supports
MIG"* (`hack/queuelab-refusal-register.md:65`). MIG is not absent because it was judged and rejected; it is
absent because the instance-family policy permits no card that has it. Nothing here about larger cards, and
nothing about different prompt-length distributions.

*(`docs/superpowers/specs/2026-09-10-does-splitting-the-card-buy-protection.md:529`, `:561`;
`docs/superpowers/specs/2026-09-15-a-ladder-whose-contender-holds-still.md:82`, `:115`;
`docs/superpowers/specs/2026-09-08-the-load-needs-an-upper-gate.md:114`)*

---

## Finding 4 — a tail-only reading reports the arm that did no work as the winner

The three-arm admission guard was declared **INVALID** by its own pre-registered checks: it held the premium
tail at 83.7x an uncontended baseline against a 1.25x target, so no protection claim was made.

Re-scoring the same evidence later, at no further spend, found something worse. The arm whose tail *matched
isolation* — the apparent winner on the headline metric — had admitted **none** of the contending tenant's
work. Its token bucket was configured smaller than the contender's prompt, so every contending request was
refused, and a tenant that is never admitted cannot lengthen anyone's tail.

**Why it matters.** Any admission control evaluated on latency alone is maximised by refusing everything.
The reading must pair the tail with the work admitted, or the study rewards the configuration that does
nothing. This is not a hypothetical failure mode — it is what this study's own numbers said until they were
read a second time.

**What it does not say.** Nothing about whether a correctly sized bucket would have protected the tail. That
question was closed by Finding 3's mechanism rather than by a rerun.

*(`docs/superpowers/specs/2026-09-05-the-price-of-protection.md:71`)*

---

## Finding 5 — preemption that did not preempt

A published measurement claimed Kueue's `reclaimWithinCohort` admitted the quota owner ~120 ms after
submission at a cost of ~39 GPU-seconds of discarded borrower work. It was retracted the same day.

The workload's container ran `sleep` as PID 1. A container's PID 1 receives no default signal disposition,
so it **ignores SIGTERM**. The borrower was not stopped by preemption: it reached **natural completion at
42.638 s with exit 0**, and SIGTERM had arrived with about 9 s of service left. The ledger recorded the stop
reason as `Succeeded` and the accounting never read that field.

**Why it matters.** The correctness of quota reclamation depends on the workload's signal handling, which
the quota system cannot observe. "Preempted" and "finished on its own" are indistinguishable in the control
plane's own records unless something reads the termination reason — and the arm that was supposed to honour
SIGTERM **did not exist**, because every workload in the study ignored it.

*(`docs/superpowers/specs/2026-08-02-queuelab-termination-contract-design.md:47`;
`docs/10_WHAT_I_GOT_WRONG.md`)*

---

## Finding 6 — the platform reports a job it never placed as running

A 2-GPU job, 2 GPUs free, quota reserved, and no node able to take it. Across 25 pre-registered trials on
two worker nodes:

| arm | headroom | outcome | samples where the CR said `Running` while unscheduled |
|---|---|---|---:|
| packed `(2,0)` | `ΣF=2, maxF=2` | scheduled 5/5 | 0 |
| **fragmented `(1,1)`** | `ΣF=2, maxF=1` | **unschedulable 5/5** | **145 of 145**, spanning 179.1 s |
| quota-short | quota 3 | never admitted 5/5 | 0 |
| aggregate-short `(1,0)` | `ΣF=1` | unschedulable 5/5 | **145 of 145**, spanning 179.1 s |

The packed and fragmented arms differ by one character — the hostname in one holder's `nodeSelector` — with
identical capacity, quota, holder count and identical total free GPUs.

**Why it matters.** `computeMLTJPhase` reports `Running` when `job.Status.Active > 0`
(`internal/controller/mltrainingjob_controller.go:288` as it stood on 2026-09-24; the line now carries the
comment explaining the fix), and Kubernetes counts *pending* Pods in `Active`. So
the CR says running for a Pod no node accepted, and `admitToRunningSeconds` is measured from that
transition — the platform's own latency metric taken from a moment that never happened. It is not specific
to fragmentation: plain capacity shortage produces the same false `Running`.

**Fixed 2026-09-25, after this measurement.** The phase now reads `job.Status.Ready`, which counts active
Pods carrying a Ready condition — something a Pod no node accepted cannot have. `.status.ready` is a pointer,
and a nil there is "this API server did not say", not "nothing is running", so it falls through to `Admitted`
rather than reading `Active` again. The table above is left as it was measured: it is the record of what the
platform did on 2026-09-24, not a description of the code today.

Repacking one holder — no added GPU, no added quota, demand 2 → 3 → 2 — returned the same Pod to scheduled
in 5/5 trials, though every one of those five breaches the study's own 5 s collection-gap rule and is
reported as evidence rather than as a pass (`experiments/fragmentation/README.md`).

**What it does not say.** Nothing about real GPUs, utilisation, gang scheduling, or automatic repacking,
which this platform does not do. The thing moved was a `pause` container, not live training.

*(`experiments/fragmentation/`, `docs/superpowers/specs/2026-09-24-node-level-gpu-fragmentation.md`)*

---

## Finding 7 — a scheduler will not swap one partition profile for another, and a quota system will not either

MIG has never been judged here: the account's instance-family policy permits no card that supports it. What
could be judged is whether the control plane can express, admit and place a partition-shaped resource at
all. Two simulated profiles, advertised as distinct extended resources by independent device-plugin
instances on one node, across 20 pre-registered trials:

| arm | inventory | quota | verdict |
|---|---|---|---|
| positive control | `p=2` on W1, `q=2` on W2 | `p=1, q=1` | `scheduled` **5/5** |
| quota-negative | as above | `p=1, q=0` | never admitted, no Pod **5/5** |
| **placement-negative** | **`p=2` on both nodes** | `p=1, q=1` | admitted, then **unschedulable 5/5** |
| independence | as positive | `p=1, q=1` | a second `p` waits **even after `q` is released** 5/5 |

**Why it matters.** The positive and placement-negative arms advertise the *same four devices* and differ
only in which key the second node publishes. Any check that counts devices in aggregate passes both. The job
is admitted by the quota system and then refused by the scheduler, with capacity of the other profile free
beside it — so "there are four GPUs and the job wants one" is not a statement that predicts placement.

No reservation ever carried a key that was not requested, in any of the 20 trials.

**What it does not say.** Nothing about real MIG, memory or fault isolation, or reconfiguration. And nothing
about enforcement: the admission guards count only `nvidia.com/gpu`, so a Job requesting only a MIG-named
resource reads as requesting no GPU and passes them untouched. This measured accounting, not policy.

*(`experiments/mig/`, `docs/superpowers/specs/2026-09-24-simulated-mig-profiles.md`)*

---

## What this project is not entitled to claim

Stated first, because the findings above are only believable if the refusals are published with them.

| claim | what is actually true |
|---|---|
| **"I operated a GPU platform"** | No. The gateway has never been deployed to EKS or through the GitOps path (`README.md:22`). The cluster was applied once on 2026-09-18 — 96 resources, no GPU instance — and destroyed in the same cycle. Argo CD has been run on kind, and **auto-sync was deliberately removed before applying** (`hack/argocd-kind.md:24`), so seven Applications resolving with no error is evidence that the manifests build and the destination resolves — **not** that drift is repaired. Self-heal has now been exercised, but narrowly: a separate Application in its own project and namespace, bootstrapped by `kubectl`, repaired six of six injected drifts (`experiments/argocd-selfheal/`). The seven platform Applications were left with automation off and are unchanged. So the GitOps *mechanism* is demonstrated on this cluster; the *platform* running under it is not. |
| **"The admission guard protects the premium tier"** | Rejected. 83.7x against a 1.25x target across four paid repetitions; the run was declared invalid by its own checks and no protection claim was made. |
| **"Sharing a card substitutes for isolation"** | Rejected as stated. 14.5x with time-slicing and 20.7x with the engine's own scheduler, both against a 2x bar — at the load those studies used. A later ladder found time-slicing **meeting** a 139 ms premium target at 1.16 and 2.31 req/s and breaching at 4.61. So the honest refusal is narrower than "sharing does not substitute": the claim fails because it was made without naming a load. |
| **"I built a training platform"** | The `MLTrainingJob` CRD exists and admits through Kueue. Its samples are worse than that: the two tenant samples run `busybox` (`config/samples/platform_v1_mltrainingjob_tenant_b.yaml:16`), and the default one names `pytorch/pytorch:2.3.0-cuda12.1-cudnn8-runtime` with `command: [python, train.py]` (`config/samples/platform_v1_mltrainingjob.yaml:13`) — but **no `train.py` exists anywhere in this repository**, so the one sample that looks like training cannot run at all. The queuelab trace is not — it runs `python:3.12-slim` and launches a PTX kernel through the CUDA driver API (`internal/queuelab/submit.go:44`) — but that is a synthetic accumulator, not a model. **Distributed training has since run, narrowly**: two gloo ranks inside one Pod, admitted through this CRD and Kueue, with gradient averaging verified by hand-checkable arithmetic and a control that fails (`experiments/cpu-ddp/`). Still no NCCL, no GPU, no multi-Pod rendezvous and no checkpoint resume — and `parallelism: 2` would not provide them, since the operator sets no `completionMode`, no `subdomain` and creates no headless Service. |

Two of these are rejected hypotheses, which is a result. Two are gaps, which are not.

---

## What each finding needs before it generalises

| finding | the next thing that would strengthen it |
|---|---|
| 1 — reservation vs use | a multi-tenant version; both arms here ran alone |
| 2 — fake device reproduces | a third topology, or a scheduling question where the two *disagree* |
| 3 — sharing vs isolation | MIG on a card that supports it, which the account's instance-family policy does not permit. The MPS arm is **unjudged rather than failed** — it did not run correctly in the matrix, which is a different statement from missing the bar |
| 4 — tail-only readings | nothing; the mechanism is established and the fix is a reading, not a run |
| 5 — preemption that did not | already closed: the termination contract is now an arm of the protocol |
