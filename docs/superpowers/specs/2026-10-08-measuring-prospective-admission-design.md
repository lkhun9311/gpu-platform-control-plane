# Measuring prospective admission directly (item 3): the design, v21

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
| v11 | 20172ae | astra's review of v10 | 1 blocker, 2 majors |
| v12 | bcbe0d8 | astra's review of v11 | 2 blockers, 1 major |
| v13 | 3e4a6c9 | astra's review of v12 | 2 blockers, 1 major, 3 minors |
| v14 | c42efd8 | astra's review of v13 | 2 blockers, 2 majors |
| v15 | f750185 | astra's review of v14 | 2 blockers, 1 minor |
| v16 | ed0a06a | astra's review of v15 | 2 blockers, 1 minor |
| v17 | 46353cc | astra's review of v16 | 2 blockers, 1 major |
| v18 | 92c2c16 | astra's review of v17 | 2 blockers, 2 majors |
| v19 | e7a9896 | astra's review of v18 | 3 blockers, 2 majors, 1 minor |
| v20 | 2d8ec3d | astra's review of v19 | 2 blockers, 2 majors, 1 minor |
| v21 | this page | astra's review of v20 | 2 blockers, 1 major |

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
| Client row, no gateway record, **the request failed before a response, and no scheduler record carries its ID** | it never finished arriving at the gateway: the record is written durably at the arrival stamp, before admission, so a request the gateway read always has one | a failure: premium counts at +∞ and toward loss; a contender is not completed |
| **A scheduler record whose ID has no gateway record** | the engine processed a request the gateway has no arrival for | **the outcome is "invalid"** (round 20, finding 1). Its lag cannot be bounded, and "no response" does not show it never arrived: a header timeout is consistent with the engine already generating (`proxy.go:594`) |
| Client row, no gateway record, **the request succeeded** | the gateway served it and its record was lost | **the outcome is "invalid"** (round 19, finding 1). A served request without a record has no lag, so neither its own timing nor its load's displacement of others can be bounded |
| Gateway record, no client row | a harness defect | the run refuses |
| A client row with an empty ID, or any duplicate ID | a harness defect | the run refuses |

**No validity quantity depends on the gateway's record** (round 8, findings 1 and 3).
- v8 inferred "forwarded" work from it and scored a client row with no record as forwarded in S and not completed. A successful S request whose record was lost then became an S failure, which helped P pass.
- An admitted decision also cannot say whether a request reached the engine. Priority rewriting and backend connection both come after admission (`server.go:492`, `:542`, `:577`).

**The record is used only for:**
- the arrival instants `sim-cap` replays;
- the release instants stage A's timing gate reads;
- the dispatch-lag reading (see Dispatch fidelity), which comes from this record alone.

**Exact-token stamping is done once, in its own epoch, and its counts are frozen** (round 8, finding 4; round 9, finding 4).
- At the start of pilot stage A, before any arm, the engine is started and the stamper sends one probe per distinct prompt length directly to the engine's port, never through the gateway.
- Each probe has its own ID, `calib-<prompt length>`, rather than the index −1 the stamper uses today.
- The engine is then stopped, and that epoch's step log is archived as calibration, outside every arm's evidence. The first arm starts on a fresh engine, as every arm does anyway.
- The two counts are frozen into the registration. Every later trace, pilot and main, is stamped from that table, so no main session sends a probe.
- A scheduler record or gateway record carrying a `calib-` ID inside an arm's evidence refuses the run.

Tokenisation of a fixed prompt does not change between instances of one pinned image and revision. Stage B re-stamps its traces live in a calibration epoch and refuses if either count differs.

**Missing gateway records refuse in the pilot, as in the main study** (round 9, finding 5; round 19, finding 1). In the main study, a served request with no record makes the outcome "invalid" (see the join). The pilot's R fit and release-timing gate also read the record:
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

