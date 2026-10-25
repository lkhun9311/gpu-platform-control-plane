# C3's main study: hold-cap against a frozen fixed spacing and a size-aware one, over three sessions — pre-registered

Written 2026-10-25. **Frozen for purchase, 2026-10-26,** at the commit that carries this line; the rules, the cells, the spacings, the checksums and the limits below are not changed after it.
codex's cold attack is reconciled, the build is in ("Build status"), the plan check passes all three blocks, and the kind rehearsal of three stage-H sessions has run twice, holding every line but the gateway latency bound this host fails.
The owner approved the purchase, the three sessions one after another, in the working session of 2026-10-26; no document records it.
The owner approved drafting it in the working session of 2026-10-25, after C3's calibration read feasible; no document records that approval.
C3's calibration (`2026-10-24-c3-headroom-calibration.md`) froze S, the size-aware spacings and the seeds, and its records stand as written.

## How it was drafted

In parallel and independently: codex `gpt-6-astra` drafted the registration cold, and I wrote my own sketch before reading its draft. Both are in `data/2026-10-25-c3-main/`, with the prompt.
Then the purchase gate was frozen (`gate.txt`, before it ran), run once at its nominal pace, and its pass band located (`pace-band.txt`). Every figure below is mine, re-derived from those files and the calibration's `verdict.json`.

| Choice | My sketch | astra's draft | Taken |
|---|---|---|---|
| Study and stage | a new study | `admission-headroom-main-2026-10-25`, a new **stage H** | astra's: G stays the calibration's |
| Arms | off, cap-only, hold-cap, fixed-S, size-aware at each length | the same, size-aware as the existing fixed-spacing mode at each length's scalar | the same |
| Block numbering | not considered | the global block, 1 to 3, enters the order's hash, though each card runs alone | astra's; the orders below are recomputed by me with the matrix's rule |
| The reference test | "within 15%" | neither 15% below the other, explicitly not equivalence; v27's stronger non-inferiority published beside it | astra's |
| A card slower than the gate's band (a higher replay pace) | not considered | not considered | first a verdict of its own; after astra's attack showed the calibration card at that edge, the owner chose to judge the length question there too (rule 6) |
| Replacement launches | not considered | at most one, for a documented Spot interruption only | astra's |
| Top risk | seed 882's heavy draw at long | the fixed control was chosen on the separation the replay predicted | both stated; astra's limits what a win licenses ("What it licenses") |

## Revised against astra's cold attack, before the build is finished

astra attacked this page cold at `d94e973a` (`data/2026-10-25-c3-main/astra-attack.txt`, from `astra-attack-prompt.txt`, which names no place to look). I reproduced each finding before acting on it.

| # | Finding | Reproduced | Resolution |
|---|---|---|---|
| 1 | The inherited serial-prefill line counts reason labels, and the spacing line times only admissions labelled "waited": neither checks the treatment's timing | yes, in `pilot_report.py`'s `mode_reasons` and `spacing_deviation`; astra's rewritten-timestamp archive I have not rebuilt | two temporal witnesses added to the scorer's build (item 6). Run on every archived card first (`temporal-witness.py`, `temporal-witness-archives.txt`): all 12 hold-cap cells admit each contender after the previous one's recorded release, by at least 0.011 ms, each release 0.015 to 1.84 ms before its first content; all 12 of v26's fixed cells hold every consecutive gap within 0.011 ms of the spacing. So the calibration's evidence passes them |
| 2 | An unscorable protection or comparison bound has no verdict, and the short length's would go unread by the interaction | yes | rule 1 takes every unscorable bound rules 3 to 7 read, and rule 6 needs every line it names to hold |
| 3 | The pace margin used a shift onto the gate's grid point with no basis | yes: the card matches at 1.0316 on the generated trace and 1.0306 on its own | removed; the margin is 0.0012 to 0.0022, and the calibration card sits at the upper edge ("The purchase gate") |
| 4 | Rule 5b's (now 5d's) license claimed a tie the calibration never measured; and failing both wins does not establish "neither 15% below" | yes | both reworded |
| 5 | Nothing requires three distinct GPUs, yet the license spoke of three cards | yes | the verdicts speak of three sessions, and the number of distinct UUIDs is published |
| 6 | A ledger refusing a fourth launch makes the allowed replacement impossible | yes | a fifth launch is refused |
| 7 | A waiter giving up as its turn comes spends the slot | yes, `fixedspacing.go` `leave` | stated |
| 8 | "Every archived cell" includes a short cell below the lower edge; a higher pace is slower, not faster; the interaction rounds to −1.114 | yes | corrected |

