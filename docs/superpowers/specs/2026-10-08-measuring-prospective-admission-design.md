# Measuring prospective admission directly (item 3): the design, v11

*Drafted 2026-10-08 for the owner's approval before anything is built. The owner approved paid runs for this direction on 2026-10-08, and asked for the design to be attacked as hard as possible before money is spent. Nothing is bought until a registration built from this design is frozen.*

## History of this page

| Version | Commit | Answered | Review findings |
|---|---|---|---|
| v1 | dcc58b0 | proposed by codex `gpt-6-astra`, amended by me | — |
| v2 | 8154cbe | astra's review of v1 | 4 blockers, 10 majors |
| v3 | 29ed20b | astra's review of v2 | 5 blockers, 11 majors |
| v4 | 5daf5c7 | astra's review of v3 | 4 blockers, 6 majors, 1 minor |
| v5 | 9b67732 | astra's review of v4 | 4 blockers, 4 majors |
| v6 | 412ba53 | astra's review of v5 | 3 blockers, 5 majors |
| v7 | 18a9b48 | astra's review of v6 | 2 blockers, 6 majors |
| v8 | 9a8c358 | astra's review of v7 | 2 blockers, 5 majors |
| v9 | 192aa03 | astra's review of v8 | 2 blockers, 4 majors, 1 minor |
| v10 | c397e48 | astra's review of v9 | 2 blockers, 3 majors |
| v11 | this page | astra's review of v10 | 1 blocker, 2 majors |

**Who established what.**
- astra read the code and found the defects. Each round was given only the page and the repository, never told where to look.
- I re-read every line it cited before accepting a finding, and re-derived every figure on this page.
- astra independently re-derived, and agreed with:
  - the primary power table twice (500,000 studies per row);
  - the error rate at the null boundary;
  - v6's validity-survival table;
  - every cost figure.

  Round 7 also re-derived v7's survival table and 15-minute allowance. Its objection was to what the survival table meant, not to its arithmetic. Round 8 re-derived the power table (1,000,000 studies per row), the money-at-risk table and every cost figure, and agreed with each. Its findings were about meaning and evidence, not arithmetic.
- **Prices:**
  - $1.10 is the runner's own Spot cap.
  - The public IPv4 charge of $0.005 per hour is AWS's published rate.
  - For gp3 storage I use $0.10 per GB-month as an upper bound, not a quoted Seoul price.

## The question

> Does **prospective** admission protect the premium TTFT tail better than pressure-blind shedding **that completes no more contender work on the same instance**, on an engine whose priority is bound to the tenant's tier and whose batch budget is fixed in advance?

**The claim is narrow:**
- relative TTFT-tail protection against a static control that **completes no more contender work** on any instance, and by design deletes about five points more;
- for clients that do not retry;
- on vLLM with synchronous scheduling;
- for the population of instances the study sampled, under the assumptions stated under Decision.

Premium TPOT, P/I, and every instance's own ratios and deletion difference are published beside it.

**TPOT is defined on engine tokens** (build item 19): (last content frame − first content frame) / (engine-reported output tokens − 1). Today's TPOT has two defects (round 7, finding 7):
- it divides by the count of content frames, so 64 tokens arriving in 32 frames read 2.03 times too slow;
- it ends at stream termination, not at the last content frame.

## Arms

Same instance and same trace within a block, with the arm order randomised per block (see Sampling).

| Arm | Gateway admission | Role |
|---|---|---|
| I, isolation | off; premium requests only | premium-only reference, published, not gated |
| O, unshed | off | proof the contention exists; P/O is a secondary endpoint |
| S, static | `static-cap`, long threshold 1, burst 30,000 estimated units, rate R | pressure-blind shedding that completes no more contender work than P on every instance |
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
- `--enable-logging-iteration-details`, which defaults to off in vLLM v0.27.1 and which the plugin does not turn on. The instrument studies add it separately (`instrument-validation.sh:278`). It is the independent witness the step-log completeness check reads (round 10, finding 3).

**Proof, read at every engine start.**
- The whole non-default-arguments line is compared with the registration (build item 5):
  - every registered key must appear with its registered value;
  - any unregistered non-default key refuses the engine;
  - the check is mutation-tested with the specimen astra passed through today's validator (prefix caching on, bfloat16, one sequence, context 8,192, memory 0.5), and with iteration logging left off;
  - it is run on the engine configuration as actually rendered into the deployment, not on the registration's own list.
