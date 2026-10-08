# Measuring prospective admission directly (item 3): the design, v5

*Drafted 2026-10-08 for the owner's approval before anything is built. The owner approved paid runs for this direction on 2026-10-08, and asked for the design to be attacked as hard as possible before money is spent. Nothing is bought until a registration built from this design is frozen.*

## History of this page

| Version | Commit | Answered | Review findings |
|---|---|---|---|
| v1 | dcc58b0 | proposed by codex `gpt-6-astra`, amended by me | — |
| v2 | 8154cbe | astra's review of v1 | 4 blockers, 10 majors |
| v3 | 29ed20b | astra's review of v2 | 5 blockers, 11 majors |
| v4 | 5daf5c7 | astra's review of v3 | 4 blockers, 6 majors, 1 minor |
| v5 | this page | astra's review of v4 | 4 blockers, 4 majors |

**Who established what.**
- astra read the code and found the defects. Each round was given only the page and the repository, never told where to look.
- I re-read every line it cited before accepting a finding, and re-derived every figure on this page.
- astra independently re-derived v4's power table (200,000 studies per row), and it agreed with mine within simulation error. The figures here are for v5's changed decision rule and are mine; the next round is asked to re-derive them.
- **Prices:**
  - $1.10 is the runner's own Spot cap.
  - The public IPv4 charge of $0.005 per hour is AWS's published rate.
  - For gp3 storage I use $0.10 per GB-month as an upper bound, not a quoted Seoul price.

## The question

> Does **prospective** admission protect the premium TTFT tail better than pressure-blind shedding **that rejects at least as much contender work on the same instance**, on an engine whose priority is bound to the tenant's tier and whose batch budget is fixed in advance?

**The claim is narrow:**
- relative TTFT-tail protection against a static control that deletes at least as much;
- for clients that do not retry;
- on vLLM with synchronous scheduling;
- for the population of instances the study sampled, under the assumption stated under Decision.

Premium TPOT, P/I and every instance's own ratios are published beside it.

## Arms

Same instance and same trace within a block, with the arm order randomised per block.

| Arm | Gateway admission | Role |
|---|---|---|
| I, isolation | off; premium requests only | premium-only reference, published, not gated |
| O, unshed | off | proof the contention exists; P/O is a secondary endpoint |
| S, static | `static-cap`, long threshold 1, burst 30,000 estimated units, rate R | pressure-blind shedding that deletes at least as much as P on every instance |
| P, prospective | `prospective`, 30,000 estimated units (about 23,000 exact tokens, three contenders) and 4 streams | the arm under test |

**Gateway, every arm:**
- `--bind-priority --enforce-benchmark-profile`, and the harness sends no priority.
- The benchmark profile is extended to accept `min_tokens` equal to `max_tokens` and nothing else (build item 2). Today it rejects the field with a 422 before admission.

## Engine, every arm, proved rather than asserted

**The frozen apparatus.**
- Qwen2.5-3B-Instruct at revision `aa8e7253…`, half precision.
- max-model-len 16,384; 64 sequences; memory 0.90; prefix caching off.
- Chunked prefill with budget **512**.
- `--scheduling-policy=priority`.
- The image pinned by digest.
- The step-logging scheduler plugin, with `--no-async-scheduling`.

**Synchronous scheduling is part of the apparatus.** The plugin subclasses the synchronous scheduler, every arm shares the setting, and the claim says synchronous.

**The whole non-default-arguments line is compared with the registration (build item 5).**
- Every registered key must appear with its registered value: dtype, context length, sequence count, memory fraction, prefix caching, chunked prefill, policy, budget, async, revision, tokenizer revision, scheduler class and logging.
- Any non-default key the registration does not name refuses the engine.
- Today's validator checks the revision, async, scheduler class and logging, and nothing else. astra ran it on a specimen with prefix caching on, bfloat16, one sequence, context 8,192 and memory 0.5, and it passed (round 4, finding 6). The build item is mutation-tested key by key with that specimen.

**The plugin records the priority** each request reached the scheduler with. Every premium request must show 0 and every standard one 1.

## The comparator deletes at least as much as P, on every instance

