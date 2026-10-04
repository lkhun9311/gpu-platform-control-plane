# What This Measured

> **Status (2026-09-23).** The findings, separated from the apparatus that produced them.
>
> `docs/10_WHAT_I_GOT_WRONG.md` records the mistakes. This records what survived them. Every number below
> cites the pre-registration or result page it came from, and every claim is bounded by what the measurement
> could actually see.

The control plane is not the result. It is the instrument. The results are eight findings that could not be
asked without it, and four claims this project is **not** entitled to make.

(Eight, counted from the headings below. This line said seven while the page carried eight, which is the
kind of drift that makes a reader stop trusting the arithmetic in the findings themselves.)

---

## The thread through all of it

**A GPU platform's instruments do not report what they cannot see.**

Reservation cannot see use (1). The scheduler cannot see whether a device is real (2). A tail metric cannot
see the work that was refused (4). A quota system cannot see whether the workload honours a signal (5).
Finding 3 is the exception, and it is the mechanism for why sharing the card did not close one of those blind
spots **at the loads measured** — the same arm closes it at lower ones, which is the whole point of stating a
load with a claim.

Finding 8 is the other exception, and it points the other way: the blind spot in 6 has a cause that can be
moved. Where the scheduler puts the *first* small pod decides whether a later large one has anywhere to go,
and that is a configuration an operator supplies or does not.

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

Time-slicing one A10G between two engines, against an isolated single-tenant baseline (`R1`). These are the
**ninth paid pilot's** numbers (2026-09-13, `hack/m5c-20260913-011031`, commit `85ae2fa`): three arms, two
repetitions each, six cells, 75 minutes, $0.85.

**The load this pilot ran, stated because a later run changed it.** Premium prompts of **200 characters** —
the trace generator's flag default, which the served tokenizer counts as **68 tokens** and which
corresponds to no `inputTokens` declaration at all — contender prompts of 40,000 characters, `timeoutMs`
**30,000**, two repetitions. The input-length resolution table that makes `baseline.inputTokens: 256`
executable did not exist yet. The design spec's seventh 2026-10-01 amendment froze the contract afterwards,
so this table and the ten-cell table below are **different loads and cannot be combined**.

| arm | premium TTFT p99 | /R1 | premium TPOT p99 | /R1 | contender served | timeouts |
|---|---:|---:|---:|---:|---:|---:|
| `R1` | 69.5 ms | 1.0x | 18.2 ms | 1.0x | — | 0 |
| `shared` | 1,892.2 ms | 27.2x | 89.1 ms | 4.9x | 278/278 | 0 |
| `timeSlicing` | **1,007.5 ms** | **14.5x** | 44.1 ms | 2.42x | 278/278 | 0 |

⚠️ **The `timeSlicing` row reversed when the same three arms were bought at the longer prompt.** On
2026-10-02, fifteen cells (`hack/m5c-20261002-014903`, commit `b97d88e`, five repetitions) measured
`R1` <!-- claim: m5c-15cell-r1-premium-ttft-p99 median -->174.268<!-- /claim --> ms, `shared` <!-- claim: m5c-15cell-shared-premium-ttft-p99 median -->4,000.579<!-- /claim --> ms and `timeSlicing` **<!-- claim: m5c-15cell-timeslicing-premium-ttft-p99 median -->14,868.019<!-- /claim --> ms** — the split card 3.7x *worse* than
the single shared engine, where here it is 1.9x better. The registered answer went from `5 (timeSlicing)` to
**`3`, INCONCLUSIVE**: the best sharing arm improved the control by 0.0 ms against a 3.9 ms spread.