astra also reproduced the nominal gate and its control exactly, the three orders, the contender counts, the spacings, and the deadline and cost arithmetic.

## The question

At premium 9.25/s and contender 0.375/s, on A10Gs, at contender prompts of 6,144, 7,695 and 8,192 tokens:
does hold-cap keep its advantage over a fixed spacing frozen at the reference, S = 1,680.4 ms, growing from the reference to the long length, while hold-cap stays admissible and protective?
And does a static spacing that knows the prompt's length do as well, and does the cap alone account for the protection?

It is an observation on three sessions, each one A10G instance, three traces and one load. It is not a claim about A10Gs in general, other loads, or admission policies generally.

## Arms, and how each spacing was frozen

Each arm runs at `-short`, `-ref` and `-long`, 15 cells a block:

| Arm | Gateway admission | Engine prefill cap | What it is for |
|---|---|---:|---|
| `off` | off | none | each length's reference |
| `caponly` | off | 384 | whether the cap alone protects |
| `hold-cap` | serial-prefill, longest hold 25 s | 384 | the treatment |
| `fixedS` | fixed spacing **1,680.4 ms** at every length, longest hold 25 s | 384 | one spacing carried across lengths |
| `sizeaware` | fixed spacing **1,176.9 / 1,680.4 / 1,830.8 ms** at short / ref / long, longest hold 25 s | 384 | a static rule that knows the length |

The spacings are the calibration's, from its scored medians, not recomputed on any card:
S = round(1.0533 × 1,595.398333 ms, 0.1 ms) = 1,680.4 ms, and s(L) = round(S × d(L) / d(ref), 0.1 ms) with d(short) 1,117.381907 and d(long) 1,738.179325 ms (`data/2026-10-25-c3-calibration-results/verdict.json`).
Both static arms use the gateway's existing fixed-spacing mode: only an admission advances its clock, and premium bypasses it.
A waiter already past its 25 s hold when its turn comes is dropped and takes no slot; one that gives up at the instant its turn is handed to it is counted as admitted and its slot is spent (`internal/gateway/fixedspacing.go`, `release` and `leave`), which can only slow the arm.
Every cell has one contender length, so a size-aware arm at a length is a fixed spacing at that length's scalar, and no new gateway mode is needed. A mixed-length size-aware rule is a different experiment.
At ref, `fixedS-ref` and `sizeaware-ref` are the same treatment bought twice. Their difference is published as a repeatability diagnostic, with no threshold, and they are never pooled.

## Cards, blocks, order and load

Three sessions, one fresh g5.2xlarge Spot instance with one A10G each, in gpu-lab, run one after another, one block each:

| Block | Seed | Contenders a cell |
|---|---:|---:|
| 1 | **882** | 172 |
| 2 | **892** | 148 |
| 3 | **893** | 163 |

Each session runs R1 first, uncapped and admission off, on its seed's premium rows; R1 never enters an endpoint.
Then the block's 15 cells in the matrix's hash of seed, stage, global block and arm (`hack/m5c-matrix.sh`), which I recomputed, and which reproduces the calibration's own G order on seed 891:

