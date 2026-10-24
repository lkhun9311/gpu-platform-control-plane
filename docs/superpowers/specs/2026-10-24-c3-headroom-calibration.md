# C3's calibration: hold-cap and a fixed spacing at a load with contender headroom — pre-registered

Written 2026-10-24.
**DRAFT, not frozen for purchase.** It is frozen only after codex's cold attack on this page has been reconciled, the build below is in, and the plan check and a kind rehearsal have run. The owner confirms the purchase after that.
The owner approved proceeding with C3 in the recommended order, calibration first, in the working session of 2026-10-24; no document records that approval. The order itself is `2026-10-22-paid-retry-candidates.md`, "Order, if any is bought".
v27's records stand as written (`2026-10-08-measuring-prospective-admission-design.md`, "v27 calibration's result" and "v27 main study"). This is a new question at a new load.

## How it was drafted

In parallel and independently: codex `gpt-6-astra` drafted the calibration cold, and I wrote my own sketch before reading its draft. Both are in `data/2026-10-24-c3-headroom/`, with the prompt.
Then a free replay was run, after both drafts and before this page (the same directory, `README.txt`). Every figure below is mine, re-derived from those files.

| Choice | My sketch | astra's draft | Taken |
|---|---|---|---|
| Study and stage | a new study | a new study id, stage F's shape | a new study, `admission-headroom-calibration-2026-10-24`, under a new **stage G**, so the stage-to-study map stays one-to-one and v27's F is untouched |
| The fixed control | flagged that 1,740 ms carried from v26 may not fit a new load | C3's text is contradictory: its gate keeps 1,740 ms while its control rule is re-derived; resolve both to one S | astra's resolution, chosen on the replay below |
| The rate rule | coherent as frozen | a headroom heuristic, not a utilisation bound or a tail guarantee | astra's wording |
| Top risk | the lighter load can dissolve the separation the main study needs | the same, ranked fourth, behind the control rule | the replay was run on it before anything else |

## The question

At premium 9.25/s and contender 0.375/s, on one A10G, is hold-cap admissible and protective at contender prompts of 6,144, 7,695 and 8,192 tokens, while the long prompt's capped prefill outlasts a fixed spacing derived from the reference's?
It is a feasibility measurement. A **feasible** verdict makes a main study comparing hold-cap with that fixed spacing and a size-aware one worth registering; it is not that study's result.

## Why 0.375 contenders a second

C3 fixed the rate before any replay: hold-cap serves contenders one capped prefill at a time, v27's calibration measured the long length's engine prefill p95 at 1,851 ms, and the rule `rate × 1,851 ms ≤ 0.70` gives 0.378/s, which C3 rounded down to 0.375 (0.694) without stating a rounding grid.
That is a chosen design point with a reason, not a guarantee. Rate times a p95 is not mean utilisation; the gateway's serial-prefill hold lasts until first content, which is longer than the engine's prefill; and a p95 bounds neither rare service times nor bursts. The rate is not changed by anything below.

## The replay, before this page

Traces from the matrix's own `gen-trace` flags at the new rate. The call reproduces all four of v27's frozen seed-871 checksums at 0.5/s, and v27's committed main-study prediction is reproduced exactly by the parameterised script. The lengths lie outside the step model's fit, so these are extrapolations.

**With the fixed arm at v26's 1,740 ms,** seeds 882, 892 and 893, pooled premium p99 at the long length:

| pace | off | hold-cap | fixed, 1,740 ms | hold-cap's median prefill, long |
|---|---:|---:|---:|---:|
| 1.000 | 1,540 | 394 | 411 | 1,683 ms |
| 1.0205 | 1,578 | 433 | 814 | 1,730 ms |
| 1.0275 | 1,589 | 452 | 1,046 | 1,745 ms |
| 1.070 | 1,664 | 509 | 1,814 | 1,842 ms |

The lighter load shortens the capped prefill too, by about 2% against v27's main-study seeds at 0.5/s (1,768 ms there, 1,730 ms here, at 1.0205). On seed 891 at 1.0205 the long median is 1,702 ms, under 1,740, and fixed-1,740's p99 at the long length is 379 against hold-cap's 374 ms.
So with v26's spacing carried unchanged, the challenge sits on a pace knife edge at this load, and on the calibration's own seed it is predicted absent.