The same explanation this page gives below for the baseline applies to it — the premium prompt is 68 tokens
here and 256 there, by the engine's own report on every premium row of both archives — and it is not
established, because the timeout moved from 30s to 60s in the same step.
Each run is tight against itself — on 2026-10-02 `R1`'s five repetitions span
<!-- claim: m5c-15cell-r1-premium-ttft-p99 min -->171.882<!-- /claim --> to
<!-- claim: m5c-15cell-r1-premium-ttft-p99 max -->175.269<!-- /claim --> ms, a width of
**<!-- claim: m5c-15cell-r1-premium-ttft-p99 width dp=1 -->3.4<!-- /claim --> ms**, and the control
`shared` spans <!-- claim: m5c-15cell-shared-premium-ttft-p99 width dp=1 -->3.9<!-- /claim --> ms — so the
two runs disagree rather than either being noisy. An earlier version of this sentence said 0.8 ms, which was the row's first and last value rather than
its extremes. **The row above is this load's result.** Published in full, including the
disagreement, under the pre-registration's 2026-10-02 amendment.

### Why these ratios are a paired comparison, and what their narrowness does not say

**Every arm is offered the same premium requests, and that is now measured rather than assumed.** `gen-trace`
builds the isolated baseline by filtering the contending tenant out of the SAME trace, so `R1`, `shared` and
`timeSlicing` receive identical premium arrivals — same offsets, same prompt lengths, same output caps, in the
same order. Fingerprinting every offered premium row of the 2026-10-02 archive gives **one digest across all
three arms and all five repetitions**, `443db0939d9846de`, at 4,655 requests per cell. The 2026-09-13 pilot
likewise gives one digest across its three arms and two repetitions.

That is what makes a per-repetition ratio a *paired* quantity: the two arms differ in the contending tenant's
139 requests and in nothing else. And the pairing survives into the completed rows — across the fifteen cells,
**69,825 premium requests were offered and 69,825 completed, with zero timeouts**, so no arm is being compared
on a different subset of the traffic it was given.

`internal/bench/paired_premise_test.go` pins the premise. It was written because "true by construction" is the
kind of claim this repository has been wrong about: the construction can change, and arms offered different
premium traffic would still produce a ratio that looks fine. Four mutations of the check go red — dropping the
arrival offset or the request index from the fingerprint, narrowing the comparison to within one arm, and
disabling the repetition comparison — each caught by a synthetic violation, because the real archives satisfy
the premise and therefore prove nothing about the check.

**Three things the paired ratios do not establish.**

| | |
|---|---|
| The two runs cannot be combined | The 2026-10-02 archive's offered-traffic digest is `443db0939d9846de` and the ninth pilot's is `52df4f52668151e2`. Different offered traffic, so their ratios are not repetitions of one experiment |
| The narrow spread is the machine's, not the GPU's | On 2026-10-02 the five `shared`/`R1` ratios span **<!-- claim: ratio m5c-15cell-shared-premium-ttft-p99 / m5c-15cell-r1-premium-ttft-p99 width dp=3 -->0.458<!-- /claim -->** (<!-- claim: ratio m5c-15cell-shared-premium-ttft-p99 / m5c-15cell-r1-premium-ttft-p99 min dp=3 -->22.827<!-- /claim --> to <!-- claim: ratio m5c-15cell-shared-premium-ttft-p99 / m5c-15cell-r1-premium-ttft-p99 max dp=3 -->23.284<!-- /claim -->) and the five `timeSlicing`/`shared` ratios span **<!-- claim: ratio m5c-15cell-timeslicing-premium-ttft-p99 / m5c-15cell-shared-premium-ttft-p99 width dp=3 -->0.181<!-- /claim -->**. Identical offered traffic means that spread is one card, one instance, one session replaying one trace — it is not variation over loads, seeds, cards or sessions |
| It is a range, not an interval | Five values of a statistic are an observed range. No confidence interval is published for this study; `RegisteredEstimand.RatioCI` is computed and withheld until a dated amendment settles the replicate-rounding convention |

### Finding 3b: under the frozen contract, one competing tenant costs 23.0x — and this run bought no split-card arm

