# Does splitting the card buy protection — pre-registration

Date: 2026-09-10 · Pre-registered **before** any card time is bought for it. Nothing here may be edited from
the moment its pilot is bought.

## Why this exists

Two layers have been measured and neither protects the premium tail at this load.

**Admission (M5-b).** A KV-occupancy guard missed a 1.25x bar at 83.7x, and re-analysis found the occupancy
limb was unreachable by construction and never fired at all.

**Engine scheduling (the price-of-protection run).** Batch budget crossed with scheduling policy, eight
cells, three repetitions, no timeouts. The best cell held the premium tail at **20.7x** an isolated baseline
against a 2x bar, and its **median** missed by 2.8x. All nine configurations scored two of the four bars and
always the same two: the contending tenant kept its work and the machine kept its throughput, while the tail
and the stream were missed everywhere.

`2026-09-09-what-would-have-to-change.md` derived why, as a ratio rather than a policy. A contending prompt
occupies the engine for about **1.03 s**; the premium tail budget at the 2x bar is **0.135 s**. Chunked
prefill divides that second and priority lets a short request enter at a piece boundary, which is why those
knobs are worth about fivefold — against a gap of twenty. Dividing the work does not divide the machine.

That page named three levers and refused to pick one. This picks the third: **divide the machine.**

## The question

> **Does giving each tenant its own engine on a shared card protect the premium tail, and what does the
> premium tenant pay in capacity for it?**

The mechanism is different from everything measured so far, and that is the point. Under `shared`, a premium
request waits in a queue behind an admitted long prefill. Under `timeSlicing` and `mps` there is no such
queue: each tenant has its own engine with its own cache, and the contention moves from queueing to the SMs.
A premium request should then run *slower* but never *behind*.

**It is not obvious this helps.** Half a card is half a card, and a premium request that runs at half speed
on an uncontended engine may land in the same place as one that queues briefly on a fast one. That is what
makes it worth measuring rather than assuming.

## Corrected on 2026-09-10, before any card time was bought

This page was written on the strength of a sentence that turned out to be false: that the three arms were
**"already built and tested in `hack/m5c-matrix.sh`"**. They were built. Nothing had ever run them, and
`docs/00_PORTFOLIO_OVERVIEW.md` already said so of the whole cluster half of the AWS path — *"offline-validated,
never applied to AWS"*. Reading the runner, rehearsing it on a real cluster, writing the code for its own
readings, and finally running the runner itself on a cluster found **fourteen** defects, each of which would
have ended or silently corrupted a paid session.

**Nine were found before any card was rented. Three more were bought by pilots, for $2.03 in total, and two
were then found by running the matrix on a free cluster.** Nothing in this section reads a result, because
there are none: every entry below is a thing that stopped the instrument or falsified what it recorded.

That
is why editing this page now is legitimate: its freeze clause binds from the moment its pilot is bought, and
the pilot is not bought. Nothing here reads a result, because there are no results.