**With the fixed spacing derived from the reference,** S = 1.0533 × hold-cap's median prefill at the reference length on seed 891, at the same pace (`predict-main-derived-<pace>.json`):

| pace | S | off, long | hold-cap, long | fixed S, long | fixed S against hold-cap, ref |
|---|---:|---:|---:|---:|---:|
| 1.000 | 1,608.5 ms | 1,540 | 394 | 1,468 | 426 against 370 |
| 1.0205 | 1,659.1 ms | 1,578 | 433 | 1,488 | 429 against 390 |
| 1.0275 | 1,672.9 ms | 1,589 | 452 | 1,513 | 447 against 400 |
| 1.070 | 1,767.3 ms | 1,664 | 509 | 1,819 | 528 against 471 |

S here is computed from the replay's unrounded medians and rounded once, to 0.1 ms, as the gate computes it; each output records the spacings it ran.
At every pace the four contender limits the replay models hold for hold-cap on every seed and length, and the derived spacing collapses at the long length. At the reference neither is 15% below the other: hold-cap over fixed-S is 0.869 to 0.909.
That is the separation the main study needs, and the reason the derived rule is taken.

What the derived rule costs, in astra's words: the reference length's fit to S holds by construction, so the calibration can no longer test it independently as v27's did ("the reference must still fit", C6). The main study has to show it instead, by fixed-S being admissible at the reference with neither it nor hold-cap 15% below the other.
And S is v26's ratio carried to a new load, not a spacing tuned at it: 1.0533 is the literal ratio of v26's selected 1,740 ms to v27's measured 1,652 ms (1,740 / 1,652 = 1.05327, frozen as **1.0533**). v26 never measured past its grid's widest spacing, so nothing establishes S as the best fixed spacing here.

## Revised against astra's cold attack, before purchase

astra attacked this page cold (`data/2026-10-24-c3-headroom/astra-attack.txt`, from `astra-attack-prompt.txt`, which names no place to look). I reproduced each finding before acting on it.

| # | Finding | Reproduced | Resolution |
|---|---|---|---|
| 1 | A NaN timestamp makes the crossed ratio NaN, which reads "fails" on its line and passes the rule that should act on it, so the inherited gate returns feasible with three failed protection lines | yes: a test with NaN first-content stamps read feasible | `crossed_log_ratio` returns unscorable for a NaN, and feasible now needs every line to hold (rule 4); each has its own test and mutation |
| 2 | "Feasible" was worded as licensing the main comparison, which this stage does not measure | yes | the license is narrowed to hold-cap's feasibility and a prefill challenge; the fixed spacing's failure is a prediction ("What it licenses") |
| 3 | The replay models four of the gate's admissibility lines, and its d differs from the scorer's in population | yes | the prediction is stated as the four modelled limits, with both differences named |
| 4 | A done record without its end time crashes the scorer instead of reading inconclusive | yes: `KeyError: 't2'` | such records are counted as a validity line; a test and a mutation |
| 5 | The derived replay rounded d to whole milliseconds before deriving S | yes: S off by up to 0.3 ms | re-run from unrounded medians; each output records its spacings; the tables above are the re-run's |
| 6 | Rule 4 dropped "not positive", and publication was promised where S cannot be computed | yes | both restored as astra's draft had them |
| 7 | The approval was cited to a page that records only a recommendation | yes | the approval is now stated as given in the working session, with no document behind it |

Findings 1 and 4 are in the scoring code v27's calibration shares, and in `crossed_log_ratio`, which the diagnostic and v26 also use. The fixes change no published verdict. Scored by `dev`'s scorer and by this one, the diagnostic's and v26's archives give byte-identical output. v27's gives the same verdict, medians and spacings, and differs only by three added validity lines, one per length, each holding at 0 done records without an end time.

## Study, stage and load

`admission-headroom-calibration-2026-10-24`, stage G, one block on **seed 891**, 7 cells:

- R1 once, first, uncapped and admission off, on the seed's premium rows only;
- then, in the matrix's hash of seed, stage, block and arm: **off-long, off-short, hold-cap-short, hold-cap-ref, hold-cap-long, off-ref**.

Off arms run admission off and no cap. Hold-cap arms run the engine's 384-token prefill cap with the gateway's serial-prefill hold, longest hold 25 s, as in v26 and v27.

| | premium | contender |
|---|---|---|
| rate, independent Poisson | 9.25/s | **0.375/s** |
| prompt | 200 characters, 68 tokens | short 31,894, ref 40,000, long 42,579 characters; 6,144, 7,695 and 8,192 tokens |
| output, minimum = cap | 64 | 16 |

420 s of arrivals per cell, a 30 s timeout, no retries, the sender pool held at 600 as in v26 and v27, a fresh engine per cell, and the batch budget, model, revision and image of v27's calibration.
One trace per length, on one arrival schedule; off and hold-cap at a length replay identical bytes. Seed 891's trace at 0.375/s has 3,793 premium and 163 contender requests.
The four checksums, R1's and one per length, are frozen in `hack/lib/prospective-pilot.sh` and in the scorer, which a test keeps equal, when the build lands. The plan refuses any other trace under this study's name.

**Limits:** v27's, which the same seven 420 s cells give: 1.25 × (200 + 7 × 920 + 12) = 8,315 s, so a hard stop at 8,340 s (2 h 19 m) and the backstop 10 minutes later.

## Validity

v26's and v27's, cell by cell, through the same functions, as revised before v27's calibration was scored (that page, "Revised before scoring"):
provenance by manifest, trace checksum and row identity, with each row's prompt length and frozen token count, and the engine's count where it reported one, equal to its trace's; eligibility; dispatch lag at most 50 ms and at most 0.1% of premium requests above 13 ms; the gateway's arrival-to-record and premium arrival-to-decision delays, p99 at most 13 ms and maximum at most 50 ms; every contender the gateway admitted present in the cell's step log; hold-cap's serial-prefill on every contender; and each off's premium loss under 0.5% and contender completion at least 95%.

## The gate, in this order

d(length) is hold-cap's median **engine** prefill at that length: from the scheduler's add to the end of the step that took a contender's last prompt token, over every contender the scheduler received, with an unfinished one at +∞.
S = 1.0533 × d(ref), rounded to 0.1 ms.

1. **inconclusive: <reason>** for a missing or extra cell, any failed or unscorable validity line, any unscorable admissibility or protection line, or any hold-cap contender success the gateway did not time;
2. **not feasible: hold-cap was not admissible at <length>: <line>**, by v26's seven admissibility lines against off at the same length;
3. **not feasible: hold-cap's 15% protection of the premium tail was not established at <length>**, when ln(hold-cap scheduled hi / off arrival lo) exceeds ln 0.85;
4. **inconclusive** when a length's engine prefill median is missing, not positive, or infinite, or when S rounds to 0.0 ms, only once 2 and 3 pass at every length; and when any validity, admissibility or protection line does not hold without having reached rules 1 to 3, since feasible needs every line to hold, not only no rule to have fired;
5. **challenge not achieved**, when d(long) does not exceed S;
6. **feasible** otherwise.

Within a rule, lengths are reported short, ref, long, and every failure is listed.
v27's second condition, "and 1.05 times the reference's", is dropped: with S at 1.0533 × d(ref), exceeding S already exceeds it.
That holds only while S is positive: a reference under 0.05 ms, as kind's stub engine gives, rounds S to 0.0 ms, which any long length exceeds, so rule 4 refuses it.
The stage G rehearsal found this, scoring "feasible" against S = 0.0 ms before the refusal was added.

**Published whatever the verdict:** S and the size-aware spacings s(length) = S × d(length) / d(ref), whenever every median is finite and positive and S does not round to zero, labelled provisional unless the verdict is feasible, and otherwise absent, with the reason in the verdict; every validity and admissibility line; off's and hold-cap's premium bounds; contender completion, p50, p95 and refusals; work p and q; premium gaps; preemptions; d and its p95 and unfinished count per length; the gateway's admission-to-first-content beside d, not judged; and the session's timings and cost.

