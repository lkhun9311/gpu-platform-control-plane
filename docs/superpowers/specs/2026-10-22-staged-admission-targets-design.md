# Staged admission targets: how close to isolation can the shared engine get? A draft registration

Written 2026-10-22.
**DRAFT. Not registered until the owner approves it; nothing may be bought under it, and no cell has run.**
Stage A2 of the staged successor; stage A1 is `2026-10-22-staged-admission-feasibility-memo.md`.
No past verdict changes: M5-b stays closed at 83.7x, Finding 9's three studies and run 3 stand as recorded, and this page asks a new question with its own design.

## The question

On one A10G, vLLM v0.27.1, at the diagnostic's frozen load, which stage of this ladder does the gateway's serial-prefill hold reach, with the engine's per-request prefill cap set to 384, 256, 192 or 128 tokens, while keeping the guard bars?

| stage | target, in every block | registered before any data |
|---|---|---|
| **T0** | hold at 384 (hold-cap, run 3's configuration) shows no regression against run 3, with zero refusals | yes |
| **T1** | some hold arm's premium TTFT p99 at most **3x** the same block's isolated engine | yes |
| **T2** | at most **2x** | yes |
| **T3** | at most **1.25x** | yes |

Every stage has the same guard bars, against the same block's unshed arm: aggregate throughput at least 95%, and contender work and contender output each at least 75%.
The answer is the highest stage reached, and by which arm, or which stage was not reached and on which line.

## Where it runs, and why not the product path

The lab apparatus, as the diagnostic, v26 and v27 ran: one g5.2xlarge Spot in gpu-lab, the pilot matrix, engine and gateway on one kind cluster on the instance.
- The product renders exactly one cap: `--long-prefill-token-threshold=384` from a constant (`internal/controller/inference_engine.go:78`), so 256, 192 and 128 cannot be asked on EKS without a product change.
- Only the lab engine writes the step log (`pilot_step_logger.PilotStepLoggingScheduler` in the engine's non-default arguments), and the guard bars below and the cap check are read from it.
- The lab has the isolated R1 cell the ratios need; run 3 measured no isolation.

**T0 is therefore operationalised as run 3's own lines, reproduced on this session's traces**, not as a comparison of milliseconds across two platforms and two instance types.
Run 3's lines, per block, against that block's off: premium p99 crossed upper end at most ln 0.85; every contender completes; contender completion p50 at most 1.5x off's; p95 at most 25 s; zero refusals of any kind; zero preemptions (`hack/eks-serve/holdcap-study/runs/20261021T021149Z/README.md`, the registered table).
"No regression" adds one number: hold-384's pooled premium p99 over off's pooled, at most **0.351**, which is run 3's worst block, 0.305, plus 15%.
Owner decision 1 is whether that is what "no regression against run 3" should mean, or whether the study should instead run on EKS after a product change that renders the cap per object.

## Arms

Each on its own fresh engine, budget `max_num_batched_tokens` 512 and 64 slots in every arm, priority bound by tier in every arm, as in the diagnostic.

| arm | admission | `long_prefill_token_threshold` | why |
|---|---|---|---|
| **R1** | off | none | isolation: the block's premium rows alone; the denominator of every ratio |
| **off** | off | none | the unshed arm: the denominator of every guard bar |
| **hold-384** | serial-prefill, longest hold 25 s | 384 | T0, and the reference the other caps move away from |
| **hold-256** | the same | 256 | the screen's only arm predicted to reach T1 inside the guards |
| **hold-192** | the same | 192 | the screen puts it at the T2 edge, 2.02 to 2.08, inside the inherited guards and failing the all-token throughput on one trace |
| **hold-128** | the same | 128 | the smallest cap that keeps a 68-token premium in one chunk with room for one more; the screen puts it below 2x by building a queue |

No cap-only arm: the diagnostic measured cap alone worse than off at 384, and the replay predicts the same at every smaller cap (`data/2026-10-22-staged-admission-feasibility/ladder-1.0.txt`, the `cap-only` rows).
This study asks how far the combination reaches, not which half does it, so a stage reached is attributed to the combination at that cap and nothing narrower.

astra's independent draft crosses caps {none, 128, 256, 384} with the hold {off, on}, eight arms and isolation, 27 cells, so each stage reached can be attributed to the cap, the hold or their interaction; it has no 192.
That costs 9 more cells, about 1 h 25 m and $1 more expected, and its hard stop is 8 h 43 m against 5 h 50 m here.
Owner decision 8 is attribution at that price, or this draft's narrower arms with 192 for resolution at the T2 edge.

## Load and seeds

The diagnostic's load, unchanged: premium 9.25/s and contender 0.5/s for 420 s per cell, 200 and 40,000 characters frozen at 68 and 7,695 engine tokens, 64 and 16 output tokens, a 30 s client timeout, the 600-connection pooled sender.
**Seeds 901, 902 and 903**, one block each; none has been used in this repository (the pilot used 801 to 803 and its stage B, the diagnostic 851 to 853, v26 861 to 863, v27 871 and 881 to 883, the unbought v24 draft 841 and 842).
Fresh seeds because A1's screen and every cap choice above were made on 851 to 853, and a study judged on the traces its arms were chosen on is judged on its own training data.
Owner decision 5 is whether to trade that for direct comparability with run 3 by reusing 851 to 853.

Each block is R1, off and the four hold arms, six cells, in the matrix's hashed order of seed, stage, block and arm, printed and frozen on this page before purchase: 18 cells.
R1 runs in every block rather than once, so each block's ratios have a denominator measured within the hour, not at the session's start.

## Estimands

- **Premium TTFT p99, per cell, at both clocks**: from the request's scheduled instant (the upper end, `sched hi`) and from its gateway arrival (the lower end, `arrival lo`), nearest rank over every premium request the trace offered, a failed, timed-out or incomplete one at +inf, as the scorer defines success (`hack/prospective-pilot/pilot_report.py`, `is_success`).
- **Isolation ratio, per block**: an arm's `sched hi` p99 over the same block's R1 `arrival lo` p99, the crossed and unfavourable pairing the diagnostic used against off; a request whose dispatch lag exceeds 13 ms is uncertain and is bounded as the scorer's crossed box bounds it, at +inf in the numerator and zero in the denominator (`hack/prospective-pilot/pilot_report.py`, the lag box).
- **Off ratio, per block**: the same pairing against off, for T0's line.
- **Guard bars, per cell against the same block's off**, in the meanings the price-of-protection safeguards gave them, from which the successor's bars descend (`2026-09-05-the-price-of-protection.md:209-210`; `2026-10-06-m5b-stays-closed-and-what-a-successor-needs-first.md`, section 3), over a shared window from the cell's replay origin to 420 s:
  - **aggregate throughput**: output tokens of successful streams, both tenants, whose last content falls inside the window, a completed stream credited once and a partial one at zero, at least 0.95 of off's;
  - **contender output share**: the contender's part of that output, as a share of the arm's total, at least 0.75 of the same share under off;
  - **contender work**: the contender's prompt tokens in steps the engine's step log shows starting inside the window, at least 0.75 of off's.
  A token belongs to a tenant by its request's `add` record; a scheduled step whose request has no `add` record makes the cell untrusted, and every denominator must be positive.
- **Beside them, reported and not judged for T1 to T3**: every token the engine scheduled in the window, prompt and output, against off's (the all-token throughput); Finding 9's contender limits (completion, p50, p95); hold refusals; the capped prefill's duration per contender from the scheduler's add to the end of the step that took its last prompt token; 64-slot occupancy and KV usage from the 1 s samples; and each step's composition by cap.

### Which bar binds at this load, under each meaning

The load's output is premium 9.25/s × 64 against contender 0.5/s × 16 tokens, 592 against 8 a second, so with the premium's output unchanged, a contender output share of 75% of off's leaves aggregate output at 99.66%: the aggregate bar cannot see the contender, and the two 75% bars are the guards that bind (astra's arithmetic, which I checked).
Read instead as every token processed, the contender's tokens were 73.5% to 77.7% of the total in the diagnostic's off cells (`data/2026-10-22-staged-admission-feasibility/verify_codex.txt:6-8`), so 95% would need about `1 − 0.05/0.735 = 0.932` of the contender's work, a materially stricter contract.
The draft registers the inherited meaning and publishes the other beside it; A1's screen puts hold-192 inside the guards under the first and outside under the second, so the choice moves a result and is owner decision 4.

## Validity, in every cell, kept apart from outcomes

v26's lines as frozen for purchase, through the same functions: the cell is the registered one by manifest, trace hash and row identity; it is present, not refused and eligible; largest dispatch lag at most 50 ms and at most 0.1% of premium requests above 13 ms; the gateway's arrival-to-record and premium arrival-to-decision p99 at most 13 ms and maximum at most 50 ms; no premium success without gap evidence; every contender the gateway admitted appears in the step log.
Added for this study:
- **the cap is the arm's**: the engine's non-default arguments name exactly the arm's `long_prefill_token_threshold`, or none for R1 and off, and no contender chunk in the step log exceeds it;
- **the hold is the arm's**: every contender decision in a hold cell carries a serial-prefill reason, and none in R1 or off;
- **R1 is isolation**: no contender row offered, and its premium rows are the block's trace's premium rows byte for byte;
- off's premium loss under 0.5% and its contender completion at least 95%, because off is every guard bar's denominator.

A failed or unscorable validity line in any cell makes the verdict inconclusive; no stage is read from an incomplete session.

## Reading the stage

In this order:
1. **inconclusive: <cell>: <line>** for a missing or extra cell or any failed or unscorable validity line.
2. **T0 not reached: block <b>: <line>** when hold-384 fails any of run 3's lines in any block, or its pooled off ratio exceeds 0.351. The other arms' ratios and guards are still published, but no higher stage is claimed: the session's reference did not reproduce, so its distances from isolation are not comparable with anything this repository has said.
3. Otherwise the highest k in T1, T2, T3 for which some hold arm, in every block, has its isolation ratio at most the target, passes all three guard bars, and had zero preemptions; the verdict names the stage and every arm that reached it.
4. **T0 reached; T1 not reached** otherwise, with each arm's worst block and first failing line.

A stage is per block, every block, because three traces pooled can hide one that failed; the pooled ratios are published beside it.

**The alternative reading, astra's, which the owner chooses between (owner decision 7).** astra drafted the stages as nested gates on each candidate arm: a cap reaches T1 only after it has itself passed T0, which means run 3's whole contract including Finding 9's contender limits, and its tail is no worse than hold-384's.
As drafted here, T0 is a property of the reference arm, and T1 to T3 carry only the ladder's guard bars.
The two readings give different answers on A1's screen: hold-256 reaches T1 as drafted, but its contender median on trace 852 is 2.54 times off's (`data/2026-10-22-staged-admission-feasibility/ladder-1.0.txt:21`), so under the nested reading it fails T0 and nothing above T0 is reachable at this load.
Which reading is meant changes what a pass licenses, not only whether one occurs, so it is fixed before the freeze, not after the result.

## Before purchase

Built and rehearsed free, in this order, and each step committed before the next:
1. The study's registration in `internal/bench/study.go`, stage G in `hack/lib/prospective-pilot.sh` with the six arms and their caps, the engine validator accepting each cap only in its own arm, and the traces for 901 to 903 generated and their checksums frozen in the scorer and the plan, which a test keeps equal.
2. `pilot_report.py ladder`: every line above, with a test per line that fails when the line's one input is changed, and a mutation of each guard bar's window.
3. The replay's prediction on the frozen traces, recorded on this page before purchase, at paces 1.00, 1.0205, 1.03 and 1.10, by a `simulate.py ladder` command ported from A1's `ladder.py` with a test.
4. Every cell on kind, twice, with file accounting complete; the stub predicts nothing and only the apparatus is judged.
5. codex `gpt-6-astra`'s cold attack on this page and a bare `codex review --commit` of each scorer commit, reconciled row by row by me.

**The purchase gate is the apparatus and T0's reproducibility, not a predicted pass above it.**
The purchase stops if the replay on the frozen seeds at 1.0205 predicts hold-384 failing any of run 3's lines; a seed is never swapped for a lighter one.
It does not stop because the replay predicts T1 to fail, or proceed because it predicts T1 to pass: buying only predicted successes would select the outcome.

## In the session

- Limits by the pilot's allowance method with its arm time of 920 s: `1.25 × (200 + 18 × 920 + 12) = 20,965 s`, a hard stop of 5 h 50 m, acquisition deadline 6 minutes before it, backstop 10 minutes after, `study-deadline` 20 minutes after.
- A block cut by the deadline is reported and not scored; the verdict needs all 18 cells.
- One login, one session, under the 12 h rule; no cell is repeated, and no cap is added or changed after the first cell runs.

## After the verdict

- **T1 not reached at any cap**: this lever does not bring the premium tail within 3x of isolation at this load inside the guard bars, and no further cap is tried under it.
- **T1 reached, T2 not**: a smaller cap is not the next step, because A1 shows the hold's service time passing the contender's arrival interval below 192; the next question is a different lever (an engine-side change that lets waiting premium work into the budget at a chunk boundary) or a lighter load with its own reason, each a new registration.
- **T2 or T3 reached**: A1 predicts neither inside the guard bars, so before any claim the step logs are read for the composition that produced it, the cell is re-scored by a separate script, and astra attacks the result cold.

## Cost and time

Measured cell times on this apparatus: the diagnostic's cold first cell 881 s and its others 537 to 559 s (`2026-10-08-measuring-prospective-admission-design.md`, v26's limits paragraph).
Expected session: `200 + 881 + 17 × 560 + 12 ≈ 10,600 s`, about 2 h 57 m; hold-128 cells may add up to 30 s each while unfinished contenders time out.
Expected cost about **$2.0** at the design page's expected $0.6824/h for a g5.2xlarge Spot, and at most about **$6.6** at its $1.1324/h cap over the full hard stop (design page, pilot "Cost").
The account's standing spend between sessions is about $0.04 a day; the risk is a teardown that fails, which the session's existing terminate-and-confirm path covers.