- **block 1, 882:** hold-cap-long, fixedS-long, fixedS-ref, hold-cap-ref, off-long, caponly-short, sizeaware-short, off-ref, fixedS-short, off-short, caponly-long, hold-cap-short, sizeaware-long, sizeaware-ref, caponly-ref;
- **block 2, 892:** hold-cap-short, off-ref, hold-cap-long, fixedS-long, fixedS-short, hold-cap-ref, sizeaware-ref, caponly-ref, caponly-short, fixedS-ref, off-short, sizeaware-short, off-long, sizeaware-long, caponly-long;
- **block 3, 893:** fixedS-long, sizeaware-ref, off-short, caponly-short, sizeaware-short, caponly-long, off-ref, sizeaware-long, fixedS-short, off-long, hold-cap-short, hold-cap-ref, fixedS-ref, hold-cap-long, caponly-ref.

The global block must reach each session: if every session hashed its block as 1, blocks 2 and 3 would run other orders.
Distinct instances are not shown to be distinct physical hosts. Each session's instance id and GPU UUID are recorded and published, and nothing here requires the UUIDs to differ: the verdicts speak of three sessions, and the page says how many distinct UUIDs they ran on.

The load and the apparatus are the calibration's: independent Poisson at 9.25/s premium and **0.375/s** contender; 420 s of arrivals a cell, a 30 s timeout, no retries, the sender pool at 600;
premium 200 characters, 68 tokens, 64 output tokens; contender 31,894, 40,000 and 42,579 characters, 6,144, 7,695 and 8,192 tokens, 16 output tokens;
a fresh engine and gateway per cell, Qwen2.5-3B-Instruct at `aa8e72537993ba99e69dfaafa59ed015b17504d1`, synchronous priority scheduling, batch budget 512, 64 sequence slots, no prefix caching, and the calibration's image.
One arrival schedule per seed; within a block only the contender's length changes, and the five arms at a length replay identical bytes.

The 12 checksums, nine full traces and three R1, are regenerated under this study's id and frozen in `hack/lib/prospective-pilot.sh` and in the scorer, which a test keeps equal. The nine must equal `data/2026-10-24-c3-headroom/trace-checksums.txt`, which the id does not enter; that file was not a freeze, and it lacks R1's.

## Sessions, limits and cost

16 cells at the calibration's 920 s a cell: 1.25 × (200 + 16 × 920 + 12) = 18,665 s, so a **hard stop at 18,720 s** (5 h 12 m) and the backstop at 19,320 s (5 h 22 m).
The session script's existing offsets then give: the matrix stopped at 5 h 04 m, acquisition at 5 h 06 m, the sweeper's tag at 5 h 32 m, and a credential horizon of 6 h 02 m (the backstop and 40 minutes).
Expected: the calibration's cells took 538 to 563 s and its cold R1 881 s, so 16 cells and their gaps are about 2 h 37 m, and a session about 2 h 45 m.

The three blocks are acquired without looking at any endpoint in between. A session stops for an apparatus fault, a deadline, or an unresolved instance state; an outcome failure is evidence and does not stop the study.
At most one replacement launch, and only for a documented Spot interruption: the whole block again, same seed and order. The interrupted block is published and never pooled. No replacement for a bad result, a validity failure, a crash or a deadline.

Cost, at the repository's budgeting figures, not a price quote: expected about **$5.6**, three 2 h 45 m sessions at $0.6824/h.
Bounded by the sweeper's tag plus 15 minutes, 347 min, at the $1.1324/h price cap: $6.55 a session, $19.65 for three, **$26.20** with the one replacement. A $27 reservation allowance is frozen. It bounds new launches, not a termination that fails.

## Validity

The calibration's lines, cell by cell, through the same functions, in every cell including R1 (that page, "Validity"), and for the two static arms v26's: each held contender released at its own arm's frozen spacing, deviation minimum at least −1 ms and p99 at most 13 ms.
Each cell's admission mode and cap are checked against its arm: off and cap-only with admission off, cap-only and the three gated arms at 384, and each fixed-spacing arm at its exact spacing.
A fully recorded treatment failure is an outcome, not missing evidence: it stays in its latency population at +∞.

## Admissibility

An arm is admissible at a length when, in **every block**, against that block's off at the same length: contender completion at least 0.95, completion p50 at most 1.5 × off's, completion p95 at most 25,000 ms, no hold refusal, no preemption, shared-window prefill work p and decode work q each at least 0.90 × off's, and premium content-gap p99 at most 1.25 × off's.
These are v26's seven lines, eight scalar checks, through `pilot_report.py`'s `admissibility_lines`.

