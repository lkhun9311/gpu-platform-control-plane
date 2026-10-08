# Measuring prospective admission directly (item 3): the design, v4

*Drafted 2026-10-08 for the owner's approval before anything is built. The owner approved paid runs for this direction on 2026-10-08, and asked for the design to be attacked as hard as possible before money is spent. Nothing is bought until a registration built from this design is frozen.*

## History of this page

| Version | Commit | Answered | Review findings |
|---|---|---|---|
| v1 | dcc58b0 | proposed by codex `gpt-6-astra`, amended by me | — |
| v2 | 8154cbe | astra's review of v1 | 4 blockers, 10 majors |
| v3 | 29ed20b | astra's review of v2 | 5 blockers, 11 majors |
| v4 | this page | astra's review of v3 | 4 blockers, 6 majors, 1 minor |

**Who established what.**
- astra read the code and found the defects. Each round was given only the page and the repository, never told where to look.
- I re-read every line it cited before accepting a finding, and re-derived every figure on this page.
- The power figures below are mine, by simulation. astra has not checked them, and the next round is asked to.

**What v3 said wrongly about the existing validator.** It said `hack/lib/instrument-validation.sh` checks only the revision. In fact it also checks synchronous scheduling, the scheduler class and iteration logging. What it does not check is the scheduling policy and the batch budget (round 3, finding 11).

## The question

> Does **prospective** admission protect the premium TTFT tail better than pressure-blind shedding **that rejects at least as much contender work**, on an engine whose priority is bound to the tenant's tier and whose batch budget is fixed in advance?

**The claim is narrow:**
- relative TTFT-tail protection against a static control that deletes at least as much;
- for clients that do not retry;
- on vLLM with synchronous scheduling.

Premium TPOT and P/I are published beside it.

## Arms

Same instance and same trace within a block, with the arm order randomised per block.

| Arm | Gateway admission | Role |
|---|---|---|
| I, isolation | off; premium requests only | premium-only reference, published, not gated |
| O, unshed | off | proof the contention exists; P/O is a secondary endpoint |
| S, static | `static-cap`, long threshold 1, burst 30,000 estimated units, rate R | pressure-blind shedding that deletes at least as much as P |
| P, prospective | `prospective`, 30,000 estimated units (about 23,000 exact tokens, three contenders) and 4 streams | the arm under test |

**Gateway, every arm:** `--bind-priority --enforce-benchmark-profile`, and the harness sends no priority. The benchmark profile is extended to accept `min_tokens` equal to `max_tokens` and nothing else (build item 2). Today it rejects the field with a 422 before admission (round 3, finding 1).

## Engine, every arm, proved rather than asserted

**The frozen apparatus.**
- Qwen2.5-3B-Instruct at revision `aa8e7253…`, half precision.
- max-model-len 16,384; 64 sequences; memory 0.90; prefix caching off.
- Chunked prefill with budget **512**.
- `--scheduling-policy=priority`.
- The image pinned by digest.
- The step-logging scheduler plugin, with `--no-async-scheduling`.

**Synchronous scheduling is part of the apparatus.** The plugin subclasses the synchronous scheduler, every arm shares the setting, and the claim says synchronous.

**Proof, read at every engine start:**
- The non-default-arguments line is validated. The existing validator already checks the revision, synchronous scheduling, the scheduler class and logging. It gains the policy and the budget (build item 5), mutation-tested with `fcfs` and with 2,048.
- The plugin records the priority each request reached the scheduler with. Every premium request must show 0 and every standard one 1.

## The comparator deletes at least as much as P

v3 let P reject one percentage point more than S, and round 3 showed two problems with that:
- **Finding 6:** extra deletion alone can move a p99. If 1.2% of premium requests are slow under S and 0.9% under P, the p99 falls from the slow value to the fast one.
- **Finding 7:** at r_S = 0.81 and r_P = 0.82, the contender safeguards are 18/19 = 0.947, below their 0.95 margin at any sample size.