| # | what was wrong | what it would have cost |
| --- | --- | --- |
| 1 | The split engines did not pass `--no-enable-prefix-caching`; the exclusive one did | vLLM V1 caches by default and this trace repeats one prompt shape, so the split arms would have beaten `shared` by a wide margin **because of a cache**, and this page would have called it separation |
| 2 | Both sharing overlays rendered `namespace: system`, a kubebuilder placeholder nothing creates | every apply refused with `namespaces "system" not found`; **neither sharing arm could ever deploy** |
| 3 | Nothing advertised a device for the `shared` arm | the sharing node deliberately lacks the exclusive plugin's label, so the control's engine either sat Pending to a 900 s timeout or **inherited the previous arm's split card and reported numbers** |
| 4 | The device count was checked with `-ge` | `timeSlicing` → `mps` both want 2, so the check passed on the outgoing arm's stale advertisement and MPS could begin as time-slicing |
| 5 | `config/gateway/rbac.yaml` has the same placeholder namespace, and the matrix binds `gateway-role` without creating it | Kubernetes accepts a binding to a missing ClusterRole, so the gateway starts and **every request fails authorization**, with nothing looking wrong until the first replay |
| 6 | No tenant weights were passed to `gen-trace` | the default mix puts the 40,000-character contender at 45% of arrivals — four to five times an A10G's prefill capacity — and **no choice of `RATE` fixes it**, because lowering it starves the premium tail below the sample floor |
| 7 | No `--model` was passed to `gen-trace` | the default is `llama-3-8b`, the engines serve Qwen2.5-3B, and the gateway routes by model name: **every request `ErrNoRoute`**, after both engines had loaded |
| 8 | This study's readings were not implemented anywhere in `internal/bench` | the readings below would have been evaluated by hand, which is not the pre-registered instrument |
| 9 | **Reading 2 was unreachable.** Its condition — meets both bars *and* starves the contender — was a strict subset of reading 1's, and reading 1 is evaluated first | an arm that bought its tail by refusing the other tenant's work would have been reported as the **deliverable**, and the reading that exists to catch exactly that would never have run |
| 10 | The matrix had **no R1 arm**. `deploy_arm` had cases for `shared` and the sharing pair and none for the isolated baseline | R1 is the denominator of both bars, so the readings declined to evaluate anything. Found by a pilot |
| 11 | The trace sent four tenants and the replay carried keys for **two** | all 41 probe requests refused by the gateway, both probe rows VOID. `hack/lib/spot-run.sh` records this same failure twice before, so this was the third. Found by a pilot |
| 12 | An engine that never became ready said only that | Pending, crash-looping, still pulling, or killed for memory are four faults with four fixes, and the run log held none of it. Found by a pilot |
| 13 | `GPUQuotaPolicy` is cluster-scoped and its `targetNamespace` is **immutable**; the matrix moves the contender between namespaces every arm | the API refuses it on the first sharing arm. **This is the matrix's entire routing mechanism.** Invisible to reading, because the immutability and the mutation are in different files |
| 14 | The port-forward was replaced between cells with a `kill` that does not wait, then slept at for three seconds | the new forward lost the race for the port and died with its output in `/dev/null`. **Two of four arms would have completed nothing**, recorded with no HTTP status, and the report would have called it a censored tail — a plumbing failure wearing a load failure's name |

**Defect 14 is the one to read twice.** The other thirteen stop the run. That one lets it finish and hands
back a table, and the table's own wording — a censored tail — points at the load rather than at the tunnel.
A reader would have re-derived the load and bought another card.

All fourteen are fixed. Each is pinned by a test that was deliberately broken to confirm it goes red, or by
`hack/test/rehearse-m5c-matrix.sh`, which runs the matrix itself on a kind cluster with stub engines and
simulated devices and asserts that its readings could be *evaluated* over the evidence it wrote — not merely
that they printed. Defects 13 and 14 were found by that rehearsal on its first pass and are not reachable by
reading: in 13 the immutability and the mutation live in different files, and in 14 the symptom only appears
from the second cell onward, which no paid run had ever reached. This is also
defect 9, whose test asserts that an arm meeting both bars with 170 of the contender's 300 requests *rejected*
is reported NEGATIVE and not POSITIVE. Defect 5 is fixed as a refusal that names the file to apply.

Defect 8's fix is `internal/bench/sharing_matrix.go`: all seven readings, evaluated in the registered order,
dispatched from `benchharness report` on a study whose arms are the topologies. That last part removed
something else — the run used to replay every arm as `off` and ship a README saying its evidence must never
be given to `benchharness report`, because pooling would collapse three topologies into one row. Evidence
that arrives with a warning against using the tool that reads it is one step from being read wrong.

**Defect 9 is the one worth dwelling on**, because it was found by writing the code for defect 8 and by
nothing else. Reading the page did not surface it; two readings that overlap look fine in prose and only
collide when something has to decide which fires first. That is the argument for the gate: implementing the
readings is not paperwork ahead of the pilot, it is the last review the design gets.

Seven of the nine were found by reading or by implementing. Two — 5 and the confirmation that the gateway
needs no operator —
came from `hack/test/rehearse-m5c-deploy.sh`, which stands up a kind cluster with stub engines and proves a
request travels key → tenant → `GPUQuotaPolicy` → namespace → `InferenceDeployment` → Service → Pod. It
asserts that each tenant reached **its own** engine rather than that both got HTTP 200, because both
tenants routed to one engine also returns two 200s, and that is the `shared` topology wearing a split arm's
name.

