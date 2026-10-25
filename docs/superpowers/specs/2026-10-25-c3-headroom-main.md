# C3's main study: hold-cap against a frozen fixed spacing and a size-aware one, over three cards — pre-registered

Written 2026-10-25. **Not frozen for purchase.** The build, the plan check, the kind rehearsal and codex's cold attack of this page come first, and buying it needs the owner's separate approval.
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
| A card faster than the gate's band | not considered | not considered | a named verdict, below: the pass band's upper edge is a reference tie that breaks toward hold-cap, and that outcome answers something |
| Replacement launches | not considered | at most one, for a documented Spot interruption only | astra's |
| Top risk | seed 882's heavy draw at long | the fixed control was chosen on the separation the replay predicted | both stated; astra's limits what a win licenses ("What it licenses") |

## The question

At premium 9.25/s and contender 0.375/s, on A10Gs, at contender prompts of 6,144, 7,695 and 8,192 tokens:
does hold-cap keep its advantage over a fixed spacing frozen at the reference, S = 1,680.4 ms, growing from the reference to the long length, while hold-cap stays admissible and protective?
And does a static spacing that knows the prompt's length do as well, and does the cap alone account for the protection?

It is an observation on three cards, three traces and one load. It is not a claim about A10Gs in general, other loads, or admission policies generally.

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
Both static arms use the gateway's existing fixed-spacing mode: only an admission advances its clock, premium bypasses it, and a waiter that expires gets no slot.
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
Distinct instances are not shown to be distinct physical hosts; the instance id and the GPU's UUID are recorded.

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

1. **inconclusive: <reason>**, for a missing or extra cell or block, any failed or unscorable validity line, or any unscorable admissibility input. A fully observed +∞ is not missing.
2. **hold-cap not operationally robust: <length, block, line>**, when H fails any admissibility line anywhere. Every failure is listed.
3. **hold-cap's protection not established at <length>**, when U(H, O) > ln 0.85 at any length.
4. **challenge not reproduced on block <b>**, unless on every block d(ref, b) ≤ 1,680.4, d(long, b) > 1,680.4, and d(long, b) > 1.05 × d(ref, b). A missing, not positive or infinite median reads inconclusive here instead.
   The 1.05 condition is back: S is frozen, no longer recomputed from each card's own reference, so exceeding S no longer implies it.
5. **The reference comparison**, the first that applies:
   - 5a. **reference comparison not established: fixed-S <inadmissible | not protective> at ref**, when F fails an admissibility line at ref, or U(F, O) > ln 0.85 there;
   - 5b. **hold-cap beat the frozen spacing at the reference already**, when W(H, F) at ref;
   - 5c. **the frozen spacing beat hold-cap at the reference**, when W(F, H) at ref;
   - 5d. **reference comparison not established: <which bound or work line>**, when U(H, F) ≤ ln 0.85 or U(F, H) ≤ ln 0.85 at ref without the W that would name it;
   - otherwise neither is 15% below the other at ref, and the verdict goes on. That is not equivalence; N(F, H) at ref is published beside it.
6. **length-dependent advantage over the frozen spacing observed**, when the interaction I⁺ = U(H, F) at long − L(H, F) at ref ≤ ln 0.85, K(H, F) at long, and either F is inadmissible at long or W(H, F) at long.
   The reference's lower bound is subtracted, so the interaction is the unfavourable end. With F's bound infinite at long and H's finite, I⁺ is −∞ and holds; with H's infinite it is +∞ and fails.
7. **length-dependent advantage not established: <which>**, otherwise, naming the failed interaction, separation or work line, and any reverse W(F, H) at long.

Rule 5b is the outcome the gate's pass band ends on: above a replay pace of about 1.033, fixed-S at ref begins to collapse while every seed's d(ref) is still under S (`pace-band.txt`).
It is registered before purchase, so that outcome is not folded into "not established". The interaction is still computed and published under it, and not judged.

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
on every seed d(ref) at most 1,638.0 ms and d(long) at least 1,714.3 ms against S = 1,680.4; at ref, hold-cap 400 against fixed-S 433 ms; at long, 452 against 1,489.5 ms; the interaction −1.113 against ln 0.85 = −0.163.
Nothing was required of the other arms, and the replay predicts neither secondary verdict favourably: size-aware at short 519 ms against hold-cap's 328, at long 428 against 452, so N(A, H) fails at short and W(H, A) at long does not hold; cap-only above off at every length, 1,224 to 1,806 ms against 1,119 to 1,589.

