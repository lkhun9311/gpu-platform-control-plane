# A workload-queue predictor of the latency-critical shared tail — a computational registration

Date: 2026-10-05 · Registered **before** the computation it describes is run, and frozen from that run; later changes are appended as dated amendments. **No card is bought by this page.**

**Why it exists.** `2026-10-05-what-an-admission-rule-has-to-know-computational.md` found that no summary set, used by a nearest-neighbour predictor, predicts the shared tail within 10% in the simulator, and that part of the failure was the predictor: it interpolates between other lengths' shared tails and cannot extrapolate. This page registers a predictor **with structure** and asks whether it is sufficient. The design was made independently by codex `gpt-6-astra` and by me and reconciled: astra's workload-queue form is the primary predictor, mine is published beside it as a secondary one, and astra's stricter gates are adopted. Both drafts are summarised in section 7.

## 1. The simulator

`hack/tail-crossing-model/itersim.py` with `PARAMS["measured"]` of `predict.py`, unchanged. Every statement here is about that simulator.

## 2. The predictor F

A **virtual FCFS workload**: each arrival adds an effective amount of work — `a_L` for a latency-critical request, `a_B` for a best-effort one — to a single queue that drains at rate one. A latency-critical request's predicted latency is the queue's backlog when it arrives plus a draw from its own **single-request** latency distribution `U_L`.

```
virtual_latencies(λL, λB, aL, aB, UL, seeds):
  for each seed: merge independent Poisson streams of LC (λL) and BE (λB) arrivals over 600 s;
    work_end = 0
    for each arrival in time order:
      wait = max(0, work_end − arrival); work_end = arrival + wait + (aL if LC else aB)
      if LC: record wait + UL
F(λL, λB) = q0 + Q99(virtual_latencies(λL, λB)) − Q99(virtual_latencies(λL, 0))
```

`Q99` is the pooled nearest-rank p99 over the forecast traces. **F predicts the contention increment** and adds it to the independently measured isolated tail `q0`. F is unsupported where `λL·aL + λB·aB ≥ 1`; an unsupported profile counts as a failure of the gate it falls in.

**Inputs, and how each is obtained without any shared-engine outcome:**

| Input | Obtained from |
|---|---|
| `U_L` | The simulator's client TTFT of one latency-critical request alone, per length (it is deterministic in the simulator) |
| `q0` | Pooled isolated p99 at the profile's LC rate, from **profiling** traces |
| `a_L` | Fitted per LC length to that length's **LC-alone** curve at its four registered LC rates: minimise the sum over rates of (log predicted/measured p95)² + (log predicted/measured p99)², golden-section search over `0 < a < 1/max rate`, 60 iterations |
| `a_B` | The same, per BE length, from the **BE-alone** curve at its four registered BE rates, the best-effort tenant's own TTFT (output 16) |

**Raw length is not an input**; it enters only through the per-profile measured `U_L`, `q0`, `a_L` and `a_B`. A pass establishes that these measured inputs are sufficient, not that any smaller set is.

## 3. Seeds, kept apart

| Use | Seeds | Traces |
|---|---|---|
| Profiling: the LC-alone and BE-alone curves that fit `a_L`, `a_B`, and the `q0` sample | 10001–10050 | 50 per curve point |
| Forecasts inside F | 30001–32000 | 2,000 per profile and arm |
| Reference outcomes the gates compare against | 20001–21000 | **1,000 per profile** |

All 288 shared profiles of the earlier page's domain are held out: no shared outcome is used for anything but the gates, and F's predictions are computed and written to disk before the first reference shared trace is generated.

## 4. The gates

On the 288 shared profiles, with `Q` the pooled reference p99 over 1,000 traces and `Δref = Q − Q_iso` (the reference isolated p99, same seeds):

| Gate | Criterion |
|---|---|
| **G1** | 95th percentile of `|F − Q| / Q` ≤ 10% |
| **G2** | G1 within each latency-critical length separately — six strata |
| **G3** | 95th percentile of `|ΔF − Δref| / max(|Δref|, 0.1 · median(U_B))` ≤ 10%, where `U_B` is the best-effort single-request latency of that profile's BE length |
| **G4** | Published, not gated: the isolated validation — `q0` against the reference isolated p99, and F's fitted queue against the LC-alone curves |

**Uncertainty.** The reference p99 of every profile is bootstrapped over whole traces (200 resamples). A gate **passes** only if it holds with each profile's error taken at the less favourable end of its bootstrap 95% interval, **fails** if it fails at the favourable end, and is **inconclusive** otherwise.

## 5. The secondary predictor, published and not gated

Mine: `z = x + w`, where `x` is drawn from the profiling isolated sample and `w = U(0, S_B) / (1 − ρ_LC)` with probability `min(1, ρ_B)`, else 0; `F' = Q99(z)`. It is a coincidence-plus-recovery approximation with no fitted parameter, and comparing it with F shows whether the queue recursion matters.

## 6. What a result decides

- **G1, G2 and G3 all pass:** F becomes the candidate admission predictor. The next registration calibrates a paid test of it — a complete study procedure simulated at least 1,000 times under the correct simulator and under named wrong alternatives (coincidence only; mixed-prefill iterations 1.25× slower; the decode cost raised to 1.0 ms when both tenants run) — and buys a card only if correct-model rejection is at most 5% and each alternative's rejection at least 80% at one-sided 95% bounds.
- **Any gate fails:** no paid run. The next question is which scheduler state — iteration boundaries, decode batching — the additive-work reduction misses. A failure here would not show that prompt length is an extra scalar input; that inference was withdrawn once already.
- **Inconclusive:** more reference traces, not a different criterion.