**The window.** p and q count only steps whose start (`t0`, converted to wall time by the plugin's own anchors, as `step_boundary.py:293` already does) is before the arm's **window end**: the latest end instant among **all** its premium requests, failures included, from the client rows.
- Every row carries an end instant on every outcome (build item 24). Today timeouts, transport errors and non-200 responses carry none. A window taken over successes alone could end 30 s early, before a final premium timeout, and drop exactly the contender work that preceded it (round 13, finding 2).
- A premium row without an end instant refuses the run.
- Validity protects S's premium tail from inflation by extra contender processing. A step that starts after the last premium request has finished cannot inflate any premium TTFT in that arm.
- That makes the window the quantity validity needs, and it is the quantity a terminal record written after the replay can prove complete (round 12, finding 2).
- The harness and the engine run on one host, with one kernel clock, so the comparison needs no cross-host synchronisation.
- c is not windowed: completion is read from the client rows, whenever it happened.

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
2. stamp exact tokens from the counts frozen in the calibration epoch, never by a live probe in an arm (round 12, finding 6);
3. derive each arm's trace from the stamped one;
4. checksum;
5. write the manifest;
6. replay with `--require-exact-tokens`.

`sim-cap` reads the same stamped trace. A missing stamp refuses before the first request, not after the run.

## Dispatch fidelity

**A frozen trace is only a frozen load if it is sent on time** (round 11, finding 1). The harness stamps each send inside its goroutine, after any scheduling delay (`replay.go:305`), and TTFT and the timeout both start from that stamp. So a replay that falls behind sends less load per second without any measurement noticing. A P arm stretched to twice its duration halves its offered rate and passes every work gate.

**Lag is measured where the request lands, not where it leaves.** Two rounds placed the stamp on the client, and each time a delay could hide after it:
- v12's send stamp precedes prompt construction and the HTTP write (round 12, finding 1);
- v13's `httptrace` `WroteRequest` fires when `Request.write` returns, before the transport flushes its buffer, so a small request can be stamped before it is written (round 13, finding 1; Go 1.26.6 `request.go`, `transport.go`).

Any client-side stamp has some later point a delay can sit behind. So the stamp moves to the receiving side.

**The rule.**
- The replay persists its origin instant in the raw file (build item 22).
- **The gateway stamps its arrival instant at the moment it has finished reading the request body,** which is just before its admission decision. That is after every client-side delay, header and body alike. A stamp at handler entry would precede a body the client is still writing (round 13, finding 3).
- Each request's **dispatch lag** is that arrival instant minus (origin + scheduled offset), on the one host clock the harness and the gateway share. The rows already carry the offset (`replay.go:44`).
- **Per arm,** the invalid outcome follows if any of these holds:
  - the p99 lag exceeds 20 ms;
  - the p99.9 lag exceeds 100 ms;
  - the mean lags of P and S differ by more than 2 ms. This rule applies from stage B on, since stage A has no S arm (round 14, finding 3).

  This is a harness failure, not a property of the arm.
- **A 50 ms maximum-lag ceiling also applies** (see "What lag can do to other requests" below). It is a zero-tolerance rule, and the page does not pretend otherwise.
  - v13 dropped a 250 ms maximum because one TCP retransmission anywhere in some 582,000 requests would invalidate the study (round 13, finding 4).
  - v20 reinstated a maximum because without one, a late request's displaced load cannot be bounded (round 19, finding 2). Round 20 (finding 3) pointed out the conflict: at one 60 ms delay per 100,000 requests, both pilots pass 50% of the time while the main study survives 0.3%.
  - **Both findings are right, and no rule satisfies both.** v21 keeps the ceiling, because an unbounded displacement would let the result be produced by the harness. It does not claim the ceiling will survive.
  - **The ceiling is read after every instance, like every whole-study gate,** and its first violation stops further purchase. So its cost is bounded by when it fails (see Money at risk).
  - **The pilots measure the harness's lag tail and publish it.** Zero exceedances above 25 ms in some 68,000 pilot requests cannot establish a rate as low as 95% main-study survival would need, one in about 11 million. The page says that instead of implying it.
- **A served request with no gateway record makes the outcome "invalid"** (see the join). v19 excluded such requests from every lag statistic, so two late contenders whose records were lost escaped the lag rules entirely (round 19, finding 1).
  - The gateway writes its record durably at the arrival stamp, before admission, so a lost one is a defect, not noise.
  - Stage A refuses on any lost record.
- **A scheduler record with no gateway record also makes the outcome "invalid"** (round 20, finding 1).
- A request with neither record, which failed before any response, never finished arriving. It is a failure under the loss and completion rules.
- **These rules bound when load arrives, not any one request's TTFT.** v14 claimed a sparse delay could move a p99 "only slightly". It cannot be caught by any aggregate rule, and round 14 (finding 2) showed four delayed requests per replay moving S's p99 from 100 to 1,000 ms. No aggregate rule can catch a few delayed requests. So the decision does not trust them: any request with lag above 5 ms is uncertain and bounded (see "Late requests are not trusted, they are bounded" under Endpoints).
- Each arm's lag distribution is published.
- The pilot measures it first: stage A refuses at the p99 and p99.9 limits, and stage B at all three.

## Sampling

**Instances are independent launches**, each a separate Spot request. Shared hardware generation, image and region could still correlate them. Round 5 (finding 7) showed that an intra-class correlation of 0.1 raises the error to 13% even when each y is exactly normal. That correlation cannot be tested with 12 instances, so it is stated as an assumption (see Decision).

**Seeds are fixed before any purchase.**
- The registration freezes a list of distinct trace seeds: one per block, in launch order, for 14 launches × 3 blocks, plus the pilot's.
- Replacements take the next unused triple.
- Today's seed check is per invocation only (`m5c-matrix.sh:520`), so a study-wide uniqueness check is build item 7.

**Arm order.** Each block's arm order is a permutation drawn from a hash of the registration's seed, the launch index and the block index. Today the generic matrix runs a fixed order (`m5c-matrix.sh:822`).

## Endpoints and decision: one ratio per instance

### Late requests are not trusted, they are bounded

Rounds 12 to 17 each found a delay that defeated the latest timing rule.
- v17 rested on an arm-blind harness. Round 17 (finding 2) showed that is not enough: a delay at the same trace positions in both arms lands in different parts of each arm's latency distribution. Three such requests made a P/S of 0.10 out of a true 1.0, with every lag check passing.
- What every one of those attacks needed was a **late** request whose TTFT the decision then trusted.

**So v18 trusts no late request.**
- **A request is uncertain** if its dispatch lag exceeds **L = 5 ms**.
- An uncertain request's TTFT is not used as a value. It is **bounded over 0 to +∞** (see "Uncertain requests and the decision" below), and the decision must hold whatever it was.
- **More than 0.1% uncertain premium requests in an arm makes the outcome "invalid".** Stage A refuses if more than 0.05% of its requests have lag above L, so a main study is not bought onto a harness that cannot keep up.

**Trusted lag is not merely published: it is in the decision's bounds.** v18 published the 5 ms bias beside the result. Round 18 (finding 3) showed what that allowed: a 1.5 ms lag on S turned a true ratio of 0.99 into 0.92, a pass. v19 takes each arm's TTFT in the definition conservative for the side being bounded (see "The interval for each instance's y" below). So every dispatch lag, trusted or not, can only move the decisive bound against P.

**What lag can do to other requests, and its rule.** A request's lag also changes when its load arrives, and so what other requests meet. Bounding a late request's own TTFT does not bound that (round 18, finding 2): two contenders per replay delayed 900 ms can move which premium requests meet a prefill, while every premium request is on time.
- **The lag ceiling, for every request:** every request in an arm, contender or premium, must have lag at most **50 ms**, or the outcome is "invalid". Stage A refuses if any request's lag exceeds 25 ms, so the main study starts with headroom.
  - v19 applied it to contenders only, and left uncertain premium requests without a maximum. Round 19 (finding 2) showed three premium requests delayed 900 ms could, by displacing their own high-priority work, move six other P requests out of the tail, with both bounds equal.
- **Within the ceiling:**
  - a premium request with lag between 5 and 50 ms is uncertain for its own TTFT, under the 0.1% cap;
  - one at 5 ms or less is trusted.
- **What remains, stated in the claim:** any request's load can be displaced by up to 50 ms, and that can change which premium requests meet contention.
  - Its effect on the tail is not bounded by any measurement in this design.
  - A contender's prefill takes on the order of seconds at a 512-token budget, so a 50 ms shift moves its contention by a small fraction of its length.
  - That is an argument, not a bound, and the page says so.

**Arm-blindness is kept as an integrity check, not as the defence** (build item 26). Round 17 (finding 4) showed literal argument equality cannot work on this runner: the manifest, raw output path and request-ID prefix legitimately differ per arm (`m5c-matrix.sh:3323`). The check compares the **resolved sending configuration**, normalised for those three:
- timeout;
- connection pool;
- concurrency;
- stream options;
- the sender's own settings.

### TTFT

**Premium TTFT is measured from the request's scheduled instant (origin + offset) to the gateway's stamp when it forwards the first content frame to the client.**
- **The end is a server-side stamp,** so a delay in the client's reading or parsing of the response is not in it (round 15, finding 1). The client's first-content stamp follows its own read and parse (`httpsender.go:415`, `:507`). The gateway's existing first-byte stamp closes on the response headers, not the first token (`proxy.go:208`).
- **The start is the scheduled instant,** the open-loop convention. Any delay before the request lands is charged to that request, so it can never shorten one. A late-delivered request cannot skip a queue it was scheduled into (round 15, finding 2).

**TTFT-arrival is measured too,** from the gateway's arrival stamp to the same end. A request's two TTFTs differ by exactly its dispatch lag:
- TTFT-scheduled includes any wait before the request landed;
- TTFT-arrival excludes it.

The decision's bounds use whichever is conservative (next section), so v18's separate consistency check is no longer needed. Both definitions' results are published.

**A premium request whose response arrived but whose gateway record is missing** makes the outcome "invalid" (see the join).

**Per instance and arm:**
- The pooled premium TTFT p99 over the instance's three blocks.
- Every premium failure (timeout, error, short completion, or unserved because the launch ended early) counts at +∞.
- About 11,600 premium requests per arm.

**y_i** = ln(p99_P / p99_S) on TTFT-scheduled; likewise ln(p99_P / p99_O).

**Uncertain requests and the decision** (round 16, finding 2; round 17, findings 1 and 3). v16 set a missing P value to +∞, believing that could only hurt P. But the t bound is not monotone in one observation: raising one instance's y from −2 to −0.11 shrank the SD enough to turn U = +0.026 into U = −0.099, a pass. So the uncertain values are bounded rather than imputed.

**The interval for each instance's y.** p99 rises with any one value, so the ratio's extremes come from opposite assignments in the two arms:
- **y_hi** = ln(p99 of P's **TTFT-scheduled**, with P's uncertain values at +∞ / p99 of S's **TTFT-arrival**, with S's uncertain values at 0);
- **y_lo** = ln(p99 of P's **TTFT-arrival**, with P's uncertain values at 0 / p99 of S's **TTFT-scheduled**, with S's uncertain values at +∞).

**Why the definitions cross.** On y_hi, the bound the benefit decision must clear:
- P carries every wait it had before landing;
- S is credited with none of its own.

So no dispatch lag in either arm, trusted or uncertain, can move y_hi in P's favour. Round 18's example (finding 3), a true 0.99 shown as 0.92 by 1.5 ms of S lag, gives y_hi = ln(19.8 / 20) = −0.010, above ln 0.95, and fails. I re-computed it.

v17 set both arms to 0 and then both to +∞. That is not the extremes. Round 17 (finding 1) built a case where both settings gave 0.792 while the true ratio could be 0.99, and the false benefit passed. Under the corrected interval, that case gives a maximum U of +0.021, a fail, which I re-computed.

**The decision over the box.**
- The upper bound U = mean + t·sd/√n is convex in the vector of y's: a linear mean plus a norm. A convex function's maximum over a box is at one of its vertices.
- **So benefit requires U < ln 0.95 at every vertex,** each instance at y_lo or y_hi, at most 2¹² = 4,096 combinations.
- **P/O is bounded the same way,** with O in S's place, and requires U < 0 at every vertex. Its threshold is 0, not ln 0.95 (round 18, finding 6).
- I checked convexity numerically: 400,000 random interior points never exceeded their box's vertex maximum.

**Infinite ends.**
- If p99_P is +∞ at y_hi (failures plus uncertain values above the rank), then y_hi = +∞, U = +∞ at that vertex, and benefit fails. Round 17 (finding 3) showed 116 failures plus 11 uncertain values can do this while both caps pass.
- If p99_S is +∞ at y_lo, then y_lo = −∞, and **benefit fails as well.** v18 said this end could only help P, and round 18 (finding 1) showed otherwise. As one observation goes to −∞, the SD grows faster than the mean falls: with eleven at a and one at a − d, U = a + 0.796 d / 12, which goes to +∞. So the vertex at y_lo defeats the decision. I re-computed this: d = 10 gives U = 0.563, and d = 1,000 gives 66.2.
- If both p99s are infinite at the same vertex, that instance's y is undefined there, and benefit fails.
- **So any infinite end on any instance fails benefit.** The futility look still reads y_lo, and treats −∞ as continuing.

**The futility look uses y_lo, the end most favourable to P.** It stops only if even that end's mean is at or above 0. Stopping for futility cannot raise the false-benefit rate, and this choice makes the stop deterministic (round 17, finding 3).

**Per-instance gates.** Each is a point rule, and any failure makes the outcome "invalid":
- premium loss under 1% in every arm;
- p_S ≤ p_P, q_S ≤ q_P and c_S ≤ c_P;
- the arm's step log complete (see Evidence).

**What the validity gate does and does not establish.** It establishes that S neither processes nor completes more contender work than P on any instance, and that is the whole of the deletion safeguard.
- It does not establish that O's contenders complete. O is only P/O's denominator, so O has no contender gate in the main study.
- v6's per-arm 99% gate on O was what nearly no main study would survive (round 6, findings 4 and 5).

**Why no t-bounded safeguards.** A t-bound on ratios that are each at least 1 can still fail on one extreme instance: 11 at 1.0 and one at 3.0 gives a lower bound of 0.93 (round 5, finding 6). P against S contender completion is published.

**Decision: a futility look, then one test.**
- **After every instance:** if any instance has an infinite end, benefit is already impossible. No further instance is bought, and the outcome is "no demonstrated benefit" (round 19, finding 4).
  - v19 let the futility look read −∞ as "continue". That could buy eleven more instances, about $20.64, after the verdict was fixed.
- **At 6 contributing instances:** if the mean of y_lo is at or above ln 1.0, stop with outcome "no demonstrated benefit".
- **At 12 contributing instances:** benefit if, at every vertex of the box, the one-sided 95% t upper bound of mean y is below ln 0.95, and that of mean ln(P/O) is below 0.
- **Launches exhausted (14) with fewer than 12 contributing:** the outcome is "insufficient".
  - v12 tested 6 to 11 instances here, and round 12 (finding 4) showed that branch unreachable: only Spot interruptions leave a launch uncounted without making the study invalid, and more than two of them already give "insufficient".
  - So 14 launches with at most two interrupted always yield 12 contributing instances.

**Precedence:** invalid, then stopped, then insufficient, then the decision. So identical evidence gives one verdict.

**Assumptions, stated in the claim.** The 5% error rate holds if four things are true. The first three cannot be checked with 12 instances. The fourth is bounded by the 50 ms lag ceiling, but its effect within that ceiling is not measured:
- the instance log-ratios are approximately normal;
- they are independent;
- **Spot interruptions are unrelated to how an instance would have performed** (round 11, finding 3);
- **load shifted by permitted lag does not change which premium requests meet contention enough to matter.** That is at most 50 ms for any request (see "What lag can do to other requests"). A request's own lag is in the decision's bounds; its effect on others is not, and is not measured.

Recording `StateReason` establishes an interruption's cause, not its independence. If the worst tenth of launches were the ones interrupted, round 11's simulation gives 15% false benefit at the null.

**Interruptions are therefore capped.** If more than two main launches are interrupted, the outcome is "insufficient", whatever the others show. So at most two launches' worth of selection can enter a verdict, and every verdict states how many launches were interrupted and when.
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

**The table describes an ideal process, not the registered one** (round 18, finding 5; round 19, finding 5).
- The table assumes complete, lag-free observation, with futility read on y itself.
- The registered procedure differs in two ways:
  - its decision reads the box, which moves y against P by uncertain values and dispatch lag;
  - its futility look reads y_lo.
- v19 said the registered procedure is never more powerful than the table. Round 19 built a sequence where the table stops for futility and the registered procedure continues and passes, so that claim is withdrawn.
- The registered procedure's power is **not established** by this page.
- **Round 18's example of how much it can lose:** 9 uncertain P values sitting just below the p99 rank, 0.077% of the arm and inside the cap, move y_hi from ln 0.8 to ln 10.

**The pilot screens the box's width on the primary itself** (round 19, finding 3). v19 screened only P/O's gap in stage A. Round 19 showed a case that passes that screen while the primary's upper end sits at 0, so benefit is impossible: arrival p99s of 16 and 20 ms against a uniform 4 ms lag.
- **The screen reads the width, not the ratio.** In stage B, for each of its two blocks, the half-width (y_hi − y_lo) / 2 of the P/S box is computed.
  - This reads how far the bounds spread around the ratio, not which arm is better. The rule that no pilot gate reads P against S's tail stands.
- If either block's half-width exceeds **0.043**, the design returns to review. That is half of 0.0859, which is half the distance from ln 0.8 to ln 0.95.
  - At that width, a true ratio of 0.80 leaves y_hi at most halfway to the threshold.
  - v19 called 0.05 "half the distance", which was wrong: half the distance is 0.0859 (round 19, finding 3).
- Stage A still publishes the uncertain fraction per arm and P/O's gap.

**This is the primary's power alone.** v8 prints no joint feasibility figure.
- The two whole-study gates, validity and premium loss, have survival probabilities nothing before the main study measures.
  - v7 multiplied a Gaussian survival table by a loss survival taken as 1.
  - Round 7 showed both factors could be far lower under assumptions consistent with every pilot rule (findings 2, 3 and 6). One example: 0.9¹² = 28% loss survival, if one instance in ten loses 2%.
- A product of assumed factors would be a number the evidence does not support.

## Money at risk, because survival cannot be known in advance

**Every whole-study gate is read after each main instance, and a failure stops further purchase.** So the money an invalid or stopped study costs is bounded by when it is discovered, whatever the survival probability. The gates are:
- validity;
- premium loss;
- the 50 ms lag ceiling;
- the record rules;
- an infinite end.

**The lag ceiling is the gate most likely to end the study, and the least predictable.** Its survival depends on a per-request reliability the pilots cannot measure (see Dispatch fidelity).

At the expected rate, the pilot costs $2.73 and each main instance about $1.88 (durations under Cost):

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
  - The expected spend is about $16.20: 2.7296 + 7.18 × 1.8766, as rounds 8 to 11 each re-derived.
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
- **P/O, on the final decision's own bound:** P/O's crossed upper end, ln(P's TTFT-scheduled p99, with uncertain values at +∞ / O's TTFT-arrival p99, with uncertain values at 0), is at most ln 0.85 on stage A's pooled blocks.
  - v20 screened the ordinary P/O ratio at 0.85 and dropped v19's gap screen. Round 20 (finding 2) showed a 4 ms lag in O that passes 0.85 while the crossed bound is +0.005, so the final P/O test could never pass, and all twelve instances would be bought.
  - This reads P against O, never against S.
- **release timing:** in P, at least 95% of admitted contenders have 50 ms or less between the gateway's release instant and the first content byte;
- **restart:** an engine restart between arms reuses host-path weights and takes under 3 minutes;
- **dispatch fidelity:** every arm within the lag limits;
- **capture:** it completes in every arm, with every terminal record after its window end.

The P/O screen reads P against O, never against S.

Then stage A fits R.

**Stage B: one instance, two full four-arm blocks** with R final. It establishes:
- every arm's loss under 0.5%;
- validity, with p_P − p_S, q_P − q_S and c_P − c_S each at least 0.03 in each of its two blocks;
- the live re-stamp equal to the frozen counts;
- the informative bound, mean p_P − p_S ≤ 0.10;
- the P/S box half-width at most 0.043 in each block (see Endpoints);
- no served request without a gateway record, and no request beyond the lag ceiling;
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
4. **Mandatory client-generated request IDs,** unique across the study, and **the gateway's per-request record** (arrival, tenant, tier, decision, release) keyed by them. The record is written durably at the arrival stamp, before admission.
   - The following refuse the run:
     - a gateway record with no client row;
     - a duplicate;
     - a served request with no record;
     - a scheduler record with no gateway record.
   - A failed request with neither record is a failure.
   - `sim-cap` replays the arrival instants.
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
   - **The sentinel proves a completed prefix, and v13 needs no more than that.** Rounds 11 and 12 showed that no quiet interval proves the engine has finished. A request whose client timed out can sit upstream of the scheduler and do work later, and vLLM's abort is an unacknowledged message (round 12, finding 2). v12 tried to fence that with a gateway scale-down and two snapshots; round 12 showed the fence was not one.
   - **v13 changes what p and q count instead** (see "The window" under the comparator): only steps that began before the arm's **window end**, the instant its last premium request finished.
     - Work the engine does after that instant cannot touch any premium TTFT in that arm, so it is irrelevant to what validity protects.
     - And a terminal record written after the replay returns, which is after the window end, proves every step before the window end was written.
   - **So capture is short:**
     1. The replay returns.
     2. Capture writes the sentinel and reads the terminal record, retrying for up to 60 s until the buffer is empty.
     3. It captures the step log, then the engine's iteration log.

     **The gateway is not scaled down,** so its records are not lost to a Pod deletion (round 12, finding 3). Its final records are exported with the arm's evidence before the namespace is deleted, and the export is checked against the sidecar's last upload.
   - Capture reads the file inside the running engine container and archives it before the namespace is deleted.
   - **The arm's step log is complete only if:**
     - the terminal record is present, with an empty buffer and the counter equal to the last written sequence number;
     - the sequence numbers run without a gap from 1 to the terminal's;
     - there is no overflow record;
     - the terminal record's wall time is after the window end;
     - **the plugin's steps match the engine's own iterations one to one, as far as the plugin's last step.**

   **The step match, made exact** (round 10, finding 1). The plugin numbers its steps from 1, incrementing before it records (`step_logging_scheduler.py:122`). vLLM numbers its iterations from 0, as the runner already checks (`m5c-matrix.sh:3004`). So the rule is:
     - plugin step k corresponds to `Iteration(k − 1)`;
     - the iteration log, captured after the step log, holds at least as many iterations as the plugin has steps. Any extra iterations are post-window work and are not compared;
     - each plugin step's total scheduled tokens equals its iteration's total, the per-step comparison the existing instrument checker already makes.

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
22. **The replay origin persisted, the gateway's arrival stamp after the body is read, and the dispatch-lag gate.** Tested by three rehearsals, each of which must make the outcome "invalid":
    - one whose replay loop sleeps before dispatch;
    - one whose `Send` sleeps 300 ms before its HTTP write;
    - one that holds every S request in a transport wrapper for 200 ms after `WroteRequest` and before the flush. That is round 13's case, which v13's stamp would not see.
24. **A terminal timestamp on every outcome.** Every row carries `EndUnixNanos`: the instant the sender returned, for timeouts, transport errors and non-200 responses too. Today those three return without one (`httpsender.go:346`, `:366`). The window end needs it (see the comparator), and a row without one refuses the run.
25. **TTFT-scheduled and TTFT-arrival, both ending at the gateway's first-content forward,** crossed in the bounds: y_hi is P-scheduled over S-arrival, and y_lo is P-arrival over S-scheduled. Any infinite end fails benefit. P/O has its own threshold, 0. Tested on:
    - round 18's 1.5 ms S-lag example, which must fail;
    - round 18's −∞ example, which must fail.
    - The gateway stamps the instant it forwards the first content frame, which needs it to recognise the first non-empty content delta in the stream.
    - TTFT-arrival is computed beside it, for the crossed bounds.
    - Uncertain requests (lag above 5 ms and at most 50 ms) are bounded over the corrected box, with P and S at opposite ends, under the 0.1% cap.
    - The infinite-end rules and the y_lo futility look apply.
    - Tested on round 17's 0.792 example, which must fail.
    - Tested on round 16's example, which must fail at its −2 vertex.
    - The client-stamp TTFT is published as well.
27. **One connection pool per block.** Today the pooled sender sizes its pool from each arm's own trace (`httpsender.go:100`, `:147`). I, with no contenders, would get about 278 connections against the others' 293 (round 18, finding 4). The pool is computed once from the block's full trace and passed to every arm, I included.
28. **The lag ceiling for every request:** at most 50 ms in the main study, 25 ms in stage A. A served request with no gateway record makes the outcome "invalid". Any infinite end stops further purchase. The P/S box half-width is screened in stage B.
26. **An arm-blind harness, checked on the resolved sending configuration,** with the manifest, raw output path and ID prefix normalised:
    - The harness writes its resolved sending configuration into each raw file: timeout, pool, concurrency, stream options and sender settings. The analysis refuses a block whose arms differ in any of them. The binary's hash must match across arms.
    - The ID prefix must differ per arm and per block, for study-wide uniqueness, and the analysis checks that it does.
    - A test asserts that no sending, waiting or stamping code reads the arm.
23. **The windowed p and q, and the short capture:** sentinel, terminal record, step log, then iteration log, with the gateway's final records exported before teardown.
20. **Rehearsals on kind with the stub engine:**
    - a whole replay-to-verdict run;
    - c_S > c_P on one instance;
    - a lost refusal;
    - an admitted contender failing after admission;
    - a request whose response never arrived, joined to the gateway's record by its client ID;
    - a request that never reached the gateway, which must count as a failure;
    - an S success whose gateway line is deleted, which must make the outcome "invalid";
    - round 20's two late S contenders with deleted gateway lines and lost responses, whose scheduler records must make the outcome "invalid";
    - round 20's 4 ms O lag, which stage A's crossed P/O screen must refuse;
    - one 60 ms request on the first main instance, which must stop further purchase;
    - round 19's two late contenders with deleted records, which must make the outcome "invalid";
    - a premium request delayed 60 ms, which must make the outcome "invalid";
    - an infinite end on the first main instance, which must stop further purchase;
    - round 15's three P premium requests delivered 900 ms late, which must leave their TTFT-scheduled including the wait;
    - round 15's four S responses read 900 ms late by the client, which must not change TTFT;
    - one arm run with a different timeout, which the analysis must refuse;
    - round 17's three delayed trace positions shared by both arms, which must be uncertain and must not produce a benefit;
    - round 17's 116 failures plus 11 uncertain values, which must make y_hi infinite and fail benefit;
    - an admitted contender failing after prefill in S, whose processed tokens must count in p_S;
    - a forwarded request refused by the engine's frontend before scheduling, which capture must not wait for;
    - a final batch held back from the writer when the sentinel arrives, which must make the terminal record report it and capture refuse after 60 s;
    - a request held upstream of the scheduler and released after the terminal record, whose work must fall outside the window and must not change p or q;
    - a step starting just before the window end, which must count;
    - a replay that falls 300 ms behind for 1% of an arm's requests, which must be "invalid" by p99.9;
    - one transport failure among an arm's requests, which must not be a lag violation;
    - a final premium request that times out before headers, whose end instant must extend the window;
    - three interrupted launches, which must give "insufficient";
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
- With main deadlines of 3 h 50, a session launched at hour t needs credentials until t + 4 h 20.
  - At the expected 2.75 hours each, sessions start at hours 0, 2.75 and 5.5, and the third needs credentials until 9 h 50, inside 12 hours. A fourth, at 8.25, would need 12 h 35, and is refused.
  - **Whether a third fits is decided at its launch by the remaining expiry, not planned in advance.** v12 said "at most two" by counting the headroom as time used (round 12, finding 5).
  - Twelve main instances need four to six logins, and the pilot one more.

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

**Session lengths.** v12's capture barrier added about 2 minutes per arm, and v13 removes it. Capture is now a sentinel, a terminal record and two file reads, as the earlier versions' per-block estimate assumed. Stage A measures the real capture time.

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

**The allowance, at the reserved lifetimes:** (2 × 185 + 14 × 245) min = 63.33 h, × $1.1324 = **$71.72**. The pilot alone is **$6.98**, superseded by the measurement pilot's three-block stage B: $8.12 allowance and $3.31 expected (see "The measurement pilot").

**This is an operational allowance, not an enforced ceiling.**
- It holds if, on every launch, at least one of the three terminators works within its time: the sweeper, the in-instance backstop, or the operator's hard stop.
- If all three fail on one instance, spending continues until a person notices.
- The account's AWS Budgets alerts (`infra/aws/bootstrap/budget.tf`) are the last line, and only if an address is subscribed. That file says an empty list means no alerts at all, and whether one is set is to be confirmed before the study.

**Small charges outside the allowance:**
- the sweeper's exercise, a few cents for a t3.nano;
- Lambda and EventBridge invocations, within the free tier at one per 5 minutes;
- S3 evidence storage.

**Expected,** at about $0.6824 per hour (Spot about $0.65, plus the volume and address):
- about **$25.25** for 12 instances;
- about **$13.99** if the futility look stops at 6;
- about **$2.73** for the pilot alone;
- plus about **$1.88** for each Spot replacement, which the expected figures exclude.

**The ledger reserves before it records.**
- Each launch first appends its reserved lifetime × $1.1324 as a reservation.
- It refuses if the reservations and recorded sessions together would exceed **$75**.
- The ledger limits what the study starts. It cannot stop an instance already running, which is the terminators' job.
- After the session it records launch and termination times from EC2 and CloudTrail.
- Billed amounts come from Cost Explorer when it settles, and are published beside the estimate.

## Open after round 21: not answered, awaiting the owner's direction

Round 21 found 2 blockers and 2 majors in v21. I checked each against the page and agree with all four. They are recorded here rather than answered with a v22, because what they show is a decision for the owner, not another rule.

| Finding | What it shows |
|---|---|
| 1 (blocker): the durable arrival write v21 added is an unbounded delay after the arrival stamp | a contender can arrive at 1 ms lag and enter admission 900 ms later; my own v21 fix created it |
| 2 (blocker): stage A's P/O screen reads y_hi only | a far y_lo in O makes U = +0.082 at a mixed vertex, so benefit is impossible while every purchase gate passes |
| 3 (major): stage B screens per-block box width, but the endpoint pools blocks | two blocks of zero width pool to a half-width of 2.41 against the 0.043 limit |
| 4 (major): the lag ceiling's survival cannot be established | 95% main-study survival needs an exceedance rate near 8.8 × 10⁻⁸. Showing that from zero events needs about 34 million requests, against the pilots' 68,565 |

**What 21 rounds have shown.** The study design settled early:
- arms;
- validity on processed and completed work;
- per-instance t with futility;
- sequential purchase.

Since round 12, every round has been about one question: what the decision may trust about request timing and observation.
- Each rule that closed a hole opened an edge in the next round: bounds, then crossed bounds, then a vertex rule, then ceilings, then screens.
- Several of those edges were in my own previous fix.
- Finding 4 is different in kind. As registered, the main study most likely cannot finish, whatever the pilot shows.

**The choice, set out for the owner:**
- **(a) Measure before designing further.** Stop adding rules. Buy only the pilot, about $2.73 expected and $6.98 at most, as a measurement of the harness and the apparatus rather than a gate:
  - the lag tail;
  - the uncertain fraction;
  - the pooled box widths;
  - P/O's crossed bounds.

  Then decide the timing rules from real numbers, and attack that design again before any main purchase.
- **(b) Keep iterating** with astra until a round finds no blocker, accepting that the timing rules may not converge.
- **(c) Shelve item 3,** recording what the 21 rounds established.

**The owner chose (a)** on 2026-10-08.

## The measurement pilot

**What it is for.** It measures the quantities the timing rules depend on, on the real apparatus, so the main study's rules can be set from numbers rather than argued against constructions.
- **It produces no verdict about P against S.**
- **It is not a gate the main study inherits.** Its numbers feed the next design round, which is attacked again before any main purchase.
- Its purchase needs the owner's approval once it is built, like any purchase.

**Sessions.** The two stages already designed:
- **stage A:** one instance, three blocks of I, O and P;
- **stage B:** one instance, **three** four-arm blocks, with R fitted on stage A.

**Stage B is bought only if R can be fitted and stage A left calibration possible** (pilot review 4, finding 2; pilot review 8, finding 3). Stage A ends in one of four ways:
- **R fitted, and every stage A arm eligible.** Stage B is bought, with the owner's approval of that session.
- **R fitted, but some stage A arm ineligible.** No stage B result can restore the formulas, since they need every arm of both stages. Stage B would buy descriptive measurements only, about $1.88 expected. That is a reduced deliverable and the owner's decision, not this branch's default. The default is "stage B not acquired".
- **No R satisfies the fitting rule on every trace.** The static bucket starts full, so a 30,000-unit burst admits at least three 10,000-unit contenders before its rate matters (`admission.go:236`). A P that admits few contenders can leave no positive R with S at least five points below it.
- **The fit is unidentifiable,** because a P contender has no gateway record.

In the last two cases the outcome is "stage B not acquired; R unavailable". Stage A's measurements are reported, and the design returns to review. No control is improvised after stage A.

Stage B has three blocks because the main endpoint pools three, and pooling is not linear in the number of blocks (pilot review 3, finding 3). Three blocks, each zero-width alone, can pool to a half-width of 2.30 where two of them pool to 0. Stage B is therefore the size of a main session: about 2.75 hours, under the main session's deadlines.

**Cost.** Both stages run as two sessions in one login, about 2.1 and 2.75 hours. Expected cost is about **$3.31**: 4.85 h at $0.6824.

**$8.12 is an operating allowance, not a maximum** (pilot review 2, finding 5). It is (185 + 245) min at the $1.1324 cap. It holds if, on each session, one of three terminators acts within the reserved lifetime:
- the sweeper;
- the in-instance backstop;
- the deadline-bounded hard stop.

An exercised sweeper shows it works, not how long it takes. If all three fail, spending continues at up to $1.1324 per hour until a person notices.

**What it measures, per arm and per block, and pooled over each stage's blocks as the main endpoint pools:**

| Quantity | Why the main design needs it |
|---|---|
| Dispatch lag (gateway arrival minus scheduled instant): full distribution, maximum, and count above 5, 25 and 50 ms | the ceiling and uncertainty rules, and round 21's finding 4 |
| Gateway-internal delays: arrival → durable record written → admission decision → proxy handoff → first content **flushed** to the client | round 21's finding 1: what happens after the arrival stamp, including the durable write. "Proxy handoff" is when the request enters the reverse proxy; connection setup and transmission to the engine come after it (pilot review 10, finding 4). First content is stamped at the flush that sends it, not at the write into the server's buffer (pilot review 10, finding 1) |
| Client-side stamps beside the gateway's: send and first content | how far each client stamp sits from the gateway's |
| Missing gateway records; scheduler records with no gateway record | the record rules |
| Each arm's premium p99 on TTFT-scheduled and TTFT-arrival, with the uncertain set at 0 and at +∞, pooled; and each arm's **box width** ln(hi/lo) | round 21's findings 2 and 3, and pilot review 2's finding 1. The pooled P/S width is the sum of the two arms' widths, so pooling is measured, not inferred from blocks |
| O/I contention, P/O on the crossed bounds | the contention and P/O screens |
| Contender p, q and c per arm; sim-cap's predicted admission against the observed (stage B) | the margin and the R fit |
| Release-to-first-content gap per contender; restart and capture times; step-log completeness checks | operational premises |
| The evidence sidecar's uploads as intervals (start, end, retries, bytes), and the dispatch lag of every request whose **scheduled instant, or whose scheduled-to-arrival interval,** overlaps an upload | pilot review, findings 3 and 6, and review 3, finding 4. Classifying by actual dispatch would drop exactly the requests an upload held back past its end |

**v1 of this scope dropped the client's "written" stamp** (pilot review, finding 4). Nothing implements it, and the decision no longer uses it.

**Stage B is not blind, and the page says so instead of sealing.** v2 of this scope sealed stage B's premium-tail quantities. Pilot review 2 (findings 1 and 2) showed that cannot work:
- The raw rows and the gateway's records are uploaded and downloaded whole (`m5c-gpu-session.sh:1040`, `:1103`, `:1539`).
- The published delay chain sums back to TTFT.
- Sealing withheld the pooled widths the next design round needs.

Blindness was meant to prevent one harm: a designer who has seen the P/S effect tuning the main study to favour it. v3 meets that harm directly.

**Frozen now, before the pilot, and not open to change by anything stage B shows:**
- the primary threshold, ln 0.95;
- the endpoint definitions;
- the arms and their configurations, except R;
- the load;
- the number of instances and blocks;
- the futility look;
- the decision procedure.

**What the next design round may change, and how: by formulas fixed now.** v2 of this scope allowed measurement rules to change "justified by a named measurement". Pilot review 3 (finding 2) showed that still permits tuning after seeing the effect: moving L from 5 to 15 ms alone moved a decisive bound from 0 to −0.22. So each rule is set now, by a formula that reads only harness-side timing, never a TTFT:
- **L** (the trusted lag limit) = max(5 ms, 2 × the largest per-arm pooled p99.9 dispatch lag over both stages), rounded up to whole milliseconds;
- **the lag ceiling** = max(50 ms, 2 × the largest dispatch lag observed in either stage);
- **the uncertainty cap** stays 0.1%. If any arm's uncertain fraction at the new L exceeds 0.05% in the pilot, the design returns to review instead;
- **the width screen** stays at a half-width of 0.043, fixed;
- **durations and deadlines,** from `cell-timings.tsv` (`m5c-matrix.sh:2281`) and the phase stamps below:
  - **arm time** = the largest **complete** cell time of any arm in either stage: its preliminary `elapsed_s` plus its upload hook's duration from `cell-uploads.tsv`. The preliminary row alone excludes the upload, so the formula would fall short by up to the hook's 120 s per cell (pilot review 10, finding 3);
  - **bring-up** = the larger of the two stages' times from the instance's EC2 `LaunchTime` to the first cell's start;
  - **session tail** = the larger of the two stages' times from the matrix's return to the `DONE` marker's upload: the archive, the node evidence and the marker (`m5c-gpu-session.sh:1098` to `:1114`). Measured, not left to the margin (pilot review 9, finding 3);
  - **main session length** = (bring-up + 12 × arm time + session tail) × 1.25;
  - **hard stop** = the main session length;
  - **acquisition deadline** = hard stop − 6 min;
  - **backstop** = hard stop + 10 min;
  - **`study-deadline`** = hard stop + 20 min, with the reserved lifetime at deadline + 15 min, as now.

  Maximum, not mean, so that a repeat of the slowest arm fits (pilot review 6, finding 3).
  - **Sessions per login are planned conservatively; each launch decides** (pilot review 7, finding 4; pilot review 8, finding 4). A session ends when its marker arrives, usually well before its hard stop H. The k-th session in a login needs credentials until its start + H + 50 min.
  - **For planning,** the next design allocates k sessions to a login only while k × H + 50 min ≤ 12 h. That assumes each session runs to its hard stop. It is an allocation, not a count of what fits: shorter sessions may let more fit, and gaps between sessions let fewer.
  - **The binding rule is the launch-time check** of the remaining expiry.

**The formulas run only on timing evidence that is complete, unambiguous and witnessed.** v4 and v5 of this scope listed the cases that make evidence unusable, and each review found one more:
- a served request without a record (pilot review 4, finding 1);
- a refused request without one (pilot review 5, finding 1);
- an incomplete step log hiding the witnesses (review 5, finding 2);
- duplicate IDs (review 5, finding 3).

v6 states the condition positively instead. **An arm's timing evidence is eligible only if all of these hold:**
1. **Every client row has exactly one gateway record, and every gateway record exactly one client row,** joined by an ID that occurs once.
   - **A gateway record is one request's `arrive` line and `done` line, joined by ID.** A `done` with no `arrive`, or an `arrive` with no `done`, is an incomplete record.
   - **And the record must carry every stamp its use needs** (pilot review 10, finding 2): an arrival stamp for every request, and a flushed first-content stamp for every premium success.
   - A request refused before its body was read has a `done` line and no arrival. That happens to authentication, policy and rate-limit refusals, which come before the body (`server.go:356` to `:401`). Its lag is unknown, so the arm is ineligible.
   - The pilot's tenants are configured so that none of those refusals should occur. The report counts them if they do.
2. **There is no exception for a request with no gateway record.** v6 excused one that failed before any response and had no scheduler record. Pilot review 6 (finding 1) showed a request can be admitted, stall before the scheduler, time out, and lose its record, and the exception would accept it. The durable write is intended, not proof that an absent record never existed.
3. **The arm's step log is complete** by the counts under build item 6, and **its coverage reaches past the window end, proved by an acknowledged fence** (pilot review 9, finding 1).
   - **Three earlier versions tried passive signals, and each failed:**
     - v7: the terminal record's time (pilot review 7, finding 1);
     - v8: 3 s of padding on the iteration log's timestamps, which are stamped when a step **ends** (pilot review 8, finding 1);
     - v9: a quiet barrier of 3 s without an iteration line plus idle metrics. One step can run 40 s without a line, and vLLM's running/waiting gauges are snapshots published from completed outputs, not an acknowledgement (pilot review 9, finding 1).
   - **The fence.** After the replay returns, so after the window end, capture sends one request with the ID `fence-<cell>` directly to the engine's port: a one-token prompt and a one-token cap.
     - Synchronous scheduling runs one step at a time. So when the fence's response completes, every step that started before the window end has already executed, and its iteration line has already been logged.
     - The fence's completion is acknowledged to the capture client by the engine itself, not by the plugin.
   - **The check, after the fence completes:** capture writes the sentinel, reads the terminal record, then captures the step log and the iteration log.
     - The arm is eligible only if the plugin's log contains the fence's `add` and `sched` records.
     - Let k_f be the plugin step of the fence's last `sched` record. The iteration log must hold at least k_f iterations, and plugin steps 1 to k_f must match iterations 0 to k_f − 1 one to one, in token totals.
     - A plugin that stopped recording before the fence lacks the fence's records. A plugin that skipped a step misaligns the token totals from that step on.
   - **The fence is outside every measurement.** Its ID prefix is excluded from p, q, c and the join, like `calib-`. A `fence-` record elsewhere refuses the run.
   - **The whole barrier is bounded** (pilot review 9, finding 4). Fence, sentinel, terminal record and both captures together must finish within 5 minutes of the replay's return. Otherwise the arm is marked ineligible, and the next arm starts on its fresh engine as usual.
   - Build item 6's rule for the main study changes the same way. Without it, a plugin that stopped after step 70 while the engine ran 100 more steps inside the window would hide about 51,200 prefill tokens, 3.2 points of p.

4. **The arm's timing is complete, in two records** (pilot review 8, finding 2; pilot review 9, finding 2). A row written before the upload hook cannot contain the upload's end, so the timing is split:
   - **`cell-timings.tsv`,** written before the hook, with every phase stamp up to the hook's start;
   - **`cell-uploads.tsv`,** appended after the hook with that hook's start and end. It is carried by the **next** cell's upload. The last cell's line goes with the session's final archive, and if that archive is lost the last line is missing.
   - A cell's complete time is its preliminary `elapsed_s` plus its upload's duration.
   - Calibration needs both records for every cell. A missing one makes the duration formula's output unavailable, as with any ineligible evidence.

   Today the row is written after the hook (`m5c-matrix.sh:3387`, `:3397`), so the last cell's duration survives only if the whole-session archive does.

The formulas read only eligible arms, and **they need every arm of both stages to be eligible.** Otherwise their outputs are **unavailable**, and the design returns to review.
- Thirteen 900 ms requests without records among 12,285 turn a true ceiling of 1,800 ms into 50 ms.
- Two records sharing an ID can give a ceiling of 2,002 or 3,800 ms depending on which is which.

Neither may calibrate anything.

**Acquisition still continues through ineligible arms,** and every measurement is reported. Each is marked eligible or not, and with the records it lacks. The priority check on an arm whose step log is incomplete is reported as **unknown, not passed**. That arm cannot show it ran the registered apparatus.

**Any change outside these formulas is a new design.** It is registered, attacked again, and states in its own page that its author had seen stage B.

**The execution contract: in the pilot, no gate stops acquisition except those that make its measurements meaningless** (pilot review 3, finding 1). The build items it reuses (4, 22, 25) carry the main study's gates, which turn violations into "invalid". In the pilot those gates are **evaluated and reported, never acted on**: each is reported as "would have fired" or "would not".

**What does stop the pilot** is anything that makes the apparatus different from the one registered:
- the engine-arguments validator;
- the image digest;
- a missing exact-token stamp;
- a premium request reaching the scheduler at any priority but 0, **or a standard request at any priority but 1**. An omitted priority defaults to 0 for both tiers (`priority.go:30`), so a missing binding passes a premium-only check (pilot review 4, finding 3);
- a sender configuration that differs between a block's arms (item 26);
- the credential check;
- the deadline.

A step log that fails its completeness check does not stop the next arm. It makes that arm ineligible for calibration as a whole, not only its processed-work figures, because the log is also the priority witness and the engine-reach witness (pilot review 5, finding 2).

**Separation:**
- Stage B's data never enter the main analysis.
- The published stage B report prints widths and S's and P's own work and timing quantities, not a P/S ratio. The raw evidence is not concealed.

**What must be built for the pilot.** A subset of the build list:
- items 1, 2, 3, 4, 5, 6, 7, **8**, 10, 11, 12, 13, 14, **16**, 18, 21, 22, 24, 25, **26** and 27. Item 26 records and compares the resolved sender configuration, including connection mode. Without it, an arm-dependent sender difference would pass into the lag distribution and from there into the formulas (pilot review 4, finding 5);
- the gateway's own delay stamps, including the durable write;
- a measurement report, in place of item 15's decision machinery;
- **a hard stop that is a deadline, not a count** (pilot review, finding 2; review 2, finding 4):
  - every AWS call in the wait is run under `timeout` with the time remaining;
  - the loop checks a wall-clock deadline, not a count of attempts;
  - **two deadlines, not one** (pilot review 4, finding 4):
    - the **acquisition deadline** is the hard stop minus a 6-minute termination reserve;
    - the termination call runs under its own fixed 5-minute `timeout`, the same reserve the existing helper uses (`spot-run.sh:195`).

    A timeout "equal to the time remaining" is zero at the deadline, and GNU `timeout` treats 0 as no limit at all.
  - **on reaching the acquisition deadline, the runner terminates the instance first,** and only then downloads evidence;
  - **the acquisition deadline stays active after the marker arrives** (pilot review 3, finding 5):
    - the marker download runs under `timeout` with the acquisition time remaining, at least 1 s;
    - the instance is terminated before any evidence download, whether the marker came or not.

    Before 9496808 a marker arriving just before the deadline led to downloads before cleanup's termination, and the termination call had no outer timeout (`spot-run.sh:203`). Both are fixed for the pilot; see "Build status" below.

  `spot_wait_for_marker` counts attempts at 30 s plus two API calls each (`spot-run.sh:374`), so a 150-minute setting can run to about 250 minutes. The pilot uses `spot_wait_for_marker_until` instead, which reads the wall clock.
- **the fence before the sentinel,** sent directly to the engine with a `fence-` ID, and the 5-minute bound on the whole barrier;
- **the two timing records,** preliminary before the hook and upload after it, and a stamp for the session tail;
- **phase timestamps per cell** (pilot review 7, finding 2): deploy start, engine ready, replay start and end, sentinel, terminal record, capture end, and upload start and end, each in UTC.
  - `cell-timings.tsv` has only a cell's start, end and total, and the runner's messages carry no timestamps (`m5c-matrix.sh:161`). So 180 s of restart and 0 s of capture cannot be told from 120 s and 60 s. The pilot writes `phases.tsv` for this.
- **the instance's EC2 `LaunchTime`,** read by the runner after launch and written with the session's evidence, for the bring-up formula. It is not left to the deferred ledger.
- **synthetic step-log support in the stub engine** (review 2, finding 3). For each request it emits plugin-format `add` and `sched` records with request IDs, anchors and sequence numbers, and on the sentinel a terminal record. So the kind rehearsal exercises items 6 and 21 rather than refusing or bypassing them. The CPU run with real vLLM remains the check on vLLM's own behaviour.

**Brought into the pilot after its review:**
- **item 8,** incremental rows and the evidence sidecar. They are part of the apparatus whose timing the pilot measures, not only a backup (pilot review, finding 3).
- **item 16,** the sweeper. It needs the owner's approval of its `terraform apply` as its own step, and its exercise must pass before the pilot is launched (pilot review, finding 2).

**Still deferred to the main study:**
- **item 9,** the interruption recorder. A Spot interruption costs the pilot's evidence, and nothing else.
- **item 17,** the ledger. The pilot is two sessions under the sweeper's deadlines.
- **item 19,** TPOT.

**Rehearsals before purchase:**
- **on kind with the stub engine,** a full stage A and stage B end to end through the measurement report. The stub is extended to honour each request's own output cap and to emit the synthetic step log. Its iteration lines gain vLLM's timestamp format; today they print `INFO stub` with no time (`helpers.go:354`). The rehearsal must show:
- **eligible arms,** not merely a report;
- one arm made ineligible by a stopped step log;
- one arm made ineligible by a deleted gateway record.
- **on CPU with real vLLM,** through `hack/vllm-plugins/validate-on-cpu.sh` extended to run the new path on a short trace. The stub has no scheduler (`cmd/benchharness/helpers.go:339`), so it cannot exercise the scheduler-side path (pilot review, finding 5). The CPU run must show:
  - the plugin's sequence numbers, sentinel and terminal record;
  - the request-ID join from client to vLLM's scheduler;
  - the scheduler-side priority;
  - the prefill and decode split.

### Build status, 2026-10-08

**Built, tested, and rehearsed on kind.** The kind rehearsal (`PILOT=1 hack/test/rehearse-m5c-matrix.sh`) ran both stages end to end at 31ea216: 21 cells, every one captured, fenced, calibrated and timed, with the matrix's file accounting exact (120 of 120 and 156 of 156).
- The four review-11 fixes: first content is stamped only for a complete SSE event; the capture bound runs from the replay's return and bounds every call; the engine validator takes the model and revision from the registration and requires the model keys; the 15-minute forecast stop is gone.
- `benchharness fit-pilot-rate` fits R by "Fitting R" above. It replays each P block's contenders at their gateway-recorded arrival instants through the gateway's own static-cap admitter, at threshold 1 and burst 30,000. It tries every R from 1 to 20,000, because admitted work need not be monotone in R. It refuses an incomplete join as "unidentifiable" and reports "R unavailable" when no R holds on all three blocks. The rehearsal now fits R on stage A and runs stage B at it.
- `hack/prospective-pilot/pilot_report.py` reports each arm's box as ln(sched_hi / arr_lo), the arm's contribution to y_hi − y_lo. Before 9b10925 it summed P's scheduled width and S's arrival width instead, which reads zero when trusted lag is non-zero. It now also pools lag per arm before taking p99.9, requires all registered cells of both stages, and requires the engine log, the fence's add record, a return stamp on every premium row and a flush stamp on every premium success.
- The duration formulas are computed: arm time from both timing records, bring-up from the instance's `LaunchTime` to the first cell's start, the session tail from the matrix's return to the marker's upload, and from them the session length and its four deadlines. A missing record makes the output unavailable.
- The session runner carries the stage, the rates and the stage's arms to the instance. It holds the registered limits (stage A 2 h 30 / 2 h 40, stage B 3 h 30 / 3 h 40) and refuses a caller's. It waits on a wall-clock acquisition deadline, terminates under a fixed 5 minutes before any download, and records the three session stamps.
- The instance's matrix stops at an absolute deadline the wrapper sets: the acquisition deadline less a 10-minute tail reserve. Counted from the instance's boot, as other studies still do, it would run about the bring-up's 25 minutes past the wrapper's termination. The 10 minutes were a reserve until stage A measured the tail; it measured 12 s in both stages, and the reserve is now 2 minutes.

**q's ceiling is 15/16, not 1.** A 16-token output takes one prefill step, which samples the first token, and 15 decode steps; the registered CPU fixture says the same (80 prefill and 7 decode tokens for 8 outputs). The margins compare differences, so this changes no rule, but a reader of q = 0.9375 should not read lost work.

**Measured on kind, not on the card.** Dispatch lag p50 is about 0.9 ms, but p99.9 is about 102 ms in every arm. That is the client's port-forward, so on kind every width is infinite at L = 5 ms. The card's lag is what stage A measures.

**Built later the same day:**
- Item 16: `infra/aws/bootstrap/sweeper.tf` and `sweeper/sweeper.py`, which terminates any live instance whose `study-deadline` tag has passed, or cannot be read as a zoned time. The pilot's launch carries the tag at hard stop + 20 min. `hack/sweeper-exercise.sh` is the exercise. Validated with `terraform validate`; not applied and not exercised.
- Item 8: the harness appends each row durably to `live-raw-<cell>.jsonl` as its request ends. During each replay a sidecar hands those rows and a fresh gateway record to S3 every 30 s, and at once on a Spot notice polled from the metadata service. Each upload is logged in `sidecar-uploads.tsv`, and the report gives the lag of requests that met an upload apart. Reconstruction against the block plan is not built; a pilot cell cut short is ineligible anyway.
- Item 13: for the pilot, the credential check refuses an expiry it cannot establish, an active role sts cannot name, and a cache entry naming only an account.
- The rehearsal's two injected ineligible arms: stage A's `off-2` with its step log stopped mid-cell by the stub, and stage B's `R1-3` with one request's gateway record deleted. The report must mark exactly those two ineligible, for those reasons.
- The CPU run with real vLLM v0.27.1 (`hack/vllm-plugins/validate-pilot-on-cpu.sh`) passed: terminal record, ID join, scheduler-side priority, alignment through the fence, and every request's prefill equal to its prompt and its decode to its output less one, including 1,230-token prompts chunked under the 512 budget. Evidence: `data/2026-10-08-pilot-cpu-validation/`.

**The pilot's seeds, frozen before its first purchase:** stage A's blocks 1 to 3 replay seeds 801, 802 and 803; stage B's, 811, 812 and 813. They are distinct from the kind rehearsal's (301 to 313) and the matrix default (11), and the main study's list must not reuse them.

**Still before purchase, each the owner's step:** an SSO login to gpu-lab; `terraform apply` of the bootstrap stack there; the sweeper exercise passing.

### Pilot results, 2026-10-09

Both stages were bought in gpu-lab on one g5.2xlarge Spot each: stage A `i-0ad29d4db683ecf44` (launch 23:51:06Z, marker 01:24:15Z), stage B `i-052798b9bc6192973` (launch 01:37:15Z, marker 03:39:36Z), both terminated before download. Reports, timings and calibration are in `data/2026-10-09-pilot-results/`, scored by `pilot_report.py` at the commit named there. The sweeper exercise passed first: a t3.nano terminated 178 s after its deadline.

**Every cell of both stages is eligible: 9 and 12.** The engine counted the frozen 68 and 7,695 tokens in both. R was fitted on stage A at 5,318.

| | Stage A | Stage B |
|---|---|---|
| Premium p99 TTFT, scheduled, R1 | 63 ms | 63 ms |
| off / prospective / static-cap | 1,498 / 1,479 / — ms | 1,510 / 1,488 / 1,451 ms |
| Box width per arm | 0.024, 0.007, 0.006 | 0.024, 0.002, 0.005, 0.007 |
| Pooled P/S half-width | — | 0.0056 |
| Contender p: off / P / S | 1.00 / 0.92–0.94 / — | 0.99–1.00 / 0.87–0.94 / 0.79–0.86 |

**The frozen formulas' outputs:** L = 13 ms, lag ceiling 409 ms, arm time 920 s (the cold first cell), bring-up 200 s, session tail 12 s, main session length and hard stop 14,065 s (3 h 54), acquisition deadline 13,705 s, backstop 14,665 s, `study-deadline` 15,265 s.

**The gates, evaluated and not acted on, as the execution contract says.** The first version of this list gave four and left out the P/O screen, which fires; astra's review of v22 (finding 3) found the omission. Every registered gate is now computed by `pilot_report.py gates` and archived as `data/2026-10-09-pilot-results/gates.json`. Uncertainty is counted as premium requests with lag above L over the arm's premium requests, pooled over the stage's blocks (v22 review, finding 4).

| Gate | Value | Rule | Fires |
|---|---:|---|---|
| A contention, O/I premium p99 | 23.6 | ≥ 1.5 | no |
| A loss, every arm's premium | 0 of 11,645 | < 0.5% | no |
| A loss, O's contender completion | 615 of 615 | ≥ 95% | no |
| A engagement, P's contender refusals | 6.5% (575 of 615 admitted) | 5% to 30% | no |
| **A P/O, crossed upper end** | **−0.0054** | **≤ ln 0.85 = −0.1625** | **yes** |
| A release timing, P within 50 ms | 100% of 575 | ≥ 95% | no |
| A restart under 3 minutes | not measured | < 180 s | — |
| **A dispatch fidelity, largest lag** | **104.5 ms** | **≤ 25 ms** | **yes** |
| **A uncertain at L = 5 ms**: R1, off, P | **8, 19, 14 of 11,645** | ≤ 0.05% | **yes** |
| **A uncertain at L = 13 ms**: R1, off, P | **7, 6, 6 of 11,645** | ≤ 0.05% | **yes** |
| A capture, every cell eligible | 9 of 9 | all | no |
| B loss, every arm's premium | 0 of 11,728 | < 0.5% | no |
| B width, per block | 0.0036, 0.0050, 0.0053 | ≤ 0.043 | no |
| B margin p, q, c (smallest block) | 0.068, 0.063, 0.068 | ≥ 0.03 | no |
| B informative bound | 0.074 | ≤ 0.10 | no |
| B re-stamp | 68 and 7,695 | equal | no |

**The P/O screen is the one the fix does not touch.** P's premium p99 is 0.995 of O's: under this load, prospective admission refused 6.5% of contender requests and left the premium tail where it was. The 100 ms stalls were the first one or two requests of each cell and cannot move a p99 of 1.5 s. This screen exists to stop the main purchase in exactly this case.

**What the cap is made of.** Every premium lag above 13 ms is near a multiple of 100 ms: 102.8 to 104.5 ms in stage A, and 103 to 104 or 204 ms in stage B. There are one or two per cell, in every arm, including R1, which has no contender. The kind rehearsal showed the same 102 ms. So it is a property of the apparatus, not of contention.

**The cause, found 2026-10-09: the gateway reported ready before it had cached what its requests read.** It is not the port-forward, which this page first suspected.
- All 35 are the first one or two requests of a cell. Their delay lies between the gateway's handler entry and its arrival stamp, 100.2 to 202.1 ms, while send to entry is 2.0 to 2.4 ms (astra's decomposition of the archives, re-checked: send minus scheduled is 0.1 to 1.1 ms for every one).
- The gateway's cache registered only the InferenceDeployment informer before start. Secret and GPUQuotaPolicy, both read before the arrival stamp, started on the first request, and each first read waited for its informer to sync, which client-go polls every 100 ms. Readiness waited only for the informers that existed, so the matrix's probe passed with neither cached.
- A fresh port-forward's first requests took 2 to 9 ms in a local test, so the tunnel does not produce it.
- Fixed in ab7f0f5: both informers are registered before start, so readiness waits for them. An envtest test fails on the old code for exactly those two kinds. The kind rehearsal at that commit has no lag above 2.5 ms in any of its 21 cells, where every cell before had about 102 ms.
- This is a gateway defect, not only a measurement one: every rollout's first requests waited the same way.