## The endpoint

Per length, never across lengths: premium TTFT p99, nearest rank, over every premium request of the three blocks pooled, per arm. Cell p99s are never averaged, and no calibration observation enters.
U(X, Y) = ln(X's scheduled-start upper p99 / Y's arrival-start lower p99), and L(X, Y) = −U(Y, X); measurement bounds, not confidence intervals, as v26's scorer computes them.
K(X, Y), comparable retained work: X's pooled completion at least Y's − 0.01, and X's mean block p and q each at least 0.97 × Y's.
W(X, Y), a 15% win: X admissible, K(X, Y), and U(X, Y) ≤ ln 0.85. N(X, Y), at most 15% worse: X admissible, K(X, Y), and U(X, Y) ≤ ln 1.15.
An infinite numerator never wins, two infinities are not ordered, and a NaN is unscorable.

d(L, b) is hold-cap's median engine prefill at length L in block b, as the calibration defines it: scheduler add to the end of the step that took the last prompt token, an unfinished prefill at +∞.

## The verdict, in this order

H is hold-cap, F fixed-S, A size-aware, C cap-only, O off.

1. **inconclusive: <reason>**, for a missing or extra cell or block, any failed or unscorable validity line, any unscorable admissibility input, or any bound rules 3 to 7 read being unscorable: a NaN, a non-positive endpoint, or two infinities, at any length, the short one included. A fully observed +∞ is not missing.
   No later rule is reached while any line it reads is unscored, and rule 6 needs every line it names to hold, not only no earlier rule to have fired, as the calibration's rule 4 does.
2. **hold-cap not operationally robust: <length, block, line>**, when H fails any admissibility line anywhere. Every failure is listed.
3. **hold-cap's protection not established at <length>**, when U(H, O) > ln 0.85 at any length.
4. **challenge not reproduced on block <b>**, unless on every block d(ref, b) ≤ 1,680.4, d(long, b) > 1,680.4, and d(long, b) > 1.05 × d(ref, b). A missing, not positive or infinite median reads inconclusive here instead.
   The 1.05 condition is back: S is frozen, no longer recomputed from each card's own reference, so exceeding S no longer implies it.
5. **The reference comparison**, the first that applies, with 5a, 5b and 5c ending the verdict and 5d carried into rule 6:
   - 5a. **reference comparison not established: fixed-S <inadmissible | not protective> at ref**, when F fails an admissibility line at ref, or U(F, O) > ln 0.85 there;
   - 5b. **the frozen spacing beat hold-cap at the reference**, when W(F, H) at ref;
   - 5c. **reference comparison not established: <which bound or work line>**, when U(H, F) ≤ ln 0.85 or U(F, H) ≤ ln 0.85 at ref without the W that would name it;
   - 5d. **hold-cap already ahead at the reference**, when W(H, F) at ref: not a verdict on its own, but the starting point rule 6 names;
   - otherwise neither directional 15% advantage is established at ref. That is not equivalence, and it does not say neither arm is 15% below the other: hold-cap's bounds at [80, 90] against fixed-S's at [100, 110] establish neither, while allowing a 20% gap. N(F, H) at ref is published beside it.
6. **length-dependent advantage over the frozen spacing observed, <from a reference with neither ahead | with hold-cap already ahead at the reference>**, when the interaction I⁺ = U(H, F) at long − L(H, F) at ref ≤ ln 0.85, K(H, F) at long, and either F is inadmissible at long or W(H, F) at long.
   The reference's lower bound is subtracted, so the interaction is the unfavourable end, and an advantage hold-cap already had at the reference is subtracted from the long one before the 15% is asked of it. With F's bound infinite at long and H's finite, I⁺ is −∞ and holds; with H's infinite it is +∞ and fails.
7. **length-dependent advantage not established: <which>**, otherwise, naming the failed interaction, separation or work line, whether hold-cap was already ahead at the reference (5d), and any reverse W(F, H) at long.

