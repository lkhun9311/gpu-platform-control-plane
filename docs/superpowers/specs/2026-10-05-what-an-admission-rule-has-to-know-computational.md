# What an admission rule has to know — a computational registration

Date: 2026-10-05 · Registered **before** the computation it describes is run, and frozen from that run; later changes are appended as dated amendments. **No card is bought by this page.**

**Why it exists.** The 2026-10-04 model-first registration concluded that an admission rule needs only the contender's prefill time and the victim's isolated tail, and that conclusion was withdrawn the same day: an independent review showed two latency-critical profiles with isolated p99s of 542.3 and 543.4 ms whose shared p99s, at the same contender, differ by a factor of 1.8 to 3.1 in the very simulator the conclusion rested on. The question the conclusion skipped is the one this page asks: **which summaries of a workload are sufficient to predict the latency-critical tenant's shared tail?** The answer is what an admission controller has to observe, and a paid run is worth buying only to test a rule that has been written down.

## 1. The simulator and its parameters

`hack/tail-crossing-model/itersim.py` with the `measured` parameters of `predict.py`, unchanged since they were fixed on 2026-10-05 from one isolated measurement. Everything here is a statement about that simulator. Its known error — it overstates the uncontended latency between 256 and 8,192 tokens, which falsified P4 on the card — is a limit on what this page can say about the card, recorded in section 6.

## 2. The declared domain

| Factor | Levels |
|---|---|
| Latency-critical length | 256, 512, 1,024, 2,048, 4,096, 8,192 tokens |
| Latency-critical utilisation `ρ_LC` = rate × its uncontended latency in the simulator | 0.05, 0.15, 0.30, 0.45 |
| Best-effort length | 2,048, 4,096, 8,192 tokens |
| Best-effort utilisation `ρ_B` = rate × `S_B`, where `S_B` is the simulator's uncontended latency of one best-effort request | 0.01, 0.02, 0.05, 0.10 |
| Held fixed | Outputs 64 and 16 tokens, budget 2,048, 64 sequences, 600 s traces |
| Replication | Ten traces per profile, seeds 1–10, pooled nearest-rank p99 |

288 contended profiles and 24 isolated ones. The levels are chosen to span what the paid runs measured (`ρ_LC` about 0.02–0.33 and `ρ_B` about 0.025–0.2 there) without tuning them to any result.

## 3. The candidate summaries

The target is `y` = the latency-critical tenant's pooled shared p99 divided by `S_B`, so profiles with different contenders are comparable. Each candidate is a set of features a controller could observe:

| Set | Features | What adopting it would mean |
|---|---|---|
| **A** — the withdrawn rule | `ρ_B`, isolated p99 / `S_B` | contender load and the victim's isolated tail suffice |
| **B** | A + `ρ_LC` | the victim's own load is needed as well |
| **C** | B + latency-critical length / best-effort length | length is a separate term after all |

## 4. The sufficiency test, fixed now

For each set, a k-nearest-neighbour predictor (k = 3, features log-transformed and standardised on the training profiles) predicts `y` for each **held-out latency-critical length** from the other five lengths' profiles — leave-one-length-out, six folds. The error is `|ŷ − y| / y` over all 288 held-out predictions.

**A set is sufficient if the 95th percentile of the held-out error is at most 10%.** The median and the worst case are published beside it. The registered expectations, written before the run: **A is not sufficient** (the counterexample is inside the domain); whether B is sufficient is the open question; C is published so that "length is a separate term" can be read off directly rather than argued.

The minimal sufficient set is the answer. If none is sufficient at 10%, that is the answer too, and the page says what tolerance the best set reaches.

## 5. What a paid test would then need

Only after section 4 has an answer: an explicit predictor `F` built on the minimal set, frozen, and a decision procedure for testing it on the card whose behaviour is measured first on at least 1,000 fresh simulated studies — a correct simulator rejected at most 5% of the time, specified wrong alternatives rejected at least 80% of the time. If no procedure meets both, no card is bought.

## 6. What this cannot establish

- Anything about the card that the simulator gets wrong. Its uncontended latency is wrong between the measured lengths; a summary sufficient in the simulator could be insufficient on the card, which is what a paid test would be for.
- Sufficiency outside the declared domain, or for other output lengths, budgets, models or cards.
- That k-nearest-neighbour prediction is the best a summary set allows. A set found insufficient here is insufficient for this predictor; a set found sufficient is sufficient at least for it.

## Result, 2026-10-05 — no candidate set is sufficient at 10%

`python3 hack/tail-crossing-model/sufficiency.py`, run once at `fce3e9a` exactly as registered: 288 contended and 24 isolated profiles, ten traces each.

| Set | Held-out error, median | 95th percentile | Worst | At 10% |
|---|---|---|---|---|
| A — `ρ_B`, isolated p99 / `S_B` | 5.6% | 33.7% | 88.8% | not sufficient |
| B — A + `ρ_LC` | 11.0% | 43.3% | 203.8% | not sufficient |
| C — B + length ratio | 8.4% | 37.2% | 196.9% | not sufficient |

**The registered answer is that none of the three is sufficient at 10%**, and the best set reaches a 95th-percentile error of 33.7% — the withdrawn rule's own summaries, A. Adding the victim's utilisation or the length ratio made the k-nearest-neighbour predictor **worse**, not better.

**Diagnostics, run after the verdict and not part of it.** Broken down by the held-out length, set A's 95th-percentile error is 37 / 19 / 24 / 15 / 12 / 56% for 256 … 8,192 tokens: the extremes, where a nearest-neighbour predictor has to extrapolate, are worst, and even the interior lengths do not reach 10%. So part of the failure is the predictor the registration fixed, and section 6 already says a set found insufficient here is insufficient **for this predictor**. Two further facts bear on how to read it: the counterexample that prompted this page puts the 256-token tenant at `ρ_LC` = 15.15 × 0.0696 = **1.05**, outside the declared domain, where the victim saturates on its own; and inside the domain the withdrawn rule's summaries were the best of the three, with a median error of 5.6%.

**What this changes.** No explicit predictor built from these summaries meets the tolerance a paid test would need, so section 5's condition for buying a card is not met and **no card is bought**. The next question is a modelling one: a predictor with structure — the queueing argument behind P2, rather than nearest neighbours — registered and checked here before it is held against the card.