- The plugin records the priority each request reached the scheduler with. Every premium request must show 0 and every standard one 1.

## The gateway's own decision record

**The gateway writes one line per request, keyed by a client-generated request ID** (build item 4):
- arrival instant;
- tenant and tier;
- decision (admitted, or refused with reason);
- release instant.

**The ID is generated by the harness before dispatch,** and is unique across the study: study, launch, block, arm and trace index. An ID the gateway only echoes cannot name a request whose response never arrived. Today an empty prefix yields an empty ID (`httpsender.go:176`), and the matrix passes a prefix only for two older studies (`m5c-matrix.sh:3323`).

**The join, with every unmatched population defined** (round 7, finding 5):

| Case | Meaning | Treatment |
|---|---|---|
| Client row and gateway record | the normal case | joined |
| Client row, no gateway record | unknown at the gateway: a pre-gateway failure, or a lost log line | its completion is read from the client row itself, as for every request; it carries no arrival or release instant |
| Gateway record, no client row | a harness defect | the run refuses |
| A client row with an empty ID, or any duplicate ID | a harness defect | the run refuses |

**No validity quantity depends on the gateway's record** (round 8, findings 1 and 3).
- v8 inferred "forwarded" work from it and scored a client row with no record as forwarded in S and not completed. A successful S request whose record was lost then became an S failure, which helped P pass.
- An admitted decision also cannot say whether a request reached the engine. Priority rewriting and backend connection both come after admission (`server.go:492`, `:542`, `:577`).

**The record is used only for:**
- the arrival instants `sim-cap` replays;
- the release instants stage A's timing gate reads.

**Exact-token stamping is done once, in its own epoch, and its counts are frozen** (round 8, finding 4; round 9, finding 4).
- At the start of pilot stage A, before any arm, the engine is started and the stamper sends one probe per distinct prompt length directly to the engine's port, never through the gateway.
- Each probe has its own ID, `calib-<prompt length>`, rather than the index −1 the stamper uses today.
- The engine is then stopped, and that epoch's step log is archived as calibration, outside every arm's evidence. The first arm starts on a fresh engine, as every arm does anyway.
- The two counts are frozen into the registration. Every later trace, pilot and main, is stamped from that table, so no main session sends a probe.
- A scheduler record or gateway record carrying a `calib-` ID inside an arm's evidence refuses the run.

Tokenisation of a fixed prompt does not change between instances of one pinned image and revision. Stage B re-stamps its traces live in a calibration epoch and refuses if either count differs.

**Missing gateway records in the pilot refuse** (round 9, finding 5). The main study tolerates a missing record, because no validity quantity reads it. The pilot's R fit and release-timing gate do read it:
- in stage A, a P contender with no gateway record makes the stage fail;
- stage A is bought again only by the owner's decision, never automatically.

## The comparator completes no more contender work than P, on every instance

**Why completed work.** v6 judged deletion by refusals plus a 99% admitted-completion gate. Round 6 broke both:
- **Finding 2:** equal refusals with P losing five admitted contenders after admission passed every gate, while P completed 38,475 fewer input tokens. The gateway decides admission before it reaches the backend (`server.go:492`, `:577`), so a failure after admission is a real path.
- **Finding 4:** across 36 per-arm gates, the 99% gate itself survived about 11% of the time at a true 99.5% completion, which made joint feasibility about 8%.

**Completed work alone is not enough** (round 7, finding 4). Failures in S lower c_S and so help P pass. If S admits 480 contenders and 60 fail after prefill, while P admits 450 and all complete, then c_S = 0.70 ≤ c_P = 0.75. Yet S **processed** 230,850 more prefill tokens, which can inflate its own premium tail. v7's claim that no failure "can favour P" was false.

**Nor is forwarding, as v8 tried** (round 8, finding 2). Ordering forwarded work above and completed work below does not bound what the engine **processed** between them.
- P's lost requests can cancel before prefill, while S's fail after it.
- The proxy cannot tell these apart (`proxy.go:760`).
- Round 8's example passes every v8 gate while S prefills 230,850 more tokens.

