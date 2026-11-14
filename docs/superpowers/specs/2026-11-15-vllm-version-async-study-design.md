# S1: does a newer vLLM, or its async scheduler, serve this load better than v0.27.1?

Date: 2026-11-15. Status: **registration v1, before any run.** Issue #585.
Study ID `vllm-version-async-2026-11-15` (`StudyVersionAsync` in `internal/bench/study.go`).
No paid run may start under this page while any value in "Not yet decided" below is open; the code refuses every cell until then (`PreflightRefusal`).

Background: the 2026-11-14 serving-benchmark decision (one harness, one judging rule, A/B/C, outcomes adopt / practically equivalent / uncertain / reject, open-loop 0.6 and 0.9 of a measured capacity, at least five paired blocks, first study capped at $20), and the 2026-11-15 audit of the harness before this run (findings cited as "audit N" below).
Both live in the private storage repository; this page restates what it relies on.

## The question

On one A10G serving Qwen2.5-3B-Instruct, at the same offered load, does moving from vLLM v0.27.1 to a newer pinned release change tail latency, per-token latency or SLO goodput, and does turning on async scheduling in that release change them further?
"No improvement" is a result: reject and practically equivalent are as publishable as adopt.

## What is fixed now, what is measured in the session, what is not yet decided

| | Value | Where enforced |
|---|---|---|
| **Fixed now** | arms, engine profile, what may differ, loads 0.6 and 0.9 λ0, workload mixture, sampling policy, campaign seed `20261115`, 5 planned blocks + at most 2 replacements, warm-up 60 s, window ≥ 300 s and ≥ 1,000 pooled requests, timeout 60,000 ms whole-request, dispatch-lag tolerance, endpoints and their populations, decision rule shape, invalidation and rerun rules, interval level 90%, 10,000 resamples, cap $20 with $2 reserve | `versionAsyncDesign`, `versionStudySampling`, `LoadManifest` |
| **Measured in the session, then frozen** | λ0 (capacity on treatment A), the window length W derived from it, the instance price | calibration artifact whose sha256 every cell's manifest carries (`CellIdentity`) |
| **Not yet decided (owner)** | B's vLLM version and image digest (C uses the same), SLO TTFT, SLO TPOT, the four equivalence margins | `Unfrozen` lists exactly these; `PreflightRefusal` refuses every manifest until they are set |

Proposals for the open values are under "Owner decisions" at the end; they are proposals, not registered values.

## Arms

Three treatments, each at two loads: six arms, named `<treatment>-<load>` (`A-l060`, `A-l090`, `B-l060`, `B-l090`, `C-l060`, `C-l090`).

| Treatment | Engine | Async scheduling |
|---|---|---|
| A | vLLM v0.27.1, `vllm/vllm-openai@sha256:0a51ea5b…bfd967` (the digest `VLLMV0271Digest` pins) | off |
| B | a newer pinned vLLM release, by digest (**owner decision**) | off |
| C | the same image as B | on |

**What must not differ.** Every treatment runs the validated `v0.27.1-a10g` profile from `internal/controller/inference_engine.go` (`measuredA10GArgs` with prefix caching off): `--dtype=half`, `--max-model-len=16384`, `--max-num-seqs=64`, `--gpu-memory-utilization=0.90`, `--no-enable-prefix-caching`, `--max-num-batched-tokens=512`, `--scheduling-policy=priority`; same model and revision, same instance, same client, same workload per block, same sampling, same timeout.
`versionStudyEngine` builds all three from one function and `EngineSettings.Diff` refuses a manifest that differs from its treatment in any field.

**What may differ.** A→B: the version and image only. B→C: async scheduling only.
Everything a release changes internally without a flag (kernels, CUDA graph policy, default scheduler internals, tokenizer handling) is part of the treatment "version"; it is not controlled and the result does not attribute an effect to any one of those internals.

**Why the profile keeps `--scheduling-policy=priority`.** It is the validated profile, and changing it for this study would make A not the incumbent.
This workload sends no `priority` field, so every request has the same priority; the policy is identical across arms.

**No gateway.** Requests go straight to the engine's OpenAI endpoint, so the comparison is the engine's.
The manifest's `gatewayURL` is the engine URL for this study, and a v3 manifest that carries gateway thresholds, `longThreshold` or `matchTolerance` is refused.

Note the controller cannot run B or C today: the CRD pins the v0.27.1 digest and the controller forces `--no-async-scheduling` (audit, "capabilities").
This page does not change that; the session runs the engine outside the CRD with the same flags, or the controller gains an experimental path. That is a separate change.