**What it did to the formulas.** The stalls set the ceiling (409 ms), and they shift the rank of p99.9, so they also moved L. As a diagnostic only, without them L would be 11 ms and the ceiling 50 ms. Deleting rows is not a corrected pilot.

**Not judged here.** P's tail beside S's is printed in the table because the report prints each arm's own quantities; the pilot reaches no verdict about P against S.

### v22 proposal, and astra's attack on it

The pilot's gates fired, so by its own rule the design returned here. A v22 was written (4325bcc) by an author who had seen stage B, and astra attacked it: two blockers, two majors and two minors, verdict "reject v22 as written". I checked each and agree with all six. The attack is archived as `data/2026-10-09-pilot-results/astra-v22-attack.md`.

| v22 item, or finding | Outcome |
|---|---|
| The gateway fix (ab7f0f5) | Kept as apparatus. The gateway now also refuses a read of any kind not registered before start (80d15ea), and its test reads through the client, because asking for an informer would create a missing one and race it (finding 6). |
| Premium-only lag for L, the ceiling and the cap (finding 1, blocker) | **Withdrawn.** The ceiling is for every request because a late contender moves what other requests meet; a premium-only ceiling would drop that protection. L, the ceiling and the cap keep the all-request population; premium lag is reported beside them. |
| The durable arrival write leaves post-arrival delay unbounded (finding 2, blocker) | Not new: it is round 21's open blocker 1. The gateway fix does not close it, and a main study needs a rule for it. |
| The P/O screen was left out of the results (finding 3, major) | Corrected above. It fires, and it is the gate the fix does not touch. |
| The cap was not computed at the calibrated L (finding 4, major) | `pilot_report.py gates` now computes every gate at L = 5 ms and at the formula's L, with the population written down. |
| `phases.tsv` was said to record deployment-to-readiness (finding 5, minor) | It does not: its first pilot stamp is `replay-start`. The restart gate is reported as not measured. |
| Pilot 2, both stages, on new seeds | **Not bought.** Astra's point stands: the P/O screen fired for a reason the fix does not address, so a second full pilot would buy the same answer to the question that matters. |