Ten cells, five repetitions of `R1` and `shared`, 2026-10-01, $1.44. Premium prompts of **1,174
characters**, which the engine's own tokenizer counted as **256 tokens** on all 46,549 premium rows —
exactly what `baseline.inputTokens` declares — contender 42,579 characters at **8,192 tokens**,
`timeoutMs` 60,000.

| arm | premium TTFT p99 (median of 5) | /R1 | p50 | p95 | premium completed | timeouts |
|---|---:|---:|---:|---:|---:|---:|
| `R1` | 174 ms | 1.0x | 87.8 ms | 143.4 ms | 23,275 / 23,275 | 0 |
| `shared` | 3,998 ms | **23.0x** | 161.3 ms | 2,349.1 ms | 23,274 / 23,275 | 0 |

**The isolated baseline is not the same number as the pilot's, and that is the first thing to say.** `R1` is
69.5 ms in the table above and 174 ms here, on the same card and the same engine. The runs differ in how much
prefill each victim request carries — the pilot's premium prompts were 200 characters and this run's are
1,174 — so the baseline moves with the load, which is why a ratio against one run's baseline cannot be read
against the other's. This page does not claim the length is the *whole* reason: the repetition count differs
too, and nothing isolated them. The timeout is a **weaker** candidate rather than an eliminated one, and an
earlier version of this sentence eliminated it: the longest request either run completed is under the pilot's
own 30 s ceiling, so raising it to 60 s **censored nothing**, which is measured. What that does not cover is
the timeout's other effect — `PoolSizeForTrace` sizes the idle connection pool as
`ceil(rate × timeout_seconds)` (`internal/bench/httpsender.go`), so the two runs replayed through clients of
different sizes. Ruling the timeout out entirely needs a comparison that holds the client fixed, and no run
has done that.

Total output throughput was level — 589.2 against 589.3 tok/s — and the latency cost was **not confined to
the tail**: p50 rose 1.84x, p95 16.4x, p99 23.0x. The five per-repetition ratios were
22.96 · 23.01 · 22.95 · 22.93 · 22.97, an **observed range and not a confidence interval**: this run
replayed one trace five times, so its narrowness shows repetition stability under one fixed load rather
than variation over loads, seeds or machines. Under the registered rounding rule the medians give
3998/174 = **22.977**; at raw precision the same medians give 22.969, and the pooled-request ratio 22.972.

**What this run cannot say.** It bought no `timeSlicing` arm, so it makes no claim about splitting the card
under this contract. The one premium request that did not complete was an **HTTP 502** in `shared`
repetition 3, with no trace in the instance log — "no timeouts" is not a success rate. And the gap between
27.2x and 23.0x is not evidence about the calibration: the prompt length and the repetition count both
differ. The timeout differs too and is not a candidate, for the reason given above.

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
service time, **neither of the two sharing modes measured here reaches it at the loads measured here**,
because the unit that must be divided is not the card — it is a request already in flight.

The bound matters and this sentence did not carry it. It read "no sharing mode reaches it", which is a
statement about every sharing mode at every load, and the paragraphs above it say the opposite: the same
`timeSlicing` arm passes at 1.16 and 2.31 requests a second. What was measured is `shared` and `timeSlicing`
on one card at the loads listed, and the service-time argument explains those observations rather than
proving a universal. An external review caught the mismatch between this sentence and its own page.

**What it does not say.** Nothing about MIG. Neither card this account may launch supports it — the
register that reads DCGM labels records exactly that: *"correct for T4 and A10G, neither of which supports
MIG"* (`hack/queuelab-refusal-register.md:65`). MIG is not absent because it was judged and rejected; it is
absent because the instance-family policy permits no card that has it. Nothing here about larger cards, and
nothing about different prompt-length distributions.