## Comparisons

1. **B vs A**: does the version alone change the outcome?
2. **C vs B**: does async scheduling change it on the new version?
3. **C vs A**: is the full upgrade adoptable over the incumbent?

The operational decision is read from C vs A (or B vs A if C is rejected); 1 and 2 explain it.

## Load: one capacity, measured on A, frozen before the first block

**Decision: one common λ0, measured on treatment A only.**
The question is what each engine does to the same traffic, and traffic does not change when an engine is upgraded.
With a per-arm λ0, "0.9 λ0" would be different offered work for each arm, and a faster engine would be tested at a higher rate: its latency and goodput would be compared at a load the slower engine never saw, and the ratio would mix "how much capacity" with "how good at a given load" (audit, "capabilities").
With a common λ0, an engine with more capacity shows it as lower tail latency and higher goodput at 0.9 λ0, which is the effect a deployer would get.
An engine with less capacity than A is pushed past its own saturation at 0.9 λ0, and that is reported as what it is: worse at A's load.
A is chosen because it is the incumbent and the only treatment whose capacity is meaningful before the study.
B's and C's own capacities are not measured by this study; if budget remains after the confirmatory blocks, a descriptive ladder on C may be run and is labelled exploratory.

**Calibration procedure (arm A, in the session, before block 1).**
- Fresh A engine, readiness as below, then a sequence of rungs. Each rung: a 60 s warm-up and a 180 s measured window at an open-loop Poisson rate, with this study's workload mixture and sampling, from calibration seeds `2026111500 + rung` (never used by a block).
- Rates: start at 0.5 req/s, multiply by 1.5 until a rung fails, then bisect between the last passing and the first failing rate until their ratio is at most 1.05. At most 10 rungs.
- A rung **passes** when, over its measured window: every request completed successfully within the timeout (no HTTP error, stream error or timeout), and the median E2E of the window's last third is at most 1.25 times the median E2E of its first third (no growing backlog).
- **λ0 is the highest passing rate.** It is a sustainable-throughput capacity, deliberately independent of the SLO so that λ0 does not depend on a number still being decided.
- The calibration artifact (rungs, per-rung counts and medians, the chosen λ0, engine identity, timestamps) is written and hashed before block 1 starts. Every cell's manifest carries λ0 and that sha256 (`CellIdentity.CapacityRequestsPerSec`, `CapacityArtifactSHA256`); `LoadManifest` checks the offered rate is exactly the load's fraction of it, and `CheckVersionCampaign` refuses a campaign whose cells name two capacities.
- One ladder on one engine start is a single measurement; its noise moves both loads of every arm equally, which is acceptable because λ0 sets the operating points and is not itself an endpoint.

**Loads.** l060 = 0.6 λ0, l090 = 0.9 λ0. 1.2 λ0 and bursts are overload exploration under a separate study ID; they are not arms here and no row of them can be filed under this study.

## Workload

- One request class, Poisson arrivals at the cell's offered rate, no tenants beyond the one the trace format needs.
- Input length drawn per request: 256 tokens (p = 0.5), 1,024 (0.3), 2,048 (0.2), sent as the character lengths `hack/input-length-resolution.json` resolved inside the v0.27.1 image (1,174, 5,183 and 10,532 characters; `versionStudyExactTokens`).
- Output length drawn per request, independently: 64 tokens (p = 0.5) or 256 (0.5), produced exactly (sampling below).
- **One workload per block and load, shared by A, B and C** (audit 2, 21). Its seed is `WorkloadSeed(20261115, block, load)`; every block gets a different seed, so the spread across blocks includes the draw of the arrival process. Each trace file is generated once and replayed by all three treatments; `CheckVersionCampaign` refuses a block whose treatments replayed different traces and two blocks that replayed the same one.
- Each trace holds the warm-up rows followed by the measurement rows, one continuous arrival process (see "Warm-up").

## Sampling and stop condition (audit 12)

Registered as `versionStudySampling` and carried in every manifest; `LoadManifest` refuses a manifest whose policy differs in any field or leaves one out.

Why it has to be explicit: the harness has never sent a sampling parameter, and v0.27.1 serving this model logged on 2026-10-24 that its defaults "have been overridden by the model's generation_config.json: {'repetition_penalty': 1.05, 'temperature': 0.7, 'top_k': 20, 'top_p': 0.8}" (`hack/mps-capability/2026-10-24-run2/m5c-run/mpscap/diag/logs-engines-m5c-a.txt:59`).
So every earlier run sampled at temperature 0.7, and whether a newer release applies the same file the same way is exactly the kind of change this study must not mistake for a scheduler effect.

