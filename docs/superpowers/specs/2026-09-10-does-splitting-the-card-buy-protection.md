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

## Design

Three arms, already built and tested in `hack/m5c-matrix.sh`, on one `g5.xlarge` (one A10G):

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

A sharing arm fires this if **both** hold against R1:

- premium TTFT p99 at or below **2x**, and
- premium TPOT p99 at or below **1.25x**.

If both sharing arms fire, the answer is the one with the higher contender throughput. Exact ties go to
`timeSlicing`, because MPS needs a control daemon that can be absent, and the simpler mechanism is the
smaller claim.

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

If a sharing arm improves premium TTFT p99 over `shared` by more than the spread, but no arm meets the 2x
bar, **that is this reading and it fires.**

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

**This is a pilot's job, not the confirmatory run's.** No confirmatory time may be bought until a pilot has
cleared readings 4, 4b and 4c and produced a load whose derivation is written down.

## Budget

| stage | cost | gate |
| ----------------------------------------- | ----: | ---- |
| pilot: R1, `shared`, `timeSlicing`, `mps`, 1 rep | ~$1.30 | 4, 4b and 4c must not fire, and the load derived |
| confirmatory: the same four arms x 3 reps | ~$2.90 | readings evaluated |
| unspent reserve | ~$1.00 | — |

Costed from the runtime model fitted to three paid runs in `2026-09-08-the-load-needs-an-upper-gate.md`:
15 min fixed, 1.5 min per arm, 7 min per arm-repetition at a 420 s trace. Four arms at one repetition is
about 55 min; at three repetitions about 105 min. Both fit the two-hour instance backstop, and the
confirmatory run is bought as three runs of one repetition each for the reason that page gives — an
interruption then costs one repetition rather than everything, and repetitions on separate instances put
instance-to-instance variation inside the spread reading 3 uses as its threshold.

**A g5.xlarge Spot in a public subnet measured $0.58–0.60/h across three zones.** The runner refuses to
launch on credentials that would expire before the run finishes.

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
