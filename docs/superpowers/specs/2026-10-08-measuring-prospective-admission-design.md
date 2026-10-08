# Measuring prospective admission directly (item 3): the design, v6

*Drafted 2026-10-08 for the owner's approval before anything is built. The owner approved paid runs for this direction on 2026-10-08, and asked for the design to be attacked as hard as possible before money is spent. Nothing is bought until a registration built from this design is frozen.*

## History of this page

| Version | Commit | Answered | Review findings |
|---|---|---|---|
| v1 | dcc58b0 | proposed by codex `gpt-6-astra`, amended by me | — |
| v2 | 8154cbe | astra's review of v1 | 4 blockers, 10 majors |
| v3 | 29ed20b | astra's review of v2 | 5 blockers, 11 majors |
| v4 | 5daf5c7 | astra's review of v3 | 4 blockers, 6 majors, 1 minor |
| v5 | 9b67732 | astra's review of v4 | 4 blockers, 4 majors |
| v6 | this page | astra's review of v5 | 3 blockers, 5 majors |

**Who established what.**
- astra read the code and found the defects. Each round was given only the page and the repository, never told where to look.
- I re-read every line it cited before accepting a finding, and re-derived every figure on this page.
- astra independently re-derived:
  - v5's primary power table (500,000 studies per row), agreeing with mine within simulation error;
  - its error rate at the null boundary;
  - every cost figure.

  v6's new figures (the validity-survival table and the sweeper's worst case) are mine, and the next round is asked to re-derive them.
- **Prices:**
  - $1.10 is the runner's own Spot cap.
  - The public IPv4 charge of $0.005 per hour is AWS's published rate.
  - For gp3 storage I use $0.10 per GB-month as an upper bound, not a quoted Seoul price.

## The question

> Does **prospective** admission protect the premium TTFT tail better than pressure-blind shedding **that rejects at least as much contender work on the same instance**, on an engine whose priority is bound to the tenant's tier and whose batch budget is fixed in advance?

**The claim is narrow:**
- relative TTFT-tail protection against a static control that deletes at least as much, which in this design is about four points more;
- for clients that do not retry;
- on vLLM with synchronous scheduling;
- for the population of instances the study sampled, under the assumptions stated under Decision.

Premium TPOT, P/I, and every instance's own ratios and deletion difference are published beside it.

## Arms

Same instance and same trace within a block, with the arm order randomised per block (see Sampling).

| Arm | Gateway admission | Role |
|---|---|---|
| I, isolation | off; premium requests only | premium-only reference, published, not gated |
| O, unshed | off | proof the contention exists; P/O is a secondary endpoint |
| S, static | `static-cap`, long threshold 1, burst 30,000 estimated units, rate R | pressure-blind shedding that deletes at least as much as P on every instance |
| P, prospective | `prospective`, 30,000 estimated units (about 23,000 exact tokens, three contenders) and 4 streams | the arm under test |

**Gateway, every arm:**
- `--bind-priority --enforce-benchmark-profile`, and the harness sends no priority.
- The benchmark profile accepts `min_tokens` equal to `max_tokens` and nothing else (build item 2).

## Engine, every arm, proved rather than asserted

**The frozen apparatus.**
- Qwen2.5-3B-Instruct at revision `aa8e7253…`, half precision.
- max-model-len 16,384; 64 sequences; memory 0.90; prefix caching off.
- Chunked prefill with budget **512**.
- `--scheduling-policy=priority`.
- The image pinned by digest.
- The step-logging scheduler plugin, with `--no-async-scheduling`.

**Proof, read at every engine start.**
- The whole non-default-arguments line is compared with the registration (build item 5):
  - every registered key must appear with its registered value;
  - any unregistered non-default key refuses the engine;
  - the check is mutation-tested with the specimen astra passed through today's validator (prefix caching on, bfloat16, one sequence, context 8,192, memory 0.5).
- The plugin records the priority each request reached the scheduler with. Every premium request must show 0 and every standard one 1.

## The gateway's own decision record

**Every admission fact comes from the gateway, keyed by request ID** (build item 4). The gateway already assigns and echoes `X-Request-Id` (`internal/gateway/server.go:338`).