## The prediction, recorded before purchase

On seed 891, at the four paces, the replay predicts that hold-cap passes the four contender limits it models (completion, completion p50, completion p95, no hold refusal) at every length, with its pooled premium p99 at 0.24 to 0.29 of off's, and:

| pace | d(short) | d(ref) | d(long) | S | d(long) > S |
|---|---:|---:|---:|---:|---|
| 1.000 | 1,106 | 1,527 | 1,648 | 1,608.5 | yes |
| 1.0205 | 1,133 | 1,575 | 1,702 | 1,659.1 | yes |
| 1.0275 | 1,147 | 1,588 | 1,726 | 1,672.9 | yes |
| 1.070 | 1,210 | 1,678 | 1,828 | 1,767.3 | yes |

So the replay points to **feasible** at every pace, and it does not predict the gate in full:
- the gate's other admissibility lines, no preemption, shared-window work p and q, and the premium inter-token gap, are not modelled (`simulate.py`, `owner_limits`), so full admissibility is unpredicted;
- the replay's d is a contender's first token less its engagement in the model, over the contenders that reached a first token; the scorer's d runs from the scheduler's add and counts an unfinished prefill as +∞, so the two differ in definition and in population;
- the replay has understated the contender's cost by 3% to 7% against every card measured so far.

The prediction does not decide the purchase. It cannot establish validity, and it cannot be used to change the rate, the seed or the multiplier.

## What comes after, not registered here

A main study only if this reads feasible: off, cap-only, hold-cap, fixed-S and size-aware at each length, one block per card on three cards, **seeds 882, 892 and 893**.
At 0.375/s seed 882 has 172 contenders a cell against 148 and 163 for 892 and 893, still the heaviest draw. It is a different trace from v27's 882 at 0.5/s, which had 234, so "882 kept" keeps the seed, not the same heavy draw.
Its purchase gate replays those frozen seeds once, at the calibration card's pace and S. If it predicts hold-cap inadmissible anywhere, or the main comparison unreachable, the study stops and no seed is swapped.

## Cost

v27's seven cells took 74 min 42 s from launch to the matrix's return: about **$0.85** at $0.6824/h, and about $1 budgeted.
At the $1.1324/h price cap and the full 2 h 19 m hard stop it is about $2.6.

## What it licenses

Feasible: that at this load, on this card and seed, hold-cap meets the owner's limits at all three lengths, and that the long prompt's median capped prefill outlasts S, 1.0533 times the reference's.
That is a challenge to the fixed spacing measured in prefill, not a fixed spacing measured failing: whether fixed-S loses the premium tail at the long length depends on the arrival schedule and the overlapping work as well, and this stage runs neither fixed-S nor size-aware. The replay predicts it does; only the main study can measure it.
So a feasible verdict licenses registering the main study and running its purchase gate, and nothing about either control's tail, nothing across cards, and nothing that revises v26's or v27's verdicts at the old load.

## What must be built before purchase

astra's inventory, re-checked against the code at `d0fd2873`:
1. the study id and its registration (`internal/bench/study.go`, `matrix_plan.go`'s arm-set check);
2. stage G in `hack/lib/prospective-pilot.sh`: the study, seed 891, the stage's arms, the four checksums, the per-arm contender length;
3. `hack/m5c-matrix.sh`: the study allowlist, the seed and rate guards, the per-arm prompt substitution, which today applies to v27's study only and would otherwise replay every arm at 40,000 characters, the plan's checksum table, and the archive README's scorer;
4. `hack/m5c-gpu-session.sh`: the study and stage, the rates bound to 9.25 and 0.375, the limits, and the scoring command;
5. `pilot_report.py`: a `headroom` gate with S in place of the literal 1,740 ms, v27's `calibration` gate left as it is;
6. tests for each, a spot-lifecycle golden, and a kind rehearsal of stage G, with each new check made to fail once.

v27's verifier (`hack/verify-admission-evidence.sh`) keeps reproducing v27 after the scorer changes, and is not repointed.