**v4 removes the allowance in P's favour. Validity requires S to reject at least as much contender work as P,** so extra deletion can only help the control.

- **r** = refused exact standard input tokens / offered exact standard input tokens, pooled.
  - Standard requests are identified by tenant.
  - A row with no tier refuses the run.
  - "Refused" means the gateway answered with an admission refusal.
- **Valid:** r_S ≥ r_P, pooled over all main blocks. Also checked after the first look (see Decision). A failure there stops the purchase, and the outcome is "invalid".
- **Informative:** r_S − r_P ≤ 0.03, so the control is not crippled. Above it, the outcome is still judged, but published as "against a control that deleted N points more".
- **Engagement bound:** P refuses at least 5% and at most 30% of contender requests in pilot stage A.

**Under validity, the safeguards' true values are at least 1** whenever admitted work completes: (1 − r_P)/(1 − r_S) ≥ 1. That answers finding 7 rather than tuning around it.

**Fitting R, in pilot stage A, which has no S arm:**
- `sim-cap` replays stage A's three P traces at each request's **recorded gateway arrival time** (build item 4).
- It uses threshold 1, burst 30,000 and the premium tenants named explicitly.
- R is the largest integer in 1…20,000 with r_S ≥ r_P + 0.01 on every one of the three traces. The margin absorbs the difference between simulation and reality.
- If no such R gives r_S − r_P ≤ 0.03 on the pooled traces, the design returns to review.
- R is committed before stage B.

**No interval is computed for r.** Admission outcomes share reservations and streams, so they are not independent trials. The rule is a point rule on pooled counts, and the counts are published.

## Load

Frozen, independent Poisson arrivals:

| Tenant | Prompt | Estimated units | Exact tokens (stamped, checked) | Rate | Output: minimum = cap |
|---|---|---:|---:|---:|---:|
| Premium | 200 characters | 50 | about 68 | 9.25/s | 64 |
| Contender | 40,000 characters | 10,000 | about 7,695 | 0.50/s | 16 |

**Per replay:**
- 420 s of arrivals;
- a 30 s whole-request timeout;
- no retries;
- about 3,885 premium and 210 contender requests.

**Output is fixed by `min_tokens` equal to the cap.**
- The Poisson generator populates it (build item 3); today it does not.
- A completion with fewer engine-reported output tokens than its cap is a failure, not a completion.

## Endpoints and decision: one ratio per instance

v3's request-level bootstrap over instances had two defects:
- with 8 to 12 instances it gives an interval of unknown coverage;
- one heavy-loss instance drawn twice makes ∞/∞, which happens in 26% of resamples in round 3's finding 3 example.

v3's power simulation also could not be built from the pilot it described (findings 2 and 5). So v4 analyses each instance as one unit.

**Per instance and arm:**
- The pooled premium TTFT p99 over that instance's completed blocks, with every premium failure (timeout, error, short completion, or unserved because a block ended early) at +∞.
- About 11,600 premium requests per arm over three blocks, so each instance's p99 rests on about 116 requests above it.

**Loss.** If any arm on any contributing instance has 1% or more premium loss, the study's outcome is **invalid**.
- The rule is whole-study, so no instance is dropped by outcome.
- It also guarantees every per-instance p99 is finite.

**Per instance:** y_i = ln(p99_P / p99_S); likewise ln(p99_P / p99_O) and the safeguards' log ratios.

**Decision: two looks, a one-sided t-interval across instances.**
- **Look 1, at 6 contributing instances.**
  - Benefit if the upper 99% bound of mean y is below ln 0.95.
  - Futility if the mean of y is at or above ln 1.0 (P/S ≥ 1): stop, with outcome "no demonstrated benefit".
  - Otherwise continue.
- **Look 2, at 12 contributing instances, or when launches are exhausted.** Benefit if the upper 96% bound of mean y is below ln 0.95.