| Field | Value | Why |
|---|---|---|
| temperature | 0 (greedy) | output does not depend on any random state |
| top_p | 1 | sent explicitly so the model's `generation_config` cannot substitute its 0.8 |
| repetition_penalty | 1 | changes logits even under greedy; the model's `generation_config` would otherwise apply 1.05 |
| seed | omitted (`omit-greedy`) | irrelevant under greedy; a per-request seed can make an engine build a per-request generator, a performance treatment of its own |
| ignore_eos | true | an engine that stops at EOS would shorten the workload differently per version |
| length policy | `exact-cap`: `max_tokens` = `min_tokens` = the row's cap | output length is a property of the workload, identical across arms |

top_k is not sent: under greedy decoding it has no effect, and its "disabled" value has changed spelling across releases, so sending it risks a refusal that tests nothing.

**Interface for the sender** (owned elsewhere; this page defines it, `internal/bench/sampling.go` implements it):
- `Study.Sampling` is nil for every earlier study, which keeps their request bodies byte-for-byte unchanged.
- When it is set, the sender calls `SamplingPolicy.RequestFields(row)` and marshals the returned `SamplingRequestFields` into the chat-completions body, taking `max_tokens` and `min_tokens` from it rather than from its own fields. JSON names are the engine's: `max_tokens`, `min_tokens`, `temperature`, `top_p`, `repetition_penalty`, `seed` (omitted unless the policy is `row-index`), `ignore_eos`.
- `SamplingPolicy.CheckCompletion(cap, engineOutputTokens, finishReason)` is the per-request check that the policy took effect. The preflight runs it on every preflight request; the analysis runs it on every successful measured request (see invalidation rule 4).

## Blocks, order, engine lifecycle

- **Blocks.** 5 planned (`MinRepetitions` 5, `PublishesInterval` true). A block is all six arms: each treatment visited once, running l060 then l090.
- **Treatment order per block** is `ArmOrder(20261115, block)`: the six orders of A, B, C are shuffled once by the campaign seed and dealt to blocks in turn, so blocks 1 to 6 never repeat an order. For this seed: block 1 B A C, block 2 B C A, block 3 C B A, block 4 A C B, block 5 A B C, block 6 C A B, block 7 B A C. Five blocks cannot balance three treatments over three positions exactly; dealing without replacement is the closest a fixed count gets, and the order is fixed before any run so it cannot be redrawn after a bad block. Each manifest records its position, and `LoadManifest` refuses a position that is not the seeded one.
- **Load order is fixed, l060 then l090, for every treatment.** Randomising it per visit would give the treatments different histories; fixing it gives every treatment the same carry-over, which then cancels in the comparison.
- **Every visit starts a fresh engine process**, A included, so "freshly started" is the same condition for all arms. Readiness: `/health` returns 200, then one unrecorded priming request per input length. Then for each load: the trace (warm-up then measurement), then drain until nothing is in flight (bounded by the timeout), then the next load. The engine is stopped after l090.
- **Identity before execution** (audit 3, 17). Each cell's v3 manifest is written before its trace starts and records campaign ID, block, position, order seed, λ0 and its artifact hash, the engine settings and the sampling policy (`RunManifest.Cell`, `Engine`, `Sampling`). Pairing reads these, never a file name.

## Warm-up and its exclusion boundary

- Every cell's trace starts with 60 s of arrivals at the cell's own rate, then W seconds of measured arrivals, as one continuous Poisson process.
- **The boundary is the intended arrival time**, `PhaseOf(offsetMs, λ0)`: a row with offset < 60,000 ms is warm-up; a row with offset in [60,000, 60,000 + W·1000) is measured. Completion time never decides membership; filtering by completion would drop the slow warm-up requests that finish inside the window and keep the reverse, differently per arm.
- Warm-up requests are sent, recorded, held to the same invalidation rules 1 and 6, and excluded from every endpoint.
- **W = max(300 s, ⌈1,000 / (5 × 0.6 × λ0)⌉ s)** (`MeasureSeconds`): the same window at both loads, long enough that the five planned blocks at the lower load pool at least 1,000 measured requests per arm, the floor below which the 2026-11-14 decision calls a p99 exploratory. W is computed from λ0 once and recorded with it.

