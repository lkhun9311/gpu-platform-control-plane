# Measuring prospective admission directly (item 3): the design, v3

*Drafted 2026-10-08 for the owner's approval before anything is built. The owner approved paid runs for this direction on 2026-10-08, and asked for the design to be attacked as hard as possible before money is spent. Nothing is bought until a registration built from this design is frozen.*

## History of this page

- **v1** (dcc58b0): proposed by codex `gpt-6-astra` (independent design), amended by me.
- **v2** (8154cbe): answered astra's first adversarial review (4 blockers, 10 majors).
- **v3** (this page): answers astra's second review of v2 (5 blockers, 11 majors), every code claim of which I re-read and found to hold. Two of its findings I had reached independently before it returned:
  - contender input is 75.9% of all tokens, so v2's aggregate gate at 0.95 allowed P to shed at most 6.6% of contender work;
  - two pilot instances give one degree of freedom for the between-instance variance.

**What the two rounds established, and by whom.**
- astra read the code and found the defects.
- I re-derived the arithmetic and re-read every cited line:
  - `cmd/benchharness/simcap.go:74` uses scheduled offsets;
  - `internal/bench/report.go:594` drops premium timeouts;
  - `internal/bench/estimand.go:309` resamples blocks;
  - `hack/lib/instrument-validation.sh` checks only the revision among the frozen engine settings;
  - `hack/m5c-matrix.sh:3032` waits for the last offered request;
  - `hack/m5c-gpu-session.sh` trusts every cache entry when sts names no role;
  - `config/vllm/deployment.yaml` mounts the model cache as `emptyDir` with budget 2,048.
- astra also reported running the process-arguments validator with `fcfs` and budget 2,048 and getting success. I did not rerun it, but I read that the validator has no check for either key.

## The question

> Does **prospective** admission protect the premium TTFT tail better than pressure-blind shedding **that rejects the same contender work**, on an engine whose priority is bound to the tenant's tier and whose batch budget is fixed in advance?

**The claim is narrow:**
- relative TTFT-tail protection against a matched static control;
- for clients that do not retry;
- on vLLM with synchronous scheduling (see Engine).

Premium TPOT and P/I are published beside it, so poor absolute service cannot hide behind a relative win.

## Arms

Same instance and same trace within a block, with the arm order randomised per block.

| Arm | Gateway admission | Role |
|---|---|---|
| I, isolation | off; premium requests only | premium-only reference, published, not gated |
| O, unshed | off | proof the contention exists; P/O is a secondary endpoint |
| S, static | `static-cap`, long threshold 1, burst 30,000 estimated units, rate R | pressure-blind shedding, matched to P |
| P, prospective | `prospective`, 30,000 estimated units (about 23,000 exact tokens, three contenders) and 4 streams | the arm under test |

**Gateway, every arm:** `--bind-priority --enforce-benchmark-profile`, and the harness sends no priority.

## Engine, every arm, proved rather than asserted

**The frozen apparatus.**
- Qwen2.5-3B-Instruct at revision `aa8e7253…`, half precision.
- max-model-len 16,384; 64 sequences; memory 0.90; prefix caching off.
- Chunked prefill with budget **512**.
- `--scheduling-policy=priority`.
- The image pinned by digest.
- The step-logging scheduler plugin, with `--no-async-scheduling`.

**Synchronous scheduling is part of the apparatus, in every arm.** The plugin subclasses the synchronous scheduler, so it cannot run under async scheduling. Every arm shares the setting. Whether vLLM v0.27.1 would choose async for this model by default is not established here, so the claim says synchronous.

**Proof, read at every engine start:**
- The engine's non-default-arguments line shows the policy, the budget, the revision and the async setting. The existing validator checks only the revision, so it is extended (build item 4).
- The plugin records the priority each request reached the scheduler with. Every premium request must show 0 and every standard one 1.

## Matching S to P

**The quantity is the rejected fraction, compared absolutely.** v2 compared admitted fractions relatively. Under that rule, P rejecting 5% and S 0.5% still passed: 4.7% relative. So v3 matches on the rejected fraction instead:
- r = refused exact standard input tokens / offered exact standard input tokens, pooled over the requests concerned;
- standard requests are identified by tenant;
- a row with no tier refuses the run rather than counting as standard;
- "refused" means the gateway answered with an admission refusal;
- a request the gateway forwarded is admitted, even if it later timed out.

**Fitting R happens in pilot stage A, which has no S arm** (see Pilot).
- `sim-cap` replays stage A's three P traces at each request's **recorded gateway arrival time**. Recording that time and teaching `sim-cap` to read it is build item 3.
- It uses threshold 1, burst 30,000, and the premium tenants named explicitly.
- R is the integer in 1…20,000 minimising |r_S − r_P|, ties to the lower R.
- R is committed before stage B begins.

**Validity, read on every set of blocks** (stage B, after the first main session, and at the end), pooled:
- r_P − r_S ≤ **0.01**, so P may reject at most one percentage point more contender work than S;
- |r_P − r_S| ≤ 0.02.