## 7. The two drafts, for the record

| | astra | mine |
|---|---|---|
| Structure | Virtual FCFS workload with fitted effective work per tenant (adopted) | Isolated sample plus a residual wait inflated by `1/(1 − ρ_LC)` (secondary) |
| Baseline | Increment added to measured `q0` (adopted) | Whole distribution convolved |
| Reference precision | 1,000 traces per profile (adopted) | 10 traces |
| Gates | Overall, per length, increment, uncertainty (adopted) | Overall only |

## 8. What this cannot establish

Anything about the card. The simulator's own uncontended latency is wrong between measured lengths, and the alternatives section 6 names are exactly the mechanisms it may be missing; this page can only say whether the card would be worth asking.

## Result, 2026-10-05 — F fails G1 and G3; no card is bought

`python3 hack/tail-crossing-model/queue_predictor.py`, run once at `e31d022` with the registered seeds and counts. F's predictions for all 288 profiles were written to disk before the first reference trace. **Disclosed:** before that run, a smoke test of the pipeline at toy scale (3 profiling, 20 forecast and 10 reference traces, 20 resamples — the reference seeds a subset of the registered ones) printed gate lines; nothing in F, the gates or the seeds was changed after it.

Fitted effective work per arrival, seconds: `a_L` 0.0430 / 0.0775 / 0.1571 / 0.3090 / 0.5631 / 1.0716 for 256 … 8,192 tokens; `a_B` 0.2936 / 0.5397 / 0.9501 for 2,048 / 4,096 / 8,192.

| Gate | Verdict | p95 error, unfavourable / favourable end |
|---|---|---|
| G1 overall | **FAIL** | 15.1% / 13.3% |
| G2, 256 tokens | FAIL | 23.6% / 18.6% |
| G2, 512 | FAIL | 15.2% / 14.5% |
| G2, 1,024 | FAIL | 12.7% / 10.6% |
| G2, 2,048 | FAIL | 13.7% / 12.4% |
| G2, 4,096 | inconclusive | 10.5% / 8.1% |
| G2, 8,192 | PASS | 8.1% / 5.1% |
| G3 increment | **FAIL** | 72.3% / 57.7% |

The secondary predictor F' (not gated) reached a 95th-percentile error of 27.4% with a median of 3.4%.

**The registered consequence: no paid run.** F is far better than the nearest-neighbour predictor (15.1% against 33.7% at the 95th percentile) and is centred — its median signed error is between +0.6% and +3.0% under every factor level — but it is not sufficient at 10%, and it gets the contention increment badly wrong.

**Diagnostic, after the verdict and not part of it.** The large errors are on the short latency-critical lengths and go both ways: F overstates the tail when the contender is short and rare (+24.2% at 256 tokens, `ρ_LC` 0.05, BE 2,048 at `ρ_B` 0.02), and understates it when the contender is long and frequent (−17.9% at 256 tokens, `ρ_LC` 0.45, BE 8,192 at `ρ_B` 0.10). The second is the mechanism stage 1 pointed at on the card: an in-progress long prefill takes the step's token budget first, so short prefills stretch across steps, which an additive amount of work per arrival cannot express. The registration named iteration-level state as the thing a failure would point to, and it does.

**What this leaves.** No reduction tried so far — three summary sets, a structured queue — predicts the shared tail within 10% across the domain; the simulator itself does, on the card's own traces, within a few percent at the latency-critical rate this study held. Whether an admission controller should run that iteration-level simulator against its measured parameters, rather than apply a rule, is the question these results raise; it is not answered here.

**G4, published after an independent review found the implementation did not print it** (`queue_predictor.py --g4`, computed from the saved run; every quantity in it is seeded, so it is the run's own G4, not a re-run). The profiling `q0` lies within −0.3% to +3.8% of the reference isolated p99 at all 24 latency-critical profiles. The fitted queue reproduces the LC-alone curves it was fitted to within 5% at most points and within 11.4% at worst (2,048 tokens at 1.588 req/s, p99). So the baseline and the single-tenant fits are sound, and **the failure is in the mixing of the two tenants** — the contention G3 measures — which is what the diagnostic above located.

## Re-run and correction, 2026-10-06

**The result reproduces exactly.** A cold review by codex `gpt-6-astra` found no saved predictions or reference outcomes in the repository, so the gates above could not be re-derived from rows. I re-ran `queue_predictor.py` at `e31d022` in a separate worktree, with the registered seeds. Every gate line came out identical: G1 15.1% / 13.3%; G2 23.6%, 15.2%, 12.7%, 13.7%, 10.5% (INCONCLUSIVE) and 8.1% at 256 to 8,192 tokens; G3 72.3% / 57.7%; F′ 27.4%. Its outputs are now kept as `data/2026-10-05-queue-predictor-predictions.json` and `data/2026-10-05-queue-predictor-references.json`.

**"The single-tenant fits are sound" overstated the G4 paragraph.** The same paragraph gives the fitted queue's worst agreement with the LC-alone curves as 11.4%, which is outside the 10% the gates use. So the mixing of the two tenants is where the diagnostic located the largest errors, not the only source of error: imperfect single-tenant fits remain a contributor. The verdict is unchanged.
