# S1 pilot: does vLLM v0.32.0, or its async scheduler, serve this fixed work better than v0.27.1?

Date: 2026-11-15. Status: **registration v2, before any run.** Issue #585.
Study ID `vllm-version-async-2026-11-15` (`StudyVersionAsync` in `internal/bench/study.go`).

v1 of this page was attacked cold by codex `gpt-6-astra` and by two diff reviews, and the owner then decided its open questions (2026-11-15). v2 answers both.
The biggest change is what the study is: **a fixed-work performance pilot on this host, not a confirmatory study.** Every verdict below is a pilot decision heuristic.
No paid run may start while a value under "Still open" is unset (`PreflightRefusal` refuses every cell), and not before the release gates at the end are met.

## The question, and what an answer licenses

On one A10G (g5.xlarge) serving Qwen2.5-3B-Instruct, given the same offered traffic, does moving from vLLM v0.27.1 to v0.32.0 change failure-inclusive tail latency or SLO goodput enough to be worth adopting, and does turning on async scheduling in v0.32.0 change them further?

A verdict says: on this host, model and revision, the `v0.27.1-a10g` flags, this synthetic fixed-work workload (input 256/1,024/2,048 tokens, exact outputs of 64/256, greedy), open-loop Poisson arrivals at 0.6 and 0.9 of A's confirmed stable operating rate, sent directly to the engine, the pilot heuristic below returned adopt / practically equivalent / uncertain / reject.

