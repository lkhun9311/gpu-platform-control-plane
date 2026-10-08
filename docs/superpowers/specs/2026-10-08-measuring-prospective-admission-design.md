# Measuring prospective admission directly (item 3): the design

*Drafted 2026-10-08, for the owner's approval before anything is built. The owner approved paid runs for this direction on 2026-10-08. Nothing is bought until a registration built from this design is frozen. Proposed by codex `gpt-6-astra` (independent design, 2026-10-08) and reviewed and amended by me where marked.*

## The question

From `2026-10-06-m5b-stays-closed-and-what-a-successor-needs-first.md`, section 3:

> Does **prospective** admission protect the premium TTFT tail better than pressure-blind shedding at comparable admitted work, on an engine whose priority is bound to the tenant's tier and whose batch budget is fixed in advance?

Prospective admission reserves a standard request's input before forwarding and releases it at the first body byte, with a bound on active standard streams.

It must not win by deletion:
- contender work and output share stay at or above 75% of an unshed arm;
- aggregate throughput stays at or above 95%.

Item 2's simulation stays closed (`2026-10-08-is-s1-enough-for-the-feasibility-check.md`), so this is measured.

**A qualification the registration must state.** The gateway releases a reservation at the first *body byte*, not the first content token (`internal/gateway/proxy.go`). The pilot measures both, and the study tests the implementation as shipped.

## Arms (one gateway, one backend, nonbinding RPM limits)

**Every arm.**
- Gateway: `--bind-priority --enforce-benchmark-profile`, and the harness sends no priority.
- Engine: Qwen2.5-3B-Instruct at the pinned revision, half precision, max-model-len 16,384, 64 sequences, memory 0.90, prefix caching **off**, chunked prefill with **budget 512**, `--scheduling-policy=priority`, the pinned image digest.
- Budget 512 is fixed in advance from the scheduler microtest, not tuned here. It is not the 2,048 of the step-timing studies.

| Arm | Gateway admission | Role |
|---|---|---|
| I, isolation | off; premium requests only | the absolute reference |
| O, unshed | off | the contention, and the safeguards' denominator |
| S, static | `static-cap`, long threshold 1, burst 30,000, rate R | pressure-blind shedding, matched to P on admitted work |
| P, prospective | `prospective`, prefill tokens 30,000, streams 4 | the arm under test |

**Matching S to P,** frozen before the pilot:
1. Measure P's admitted fraction of exact standard input on three pilot traces.
2. Simulate S offline (`benchharness sim-cap`) at burst 30,000 for integer R.
3. Freeze the R closest to P's fraction, ties to the lower R, if within 2.5%.

In confirmation, |w_S − w_P| / w_P ≤ 0.05 or the matched comparison is invalid. R is never re-tuned on confirmatory data.

## Load (frozen, independent Poisson arrivals)

| Tenant | Prompt | Gateway units | Rate | Output cap |
|---|---|---:|---:|---:|
| Premium | 200 characters | 50 | 9.25/s | 64 |
| Contender | 40,000 characters | 10,000 | 0.50/s | 16 |

- Each replay is 420 s of arrivals, a 30 s whole-request timeout, and no client retries.
- Seeds: pilot 1001–1003, confirmation 2001–2020.
- Every offered prompt is stamped with the pinned tokenizer's exact count before checksumming.

**The prospective caps** (3 reservations of 10,000 units, 4 streams) are twice the contender's mean outstanding population in the archived 512/priority runs, rounded up. That rule is a heuristic, frozen in advance, not a fitted optimum.

## Endpoints and decision

**Primary:** P/S, the ratio of pooled premium client TTFT p99. Success requires both:
- the point estimate at or below 0.90;
- the paired-block 95% upper bound below 1.0, from 10,000 resamples of whole blocks at seed 20261008.

**Also required:** the P/O upper bound below 1.0.

**Published, not gating:** P/I, against the earlier 1.25× absolute-protection benchmark.

**Safeguards,** for P and for S against O, by point estimate and paired-block lower bound:
- contender admitted exact input ≥ 75%;
- contender completed work and output share ≥ 75%;
- aggregate completed output tokens per second ≥ 95%.

All are counted over a common 450-second window with a ledger of refusals, errors, timeouts and outstanding requests.

**Invalid if any of these occurs:**
- missing accounting or configuration;
- an unmatched admission;
- any shed premium request;
- 1% or more of premium requests timing out or failing in any repetition.

Every other outcome is reported by name: benefit, benefit that fails safeguards, or no demonstrated benefit.

## Repetitions, power and cost

**Repetitions.** 20 complete four-arm blocks, each with a fresh trace, in a randomised balanced arm order.

**Amended (mine).** astra proposed a fresh instance per block. I propose several blocks per instance instead, because each instance costs about 15 minutes of bring-up:
- four instances of five blocks each;
- the engine restarted and drained between arms;
- the instance recorded as a block covariate.

Instance-to-instance variation is then visible rather than confounded with blocks.

**Power, a surrogate estimate.** Using a paired log-ratio SD of 0.33, from fresh-trace archives, 20 blocks give about 80% power at a true P/S of 0.80; detecting 0.90 would need about 80 blocks. The registration states this, and buys no outcome-dependent extension.

**Cost.**
- A pilot of at most 2 hours on one g5.xlarge Spot instance.
- Then about 16 to 18 instance-hours for 20 blocks.
- Expected $12 to $13 at about $0.65 per hour; the ceiling frozen with the registration.

## What must be built before any purchase

1. A new study id, a frozen manifest, and readings for this study, rather than relabelling M5-b's, whose checks require `kv-aware`.
2. A runner:
   - fresh traces per block and several blocks per instance;
   - a staged pilot-then-freeze;
   - safeguards counted from the engine's exact output;
   - uploads after every arm;
   - an independent terminate per instance.
3. Recording of the gateway-bound priority in the raw rows, and of first-body against first-content timing.
4. Rehearsals on kind:
   - the existing prospective rehearsal;
   - the whole replay-to-verdict path, including a deliberate mismatch, a missing token count, a censored tail and an interrupted upload.

## Risks this project has already paid for

- wrong admission units or burst;
- prefix caching inflating prefill;
- wrong tenant or model routing;
- ineffective priority;
- evidence lost at a deadline or a Spot interruption;
- log rotation on long cells, `2026-10-07-confirming-s1-on-unseen-settings.md`.

Each needs a check before purchase.