v4 checked deletion pooled across instances, while the endpoint is per instance. Round 4 (finding 2) built six instances in which:
- P deleted more on the five that showed the benefit;
- S deleted more on the sixth;
- pooled rejection was equal, and the whole look-1 decision passed.

The same mismatch made v4's safeguard claim false: a geometric mean of per-instance ratios can sit below 0.95 while pooled ratios are 1 (finding 5). So validity is now checked where the endpoint is.

**Definitions:**
- **r** = refused exact standard input tokens / offered exact standard input tokens, per instance, pooled over that instance's blocks.
- The tier of a request is **its tenant's tier in the frozen trace**, not a response header. A timed-out request receives no headers, so a header-derived tier would make every pre-header timeout a "missing tier" (round 4, finding 7).
- Where a response header carries a tier, it must equal the trace's, or the run refuses.
- "Refused" means the gateway answered with an admission refusal.

**Validity: r_S ≥ r_P on every contributing instance.**
- One violation makes the study's outcome "invalid".
- It is read after every instance, and a violation stops further purchase.

**Under it, each instance's contender completion ratios are at least 1 whenever admitted work completes:** (1 − r_P)/(1 − r_S) ≥ 1. So the safeguards' true per-instance values, and their geometric mean, are at least 1.

**The margin that makes per-instance validity attainable.** P and S replay the same arrivals within a block, so their rejections are correlated. How correlated is unknown, and pilot stage B measures it.
- **d** = r_S − r_P per block. In stage B (two blocks), its SD is estimated as the larger of the two blocks' |d − mean d| · √2 and 0.01.
- **The margin is m = 3 × SD / √3**, since an instance pools three blocks.
- **R is re-fitted at the start of stage B's analysis** so that `sim-cap` on stage A's three P traces gives r_S ≥ r_P + m on each.
  - This is the one re-fit, done before any main instance and pre-registered here.
- **Informative:** if m > 0.04, the design returns to review rather than run against a control crippled by its margin.
- r_S − r_P per instance is published beside every result.

**Fitting R, first in pilot stage A, which has no S arm:**
- `sim-cap` replays stage A's three P traces at each request's **recorded gateway arrival time** (build item 4).
- It uses threshold 1, burst 30,000 and the premium tenants named explicitly.
- R is the largest integer in 1…20,000 with r_S ≥ r_P + 0.01 on every trace.
- That R runs stage B, which then sets m and the final R.

**No interval is computed for r.** Admission outcomes share reservations and streams, so they are not independent trials. The rules are point rules on counts, and the counts are published.

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
- The Poisson generator populates it (build item 3).
- A completion with fewer engine-reported output tokens than its cap is a failure, not a completion.

## Endpoints and decision: one ratio per instance

**Per instance and arm:**
- The pooled premium TTFT p99 over that instance's completed blocks.
- Every premium failure (timeout, error, short completion, or unserved because a block ended early) counts at +∞.
- About 11,600 premium requests per arm over three blocks.

**Loss is judged on every launch, not only contributing ones.**
- If any arm of any launch has 1% or more premium loss in its reconstructed rows, the study's outcome is **invalid**.
- That includes a launch that completed no block.
- So no launch escapes the gate by failing early (round 4, finding 3), and every contributing instance's p99 is finite.

**Per instance:** y_i = ln(p99_P / p99_S); likewise ln(p99_P / p99_O) and the three safeguards' log ratios.

**Decision: a futility look, then one test.**
- **At 6 contributing instances:** if the mean of y is at or above ln 1.0 (P/S ≥ 1), stop with outcome "no demonstrated benefit". There is no early benefit verdict.
- **At 12 contributing instances, or when launches are exhausted with at least 6:** benefit if the one-sided 95% t upper bound of mean y is below ln 0.95.
- **Fewer than 6 contributing instances at exhaustion:** outcome "insufficient", with nothing judged.

**"Benefit" also requires, at the same test:**
- P/O's upper bound below ln 1.0;
- each safeguard (P against S, lower bound above ln 0.95):
  - contender completed exact input tokens;
  - contender completed requests;
  - premium completed requests.