**So validity reads the engine's own account of processed work.** The step-logging plugin, loaded in every arm, records in each step the tokens the scheduler gave each request (`hack/vllm-plugins/step_logging_scheduler.py`, the `sched` record's `tokens`, with `computed` before the step and the request's `prompt` from its `add` record).

**That field is all scheduled tokens, prefill and decode together.** The committed CPU fixture's 80-token prompt totals 87 = 80 + 8 − 1 (round 9, finding 3). So v10 splits each step's tokens for each request explicitly:
- **prefill tokens** = min(scheduled, max(prompt − computed before, 0));
- **decode tokens** = scheduled − prefill tokens.

Preemption recomputation, if it happens, is counted as processing in the arm where it happens: it is work the engine did.

**Three quantities, all per instance over its three blocks:**
- **p** = contender prefill tokens, summed over the step records / offered exact contender input tokens.
- **q** = contender decode tokens, summed over the step records / (offered contender requests × the 16-token cap).
- **c** = exact input tokens of contender requests whose client row shows completion with full engine-reported output / offered exact contender input tokens. This is read from the client row alone, so a lost gateway record cannot change it.

p and q count what the engine processed whether or not the request later completed.

**Why q too.** Prefill alone does not bound processing (round 9, finding 2). Failed S contenders can decode for 15 tokens each against long contexts while P's fail after one, and that passes p and c with S executing 4,600 more decode tokens.

**What remains unbounded, stated.** Tokens are counted, not weighted by cost. A decode token against a 7,695-token context costs more than one against a short context, and that is not measured. Both arms' contenders have the same prompt length, so the per-token cost is comparable between them.

**Joining step records to client rows** uses the client-generated request ID. The plugin records vLLM's request ID. That vLLM v0.27.1 derives it from `X-Request-Id` is my reading of the server, not yet verified. Build item 21 verifies it on kind and, if it does not hold, makes the plugin record the header itself. A scheduled request with no client match refuses the run.

A request's tier is its tenant's tier in the frozen trace, and a tier in the gateway's record or a response header must agree, or the run refuses.

**Validity: p_S ≤ p_P, q_S ≤ q_P and c_S ≤ c_P on every contributing instance.**
- **S prefills and decodes no more contender tokens than P,** so S's tail cannot be inflated by extra contender tokens, whatever happened to the requests afterwards.
- **S completes no more contender work than P,** so P cannot win by losing work it processed (round 6, finding 2).
- One violation of either makes the outcome "invalid". It is read after each instance, and a violation stops further purchase.

**R's fitting target is m = 0.05:** S admits about five points less contender work than P in `sim-cap`, which predicts admission only. Processing and completion follow admission when nothing fails, which stage B checks. That is a target on the fitting instance, not a property the population is known to have (round 7, finding 3). Nothing measured before the main study establishes the population's margin, so v8 does not print a probability that validity survives.
- v7's survival table followed from a Gaussian model of d, not from the moments it named. A two-point distribution with the same mean, SD and correlation survives 6.9% of the time, not 55.6% (round 7, finding 2).
- **What v8 relies on instead is sequential purchase,** under Money at risk below: validity is read after every instance, so an invalid study is discovered, and stops buying, at the first instance that shows it.

**Stage B checks the margin on fresh traces.** Each of its two blocks must show p_P − p_S ≥ 0.03, q_P − q_S ≥ 0.03 and c_P − c_S ≥ 0.03, or the design returns to review.

**A purchase-stop rule, not a verdict:** if any of the first three main instances shows p_P − p_S, q_P − q_S or c_P − c_S below 0.02, no further instance is bought. The outcome is "stopped: margin too thin", and nothing is judged.
- The rule reads only S's and P's contender work, never a tail.
- It ends a study whose population margin is visibly below the fitting target before most of its cost is spent.

**Only full instances contribute.** An instance contributes only if it completed all three blocks. An instance cut short by an evidenced Spot interruption contributes nothing and is replaced. Any other early end makes the study invalid (see Evidence).

**Fitting R.**
- In stage A, `sim-cap` replays the three P traces at the gateway's recorded arrival instants, with threshold 1, burst 30,000 and the premium tenants named.
- It predicts S's admissions. With P's admissions from the gateway's record, R is the largest integer in 1…20,000 with predicted admitted contender work a_S ≤ a_P − 0.05 on every trace.
- a is used only to fit R, never to judge validity.
- That R is final. Stage B checks it, and is never used to re-fit it.