**Where the premium tail's 1.5 s goes** (2026-10-09; my reading of the step logs and astra's, done independently and in agreement; astra's is archived as `data/2026-10-09-pilot-results/astra-po-investigation.md`):
- In every contended arm, a request above the p99 spends about 1.35 s between the scheduler's `add` and its first scheduled step, and its own prefill step takes about 80 ms. The gateway, the durable write and delivery together take under 20 ms.
- That wait is one contender's prefill. Its 7,695 tokens run in 512-token chunks over 16 to 18 steps of about 80 ms. Every one of the 517 tail requests met exactly one contender in prefill; 505 waited through nothing else. In `pp-A-off-3-750`'s 16 blocked steps, 7,463 tokens went to that prefill and none to the new premium request, and no other premium prefill started either.
- The cause is the scheduler's order, as vLLM v0.27.1 implements it: running requests are scheduled first, and waiting requests only take what budget is left. Priority orders the waiting queue; it does not let a new premium request displace a running prefill at the next chunk boundary. No preemption occurred in any cell.
- A second, smaller tail is sequence capacity: with all 64 slots occupied, mostly by running premium decodes, new requests wait without any contender prefill.

**What this does to the premise.**
- The design assumed the 512-token budget bounds a premium request's wait to about one step. It bounds the step's work, not the wait.
- Prospective admission as built counts outstanding input and streams. It admits premium unconditionally and never looks at the premium queue or at a prefill's progress, so three outstanding contender prefills are allowed, and one is enough to produce the tail.
- What admission can still reach: it decides whether the blocking state forms. In off, premium requests that entered with exactly one contender in the engine had a p99 about 16 to 19% below off's; that is a selected observation, not a policy's measured effect. Refusing every contender approaches R1's 63 ms but is not a work-preserving policy.
- Repeating the pilot would not answer this, so pilot 2 stays unbought.