**Changed after the gate, by the owner's choice (2026-10-25).** As first drafted, hold-cap ahead at the reference ended the verdict, and the length question went unanswered.
That outcome is where the gate's pass band ends: above a replay pace of about 1.0328 fixed-S at ref begins to collapse while every seed's d(ref) is still under S, and the calibration card itself matches the replay at 1.0306 to 1.0316 (`pace-band.txt`).
So it was changed, after reading the replay, to the rule above: the question is whether hold-cap's advantage grows from the reference to the long length, and an advantage already present at the reference does not answer it either way, since the interaction subtracts it.
The change is not blind. The replay predicts the interaction holding on both sides of the edge (−1.088 at 1.0306, −1.013 at 1.035, −0.733 at 1.050, against ln 0.85 = −0.163), which is part of why it was made; a reader should weigh a rule 6 verdict knowing that.

**Size-aware, separately**, the first that applies, on valid evidence:
1. **the frozen size-aware control broke the limits at <length>**, when A is inadmissible anywhere;
2. **the frozen size-aware control did as well, within 15%**, when U(A, O) ≤ ln 0.85 and N(A, H) at every length; any W(A, H) is reported;
3. **hold-cap beat the frozen size-aware control at long**, when W(H, A) at long;
4. **size-aware comparison unresolved**, otherwise.

**Cap-only, separately:** **the cap alone protects, within 15% of hold-cap**, when U(C, O) ≤ ln 0.85 and N(C, H) at every length. That the gateway's signal adds to the cap needs W(H, C), at a named length.
Neither separate verdict rescues a failed primary one; both are published whatever the primary reads, with the comparisons that could not be made marked.

## The purchase gate, run before this page

Frozen in `data/2026-10-25-c3-main/gate.txt` (commit `e046fb16`) before it ran: the replay of seeds 882, 892 and 893, every arm at the frozen spacings, at nominal pace 1.0275, the replay grid's pace whose seed-891 ref median (1,588.27 ms) lies nearest the card's 1,595.40 ms.
The driver first reproduced the committed `predict-main-derived-1.0275.json` exactly, 15 pooled p99s and three prefill medians.

**It passes, at 1.0275, on all five conditions** (`gate-1.0275.json`, commit `68fb8c85`): hold-cap inside the four modelled limits everywhere, its pooled p99 0.27 to 0.29 of off's;
on every seed d(ref) at most 1,638.0 ms and d(long) at least 1,714.3 ms against S = 1,680.4; at ref, hold-cap 400 against fixed-S 433 ms; at long, 452 against 1,489.5 ms; the interaction −1.114 against ln 0.85 = −0.163.
Nothing was required of the other arms, and the replay predicts neither secondary verdict favourably: size-aware at short 519 ms against hold-cap's 328, at long 428 against 452, so N(A, H) fails at short and W(H, A) at long does not hold; cap-only above off at every length, 1,224 to 1,806 ms against 1,119 to 1,589.

Its pass band, sensitivity and not deciding (`pace-band.txt`): from about 1.007, where seed 892's d(long) falls under S, to about 1.033, where hold-cap over fixed-S at ref falls under 0.85.
Every archived ref and long cell has run inside it, in the gate's sense of pace: eight ref cells on four cards at 1.0198 to 1.0306, two long cells at 1.0301 and 1.0322. (The two short cells, 1.0070 and 1.0151, are not what either edge reads.)
**The calibration card itself sits at the upper edge.** Its ref cell matches the replay at 1.0306 on its own archived trace and at about 1.0316 on the generated one, 0.0022 and 0.0012 below the edge, and it is the only card at this load.
At 1.0316 the gate's replay still passes, but hold-cap over fixed-S at ref is 0.889 against the 0.85 that ends the tie.
So a card like the calibration's has a real chance of finding hold-cap already ahead at the reference (5d), which rule 6 now judges rather than stops on: under a normal spread of 0.0033 per cell, about one in four per cell. That figure is an illustration resting on assumptions `pace-band.txt` states, not a probability.
An earlier version of this page put the margin at 0.0054 and the chance at one in seven, after a shift onto the gate's scale that astra's attack showed had no basis (below).

