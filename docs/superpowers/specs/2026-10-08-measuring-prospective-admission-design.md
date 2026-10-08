# Measuring prospective admission directly (item 3): the design, v2

*Drafted 2026-10-08 for the owner's approval before anything is built. The owner approved paid runs for this direction on 2026-10-08, and asked for the design to be attacked as hard as possible before money is spent. Nothing is bought until a registration built from this design is frozen.*

## History of this page

- **v1:** proposed by codex `gpt-6-astra` (independent design), amended by me.
- **v2:** answers astra's adversarial review of v1, which ranked 4 blockers and 10 major findings. The changes and the findings they answer are listed at the end.
- **My own review:** I re-derived every figure that review rested on.
  - 20 blocks give 86% power at a true P/S of 0.80, but about 30% at 0.90, and the v1 rule caps power at 0.90 at 50% for any number of blocks. v1 claimed 80 blocks would detect 0.90; that is false.
  - A safeguard whose true value equals its margin passes a 95% lower-bound gate 2.5% of the time.
  - Contender output is 1.33% of offered capped output, so an aggregate-output gate cannot detect deletion.
  - The m5c runner skips its credential-expiry check when the CLI cannot export an expiry and no cache exists.

## The question

> Does **prospective** admission protect the premium TTFT tail better than pressure-blind shedding at comparable admitted work, on an engine whose priority is bound to the tenant's tier and whose batch budget is fixed in advance?

It must not win by deletion.

**The claim is narrow, and stays narrow:**
- relative TTFT-tail protection against a matched static control, for clients that do not retry;
- premium TPOT and P/I are published beside it so that poor absolute service cannot hide behind a relative win.

**Release timing.** The gateway releases a reservation at the first response body byte (`internal/gateway/proxy.go`). In vLLM v0.27.1 the first body byte is the role frame, sent inside the result loop once the first output exists, after the prefill (`entrypoints/openai/chat_completion/serving.py`, lines 485–542; the earlier yields are the error path). So the reservation covers the prefill.
- The pilot measures first body byte against first content per request.
- If the median gap exceeds 50 ms, the registration stops, because the mechanism would then not be the one described.

## Arms

Same instance, same trace within a block, order randomised.

**Every arm.**
- Gateway: `--bind-priority --enforce-benchmark-profile`, and the harness sends no priority.
- Engine: Qwen2.5-3B-Instruct at revision `aa8e7253…`, half precision, max-model-len 16,384, 64 sequences, memory 0.90, prefix caching off, chunked prefill with budget **512**, `--scheduling-policy=priority`, the image pinned by digest.
- Engine configuration is **proved, not asserted**:
  - the engine's own non-default-arguments line must show the policy, the budget and the revision, by the m5c runner's existing process-arguments check;
  - the step-logging instrument, extended to record each request's priority as the scheduler received it, must show 0 for every premium request and 1 for every standard one.

  The gateway's header proves only what the gateway wrote.

| Arm | Gateway admission | Role |
|---|---|---|
| I, isolation | off; premium requests only | premium-only service reference, published |
| O, unshed | off | contention, and the safeguards' denominator |
| S, static | `static-cap`, long threshold 1, burst 30,000 estimated units, rate R | pressure-blind shedding, matched to P |
| P, prospective | `prospective`, 30,000 estimated units (about 23,000 exact tokens, three contenders) and 4 streams | the arm under test |

## Matching S to P, fully specified before the pilot

- **Population.** Standard-tier requests identified by tenant. A row with no tier refuses the run rather than counting as standard. Admitted means the gateway forwarded the request, including requests that later timed out.
- **w** = admitted exact standard input tokens / offered exact standard input tokens, pooled over the requests concerned.
- **Pilot.** On the pilot's four P replays (two instances, two blocks each), w_P is pooled over all four.
  - `sim-cap` replays the same four traces' recorded gateway arrival times, not their scheduled ones, with threshold 1 and the premium tenants named explicitly.
  - It does so at burst 30,000 and integer R = 1…20,000, and R is the value minimising |w_S − w_P| / w_P, ties to the lower R.
  - If that minimum exceeds 2.5% (relative), the registration stops.
- **Confirmation.** |w_S − w_P| / w_P ≤ 0.05, pooled over all blocks, or the matched comparison is invalid.
  - The match is also read after the first main session. Above 0.05 there, no further session is bought; the run stays invalid, and nothing is re-tuned or replaced.
- **Precision is stated, not assumed.** Four pilot replays hold about 840 contender requests. The registration reports w_P's binomial 95% interval beside the 2.5% band; at w = 0.85 the expected half-width is about ±2.9% relative, so the 2.5% band is narrower than the pilot can resolve and the confirmation threshold, not the pilot fit, is what guards the match.
- **A limitation published with any result:** P may admit up to 5% less work than S. The ledger reports by how much, and the sign is stated beside the tail result.

## Load

Frozen, independent Poisson arrivals:

| Tenant | Prompt | Estimated units | Exact tokens (stamped, checked) | Rate | Output cap |
|---|---|---:|---:|---:|---:|
| Premium | 200 characters | 50 | about 68 | 9.25/s | 64 |
| Contender | 40,000 characters | 10,000 | about 7,695 | 0.50/s | 16 |