### The platform changed, and so did the budget

The original budget — pilot ~$1.30, confirmatory ~$2.90 — was costed from the runtime model fitted to three
paid runs that each rented **one self-contained Spot instance**. `hack/m5c-matrix.sh` does not do that. It
drives an **EKS cluster with a GPU node group**, and no such cluster exists or has ever been applied. The
figure was wrong for a reason that has nothing to do with the arithmetic: it costed a shape the runner does
not have.

The runner now takes `PLATFORM=eks|kind`. The `kind` path rents one Spot instance and builds a kind cluster
on it with the real NVIDIA device plugin — the recipe `hack/queuelab-gpu-session.sh` already paid for and
proved on A10Gs. The EKS path is untouched: its lines were moved into a function and not otherwise edited,
which `git diff -w` shows.

**`g5.2xlarge`, not `g5.xlarge`.** Measured on 2026-09-10 in `ap-northeast-2`: **$0.68/h against $0.58/h**,
for 32 GiB of host memory instead of 16. A kind node, two vLLM engines and the harness on 16 GiB is the kind
of margin that is discovered at the rollout timeout, and ten cents an hour is the wrong place to economise.

## Design

Three arms, on one `g5.2xlarge` (one A10G), through `PLATFORM=kind`:

| arm | topology |
| ------------- | -------- |
| `shared` | both tenants on ONE engine — the price-of-protection control's topology |
| `timeSlicing` | one engine per tenant, each with its own cache on half the card |
| `mps` | the same two engines, sharing through MPS instead |

Plus **R1**, the isolated premium baseline, which every study here measures as its ceiling.

`shared` is the control and it is not a formality: it is the arm that reproduces the previous result on this
topology, and if it does not reproduce, nothing else on the page means anything.

**What this cannot report, by construction.** Under time-slicing and MPS a busy SM belongs to no single
engine, and `internal/queuelab`'s exclusivity clause refuses to attribute it. So the matrix reports what the
CLIENTS observed — per-engine latency and throughput — and reports no per-engine GPU utilisation. The
sharing modes get their own device-plugin configuration rather than replacing the exclusive one, because
that config is what queuelab's device evidence depends on.

### What the engines may and may not differ in

The matrix varies topology. Every other engine setting has to be identical across the arms, or its effect
arrives in the result wearing topology's name — which is what defect 1 was. Three settings are allowed to
differ, and each is forced by the split rather than chosen:

| setting | exclusive | each split engine | why it may differ |
| --- | ---: | ---: | --- |
| `--gpu-memory-utilization` | 0.90 | 0.475 | time-slicing does not partition memory; two engines draw on one pool, so the fractions must sum below 1 |
| `--max-num-seqs` | 64 | 32 | half each, so **the card admits the same total concurrency under either topology**. Per-engine 64 would offer the card twice the concurrency in the split arms and confound separation with a larger batch |
| the device-plugin overlay | whole-card, 1 device | time-slicing or MPS, 2 devices | this is the mechanism under test |

Everything else must match, and `--max-num-batched-tokens=2048` is now **stated** on all three engines
rather than left to the engine. 2048 is not a choice: the price-of-protection run established it by running
an arm that asked for 2048 explicitly and reproducing its control's throughput to 1.2 ms. Left as a default
it would have been a default resolved **from how much card the engine has**, so the split engines could
silently have run a different budget from the exclusive one — and that run measured the budget moving the
premium tail about fivefold, which is the size of effect this matrix is looking for.

`internal/bench`'s contract tests hold this: any flag the exclusive engine passes must be passed identically
by both split engines unless it is named in an allow-list with a reason, and a flag added to either side
later fails the suite until somebody decides which case it is.

**This run therefore reports nothing about what budget a half-card engine would choose for itself.** That is
a real question and it is not this one.

## The bars do not move, and that is deliberate

**Premium TTFT p99 at or below 2x R1. Premium TPOT p99 at or below 1.25x R1.** The same numbers the
price-of-protection run used, and the same ones M5-b's 1.25x descends from.