The gate is not blind: these seeds' replays were read while the calibration page was written. A pass says the modelled prerequisites of rules 2 to 6 are reachable at the nominal pace, not the verdict.
Preemption, shared-window work and premium gaps are not modelled, the replay's d differs from the scorer's in definition and population, and the replay has understated the contender's cost by 3% to 7% against every card measured.

## Published whatever the verdict

The registration's version; the gate, its control and every sensitivity run; every cell's inventory and every exclusion; all three sessions' raw evidence under checksums, and any interrupted block's;
every validity and admissibility line; each arm's pooled and per-block premium bounds per length; both directions of every comparison, the interaction, and K's lines;
contender completion, p50, p95, refusals and cancellations; p and q; premium gaps; preemptions; d, its p95 and unfinished count per length and block; the gateway's admission-to-first-content beside d, not judged;
each static arm's spacing deviations; `fixedS-ref` against `sizeaware-ref`; each card's identity, its cells' pace in the gate's sense, the timings, the cost and the termination record.
All three verdict families are published even when the primary stops early.

## What it licenses

Rule 6: that in these three sessions, at this load and these traces, hold-cap's tail advantage over **this frozen spacing, 1,680.4 ms**, grew by at least 15% from the reference to the long length, with hold-cap inside the owner's limits.
Not over fixed spacing generally: S is v26's ratio carried to this load and chosen because the replay predicted it would separate, and nothing here measures a wider spacing failing the limits (astra's first risk).
That fixed-S missed the protection target at long needs, in addition, L(F, O) > ln 0.85 there; a failed upper-bound test alone does not say it.
Hold-cap already ahead at the reference (5d), with rule 6 or 7: in addition, that on these sessions hold-cap beat the frozen spacing by 15% at the very length S was derived from. The calibration never ran fixed-S, so there was no measured tie for this to break; it says the frozen spacing did not transfer from the calibration's card and seed to these.
Rules 2 to 4, 5a to 5c and 7: that the registered contrast was not reached, or not shown; none establishes equivalence, a general failure, or anything that revises v26's or v27's verdicts.
The size-aware verdicts concern a control calibrated on one card and seed, whose short spacing, 1,176.9 ms, lies below the calibration's own short p95 of 1,253.9 ms. A loss is a loss of that calibration, not proof that static size knowledge cannot work (astra's third risk).

## What must be built before purchase