**A later run under the CRD contract did not replace these numbers.** On 2026-10-01 a
`GpuSharingBenchmark` compiled into the paid runner's whole configuration for the first time — the instance
logged the CR's digest, and cell 1 of 10 produced 4,655 rows whose manifest names the study, the tokenizer
revision and the engine digest. It then stopped itself on a cell boundary: a cell took 15.7 minutes against
the runner's assumed 10, so ten cells need about 212 and the deadline was 160. One cell is not a comparison,
and that run bought the provenance chain rather than a result. **The table above remains the ninth pilot's**,
and nothing in the 2026-10-01 run retroactively confirms it.

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

**Fixed 2026-09-25, after this measurement.** The phase now reads `job.Status.Ready`, which counts active,
non-terminating Pods whose Ready condition is true — something a Pod no node accepted cannot have. That is
*stricter* than "scheduled", not equal to it: a Pod running behind a failing readiness probe is not counted,
so the phase carries readiness delay too. Job status exposes no "scheduled" count, and of the two it does
expose this is the one that cannot be true of an unplaceable Pod. `.status.ready` is a pointer written by the
Job controller, which reports a non-nil zero; a nil means a cluster too old to report it, so it falls through
to `Admitted` rather than reading `Active` again. The table above is left as it was measured: it is the record
of what the platform did on 2026-09-24, not a description of the code today.

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

## Finding 8 — the state behind Finding 6 is one an operator configures, in two of three runs

Finding 6 measured a platform mis-reporting a job it could not place. This asks the prior question: **does the
state that traps the job arise because nobody told the scheduler how to pack?** A registered campaign — 2 arms
× 3 repetitions = 6 cells, one fixed submission sequence, workers advertising 2, 1 and 1 devices — answers it
on the sequence's discriminating step, a 2-device request submitted after two 1-device ones.

| arm | rep 1 | rep 2 | rep 3 | what happened to the 2-device request |
|---|---:|---:|---:|---|
| **no configuration supplied** (`S-default`) | **2** | **2** | 0 | refused in 2 of 3 — a 1-device pod had split the two-device node |
| GPU-aware packing supplied (`S-gpu-most`) | 0 | 0 | 0 | bound in 3 of 3 — the one-device nodes filled first |

`stranded_devices` is the registered figure: free devices on a cluster where no pending workload fits anywhere,
`max(f_i) < q ≤ Σf_i`, with the witness drawn from pending demand rather than assumed. At the stranded steps the
free counts were `1, 0, 1` against a request of 2 — two devices free, unusable, and a workload waiting for them.

**Why it matters.** `MostAllocated` scoring over `nvidia.com/gpu` prefers the node it can fill completely,
because `1/1` is a higher post-placement fraction than `1/2`. That leaves the large node intact for the large
request. The default scheduler has no reason to protect it, and in two of three runs it did not. The remedy
costs a `KubeSchedulerConfiguration`, not hardware — but it is a remedy for *this shape of demand*, and a
different mix could reverse the sign.

**No statistic is computed from six cells**, as the protocol registered in advance, and none is reported. What
is published is the series.

**What it does not say.** Not that `MostAllocated` is responsible — the treatment is the mount, the resource
list and the strategy *together*, so the comparison attributes to supplying that configuration and nothing
narrower. Not that the reference scheduler is deterministic: the same three repetitions run earlier on a
differently-built cluster gave `2, 0, 2` — the same two-of-three, in a different position. And not that six
cells settle it; a single cell of either arm would have been swallowed by that variation, which is why the
campaign refused to publish until every registered cell stood.

**The instrument is the finding as much as the numbers are.** The protocol is a file the tool reads, not a
discipline the author keeps: `cmd/strandedrun` recomputes the page's arithmetic from
`hack/stranded-protocol.yaml` and refuses a protocol that contradicts itself; the performer and the judge are
separate programs and the protocol refuses to name the performer as its own judge; a cell may be discarded only
for a registered reason, and ties, identical outcomes and a stranding figure of zero are registered as **not**
invalidating, so the runs that come out level cannot be quietly dropped. Twice the apparatus overruled its
author — an early pair that matched the hypothesis was disclosed as a rehearsal and then disarmed by the
variation above, and a qualification fixture was refused by a guard written four changes earlier because on a
symmetric layout the two candidate nodes tie.