**The scheduler replay, first of the free experiments (2026-10-09; the owner chose to redesign the admission rule).** `hack/prospective-pilot/simulate.py` models the scheduler as the step logs show it, running requests first and then waiting ones by priority, with a 512-token budget and 64 slots, and a step time fitted on 282,897 archived steps. It reproduces every archived arm's premium p99 to within −6% to +6% (R1 +2 to +6%; contended arms −6% to 0%, a little low). It then replays each off cell's arrivals under candidate gateway rules that use only what a gateway can see, whether a contender's first token has come back:

| Rule, on the six off cells | Premium p99, simulated, against off's | Contenders completed | Contender held at the gateway |
|---|---|---|---|
| hold a contender while another's prefill runs | 0.99 | all | median 0.4 to 2.9 s, up to 18 s |
| hold while a prefill runs or a premium request waits | 0.95 | all | up to 20 s |
| at most one contender outstanding, holding the rest | 0.88 to 0.90 | all but 8 of 239 in one cell | median 2.7 to 8.1 s, up to 30 s |
| refuse a contender while another's prefill runs | 0.84 to 0.88 | 61 to 69% | — |

**No rule reaches 0.85 and keeps the contender's work, and the one that comes near refuses 31 to 39%, outside the 5 to 30% the design allows.** The floor is one prefill's duration, about 1.2 to 1.3 s: while more than 1% of premium requests arrive during some contender's prefill, the p99 is that prefill. Serialising prefills removes only the overlap of two. These are screening results from a model, not measurements.

**v23: the engine's prefill cap together with a one-prefill gateway rule, a feasibility candidate** (2026-10-09). astra attacked the first version of this section; verdict "reject v23 as a work-preserving conclusion; retain it as a feasibility candidate". I checked the seven findings and agree with all of them; the attack is archived as `data/2026-10-09-pilot-results/astra-v23-attack.md`, and this section is the corrected one.
- vLLM v0.27.1's V1 scheduler has `long_prefill_token_threshold`: when positive, no prefill takes more than that many tokens in a step, running or new (`v1/core/sched/scheduler.py:521` and `:899` in the image). Under a 512 budget it leaves room beside a running prefill, **but not always**: with all 64 slots taken there is no room at all, and with 61 premium decodes beside a 384-token chunk only 67 tokens remain, one short of a premium prompt (finding 3). The archives hold 1,836 steps that scheduled 64 requests.
- **On the real engine (CPU, free), what was shown and what was not.** With no threshold, premium requests that arrived during a 3,030-token prefill were not allocated until its last chunk. With 256, each was allocated beside the running chunk. That is first allocation, not prompt completion: some got part of their prompt and finished it a step later, and one spent 992 ms before the scheduler's add at all (finding 5). The run used 16 slots and 4-token outputs, so it says nothing about the 64-slot regime. `hack/vllm-plugins/prefill-block-on-cpu.sh`; evidence in `data/2026-10-09-prefill-block-cpu/`.
- **The threshold alone makes the tail worse in the replay**, 1.15 to 1.74 times off's p99: slower prefills overlap more, and two contenders in prefill take the whole budget between them. It works only with at most one contender in prefill, which is a gateway rule.
- **In the replay**, corrected after both reviews: timeouts cancel in the engine, decode adds context, a request in flight cannot block a ready one, the gateway sees a token only once delivered, decisions see every delivered notice, and a held contender is forwarded when its condition clears rather than at a step boundary. At the fitted step times and with every step 10% slower, on the six off cells (`data/2026-10-09-pilot-results/simulate-combine.txt`):