astra's inventory, to be re-checked against the code before each item is built:
1. the study id, its 16 labels and its arm-set check (`internal/bench/study.go`, `matrix_plan.go`), so `gen-trace` stamps exact tokens under it;
2. stage H in `hack/lib/prospective-pilot.sh`: the study, the three seeds, the arms, the 12 checksums, the per-arm length, and the gateway and cap mapping for `caponly-*`, `fixedS-*` and `sizeaware-*`, whose spacings the existing fixed mapping does not accept;
3. `hack/m5c-matrix.sh`: the allowlist, the rate guards, one block per session with the global block carried into the seed lookup, the order's hash, file names and request ids, the prompt substitution, the checksum table, and the archive README's scorer;
4. `hack/m5c-gpu-session.sh`: the study and stage, the block, 18,720 and 19,320 s, the rates, and the scoring command, through the user data to the instance;
5. a launch ledger that refuses a fifth launch, a second replacement, a replacement without a recorded Spot interruption, or a block already completed;
6. `pilot_report.py`: a main scorer over three session archives, the rules above, the calibration's `headroom` and v26's `frontier` left as they are;
   with two temporal witnesses the inherited lines lack (astra's finding 1): in a hold-cap cell, every admitted contender carries its release instant, each is admitted no sooner than the previous admitted contender's release, and each release lies at most 13 ms before its first content; in a fixed-spacing cell, every consecutive pair of contender admissions at least the spacing less 1 ms apart, whatever their reason labels. A missing stamp is missing evidence;
7. a versioned verifier for the main study's evidence, `verify-c3-evidence.sh` not repointed. It is written after the sessions and before any result is published, since its release tag, assets and committed verdict do not exist before them;
8. tests for each, spot-lifecycle goldens for stage H, and a kind rehearsal of three stage-H sessions scored together, with each new check made to fail once.

## Build status, 2026-10-25

Built and pushed on `feat/c3-main-gate`, each with its tests and each new check made to fail once:

| Item | Commit | What pins it |
|---|---|---|
| 1, the study | `374ecb8f` | the arm-set test; dropping the study from the rule turns it red |
| 2, stage H in the library | `c918373e`, `48ee7418` | the library checks: the 12 checksums, the nine equal to `trace-checksums.txt`, the spacings, the cap-only mapping, the three frozen orders; a wrong checksum and a wrong spacing each turn them red |
| 3, the matrix | `48ee7418` | the plan check passes all three blocks with the registered orders and contender counts 172, 148 and 163; it refuses a block on another's seed, a missing block, a fourth block, a block passed to stage G, the old rate, and an order hashed from the local repetition |
| 4, the session | `1ae2b556` | 36 lifecycle scenarios; the block reaches the instance's user data, and dropping its substitution fails every session scenario |
| 5, the ledger | `c4cd7ec2`, `7b7e92bb`, `b4850bda` | its rules on fixed ledgers, a session refusal read at HEAD, and scenarios on a fixed ledger so recording a launch does not change them |
| 6, the scorer | `885f3528`, `a8552458` | 16 tests, 13 mutations each red; the diagnostic, v26, v27 calibration and C3 calibration archives score byte-identically with the scorer before it |

codex's bare reviews of `885f3528` found two defects, a truncated cell crashing the report and the secondary verdicts waiting on the primary's text, both reproduced by a test and fixed in `a8552458`; of `c4cd7ec2` and `7b7e92bb`, tests that depended on the live ledger, fixed in `b4850bda`; of `efa7c235`, none. These are static reviews; the test runs are mine.
The kind rehearsal of stage H ran on 2026-10-25 at `efa7c235`: three matrices one after another, blocks 1 to 3 on seeds 882, 892 and 893, scored together by `pilot_report.py headroom-main`.
Every block wrote all 253 expected files and completed all 16 cells; every cell was eligible, ran its own admission mode and cap, and the 20-second traces' provenance lines failed by design.
Every validity line beyond provenance held, the new ones included (request ids naming the block, the engine's cap, the cell order, both temporal witnesses), except one class: the gateway's arrival-to-record and premium arrival-to-decision p99, bound at 13 ms, failed in 48 lines at 13.4 to 26.0 ms, every maximum under the 50 ms ceiling.
That is the failure the calibration's rehearsals showed on this host (13.1 to 23.6 ms), and which its control, v27's stage F on `dev`'s tree, showed too; on both cards since, those lines read 4.9 to 5.7 ms.
Block 1, run while I also ran the library and lifecycle checks, has 22 of the 48 lines; blocks 2 and 3, with nothing else running, 12 and 14.
The bound is not relaxed: on the cards it is judged as registered, and a failure there makes the study inconclusive.
The rehearsal kept no files (it ran without KEEP=1), so the scorer's verdict on the stub's evidence was not printed past the validity check that stopped it.
It was run again at `fb865e99` keeping its files: every block again wrote all 253 files; the untrusted validity lines were the 48 provenance lines and 51 gateway latency lines (18, 19 and 14 by block), p99 13.1 to 17.5 ms, every maximum under 19.9 ms; and `headroom-main` scored the three archives without error.
Beyond validity, kind cannot score two things the card does: the stub exports no preemption counter, so the four capped arms' 36 preemption lines were unscorable (on the calibration's card every such line was scored), and the stub's instant answers leave 21 completion-p50 and shared-window work lines failing against off. With provenance, gateway latency and preemptions forced to pass, the scorer ran through rules 1 to 3 and both separate verdicts on that evidence without error; rules 4 to 7 are pinned by the unit tests.