The two levels sum to 0.05, so the overall error is at most 5% by the union bound. In simulation at a true P/S of 0.95 it was 4.4% to 4.7%, for σ from 0.05 to 0.30.

**"Benefit" also requires, at the same look and level:**
- P/O's upper bound below ln 1.0;
- each safeguard, P against S, with its lower bound above ln 0.95:
  - contender completed exact input tokens;
  - contender completed requests;
  - premium completed requests.

**Power of the primary,** at a true P/S of 0.80. σ is the SD of y across instances, between- and within-instance together. My simulation (20,000 studies per row):

| σ | Benefit at look 1 | Benefit overall |
|---:|---:|---:|
| 0.10 | 76% | 100% |
| 0.15 | 39% | 97% |
| 0.20 | 23% | 85% |
| 0.30 | 10% | 54% |

**The purchase does not depend on estimating σ beforehand.**
- The t-interval reads σ from the instances themselves, which the pilot could not do (finding 2).
- The registration publishes this table. The owner accepts it as the risk: at σ = 0.30, half the time the study ends without a verdict.
- The safeguards and P/O enter the joint verdict, and the table is for the primary alone.
- Under validity the safeguards' true values are at least 1, so they cost little power. P/O's cost depends on the true P/O, which only stage A will suggest.

**Outcomes, named in advance:**
- invalid;
- benefit;
- benefit that fails safeguards;
- no demonstrated benefit.

## Pilot, in two stages, neither in the main analysis

**Stage A: one instance, three blocks of I, O and P** (randomised order). It establishes:
- **contention:** O's pooled premium TTFT p99 ≥ 1.5 × I's;
- **no overload:** O completes ≥ 99% of premium and ≥ 95% of contender requests;
- **engagement:** P refuses 5% to 30% of contender requests;
- **release timing:** in P, at least 95% of admitted contenders have 50 ms or less between the gateway's release instant (build item 6) and the first content byte;
- **restart:** an engine restart between arms reuses host-path weights and takes under 3 minutes.

Then it fits R.

**Stage B: one instance, two full four-arm blocks with R frozen.** It establishes:
- validity, r_S ≥ r_P, on fresh traces;
- the whole four-arm cycle at full duration on the GPU.

**Every gate refuses the main purchase if unmet. None reads P against S's tail.**

## Evidence that survives an early end

**Raw rows are written incrementally,** one durable line per finished or failed request (build item 8). Today `cmd/benchharness` writes the file only after the whole replay returns, and a cancellation drops unsent rows (round 3, finding 8).

**Reconstruction against the frozen block plan.** Every planned request either has a row or is counted as a failure. An arm with no raw file at all counts every one of its premium requests as lost.

**Spot interruptions are evidenced, not inferred.** Today the runner reads only an S3 marker and the EC2 state, and `terminated` looks the same whatever caused it (finding 9). Build item 9 records them:
- the instance polls the metadata service's `spot/instance-action` and uploads a notice marker;
- the runner records the instance's `StateReason`.

A block cut short by an evidenced Spot interruption is dropped whole. Anything else ending a block early drops nothing: reconstruction applies.

**Counting instances (finding 10):**
- An instance **contributes** if it completed at least one block.
- Looks count contributing instances, not launches.
- Main launches are capped at **14** in total, replacements included.
- If 14 launches yield fewer than 12 contributing instances, look 2 uses what exists, and the publication states the reduced count.

## What must be built before any purchase