They are carried forward rather than chosen, and carrying them forward is the only choice that cannot be
accused of fitting. Every cell in the last run missed the tail bar by an order of magnitude; a bar picked
now, with those numbers in hand, would be picked for reachability. `2026-09-09-what-would-have-to-change.md`
says a successor may set a different bar only from a stated service objective that does not read that run's
results, and no such objective has been stated, so the bar stays where it was.

The share and throughput bars change, because the quantity they were about changes. Splitting a card is
supposed to cost capacity — that is the trade being measured, not a defect — so the aggregate-throughput
clause is replaced by reading 1b's job of reporting the price rather than gating on it.

## Pre-registered readings

Evaluated in this order. **The first that fires is the answer.**

### 4. The load did not create contention — INVALID

If `shared`'s premium TTFT p99 is under 5x R1's, this trace is not producing the interference the run exists
to study. Same threshold and same reason as the previous study's reading 4.

### 4b. The load was too high to measure — INVALID

If any arm completed fewer than `MinTailSamples` premium requests, or fewer than `MinTailSamples` of the
contender's, the run is INVALID. `MinTailSamples` is 100 and is derived in `internal/bench/report.go` from
the nearest-rank percentile, not chosen here.

**Applied to every arm, not only the control.** The previous study put this floor on the control alone,
because the control was the denominator of every ratio. Here a split card gives each engine less to work
with, so an arm collapsing is a live outcome for the arms themselves and not just for the baseline.

### 4c. The sharing mode did not engage — INVALID for that arm

If the MPS arm ran without the control daemon reachable, it is the time-slicing arm under another name.
`hack/m5c-matrix.sh` already refuses this rather than reporting it; the reading exists so the refusal is a
registered outcome rather than a script detail.

### 1. Separation protects — POSITIVE, and this is the deliverable

A sharing arm fires this if **all three** hold against R1:

- premium TTFT p99 at or below **2x**, and
- premium TPOT p99 at or below **1.25x**, and
- **reading 2 does not hold for that arm** — the tail was not bought by starving the contender.

If both sharing arms fire, the answer is the one with the higher contender throughput. Exact ties go to
`timeSlicing`, because MPS needs a control daemon that can be absent, and the simpler mechanism is the
smaller claim.

**The third clause was added on 2026-09-10, before any card, and it is a correction rather than a
tightening.** This reading first listed only the two bars. Reading 2's condition — meets both bars *and*
starves the contender — is then a strict subset of this one, and "the first that fires is the answer" would
have reported an arm that bought its tail by taking the other tenant's work as POSITIVE, with reading 2
never reached. **Reading 2 was unreachable.** That is the same defect class this page was written to close:
the previous study's readings did not cover their own outcome space, and here two of them overlapped instead
of leaving a gap. Found by implementing them, which is why implementation is a gate on renting a card.

The price-of-protection evaluator does not have this problem because its reading 1 gates on the contender's
share directly. This page deliberately removed that bar — splitting a card is *supposed* to cost capacity —
and removing it is what left the overlap.

**The price is reported, not gated on.** The write-up's first sentence must carry the premium tenant's
throughput under the winning arm as a fraction of R1's. Protection that costs half the machine is a real
answer and a different product from one that costs a tenth, and a pass/fail line would report them
identically.

### 2. Separation protects only by starving the contender — NEGATIVE

If a sharing arm meets both bars while the contender's completed output falls below **75%** of its output
under `shared`, then the tail was bought by taking the other tenant's work rather than by dividing the card.

**Starvation must be shown, not inferred from a smaller number.** The run records, per tenant, completed
responses, admission rejections, client-side timeouts, streams that broke after their first token, and
requests still outstanding when the window closed. A share that fell because work was delayed is a different
finding from one that fell because work was refused, and only the second is this reading.

### 3. Splitting the card changes nothing that matters — INCONCLUSIVE

If no sharing arm improves premium TTFT p99 over `shared` by more than `shared`'s own
repetition-to-repetition spread, then dividing the machine does not move this load and the next step is
neither this mechanism nor another sweep of it.

### 5. It protects but not to the bar — the outcome the last study had no name for

If a sharing arm improves premium TTFT p99 over `shared` by more than the spread, but no arm meets **both**
bars, **that is this reading and it fires.**