| Engine threshold + gateway rule | Premium p99 against off's, fitted / 10% slower | Contenders completed, fitted / 10% slower | Contender completion p50 (off: 3.0 to 6.1 s) | Longest hold |
|---|---|---|---|---|
| 384 + hold while another contender is in prefill | 0.27 to 0.36 / 0.33 to 0.44 | all / all but 24 of 239 in one cell, where off itself loses 13 | 3.7 to 6.8 s | 24 s |
| 256 + hold while another contender is in prefill | 0.10 to 0.11 / 0.10 to 0.12 | all but 25 of 239 in one cell / 8 to 79 lost per cell | 6.2 to 16.9 s | 30 s |
| 256 + refuse while another contender is in prefill | 0.10 | 49 to 59% (the rest refused) | — | — |

- **Why this is a candidate and not a conclusion** (finding 1). The capped regime, interior chunks of 384 or fewer tokens beside one long prefill, never occurs in the archives (none of 44,221 interior chunks), so its step times are extrapolated; and contender completion turns on them, as the 10% column shows. The premium tail is robust to that; the contender's cost is not.
- **The cost is not only time held at the gateway** (finding 4): a 7,695-token prompt needs at least 21 steps at 384 and 31 at 256 instead of 16, each with its overhead, and the contender's prefill stays resident longer.
- **The rule's guarantee holds only without preemption** (finding 6): a preempted contender recomputes its prompt after its first token, when the gateway already counts it as done. No preemption occurred in any pilot cell, and the KV cache had about 387,000 tokens against peaks near 19,000 in the replay; the guarantee is stated with that condition, and a GPU session must measure it.

**The CPU experiment, redone to prompt completion and first content** (2026-10-09; 64 slots, warmed, 64-token premium outputs, `data/2026-10-09-prefill-block-cpu/`, step logs gzipped). Premium requests that arrived during a 3,030-token prefill:

| Regime | Threshold | Steps from the scheduler's add to prompt completion, median / max | Client send to first content, median / max |
|---|---|---|---|
| light | 0 | 3.5 / 6 | 1,138 / 1,665 ms |
| light | 384 | 1 / 1 | 393 / 544 ms |
| light | 256 | 1 / 1 | 298 / 422 ms |
| 60 of 64 slots held by decoders | 0 | 67 / 129 | 5,991 / 10,679 ms |
| 60 of 64 slots held by decoders | 384 | 63 / 125 | 5,698 / 10,224 ms |
| 60 of 64 slots held by decoders | 256 | 61.5 / 134 | 5,710 / 10,890 ms |

With room in the engine the cap does what the replay assumed: the prompt completes in the step after the add. With the slots full it does nothing, because the wait is for a slot, not for budget (v23 review, finding 3). So the candidate's effect depends on how often the slots fill under the real load; the pilot's archives have 1,836 steps at 64 requests.

**What is left free, and what a paid session must measure.** Free: the CPU experiment measured to prompt completion and first content, warmed, at 384, with all 64 slots occupied and with sustained arrivals; and a kind test of a gateway hold rule's fidelity: release on delivered first content, concurrent arrivals and cancellation. Then, with acceptance limits frozen before purchase (premium p99 ratio, contender completion, completion latency and longest hold), one GPU session comparing off, current P, hold only, cap only and the combination, measuring capped step durations, premium TTFT and inter-token latency, contender completion with timeouts counted, throughput, 64-slot occupancy, KV usage and preemption, and the gateway's release timing.

### v24: the diagnostic session, drafted 2026-10-09, and rejected as not purchase-ready

astra attacked the draft below: 3 blockers, 6 majors, 2 minors; verdict "reject v24 as purchase-ready; retain 384+serial-prefill as a candidate requiring an executable, rehearsed protocol". I checked them and agree; the attack is `data/2026-10-09-pilot-results/astra-v24-attack.md`. In short:
- **The apparatus cannot run it** (blocker): the matrix, the study registry, the engine validator, the gateway arguments and the report accept only the pilot's stages, arms and three blocks.
- **Premium inter-token latency is undefined and not captured** (blocker): a p99 of individual gaps and of per-request averages differ by up to 16 times on a 64-token response, and the sender keeps no per-token timestamps.
- **The rule releases on the first body byte, the replay on delivered first content** (blocker): an SSE frame without content would release the next contender. Equivalence on the pinned engine must be shown, or the two made the same. **Done both ways (2026-10-09):** on vLLM v0.27.1 (CPU), the role frame with empty content arrives in the same read as the first token, 1,550 to 1,656 ms after a 3,000-token prompt was sent, while the headers come at 4 ms; and serial-prefill now releases at the first complete content event, by a watcher of its own, so a contentless frame cannot release it on any engine (its pipeline test sends one first, and fails if released on the first byte).
- **The cost limits sit just above the replay's favourable outputs** (25 s against a 23.8 s longest hold) without a rationale of their own; p95 completion latency and windowed contender work are unbounded; "longest hold" excludes the requests refused for waiting.
- **Two blocks cannot carry a pass or fail**: two of two successes bound block success only above 22%. The verdict has to be "observed on these traces", with an inconclusive outcome.
- **Validity gates are missing**: premium loss, off's health, an infinite denominator, which L and ceiling apply.
- **Peak KV and slot occupancy are not captured** by before-and-after scrapes; P has no decision role and R1 is missing; 10 cells by the pilot's own allowance method need 3 h 16 m, not 1 h 50 m.

### v25: the diagnostic protocol, revised against the v24 attack (2026-10-09, not yet attacked)

Each line says which v24 finding it answers.

**Study** `admission-diagnostic-2026-10-10`, one g5.2xlarge session in gpu-lab, the pilot's load, lengths, engine and capture.

**Arms** (finding 10): **R1** (isolated, once), **off**, **hold** (serial-prefill, longest hold 25 s, released at the first content event), **cap** (off with `--long-prefill-token-threshold 384`), **hold+cap**. P is dropped: the pilot measured it at 0.995 of off and it decides nothing here. R1 is the isolated anchor every ratio is read beside.

**Blocks** (finding 5): three blocks of off, hold, cap and hold+cap, each in a hashed order, plus R1 once at the start: 13 cells. Seeds, frozen now: 851, 852, 853.

**Limits** (finding 11), by the pilot's own allowance method with its measured arm time: 1.25 × (200 + 13 × 920 + 12) = 15,215 s. Hard stop 4 h 14 m (15,240 s), acquisition deadline 6 min before it, backstop 10 min after, `study-deadline` 20 min after. The matrix on the instance stops 2 minutes before the acquisition deadline, so its archive and marker are up first; the pilot measured that tail at 12 s. A block cut by the deadline is reported and not scored; the verdict reads complete blocks only.

**Validity, or the verdict is "inconclusive"** (finding 6), checked per block:
- every arm's premium loss under 0.5%, and off's crossed denominator finite;
- every request's dispatch lag at most 50 ms, and at most 0.1% of each arm's premium requests above L = 13 ms (pilot 1's L; its stall-inflated 409 ms ceiling is not used, because the stall it measured is fixed);
- capture and eligibility as in the pilot;
- the preemption counter read before and after every hold+cap cell; a missing or failed read makes that cell unscorable, not passing (finding 9).

**Acceptance for hold+cap, every line in every complete block** (findings 4, 7, 8). The cost lines are set by what the contender tenant can bear, not by the replay's outputs: the contender is a long batch-like request whose client times out at 30 s, so it must still complete in time, and twice off's latency is the most a batch client can absorb without its own timeouts moving.
- premium TTFT p99, crossed upper end against off, at most ln 0.85;
- contender completion, timeouts, refusals and late finishes counted as failures, at least 95%;
- contender completion latency from its scheduled instant to the client's last token, failures at +inf: p50 at most 1.5 × off's, and p95 at most 25 s, 5 s inside the client's 30 s timeout. **These two limits and the 95% are the owner's decision (2026-10-09)**, chosen from three offered with off's and the replay's numbers beside them: the contender keeps a service close to what off gives it. The replay puts hold+cap's p95 at 8.1 to 24.1 s, so the p95 line may fail on the card;
- contender work processed within the premium window (p and q, as the pilot defines them) at least 0.9 × off's, so the cost cannot be moved into the drain after the premium load ends;
- **zero** `serial_prefill_hold_timeout` refusals; holds are measured from the admission decision's start to its end (`admission_wait_seconds` and the record's decided stamp), over every held request including those refused;
- premium inter-token gap p99, pooled over every client-visible gap of every premium success, at most 1.25 × off's (finding 2);
- zero preemptions.

**Verdict** (finding 5): "**observed on these traces**: hold+cap met every limit in all three blocks", or "**not met**: <the first failing line and block>", or "**inconclusive**: <the failed validity check>". Three blocks of one card cannot carry more: three successes of three bound the block success rate above 37% at 95%, so a pass licenses designing a main study, not concluding one.

**Measured and published whatever the verdict:** each arm's premium p50 and p99 beside R1's; step durations by chunk size; running, waiting, KV usage and preemptions from the 1 s engine samples; gateway holds; throughput.

**Built for it so far:** serial-prefill released at the first content event (64188a2), hold time in the latency metrics and as `admission_wait_seconds` (e7e7874), every client-visible inter-token gap (9b7dc1a), the 1 s engine sampler (6a6b538). **Built since** (2026-10-09): the study's registration and stage D, its cells in the matrix (R1 once, three hashed blocks of four), the engine's cap only on cap and hold-cap and the validator refusing it anywhere else, serial-prefill on hold and hold-cap, the session's 4 h 14 m limits (02223ed, 2810b80, c91350c); the report's `diagnostic` command scoring every line per block, with unscorable lines kept apart from measured failures and a lone cell's violations still reported (46de41a, c4f4e87); serial-prefill reading its responses decoded whatever the client asks (24e5f02). **Rehearsed on kind** at c91350c: 13 cells, file accounting 208 of 208, the hold only in the hold arms, the cap only in the cap arms, and a verdict scored (the stub's, which models no scheduler, says "not met" and means nothing).

**astra's attack on v25** (`data/2026-10-09-pilot-results/astra-v25-attack.md`): 1 blocker, 6 majors, 1 minor; verdict "reject v25 as freeze-ready and purchase-ready". I agree with all eight. What was done about each, the same day:

| Finding | Done |
|---|---|
| 1 (blocker) missing gap evidence read as fast gaps; an unterminated stream counted as a success | A success now needs `[DONE]`; a premium success whose gaps number other than its frames less one is a problem that makes the cell ineligible, and rows with no gaps at all are counted apart (7764c53) |
| 2 the cost limits are asserted, not derived; p95 within 2× off can exceed the 30 s timeout | **Decided by the owner**: completion at least 95%, p50 at most 1.5 × off's, p95 at most 25 s, no hold refusal. Off's health is added to validity: off must complete at least 95% of contenders, or the block is inconclusive |
| 3 the pilot's window ends at each arm's last premium return, which a worse treatment lengthens | Retained work is also measured over a window shared by every arm, ending at the block's last scheduled instant (7764c53); the acceptance line uses that one |
| 4 no replay of the exact policy | The replay now refuses a contender held 25 s from its arrival and times completion at delivery (b805a95). Hold+cap at 384: fitted, every contender completes in all six cells with no hold refusal; 10% slower, five cells the same and the sixth 230 of 239 with 9 hold refusals, where off completes 226 |
| 5 one request's hold cannot be reconstructed | The record now has the decision's start, so decided minus deciding is each request's hold, refused or admitted (5f38f72) |
| 6 a block cut by the deadline has no outcome | Precedence: a positive verdict needs all three blocks complete and eligible; fewer is "inconclusive", and any failure observed in an incomplete block is still reported |
| 7 one-second samples cannot show a peak or a saturated stretch | The samples are published as sampled observations only, never as a maximum or a duration; a failed read leaves a row; the cadence is held. Their stamps were nanoseconds labelled milliseconds, which this machine's `date +%s%3N` produced, and a check now pins milliseconds (4394227) |
| 8 an auxiliary arm's harm can make the candidate's block inconclusive | Validity reads off and hold+cap only; hold and cap are reported, and their own loss does not void the block. The nine-cell design (one five-arm block, then two off and hold+cap pairs) is the cheaper alternative, which loses the repeated ablation |

**astra's final attack before purchase** (`data/2026-10-09-pilot-results/astra-final-attack.md`): 1 blocker, 3 majors, 1 minor; "not ready". I agree with all five and fixed them the same day: a cell the matrix refused is invalid in the scorer; a block whose validity fails leaves its comparisons unscored, and only what a cell observes directly (a hold refusal, a preemption) can still fail it; completion is timed at the last content frame, not the replay's return; a positive verdict needs all thirteen cells, and live snapshots of a missing cell are named (d0da162); the instance's tail reserve is 2 minutes, not 10 (this commit). The rehearsal accepts any of the three verdicts, since the stub models no scheduler; the verdict's distinctions are pinned by the report's tests.

### The diagnostic's result, 2026-10-09

Bought in gpu-lab on one g5.2xlarge Spot, `i-0bed746c2078352f1`, launched 12:25:20Z, marker 14:37:59Z, terminated before download; 13 cells, every one eligible, no refusal, the engine counting the frozen 68 and 7,695 tokens. Scored by `pilot_report.py diagnostic` at the commit in `data/2026-10-09-diagnostic-results/`.

**Verdict: observed on these traces: hold-cap met every limit in all three blocks.**

| Arm | Premium TTFT p99, scheduled, blocks 1 / 2 / 3 | Contenders completed | Contender completion p50 | p95 | Premium inter-token gap p99 |
|---|---|---|---|---|---|
| R1 | 63.5 ms | — | — | — | 31.7 ms |
| off | 1,470 / 1,516 / 1,486 ms | all | 3.2 / 5.2 / 3.2 s | 13.5 / 11.7 / 7.9 s | 91–93 ms |
| hold | 1,453 / 1,511 / 1,477 ms | all | 3.2 / 5.3 / 3.2 s | 13.6 / 12.0 / 8.0 s | 91–93 ms |
| cap | 1,742 / 1,752 / 1,626 ms | all | 3.5 / 5.6 / 3.5 s | 13.7 / 12.0 / 8.4 s | 90–91 ms |
| **hold-cap** | **423 / 479 / 452 ms** | **all** | **4.0 / 7.2 / 4.0 s** | **16.8 / 16.0 / 9.6 s** | **88–89 ms** |