**Informative bound.** If stage B's mean p_P − p_S exceeds 0.10, the design returns to review rather than run against a crippled control.

**No interval is computed for f or c.** The rules are point rules on counts, and the counts are published.

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

**Exact tokens are stamped, in one fixed order, before any manifest exists** (build item 18). p, q, c and R's fit are defined in exact tokens, but today:
- the Poisson generator leaves `ExactInputTokens` zero (`trace.go:296`);
- the matrix generates a fresh trace and its manifest just before replay (`m5c-matrix.sh:3304`);
- the replay does not ask for the existing `--require-exact-tokens` refusal (`main.go:628`).

Stamping after the manifest changes the trace's checksum, and regenerating afterwards discards the stamp (round 7, finding 1).

**The order is:**
1. generate the canonical trace;
2. stamp exact tokens against the running engine;
3. derive each arm's trace from the stamped one;
4. checksum;
5. write the manifest;
6. replay with `--require-exact-tokens`.

`sim-cap` reads the same stamped trace. A missing stamp refuses before the first request, not after the run.

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

**Per-instance gates.** Each is a point rule, and any failure makes the outcome "invalid":
- premium loss under 1% in every arm;
- p_S ≤ p_P, q_S ≤ q_P and c_S ≤ c_P;
- the arm's step log complete (see Evidence).

**What the validity gate does and does not establish.** It establishes that S neither processes nor completes more contender work than P on any instance, and that is the whole of the deletion safeguard.
- It does not establish that O's contenders complete. O is only P/O's denominator, so O has no contender gate in the main study.
- v6's per-arm 99% gate on O was what nearly no main study would survive (round 6, findings 4 and 5).

**Why no t-bounded safeguards.** A t-bound on ratios that are each at least 1 can still fail on one extreme instance: 11 at 1.0 and one at 3.0 gives a lower bound of 0.93 (round 5, finding 6). P against S contender completion is published.

**Decision: a futility look, then one test.**
- **At 6 contributing instances:** if the mean of y is at or above ln 1.0, stop with outcome "no demonstrated benefit".
- **At 12 contributing instances:** benefit if the one-sided 95% t upper bound of mean y is below ln 0.95, and the one-sided 95% t upper bound of mean ln(P/O) is below 0.
- **Launches exhausted (14) with fewer than 12 contributing:** the test runs on what exists if there are at least 6; with fewer, the outcome is "insufficient".

**Precedence:** invalid, then stopped, then insufficient, then the decision. So identical evidence gives one verdict.

**Assumptions, stated in the claim.** The 5% error rate holds if the instance log-ratios are approximately normal **and** independent. Neither can be checked with 12 instances.
- A minority of about 10% of instances on which P is much worse is missed by all 12 draws 0.9¹² = 28% of the time.
- A shared component with correlation 0.1 raises the error to 13%.
- So the claim is about the typical instance, and every instance's y is published.

**Power at a true P/S of 0.80,** normal and independent, primary alone, futility applied.

| σ of y | Mine (20,000 per row) | astra's (1,000,000 per row) |
|---:|---:|---:|
| 0.10 | 100% | 99.996% |
| 0.15 | 98% | 98.07% |
| 0.20 | 88% | 87.29% |
| 0.30 | 59% | 58.48% |