**"Both bars" is an amendment made on 2026-09-11, and the freeze clause at the top of this page had already
begun.** It is recorded here rather than made quietly, and what follows is the argument for it. Disagree
with the argument and the amendment should be reverted, not kept because it is already in the code.

This reading first said "no arm meets the 2x bar" — the tail bar alone. Reading 1 gates on two bars, and so
does reading 2. So an arm that holds the tail inside 2x while its stream runs at ten times R1's fires
**nothing**: not 1 or 2, which want both bars, not 3, which wants no improvement over the control, and not
this reading, which turned it away for having met the tail bar. **That is the identical gap this page was
written to close**, one bar over from where the last study left it.

Three things make the amendment legitimate rather than convenient:

- **No paid run has produced a scorable result.** Three pilots have been bought and every one of them
  ended in a defect; the only evidence ever scored came from stub engines in a rehearsal. There is no
  outcome this change could be fitted to, because there are no outcomes.
- **It moves no threshold.** 2x and 1.25x are untouched, and so is every other reading's condition. What
  changes is which reading claims a region of the outcome space that currently belongs to none of them.
- **It was found by a machine, not by a preference.** A mutation battery against the scorer showed the
  stream bar was pinned by no test; writing that test produced the arm above, and the arm had no reading.

With the amendment the four readings partition the improved-arm space: met both bars with the contender's
work intact is 1, met both by starving it is 2, improved on the control without meeting both is this
reading, and failed to improve beyond the control's own noise is 3.

**What this does not claim.** The readings are still not mutually exclusive ACROSS ARMS — time-slicing can
satisfy reading 1 while MPS satisfies reading 2 — and a large enough control spread can satisfy 1 and 3 at
once. First-match ordering picks the answer; it does not make the predicates disjoint. That was true before
this amendment and remains true after it.

It exists because the previous study's readings did not cover their own outcome space. Reading 2 there
required some cell to have met the bar; reading 3 required no cell to have beaten the control; the evidence
landed between them and nothing fired. That gap is closed here in advance rather than after seeing which way
the numbers went. The write-up reports the improvement and the remaining distance, and the milestone closes
on it as a measured partial result.

## The load has to be re-derived before this is bought

The price-of-protection load was derived against ONE engine with the whole card. This run gives each tenant
an engine with half of it, so the same offered rate may saturate what it now has.

The derivation is the same shape as `2026-09-08-the-load-needs-an-upper-gate.md`: measure the sustained
prefill throughput of a single engine on half a card, hold the premium tenant's rate fixed because it is a
few percent of capacity and moving it changes what the result means, and set the contender's rate so the
offered prefill sits near 60% of what the split engine can do. Reading 4b is the backstop if that derivation
is wrong.

**And the mix, not only the rate.** Defect 6 above is the reason this is spelled out. `gen-trace` defaults
to premium 1 / noisy 1 / two probes at 0.1, which puts the 40,000-character contender at 45% of arrivals; at
about 1.03 s of engine per contender prompt that is four to five times an A10G's prefill capacity at any
rate this study could use. Lowering `RATE` until the contender fits drops the premium tenant below the
hundred-sample floor reading 4b enforces, so **no value of `RATE` alone produces a valid trace**. The
price-of-protection run measured `RATE=9.85 PREMIUM_WEIGHT=1 NOISY_WEIGHT=0.054 PROBE_WEIGHT=0.0054
DURATION_MS=420000` for one engine with a whole card; that is a starting point for the derivation, not its
answer, because each engine here has half a card. The runner refuses to start without all five.

**This is a pilot's job, not the confirmatory run's.** No confirmatory time may be bought until a pilot has
cleared readings 4, 4b and 4c and produced a load whose derivation is written down.

## Budget

Corrected on 2026-09-10 for the platform change, before any card time was bought. The old figures assumed a
self-contained Spot instance the runner did not use; the new ones assume the one it now does.