## Endpoints

All latencies are client-observed, from durations on the client's monotonic clock (audit 11), relative to each request's **intended arrival** (its trace offset from the replay origin), so a late dispatch is charged to latency rather than hidden (audit 10). The population of every endpoint is the cell's measured rows, P.

| Endpoint | Per request | Population and percentile | A failure |
|---|---|---|---|
| `ttft_p99` | first content byte − intended arrival | all of P, nearest-rank p99, pooled over the analysed blocks | no first content byte: +∞. A first byte that was observed is kept even if the stream later failed (audit 6) |
| `tpot_p99` | (last content byte − first content byte) / (engine `completion_tokens` − 1) | successful rows of P, nearest-rank p99, pooled | excluded; failures are counted by the other three endpoints |
| `e2e_p99` | last content byte − intended arrival | all of P, nearest-rank p99, pooled | +∞ |
| `goodput` | success ∧ TTFT ≤ SLO_TTFT ∧ TPOT ≤ SLO_TPOT | count over P divided by the offered window W × blocks; requests/s | not good |
| `cost_per_slo_request` | | price × W × blocks / good count | see below |

- **Success** is HTTP 200, a stream ending in `[DONE]`, an engine usage chunk with `completion_tokens` equal to the cap and `finish_reason` `length`. A failure is an HTTP error, a stream error, or a timeout of the whole-request deadline; each is an outcome of the arm, never removed.
- TPOT and E2E end at the last **content** frame, not at `[DONE]` or the usage trailer, so a slower trailer is not counted as slower generation (audit 8). The trailer delay is recorded and reported descriptively.
- TPOT uses the engine's own token count (`OutputCount` is `engine-tokens-v2` for this study, audit 1): the newer engine may put several tokens in one frame, and frames would understate its token rate.
- Because +∞ enters TTFT and E2E, an arm that fails more than 1% of P has an infinite p99: failures cannot improve a tail (audit 6). TPOT is read beside the success fraction, which goodput carries.
- Dispatch-based TTFT (from the transport write) and the inter-content-frame gap distribution (from individual gaps, not per-request means) are reported descriptively and do not vote.

**Cost.**
- Price: the on-demand hourly price of the session's instance type in its region, read from the AWS Price List API at session start and stored in the session record (the multi-pod-ddp session read g5.xlarge at $1.237/h this way on 2026-10-22). One price for every arm.
- **Steady-state cost per SLO-meeting request** = price per second × measured seconds / good requests. With a common offered window it equals price / goodput exactly, so it carries no information goodput does not; it is reported and does not vote.
- **Billed cost per SLO-meeting request** charges each arm its billed seconds: for each of its visits, engine process start to the end of the l090 drain. It includes engine start-up, which a newer version may change. Reported descriptively per treatment, because start-up is paid per visit and its total depends on the schedule.
- Whole-session spend (setup, calibration, preflight, all blocks, teardown) is reported once, not divided among arms.
- The same GPU rented for the same time costs the same; a latency gain is a cost gain only through goodput, which is why goodput, not cost, votes.

## Analysis

- **Blocks analysed:** the complete blocks only, those with all six cells valid (`CheckVersionCampaign`). At least 5 are required; fewer means the result is **not confirmatory** and only descriptive numbers may be published (audit 14).
- **Effect** of a candidate over a reference at one load: the ratio of pooled statistics. Oriented so positive is better for the candidate: d = ln(reference p99 / candidate p99) for the three latencies, d = ln(candidate goodput / reference goodput) for goodput.
- **Interval:** percentile block bootstrap, 10,000 resamples of the complete blocks with replacement, the same block indices for both arms, pooled statistics recomputed per resample; the 5th and 95th percentiles (90% two-sided). With five blocks there are only 126 distinct resamples, so the interval is coarse; it is a registered decision device, not a calibrated 90% confidence interval.
- A resample in which the **reference** statistic is infinite or zero makes d undefined; the endpoint is then **not evaluable** for that comparison and load, and no resample is dropped to make it evaluable (audit 24). A candidate p99 of +∞ against a finite reference is d = −∞, a valid "worse".

## Practical-equivalence margins and the decision rule

For each voting endpoint e (`ttft_p99`, `tpot_p99`, `e2e_p99`, `goodput`) a relative margin m_e is registered (**owner decision**), and δ_e = ln(1 + m_e).