**Error at a true P/S of 0.95:** 4.9% to 5.1% (mine) and 4.98% (astra's).

**This is the primary's power alone.** v8 prints no joint feasibility figure.
- The two whole-study gates, validity and premium loss, have survival probabilities nothing before the main study measures.
  - v7 multiplied a Gaussian survival table by a loss survival taken as 1.
  - Round 7 showed both factors could be far lower under assumptions consistent with every pilot rule (findings 2, 3 and 6). One example: 0.9¹² = 28% loss survival, if one instance in ten loses 2%.
- A product of assumed factors would be a number the evidence does not support.

## Money at risk, because survival cannot be known in advance

**Every whole-study gate is read after each main instance, and a failure stops further purchase.** So the money an invalid or stopped study costs is bounded by when it is discovered, whatever the survival probability.

At the expected rate, the pilot costs $2.73 and each main instance about $1.88:

| Discovered after | Spent, expected |
|---|---:|
| the pilot (any pilot gate) | $2.73 |
| main instance 1 | $4.61 |
| main instance 3 (the margin stop's last reading) | $8.36 |
| main instance 6 (the futility look) | $13.99 |
| main instance 12 | $25.25 |

**The registration asks the owner to accept this table, not a probability.** It shows what a failure costs at the point where it is found.
- **It does not say where failures will land.** v8 claimed the stop rules keep common failures near the top rows, and round 8 (finding 6) showed that does not follow.
- **Round 8's example:** one instance in ten violates the loss gate, and every pilot passes.
  - An invalid study is then found after instance 3 in 62% of the cases where it is found at all.
  - The expected spend is about $16.20, 2.7296 + 7.18 × 1.8766.
- Sequential reading bounds the cost of a failure by when it appears. It does not make failures appear early.

**Outcomes, named in advance:**
- invalid;
- stopped: margin too thin;
- insufficient;
- benefit;
- no demonstrated benefit.

v5's "benefit that fails safeguards" is gone with the t-bounded safeguards: a safeguard failure is now "invalid".

## Pilot, in two stages, neither in the main analysis

**Stage A: one instance, three blocks of I, O and P** (randomised order). It establishes:
- **contention:** O's pooled premium TTFT p99 ≥ 1.5 × I's;
- **loss:** every arm, P included, under 0.5% premium loss, and O completes ≥ 95% of contender requests (so the engine is not overloaded);
- **engagement:** P refuses 5% to 30% of contender requests;
- **P/O:** P's pooled premium p99 is at most 0.85 × O's, so that P/O's gate is not hopeless;
- **release timing:** in P, at least 95% of admitted contenders have 50 ms or less between the gateway's release instant and the first content byte;
- **restart:** an engine restart between arms reuses host-path weights and takes under 3 minutes.

The P/O screen reads P against O, never against S.

Then stage A fits R.

**Stage B: one instance, two full four-arm blocks** with R final. It establishes:
- every arm's loss under 0.5%;
- validity, with p_P − p_S, q_P − q_S and c_P − c_S each at least 0.03 in each of its two blocks;
- the live re-stamp equal to the frozen counts;
- the informative bound, mean p_P − p_S ≤ 0.10;
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

| Launch ended by | Outcome |
|---|---|
| Completion of all three blocks | the instance contributes |
| An evidenced Spot interruption | the launch contributes nothing and is replaced |
| Anything else (engine, gateway, harness, runner, a deadline), at any point | **the study is invalid**, unconditionally |

**Why unconditionally.** v6 reconstructed such an end and applied the loss gate. Round 6 (finding 1) showed a launch that died before the last premium request of its final arm: loss 0.0086%, so it passed. Yet it was excluded for not completing three blocks, so its measured P/S, perhaps unfavourable, disappeared.
- Such an end may depend on the arm, so the only rule that cannot select by outcome is to stop.
- Reconstruction remains, for the published account of what happened.

**The matrix's projection stop is disabled for this study** (build item 10). Its projection includes the cold first cell and multiplies by 1.2, so it would refuse all three session shapes after their first cell (`m5c-matrix.sh:2795`, `:2833`, `:2848`; round 5, finding 5). The session's cell count is fixed by the registration. Its deadlines are sized from that count, and the hard stop and the sweeper are what bound time.

**Main launches are capped at 14**, replacements included.

## What must be built before any purchase

1. **A new study, `prospective-admission`,** with its arms, a frozen manifest and readings (`study.go:529` permits `kv-aware` only).
2. **The benchmark profile accepts `min_tokens` only when equal to `max_tokens`,** with a test that any other value is still refused.
3. **The Poisson generator populates `MinOutputTokens`.**
4. **Mandatory client-generated request IDs,** unique across the study, and **the gateway's per-request record** (arrival, tenant, tier, decision, release) keyed by them. A gateway record with no client row refuses, as does a duplicate. A client row with no record is allowed in the main study and refused in the pilot. `sim-cap` replays the arrival instants.
5. **The engine-arguments validator compares the whole line,** mutation-tested key by key.
6. **The matrix deploys admission per arm** (`m5c-matrix.sh:2187`). **Step-log capture is proved complete by counts, not inferred from a marker** (round 8, finding 5; round 9, finding 1).
   - **Waiting for an ID fails:** today capture waits for the last trace request's ID (`:3032`). A forwarded request can fail in the engine's frontend before the scheduler sees it, so that ID may never appear.
   - **Waiting for quiescence fails too:** the plugin hands batches to a background writer, so an empty scheduler and a file ending in a flush can coexist with an unwritten final batch. astra reproduced exactly that with the real plugin.
   - **So the plugin numbers every record.** Each flush record carries its first and last sequence numbers, and an overflow record already exists when its buffer fills (`step_logging_scheduler.py:70`).
   - **At the end of each arm the engine is not stopped.** v10 stopped it, and round 10 (finding 2) showed the terminal record would then be unreachable:
     - capture reads the log by `kubectl exec` into the engine container (`:3037`);
     - the log lives in the Pod's `emptyDir`;
     - the next arm deletes the namespace.
   - **Instead, a sentinel triggers the terminal record.** After the replay returns and the engine reports no running or waiting requests, capture writes a sentinel file beside the log, by `kubectl exec`. The plugin's writer thread, its only consumer, waits on its queue with a one-second timeout and checks for the sentinel. When it finds it, it:
     - drains its queue;
     - reads the scheduler thread's record counter and buffer length;
     - writes a terminal record holding its last written sequence number, that counter, that buffer length and the last step index.

     If the buffer is not empty or the counter is ahead of what was written, the terminal record says so, and capture retries for up to 60 s before refusing. The scheduler thread already flushes its buffer whenever the engine is idle (`step_logging_scheduler.py:144`).
   - **Capture then reads the file as it does today,** still inside the running container, and archives it before the namespace is deleted.
   - **The arm's step log is complete only if:**
     - the terminal record is present, with an empty buffer and the counter equal to the last written sequence number;
     - the sequence numbers run without a gap from 1 to the terminal's;
     - there is no overflow record;
     - **the plugin's steps match the engine's own iterations one to one.**

   **The step match, made exact** (round 10, finding 1). The plugin numbers its steps from 1, incrementing before it records (`step_logging_scheduler.py:122`). vLLM numbers its iterations from 0, as the runner already checks (`m5c-matrix.sh:3004`). So the rule is:
     - plugin step k corresponds to `Iteration(k − 1)`;
     - the count of plugin steps equals the count of iteration lines;
     - each step's total scheduled tokens equals that iteration's total, the per-step comparison the existing instrument checker already makes.

     v10's rule ("the last step index equals the last iteration") rejected a complete log. On the committed CPU fixture: 70 steps numbered 1 to 70, against 70 iterations numbered 0 to 69.

   The iteration log is written by vLLM independently of the plugin, and needs `--enable-logging-iteration-details`, which is now in the frozen apparatus.
   - A request that reached the gateway but never the scheduler simply has zero processed tokens.
   - An incomplete step log makes the outcome "invalid", like any non-Spot early end.
   - `check_step_log.py` is not reused as is: it requires every client request to be scheduled and assumes complete output accounting (`:139`, `:144`), which refusals and partial failures here violate. A checker for this study is written instead.
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
    - round 5's lost-refusal example, which must be "invalid";
    - round 6's five post-admission losses, which must be "invalid";
    - round 6's launch dying in its last arm, which must be "invalid";
    - a censored instance;
    - a loss at exactly 1%;
    - a Spot-interrupted launch, which must be replaced, not judged;
    - fewer than 6 contributing instances.
16. **A termination sweeper that exists before any launch** (see Cost).
17. **The reserving spend ledger.**
18. **The exact-token order:** generate, stamp from the frozen counts, derive, checksum, manifest, then replay with `--require-exact-tokens`.
    - The live stamp runs only in calibration epochs, with `calib-` IDs, directly against the engine.
    - Tested by a rehearsal whose stamp is deliberately missing, which must refuse before the first request.
19. **TPOT on engine tokens and the last content frame,** beside the existing figure, which stays for the studies it has already judged.
21. **The step-record join and processed work.**
    - Verify on kind that the plugin's request ID carries the client's `X-Request-Id`, and if not, make the plugin record it.
    - Compute p and q from the `sched` records by the registered split, tested on the committed CPU fixture: its 80-token prompt must give 80 prefill and 7 decode tokens.
    - Refuse on a scheduled request with no client match, and on a `calib-` ID inside an arm.
    - Test round 9's reversal example: raw sums put S below P while prefill puts S above, and the analysis must call it "invalid".
    - (Numbered 21 so that references to 20 stay stable.)
20. **Rehearsals on kind with the stub engine:**
    - a whole replay-to-verdict run;
    - c_S > c_P on one instance;
    - a lost refusal;
    - an admitted contender failing after admission;
    - a request whose response never arrived, joined to the gateway's record by its client ID;
    - a request that never reached the gateway, and an S success whose gateway line is deleted, which must still count as completed;
    - an admitted contender failing after prefill in S, whose processed tokens must count in p_S;
    - a forwarded request refused by the engine's frontend before scheduling, which capture must not wait for;
    - a final batch held back from the writer when the sentinel arrives, which must make the terminal record report it and capture refuse after 60 s;
    - a complete log, which must pass the step-to-iteration match; the committed CPU fixture is the first test, at 70 steps against iterations 0 to 69;
    - a step whose token total differs from its iteration's, which must refuse;
    - S's failed contenders decoding 15 tokens against P's one, which must fail q;
    - an exact-token stamp sent through the gateway by mistake, which must refuse;
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
  - **Its role.** v6 said "`ec2:TerminateInstances` and nothing else", which could not find an instance to terminate (round 6, finding 7). The role is granted:
    - `ec2:DescribeInstances`, which cannot be scoped by resource, to find tagged instances;
    - `ec2:TerminateInstances`, conditioned on the `study-deadline` tag being present;
    - its own log group, to write to.

    Today's scheduler role grants only `eks:UpdateNodegroupConfig` (`ttl.tf:48`).
- **The sweeper is exercised before the study.** A t3.nano is launched with a deadline two minutes ahead. The exercise passes only if the instance's `terminated` state arrives within 12 minutes of the deadline, and the measured lag is recorded.
- **This changes the account's infrastructure** with a `terraform apply` in the bootstrap stack, and needs the owner's approval as its own step.

**Deadlines:**

| Session | Expected hours | Hard stop | Backstop | `study-deadline` after launch |
|---|---:|---:|---:|---:|
| Pilot A, B | about 2.1 and 1.9 | 2 h 30 | 2 h 40 | 2 h 50 |
| Main, each | about 2.75 | 3 h 30 | 3 h 40 | 3 h 50 |

**The reserved lifetime is the deadline plus 15 minutes:** 185 minutes for a pilot session, 245 for a main one.
- The 15 minutes are the exercise's 12-minute pass limit, measured from the deadline and so already including the wait for a sweep, plus 3 to spare.
- AWS documents delivery delays and retries for both EventBridge and Lambda, so no interval is a guarantee.
- The exercise establishes that the sweeper works, not a maximum latency (round 6, finding 8).

**The worst-case rate per instance-hour:**

| Component | $/h |
|---|---:|
| Spot cap | 1.10 |
| 200 GB gp3, at most $0.10 per GB-month over 730 h | 0.0274 |
| Public IPv4 | 0.005 |
| **Total** | **1.1324** |

**The allowance, at the reserved lifetimes:** (2 × 185 + 14 × 245) min = 63.33 h, × $1.1324 = **$71.72**. The pilot alone is **$6.98**.

**This is an operational allowance, not an enforced ceiling.**
- It holds if, on every launch, at least one of the three terminators works within its time: the sweeper, the in-instance backstop, or the operator's hard stop.
- If all three fail on one instance, spending continues until a person notices.
- The account's AWS Budgets alerts (`infra/aws/bootstrap/budget.tf`) are the last line, and only if an address is subscribed. That file says an empty list means no alerts at all, and whether one is set is to be confirmed before the study.

**Small charges outside the allowance:**
- the sweeper's exercise, a few cents for a t3.nano;
- Lambda and EventBridge invocations, within the free tier at one per 5 minutes;
- S3 evidence storage.

**Expected,** at about $0.6824 per hour (Spot about $0.65, plus the volume and address):
- about **$25** for 12 instances;
- about **$14** if the futility look stops at 6;
- about **$2.73** for the pilot alone;
- plus about **$1.90** for each Spot replacement, which the expected figures exclude.

**The ledger reserves before it records.**
- Each launch first appends its reserved lifetime × $1.1324 as a reservation.
- It refuses if the reservations and recorded sessions together would exceed **$75**.
- The ledger limits what the study starts. It cannot stop an instance already running, which is the terminators' job.
- After the session it records launch and termination times from EC2 and CloudTrail.
- Billed amounts come from Cost Explorer when it settles, and are published beside the estimate.

## What v11 changed, against the review of v10

| v10 finding | Change |
|---|---|
| 1: last step against last iteration is off by one | plugin step k matches `Iteration(k − 1)`, with equal counts and per-step token totals; the CPU fixture is the first test |
| 2: stopping the engine makes the terminal record unreachable | the engine is not stopped: a sentinel triggers the writer's terminal record, and capture reads it in the running container |
| 3: iteration logging is not in the frozen apparatus | `--enable-logging-iteration-details` frozen; the validator runs on the rendered configuration |

Round 10 re-derived the power table (2,000,000 studies per row), the null rate and every cost figure, and agreed with each.

## What v10 changed, against the review of v9

| v9 finding | Change |
|---|---|
| 1: quiescence does not prove the writer drained | numbered records; a terminal record at a graceful stop; reconciliation with vLLM's own iteration log; a checker for this study |
| 2: prefill and completion leave decode unbounded | q, contender decode tokens, added to validity; cost-weighting stated as unmeasured |
| 3: `tokens` is all scheduled tokens | an explicit per-step prefill and decode split, tested on the committed fixture |
| 4: stamping probes reach the instrumented scheduler | one calibration epoch, `calib-` IDs, frozen counts; no main-session probe |
| 5: missing gateway records in the pilot | the pilot refuses them |

## What v9 changed, against the review of v8

| v8 finding | Change |
|---|---|
| 1: a missing gateway record erased S's successes | completion is read from the client row alone; no validity quantity depends on the gateway's record |
| 2: forwarding and completion do not bound processing | validity reads processed work from the engine's step records: p_S ≤ p_P and c_S ≤ c_P |
| 3: the gateway record cannot say what reached the engine | it is no longer asked to; it serves only arrival and release timing |
| 4: stamping through the gateway breaks the join | stamping goes directly to the engine, under its own ID prefix |
| 5: capture waits for an ID that may never appear | capture ends on engine quiescence |
| 6: the money-at-risk table implied early discovery | said not to; round 8's $16.20 example printed |
| 7: the 15-minute explanation double-counted | corrected |

## What v8 changed, against the review of v7

| v7 finding | Change |
|---|---|
| 1: no exact-token pipeline | a fixed generate → stamp → derive → checksum → manifest → `--require-exact-tokens` order (build item 18) |
| 2: the survival table followed from a Gaussian model, not its moments | removed; v8 prints no survival probability and relies on sequential purchase, with a money-at-risk table |
| 3: the fitting margin is not the population margin | said so; stage B requires 0.03 per block; a purchase-stop rule on the first three main instances |
| 4: S failures favour P under completed work alone | validity also requires S to forward no more work than P (f_S ≤ f_P) |
| 5: the mandatory join contradicted pre-gateway failures | every unmatched population defined; no complete-join gate; a pre-gateway rehearsal |
| 6: loss survival assumed to be 1 | no joint feasibility figure; loss is read after each instance and stops purchase |
| 7: TPOT on content frames | TPOT on engine tokens and the last content frame (build item 19) |

## What v7 changed, against the review of v6

| v6 finding | Change |
|---|---|
| 1: a nearly complete non-Spot launch escaped by exclusion | any non-Spot early end makes the study invalid, unconditionally |
| 2: admitted failures let P delete more with equal refusals | validity on completed contender work, c_S ≤ c_P per instance |
| 3: gateway IDs cannot name a request with no response | mandatory client-generated IDs, unique study-wide, join checked both ways |
| 4: the completion gates took feasibility to about 8% | the per-arm completion gates are removed; feasibility recomputed |
| 5: the pilots could pass an O that the main study would fail | O has no contender gate in the main study |
| 6: survival assumed independent blocks; the spread check misdescribed | the table includes block correlation; m = 0.05; stage B checks the margin per block |
| 7: the sweeper could not find instances | `ec2:DescribeInstances` added |
| 8: $69 was a conditional figure | a 15-minute allowance; stated as an allowance, not a ceiling; the residual failure named |

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