## What each outcome licenses

| outcome | licenses | does not license |
|---|---|---|
| inconclusive | nothing about admission; what the apparatus must fix | any ratio, even one that looks clean |
| T0 not reached | that run 3's lines did not reproduce on this card and these traces, and on which line | that hold-cap regressed in the product; this is the lab |
| T0, not T1 | hold-cap reproduced; no cap down to 128 brought the tail within 3x inside the guards here | that no admission rule can |
| T1 at cap c | on this card, this load and these traces, the hold with cap c held the premium p99 within 3x of the same session's isolation while keeping 95% of off's throughput | Finding 9's contender limits, which T1 does not require and are reported beside it; another card, load or engine version |
| T2 | the same at 2x | the same |
| T3 | the same at 1.25x, after the checks above | anything before those checks |

Three blocks on one card bound the block success rate only above 37% at 95%; every positive line reads "observed on these traces".

## Ways this design could produce a plausible wrong number

| risk | what stops it |
|---|---|
| a low premium p99 bought by a contender queue that never drains, scored on survivors | guard bars read from the step log over a window shared by every arm of a block; an unfinished contender's tokens count as not done |
| a cap the engine did not apply, or a hold that did not run, labelled as the arm | the cap and hold validity lines, read from the engine's arguments, the step log's chunk sizes and the gateway's decision reasons |
| a ratio inflated by a slow isolation cell, or deflated by borrowing a better one | R1 in every block, the crossed pairing against R1's lower end, and no ratio across blocks or sessions |
| a premium tail lowered by dropping failures | failures at +inf in the p99, as every study here has scored them |