**Endpoint verdict** from its 90% interval [lo, hi] of d:
- **Equivalent**: −δ < lo and hi < δ.
- **Better**: lo > 0, and not equivalent.
- **Worse**: hi < 0, and not equivalent.
- **Non-inferior**: lo > −δ, and none of the above.
- **Uncertain**: everything else, including not evaluable.

A difference that is statistically clear but inside the margin is equivalent, not better or worse.

**Comparison verdict at one load:**
- **Reject**: any voting endpoint is worse.
- **Adopt**: no endpoint is worse, every endpoint has lo > −δ (equivalent, better or non-inferior), and at least one is better.
- **Practically equivalent**: every endpoint is equivalent.
- **Uncertain**: anything else.

**Across the two loads:** reject if either load rejects; adopt if one load adopts and the other adopts or is equivalent; practically equivalent if both are; otherwise uncertain.

Every one-sided bound is a 5% test, so equivalence is a TOST at 5% and non-inferiority a 5% test per endpoint. Adoption needs only one of four endpoints better, which inflates the chance of a spurious "better" across endpoints; no correction is applied, and the report prints every endpoint verdict beside the comparison verdict so that an adopt resting on one endpoint is visible as such.
With five blocks, power is low; "uncertain" is the expected outcome unless an effect is large.

## Invalidation

Applied to every cell of every arm, at both loads, with the same predicate, before any endpoint is computed and without looking at endpoint values (audit 15). One invalid cell makes its whole block incomplete.

1. **Incomplete schedule** (audit 4): some trace row has no terminal record, has two, or was never dispatched (cancelled or not sent). Every row needs exactly one of success, HTTP error, stream error, timeout.
2. **Dispatch lag** (audit 10): lag = transport write − intended arrival, per row; p99 over P above 10 ms or maximum above 100 ms invalidates the cell. These bounds are fixed now; the free CPU rehearsal below must show the client meets them at 0.9 of a plausible λ0 before the paid session.
3. **Missing usage** (audit 7): a successful row whose usage chunk is absent or carries no `completion_tokens`, or whose `prompt_tokens` differs from the registered count for its length.
4. **Sampling not in effect** (audit 12): a successful row that fails `CheckCompletion`. If this happens at preflight the campaign does not start.
5. **Identity** (audit 5, 13, 17): a manifest that `LoadManifest` refuses is never run; the effective engine settings read from the running engine (its version endpoint and its startup log of non-default arguments) differ from the manifest; any row lacks the cell's identity.
6. **Recorder failure** (audit 18, 19): any write or durability error, or recorder backlog overflow.

**Not invalidating:** an HTTP error, stream error, timeout, engine crash or failure to become ready during a visit, when caused by the engine. These are outcomes of the arm: they enter as +∞ and as lost goodput. A crash is invalidating only when the instance's own event log shows an external cause (instance retirement, host failure), decided from that log alone.

**Censoring** in the harness sense (a request with no observed outcome) is invalidation rule 1; a timeout is an observed outcome and is never censored away.

## Rerun policy

- An incomplete block is **replaced**, not repaired: the next block index (6, then 7) runs in full with its own seeded order and workload. At most 2 replacements (`MaxReplacementBlocks`); a manifest for block 8 or later is refused.
- Replacements run after the planned blocks. A valid cell or block is never rerun, and there is never a choice between two valid blocks.
- Invalid blocks stay in the archive with their reason and are listed in the report.
- If more than 2 blocks are invalid, or the cap stops the campaign first, the result is not confirmatory.

## Preflight and rehearsal

- **Free, before the paid session:** a CPU rehearsal of the whole campaign shape against a stub engine (all six arms, two blocks, manifests through `LoadManifest`, cells through `CheckVersionCampaign`), which must also show dispatch lag within rule 2 at the planned rates.
- **Paid, before block 1:** after calibration, per treatment, 30 requests at a low rate with the registered sampling, checked by rules 3 to 5 and `CheckCompletion`; the engine's `prompt_tokens` for the three input lengths must equal `versionStudyExactTokens`, which also catches a newer version's chat template changing the prompt. A failure stops the session before any block.

## Budget and the $20 stop rule