1. **A new study, `prospective-admission`,** with its arms, a frozen manifest and readings. M5-b's study permits `kv-aware`, not `prospective` (`study.go:529`).
2. **The benchmark profile accepts `min_tokens` only when equal to `max_tokens`,** with a test that any other value is still refused.
3. **The Poisson generator populates `MinOutputTokens`.**
4. **The gateway records each request's arrival instant,** the raw rows carry it, and `sim-cap` replays it. Today it replays scheduled offsets (`simcap.go:74`).
5. **The validator checks the policy and the budget,** mutation-tested.
6. **The gateway records each request's release instant.**
7. **The matrix deploys admission per arm** (today it deploys admission off, `m5c-matrix.sh:2187`), and step-log capture waits for the last **forwarded** request (`m5c-matrix.sh:3032`).
8. **Incremental raw rows, and reconstruction against the block plan.**
9. **The Spot interruption recorder.**
10. **The plugin records the scheduler-side priority.**
11. **The model cache on a host path** for this study's engine, in place of `emptyDir`.
12. **The credential check refuses when:**
    - it cannot establish an expiry;
    - sts cannot name the active role;
    - a cache entry carries only an account rather than the exact role path.
13. **The per-instance censored p99, the two-look t decision and the joint verdict,** tested on hand-built evidence that includes a censored instance and a loss at exactly 1%.
14. **The reserving spend ledger** (see Cost).
15. **Rehearsals on kind with the stub engine:**
    - a whole replay-to-verdict run;
    - r_S < r_P;
    - a missing tier;
    - a censored tail;
    - a short completion;
    - a refused final contender;
    - the harness killed mid-replay;
    - an interrupted upload;
    - a full-duration four-arm cycle with engine restart and log capture.

## Credential windows

The AWS SSO session lasts at most 12 hours from a login.
- Each session is one instance.
- The owner logs in immediately before each login's first session.
- No launch proceeds unless the expiry, established under build item 12, exceeds the session's backstop plus 30 minutes.

## Cost

**Every session sets its own deadlines, overriding the runner's defaults** (16,800 s hard stop, 17,400 s backstop):

| Session | Expected hours | Hard stop | Backstop |
|---|---:|---:|---:|
| Pilot A, B | about 2.1 and 1.9 | 2.5 h | 2 h 40 min |
| Main, each | about 2.75 | 3.5 h | 3 h 40 min |

**Worst case.** Every launch runs to its backstop at the $1.10 Spot cap, plus 200 GB of gp3 at about $0.022 per hour: (2 × 2.67 h + 14 × 3.67 h) × $1.122 = **$63.58**.

**Expected:**
- about $14 if look 1 decides at 6 instances;
- about $25 at 12 instances.

Both are at about $0.65 per hour plus the volume.

**The ledger reserves before it records.**
- Each launch first appends its worst case (backstop × cap, plus the volume) as a reservation.
- It refuses if the reservations and recorded sessions together would exceed **$65**.
- After the session it records the instance's launch and termination times, from EC2 and CloudTrail. Those are times, not a bill.
- Billed amounts come from Cost Explorer when it settles, and are published beside the estimate. They do not drive the gate.

**The pilot alone is about $2.70 expected and at most $6.** It can stop the study before any main purchase.

## What v4 changed, against the review of v3

| v3 finding | Change |
|---|---|
| 1: the profile rejects `min_tokens`; the generator never sets it | build items 2 and 3 |
| 2: the pilot cannot estimate between-instance variance | no pre-estimate: per-instance t-interval reads σ from the instances, with a published power table |
| 3: ∞/∞ in the bootstrap | the bootstrap is removed; whole-study invalidity at 1% loss on any instance keeps every per-instance p99 finite |
| 4: the ceiling was not bounded | explicit deadlines per session; EBS counted; a reserving ledger; $65 |
| 5: the simulation was inconsistent | removed; power by t-simulation on y |
| 6: extra deletion can make the benefit | S must delete at least as much: r_S ≥ r_P |
| 7: the safeguards were infeasible under the match | under r_S ≥ r_P their true values are at least 1 |
| 8: evidence lost on an early end | incremental rows; reconstruction against the plan |
| 9: no Spot notice recorder | build item 9 |
| 10: instance accounting | contributing instances; 14 launches including replacements |
| 11: the validator's scope misstated | corrected in History |