It does **not** license:
- a calibrated statistical claim: the interval is a percentile bootstrap over six blocks, not a confidence interval with known coverage, and no bound is a 5% test or TOST;
- deploying v0.32.0 in production: exact lengths and greedy decoding remove natural stopping, the sampling path, output-length changes and semantic behaviour. Operational adoption additionally needs a separately specified natural-stop and production-sampling correctness check;
- other GPUs, models, workloads, prefix caching, overload (1.2 λ0, bursts), several replicas, the gateway path;
- any claim about B's or C's capacity (only A's operating rate is measured), or attributing an effect to one internal change of the release, or anything about GPU utilisation.

## Fixed now, measured in the session, still open

| | Value | Enforced by |
|---|---|---|
| **Fixed now** | arms; v0.32.0 for B and C; the engine profile and what may differ; `--scheduling-policy=priority`; model, model revision, tokenizer revision and chat template; loads 0.6 and 0.9 λ0; workload mixture; sampling; campaign seed `20261115`; 6 planned blocks + at most 2 replacements; treatment and load orders; warm-up 60 s; window rule; timeout; dispatch-lag tolerance; SLO; decision rule and its thresholds; calibration ladder and criteria; invalidation, ledger and rerun rules; phase bounds; $20 cap with $2 reserve | `versionAsyncDesign`, `versionStudySampling`, `LoadManifest` |
| **Measured or read in the session, then frozen** | λ0; the window W; the instance price; every trace | the campaign bundle (`LoadCampaignBundle`), whose sha256 every cell carries |
| **Still open** | nothing (the engine-path track froze the last four values on 2026-11-15) | `Unfrozen` would list B's and C's image digest and flag review if any were unset; `PreflightRefusal` refuses every manifest and bundle while it lists anything |

The two engine-path fields are `EngineSettings.Image` for treatments B and C, and `EngineFlagReviews`: the sha256 of the effective-argument record that track reviewed against the v0.32.0 image's own flags, confirming that each registered setting maps to a real flag.

**Runtime identity compares arguments, not hashes** (#608).
- A running engine's command line is reduced by `ParseProfileArgs` to its profile arguments, without the model, port, served name and revisions.
- `CheckRuntime` compares those arguments, in order, with `ReviewedProfileArgs`:
  - for B and C, the review records' `renderedProfileArgs`, which `TestReviewedProfileArgsAreTheReviewRecords` holds to the files `EngineFlagReviews` hashes;
  - for A, the validated v0.27.1 profile.
- No argv can hash to the review file, so its hash stays provenance.
- `CheckRuntime` needs no bundle, so a wrong engine is refused at preflight, before calibration. `CompareRuntime` adds the bundle's frozen image.
B and C run `vllm/vllm-openai@sha256:befccf0e7e4089aa23926bb6f887a85c0d46c2a99e6de5c5ffdf5cb7957c5b34`, the manifest list Docker Hub's `v0.32.0` tag resolved to on 2026-11-15; the image records the build commit the tag names.
Their reviews are `hack/engine-flag-reviews/vllm-v0.32.0-async-off.json` (B) and `hack/engine-flag-reviews/vllm-v0.32.0-async-on.json` (C); `TestEngineFlagReviewsAreTheCommittedRecords` recomputes both hashes, and the controller's `TestExperimentalV0320RendersItsReviewedRecord` holds the rendering to the same files.
That is a source review: no flag's effect on v0.32.0 has been measured here.

## Arms and what may differ

Six arms, `<treatment>-<load>`: `A-l060`, `A-l090`, `B-l060`, `B-l090`, `C-l060`, `C-l090`.

| Treatment | Engine | Async scheduling |
|---|---|---|
| A | vLLM v0.27.1, `vllm/vllm-openai@sha256:0a51ea5b…bfd967` (`VLLMV0271Digest`) | off |
| B | vLLM v0.32.0, `vllm/vllm-openai@sha256:befccf0e…5b34` (`VLLMV0320Digest`) | off |
| C | the same image as B | on |

**Must not differ:** the `v0.27.1-a10g` profile from `internal/controller/inference_engine.go` (`measuredA10GArgs`, prefix caching off): `--dtype=half`, `--max-model-len=16384`, `--max-num-seqs=64`, `--gpu-memory-utilization=0.90`, `--no-enable-prefix-caching`, `--max-num-batched-tokens=512`, `--scheduling-policy=priority`. Also the model `Qwen/Qwen2.5-3B-Instruct` at revision `aa8e72537993ba99e69dfaafa59ed015b17504d1` for weights and tokenizer, chat template sha256 `cd8e9439…527f`, instance, client, workload per block, sampling and timeout.
`versionStudyEngine` builds all three from one function; `EngineSettings.Diff` refuses a manifest or a running engine that differs in any field.
**May differ:** A→B, the version and image; B→C, async scheduling. What a release changes without a flag is part of "version" and is not attributed further.

`--scheduling-policy=priority` stays (owner, 2026-11-15) because it is the validated incumbent profile. This workload sends no `priority` field, so every request has the same priority.
No gateway is in the path; a v3 manifest with gateway thresholds, `longThreshold` or `matchTolerance` is refused.

## Comparisons and how one is chosen

- **C vs A is primary**: it is the operational decision, C if it adopts.
- **B vs A is the fallback**: B is selected only when C vs A does not adopt and B vs A does.
- **C vs B is explanatory only**: it says whether the version or the scheduler produced a C vs A result, and never selects.

`SelectTreatment` encodes this; otherwise A stays.
Two chances to adopt (primary and fallback) and two loads are multiplicity the heuristic does not correct; the report prints every endpoint and load result beside the selection.

## Load: λ0 is A's confirmed stable operating rate

**One common λ0, measured on A.** This answers "what happens to the same traffic after upgrading". For an arm X with capacity c_X, a fraction f of λ0 sits at about f·λ0/c_X of X's own capacity: if B had twice A's capacity its points would be near 30% and 45%; at 75% of A's capacity, near 80% and 120%. That is the effect a deployer would see. The design does not measure relative capacity, and a faster engine need not show higher goodput when A already serves every request within SLO.

**λ0 is not called a sustainable capacity.** A finite window cannot establish one. It is the highest rate the registered ladder found stable, confirmed again on fresh traces (`CalibrationRule`, `ClassifyRung`, `CalibrationRule.Run`).

**Each rung** starts from a drained engine (client has nothing outstanding; the engine's own metrics report no running or waiting request), then 60 s warm-up and a 180 s window at an open-loop rate, from trace seed `CalibrationSeed(ordinal)` = 2026111500 + rung ordinal (never a block's seed). Its drain is bounded at 120 s.

**Classification** over the window (tolerance ε = 0.02):
- **unstable** (a backlog) if departures in the window are fewer than (1 − ε) × arrivals in it; or outstanding requests grew by more than max(3, ε × arrivals); or the least-squares trend of outstanding requests sampled each second exceeds ε × the offered rate per second (`OutstandingSlope`); or any window arrival has no outcome at the drain deadline;
- **unreliable** if it keeps pace but failures exceed 0.5% of window arrivals: reliability is judged apart from throughput, so one rare error no longer decides capacity;
- **invalid** if it did not start drained or offered nothing; it is repeated, at most 2 times in the whole ladder;
- otherwise **stable**.

**Ladder:**
1. Expansion: from 0.5 req/s, multiply by 1.5 while stable, at most 12 rungs (up to about 43 req/s).
2. Lower fallback: if the first rung is not stable, halve up to 2 times.
3. Refinement: geometric bisection until the bracket ratio is at most 1.05, with its own allowance of 6 rungs.
4. Confirmation: the selected rate must be stable on 2 more fresh traces. If not, step down by 1.05 and require 3 stable rungs there, at most 2 step-downs.

**Every failure is an explicit stop**, "calibration unresolved", with no default λ0: no upper bracket within the expansion rungs, nothing stable down to the lower fallback, a bracket still wider than 1.05, a rate never confirmed, or rungs that stay invalid. The session then ends.
The ladder is bounded at `MaxRungs` = 30 rungs × 360 s = 3 h. On a noiseless capacity of 8 req/s it selects 7.92 req/s, a 1.026 bracket, after 8 expansion rungs, 4 refinement rungs and 2 confirmations. v1's ten-rung ladder ran out there with the bracket still at 1.091 (arithmetic bisection) or 1.107 (geometric); v1 did not say which.
The artifact (`CalibrationArtifact`: resolved, λ0, every rung with purpose and class) is written before block 1, and the bundle pins its bytes.

**Loads.** l060 = 0.6 λ0 and l090 = 0.9 λ0. 1.2 λ0 and bursts belong to a separate study.

## Workload, traces and the window

- One request class, Poisson arrivals. Input 256 (p 0.5), 1,024 (0.3) or 2,048 (0.2) tokens, sent as 1,174, 5,183 and 10,532 characters (`versionStudyExactTokens`). Output exactly 64 or 256 tokens (0.5 each).
- **All traces are generated after λ0 and before block 1**, the replacement blocks' included: one per block and load, seed `WorkloadSeed(20261115, block, load)`, shared by A, B and C.
- **W is chosen from those traces alone** (`ChooseWindow`): from 300 s in 60 s steps until the six planned blocks' traces offer at least 1,000 measured requests at each load, at most 1,800 s, otherwise the session stops. The floor is therefore met by the actual traces, not expected from a rate; the window is never lengthened after outcomes are seen. The generator must be prefix-stable, so that a shorter window's trace is a prefix of a longer one's; `LoadCampaignBundle` recomputes the choice from the traces and refuses a bundle whose W differs.
- Every trace is checked by content: its rows are in order, every length is registered, no row falls outside warm-up plus window, its measured count is as declared, and **its warm-up sends every one of the six input × output classes** (warm-up qualification is a property of the trace, decided before any outcome).
- **Amendment 2026-11-15 (owner): a stratified warm-up.**
  - **Rule:** the first six warm-up rows take the six input × output classes once each, in an order drawn from the trace's seed by a separate generator (`VersionTrace`). Their arrival times and every later row are the stream's own, so the measured population is exactly what the unstratified trace holds (`TestVersionTraceStratifiesTheWarmup`).
  - **Why:** before it, a trace whose warm-up missed a class was refused, since redrawing would be choosing a workload.
    - Assuming independent Poisson counts per class, one 60 s warm-up at 0.6 λ0 misses a class about 41% of the time at λ0 = 0.5, 9% at 0.9, 1% at 1.5 and 0.15% at 2. The rarest class is (2,048, 64) at 10%.
    - Under seed `20261115`, every λ0 low enough to lengthen the window past 300 s (below about 0.93) failed on at least one of the 16 traces. Calibrations at 0.9, 0.85, 0.8, 0.75 and 0.5 each stopped, so the window-lengthening rule could not run.
  - **Remaining refusal:** a warm-up with fewer than six arrivals cannot send every class and is still refused. That takes 0.6 λ0 × 60 s below six, about λ0 < 0.17, which is below the range where the 1,000-request floor can be met anyway.

## Sampling and stop condition

| Field | Value | Why |
|---|---|---|
| temperature | 0 | greedy |
| top_p | 1 | sent so the model's generation config cannot substitute 0.8 |
| repetition_penalty | 1 | changes logits even under greedy |
| seed | omitted | irrelevant under greedy; a per-request seed can be a performance treatment of its own |
| ignore_eos | true | an engine stopping at EOS would shorten the workload per version |
| length | `max_tokens` = `min_tokens` = the row's cap | output length is a property of the workload |

The harness has never sent a sampling parameter, and v0.27.1 serving this model logged on 2026-10-24 that its defaults "have been overridden by the model's generation_config.json: {'repetition_penalty': 1.05, 'temperature': 0.7, 'top_k': 20, 'top_p': 0.8}" (`hack/mps-capability/2026-10-24-run2/m5c-run/mpscap/diag/logs-engines-m5c-a.txt:59`). top_k is not sent: it has no effect under greedy, and its "disabled" spelling has changed across releases.
Greedy decoding does not guarantee identical text across versions or batch schedules; output text digests are recorded as diagnostics and are not compared.

Sender interface (owned elsewhere): with `Study.Sampling` set, the sender marshals `SamplingPolicy.RequestFields(row)` into the body, taking `max_tokens` and `min_tokens` from it; nil keeps every earlier study's body unchanged.

## Blocks, order and lifecycle

- **6 planned blocks** (`MinRepetitions` 6). `ArmOrder(20261115, block)` deals the six treatment orders once each, so each treatment holds each position exactly twice: blocks 1 to 6 run B A C, B C A, C B A, A C B, A B C, C A B; replacements 7 and 8 run B A C and B C A.
- **Load order is counterbalanced** (`LoadOrder`): odd blocks run l060 then l090, even blocks l090 then l060, the same for every treatment of a block. Each load runs first in three planned blocks. A fixed order would make "l090" mean "l090 after l060", and carry-over need not cancel between versions.
- **Engine start and readiness.** Every visit starts a fresh engine process, A included. It must be ready within 600 s of process start: `/health` returns 200, and one priming request per input × output class is answered. An engine that misses the deadline is **unavailable** for that visit (see dispositions).
- **Cache policy.** The model and tokenizer files live in a persistent cache filled during setup. Each image keeps its own compile cache, populated by its preflight start before block 1 and never cleared during the campaign, so every visit in the blocks starts with a warm compile cache for its own image. Prefix caching stays off. GPU temperature and clocks are sampled every 5 s and reported; they are not controlled.
- **Drain verification.** After a cell's last arrival, the drain ends when the engine's own metrics report no running or waiting request, not when the client's timeouts fire. If it has not ended within 120 s, the engine is restarted (with the same readiness bound) before the next load. The restart is recorded and is not invalidating.
- **Identity before execution.** Each cell's v3 manifest is written before its trace starts. It records campaign ID, block, treatment position, load position, order seed, λ0, the bundle's sha256, model, tokenizer revision, engine settings and sampling (`CellIdentity`, `RunManifest.Engine`, `Sampling`). `LoadManifest` checks each against the registration and the seeded plan.

## Per-request dispositions

Every scheduled request gets exactly one disposition (`ClassifyRow`, `RowDisposition`).

| Layer | Result |
|---|---|
| not dispatched, engine missed its readiness deadline | `engine-unavailable`: a failure of the arm, recorded without pretending the request was sent |
| not dispatched for any other reason | protocol fault: the cell is invalid |
| timed out (whole-request deadline) / transport error / non-200 / stream without `[DONE]` | `timeout` / `transport-error` / `http-error` / `stream-error`: failures of the arm |
| stream completed | **conformance is checked here, before success**: usage chunk present, `prompt_tokens` equal to the registered count, `completion_tokens` equal to the cap and `finish_reason` `length` (`CheckCompletion`). Any miss is a protocol fault and invalidates the cell; it is never reclassified as an arm failure |
| stream completed and conformant | `success` |

v1 checked usage and exact length only on successful rows while defining success to include them, which is circular; this order removes that.
Exact length shows the policy took effect on length; it does not prove greedy decoding or the repetition penalty, which only the request body and the engine's effective defaults establish.

## Endpoints

All latencies are client-observed durations on the client's monotonic clock, from each request's **intended arrival**. Population P: the cell's measured rows (intended arrival within the window).

| Endpoint | Definition | Role |
|---|---|---|
| `ttft_p99` | nearest-rank p99 over all of P of first content byte − intended arrival; a request with no content byte is +∞ | votes (tolerated loss) |
| `e2e_p99` | nearest-rank p99 over all of P of last content byte − intended arrival; any failure is +∞ | votes (tolerated loss), and is the **designated benefit endpoint** |
| `goodput` | requests of P that succeeded with TTFT ≤ 1,000 ms and TPOT ≤ 60 ms, ÷ (W × blocks) | votes (tolerated loss); an arrival-cohort SLO yield, not departure throughput |
| failure fraction | failures of P ÷ P, pooled | **absolute reliability guardrail**: the candidate must be ≤ 0.5% |
| `tpot_p99` | over successful rows: (last − first content byte) / (`completion_tokens` − 1) | **descriptive only, never votes**: a success-only population can improve by failing slow requests |
| `cost_per_slo_request` | price × W × blocks / good requests | descriptive: equal to price / goodput |

- Success fraction and the count of each failure category are reported separately for every cell and pool; goodput alone mixes reliability and SLO compliance.
- TPOT is a client streaming measure: it depends on how content is chunked into frames. Frames per response are recorded, and a response delivered in fewer than two content frames has no TPOT and is **not good** (`GoodRequest`), never TPOT 0.
- Time from the last content byte to `[DONE]` and to the usage trailer is reported as a completion-through-trailer diagnostic.
- Realised denominators are checked: each cell's P must equal its trace's measured count (rule 1 below), so the offered floor of 1,000 per load is met in fact.
- Price: the on-demand price of the instance in its region, read from the AWS Price List API at session start and frozen in the bundle with its source and time, plus the session's other charges per hour.

## Analysis

- **Analysed blocks** are derived from the attempt ledger only (`AnalysisSet`). The analysis needs exactly 6 valid blocks; otherwise it is an **incomplete pilot**: descriptive numbers only, no verdict.
- **Effect** (`OrientedEffect`), positive = candidate better: ln(reference / candidate) for TTFT and E2E p99; ln(candidate / reference) for goodput; pooled over the analysed blocks.
- **Zero and infinity cases are registered:**
  - Latency: a reference that is +∞, zero or NaN makes the effect undefined. A candidate of +∞ against a finite reference is −∞, a valid "worse". A zero latency is a measurement fault and undefined.
  - Goodput: a reference of zero makes the effect undefined. A candidate of zero against a positive reference is −∞.
  - TPOT and cost never produce a voting effect.
- **Interval:** the exact block-bootstrap distribution, not a random sample of it (`ExactBlockBootstrap`). All 462 multisets of six blocks drawn with replacement are enumerated, each weighted by its multinomial count (weights sum to 6^6 = 46,656). Bounds are the weighted 5th and 95th percentiles: the smallest value whose cumulative weight reaches 5% (resp. 95%).
- **Evaluability is deterministic:** an endpoint is not evaluable when any multiset with positive weight has an undefined effect. Random draws would decide it by luck: a resample made only of one block has weight 1/46,656 with six blocks, and 10,000 random draws miss it 81% of the time (4% with five blocks).
- This removes Monte Carlo noise; **it does not make the interval calibrated.** Six blocks are six experimental units, and a percentile bootstrap of a p99 with an infinity boundary has unknown coverage.

## Pilot decision heuristic

Thresholds on the oriented log effect (`DecisionRule`):

| | latency (TTFT p99, E2E p99) | goodput |
|---|---|---|
| worthwhile benefit, minimum 10% | lower bound > ln(1/0.9) = 0.1054 (a tenth less latency) | lower bound > ln 1.1 = 0.0953 |
| tolerated loss, 10% | lower bound ≥ −ln 1.1 = −0.0953 (at most a tenth more latency) | lower bound ≥ ln 0.9 = −0.1054 |
| established material harm | upper bound < −0.0953 | upper bound < −0.1054 |

The owner set 10% tolerated loss on the latency endpoints, and confirmed (2026-11-15) that the same 10% applies to goodput, as an SLO-latency outcome. The owner also confirmed E2E p99 as the only designated benefit endpoint.

**One load** (`AssessLoad`), in this order:
1. **Harm** if the candidate's failure fraction exceeds 0.5% (or is unknown), or any voting endpoint shows established material harm. No ratio can buy back added failures.
2. **Uncertain** if any voting endpoint is not evaluable or missing, or the reference itself exceeds the guardrail.
3. **Benefit** if every voting endpoint is within its tolerated loss and the designated endpoint, E2E p99, shows an established worthwhile benefit.
4. **Equivalent** if every voting endpoint's interval lies between its tolerated loss and its worthwhile benefit.
5. **Safe** if every endpoint is within its tolerated loss, but neither of the above.
6. Otherwise **uncertain**.

A gain that is statistically clear but smaller than 10% is not a benefit. A loss that is clear but within 10% is not harm, and its interval reaching past the tolerance leaves the load uncertain rather than rejected.

**Across the two loads** (`CombineLoads`), stated as an operating policy, since a deployment serves both regimes:
- **reject** if either load shows harm;
- else **uncertain** if either load is uncertain;
- **practically equivalent** only if both loads are equivalent;
- **adopt** if a worthwhile benefit is established at either load and the other load is benefit, equivalent or safe;
- otherwise (safe at both, or safe and equivalent) **uncertain**.

**Selection** as above: C if C vs A adopts, else B if B vs A adopts, else A.

## Invalidation

These rules decide validity without looking at endpoint values. They apply with the same predicate to every cell, arm and load; one invalid cell makes its block invalid.

1. **Incomplete accounting:** a scheduled row without exactly one disposition, or a measured population that differs from the trace's.
2. **Dispatch lag:** transport write − intended arrival, p99 over P above 10 ms or maximum above 100 ms. The client shares the instance with the engine, so lag could become treatment-dependent. If lag invalidates cells of the same treatment in two blocks, the campaign stops as an incomplete pilot rather than replacing blocks that a treatment keeps invalidating.
3. **Protocol fault:** a nonconforming completed stream, or a request not dispatched without a recorded engine-unavailable visit.
4. **Identity:** a manifest that `LoadManifest` refuses is never run. A running engine that `CampaignBundle.CompareRuntime` refuses (version, image digest, model revision, tokenizer, chat template, reviewed effective arguments, any registered setting) invalidates its visit's cells.
5. **Recorder failure:** any write or durability error, or backlog overflow.
6. **External cause:** decided by an automatic predicate (amendment 2026-11-15, owner).
   - A block is invalid for an external cause only if, within its time range, AWS reported one of these for the instance:
     - an EC2 scheduled event, such as instance retirement or a system reboot;
     - a failed system status check;
     - a spot interruption notice.
   - Nothing else counts as external. Any other crash or unavailability is an engine outcome.
   - The predicate is fixed before any run and reads only those AWS records, so it cannot be applied after seeing results. Before, a human decided from the instance's event log, which an append-only ledger that decides replacement could not accommodate.

Engine-caused failures, crashes and missed readiness deadlines are **outcomes**, not invalidity. Replacement is reserved for instrumentation, protocol and external failures.

## Attempt ledger and reruns

- Every block attempt is written to the ledger when it ends (`BlockAttempt`: block, status valid / invalid / stopped, reason, start and end, the block it replaces), and never edited. The ledger is archived (`Closed`) before anything is computed from it.
- `AnalysisSet` refuses a ledger that is not archived; an attempt without a recorded start or end, or one that does not end after it starts; planned or replacement blocks out of order (a replacement must take the next block number, since the number fixes its workload seed and orders); a block attempted twice; an invalid or stopped attempt without a reason; overlapping attempts; anything after a stopped attempt; a replacement that names a valid block ("a valid block is never rerun"), no block, or an already replaced one; a replacement that starts before every planned block has ended; and more than 2 replacements. The analysed set is then exactly the valid blocks; since replacements exist only for invalid blocks, there is never a choice between valid blocks.
- A replacement runs under the next block number with its own pre-generated trace, seeded order and load order.
- `CheckVersionCampaign` pairs cells only through the bundle and the ledger. It refuses:
  - a cell of a block the ledger never attempted;
  - a cell run under another bundle, λ0, model or tokenizer;
  - a cell that replayed a trace other than the bundle's for its block and load;
  - a duplicate cell;
  - a valid block missing any of its six cells;
  - an analysed set whose traces offer fewer than 1,000 measured requests at either load. W met the floor over the planned blocks, and a replacement's trace can offer fewer rows than the block it replaces.

## Frozen campaign bundle

Written after calibration and trace generation, before block 1 (`CampaignBundle`, `LoadCampaignBundle`):
- campaign ID; model, model revision, tokenizer revision, chat template, each compared with the registration;
- λ0, and the calibration artifact's path and sha256, recomputed from the artifact's bytes, which must say resolved and the same λ0;
- W, recomputed from the traces;
- the instance price, its source and read time, and other charges per hour;
- each treatment's digest-pinned image, compared with the registration;
- one entry per block and load, replacements included: path, sha256 (recomputed from the bytes that are then parsed), seed (must be the block's), measured rows (recomputed).

The bundle is decoded strictly: unknown, wrong-case, null and missing keys are refused, as in a manifest.

## Budget and the $20 stop rule

Every phase has a ceiling the runner enforces (`PhaseBounds`):

| Phase | Bound |
|---|---|
| setup (launch, two image pulls, model download) | 2,700 s |
| calibration | 30 rungs × (60 + 180 + 120) s = 10,800 s |
| paid preflight, per treatment (start, readiness, 30 requests) | 900 s |
| engine readiness, per start | 600 s |
| drain, per cell | 120 s |
| block (`BlockBoundSeconds`): per treatment two starts and two cells | 3 × (2 × 600 + 2 × (60 + W + 120)) s; 6,480 s at W = 300 |
| teardown | 600 s |

- **Before every block**, `MayStartBlock` requires that spending so far plus **every valid block still needed** at its bound, teardown and the $2 reserve fit under $20. Checking only one more block is not enough.
- **Before block 1**, once W is known, the same check with all six blocks.
- **Absolute teardown deadline:** `TeardownDeadlineSeconds` after launch, whatever phase is running. That is (cap − reserve) ÷ session rate − the teardown bound, which covers setup and calibration too. The session's watchdog must be shown to enforce it before a paid run (release gate).

**This registration's worst case does not fit the cap**, and it does not resolve that:
- `SessionBoundSeconds` at W = 300 is 55,680 s (15.5 h): about $19.13 at the $1.237/h g5.xlarge price recorded on 2026-10-22, before other charges and the $2 reserve.
- The rule above therefore can stop the campaign after an expensive calibration, ending it as an incomplete pilot.
- Most of the bound is engine readiness (600 s, counted twice per visit), which no session has measured on a warm instance; the only recorded figure is a 9 min 31 s cold start on EKS.
- Narrowing the bounds needs that measurement and an amendment of this page.
- **Owner decision (2026-11-15): measure, then amend.** Readiness is measured in the free rehearsal, and this page is amended with tighter bounds before any paid run. The owner did not accept running under the current bound. So a worst case that fits under $20 with the reserve is itself a release gate.

## Release gates (before any paid run)

The registered protocol is not executable at this head (attack item 1). Before a paid run:
- **A complete free campaign rehearsal** against a stub engine, through the real code paths:
  - request serialization with the sampling fields;
  - monotonic timing from intended arrival, with transport-write, last-content and trailer stamps;
  - usage presence recorded apart from the count, and finish reasons;
  - v3 manifests, trace and bundle checks, the ledger, dispositions with failure injection (HTTP errors, broken streams, timeouts, an engine that never becomes ready, a nonconforming completion);
  - `CheckVersionCampaign`, the exact bootstrap and the verdict.

  A two-block rehearsal must expect "incomplete pilot"; showing a verdict needs six blocks.
- **The sender:** done in code, still to be shown in the rehearsal.
  - When a study registers a policy, the replay puts it on every request (`HTTPSender.SetSampling`, from `RequestFields`). A study without one sends the body it always sent.
  - Every row records, on the monotonic clock, the intended arrival (`RequestClock.IntendedNanos`), the transport write, first and last content, and the usage trailer and `[DONE]`. `RequestClock.FromIntended` gives a latency from intended arrival, or reports it absent.
  - Since #587 each row also carries a terminal disposition and usage presence.
- **Replay accepts v3:** done. An empty `matchTolerance` on a v3 manifest is stamped as 0 (`replayMatchTolerance`); every earlier schema is still parsed and range-checked.
- **The writers:** the trace generator, the bundle writer and the v3 manifest writer are done in code.
  - `VersionTrace` and `WriteCampaignBundle` write the bundle (`benchharness version-bundle`), and `VersionCellManifest` writes the cell manifests (`benchharness version-manifests`).
  - Each round-trips through `LoadCampaignBundle`, `LoadManifest` and `CheckVersionCampaign`.
  - **The calibration runner:** done in code (`benchharness version-calibrate`).
    - Each rung waits until the engine's own `vllm:num_requests_running` and `vllm:num_requests_waiting` read 0 (`WaitDrained`). A rung that cannot start drained sends nothing and is invalid.
    - The rung then replays `CalibrationTrace` at the rung's rate. `ObserveRung` reads arrivals, departures, outstanding work and its trend, failures and unresolved requests off the rows' own monotonic clock.
    - Every rung's rows and record are written as it ends. The artifact is written for an unresolved ladder too.
    - It has only been run against stub engines. A live engine is the rehearsal's job, and its readiness the paid preflight's (#594).
- **An engine path** that runs v0.32.0 with the registered settings: done. The `experimental-a10g` profile renders release `v0.32.0` on its pinned digest with either async choice (#586 and this change). What remains is showing it in the free rehearsal.
- **The watchdog** enforces the absolute teardown deadline.

## What answers what

| Source | Item | Answer here |
|---|---|---|
| owner | pilot, 6 blocks, roles of the comparisons | "The question"; `MinRepetitions` 6; `SelectTreatment` |
| owner | v0.32.0; digest and flag reviews filled by the engine-path track | `Engines`, `EngineFlagReviews`, `Unfrozen` |
| owner | SLO 1,000 / 60 ms; 10% benefit, 10% loss, 0.5% guardrail; TPOT descriptive; reject by established harm; cross-load policy | `SLO`, `DecisionRule`, `AssessLoad`, `CombineLoads` |
| owner | keep `priority` | `versionStudyEngine` |
| attack 2, 3 | λ0 criteria, separate budgets, fallback, confirmation, unresolved stop, drained start | "Load"; `CalibrationRule` |
| attack 4 | success-only TPOT | not voting; guardrail; failure categories reported |
| attack 5 | circular checks, readiness, unavailable engines | "Per-request dispositions"; readiness bound |
| attack 6 | calibrated claims | removed; pilot heuristic; exact enumeration |
| attack 7 | benefit and harm thresholds, cross-load | "Pilot decision heuristic" |
| attack 8, review a | frozen bundle, model and tokenizer pinned, artifact contents | `CampaignBundle`; `validateV3`; `CheckVersionCampaign` |
| review b | null values | `checkKeys` refuses a null for any present key |
| attack 9 | attempt ledger | `AttemptLedger`, `AnalysisSet` |
| attack 10 | sample floor | `ChooseWindow` from the traces; realised denominators checked; the analysed set recounted in `CheckVersionCampaign` |
| diff review 3 | replacement numbering, attempt times, analysed floor | `AnalysisSet`; `CheckVersionCampaign` |
| attack 11 | carry-over, cache, readiness, drain, warm-up | `LoadOrder`; "Blocks, order and lifecycle"; warm-up qualification in the bundle check |
| attack 12 | zero and infinity cases, Monte Carlo evaluability, chunking | `OrientedEffect`; `ExactBlockBootstrap`; `GoodRequest` |
| attack 13 | phase bounds, preflight, remaining blocks, teardown deadline | "Budget"; the unresolved overrun stated |
| attack 1, 14 | runner and sender gaps; production adoption | release gates; "what an answer licenses" |