- **Premium p99, crossed upper end against off:** ln 0.288, 0.316, 0.304, each far below ln 0.85.
- **Contender cost, against the owner's limits:** completion 100%; p50 1.26, 1.38 and 1.25 times off's (limit 1.5); p95 16.8, 16.0 and 9.6 s (limit 25 s); no hold refusal; no preemption; work in the shared window 0.99 to 1.00 of off's for p and 0.99 for q.
- **Each part alone did what the replay said it would:** the hold alone left the tail at about 0.99 of off's, the cap alone made it worse, 1.09 to 1.19 times, and together they cut it to about 0.30. The replay had predicted 0.95 to 0.97, 1.15 to 1.27, and 0.27 to 0.36.

**What it licenses.** By the protocol's own reading, three blocks of one card: designing a main study of hold-cap against a static control is warranted; this is not that study's result. Three passing blocks bound the block success rate above 37% at 95%. Hold-cap still sits about seven times above isolated service (452 against 63.5 ms), and the contender pays about 25 to 38% in median completion.

### The static control, screened before a main study is drafted, 2026-10-10

**The question a main study would ask.** Hold-cap forwards the next contender when the previous one's first content arrives. The simplest static control forwards it a fixed spacing after the previous one, with the same 384 cap and no signal from the engine. Does the first-token signal buy anything over that? Before writing a protocol, the replay and the three cards' step logs were asked what such a study would find. Every figure below is re-derived from `simulate.py control`, `feasible` and `pace`, whose outputs are in `data/2026-10-09-pilot-results/simulate-control.txt`, `simulate-feasible.txt` and `simulate-pace.txt`. A first draft of this section was attacked cold by astra, and a bare review of the replay's commit found that an idle engine skipped a spacing's release time; that defect is fixed and pinned by a test, and it moved one printed figure by 1 ms. The draft's conclusion did not survive the attack, and what follows replaces it.

**At the fitted pace, hold-cap is on the frontier.** Over the six archived off cells, spacings from 1.0 to 3.0 s, no spacing was at least as good as hold-cap on both premium p99 and contender completion p50 in any cell. The trade is steep around it:
- **1.6 s** matches hold-cap's contender p50 (−2.5% to +3.2%), and its premium p99 is 0.32 to 1.02 of off's against hold-cap's 0.27 to 0.36;
- **1.7 s** gives premium p99 0.24 to 0.38 of off's; hold-cap's median contender completion is 9% to 16% lower than this spacing's, and in pilot B's third off cell the spacing refuses two contenders for waiting;
- **1.8 s and wider** cut the premium tail further, to 0.22 to 0.30 at 1.8 s, and pay in contender latency, then in refusals (5 at 1.8 s, 14 at 1.9 s, 25 at 2.0 s in pilot B's third off cell).

**The owner's limits decide which spacings are candidates.** The contender limits frozen for the diagnostic apply to a control as much as to hold-cap: completion at least 95%, completion p50 at most 1.5 times off's, p95 at most 25 s, no hold refusal. Scanned in 10 ms steps from 1.50 to 1.80 s, every spacing up to 1.66 s meets them in all six cells, and every spacing from 1.67 s fails in pilot B's third off cell, first by a hold refusal or the 25 s p95, and from 1.73 s also on the median elsewhere. Hold-cap meets them in all six. Among the spacings that meet them everywhere, the cell with the worst premium tail is never below 0.618 of off's; hold-cap's worst cell is 0.357. At the widest admissible spacing, 1.66 s, hold-cap's contender median is lower in every cell (1.12 to 1.24 times off's against 1.20 to 1.33), its premium tail is lower by 7% to 44% in three cells, and higher by 2% to 5% in the other three.

**Why the spacing is a knife edge.** A fixed spacing protects the premium tail only while it outlasts a capped prefill; when it does not, contenders pile up unfinished and the queue cascades. On the diagnostic's card, measured in the step logs from the scheduler's insertion of a contender to the end of the step that took its last prompt token, a hold-cap contender's prefill was p50 1,637 to 1,665 ms, p95 1,706 to 1,733 ms, longest 1,788 to 1,890 ms. The replay's own prefill for the same rule, timed from its modelled engine arrival, is shorter: p50 1,599 and p95 1,696 ms on pilot A's first off cell. In that replay at 10% slower steps, the 1.7 s spacing's contender time from engine arrival to first token grows from p95 1,680 to 9,476 ms, up to six contenders are in the engine without a first token, waiting or running, and two or more are for 35% of the span; that counts queued contenders too, not six prefills receiving tokens at once. Over all six cells at 10% slower, the 1.7 s spacing's premium p99 is 1.17 to 1.27 of off's, worse than doing nothing, while hold-cap's is 0.33 to 0.44; but hold-cap then also breaks the owner's limits in pilot B's third cell, with 9 hold refusals and a p95 of 27.7 s. So the slower replay shows feedback keeping the premium protection, not keeping the whole service inside its limits. At 10% faster, the same spacing has slack and a lower premium tail than hold-cap, 0.18 to 0.21 against 0.22 to 0.29, at a contender median up to 62% higher (5,899 against 3,636 ms in pilot B's first cell).

**But the cards have not drifted 10%.** Against the step model fitted on pilots A and B, every cell's total measured step time was 0.9880 to 1.0275 of predicted, the diagnostic's card included, though it was held out of the fit. The largest departures are within one card, between arms: the diagnostic's hold-cap cells ran 1.0205 to 1.0275 while its off cells ran 0.9952 to 1.0023. I have not established why; one candidate is that the model was fitted on archives with no capped steps. So a 10% slowdown across a whole cell is a replay perturbation, not something these three g5 cards showed. These are cell totals; they do not exclude slower stretches during capped prefills, which is where a cascade would start, and the replay's perturbation scales every step alike, without the measured residual spread.

**What follows for the main study.** The control is legitimate, and its spacing is not a free choice: the owner's limits leave a window whose widest point is 1.66 s on these traces, and a registration can name that rule, "the widest spacing meeting the owner's limits on the calibration cells", rather than a number. Against that control, the replay predicts hold-cap costs contenders less in every cell and protects the premium tail far better in some cells and slightly worse in others. A per-block comparison would therefore be mixed, and a pooled or worst-block endpoint is where the replay predicts a difference; which of these the study registers is the owner's choice, and the sizing follows from it. Two things the replay cannot settle bear on the design. First, its capped prefill is 2% to 4% shorter than the card's, so a spacing selected in the replay, 1.66 s, sits at the card's measured prefill median and would likely cascade on the card; the control's spacing has to be calibrated on the card that runs it, from measured prefills, not from the replay. Second, the 10 ms grid steps from admissible to inadmissible between 1.66 and 1.67 s in one cell, so the window's edge is located only on these six traces, and is not a property established for the card.

**So the main study is not drafted yet.** Its shape is now clear: off, hold-cap, and a fixed spacing with the same cap, calibrated on the running card by a frozen rule against the owner's limits, compared on a registered pooled or worst-block premium endpoint with the contender limits as constraints. Drafting it needs the owner's choice of endpoint. A robustness study, which lengthens the capped prefill with longer contender prompts, is a separate design; if it is chosen, its control should include a spacing that scales with the prompt's work, or the comparison only tests that the control ignores request size.

### v26: hold-cap against a frontier of fixed spacings, drafted 2026-10-10, attacked once and revised

The owner chose the endpoint: premium TTFT p99 pooled across blocks.

**Why the control is a frontier, not one calibrated spacing.** The pooled endpoint needs the control's spacing fixed before the card runs it, and the replay cannot fix it. Scanned at step-time scales from 0.950 to 1.100 in steps of 0.005 (`simulate-feasible-pace-grid.txt`), the widest spacing meeting the owner's limits in all six archived cells moves from 1.62 s at 0.950 to 1.66 s from 0.970 to 1.015, back to 1.64 s at 1.025, and then disappears: from 1.030 up, no spacing meets them, because pilot B's third trace pushes every spacing past the 25 s p95 or into a hold refusal. Over the same range, hold-cap's pooled premium p99 over that widest spacing's goes from 1.102 at 0.950, the spacing ahead, through 0.967 at 0.985, to 0.473 at 1.025. The diagnostic's card ran its hold-cap cells at 1.0205 to 1.0275 of the model and its off cells at 0.9952 to 1.0023. So the replay's error on capped steps is about the size of the swing, and a spacing calibrated through the replay would let that error decide the outcome. Instead, the card runs a frozen grid of spacings, and the owner's limits judge each one on the card.

**Arms, each on a fresh engine, all with `--long-prefill-token-threshold 384` except off:**
- **off:** admission off, no cap;
- **hold-cap:** serial-prefill, longest hold 25 s, cap 384, as in the diagnostic;
- **fixed-1.62, fixed-1.66, fixed-1.70, fixed-1.74:** the gateway forwards a contender no sooner than that many seconds after it forwarded the previous one, in arrival order, with the same 25 s longest hold, and nothing from the engine.

The grid is frozen now. It spans the replay's widest admissible spacing at every pace where one exists, 1.62 to 1.66 s, and the card's measured hold-cap prefill, p50 1,637 to 1,665 ms and p95 1,706 to 1,733 ms. Its 40 ms step can miss the best fixed spacing between two points; that bias favours hold-cap, and the page states it beside the verdict.

**Blocks:** three blocks of the six arms, each in a hashed order, plus R1 once at the start: 19 cells. Seeds, frozen now: 861, 862, 863.

**Limits,** by the pilot's allowance method with the diagnostic's arm time kept at 920 s: 1.25 × (200 + 19 × 920 + 12) = 22,115 s. Hard stop 6 h 9 m (22,140 s), acquisition deadline 6 minutes before it, backstop 10 minutes after, `study-deadline` 20 minutes after. The diagnostic's measured cells took 537 to 559 s after its cold first cell (881 s), so 19 cells are expected near 3 h 10 m, well inside the hard stop. One session, in one login, under the 12 h rule.

**Admissible, per arm, in every complete block, the same lines for hold-cap and every fixed arm:**
- the owner's four contender limits, as frozen for the diagnostic: completion at least 95%, completion p50 at most 1.5 times that block's off, p95 at most 25 s, no hold refusal;
- the diagnostic's three further safeguards, kept binding so that a pass cannot come from lost work or moved cost (v26 review, finding 4): no preemption in the cell, contender work in the shared window at least 0.9 of off's for both p and q, and premium inter-token gap p99 at most 1.25 times off's.

A cancelled or failed contender also releases a serial-prefill reservation without first content; such contenders are failures in the completion line, so their number is bounded by it, and it is published per cell.

**Validity, for every arm, kept apart from outcomes (v26 review, finding 7).** A validity line asks whether the evidence can be trusted; an outcome line asks what the arm did. Validity, in any cell of any arm: the cell is present, not refused and eligible; its largest dispatch lag is at most 50 ms and at most 0.1% of premium requests lag above 13 ms; no premium success lacks gap evidence and no contender success lacks complete gaps; and the gateway's own delay after its arrival stamp, the durable record and the decision, has p99 at most 13 ms and maximum at most 50 ms (v26 review, finding 3; on the diagnostic's card it measured p99 4.98 to 5.68 ms and maximum 7.74 to 12.51 ms in every cell). Off's premium loss under 0.5% stays a validity line, since off is the reference. In a treatment arm, a premium request that the apparatus recorded whole and that failed or timed out is an outcome: it enters that arm's pooled p99 at +inf, and so an overloaded fixed arm loses on the endpoint instead of voiding the study.

**The endpoint:** each arm's premium TTFT p99, pooled over its three cells, taken from the scheduled start; for a comparison between two arms, the crossed upper end ln(A's pooled p99 scheduled hi / B's pooled p99 arrival lo), as the diagnostic's crossed box.

**Verdict, frozen before purchase, read in this order:**
1. **inconclusive: <reason>** when any validity line above fails in any cell, a cell is missing, or fewer than three blocks are complete.
2. **not met: hold-cap broke the owner's limits** when hold-cap is not admissible.
3. **observed on these traces: hold-cap met the limits and no fixed spacing in the grid did** when no fixed arm is admissible.
4. **observed on these traces: hold-cap beat every admissible fixed spacing** when, for every admissible fixed arm F, ln(hold-cap scheduled hi / F arrival lo) is at most ln 0.85.
5. **observed on these traces: fixed-<s> beat hold-cap** when the admissible fixed arm with the lowest pooled p99, F, has ln(F scheduled hi / hold-cap arrival lo) at most ln 0.85.
6. **not established: neither hold-cap nor fixed-<s> was 15% below the other**, naming that F, otherwise. A ratio of 0.90 is this verdict, not a fixed-arm win (v26 review, finding 5).

**Published whatever the outcome:** every arm's pooled and per-block premium p99, contender completion, p50, p95 and hold refusals, each fixed arm's admissibility by block, the measured capped prefill per cell, and each cell's pace against the replay's model.

**What the replay predicts.** `simulate.py frontier` replays the registered decision itself, every grid arm judged and hold-cap compared against every admissible one, with each of the six archived off cells standing for a block, at paces 0.950 to 1.100 (`simulate-frontier-pace-grid.txt`). It models the owner's four limits on point estimates, not the crossed bounds, the three further safeguards or validity, and it replays six old traces, not the three new seeds. It predicts verdict 6, not established, from 0.950 to 0.990: the best admissible spacing, fixed-1.62 up to 0.965 and fixed-1.66 from 0.970, stays within 15% of hold-cap either way. It predicts verdict 4 from 0.995 to 1.005, hold-cap's pooled p99 0.81 to 0.72 of fixed-1.66's. From 1.010 up, it predicts verdict 2: hold-cap itself breaks the owner's limits, always in pilot B's third trace, the heaviest of the six with 239 contenders, mostly at the 25 s p95, which it misses by 17 ms at 1.010. The diagnostic's own traces kept hold-cap's p95 at 9.6 to 16.8 s on a card whose hold-cap cells ran at 1.0205 to 1.0275 of the model. So the verdict on the card turns on two things the replay cannot settle: the card's pace on capped steps, and whether the new seeds' traces are as heavy as pilot B's third. That is why it is a measurement and not a foregone result; it is also why the seeds' traces should be replayed before purchase (below).