Its pass band, sensitivity and not deciding (`pace-band.txt`): from about 1.007, where seed 892's d(long) falls under S, to about 1.033, where hold-cap over fixed-S at ref falls under 0.85.
Every archived hold-cap cell has run inside it, in the gate's sense of pace: eight ref cells on four cards at 1.0167 to 1.0275, two long cells at 1.0270 and 1.0291.
The upper edge lies 0.0054 above the fastest, which is the calibration's own card, the only one at this load. If that card's pace is typical of this load, about one chance in seven that one of three cards crosses it; if the 0.5/s cards are, almost none.

The gate is not blind: these seeds' replays were read while the calibration page was written. A pass says the modelled prerequisites of rules 2 to 6 are reachable at the nominal pace, not the verdict.
Preemption, shared-window work and premium gaps are not modelled, the replay's d differs from the scorer's in definition and population, and the replay has understated the contender's cost by 3% to 7% against every card measured.

## Published whatever the verdict

The registration's version; the gate, its control and every sensitivity run; every cell's inventory and every exclusion; all three sessions' raw evidence under checksums, and any interrupted block's;
every validity and admissibility line; each arm's pooled and per-block premium bounds per length; both directions of every comparison, the interaction, and K's lines;
contender completion, p50, p95, refusals and cancellations; p and q; premium gaps; preemptions; d, its p95 and unfinished count per length and block; the gateway's admission-to-first-content beside d, not judged;
each static arm's spacing deviations; `fixedS-ref` against `sizeaware-ref`; each card's identity, its cells' pace in the gate's sense, the timings, the cost and the termination record.
All three verdict families are published even when the primary stops early.

## What it licenses

Rule 6: that on these three cards, at this load and these traces, hold-cap's tail advantage over **this frozen spacing, 1,680.4 ms**, grew by at least 15% from the reference to the long length, with hold-cap inside the owner's limits.
Not over fixed spacing generally: S is v26's ratio carried to this load and chosen because the replay predicted it would separate, and nothing here measures a wider spacing failing the limits (astra's first risk).
That fixed-S missed the protection target at long needs, in addition, L(F, O) > ln 0.85 there; a failed upper-bound test alone does not say it.
Rule 5b: that a spacing frozen on one card at the reference did not hold its tie with hold-cap at that same length on these cards. It says nothing about length dependence.
Rules 2 to 4, 5a, 5c, 5d and 7: that the registered contrast was not reached, or not shown; none establishes equivalence, a general failure, or anything that revises v26's or v27's verdicts.
The size-aware verdicts concern a control calibrated on one card and seed, whose short spacing, 1,176.9 ms, lies below the calibration's own short p95 of 1,253.9 ms. A loss is a loss of that calibration, not proof that static size knowledge cannot work (astra's third risk).

## What must be built before purchase

astra's inventory, to be re-checked against the code before each item is built:
1. the study id, its 16 labels and its arm-set check (`internal/bench/study.go`, `matrix_plan.go`), so `gen-trace` stamps exact tokens under it;
2. stage H in `hack/lib/prospective-pilot.sh`: the study, the three seeds, the arms, the 12 checksums, the per-arm length, and the gateway and cap mapping for `caponly-*`, `fixedS-*` and `sizeaware-*`, whose spacings the existing fixed mapping does not accept;
3. `hack/m5c-matrix.sh`: the allowlist, the rate guards, one block per session with the global block carried into the seed lookup, the order's hash, file names and request ids, the prompt substitution, the checksum table, and the archive README's scorer;
4. `hack/m5c-gpu-session.sh`: the study and stage, the block, 18,720 and 19,320 s, the rates, and the scoring command, through the user data to the instance;
5. a launch ledger that refuses a fourth launch, a second replacement, or a block already completed;
6. `pilot_report.py`: a main scorer over three session archives, the rules above, the calibration's `headroom` and v26's `frontier` left as they are;
7. a versioned verifier for the main study's evidence, `verify-c3-evidence.sh` not repointed;
8. tests for each, spot-lifecycle goldens for stage H, and a kind rehearsal of three stage-H sessions scored together, with each new check made to fail once.