Per replay: 420 s of arrivals, a 30 s whole-request timeout, no retries; about 3,885 premium and 210 contender requests.

**Pilot gates, each refusing the main purchase if unmet.** None reads P against S.
- O's pooled premium TTFT p99 is at least 1.5 × I's, so the contention exists.
- O completes at least 99% of premium and 95% of contender requests, so the engine is not overloaded.
- The P reservation is full on arrival for at least 5% of contender requests, so the mechanism engages.
- An engine restart between arms reuses the weights from a host-path cache and takes under 3 minutes.

## Endpoints, decision and power

**Censoring.** A premium request that times out or fails before its first content counts at +∞ in its arm's p99, so selective loss can only make an arm look worse. One whose first content arrived keeps its observed TTFT. A repetition with 1% or more premium loss is invalid.

**Primary:** P/S, the ratio of pooled premium TTFT p99. Success requires the one-sided 95% upper bound of P/S below **0.95**, so the benefit is at least 5% at that confidence.
- The v1 rule also required the point estimate to be at most 0.90. That capped power at 50% at a true 0.90 and added nothing the bound does not, so it is dropped.
- P/O's upper bound below 1.0 is also required.

**Safeguards,** P against O and S against O, each a one-sided 95% lower bound:
- contender completed exact input tokens in the 450-second window ≥ 0.75;
- contender completed requests ≥ 0.75;
- aggregate completed exact tokens per second (input plus output, from the engine's usage on clean completions) ≥ 0.95.

v1's aggregate-output gate is replaced, because contender output is 1.33% of the total.

**Interval: clustered by instance.** Blocks share an instance, so the bootstrap resamples instances, with blocks nested inside. Sampling blocks independently would treat correlated blocks as independent.

**Number of instances and blocks, fixed by rule before the main purchase:**
1. From the pilot (two instances, at least two blocks each), estimate the between-instance and within-instance SD of each endpoint's log ratio. Means are not used.
2. Simulate the full joint verdict (primary, P/O and the six safeguards) with that variance, at an assumed true P/S of 0.80 and safeguards at 0.90, through the same clustered estimator.
3. Buy the smallest number of instances, three blocks each, with simulated joint power at least 80%, at a minimum of 8 instances.
4. If more than 12 instances would be needed, do not buy, and report the study as unaffordable at this power.

**Outcomes, each named:**
- invalid;
- benefit;
- benefit that fails safeguards;
- no demonstrated benefit.

## Operations, each a check before purchase

- **The runner** is built on the m5c session and matrix, which already have:
  - provenance and process-argument checks;
  - per-cell uploads;
  - the kubelet log-rotation fix and rotated-log refusal;
  - Spot-lifecycle goldens.
- **The engine** keeps model weights on a host path, so restarts do not download. The pilot gate times it.
- **The credential check refuses, rather than skips, when it cannot establish an expiry.** The fallback path in `hack/m5c-gpu-session.sh` is fixed first. No session is launched without at least its estimate plus 30 minutes, and the owner logs in immediately before each.
- **Interrupted blocks.** A block that does not complete is dropped whole and never rerun. The next seed from a pre-registered list takes its place, in order.
- **Rehearsals on kind with the stub engine:**
  - a whole replay-to-verdict run;
  - a deliberate S/P mismatch;
  - a missing tier;
  - a censored tail;
  - an interrupted upload;
  - a full-duration arm cycle with engine restart and log capture, the omission behind the rotated-log refusal.

## Credential windows

The AWS SSO session lasts at most 12 hours from a login.
- **The pilot:** two sessions, one instance each, two blocks each, about 2 hours each, both in one login.
- **Each main session:** one instance, three blocks, about 2.5 to 3 hours (v1 measured about 15 minutes of bring-up and about 50 minutes per block). At most three run consecutively per login, so 8 to 12 instances need three or four logins.

## Cost

At about $0.65 per g5.xlarge Spot hour:
- the pilot, about 4 instance-hours, about $3;
- the main measurement, 8 to 12 instances at about 2.75 hours, so 22 to 33 instance-hours, about $14 to $21;
- a frozen ceiling of $26 for the whole study, recorded with the registration.

This is about twice v1's $12 to $13. The difference is what clustered power costs: v1's 20 blocks on 4 instances had 3 degrees of freedom between instances, not 19.

## What v2 changed, against the review of v1

| Finding | Change |
|---|---|
| 1, 2: power and the joint verdict | point rule dropped; joint power simulated with pilot variance; a stop if it needs more than 12 instances |
| 3: clustering | instance-level bootstrap; at least 8 instances; the cost roughly doubles |
| 4: censoring | losses count at +∞ |
| 5, 6, 7: matching | fully specified; pooled; recorded arrival times; tier required; early stop on mismatch; limitation published |
| 8: engine identity | process arguments and scheduler-side priority are proved |
| 9: uninformative load | four pilot gates |
| 10: tail precision | pooled p99 with the clustered bootstrap, sized by simulation |
| 11: release timing | measured, with a stop above 50 ms |
| 12: safeguards | defined on completed exact tokens; output gate replaced |
| 13: restarts and interruptions | host-path weights; whole-block drop, pre-registered replacement seeds; full-cycle rehearsal |
| 14: credentials | fallback refuses |
| 15: claim | narrow, with TPOT and P/I published |