Per request, it writes one line with:
- arrival instant;
- tenant and tier;
- decision (admitted, or refused with reason);
- release instant.

**Why.** A response that never arrives carries no headers. So a header-based record cannot tell a lost refusal from an admitted request that failed, and `report.go:112` already marks such rows "admission unknown".
- Round 5 (finding 1) showed this lets validity pass while P refuses more: 14 lost refusals look like 14 transport errors.
- With the gateway's record, a contender's decision is known whether or not its response arrived.

**If a request has no gateway record,** validity is judged conservatively:
- it counts as **refused** in P's r;
- it counts as **not refused** in S's r.

The gateway's lines are uploaded with the rows (see Evidence).

**Admitted work must complete.** In every arm on every instance, at least 99% of admitted contenders must complete with their full output, or the outcome is "invalid". This enforces the condition the safeguard argument rests on, which v5 only assumed (finding 1).

## The comparator deletes at least as much as P, on every instance

**Definitions:**
- **r** = refused exact standard input tokens / offered exact standard input tokens, per instance, over its three blocks, from the gateway's record.
- A request's tier is its tenant's tier in the frozen trace. The gateway's record must agree, or the run refuses.

**Validity: r_S ≥ r_P on every contributing instance.**
- One violation makes the outcome "invalid".
- It is read after each instance, and a violation stops further purchase.

**The margin is fixed in advance at m = 0.04.** R is fitted so that S rejects about four points more than P. v5 estimated the margin from one degree of freedom, which round 5 (finding 4) showed gives all 12 instances valid only about 63% of the time at a block SD of 0.02.

With per-instance difference d ~ N(m, s/√3) over three blocks, the probability that all 12 instances are valid:

| Block SD of r_S − r_P | m = 0.03 | **m = 0.04** | m = 0.05 |
|---:|---:|---:|---:|
| 0.01 | 100% | 100% | 100% |
| 0.02 | 94.5% | **99.7%** | 100% |
| 0.03 | 60.0% | **88.1%** | 97.7% |
| 0.04 | 29.4% | **60.0%** | 83.2% |

**Stage B checks the assumption rather than estimating from it.** If its two blocks' |d₁ − d₂| exceeds 0.06, which is about two SDs of a difference at block SD 0.03, the design returns to review.

**Only full instances contribute.** An instance contributes only if it completed all three blocks, so the margin always stands on three blocks. An instance cut short by an evidenced Spot interruption contributes nothing and is replaced (see Evidence). v5 let one-block instances contribute at a standardised margin of √3 (finding 4).

**Fitting R.**
- In stage A, `sim-cap` replays the three P traces at the gateway's recorded arrival instants, with threshold 1, burst 30,000 and the premium tenants named.
- R is the largest integer in 1…20,000 with r_S ≥ r_P + 0.04 on every trace.
- That R is final. Stage B checks it, and is never used to re-fit it.

**Informative bound.** If stage B's mean r_S − r_P exceeds 0.08, the design returns to review rather than run against a crippled control.

**No interval is computed for r.** The rules are point rules on counts, and the counts are published.

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

**Output is fixed.** The Poisson generator populates `MinOutputTokens` (build item 3), and a completion with fewer engine-reported output tokens than its cap is a failure.

## Sampling

**Instances are independent launches**, each a separate Spot request. Shared hardware generation, image and region could still correlate them. Round 5 (finding 7) showed that an intra-class correlation of 0.1 raises the error to 13% even when each y is exactly normal. That correlation cannot be tested with 12 instances, so it is stated as an assumption (see Decision).

**Seeds are fixed before any purchase.**
- The registration freezes a list of distinct trace seeds: one per block, in launch order, for 14 launches × 3 blocks, plus the pilot's.
- Replacements take the next unused triple.
- Today's seed check is per invocation only (`m5c-matrix.sh:520`), so a study-wide uniqueness check is build item 7.

**Arm order.** Each block's arm order is a permutation drawn from a hash of the registration's seed, the launch index and the block index. Today the generic matrix runs a fixed order (`m5c-matrix.sh:822`).

## Endpoints and decision: one ratio per instance