| stage | cost | gate |
| ----------------------------------------- | ----: | ---- |
| ~~prerequisite: implement this page's readings~~ | $0 | **done.** `internal/bench/sharing_matrix.go` evaluates 4, 4b, 4c, 1, 2, 3 and 5 in that order, dispatched from `benchharness report`; each was deliberately failed to confirm it fires. Writing it is what found defect 9 |
| ~~prerequisite: `hack/m5c-gpu-session.sh`~~ | $0 | **done.** Nine characterization scenarios recorded and replayed, and its GPU-free bring-up rehearsed end to end on a real kind cluster through `hack/test/rehearse-bringup.sh` |
| ~~prerequisite: run the matrix itself off a card~~ | $0 | **done.** `hack/test/rehearse-m5c-matrix.sh` runs all four arms end to end on kind and evaluates the readings over what they wrote. It found defects 13 and 14 |
| already spent | **$2.03** | three pilots. The first bought nothing (defect in this session's own runner), the second bought defects 10-12 and a complete `shared` measurement, the third was cancelled on a credential margin |
| pilot: R1, `shared`, `timeSlicing`, `mps`, 1 rep | ~$0.90 | 4, 4b and 4c must not fire, and the load derived and written down |
| confirmatory: the same four arms x 3 reps | ~$2.10 | readings evaluated by the code above, not by hand |
| unspent reserve | ~$1.00 | — |

**~$0.90, and it is lower than the original $1.30 rather than higher.** `g5.2xlarge` Spot is $0.68/h against
the $0.58/h `g5.xlarge` this page first costed, but the EKS control plane at $0.100/h and the NAT gateway
the cluster path implies are both gone. The runtime model is the one fitted to three paid runs in
`2026-09-08-the-load-needs-an-upper-gate.md` — 15 min fixed, 1.5 min per arm, 7 min per arm-repetition at a
420 s trace — with the fixed cost raised to about 25 min, because a kind session installs a driver, a
container toolkit and a cluster where a `docker run` session installs nothing. Four arms at one repetition
is then about 70 min; at three repetitions about 130 min.

**130 minutes does not fit a two-hour backstop, and the confirmatory run is bought as three separate runs of
one repetition for that reason as well as the original one** — an interruption costs one repetition rather
than everything, and repetitions on separate instances put instance-to-instance variation inside the spread
reading 3 uses as its threshold.

The pilot's real gate is not its price. It is that a rented card can only tell us things a cluster cannot,
and everything a cluster could tell us has now been asked: the deployment path is rehearsed, the routing is
proved, and the eight defects above are closed. What is left needs an A10G.

**Spot prices, read from `ec2 describe-spot-price-history` on 2026-09-10 in `ap-northeast-2`, all three
zones:** `g5.2xlarge` $0.680–0.689/h, `g5.xlarge` $0.574–0.596/h. Both in a default public subnet, so
inbound crosses an internet gateway rather than a NAT gateway — which is where earlier paid runs lost
$0.059/GB on 15.6 GB of image and weights. The runner refuses to launch on credentials that would expire
before the run finishes.

## What this run will not be able to say

- **Anything about per-engine GPU utilisation.** Under sharing a busy SM belongs to no engine, and the
  instrument says so rather than guessing.
- **Anything about a bigger card, or two cards.** One A10G, split two ways.
- **Anything about MIG.** The A10G does not support it; a partitioned card is a different mechanism from
  either of these and is not on this page.
- **A general claim that separation cannot protect a tail**, if it does not. One model, one card, one
  arrival trace, two mechanisms.
- **Anything about what this costs to operate.** Every cost here is capacity and tenant share, measured on
  Spot for under two hours. It is not an operating cost model.

## What was decided before any data

The bars, the arm set, the reading order, the outcome space including reading 5, the floor applied to every
arm rather than the control alone, and the requirement that a pilot derive the load. Recorded here so that
what a later reader compares the results against is this page rather than a memory of it.

**And, from 2026-09-10 and still before any card:** the platform, the instance type, the corrected budget,
which engine settings may differ between the arms and which may not, that the trace's tenant mix is derived
rather than defaulted, and that the readings must exist in code before anything is rented.

Every one of those was decided from arithmetic, from the previous run's evidence, or from a rehearsal on a
free cluster. **None of them was decided from a result of this study, because this study has none.** The
distinction is the whole value of a page like this, so it is worth being explicit: the corrections above are
what a pre-registration is *supposed* to absorb — they were bought by reading and rehearsing rather than by
a card, and they arrived while editing was still allowed. What may not happen after the pilot is bought is
a change to the bars, the readings, or the order they are evaluated in.