**Before purchase: replay the frozen seeds.** The traces for seeds 861 to 863 are generated, not drawn, so they exist before the card runs them. The build generates them and replays them through `frontier` at the fitted pace and at the diagnostic card's 1.0205 to 1.0275, and the page records the predicted verdict for each, before any spend. A seed is not swapped for a lighter one if its trace is heavy: the seeds are frozen here, and replacing one after seeing its prediction would select the traces for the verdict.

**What it would not show.** One card, one load, three traces: a verdict here describes these traces on this card, not g5 cards or other loads. A fixed spacing tuned on this card's own measured prefill, between the grid's points, could do better than the grid's best. And the robustness question, a load whose prefill lengthens, is not asked.

**What the first attack on v26 changed.** Astra attacked the draft cold (`astra-v26-attack.txt`); bare reviews of the replay's two commits found nothing further. Each change below was re-derived or re-run by me.

| v26 finding | Change |
|---|---|
| 1: the replay refused a held contender at the step boundary past 25 s although its spacing had ended inside it | the deadline is judged at the instant the rule would forward; pinned by a test that fails on the old order and on the old sweep alone. It moved four printed figures in `simulate-control.txt`, none quoted on this page, and no admissibility on the pace grid |
| 2: a contender with fewer gaps than frames was timed early | it is untimed, as a premium success is; pinned by a test. The diagnostic rescored identically: it had no such contender |
| 3: the gateway's own delay after its arrival stamp was reported but not bounded | a validity line for every cell, p99 at most 13 ms and maximum at most 50 ms, against 4.98 to 5.68 and 7.74 to 12.51 ms measured on the diagnostic's card |
| 4: the diagnostic's preemption, work and gap safeguards were not carried over | binding, for hold-cap and every fixed arm alike |
| 5: verdict 5 called a 0.90 ratio a fixed-arm win | a fixed-arm win needs its own 15%; otherwise "not established" |
| 6: the replay compared only the widest spacing, not the registered decision | `simulate.py frontier` replays the decision; its prediction replaces the earlier one, and adds that hold-cap breaks the limits from a pace of 1.010 on one heavy trace |
| 7: validity's scope across arms was ambiguous | apparatus lines bind every arm; a treatment arm's failed premium request is an outcome at +inf, so an overloaded fixed arm loses instead of voiding the study |

The draft as written, kept for the record:

**Its question.** On the A10G, under the pilot's frozen load, does the engine's prefill cap at 384 together with the gateway's serial-prefill hold cut the premium tail, at a contender cost inside limits frozen here, before any card time? It is a feasibility measurement of one candidate, not the main study: it answers whether a main study of this treatment is worth designing.

**Arms, each on its own fresh engine as in the pilot:**
- **off:** admission off, no cap (the pilot's O);
- **P:** the pilot's prospective admission, no cap;
- **hold:** serial-prefill (`--admission-mode serial-prefill`, longest hold 25 s), no cap;
- **cap:** admission off, `--long-prefill-token-threshold 384`;
- **hold+cap:** both.

Hold alone and cap alone are there so the combination's effect is not confounded (v23 review): the replay says each alone does little or harm, and the session measures that rather than assumes it.

**Size.** Two blocks of the five arms, in a hashed order per block, on the pilot's load and lengths, under the pilot's capture and eligibility rules; 10 cells, about 1 h 50 m at the pilot's cell times. Seeds, frozen now: 841 and 842.

**Acceptance, frozen before purchase; hold+cap passes only if every line holds, pooled over its two blocks:**
- premium TTFT p99 on the crossed upper end, ln(hold+cap scheduled hi / off arrival lo), at most ln 0.85;
- contender completion, with timeouts and refusals counted as failures, at least 95%;
- contender completion latency p50 at most twice off's;
- longest gateway hold under 25 s, so no contender is refused for waiting;
- premium inter-token p99 at most 1.25 times off's, so the cap's extra steps do not move the cost into decode;
- no preemption in any hold+cap cell, the condition the hold rule's guarantee rests on.

**Measured beside them, published whatever the outcome:** step durations by chunk size (the capped regime the archives lack), 64-slot occupancy, KV usage, the gateway's hold and release times, throughput, and the same for every arm.

**What it does not decide.** A pass makes a main study of hold+cap against a static control worth designing; it is not that study's result. A failure on a contender line with the premium line passing says the trade is real but too costly at 384, and 256 is not tried in this session.

**The cheapest deciding experiments, in order** (astra's list, which I adopt): a scheduler replay on the archives to screen candidate admission rules with their retained contender work; a CPU test that injects a premium request at known chunks of a running prefill, and with all 64 slots full; a kind test of the chosen rule's fidelity; and only then one targeted GPU session comparing off, current P and the best candidate. An engine-side change, letting waiting premium work into the budget at chunk boundaries, is a different treatment and would be a different study.

## What v21 changed, against the review of v20

| v20 finding | Change |
|---|---|
| 1: a failed request without a gateway record can still have reached the engine | the record is written durably at arrival; a scheduler record with no gateway record makes the outcome "invalid"; the two stale permissions are removed |
| 2: the P/O screen was dropped while P/O stays a final test | stage A screens P/O's crossed upper end at ln 0.85 |
| 3: the 50 ms ceiling is a zero-outlier rule again | kept, with the conflict stated: no rule satisfies both round 13's finding and round 19's. It is read after every instance and stops purchase; the pilots cannot establish its survival, and the page says so |

Round 20 re-derived the power table and every cost figure, and agreed with each. No cost figure changed in v21.

## What v20 changed, against the review of v19

| v19 finding | Change |
|---|---|
| 1: contenders without gateway records escaped the lag rule | a served request with no gateway record makes the outcome "invalid"; a request that failed before any response stays a failure |
| 2: uncertain premium requests had no maximum delay | a 50 ms lag ceiling for every request, premium and contender; within it, premium lag of 5 to 50 ms is uncertain for its own TTFT; the remaining displacement effect is a stated assumption, no longer called "enforced by construction" |
| 3: the pilot screen did not test the primary; "half the distance" was wrong | stage B screens the P/S box's half-width, which reads the bounds' spread and not the ratio, at 0.043; half the distance is 0.0859 |
| 4: purchase continued after benefit was impossible | any infinite end stops further purchase |
| 5: "never more powerful than the table" does not hold | withdrawn; the registered procedure's power is stated as not established |

Round 19 re-derived the power table (1,000,000 studies per row) and every cost figure, and agreed with each. No cost figure changed in v20.

## What v19 changed, against the review of v18

| v18 finding | Change |
|---|---|
| 1: the −∞ end was dismissed but defeats the decision | any infinite end fails benefit; re-computed (U → +∞ as one y → −∞) |
| 2: a late contender shifts what others meet | a contender lag rule, 50 ms main and 25 ms stage A; the residual load-shift effect stated in the claim as unmeasured |
| 3: trusted lag was published, not applied | the bounds cross definitions: y_hi = P-scheduled over S-arrival, so no lag can favour P; round 18's 0.99-as-0.92 example now fails |
| 4: per-arm pools differ for I | one pool per block, from the full trace (build item 27) |
| 5: the power table ignores the bounds | stated as an upper bound on the decision's power; stage A measures the uncertain fraction and the y_hi gap, with a stop above 0.05 |
| 6: P/O's threshold was ambiguous | P/O requires U < 0 at every vertex |

**A correction to v18's own claim.** v18 said bounding late requests closed the timing attacks. It closed attacks on a late request's own TTFT. It did not close a late request's effect on others, which v19 bounds by the contender lag rule and states as unmeasured beyond that.

Round 18 re-derived the power table and every cost figure, and agreed with each. No cost figure changed in v19.

## What v18 changed, against the review of v17

| v17 finding | Change |
|---|---|
| 1: the imputation box was not the ratio's extremes | P and S at opposite ends: y_lo = P at 0 over S at +∞, y_hi = P at +∞ over S at 0. My error, and round 17's example now fails |
| 2: shared-position delays defeat arm-blindness | **late requests are not trusted:** lag above 5 ms makes a request uncertain, bounded like a missing record; the trusted lag's bias is bounded and published |
| 3: futility and infinite p99s undefined under intervals | futility reads y_lo; infinite ends defined; an undefined instance fails benefit |
| 4: literal argument equality cannot work on this runner | arm-blindness checked on the resolved sending configuration, as an integrity check rather than the defence |

**Why this closes the timing line.** Every timing attack from round 12 to 17 needed the decision to trust the TTFT of a request that arrived late. v18 trusts no late request: the decision must hold whatever their values were. The residual, at most 5 ms of lag in a trusted request's TTFT, is a measured bound and not an assumption.

Round 17 re-derived the power table and every cost figure, and agreed with each. No cost figure changed in v18.

## What v17 changed, against the review of v16

| v16 finding | Change |
|---|---|
| 1: combining the two delay attacks defeats the conjunction | the timing threat model is stated: an arm-blind harness, enforced by the manifest and a test, cannot choose requests by outcome. One primary, TTFT-scheduled, ending at the gateway's first-content forward; TTFT-arrival is a point consistency check |
| 2: +∞ for a missing P value can lower the t bound | missing values are bounded, not imputed; benefit must hold at every vertex of the imputation box, which is exact because the bound is convex |
| 3: the max-of-two primary had no power basis | the conjunction is gone; the power table again describes the primary |

**Why v17 stops adding timing rules.** Every timing counterexample since round 13 delays requests chosen by their outcome, and v16's two-definition rule fell to the two attacks combined. Rules of that kind can always be met by a cleverer selection. An arm-blind open-loop harness cannot make the selection at all, so v17 enforces that property and names it in the claim.

Round 16 re-derived the power table and every cost figure, and agreed with each. I reproduced its two U values, +0.026015 and −0.099337, before writing the vertex rule. No cost figure changed in v17.

## What v16 changed, against the review of v15

| v15 finding | Change |
|---|---|
| 1: TTFT ended at the client's read, after the client's own delays | both definitions end at the gateway's stamp when it forwards the first content frame |
| 2: arrival-based TTFT rewards delivering P late | benefit must hold on TTFT-scheduled and TTFT-arrival both; y is the less favourable of the two |
| 3: missing records in I undefined | 0 ms in I, the value less favourable to P/I |

**Why a conjunction and not a better single stamp.** Rounds 12 to 15 each moved one TTFT boundary and each found a delay on the other side of it. The two start points fail in opposite directions:
- a scheduled start charges a pre-arrival delay to the delayed arm;
- an arrival start hides it.

A delay can favour P on one of them only. Requiring both turns each attack into a failed verdict, not a false one.

Round 15 re-derived the power table and every cost figure, and agreed with each. No cost figure changed in v16.

## What v15 changed, against the review of v14

| v14 finding | Change |
|---|---|
| 1: a missing record as failure contradicted the join | the record's absence no longer means failure; a premium TTFT without a record is +∞ in P and 0 in S and O; at most 0.1% per arm |
| 2: sparse delays pass every lag rule and move p99 tenfold | premium TTFT is measured from the gateway's arrival instant, so a client-side delay is in no TTFT; the lag rules now only bound load timing |
| 3: stage A cannot compare P's and S's lag | that rule applies from stage B |

**Why the endpoint moved rather than the gate.** Three rounds (12, 13 and 14) each found a way to delay a request that the latest lag stamp or rule could not see. Any aggregate rule misses a few delays, and any client-side stamp has a later point to hide behind. Measuring TTFT from where the request lands makes a client-side delay irrelevant to the tail, rather than trying to catch every one.

Round 14 re-derived the power table and every cost figure, and agreed with each. No cost figure changed in v15.

## What v14 changed, against the review of v13

| v13 finding | Change |
|---|---|
| 1: `WroteRequest` fires before the flush | lag is measured at the gateway, after it has read the body, against the scheduled instant |
| 2: the window needs end instants that failures lack | every outcome carries an end instant (build item 24); the window covers all premium requests; a missing end refuses |
| 3: arrival before `WroteRequest` is legitimate | the client-versus-gateway ordering rule is gone |
| 4: a zero-connection-failure requirement | no maximum-lag rule; quantile and mean-difference rules; a missing gateway record is a failure governed by loss and completion, not a lag violation |

Round 13 re-derived the power table (2,000,000 studies per row) and every cost figure, and agreed with each. No cost figure changed in v14.

## What v13 changed, against the review of v12

| v12 finding | Change |
|---|---|
| 1: the send stamp misses delay inside `Send` | lag from the `httptrace` written instant, with the gateway's arrival as a second reading; a rehearsal sleeping inside `Send` |
| 2: two quiet snapshots are not a fence | **no fence is needed:** p and q count only steps before the window end, after which no work can touch the arm's premium tail, and a terminal record written after the replay proves that window complete |
| 3: scaling the gateway down loses its last records | the gateway is not scaled down; its final records are exported before teardown |
| 4: the 6-to-11-instance fallback is unreachable | removed: fewer than 12 contributing instances after 14 launches is "insufficient" |
| 5: "at most two sessions per login" was wrong | decided at each launch by remaining expiry; up to three fit at expected durations |
| 6: two stamping instructions contradicted | the order now stamps from the frozen counts |

**Removing the barrier restores v11's durations and cost:** main sessions about 2.75 h, $25.25 expected for 12 instances, a $71.72 allowance, and a $75 ledger ceiling.

Round 12 re-derived the power table and every v12 cost figure, and agreed with each.

## What v12 changed, against the review of v11

| v11 finding | Change |
|---|---|
| 1: a late replay lowers P's offered load unseen | the replay origin persisted; a dispatch-lag gate, p99 ≤ 20 ms and max ≤ 250 ms, in pilot and main |
| 2: the sentinel proves a prefix, not the end | a capture barrier: the gateway scaled to zero, engine metrics quiet, two identical terminal records 60 s apart, then both logs |
| 3: informative Spot interruptions | stated as a third assumption; more than two interrupted launches gives "insufficient" |

**The barrier costs about 2 minutes per arm,** so every duration, deadline and cost moved:

| | v11 | v12 |
|---|---:|---:|
| Main session | 2.75 h | 3.15 h |
| Expected cost, 12 instances | $25.25 | $28.91 |
| Allowance | $71.72 | $80.78 |
| Ledger ceiling | $75 | $85 |
| Main sessions per login | three | two |

Round 11 re-derived the power table (10,000,000 studies per row) and every v11 cost figure, and agreed with each. v12's new cost figures are mine.

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