*(`docs/superpowers/specs/2026-09-29-stranded-gpu-frozen-protocol.md`, `cmd/strandedrun`, `hack/stranded-cell.sh`)*

---

## What this project is not entitled to claim

Stated first, because the findings above are only believable if the refusals are published with them.

| claim | what is actually true |
|---|---|
| **"I operated a GPU platform"** | No. The gateway has never been deployed to EKS or through the GitOps path (`README.md:22`). The cluster was applied once on 2026-09-18 — 96 resources, no GPU instance — and destroyed in the same cycle. Argo CD has been run on kind, and **auto-sync was deliberately removed before applying** (`hack/argocd-kind.md:24`), so seven Applications resolving with no error is evidence that the manifests build and the destination resolves — **not** that drift is repaired. Self-heal has now been exercised, but narrowly: a separate Application in its own project and namespace, bootstrapped by `kubectl`, repaired six of six injected drifts (`experiments/argocd-selfheal/`). The seven platform Applications were left with automation off and are unchanged. So the GitOps *mechanism* is demonstrated on this cluster; the *platform* running under it is not. |
| **"The admission guard protects the premium tier"** | Rejected. 83.7x against a 1.25x target across four paid repetitions; the run was declared invalid by its own checks and no protection claim was made. |
| **"Sharing a card substitutes for isolation"** | Rejected as stated. 14.5x with time-slicing and 20.7x with the engine's own scheduler, both against a 2x bar — at the load those studies used. ⚠️ **Splitting the card has been measured only at the pre-freeze load.** The ten-cell run under the frozen contract bought no `timeSlicing` arm, so it adds nothing to this refusal: its 23.0x is one shared engine against isolation, and reading it as a statement about splitting would be the comparison reading `4d` exists to block. A later ladder found time-slicing **meeting** a 139 ms premium target at 1.16 and 2.31 req/s and breaching at 4.61. So the honest refusal is narrower than "sharing does not substitute": the claim fails because it was made without naming a load. |
| **"I built a training platform"** | The `MLTrainingJob` CRD exists and admits through Kueue. Its samples are worse than that: the two tenant samples run `busybox` (`config/samples/platform_v1_mltrainingjob_tenant_b.yaml:16`), and the default one names `pytorch/pytorch:2.3.0-cuda12.1-cudnn8-runtime` with `command: [python, train.py]` (`config/samples/platform_v1_mltrainingjob.yaml:13`) — but **that image contains no `train.py` and nothing puts one there**, so the one sample that looks like training cannot run at all. (A `train.py` does exist in this repository now — `experiments/cpu-ddp/train.py`, added after this row was written — but it is built into its own image by `experiments/cpu-ddp/Dockerfile` and is not the file the sample names. The sample is still broken; only the sentence's "anywhere in this repository" was.) The queuelab trace is not — it runs `python:3.12-slim` and launches a PTX kernel through the CUDA driver API (`internal/queuelab/submit.go:44`) — but that is a synthetic accumulator, not a model. **Distributed training has since run, narrowly**: two gloo ranks inside one Pod, admitted through this CRD and Kueue, with gradient averaging verified by hand-checkable arithmetic and a control that fails (`experiments/cpu-ddp/`). Still no NCCL, no GPU, no multi-Pod rendezvous and no checkpoint resume — and `parallelism: 2` would not provide them, since the operator sets no `completionMode`, no `subdomain` and creates no headless Service. |

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
| 8 — configuration removes stranding | a second layout, and a demand mix where packing should *lose*. Both arms ran on one shape; the campaign cannot cancel a drift over time, because both arms render the same cluster name and must run in sequence |