If either fails in stage B, nothing is bought: the design returns to review, and R is never re-tuned on main data. If either fails after the first main session, no further session is bought, and the study's outcome is "invalid".

**Deliberately no confidence interval for r.** Admission outcomes share reservations and streams, so they are not independent trials, and a binomial interval would have unknown coverage (review finding 16). The gate is a pre-registered point rule on pooled counts, and the counts are published.

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

**Output is fixed, so it cannot be deleted silently.** `MinOutputTokens` equals the cap for both tenants, and the field already exists. A clean completion therefore has exactly its cap in engine-reported output tokens. Any shorter completion is counted as a failure, not a completion.

v2's aggregate-token safeguard let premium output fall by 37.5% and still pass (review finding 7). Fixed output removes that freedom instead of trying to detect it.

## Endpoints, decision and power

**Censoring, with no request or repetition dropped.**
- In the summary, a premium request that timed out, failed, or completed short counts at +∞ in its arm's pooled TTFT p99, even if its first content arrived.
- So selective loss can only make an arm look worse.
- No repetition is removed for loss: a dropped repetition would be selection by outcome.
- If any arm's pooled premium loss reaches 1%, the study's outcome is "invalid".

The existing summary drops timeouts (`report.go:594`), so this is build item 5.

**Primary: P/S**, the ratio of pooled premium TTFT p99. Success requires its one-sided 95% upper bound below **0.95**.

**Secondary, also required:** P/O's upper bound below 1.0.

**Safeguards, P against S,** each a one-sided 95% lower bound, and each true at about 1.0 when the match holds:
- contender completed exact input tokens, P/S ≥ 0.95;
- contender completed requests, P/S ≥ 0.95;
- premium completed requests, P/S ≥ 0.99.

**Why S and not O.** v2 compared against O, which forbade the shedding both arms are built to do. As review finding 1 showed, that made 80% joint power impossible at any size, since a safeguard whose true value is 0.90 cannot clear a 0.95 bound. Deletion relative to O is published, not gated, because it is the treatment's own definition.

**Interval.**
- The bootstrap resamples **instances**, with blocks nested inside.
- It recomputes each arm's pooled request-level p99 on every replicate, never a function of block ratios: per-block ratios do not determine the pooled ratio (review finding 3's counter-example).
- It is build item 6; `estimand.go` today resamples blocks.

**Sizing the main purchase, by an executable rule:**
1. **Between-instance SD.** σ_b is the larger of:
   - the pilot's estimate, which has one degree of freedom;
   - the between-instance SD of the premium TTFT p99 log-ratio in the archived multi-instance M5 sessions, each source named in the registration.

   If no archived session qualifies, σ_b is twice the pilot's estimate. Whether one qualifies is not yet checked. Using the pilot alone would size the purchase on one contrast.
2. **Synthetic studies.** For each of 2,000, build each simulated instance i with u_i ~ N(0, σ_b), and each of its three blocks as follows:
   - draw pilot stage-B blocks k and k′ independently;
   - S is block k's S request rows;
   - O is block k's O request rows;
   - P is block k′'s S request rows, with every TTFT multiplied by 0.80 · exp(u_i).

   The work safeguards are drawn from the stage-B blocks' own P and S completion counts. Every synthetic study is then judged by the registered estimator and rules.
3. **Power** is the fraction of synthetic studies that reach "benefit" (the joint verdict).
   - Buy the smallest number of instances, at least 8, with power at least 80%.
   - Report power at 2σ_b beside it.
   - If more than 12 instances are needed, do not buy, and report the study as unaffordable.

**Outcomes, named in advance:**
- invalid;
- benefit;
- benefit that fails safeguards;
- no demonstrated benefit.

## Pilot, in two stages, neither included in the main analysis

**Stage A: one instance, three blocks of I, O and P** (randomised order, no S, since R does not yet exist). It establishes:
- **contention:** O's pooled premium TTFT p99 ≥ 1.5 × I's;
- **no overload:** O completes ≥ 99% of premium and ≥ 95% of contender requests;
- **engagement:** P refuses at least 5% of contender requests;
- **release timing:** in P, at least 95% of admitted contenders have a gap of 50 ms or less between the gateway's release instant and the first content byte;
- **restart:** an engine restart between arms reuses host-path weights and takes under 3 minutes.

Recording the release instant is build item 7. The existing first-byte stamp includes the headers, and the release callback records no time. The release timing must hold per contender, not as a pooled median: v2's pooled median could pass with every contender violating it, since contenders are 5% of requests. Stage A then fits R.

**Stage B: a second instance, two full four-arm blocks** with R frozen. It establishes:
- the match validity rule;
- the request rows the power simulation resamples;
- a second instance for σ_b.

**Every gate in both stages refuses the main purchase if unmet. None reads P against S's tail.**

## What must be built before any purchase