**The assumption, stated rather than hidden.** The 5% error rate holds if the instance log-ratios are approximately normal. With 12 instances that cannot be checked.
- No method can do better with this few instances. A minority of about 10% of instances on which P is much worse would be missing from all 12 draws 0.9¹² = 28% of the time (round 4, finding 1's construction).
- So the claim is about the typical instance, and every instance's y is published so that a reader sees the spread rather than only the mean.

**Power of the primary at a true P/S of 0.80,** normal model, my simulation (20,000 studies per row, futility applied):

| σ of y across instances | Benefit |
|---:|---:|
| 0.10 | 100% |
| 0.15 | 98% |
| 0.20 | 88% |
| 0.30 | 59% |

**Error at a true P/S of 0.95:** 4.9% to 5.1% for σ from 0.05 to 0.30.

**Joint power.** Under validity the safeguards' true values are at least 1, so they cost little. P/O's cost depends on the true P/O, which only stage A suggests.

**Outcomes, named in advance:**
- invalid;
- insufficient;
- benefit;
- benefit that fails safeguards;
- no demonstrated benefit.

## Pilot, in two stages, neither in the main analysis

**Stage A: one instance, three blocks of I, O and P** (randomised order). It establishes:
- **contention:** O's pooled premium TTFT p99 ≥ 1.5 × I's;
- **loss:** every arm, P included, loses under 0.5% of premium requests, with O also completing ≥ 95% of contender requests;
- **engagement:** P refuses 5% to 30% of contender requests;
- **release timing:** in P, at least 95% of admitted contenders have 50 ms or less between the gateway's release instant (build item 6) and the first content byte;
- **restart:** an engine restart between arms reuses host-path weights and takes under 3 minutes.

Then it fits the first R.

**Stage B: one instance, two full four-arm blocks.** It establishes:
- **loss:** every arm under 0.5%;
- **validity:** r_S ≥ r_P on the instance;
- **the margin:** m, and the final R;
- the whole four-arm cycle at full duration on the GPU.

The loss gates cover P, which v4's did not: a P losing 2% passed both v4 pilots and guaranteed an invalid main study (round 4, finding 8).

**Every gate refuses the main purchase if unmet. None reads P against S's tail.**

## Evidence that survives an early end

**Raw rows are written incrementally,** one durable line per finished or failed request (build item 8). Today `cmd/benchharness` writes the file only after the whole replay returns.

**Reconstruction against the frozen block plan.** Every planned request either has a row or counts as a failure. An arm with no raw file counts every one of its premium requests as lost.

**The matrix's own early stops are early ends too.** It stops between arms on its time projection (`m5c-matrix.sh:2848`) and fails on a replay error (`:3331`). Each session's arms are budgeted so the projection cannot fire before the hard stop, and if it does, reconstruction applies.

**Spot interruptions are evidenced** (build item 9):
- the instance polls the metadata service's `spot/instance-action` and uploads a notice marker;
- the runner records the instance's `StateReason`.

A block cut short by an evidenced Spot interruption is dropped whole, and its launch's other blocks stand. Anything else drops nothing.

**Counting instances:**
- An instance **contributes** if it completed at least one block.
- The decision counts contributing instances.
- Main launches are capped at **14**, replacements included.

## What must be built before any purchase

1. **A new study, `prospective-admission`,** with its arms, a frozen manifest and readings. M5-b's study permits `kv-aware`, not `prospective` (`study.go:529`).
2. **The benchmark profile accepts `min_tokens` only when equal to `max_tokens`,** with a test that any other value is still refused.
3. **The Poisson generator populates `MinOutputTokens`.**
4. **The gateway records each request's arrival instant,** the raw rows carry it, and `sim-cap` replays it. Today it replays scheduled offsets (`simcap.go:74`).
5. **The engine-arguments validator compares the whole line with the registration,** mutation-tested key by key.
6. **The gateway records each request's release instant.**
7. **The matrix deploys admission per arm** (today admission is off, `m5c-matrix.sh:2187`), and step-log capture waits for the last **forwarded** request (`:3032`).
8. **Incremental raw rows, and reconstruction against the block plan.**
9. **The Spot interruption recorder.**
10. **The plugin records the scheduler-side priority.**
11. **The model cache on a host path,** in place of `emptyDir`.
12. **The credential check refuses when:**
    - it cannot establish an expiry;
    - sts cannot name the active role;
    - a cache entry carries only an account rather than the exact role path.
13. **Tier from the trace,** with a header mismatch refused.
14. **The analysis:** per-instance censored p99, per-instance validity, the futility look and the t test, the joint verdict, and every named outcome. It is tested on hand-built evidence including:
    - a censored instance;
    - a loss at exactly 1%;
    - a launch with zero completed blocks;
    - round 4's six-instance deletion example, which must come out "invalid";
    - fewer than 6 contributing instances.
15. **An independent termination deadline per instance.** Immediately after `RunInstances` returns, the runner creates an EventBridge Scheduler one-time schedule that calls `ec2:TerminateInstances` on that instance at its backstop plus 10 minutes. The pattern is `hack/lib/gpu-ttl.sh`, which today serves only EKS node groups. If the schedule cannot be created, the runner terminates the instance at once.
    - The in-instance backstop starts inside user-data, which ran 63 s after launch in one measurement, and the outside hard stop is a polling loop. Neither bounds an instance whose user-data never runs while the operator's process is gone (round 4, finding 4).
16. **The reserving spend ledger** (see Cost).
17. **Rehearsals on kind with the stub engine:**
    - a whole replay-to-verdict run;
    - r_S < r_P on one instance;
    - a header tier different from the trace's;
    - a pre-header timeout, which must not be a missing tier;
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

**Every session sets its own deadlines**, overriding the runner's defaults (16,800 s hard stop, 17,400 s backstop):

| Session | Expected hours | Hard stop | Backstop | Termination schedule |
|---|---:|---:|---:|---:|
| Pilot A, B | about 2.1 and 1.9 | 2 h 30 | 2 h 40 | 2 h 50 after launch |
| Main, each | about 2.75 | 3 h 30 | 3 h 40 | 3 h 50 after launch |

**The worst-case rate per instance-hour:**

| Component | $/h |
|---|---:|
| Spot cap | 1.10 |
| 200 GB gp3, at most $0.10 per GB-month over 730 h | 0.0274 |
| Public IPv4 | 0.005 |
| **Total** | **1.1324** |

**Worst case.** Every launch lives to its termination schedule: (2 × 170 + 14 × 230) min = 3,560 min = 59.33 h, × $1.1324 = **$67.19**. The pilot alone is at most **$6.42**.

**Expected,** at $0.65 plus the same volume and address (about $0.6824 per hour):
- about **$25** for the full 12 instances;
- about **$14** if the futility look stops at 6;
- about **$2.70** for the pilot alone.

The volume is deleted on termination (`spot-run.sh:166`).

**The ledger reserves before it records.**
- Each launch first appends its worst case (termination schedule × $1.1324) as a reservation.
- It refuses if the reservations and recorded sessions together would exceed **$70**.
- After the session it records launch and termination times from EC2 and CloudTrail. Those are times, not a bill.
- Billed amounts come from Cost Explorer when it settles, and are published beside the estimate.

## What v5 changed, against the review of v4

| v4 finding | Change |
|---|---|
| 1: the t error bound depends on normality | the assumption is stated in the claim; no early benefit stop; every instance's ratio published; the minority limit quantified |
| 2: pooled matching did not protect the per-instance endpoint | validity r_S ≥ r_P on every instance, with a margin from stage B |
| 3: a launch with no completed block escaped the loss gate | loss judged on every launch; outcome "insufficient" below 6 instances |
| 4: no lifetime bound | an independent EventBridge termination per instance; IPv4 and a gp3 upper bound costed; $70 |
| 5: the safeguard identity did not hold for geometric means | per-instance validity makes each instance's ratio at least 1 |
| 6: the validator checked a subset | whole-line comparison, mutation-tested key by key |
| 7: pre-header timeouts would read as missing tier | tier from the trace |
| 8: the pilots ignored P's loss | loss gates on every arm in both stages |