## Open decisions for the owner

1. Lab, as drafted, or the product path on EKS after a change that renders the cap per object; and whether T0 is run 3's lines reproduced plus the 0.351 bound.
2. Whether T1 to T3 also require zero refusals; as drafted they do not, and the guard bars bound what refusals can delete.
3. Whether Finding 9's contender limits join the guard bars; A1's screen predicts hold-256 fails the median limit on one of three traces (2.54x off's on 852) while reaching T1.
4. Which meaning "aggregate throughput" has: output tokens, as inherited and drafted, under which it cannot see the contender at this load; or every token processed, under which it implies about 93% of the contender's work and hold-192 fails it on A1's screen.
5. Fresh seeds 901 to 903, as drafted, or the diagnostic's 851 to 853 (astra proposed 2026102201 to 2026102203, equally unused).
6. Whether to buy the calibration A1 lists first, or let this session's own step logs serve, as drafted.
7. Whether the stages are properties of the ladder, as drafted, or nested gates each candidate must pass in turn from T0, as astra drafted (above, "The alternative reading").
8. The narrower arms drafted here, or astra's cap × hold factorial.
9. Whether to end acquisition early when every candidate has failed T0 in a complete block, as astra proposed; this draft runs all 18 cells.

## How this draft was made

I wrote this page from A1's computation before reading astra's draft; astra drafted its own from the same specification, cold (prompt and answer in `data/2026-10-22-staged-admission-feasibility/astra-a2-prompt.txt` and `astra-a2.txt`).
My prompt asked it, as one example among several, whether one guard bar makes another redundant at this load, which pointed it at a question I had already worked on; its answer about output tokens was nevertheless one I had not considered.
We agreed without consultation on the lab apparatus, on T0 as run 3's contract reproduced in the lab rather than milliseconds compared across platforms, on per-block crossed ratios against an isolation cell in every block, on fresh seeds, and on the purchase gate not selecting on a predicted pass.
After reading it I changed three things here: the guard bars now carry the price-of-protection's output-token meanings, as astra argued from the lineage, with my all-token reading kept beside them; the shared window is a fixed 420 s, as astra's is; and uncertain requests are bounded as the scorer's lag box does.
The nesting of the stages, the arms and the early stop are left as decisions 7 to 9, with both versions stated.
Every number on this page is mine or re-derived by me from the cited file.