- Cap $20 for the whole session, calibration and preflight included; $2 held back for teardown and the last billed interval. Before each block: `MayStartBlock(spent, worst)`, where `spent` is price × elapsed since launch plus other session charges so far and `worst` is the larger of the planning estimate and the costliest completed block. A block that would cross $18 is not started.
- Planning estimate (not measured): per visit, an engine restart R plus two cells of 60 s warm-up + W + up to 60 s drain. At W = 300 s and an assumed R of 3 min, a block is about 51 min, about $1.05 at $1.237/h. Seven blocks, a 40-minute calibration and 30 minutes of setup and image pulls come to 427 min, about 7.1 h and $8.8 for the instance. The engine start-up time on an instance that already holds the image and the model is not measured; the nearest recorded figure is the 9 min 31 s the conformance engine took to start on EKS (`2026-10-12-serve-one-request-on-eks-design.md`). The rule uses observed block costs from block 2 on.
- The session's existing watchdog and teardown controls apply; the stop rule does not replace them.

## What a result licenses

A verdict says: on one g5.xlarge A10G, Qwen2.5-3B-Instruct at tokenizer revision `aa8e72537993ba99e69dfaafa59ed015b17504d1`, the `v0.27.1-a10g` flags, this synthetic workload (input 256/1,024/2,048 tokens, exact outputs of 64/256, greedy), open-loop Poisson arrivals at 0.6 and 0.9 of A's measured sustainable throughput, sent directly to the engine, candidate X is adopt / practically equivalent / uncertain / reject against reference Y, by the endpoints and margins above.

It does **not** license: other GPUs, models, prompt or output distributions, natural stopping, prefix caching, overload (1.2 λ0, bursts), multiple replicas, the gateway path, any claim about B's or C's capacity (only A's is measured), attributing an effect to a particular internal change of the release, or any claim about GPU utilisation.

## Audit findings addressed here

| Finding | At the study-definition level | Enforced by |
|---|---|---|
| 1 frame count | the study is on `engine-tokens-v2`; the frame-rule test now covers an explicit historical list, and a new study must state its contract | `StudyVersionAsync`, `TestHistoricalStudiesKeepTheFrameRule`, `TestNewStudiesStateTheirContract` |
| 2 workload pairing | one trace per block and load, seeded, shared by A/B/C | `WorkloadSeed`, `LoadManifest` (seed), `CheckVersionCampaign` (same trace within, distinct across) |
| 3 block identity | campaign, block, position, seed, λ0 recorded before execution | `CellIdentity`, `CheckVersionCampaign` |
| 12 sampling | frozen greedy exact-length policy; sender interface | `SamplingPolicy`, `LoadManifest` |
| 13 manifest validation | strict decoding (unknown and wrong-case keys refused), schema enum v2/v3, primary endpoint and timeout scope enums, finite tolerance, typed engine settings, one full comparison with the registration | `decodeManifest`, `validateFields`, `validateV3` |
| 14 repetition floor | fewer than 5 complete blocks is an error, not a warning | `CheckVersionCampaign` |
| 15 per-block censoring | one validity predicate for every cell, arm and endpoint; any invalid cell makes the block incomplete | this page; the report must implement it |
| 17 mixed settings | per-cell engine, sampling, timeout and capacity compared with the registration; one capacity per campaign | `validateV3`, `CheckVersionCampaign` |
| 21 trace reuse | a different workload seed per block, refusal of two blocks sharing a trace | `WorkloadSeed`, `CheckVersionCampaign` |

**Capabilities list:** this page registers the protocol, the capacity definition and calibration rule, the campaign order and rerun rules, the warm-up boundary, goodput and cost, and the decision rule.
It does not build them. Still to build elsewhere, before a paid run: an engine path that can run B and C, the calibration runner and artifact, a campaign runner that writes v3 manifests (`gen-trace` and `prepare-traces` still write v2 and will be refused for this study), a trace generator for this workload, the sender fields (intended arrival, transport write, last content, `[DONE]`, usage presence separate from count, finish reason, monotonic durations), the cell validity predicate in the report, and the bootstrap and verdict over the four endpoints.

## Owner decisions

Each is listed by `Unfrozen()` until set, and the registration is amended in a commit before the session.

1. **B's version and digest.** A release newer than v0.27.1 whose async-scheduling flag exists and whose default matches what B and C set explicitly. Proposal: the newest stable release at amendment time, pinned by digest, with the session reading its effective settings back.
2. **SLO.** Proposal: TTFT ≤ 1,000 ms and TPOT ≤ 60 ms. Both should be set from the product target, not from A's measured latency, or goodput becomes a statement about A.
3. **Margins.** Proposal: 10% for each p99 latency, 2% for goodput. A smaller latency margin asks five blocks for more precision than they can give and turns most results uncertain.
4. Whether to keep `--scheduling-policy=priority` (the validated profile, the current registration) or use `fcfs` for all arms.