**Per instance and arm:**
- The pooled premium TTFT p99 over the instance's three blocks.
- Every premium failure (timeout, error, short completion, or unserved because the launch ended early) counts at +∞.
- About 11,600 premium requests per arm.

**y_i** = ln(p99_P / p99_S); likewise ln(p99_P / p99_O).

**Per-instance gates.** Each is a point rule; any failure makes the outcome "invalid":
- premium loss under 1% in every arm;
- r_S ≥ r_P;
- at least 99% of admitted contenders completed in every arm.

These replace v5's three t-bounded safeguards. Under these gates, P never deletes more contender work than S on any instance, and the admitted work completes, which is what the safeguards were meant to establish.
- A t-bound on ratios that are each at least 1 could still fail on one extreme instance: 11 at 1.0 and one at 3.0 gives a lower bound of 0.93 (round 5, finding 6).
- So the bounds cost power while guarding nothing the gates leave open.
- P against S contender completion is still published.

**Decision: a futility look, then one test.**
- **At 6 contributing instances:** if the mean of y is at or above ln 1.0, stop with outcome "no demonstrated benefit".
- **At 12 contributing instances:** benefit if the one-sided 95% t upper bound of mean y is below ln 0.95, and the one-sided 95% t upper bound of mean ln(P/O) is below 0.
- **Launches exhausted (14) with fewer than 12 contributing:** the test runs on what exists if there are at least 6; with fewer, the outcome is "insufficient".

**Precedence:** invalid, then insufficient, then the decision. So identical evidence gives one verdict.

**Assumptions, stated in the claim.** The 5% error rate holds if the instance log-ratios are approximately normal **and** independent. Neither can be checked with 12 instances.
- A minority of about 10% of instances on which P is much worse is missed by all 12 draws 0.9¹² = 28% of the time.
- A shared component with correlation 0.1 raises the error to 13%.
- So the claim is about the typical instance, and every instance's y is published.

**Power at a true P/S of 0.80,** normal and independent, primary alone, futility applied.

| σ of y | Mine (20,000 per row) | astra's (500,000 per row) |
|---:|---:|---:|
| 0.10 | 100% | 99.997% |
| 0.15 | 98% | 98.06% |
| 0.20 | 88% | 87.33% |
| 0.30 | 59% | 58.50% |

