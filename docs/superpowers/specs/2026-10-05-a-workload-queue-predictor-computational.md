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