1. **A new study, `prospective-admission`,** with its arms, a frozen manifest and readings. Today M5-b's study permits `kv-aware`, not `prospective` (`study.go:529`), and unknown studies are refused.
2. **The matrix deploys admission per arm.** Today it deploys admission off (`m5c-matrix.sh:2187`).
3. **The gateway records each request's arrival instant,** the raw rows carry it, and `sim-cap` replays it.
4. **The process-arguments validator checks the policy, the budget and the async setting for this study,** and is mutation-tested with `fcfs` and budget 2,048.
5. **A censoring-aware summary,** as above, beside the existing one, which stays for the studies it has already judged.
6. **The instance-clustered pooled bootstrap,** tested with review finding 3's counter-example.
7. **The gateway records the release instant per request.**
8. **Step-log capture waits for the last forwarded request,** not the last offered one. Today a correctly refused final contender would make capture refuse a good arm (`m5c-matrix.sh:3032`).
9. **The plugin records the scheduler-side priority.**
10. **The model cache moves to a host path,** for this study's engine, in place of `emptyDir`.
11. **The credential check refuses when:**
    - it cannot establish an expiry;
    - sts cannot name the active role;
    - a cache entry carries only an account, rather than the exact role path.

    Today the first two warn and proceed, and the third borrows another role's expiry.
12. **A study-wide spend ledger** that each launch reads, described under Cost.
13. **The power simulation,** running the registered estimator end to end.
14. **Rehearsals on kind with the stub engine:**
    - a whole replay-to-verdict run;
    - a deliberate r mismatch;
    - a missing tier;
    - a censored tail;
    - a short completion;
    - a refused final contender;
    - an interrupted upload;
    - a full-duration arm cycle with engine restart and log capture.

## Interruptions

**A Spot interruption** is evidenced by the interruption notice the runner records.
- The interrupted block is dropped whole.
- The instance keeps its completed blocks, and an instance with fewer than three still counts as one cluster.
- A replacement instance takes the next pre-registered seeds, and counts toward the 12-instance cap and the spend ceiling.

**Anything else that ends a block early** (engine failure, gateway failure, a runner fault) does not drop it.
- Its requests not served count as failures, and censoring applies.
- If that makes an arm's loss reach 1%, the outcome is "invalid".

Dropping such blocks would remove exactly the blocks where an arm behaves badly (review finding 15).

## Credential windows

The AWS SSO session lasts at most 12 hours from a login.
- Each session is one instance.
- The owner logs in immediately before each login's first session.
- No launch proceeds unless the credential expiry, established under build item 11, exceeds the session's hard stop plus 30 minutes.

## Cost

**Durations,** from v1's measurement of about 15 minutes of bring-up and about 50 minutes per four-arm block:

| Session | Hours | Expected at about $0.65/h | Worst case: hard stop × $1.10 cap |
|---|---:|---:|---:|
| Pilot A: 3 blocks of 3 arms | about 2.1 | about $1.40 | 2.5 h → $2.75 |
| Pilot B: 2 blocks | about 1.9 | about $1.25 | 2.5 h → $2.75 |
| Main, each: 3 blocks | about 2.75 | about $1.80 | 3.5 h → $3.85 |

**Totals:**
- Expected, at 8 to 12 main instances: about $17 to $24.
- Worst case, at 12 main instances plus two replacements at every session's hard stop: $5.50 + 14 × $3.85 = **$59.40**.

**The ledger enforces the ceiling.** It records each finished session's billed hours from CloudTrail. Every launch refuses if the ledger's total plus that launch's worst case would exceed the frozen ceiling of **$60**. The runner's per-session $1.10 cap and hard stop stay as they are, and the ledger is what connects them to the study.

**The pilot alone is about $2.65 expected and at most $5.50.** It can stop the study before any main purchase.

## What v3 changed, against the review of v2

| v2 finding | Change |
|---|---|
| 1: safeguards at 0.90 against 0.95 bounds | safeguards compare P to S, true at about 1.0 under the match |
| 2: S has no rate during the pilot | two-stage pilot: R fitted in stage A, frozen before stage B |
| 3: the power simulation was not executable; ratios ≠ pooled ratio | request-level synthetic studies through the registered estimator; σ_b from archives when larger |
| 4: no recorded gateway arrival | build item 3 |
| 5: the build list was missing | restored and extended, items 1–14 |
| 6: the validator ignores policy and budget | build item 4, mutation-tested |
| 7: output deletion passed | output fixed at the cap; short completions are failures |
| 8: the aggregate gate demanded 93.4% retention | removed |
| 9: relative match let P reject ten times more | absolute rejected-fraction match, P at most 1 point more |
| 10: async scheduling unfrozen | synchronous in every arm, registered, and in the claim |
| 11: capture expects the last offered request | build item 8 |
| 12: the release-timing median, and no timestamp | per-contender 95% rule; build item 7 |
| 13: `emptyDir` | build item 10 |
| 14: the credential identity hole | build item 11 |
| 15: interruptions and budget | Spot-only drop; everything else censored; ledger with $60 ceiling |
| 16: binomial interval | removed; a point rule on published counts |