**Error at a true P/S of 0.95:** 4.9% to 5.1% (mine) and 4.95% (astra's).

**Joint feasibility, multiplied rather than modelled:**
- the primary, from the table;
- the validity survival, from the margin table (88% at block SD 0.03);
- P/O, which stage A screens (see Pilot).

At σ = 0.20 and block SD 0.03, the study reaches a benefit verdict about 0.88 × 0.88 ≈ 77% of the time when P/S is truly 0.80, before P/O. The product treats the two as independent, which they need not be, so it is an approximation.

**Outcomes, named in advance:**
- invalid;
- insufficient;
- benefit;
- no demonstrated benefit.

v5's "benefit that fails safeguards" is gone with the t-bounded safeguards: a safeguard failure is now "invalid".

## Pilot, in two stages, neither in the main analysis

**Stage A: one instance, three blocks of I, O and P** (randomised order). It establishes:
- **contention:** O's pooled premium TTFT p99 ≥ 1.5 × I's;
- **loss:** every arm, P included, under 0.5% premium loss, and O completes ≥ 95% of contender requests;
- **admitted contender completion:** in P, at least 99%;
- **engagement:** P refuses 5% to 30% of contender requests;
- **P/O:** P's pooled premium p99 is at most 0.85 × O's, so that P/O's gate is not hopeless;
- **release timing:** in P, at least 95% of admitted contenders have 50 ms or less between the gateway's release instant and the first content byte;
- **restart:** an engine restart between arms reuses host-path weights and takes under 3 minutes.

The P/O screen reads P against O, never against S.

Then stage A fits R.

**Stage B: one instance, two full four-arm blocks** with R final. It establishes:
- every arm's loss under 0.5%;
- admitted contender completion of at least 99% in S and P;
- validity, r_S ≥ r_P;
- the spread check |d₁ − d₂| ≤ 0.06 and the informative bound;
- the whole four-arm cycle at full duration on the GPU.

**Every gate refuses the main purchase if unmet. None reads P against S's tail.**

## Evidence that survives an early end

**Rows leave the instance as they are written** (build item 8).
- The harness appends one durable line per finished or failed request.
- A sidecar uploads the raw file and the gateway's decision record to S3 every 30 s during each replay.
- On a Spot notice, it flushes immediately: the two-minute warning is far longer than one upload.

Today the hook uploads only after a replay and its log capture (`m5c-matrix.sh:3387`), and the volume is deleted on termination. So a dying instance could lose an almost-complete replay (round 5, finding 8).

**Reconstruction against the frozen block plan.** Every planned request either has an uploaded row or counts as a failure.

**Spot interruptions are evidenced** (build item 9):
- the instance polls the metadata service's `spot/instance-action` and uploads a notice marker;
- the runner records the instance's `StateReason`.

**Which population each rule judges** (round 5, finding 3):

| Launch ended by | Its completed blocks | Its in-progress and unstarted blocks | The loss gate |
|---|---|---|---|
| Completion | all three, contributing | none | applies |
| An evidenced Spot interruption | not contributing (instance incomplete) | dropped | does not apply: the launch contributes nothing and is replaced |
| Anything else (engine, gateway, harness, runner, a deadline) | judged | reconstructed as failures | applies to all of them, and almost always gives "invalid" |

A non-Spot early end making the study invalid is deliberate. Such an end may depend on the arm, and dropping it would select by outcome.

**The matrix's projection stop is disabled for this study** (build item 10). Its projection includes the cold first cell and multiplies by 1.2, so it would refuse all three session shapes after their first cell (`m5c-matrix.sh:2795`, `:2833`, `:2848`; round 5, finding 5). The session's cell count is fixed by the registration. Its deadlines are sized from that count, and the hard stop and the sweeper are what bound time.

**Main launches are capped at 14**, replacements included.

## What must be built before any purchase

1. **A new study, `prospective-admission`,** with its arms, a frozen manifest and readings (`study.go:529` permits `kv-aware` only).
2. **The benchmark profile accepts `min_tokens` only when equal to `max_tokens`,** with a test that any other value is still refused.
3. **The Poisson generator populates `MinOutputTokens`.**
4. **The gateway's per-request decision record** (arrival, tenant, tier, decision, release) by request ID, and `sim-cap` replaying its arrival instants.
5. **The engine-arguments validator compares the whole line,** mutation-tested key by key.
6. **The matrix deploys admission per arm** (`m5c-matrix.sh:2187`), and step-log capture waits for the last forwarded request (`:3032`).
7. **Study-wide seed uniqueness and hashed arm order.**
8. **Incremental rows, the 30-second evidence sidecar with a Spot-notice flush, and reconstruction.**
9. **The Spot interruption recorder.**
10. **The projection stop disabled for this study,** with a test that a cold first cell does not stop a session.
11. **The plugin records the scheduler-side priority.**
12. **The model cache on a host path,** in place of `emptyDir`.
13. **The credential check refuses when:**
    - it cannot establish an expiry;
    - sts cannot name the active role;
    - a cache entry carries only an account rather than the exact role path.
14. **Tier from the trace,** with a mismatch against the gateway's record refused.
15. **The analysis:** per-instance censored p99, the per-instance gates, the futility look and the t test, precedence and every named outcome. It is tested on hand-built evidence including:
    - round 4's six-instance deletion example, which must be "invalid";
    - round 5's lost-refusal example, which must be "invalid" under the conservative rule;
    - a censored instance;
    - a loss at exactly 1%;
    - a Spot-interrupted launch;
    - a non-Spot launch with zero completed blocks;
    - fewer than 6 contributing instances.
16. **A termination sweeper that exists before any launch** (see Cost).
17. **The reserving spend ledger.**
18. **Rehearsals on kind with the stub engine:**
    - a whole replay-to-verdict run;
    - r_S < r_P on one instance;
    - a lost refusal;
    - a pre-header timeout;
    - a header tier different from the trace's;
    - a censored tail;
    - a short completion;
    - a refused final contender;
    - the harness killed mid-replay, with the sidecar's uploads checked against the local file;
    - a full-length session of each shape (8, 9 and 12 cells), with engine restarts and log capture, so the projection stop and the deadlines are exercised at their real durations.

## Credential windows

The AWS SSO session lasts at most 12 hours from a login.
- Each session is one instance.
- The owner logs in immediately before each login's first session.
- No launch proceeds unless the expiry, established under build item 13, exceeds the session's termination deadline plus 30 minutes.

## Cost

**The termination sweeper, which exists before launch** (build item 16).
- v5 created a termination schedule after `RunInstances` returned. If AWS accepted the launch but its answer was lost and the operator's process then died, no schedule would exist. That failure is already modelled in the lifecycle goldens (`launch-accepted-but-answer-lost`; round 5, finding 2).
- **So the deadline travels with the launch.**
  - `RunInstances` carries a `study-deadline` tag, set in the same call's tag specifications, so it exists the moment the instance does.
  - A Lambda in `infra/aws/bootstrap`, run by EventBridge every 5 minutes, terminates any instance whose `study-deadline` has passed.
  - Its role is granted `ec2:TerminateInstances` on instances carrying that tag, and nothing else. Today's scheduler role grants only `eks:UpdateNodegroupConfig` (`ttl.tf:48`).
- **The sweeper is exercised before the study.** A t3.nano is launched with a past deadline, and the run checks that it was terminated within 10 minutes.
- **This changes the account's infrastructure** with a `terraform apply` in the bootstrap stack, and needs the owner's approval as its own step.

**Deadlines:**

| Session | Expected hours | Hard stop | Backstop | `study-deadline` after launch |
|---|---:|---:|---:|---:|
| Pilot A, B | about 2.1 and 1.9 | 2 h 30 | 2 h 40 | 2 h 50 |
| Main, each | about 2.75 | 3 h 30 | 3 h 40 | 3 h 50 |

**The worst-case lifetime** is the deadline plus one sweep interval plus EventBridge's one-minute precision: 176 minutes for a pilot session, 236 for a main one.

**The worst-case rate per instance-hour:**

| Component | $/h |
|---|---:|
| Spot cap | 1.10 |
| 200 GB gp3, at most $0.10 per GB-month over 730 h | 0.0274 |
| Public IPv4 | 0.005 |
| **Total** | **1.1324** |

**Worst case:** (2 × 176 + 14 × 236) min = 60.93 h, × $1.1324 = **$69.00**. The pilot alone is at most **$6.64**.
- This is conditional on the sweeper working, and the exercise above is the evidence it does.
- If the sweeper's own invocation fails, the in-instance backstop and the operator's hard stop remain.
- None of the three is a guarantee alone.

**Expected,** at about $0.6824 per hour (Spot about $0.65, plus the volume and address):
- about **$25** for 12 instances;
- about **$14** if the futility look stops at 6;
- about **$2.73** for the pilot alone.

**The ledger reserves before it records.**
- Each launch first appends its worst case (lifetime × $1.1324) as a reservation.
- It refuses if the reservations and recorded sessions together would exceed **$75**.
- After the session it records launch and termination times from EC2 and CloudTrail.
- Billed amounts come from Cost Explorer when it settles, and are published beside the estimate.

## What v6 changed, against the review of v5

| v5 finding | Change |
|---|---|
| 1: lost refusals can pass validity; admitted completion assumed | the gateway's own decision record; a conservative rule for missing records; a 99% admitted-completion gate |
| 2: the termination schedule existed only after launch | a tag-carried deadline and a pre-existing sweeper, with its own role and an exercise |
| 3: Spot drop against the all-launch loss gate | a population table per end type; Spot-interrupted launches contribute nothing and are replaced; precedence fixed |
| 4: a margin from one degree of freedom; partial instances | a fixed margin of 0.04 with a published survival table; a stage-B spread check; only full instances contribute |
| 5: the projection stop fires after the first cell | disabled for this study; full-length rehearsals of each session shape |
| 6: t-bounded safeguards could fail with every ratio ≥ 1 | replaced by per-instance point gates |
| 7: independence unspecified | stated as an assumption with its consequence; frozen study-wide seeds; hashed arm order |
| 8: local rows die with the volume | a 30-second evidence sidecar with a Spot-notice flush |
